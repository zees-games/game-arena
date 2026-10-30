extends RefCounted

## ArenaPlayer hooks for dot-replay's [DotKillcamHost]: how a drawn body is read and posed.

const KillPov := preload("arena_kill_pov.gd")
const SKIP_ACTIONS: PackedStringArray = ["dot_fps_jump", "arena_fire", "ui_cancel"]


## Gives [param host] arena's skip keys and body hooks.
static func configure(host: DotKillcamHost) -> void:
	host.log_channel = "arena.killcam"
	host.skip_actions = SKIP_ACTIONS
	host.skip_hint = "Jump or Fire to skip"
	host.state_fn = state_of
	host.place_body_fn = place_body
	host.restore_body_fn = restore_body
	if DotAddonApi.build_level("dot_replay") >= 7:  # older hosts replay bodies by speed only
		host.set(&"pose_fn", pose_of)
		host.set(&"apply_pose_fn", apply_pose)


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
	var body: Node3D = p.get(&"body_mesh")
	if body != null:
		body.transform = saved[0]
		body.visible = saved[1]


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
		touched[p] = [body.transform, false if attached else body.visible]
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
