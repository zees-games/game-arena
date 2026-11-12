extends RefCounted

## The phone's controls: dot-mobile's stick, drag-look and buttons over the HUD, driving the client's own
## [DotFpsTouchSampler]. Fire is read through [method is_held], so a thumb and auto-fire take the Fire key's path.
## Built on every client: a server may give auto-fire to keyboard players too (`sv_autofire_desktop`). See docs/client.md, "Touch".

const SelfScript := preload("arena_touch.gd")
const TagRules := preload("arena_name_tag_rules.gd")

## Offsets are from the bottom-right corner (see [DotTouchButtons]). Every radius is at least 24 so a
## button is 48 px across, thumb size, and the cluster still sits above the ammunition plate.
const LAYOUT: Array[Dictionary] = [
	{"id": &"fire", "label": "FIRE", "offset": Vector2(86, 150), "radius": 52.0},
	{"id": &"jump", "label": "JUMP", "offset": Vector2(200, 130), "radius": 42.0, "hold": DotFpsCommand.BUTTON_JUMP},
	{"id": &"crouch", "label": "DUCK", "offset": Vector2(60, 272), "radius": 36.0, "hold": DotFpsCommand.BUTTON_CROUCH},
	{"id": &"reload", "label": "R", "offset": Vector2(170, 244), "radius": 36.0},
	{"id": &"next", "label": "NEXT", "offset": Vector2(268, 200), "radius": 36.0},
]

## Aim assist's candidates: within this many degrees of the crosshair and metres, each checked for a wall.
const ASSIST_CONE_DEG := 10.0
const ASSIST_RANGE := 80.0

var controls: DotMobileControls = null
## dot-ui's buttons inside the overlay, for the shell's DPI fit.
var buttons: DotTouchButtons:
	get:
		return controls.buttons if controls != null else null

var _client: Node = null


## Builds the overlay under [param host] (the HUD), following [param rules] (the server's). Never null.
static func build(client: Node, host: Control, sampler: DotFpsSampler, rules: DotMobileRules, menu_button: Button = null) -> RefCounted:
	var made: RefCounted = (SelfScript as GDScript).new()
	made.call(&"_setup", client, host, sampler, rules, menu_button)
	return made


func _setup(client: Node, host: Control, sampler: DotFpsSampler, rules: DotMobileRules, menu_button: Button) -> void:
	_client = client
	controls = DotMobileControls.new()
	controls.name = "TouchControls"
	controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if rules != null:
		controls.rules = rules
	if menu_button != null:
		controls.ignore_fn = func(at: Vector2) -> bool:
			return menu_button.visible and menu_button.get_global_rect().has_point(at)
	controls.setup(sampler, LAYOUT)
	controls.live_fn = _client_bool.bind(&"touch_live")
	controls.crosshair_fn = _crosshair
	controls.targets_fn = _assist_targets
	controls.eye_fn = _eye
	controls.button_pressed.connect(_pressed)
	host.add_child(controls)


## A declared button held by a thumb, or Fire held by auto-fire.
func is_held(id: StringName) -> bool:
	return controls != null and controls.is_held(id)


## True when the overlay is up and forwards [param event] itself, or [param event] is the mouse Godot emulates
## from a touch, which would turn the view a second time.
func takes(event: InputEvent) -> bool:
	if controls == null or not controls.touch:
		return false
	return controls.takes(event) or (event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION)


func active() -> bool:
	return controls != null and controls.touch


## Called every frame by the client: pauses under a menu or the console, and matches auto-fire to the gun in hand.
func sync(busy: bool, gun: DotWeaponDef) -> void:
	if controls == null:
		return
	controls.paused = busy
	controls.autofire.automatic = gun == null or gun.is_continuous()


func describe() -> Dictionary:
	return controls.describe() if controls != null else {"built": false}


func _pressed(id: StringName) -> void:
	if id == &"next":
		_client.call(&"touch_next_weapon")


func _client_bool(method: StringName) -> bool:
	return is_instance_valid(_client) and _client.has_method(method) and bool(_client.call(method))


func _camera() -> Camera3D:
	return _client.get_viewport().get_camera_3d() if is_instance_valid(_client) and _client.is_inside_tree() else null


