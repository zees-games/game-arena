extends RefCounted

## ArenaPlayer hooks for dot-replay's [DotKillcamHost]: how a drawn body is read and posed.

const KillPov := preload("arena_kill_pov.gd")
const KillcamShots := preload("arena_killcam_shots.gd")
const ArenaPlayer := preload("arena_player.gd")
## `cl_killcam_hz`: most recordings of every body's state a second while no replay plays (0: one every frame). The replay
## interpolates between rows, so 60 a second draws the same replay as 240; the recording was 0.03 ms a body a frame.
static var record_hz: float = 60.0
## The pose record written by [method _record_fast] rather than the figure's own (identical layout).
static var fast_pose: bool = true

const SKIP_ACTIONS: PackedStringArray = ["dot_fps_jump", "arena_fire", "ui_cancel"]
const SEQ_RANGE := 4096
const SEQ_META := &"killcam_seen_seq"
const ALIVE_META := &"killcam_seen_alive"
const FALL_META := &"killcam_ragdoll"
const HIDDEN_META := &"killcam_hidden_ragdolls"
## Aux columns in a state row (5 + aux index).
const ROW_FIRE_SEQ := 7
const ROW_FIRE_KIND := 8


## Gives [param host] arena's skip keys and body hooks. [param yard_fn] returns the client's DotPlayerRagdolls (or null).
static func configure(host: DotKillcamHost, yard_fn: Callable = Callable(), shots: KillcamShots = null) -> void:
	host.log_channel = "arena.killcam"
	host.skip_actions = SKIP_ACTIONS
	host.skip_hint = "Jump or Fire to skip"
	host.state_fn = state_of
	if shots != null:
		shots.state_fn = state_of
	host.place_body_fn = place_body
	host.restore_body_fn = restore_body
	if DotAddonApi.build_level("dot_replay") >= 7:  # older hosts replay bodies by speed only
		host.set(&"pose_fn", pose_of)
		host.set(&"apply_pose_fn", apply_pose)
	if DotAddonApi.build_level("dot_replay") >= 8:
		host.set(&"event_fn", func(p: Node, ra: Array, rb: Array, alpha: float, is_victim: bool) -> void:
			var again: Array = host.get(&"_again")
			var at: float = float((again[0] as Dictionary).get("time", -1.0)) if not again.is_empty() else -1.0
			replay_events(p, ra, rb, alpha, is_victim, yard_fn.call() if yard_fn.is_valid() else null, shots, at))


## What a body did between two recorded rows: its muzzle flash and tracer for each new shot, and the death ragdoll
## the frame the victim's row turns dead.
static func replay_events(p: Node, ra: Array, rb: Array, alpha: float, is_victim: bool, yard: Variant, shots: KillcamShots = null, at: float = -1.0) -> void:
	var row := rb if alpha >= 0.5 else ra
	var body: Node3D = p.get(&"body_mesh")
	var held: Node3D = p.get(&"held")
	if row.size() > ROW_FIRE_KIND:
		var seq := int(row[ROW_FIRE_SEQ])
		var seen: int = p.get_meta(SEQ_META, seq)
		p.set_meta(SEQ_META, seq)
		var fresh := posmod(seq - seen, SEQ_RANGE)
		if fresh > 0 and fresh < SEQ_RANGE / 2 and body != null and body.visible and held != null:
			var kind := int(row[ROW_FIRE_KIND])
			var recoil: Vector2 = ArenaPlayer.WATCHED_RECOIL.get(kind, Vector2(0.6, 0.1))
			# The recorded shot (where the gun stood and pointed) draws the flash, tracer and spark; without one the
			# held weapon draws its own from where it points now.
			var shot := shots.take(int(p.get(&"player_id")), at) if shots != null and at >= 0.0 else {}
			if shot.is_empty():
				held.call(&"on_fired", recoil, kind)
			else:
				held.call(&"on_fired", recoil, kind, false)
				shots.play(shot, p, kind)
	var alive: bool = row[3]
	var was: bool = p.get_meta(ALIVE_META, alive)
	p.set_meta(ALIVE_META, alive)
	if is_victim and was and not alive and yard is DotPlayerRagdolls and body != null and not p.has_meta(FALL_META):
		_fall(p, body, ra, rb, alpha, yard as DotPlayerRagdolls)


