extends Node3D

## Your own arms on dot-player-char's DotPlayerViewArms, holding the weapon where AwViewModel
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
## cl_fp_scope_arms_hide: aim fraction the scoped arms hide at, for every weapon (-1: each weapon's own).
static var scope_arms_hide_override := -1.0
## cl_fp_max_lean: cap on how far the arms lean to a hand target, for every weapon (-1: each weapon's own).
static var max_lean_override := -1.0

var arms: DotPlayerViewArms = null
var body: Node3D = null
var _grip: DotViewGrip = null
var _own_lean := 0.4
## The game whose `fp_arms` rule (arena_fp_arms) may put one arm set on everybody; null keeps the player's own.
var rules: Object = null
var _arm_set: Array = []
var _boxes: Dictionary = {}


static func available() -> bool:
	return DotAddonApi.build_level("dot_player_char") >= NEEDS_LEVEL


## Puts a view model's hands on [param body]'s camera: AwViewModel's own when there is no API, else these arms under [param parent].
static func mount(parent: Node, model: AwViewModel, body: Node3D, look: DotHumanoidLook, p_rules: Object = null) -> Node3D:
	if not available() or not model.has_signal(&"hands_reached"):
		return null
	model.show_arms = false
	var mounted := new()
	mounted.name = "ViewArms"
	mounted.body = body
	mounted.rules = p_rules
	parent.add_child(mounted)
	mounted.arms = DotPlayerViewArms.new()
	mounted.arms.name = "ViewArms"
	mounted.add_child(mounted.arms)
	mounted.arms.build(look, 1.8)
	mounted._own_lean = mounted.arms.max_lean
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
	var model: AwViewModel = body.weapons.view_model() if body != null and body.weapons != null else null
	_grip.bounds = weapon_bounds(model, _boxes)


## The drawn weapon's box in the frame [signal AwViewModel.hands_reached] gives its points in, which the arms keep
## their elbows out of. That frame is often a bare marker (HandsFrame) with no mesh for dot-player-char to measure,
## but its points are the animated node's, so the weapon is measured there. [param boxes] keeps each weapon's own box.
static func weapon_bounds(model: AwViewModel, boxes: Dictionary) -> AABB:
	var weapon: Node3D = model.weapon_node() if model != null else null
	if weapon == null or not weapon.is_inside_tree():
		return AABB()
	var animated: Node3D = weapon
	while animated.get_parent() != model and animated.get_parent() is Node3D:
		animated = animated.get_parent() as Node3D
	if animated.get_parent() != model:
		return AABB()
	var key := weapon.get_instance_id()
	if not boxes.has(key):
		if boxes.size() > 32:
			boxes.clear()
		boxes[key] = DotViewGrip.one_hand(weapon, Vector3.ZERO).bounds_local()
	var box: AABB = boxes[key]
	if not box.has_volume():
		return AABB()
	return (animated.global_transform.affine_inverse() * weapon.global_transform) * box


## The look the server's `fp_arms` rule draws on every player's arms (a stock set, seeded by its value); null for
## each player's own. [param memo] keeps it one object, since the rig rebuilds whenever the drawn look is a new one.
static func arm_set_look(p_rules: Object, memo: Array) -> DotHumanoidLook:
	var set_id := int(p_rules.call(&"rule", "fp_arms")) if p_rules != null and p_rules.has_method(&"rule") else 0
	if set_id <= 0:
		return null
	if memo.size() != 2 or int(memo[0]) != set_id:
		memo.assign([set_id, DotHumanoidLook.stock(set_id)])
	return memo[1] as DotHumanoidLook


## Holding, follows the whole look like the drawn weapon, so pitch never takes the grip out of reach; empty-handed
## (a downed crawl), by yaw only. Hidden with the view model or a scope.
func _process(delta: float) -> void:
	var camera: Camera3D = body.camera if body != null else null
	if camera == null or arms == null:
		return
	var model: AwViewModel = body.weapons.view_model() if body.weapons != null else null
	global_position = camera.global_position
	global_rotation = Vector3(camera.global_rotation.x if holding() else 0.0, camera.global_rotation.y, 0.0)
	visible = model != null and model.visible and not model.arms_hidden_by_scope() and body.is_alive()
	if model != null and model.has_method(&"art_hand_scale"):
		var own: float = model.call(&"art_hand_scale")
		arms.hand_scale = (own if own > 0.0 else DEFAULT_HAND_SCALE) * hand_scale_mult
	if model != null and model.has_method(&"art_forearm_scale"):
		var fore: float = model.call(&"art_forearm_scale")
		arms.forearm_scale = (fore if fore > 0.0 else 1.0) * forearm_scale_mult
	if model != null:
		model.scope_arms_hide_override = scope_arms_hide_override
		var lean: float = model.call(&"art_max_lean") if model.has_method(&"art_max_lean") else -1.0
		arms.max_lean = max_lean_override if max_lean_override >= 0.0 else (lean if lean >= 0.0 else _own_lean)
	if arms.has_method(&"set_look_override"):
		arms.set_look_override(arm_set_look(rules, _arm_set))
	if &"debug_pose" in arms and arms.debug_pose != debug_pose:
		arms.debug_pose = debug_pose
	var v: Vector3 = body.controller.state.velocity
	arms.tick(Vector2(v.x, v.z).length(), delta)


func holding() -> bool:
	return arms != null and arms.shown and _grip != null and _grip.is_valid()
