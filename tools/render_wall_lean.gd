extends SceneTree

const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMapLighting := preload("../maps/arena_map_lighting.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

## The view model against a wall, to look at: dm_box's south wall at three distances (deep, middle, a graze) from five
## views (level, looking down, looking up, turned to each side). Writes `screenshots/wall_lean/<distance>_<view>.png`.
## Usage: `tools/render_wall_lean.sh [weapon-slot-less]`; needs xvfb-run (headless frames are empty).

const OUT_DIR := "screenshots/wall_lean"
const TICK_RATE := 64
const WALL_Z := 24.0

var _player: ArenaPlayer = null
var _cases: Array = []
var _case: Dictionary = {}
var _settle := 0
var _armed := false
var _tick := 1
var _look := Vector2(180.0, 0.0)


func _initialize() -> void:
	Engine.physics_ticks_per_second = TICK_RATE
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var map := ArenaMap.dm_box()
	root.add_child(map.to_scene())
	root.add_child(ArenaMapLighting.build(map))
	_player = ArenaPlayer.new()
	_player.name = "You"
	_player.setup(ArenaPlayer.Mode.HEADLESS, map, 7, "You")
	root.add_child(_player)
	_player.spawn(Transform3D(Basis(), Vector3(0.0, 0.05, 20.0)), 0)
	_player.attach_camera(100.0)
	_player.camera.current = true
	var views := {"level": Vector2(180.0, 0.0), "down": Vector2(180.0, -25.0), "up": Vector2(180.0, 25.0),
		"left": Vector2(145.0, 0.0), "right": Vector2(215.0, 0.0)}
	var dists: Array = [0.9, 0.6, 0.4]
	if not OS.get_cmdline_user_args().is_empty():
		dists = Array(OS.get_cmdline_user_args()).map(func(a: String) -> float: return a.to_float())
	for dist: float in dists:
		for view: String in views:
			_cases.append({"name": "d%.1f_%s" % [dist, view], "dist": dist, "view": views[view]})


func _physics_process(_delta: float) -> bool:
	if not _armed:
		_armed = true
		var hands := ZeeViewModel.new()
		hands.name = "Hands"
		_player.camera.add_child(hands)
		_player.arm_first_person(hands, true)
		_player.give_default_loadout()
		return false
	if _case.is_empty() and not _cases.is_empty():
		_case = _cases.pop_front()
		var v: Vector2 = _case["view"]
		# Stand so the view axis is 'dist' from the wall plane, whatever the yaw.
		var eye_z: float = WALL_Z - float(_case["dist"])
		_look = v
		_player.controller.teleport(Vector3(0.0, 0.05, eye_z), v.x, v.y)
		_settle = 30
	var cmd := DotFpsCommand.new()
	cmd.yaw = _look.x
	cmd.pitch = _look.y
	var _a := _player.simulate_tick(_tick, 1.0 / float(TICK_RATE), cmd, DotWeaponCommand.new())
	_tick += 1
	return false


func _process(delta: float) -> bool:
	if _case.is_empty():
		return _cases.is_empty() and _armed and _tick > 3
	_player.view_now = null
	_player.present(delta)
	if _settle > 0:
		_settle -= 1
		return false
	root.get_texture().get_image().save_png(OUT_DIR.path_join("%s.png" % _case["name"]))
	print("wrote ", _case["name"])
	_case = {}
	return false