static func _fall(p: Node, body: Node3D, ra: Array, rb: Array, alpha: float, yard: DotPlayerRagdolls) -> void:
	var hidden: Array = []
	for old: DotPlayerRagdoll in yard.live():
		if old.visible:
			old.visible = false
			hidden.append(old)
	body.global_position = (ra[0] as Vector3).lerp(rb[0], alpha)
	body.global_basis = Basis(Vector3.UP, lerp_angle(deg_to_rad(ra[1]), deg_to_rad(rb[1]), alpha))
	var was_shown := body.visible
	body.visible = true
	var made: Variant = p.call(&"fall_body", yard, DotPlayerDeath.new(), false)
	body.visible = was_shown
	if made != null:
		p.set_meta(FALL_META, made)
	p.set_meta(HIDDEN_META, hidden)


## Puts back what [method replay_events] changed on [param p]: the ragdoll it made, the ones it hid, its counters.
static func _forget(p: Node) -> void:
	var made: Variant = p.get_meta(FALL_META) if p.has_meta(FALL_META) else null
	if is_instance_valid(made) and made is Node:
		(made as Node).queue_free()
	for old: Variant in (p.get_meta(HIDDEN_META) if p.has_meta(HIDDEN_META) else []):
		if is_instance_valid(old) and old is Node3D:
			(old as Node3D).visible = true
	for key: StringName in [SEQ_META, ALIVE_META, FALL_META, HIDDEN_META]:
		if p.has_meta(key):
			p.remove_meta(key)


## The body's skeleton pose as drawn; none for a body nobody sees (a first-person player's own).
static func pose_of(p: Node) -> PackedFloat32Array:
	var body: Node3D = p.get(&"body_mesh")
	var figure: Object = p.get(&"figure")
	if body == null or not body.visible or figure == null or not figure.has_method(&"pose_record"):
		return PackedFloat32Array()
	if fast_pose:
		var sk: Skeleton3D = figure.get(&"_skeleton")
		var model: Node3D = figure.get(&"_model")
		if sk != null and model != null:
			return _record_fast(figure, sk, model)
	return figure.call(&"pose_record")


## `DotHumanoidPoseRecord.record` with one allocation and indexed writes in place of an `append_array([...])` per bone, and the
## root bones found once per figure; the same layout, so `pose_apply` reads it unchanged.
static func _record_fast(figure: Object, sk: Skeleton3D, model: Node3D) -> PackedFloat32Array:
	var n := sk.get_bone_count()
	var roots: PackedInt32Array
	if figure.has_meta(&"kc_roots") and int(figure.get_meta(&"kc_roots_n", -1)) == n:
		roots = figure.get_meta(&"kc_roots")
	else:
		for i in n:
			var parent := sk.get_bone_parent(i)
			if parent < 0 or sk.get_bone_parent(parent) < 0:
				roots.append(i)
		figure.set_meta(&"kc_roots", roots)
		figure.set_meta(&"kc_roots_n", n)
	var out := PackedFloat32Array()
	out.resize(13 + n * 4 + roots.size() * 3)
	var t := model.transform
	out[0] = n
	var bx := t.basis.x
	var by := t.basis.y
	var bz := t.basis.z
	var o := t.origin
	out[1] = bx.x; out[2] = bx.y; out[3] = bx.z
	out[4] = by.x; out[5] = by.y; out[6] = by.z
	out[7] = bz.x; out[8] = bz.y; out[9] = bz.z
	out[10] = o.x; out[11] = o.y; out[12] = o.z
	var k := 13
	for i in n:
		var q := sk.get_bone_pose_rotation(i)
		out[k] = q.x; out[k + 1] = q.y; out[k + 2] = q.z; out[k + 3] = q.w
		k += 4
	for i in roots:
		var v := sk.get_bone_pose_position(i)
		out[k] = v.x; out[k + 1] = v.y; out[k + 2] = v.z
		k += 3
	return out


