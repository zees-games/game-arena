extends Node3D

## Your own arms on dot-player-char's DotPlayerViewArms, holding the weapon where ZeeViewModel
## measured its grip. Absent below API 8: the view model draws its own hands then.

const NEEDS_LEVEL := 8
## Poses held with the firing hand alone.
const ONE_HAND: Array[StringName] = [&"melee", &"thrown", &"fists"]

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


## Follows the camera by yaw only (under the pitch the arms would swing with the look); hidden with the view model or a scope.
func _process(delta: float) -> void:
	var camera: Camera3D = body.camera if body != null else null
	if camera == null or arms == null:
		return
	var model: ZeeViewModel = body.weapons.view_model() if body.weapons != null else null
	global_position = camera.global_position
	global_rotation = Vector3(0.0, camera.global_rotation.y, 0.0)
	visible = model != null and model.visible and not model.is_scoped() and body.is_alive()
	var v: Vector3 = body.controller.state.velocity
	arms.tick(Vector2(v.x, v.z).length(), delta)


func holding() -> bool:
	return arms != null and arms.shown and _grip != null and _grip.is_valid()
