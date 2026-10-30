extends DotGameCheckSuite
## The first-person arms hold the gun as it is drawn: for every weapon, at the hip, down the sights, looking up and
## down, running into a wall and through every reload frame, each hand reaches its grip point (within REACH_M of the
## arms' own palm offset), that point lands on the drawn grip's pixel, and exactly one set of arms is shown.
##   godot --headless --path . res://examples/headless_viewarms.tscn

const ArenaPresentation := preload("../game/arena_presentation.gd")

## Metres a hand may sit from its target: the IK lands exactly when the target is in reach.
const REACH_M := 0.03
## Pixels the hand target may sit from the drawn grip on screen.
const PIXEL_PX := 2.0
const PHASES := ["hip", "aim", "look down", "look up", "run into the wall", "reload"]

var _client: Node = null
var _entered := 0
var _finished := 0
var _sections := 0
## The eye last frame: a respawn or round reset moves it metres, and the arms follow a frame later.
var _last_eye := Vector3.ZERO


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	var _scratch := ArenaPresentation.use_scratch_settings("headless_viewarms")
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("mouse_capture_override", true)
	add_child(_client)
	_run.call_deferred()


func _run() -> void:
	print("game-arena: the first-person arms hold every weapon where it is drawn")
	if not await _until(func() -> bool: return _client.get("player") != null and _client.get("view_arms") != null, 30.0):
		_check(false, "the offline client arms its player")
		_report_sections(0, 0, 1)
		return
	var me = _client.get("player")
	me.health.invulnerable = true
	var ids: Array = ZeeWeaponPack.table().keys()
	ids.sort()
	_sections = ids.size()
	for id: StringName in ids:
		await _weapon(me, id)
	_report_sections(_entered, _finished, _sections)


func _weapon(me: Node, id: StringName) -> void:
	_entered += 1
	print("")
	print(id)
	var def: DotWeaponDef = ZeeWeaponPack.table()[id]
	var _given = me.arsenal.give(id)
	me.arsenal.equip(def.slot)
	var held := await _until(func() -> bool: return me.arsenal.current() != null and me.arsenal.current().def.id == id and _holding(), 3.0)
	if not _check(held, "%s is in the hands" % id):
		_finished += 1
		return
	await _seconds(1.0)
	var sampler: DotFpsSampler = _client.get("_sampler")
	var yaw: float = sampler.yaw
	var hip_x := 0.0
	for phase: String in PHASES:
		var worst := {"reach": 0.0, "pixel": 0.0, "near": INF, "sets": 1, "n": 0, "wall": 0.0, "sprint": 0.0, "hand": "-", "behind": 0, "need": 0.0, "arm": 0.0}
		match phase:
			"hip":
				await _sample(worst, 0.4)
				hip_x = _holder_x()
			"aim":
				Input.action_press(&"arena_aim")
				await _sample(worst, 0.8)
				_check_centred(id, hip_x)
				Input.action_release(&"arena_aim")
				await _seconds(0.5)
			"look down", "look up":
				sampler.look_at_angles(yaw, -70.0 if phase == "look down" else 70.0)
				await _sample(worst, 0.6)
				sampler.look_at_angles(yaw, 0.0)
				await _seconds(0.4)
			"run into the wall":
				Input.action_press(&"dot_fps_forward")
				Input.action_press(&"dot_fps_sprint")
				await _sample(worst, 3.0)
				Input.action_release(&"dot_fps_forward")
				Input.action_release(&"dot_fps_sprint")
				sampler.look_at_angles(yaw + 180.0, 0.0)
				yaw += 180.0
				await _seconds(0.5)
			"reload":
				if not def.uses_magazine():
					continue
				me.arsenal.current().magazine = 1 if def.magazine > 1 else 0
				Input.action_press(&"arena_reload")
				await _seconds(0.2)
				Input.action_release(&"arena_reload")
				if not _check(me.arsenal.is_reloading(), "%s reloads" % id):
					continue
				while me.arsenal.is_reloading():
					await _sample(worst, 0.0)
		var what := "%s %s: hands %.3f m from their grips, %.1f px off the drawn grip, %d samples" % [id, phase, worst.reach, worst.pixel, worst.n]
		var detail := "worst %s (%.2f m from its shoulder, arm %.2f m), %d hand targets behind the eye, nearest hand %.3f m, arm sets %d, wall %.2f, sprint %.2f" % [worst.hand, worst.need, worst.arm, worst.behind, worst.near, worst.sets, worst.wall, worst.sprint]
		_check(worst.reach <= REACH_M and worst.pixel <= PIXEL_PX and worst.sets == 1 and worst.near > _near(), what, detail)
	_finished += 1


