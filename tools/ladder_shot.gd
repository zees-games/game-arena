extends SceneTree

const ArenaAvatars := preload("../game/arena_avatars.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMapLighting := preload("../maps/arena_map_lighting.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

## Drives a player up one of a converted map's ladders, over the lip and back down, and saves a
## frame every EVERY ticks from the side (tp_NN) and from the player's eyes (fp_NN).
## xvfb-run -a godot --path . --resolution 1280x720 --script res://tools/ladder_shot.gd -- <map id> <ladder index>

const TICK_RATE := 64
const EVERY := 20
const OUT := "screenshots/ladder"

var _player: ArenaPlayer
var _cam: Camera3D
var _fp: Camera3D
var _rung := AABB()
var _away := Vector3.ZERO
var _yaw := 0.0
var _phase := 0
var _last_shot := 0
var _fp_next := false
var _tick := 0
var _hold := 0
var _frame := 0
var _was_on := false
var _armed := false
var _start := Vector3.ZERO
var _tag := ""


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var map := ArenaMap.by_id(StringName(args[0]))
	_tag = "%s_%s" % [args[0], args[1]]
	Engine.physics_ticks_per_second = TICK_RATE
	root.add_child(map.to_scene())
	root.add_child(ArenaMapLighting.build(map))
	DirAccess.make_dir_recursive_absolute(OUT)
	var tall: Array[AABB] = []
	for rung in map.mechanics.ladders:
		if rung.size.y >= 1.5:
			tall.append(rung)
	_rung = tall[int(args[1])]
	_player = ArenaPlayer.new()
	_player.setup(ArenaPlayer.Mode.HEADLESS, map, 7, "You")
	root.add_child(_player)
	_player.spawn(Transform3D(Basis(), Vector3.ZERO), 0)
	_player.attach_camera(100.0)
	_player.attach_body_mesh(Color(0.3, 0.5, 0.85), ArenaAvatars.stock_avatar(&"arena-player-00000007"))
	_fp = _player.camera
	_cam = Camera3D.new()
	_cam.fov = 70.0
	root.add_child(_cam)
	_cam.current = true
	_pick_side(map)


func _pick_side(map: ArenaMap) -> void:
	var body := DotFpsPhysicsBody.for_node(map.collision_root)
	var tun: DotFpsTunables = _player.controller.tunables
	var thin_x := _rung.size.x < _rung.size.z

	for side: float in [1.0, -1.0]:
		var away := Vector3(side, 0.0, 0.0) if thin_x else Vector3(0.0, 0.0, side)
		var face := _rung.get_center() + away * ((_rung.size.x if thin_x else _rung.size.z) * 0.5)
		var at := Vector3(face.x, _rung.position.y + 0.1, face.z) + away * (tun.radius + 0.05)
		var height := tun.stand_height - 0.2

		if not body.overlaps(at + Vector3.UP * (0.1 + height * 0.5), height, tun.radius - 0.05):
			_away = away
			_start = at
			_yaw = rad_to_deg(atan2(away.x, away.z))
			return


func _physics_process(_delta: float) -> bool:
	if not _armed:
		_armed = true
		_player.controller.teleport(_start, _yaw, 0.0)

	var cmd := DotFpsCommand.new()
	cmd.move = Vector2(0.0, 1.0)
	cmd.yaw = _yaw if _phase < 2 else _yaw + 180.0
	cmd.pitch = 40.0 if _phase < 2 else -50.0
	var s: DotFpsState = _player.controller.state
	var on: bool = s.mode == _player.ladder.mode_id
	_was_on = _was_on or on

	if _phase == 0 and _was_on and not on:
		_phase = 1
		_hold = TICK_RATE / 8
	elif _phase == 1:
		_hold -= 1
		if _hold <= 0:
			_phase = 2
			_was_on = false
			_hold = 0
	elif _phase == 2 and _was_on and s.is_grounded() and s.position.y <= _rung.position.y + 0.6:
		_phase = 3
		_hold = 40

	if _phase == 3:
		cmd.move = Vector2.ZERO
		_hold -= 1
		if _hold <= 0:
			quit(0)

	var weapon := DotWeaponCommand.new()
	weapon.yaw = cmd.yaw
	weapon.pitch = cmd.pitch
	var _out := _player.simulate_tick(_tick, 1.0 / float(TICK_RATE), cmd, weapon)
	_tick += 1

	if _tick > TICK_RATE * 30:
		quit(1)

	return false


func _process(delta: float) -> bool:
	_player.present(delta)
	var feet := _player.controller.state.position
	var perp := Vector3(-_away.z, 0.0, _away.x)
	_cam.global_position = feet + _away * 3.4 + perp * 2.2 + Vector3.UP * 1.4
	_cam.look_at(feet + Vector3.UP * 0.8)

	if _fp_next:
		_fp_next = false
		_save("fp", _fp)
		_fp.current = false
		_cam.current = true
	elif _tick - _last_shot >= EVERY:
		_last_shot = _tick
		_frame += 1
		_save("tp", _cam)
		_cam.current = false
		_fp.current = true
		_fp_next = true

	return false


func _save(view: String, _from: Camera3D) -> void:
	var image := root.get_texture().get_image()
	var name := "%s_%s_%03d.png" % [_tag, view, _frame]
	image.save_png(OUT.path_join(name))
	print("%s phase %d y %.2f mode %d" % [name, _phase, _player.controller.state.position.y, _player.controller.state.mode])
