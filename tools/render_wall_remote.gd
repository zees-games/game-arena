extends SceneTree

const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMapLighting := preload("../maps/arena_map_lighting.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

## A third-person remote body (the world model in its hand) against dm_box's south wall at three distances, seen from
## the side and from behind. Writes `screenshots/wall_remote/<distance>_<side|back>.png`. Needs xvfb-run.
## Usage: `xvfb-run -a godot --path . --resolution 640x360 --script res://tools/render_wall_remote.gd`

const OUT_DIR := "screenshots/wall_remote"
const WALL_Z := 24.0

var _player: ArenaPlayer = null
var _cam: Camera3D = null
var _cases: Array = []
var _case: Dictionary = {}
var _settle := 0
var _armed := 0
var _tick := 1


func _initialize() -> void:
	Engine.physics_ticks_per_second = 64
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var map := ArenaMap.dm_box()
	root.add_child(map.to_scene())
	root.add_child(ArenaMapLighting.build(map))
	_player = ArenaPlayer.new()
	_player.name = "Them"
	_player.setup(ArenaPlayer.Mode.HEADLESS, map, 8, "Them")
	root.add_child(_player)
	_player.spawn(Transform3D(Basis(), Vector3(0.0, 0.05, 20.0)), 0)
	_player.attach_body_mesh(Color(0.8, 0.3, 0.2))
	_player.give_default_loadout()
	_cam = Camera3D.new()
	_cam.fov = 60.0
	root.add_child(_cam)
	_cam.current = true
	for dist: float in [0.9, 0.5, 0.3]:
		_cases.append({"name": "d%.1f_side" % dist, "dist": dist, "cam": Vector3(2.2, 1.4, 1.0)})
		_cases.append({"name": "d%.1f_back" % dist, "dist": dist, "cam": Vector3(0.6, 1.9, -2.2)})


func _physics_process(_delta: float) -> bool:
	if _case.is_empty() and not _cases.is_empty():
		_case = _cases.pop_front()
		var z: float = WALL_Z - float(_case["dist"])
		_player.controller.teleport(Vector3(0.0, 0.05, z), 180.0, 0.0)
		var off: Vector3 = _case["cam"]
		_cam.global_position = Vector3(off.x, off.y, z + off.z)
		_cam.look_at(Vector3(0.0, 1.2, z + 0.3 if off.z > 0.0 else z - 0.5), Vector3.UP)
		_settle = 40
	var cmd := DotFpsCommand.new()
	cmd.yaw = 180.0
	var _a := _player.simulate_tick(_tick, 1.0 / 64.0, cmd, DotWeaponCommand.new())
	_tick += 1
	return false


func _process(delta: float) -> bool:
	if _case.is_empty():
		return _cases.is_empty() and _tick > 3
	_player.view_now = null
	_player.present(delta)
	if _settle > 0:
		_settle -= 1
		return false
	root.get_texture().get_image().save_png(OUT_DIR.path_join("%s.png" % _case["name"]))
	print("wrote ", _case["name"], " held=", _player.held != null)
	_case = {}
	return false