static func apply_pose(p: Node, a: PackedFloat32Array, b: PackedFloat32Array, alpha: float) -> void:
	var figure: Object = p.get(&"figure")
	if figure != null and figure.has_method(&"pose_apply"):
		var _drawn: bool = figure.call(&"pose_apply", a, b, alpha)


# [feet, yaw, pitch, alive, eye height]: where the body was drawn, not where the tick put it.
static func state_of(p: Node) -> Array:
	var controller: DotFpsController = p.get(&"controller")
	if controller == null:
		return []
	var st := controller.state
	var eye_h := 1.6
	if controller.motor != null:
		eye_h = controller.motor.eye_position(st).y - st.position.y
	var yaw := st.yaw
	var pitch := st.pitch
	var feet := (p as Node3D).global_position
	var view: Node3D = p.get(&"view")
	var body: Node3D = p.get(&"body_mesh")
	if p.get(&"camera") != null and view != null:
		var look: Variant = p.get(&"view_now")
		if look is Vector2:
			yaw = (look as Vector2).x
			pitch = (look as Vector2).y
		feet = view.global_position - Vector3(0.0, eye_h, 0.0)
	elif body != null and bool(p.get(&"interpolate_body")):
		feet = body.global_position
	return [feet, yaw, pitch, bool(p.call(&"is_alive")), eye_h] + Array(KillPov.aux_of(p))


static func restore_body(p: Node, saved: Array) -> void:
	_forget(p)
	var body: Node3D = p.get(&"body_mesh")
	if body != null:
		body.transform = saved[0]
		# A remote body saved hidden while down is alive again by now: the respawn drew it, and the
		# snapshot would leave a live bot invisible. A body attached for the replay stays hidden after it.
		body.visible = saved[1] or (saved.size() < 3 and bool(p.call(&"is_alive")))


## The player's crouch fraction (x) and slide (y, 1 or 0) now: the replay hands a hidden body no
## recorded pose, so its live stance is the nearest thing to what it was doing.
static func _stance_of(p: Node) -> Vector2:
	var controller: DotFpsController = p.get(&"controller")
	if controller == null:
		return Vector2.ZERO
	return Vector2(controller.state.crouch_fraction, 1.0 if controller.state.is_sliding() else 0.0)


static func place_body(p: Node, feet: Vector3, yaw: float, shown: bool, pitch: float, speed: float, touched: Dictionary) -> void:
	var body: Node3D = p.get(&"body_mesh")
	var attached := false
	if body == null:
		if not shown:
			return
		p.call(&"attach_body_mesh", Color.WHITE, p.get(&"avatar"))
		body = p.get(&"body_mesh")
		attached = true
		if body == null:
			return
	if not touched.has(p):
		# A body attached only for the replay (a first-person player's own) goes back hidden.
		touched[p] = [body.transform, false if attached else body.visible] + ([true] if attached else [])
	body.visible = shown
	if not shown:
		return
	body.global_position = feet
	body.global_basis = Basis(Vector3.UP, deg_to_rad(yaw))
	var figure: Node3D = p.get(&"figure")
	if figure == null:
		return
	figure.set(&"hide_head", false)
	figure.position = Vector3.ZERO
	# A body hidden before the replay had no pose recorded: animated here by the frame's real
	# time, since a clip switched with none left to blend in draws the rest pose.
	if not bool(touched[p][1]):
		var stance := _stance_of(p)
		figure.call(&"set_motion", {"on_floor": true, "alive": true, "aim": deg_to_rad(pitch),
			"crouched": stance.x > 0.5, "crouch": stance.x, "sliding": stance.y > 0.5})
		figure.call(&"animate", speed, figure.call(&"frame_delta"))
