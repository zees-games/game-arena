extends Node3D

## Your own arms on dot-player-char's DotPlayerViewArms, holding the weapon where ZeeViewModel
## measured its grip. Absent below API 8: the view model draws its own hands then.

const NEEDS_LEVEL := 8
## Poses held with the firing hand alone.
const ONE_HAND: Array[StringName] = [&"melee", &"thrown", &"fists"]
## Nearest a held grip comes to the eye (metres), so a pistol's hand does not fill the view.
const HANDS_MIN_DISTANCE := 0.3
## DotPlayerViewArms' own hand size, for a weapon whose profile does not say.
const DEFAULT_HAND_SCALE := 0.5

## cl_pose_debug: draws the grip sockets, hand targets and arm bones over the view.
static var debug_pose := false
## cl_fp_hand_scale: multiplies the held-hand size of every weapon (1 leaves the profile's).
static var hand_scale_mult := 1.0
## cl_fp_forearm_scale: multiplies the held-forearm size of every weapon.
static var forearm_scale_mult := 1.0

var arms: DotPlayerViewArms = null
var body: Node3D = null
var _grip: DotViewGrip = null


static func available() -> bool:
	return DotAddonApi.build_level("dot_player_char") >= NEEDS_LEVEL


## Puts a view model's hands on [param body]'s camera: ZeeViewModel's own when there is no API, else these arms under [param parent].
static func mount(parent: Node, model: ZeeViewModel, body: Node3D, look: DotHumanoidLook) -> Node3D:
	if not available() or not model.has_signal(&"hands_reached"):
		return null
	model.show_arms = false
	var mounted := new()
	mounted.name = "ViewArms"
	mounted.body = body
	parent.add_child(mounted)
	mounted.arms = DotPlayerViewArms.new()
	mounted.arms.name = "ViewArms"
	mounted.add_child(mounted.arms)
	mounted.arms.build(look, 1.8)
	if &"hands_scale" in model:
		model.hands_scale = mounted.arms.held_scale
		model.hands_min_distance = HANDS_MIN_DISTANCE
	model.hands_reached.connect(mounted._on_hands)
	return mounted


func _on_hands(anchor: Node3D, grip: Vector3, fore: Vector3, pose: StringName) -> void:
	var one := pose in ONE_HAND
	if _grip == null or _grip.anchor != anchor or _grip.is_two_hand() == one:
		_grip = DotViewGrip.one_hand(anchor, grip) if one else DotViewGrip.two_hand(anchor, grip, fore)
		arms.set_held(_grip)
	_grip.grip = grip
	if not one:
		_grip.support = fore


## Holding, follows the whole look like the drawn weapon, so pitch never takes the grip out of reach; empty-handed
## (a downed crawl), by yaw only. Hidden with the view model or a scope.
func _process(delta: float) -> void:
	var camera: Camera3D = body.camera if body != null else null
	if camera == null or arms == null:
		return
	var model: ZeeViewModel = body.weapons.view_model() if body.weapons != null else null
	global_position = camera.global_position
	global_rotation = Vector3(camera.global_rotation.x if holding() else 0.0, camera.global_rotation.y, 0.0)
	visible = model != null and model.visible and not model.is_scoped() and body.is_alive()
	if model != null and model.has_method(&"art_hand_scale"):
		var own: float = model.call(&"art_hand_scale")
		arms.hand_scale = (own if own > 0.0 else DEFAULT_HAND_SCALE) * hand_scale_mult
	if model != null and model.has_method(&"art_forearm_scale"):
		var fore: float = model.call(&"art_forearm_scale")
		arms.forearm_scale = (fore if fore > 0.0 else 1.0) * forearm_scale_mult
	if &"debug_pose" in arms and arms.debug_pose != debug_pose:
		arms.debug_pose = debug_pose
	var v: Vector3 = body.controller.state.velocity
	arms.tick(Vector2(v.x, v.z).length(), delta)


func holding() -> bool:
	return arms != null and arms.shown and _grip != null and _grip.is_valid()
