extends RefCounted

## ArenaPlayer hooks for dot-replay's [DotKillcamHost]: how a drawn body is read and posed.

const KillPov := preload("arena_kill_pov.gd")
const ArenaPlayer := preload("arena_player.gd")
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
static func configure(host: DotKillcamHost, yard_fn: Callable = Callable()) -> void:
	host.log_channel = "arena.killcam"
	host.skip_actions = SKIP_ACTIONS
	host.skip_hint = "Jump or Fire to skip"
	host.state_fn = state_of
	host.place_body_fn = place_body
	host.restore_body_fn = restore_body
	if DotAddonApi.build_level("dot_replay") >= 7:  # older hosts replay bodies by speed only
		host.set(&"pose_fn", pose_of)
		host.set(&"apply_pose_fn", apply_pose)
	if DotAddonApi.build_level("dot_replay") >= 8:
		host.set(&"event_fn", func(p: Node, ra: Array, rb: Array, alpha: float, is_victim: bool) -> void:
			replay_events(p, ra, rb, alpha, is_victim, yard_fn.call() if yard_fn.is_valid() else null))


## What a body did between two recorded rows: its muzzle flash and tracer for each new shot, and the death ragdoll
## the frame the victim's row turns dead.
static func replay_events(p: Node, ra: Array, rb: Array, alpha: float, is_victim: bool, yard: Variant) -> void:
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
			held.call(&"on_fired", ArenaPlayer.WATCHED_RECOIL.get(kind, Vector2(0.6, 0.1)), kind)
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
	if made is Node and is_instance_valid(made):
		(made as Node).queue_free()
	for old: Variant in (p.get_meta(HIDDEN_META) if p.has_meta(HIDDEN_META) else []):
		if old is Node3D and is_instance_valid(old):
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
	return figure.call(&"pose_record")


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
		figure.call(&"set_motion", {"on_floor": true, "alive": true, "aim": deg_to_rad(pitch)})
		figure.call(&"animate", speed, figure.call(&"frame_delta"))
