extends SceneTree

const ArenaAvatars := preload("../game/arena_avatars.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMapLighting := preload("../maps/arena_map_lighting.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

## Plays one scripted clip (a DotScenario from tools/filmstrip_scenarios.json) and draws a
## first-person view on the left and a third-person view on the right of one window, for
## `--write-movie` to record. Run by tools/filmstrip_run.sh:
## `godot --write-movie out.avi --fixed-fps 15 --script res://tools/filmstrip_capture.gd -- <clip>`.

const TICK_RATE := 64
const SETTLE_TICKS := 40
const VIEW := Vector2i(640, 480)
const MOVE_BUTTONS := {"jump": DotFpsCommand.BUTTON_JUMP, "crouch": DotFpsCommand.BUTTON_CROUCH,
	"sprint": DotFpsCommand.BUTTON_SPRINT, "walk": DotFpsCommand.BUTTON_WALK}
const WEAPON_BUTTONS := {"attack": DotWeaponCommand.BUTTON_ATTACK, "alt": DotWeaponCommand.BUTTON_ALT,
	"reload": DotWeaponCommand.BUTTON_RELOAD, "aim": DotWeaponCommand.BUTTON_AIM}

var _clip: DotScenario = null
var _player: ArenaPlayer = null
## The own body is on its own layer so the first-person view leaves it out while the
## third-person view, sharing the world, still draws it.
const BODY_LAYER := 1 << 18
const VIEW_LAYER := 1 << 19
var _fp_cam: Camera3D = null
var _tp_cam: Camera3D = null
var _tick := 0
var _prev_time := 0.0
var _flinch := DotFpsAimBreak.new()
var _wobble := Vector2.ZERO
var _dead := false
var _metrics := DotClipMetrics.new()
var _bones: Skeleton3D = null
var _feet: Array[int] = []
var _sole := NAN
var _spawn_yaw := 0.0
var _log: Array[String] = []
var _prev_feet: Array = []
var _hands: Node3D = null
var _armed := false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var clips := DotScenario.load_file("res://tools/filmstrip_scenarios.json")
	if args.is_empty() or not clips.has(args[0]):
		printerr("filmstrip: clip %s not in %s" % [str(args), str(clips.keys())])
		quit(2)
		return
	_clip = clips[args[0]]
	Engine.physics_ticks_per_second = TICK_RATE
	var map := ArenaMap.dm_box()
	root.add_child(map.to_scene())
	root.add_child(ArenaMapLighting.build(map))

	_player = ArenaPlayer.new()
	_player.name = "You"
	_player.setup(ArenaPlayer.Mode.HEADLESS, map, 7, "You")
	root.add_child(_player)
	_player.spawn(Transform3D(Basis(), Vector3.ZERO), 0)
	_player.attach_camera(100.0)
	_player.attach_body_mesh(Color(0.3, 0.5, 0.85), ArenaAvatars.stock_avatar(&"arena-player-00000007"))
	var hands := ZeeViewModel.new()
	hands.name = "Hands"
	# The rig finds the hands by path, so they hang under the drawn camera before it is armed.
	_fp_cam = _view(0)
	_fp_cam.add_child(hands)
	_hands = hands
	var spawn: Array = _clip.fields.get("spawn", [15.0, 0.05, -13.0])
	_spawn_yaw = float(_clip.fields.get("spawn_yaw", 0.0))
	_player.controller.teleport(Vector3(spawn[0], spawn[1], spawn[2]), float(_clip.fields.get("spawn_yaw", 0.0)), 0.0)

	# Two cameras sharing the one world, side by side; the player's own camera is not drawn.
	_tp_cam = _view(1)
	_player.camera.current = false


func _view(slot: int) -> Camera3D:
	var holder := SubViewportContainer.new()
	holder.position = Vector2(VIEW.x * slot, 0)
	holder.size = Vector2(VIEW)
	var port := SubViewport.new()
	port.size = VIEW
	port.world_3d = root.world_3d
	var cam := Camera3D.new()
	cam.current = true
	port.add_child(cam)
	holder.add_child(port)
	var layer := CanvasLayer.new()
	layer.add_child(holder)
	root.add_child(layer)
	return cam


func _clip_time() -> float:
	return float(_tick - SETTLE_TICKS) / float(TICK_RATE)


func _physics_process(_delta: float) -> bool:
	if not _armed:
		# The tree is not live inside _initialize, and the rig finds the hands by their path.
		_armed = true
		_player.arm_first_person(_hands, true)
		_player.give_default_loadout()
	var time := _clip_time()
	var state := _clip.state_at(maxf(time, 0.0))
	var move: Array = state["move"]
	var move_cmd := DotFpsCommand.new()
	move_cmd.move = Vector2(float(move[0]), float(move[1]))
	move_cmd.yaw = _spawn_yaw + float(state["yaw"]) + _wobble.x
	move_cmd.pitch = float(state["pitch"]) + _wobble.y
	var weapon_cmd := DotWeaponCommand.new()
	if time >= 0.0:
		for button: String in state["buttons"]:
			move_cmd.buttons |= int(MOVE_BUTTONS.get(button, 0))
			weapon_cmd.buttons |= int(WEAPON_BUTTONS.get(button, 0))
	weapon_cmd.yaw = move_cmd.yaw
	weapon_cmd.pitch = move_cmd.pitch
	var _out := _player.simulate_tick(_tick, 1.0 / float(TICK_RATE), move_cmd, weapon_cmd)
	if time >= 0.0:
		for step: Dictionary in _clip.events_between(maxf(_prev_time, -0.001), time):
			_event(String(step["event"]), time)
	_prev_time = time
	_tick += 1
	return false


func _event(event: String, time: float) -> void:
	match event:
		"hit":
			_flinch.note_hit(time, _player.controller.tunables, 25.0)
			_hit(25.0)
		"die":
			_hit(_player.health.health + _player.health.armour + 50.0)
			_player.make_dead()
			_dead = true


func _hit(amount: float) -> void:
	_player.health.invulnerable = false
	_player.health.invulnerable_until_tick = -1
	_player.health.apply(DotDamage.make(0, _player.player_id, amount, DotDamageType.new()))


func _process(delta: float) -> bool:
	var time := _clip_time()
	if time >= _clip.duration:
		_report()
		return true
	var shake := _flinch.shake(maxf(time, 0.0))
	_player.camera_offset = Vector3(0.0, shake.y, shake.z)
	_player.camera_roll = deg_to_rad(shake.x)
	_wobble = _flinch.wobble(maxf(time, 0.0))
	_player.present(delta)
	_fp_cam.global_transform = _player.camera.global_transform
	_fp_cam.fov = _player.camera.fov
	_fp_cam.cull_mask = 0xFFFFF & ~BODY_LAYER
	_tp_cam.cull_mask = 0xFFFFF & ~VIEW_LAYER
	_tag_body(_player)
	var feet := _player.controller.state.position
	var yaw := deg_to_rad(_spawn_yaw + float(_clip.state_at(maxf(time, 0.0))["yaw"]))
	var behind := Basis(Vector3.UP, yaw) * Vector3(1.1, 1.7, 2.8)
	_tp_cam.global_position = feet + behind
	_tp_cam.look_at(feet + Vector3(0.0, 0.9, 0.0))
	if time >= 0.0:
		_sample(time, feet)
	return false


func _sample(time: float, feet: Vector3) -> void:
	if _bones == null and _player.figure != null:
		_bones = _player.figure.find_children("*", "Skeleton3D", true, false).front() as Skeleton3D
		for i in _bones.get_bone_count():
			var bone := _bones.get_bone_name(i).to_lower()
			if bone.contains("foot") and not bone.contains("toe"):
				_feet.append(i)
	var sample := {"t": time, "root": feet, "ground_y": feet.y, "grounded": _player.controller.state.is_grounded()}
	if _bones != null:
		var ankles: Array = _feet.map(func(i: int) -> Vector3: return _bones.global_transform * _bones.get_bone_global_pose(i).origin)
		if is_nan(_sole):
			_sole = ankles.map(func(a: Vector3) -> float: return a.y - feet.y).min()
		sample["feet"] = ankles.map(func(a: Vector3) -> Vector3: return a - Vector3(0.0, _sole, 0.0))
		var row := "%.2f pos=(%.1f,%.1f) root_v=%.2f" % [time, feet.x, feet.z, _player.controller.state.velocity.length()]
		for k in ankles.size():
			var a: Vector3 = sample["feet"][k]
			var v := 0.0
			if _prev_feet.size() == ankles.size():
				v = Vector2(a.x - _prev_feet[k].x, a.z - _prev_feet[k].z).length() * 15.0
			row += "  %s h=%.3f v=%.2f" % [_bones.get_bone_name(_feet[k]), a.y - feet.y, v]
			_log.append(row)
		_prev_feet = sample["feet"].duplicate()
		var rotations: Array = []
		for i in _bones.get_bone_count():
			rotations.append(_bones.get_bone_pose_rotation(i))
		sample["rotations"] = rotations
	var points: Array[Vector2] = []
	for spot in [feet, feet + Vector3(0.0, 1.7, 0.0)]:
		points.append(_unit(_tp_cam, spot))
	sample["points"] = points
	var query := PhysicsRayQueryParameters3D.create(_tp_cam.global_position, feet + Vector3(0.0, 1.0, 0.0))
	for body in _player.find_children("*", "CollisionObject3D", true, false):
		query.exclude.append((body as CollisionObject3D).get_rid())
	sample["blocked"] = not _tp_cam.get_world_3d().direct_space_state.intersect_ray(query).is_empty()
	_metrics.add(sample)


func _unit(cam: Camera3D, spot: Vector3) -> Vector2:
	if cam.is_position_behind(spot):
		return Vector2(-1.0, -1.0)
	return cam.unproject_position(spot) / Vector2(VIEW)


func _report() -> void:
	var limits: Dictionary = {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://tools/filmstrip_thresholds.json"))
	if parsed is Dictionary:
		limits = parsed.get("defaults", {}).duplicate()
		limits.merge(parsed.get("clips", {}).get(_clip.name, {}), true)
	var text := DotClipMetrics.table(_clip.name, _metrics.evaluate(limits))
	print(text)
	DirAccess.make_dir_recursive_absolute("res://screenshots/filmstrip")
	var file := FileAccess.open("res://screenshots/filmstrip/%s_report.txt" % _clip.name, FileAccess.WRITE)
	file.store_string(text + "\n" + "\n".join(_log) + "\n")


func _tag_body(node: Node) -> void:
	if node == _player.camera:
		return
	if node is VisualInstance3D:
		(node as VisualInstance3D).layers = BODY_LAYER
	for child in node.get_children():
		_tag_body(child)
