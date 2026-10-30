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
var _before := Vector3.INF
var _flinch := DotFpsAimBreak.new()
var _wobble := Vector2.ZERO
var _dead := false
var _metrics := DotClipMetrics.new()
var _spawn_yaw := 0.0
var _hands: Node3D = null
var _armed := false
var _query := PhysicsRayQueryParameters3D.new()
## A clip's `own_body` (DotPlayerViewRules.BODY_*): the first-person view draws your own body, placed by the game.
var _own_body := 0


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
	_spawn_yaw = float(_clip.fields.get("spawn_yaw", 0.0))
	_own_body = int(_clip.fields.get("own_body", 0))

	# Two cameras sharing the one world, side by side; the player's own camera is not drawn.
	_tp_cam = _view(1)
	for body in _player.find_children("*", "CollisionObject3D", true, false):
		_query.exclude.append((body as CollisionObject3D).get_rid())
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
		# A clip's "weapon" field holds that weapon (any id of the pack) instead of the default primary.
		var weapon_id := StringName(String(_clip.fields.get("weapon", "")))
		if weapon_id != &"":
			var given := _player.arsenal.give(weapon_id)
			if given.ok:
				var _held := _player.arsenal.equip(int((given.value as DotWeaponSlot).def.slot))
		# Placed once the tree is live: a teleport inside _initialize was lost and every clip began at the origin.
		var spawn: Array = _clip.fields.get("spawn", [15.0, 0.05, -13.0])
		_player.controller.teleport(Vector3(spawn[0], spawn[1], spawn[2]), _spawn_yaw, 0.0)
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
	_before = _player.controller.state.position
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
		return true
	var shake := _flinch.shake(maxf(time, 0.0))
	_player.camera_offset = Vector3(0.0, shake.y, shake.z)
	_player.camera_roll = deg_to_rad(shake.x)
	_wobble = _flinch.wobble(maxf(time, 0.0))
	_player.present(delta)
	# The game places and turns your own body between ticks only in its view paths, which this camera skips.
	var alpha := clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0)
	var feet := _player.controller.state.position
	if _before.is_finite():
		feet = _before.lerp(feet, alpha)
	time -= (1.0 - alpha) / float(TICK_RATE)
	if _own_body > 0 and _player.figure != null:
		_player.own_body_mode = _own_body
		_player.figure.first_person = DotHumanoidOwnView.BODY if _own_body >= 2 else DotHumanoidOwnView.LEGS
		_player.body_mesh.visible = true
	elif _player.body_mesh != null:
		_player.body_mesh.global_position = feet
		_player.body_mesh.global_rotation = Vector3(0.0, deg_to_rad(_player.controller.state.yaw), 0.0)
	_fp_cam.global_transform = _player.camera.global_transform
	_fp_cam.fov = _player.camera.fov
	_fp_cam.cull_mask = 0xFFFFF if _own_body > 0 else 0xFFFFF & ~BODY_LAYER
	_tp_cam.cull_mask = 0xFFFFF & ~VIEW_LAYER
	_tag_body(_player)
	var yaw := deg_to_rad(_spawn_yaw + float(_clip.state_at(maxf(time, 0.0))["yaw"]))
	var behind := Basis(Vector3.UP, yaw) * Vector3(1.1, 1.7, 2.8)
	_tp_cam.global_position = feet + behind
	_tp_cam.look_at(feet + Vector3(0.0, 0.9, 0.0))
	if time >= 0.0:
		_sample(time, feet)
	return false


func _sample(time: float, feet: Vector3) -> void:
	var sample := _metrics.pose_sample(time, _player.figure.skeleton() if _player.figure != null else null, feet, _player.controller.state.is_grounded())
	sample["points"] = [_unit(_tp_cam, feet), _unit(_tp_cam, feet + Vector3(0.0, 1.7, 0.0))]
	_query.to = feet + Vector3(0.0, 1.0, 0.0)
	_query.from = _tp_cam.global_position
	sample["blocked"] = not _tp_cam.get_world_3d().direct_space_state.intersect_ray(_query).is_empty()
	_metrics.add(sample)


func _unit(cam: Camera3D, spot: Vector3) -> Vector2:
	if cam.is_position_behind(spot):
		return Vector2(-1.0, -1.0)
	return cam.unproject_position(spot) / Vector2(VIEW)


## Runs once at shutdown, after `_process` has returned true, so none of it is per-frame.
func _finalize() -> void:
	var text := DotClipMetrics.table(_clip.name, _metrics.evaluate(DotClipMetrics.limits_for("res://tools/filmstrip_thresholds.json", _clip.name)))
	print(text)
	DotClipMetrics.write_report("res://screenshots/filmstrip/%s_report.txt" % _clip.name, text)


func _tag_body(node: Node) -> void:
	if node == _player.camera:
		return
	if node is VisualInstance3D:
		(node as VisualInstance3D).layers = BODY_LAYER
	for child in node.get_children():
		_tag_body(child)