## How far the gun sits right of the eye's centre line, metres.
func _holder_x() -> float:
	var vm: ZeeViewModel = _client.get("view_model")
	var camera: Camera3D = _client.get("player").camera
	return absf((camera.global_transform.affine_inverse() * (vm.get(&"_holder") as Node3D).global_position).x)


## Held aim must bring a weapon that can aim fully up, and its gun nearer the centre than at the hip.
func _check_centred(id: StringName, hip_x: float) -> void:
	var vm: ZeeViewModel = _client.get("view_model")
	if not vm.can_aim():
		return
	var x := _holder_x()
	_check(vm.aim_fraction() >= 0.99 and (x < hip_x - 0.02 or x < 0.03), "%s aim: sights up and gun centred" % id, "fraction %.2f, gun %.3f m off centre, %.3f at the hip" % [vm.aim_fraction(), x, hip_x])


## Every frame for [param seconds] (at least one), each measured while the arms hold the weapon.
func _sample(worst: Dictionary, seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	var first := true
	while first or Time.get_ticks_msec() < until:
		first = false
		# A zero timer fires after the frame's _process, as drawn: at process_frame the player has stepped and the arms have not yet followed.
		await get_tree().process_frame
		await get_tree().create_timer(0.0).timeout
		var vm: ZeeViewModel = _client.get("view_model")
		var arms: Node3D = _client.get("view_arms")
		if vm == null or vm.is_scoped() or not _holding() or not arms.visible:
			continue
		var eye: Vector3 = _client.get("player").camera.global_position
		var jumped := eye.distance_to(_last_eye) > 1.0
		_last_eye = eye
		if jumped:
			continue
		worst.n += 1
		worst.wall = maxf(worst.wall, float(vm.get(&"_wall").get(&"amount")))
		worst.sprint = maxf(worst.sprint, float(vm.get(&"_sprint")))
		var grip: DotViewGrip = arms.get(&"_grip")
		var held: DotPlayerViewArms = arms.get(&"arms")
		var skeleton := (held.arms() as DotHumanoidFigure).skeleton()
		var camera: Camera3D = _client.get("player").camera
		var animated: Node3D = vm.get(&"_animated")
		var pairs := [["Middle1.R", grip.grip_world(), grip.grip, held.palm_offset]]
		if grip.is_two_hand():
			var p: Vector3 = held.palm_offset
			pairs.append(["Middle1.L", grip.support_world(), grip.support, Vector3(-p.x, p.y, p.z)])
		for pair: Array in pairs:
			if -(camera.global_transform.affine_inverse() * (pair[1] as Vector3)).z < _near():
				worst.behind += 1
				continue
			var hand := skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone(pair[0])).origin
			var target: Vector3 = pair[1] + held.global_transform.basis * (pair[3] as Vector3)
			if hand.distance_to(target) > worst.reach:
				worst.reach = hand.distance_to(target)
				worst.hand = pair[0]
				var side := (pair[0] as String).right(1)
				var at := func(bone: String) -> Vector3: return skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone(bone + side)).origin
				var shoulder: Vector3 = at.call("UpperArm.")
				worst.need = shoulder.distance_to(target)
				worst.arm = shoulder.distance_to(at.call("LowerArm.")) + (at.call("LowerArm.") as Vector3).distance_to(hand)
			var drawn: Vector3 = animated.global_transform * (pair[2] as Vector3)
			worst.pixel = maxf(worst.pixel, camera.unproject_position(pair[1]).distance_to(camera.unproject_position(drawn)))
			worst.near = minf(worst.near, -(camera.global_transform.affine_inverse() * hand).z)
		var sets := _arm_sets(camera)
		if sets != 1:
			worst.sets = sets


## Visible arm sets near the eye: zee's own, dot-player-char's view arms, a first-person figure.
func _arm_sets(camera: Camera3D) -> int:
	var found: Array = []
	for node in _client.find_children("*", "Node3D", true, false):
		var script: Script = node.get_script()
		var named := str(script.get_global_name()) if script != null else ""
		if named in ["ZeeViewArms", "DotPlayerViewArms"] and (node as Node3D).is_visible_in_tree() and (node as Node3D).global_position.distance_to(camera.global_position) < 2.0:
			found.append(node)
	return found.size()


func _holding() -> bool:
	var arms: Node3D = _client.get("view_arms")
	return arms != null and bool(arms.call(&"holding"))


func _near() -> float:
	return (_client.get("player").camera as Camera3D).near


func _frames(n: int) -> void:
	for _i in n:
		await get_tree().process_frame


func _seconds(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return bool(condition.call())