func _me() -> Node:
	return _client.get(&"player") if is_instance_valid(_client) else null


func _others() -> Array:
	var game: Object = _client.get(&"game") if is_instance_valid(_client) else null
	return game.call(&"players") if game != null else []


func _eye() -> Vector3:
	var cam := _camera()
	return cam.global_position if cam != null else Vector3.ZERO


func _crosshair() -> int:
	var cam := _camera()
	var me := _me()
	if cam == null or me == null:
		return DotMobileAutoFire.TARGET_NONE
	return crosshair_kind(cam.global_position, -cam.global_basis.z, me, _others(), cam.get_world_3d().direct_space_state,
		TagRules.occluder_mask)


func _assist_targets() -> PackedVector3Array:
	var cam := _camera()
	var me := _me()
	if cam == null or me == null:
		return PackedVector3Array()
	return assist_targets(cam.global_position, -cam.global_basis.z, me, _others(), cam.get_world_3d().direct_space_state,
		TagRules.occluder_mask)


## What the crosshair is on: the nearest body the camera's ray passes through (the name tags' own test), ENEMY for a
## living opponent, FRIEND for a team-mate or the dead (never shot), NONE when nothing is or a wall is in front.
## One analytic test a body and at most one physics ray.
static func crosshair_kind(eye: Vector3, forward: Vector3, me: Object, others: Array, space: PhysicsDirectSpaceState3D,
		mask: int) -> int:
	var best: Node3D = null
	var best_t := INF
	var best_aim := Vector3.ZERO
	for p: Node3D in others:
		if p == me or not is_instance_valid(p) or not p.is_inside_tree():
			continue
		var body: Node3D = p.get(&"body_mesh")
		if body != null and not body.is_visible_in_tree():
			continue
		var feet := body.global_position if body != null else p.global_position
		# Behind the eye: skipped before the dynamic height lookup and the ray test.
		var t := forward.dot(feet - eye)
		if t < -1.0 or t >= best_t:
			continue
		var height := _height(p)
		if not TagRules.ray_hits_body(eye, forward, feet, height):
			continue
		best_t = t
		best = p
		best_aim = feet + Vector3(0.0, height * 0.6, 0.0)
	if best == null:
		return DotMobileAutoFire.TARGET_NONE
	if not _is_enemy(best):
		return DotMobileAutoFire.TARGET_FRIEND
	if _blocked(space, mask, eye, best_aim):
		return DotMobileAutoFire.TARGET_NONE
	return DotMobileAutoFire.TARGET_ENEMY


## The chests of living opponents near the crosshair with no wall between, for aim assist.
static func assist_targets(eye: Vector3, forward: Vector3, me: Object, others: Array, space: PhysicsDirectSpaceState3D,
		mask: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	var cos_cone := cos(deg_to_rad(ASSIST_CONE_DEG))
	for p: Node3D in others:
		if p == me or not _shown(p) or not _is_enemy(p):
			continue
		var at := _feet(p) + Vector3(0.0, _height(p) * 0.6, 0.0)
		var to := at - eye
		var dist := to.length()
		if dist < 0.01 or dist > ASSIST_RANGE or forward.dot(to / dist) < cos_cone:
			continue
		if not _blocked(space, mask, eye, at):
			out.append(at)
	return out


static func _shown(p: Node3D) -> bool:
	if not is_instance_valid(p) or not p.is_inside_tree():
		return false
	var body: Node3D = p.get(&"body_mesh")
	return body == null or body.is_visible_in_tree()


static func _feet(p: Node3D) -> Vector3:
	var body: Node3D = p.get(&"body_mesh")
	return body.global_position if body != null else p.global_position


static func _height(p: Node3D) -> float:
	return float(p.call(&"stand_height")) if p.has_method(&"stand_height") else 1.8


static func _is_enemy(p: Node3D) -> bool:
	return bool(p.call(&"is_alive")) and not TagRules.is_teammate(int(p.get(&"player_id")), int(p.get(&"team")))


static func _blocked(space: PhysicsDirectSpaceState3D, mask: int, from: Vector3, to: Vector3) -> bool:
	if space == null or mask == 0:
		return false
	return not space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, mask)).is_empty()
