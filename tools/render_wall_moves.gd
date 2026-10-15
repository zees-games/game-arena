extends SceneTree

const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMapLighting := preload("../maps/arena_map_lighting.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const WallRouteDriver := preload("../examples/wall_route_driver.gd")

## dm_atrium's wall routes from first person, as a frame sequence and a per-frame log.
##
## [codeblock]
## tools/render_wall_moves.sh                  # all three: run, runjump, chimney
## tools/render_wall_moves.sh run              # one
## RENDERER=gl_compatibility tools/render_wall_moves.sh
## [/codeblock]
##
## [b]What no suite reaches: the camera.[/b] The suites assert the simulated state, and every
## simulation-to-screen bug this family has had (a view drawn at the last tick, a roll that
## snapped) passed all of them. So this draws a player through `ArenaPlayer.present`, the
## one place the game writes the camera, at three frames a tick (`--fixed-fps 192` against
## 64 ticks, so the interpolation fraction runs 0, 1/3, 2/3 the way it does on a 192 Hz
## screen), and keeps two things: a PNG every [constant SAVE_EVERY] frames (two ticks) in
## `screenshots/wall_moves/`, and a CSV of every frame (the eye, the roll, the lean the
## wall run asked for), which `render_wall_moves.sh` reads for steps and reversals.
##
## Scenarios: `run`, the north gallery's gap run on the wall by a slide-jump; `runjump`, the
## same run kicked off the wall half a second in; `chimney`, the two wall jumps up onto
## the gallery.

const OUT_DIR := "screenshots/wall_moves"
const TICK_RATE := 64
const SAVE_EVERY := 6
## Ticks recorded after the driver's first: the approach, the move and the landing.
const RECORD_TICKS := 120

var _map: ArenaMap = null
var _player: ArenaPlayer = null
var _scenarios: Array[String] = []
var _scenario := ""
var _driver: WallRouteDriver = null
var _tick := 1
var _driven := -1
var _frame := 0
var _log: PackedStringArray = []
var _kicked := false
var _settle := 0
## `third` on the command line: the same routes drawn from the third-person camera, files
## named `<scenario>_tp_NNN.png`, so the body's roll and turn on the wall can be looked at.
var _third := false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_third = args.has("third")
	for name in ["run", "runjump", "chimney"]:
		if args.is_empty() or args.has(name):
			_scenarios.append(name)

	Engine.physics_ticks_per_second = TICK_RATE
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	_map = ArenaMap.dm_atrium()
	root.add_child(_map.to_scene())
	root.add_child(ArenaMapLighting.build(_map))

	_player = ArenaPlayer.new()
	_player.name = "You"
	_player.setup(ArenaPlayer.Mode.HEADLESS, _map, 7, "You")
	root.add_child(_player)
	_player.spawn(Transform3D(Basis(), Vector3(0.0, 0.1, 25.0)), 0)
	_player.attach_camera(100.0)
	_player.camera.current = true
	_player.third_person = _third
	if _third:
		_player.present_own_body(false, 0.0)
	# The first scenario starts on the first physics frame, not here: the player's nodes are
	# not ready until the tree runs, and a teleport made before that is undone by it (the
	# first version of this tool recorded a run from the spawn point).
	_scenario = "starting"


func _next_scenario() -> void:
	if _scenarios.is_empty():
		_scenario = ""
		return

	_scenario = _scenarios.pop_front()
	var route: Dictionary = _map.wall_routes[1 if _scenario == "chimney" else 0]
	_driver = WallRouteDriver.new(route, &"walls")
	var start := _driver.start

	if route["kind"] == &"run":
		# Four and a half metres from the edge at a run, rather than ten from a standstill,
		# so the 1.9 s recorded are the run and not the run-up.
		var forward := DotFpsMotor.forward_for(_driver.yaw)
		start = Vector3(start.x, start.y, start.z) + forward * 5.5

	_player.controller.teleport(start, _driver.yaw, 0.0)
	if route["kind"] == &"run":
		_player.controller.state.velocity = DotFpsMotor.forward_for(_driver.yaw) * 9.0
	_settle = 0 if route["kind"] == &"run" else 24
	_driven = -1
	_kicked = false
	_log = PackedStringArray(["frame,tick,alpha,eye_x,eye_y,eye_z,pitch,yaw,roll_deg,wall_roll,running,grounded,speed"])


func _physics_process(_delta: float) -> bool:
	if _scenario == "starting":
		_next_scenario()
	if _scenario == "":
		return true

	var command := DotFpsCommand.new()
	command.yaw = _driver.yaw

	if _settle > 0:
		_settle -= 1
	else:
		if _driven < 0:
			_driven = _tick
		command = _driver.next(_player.controller.state)
		# `runjump`: a jump off the wall half a second into the run.
		var state := _player.controller.state
		if _scenario == "runjump" and not _kicked and state.is_wall_running() and state.wall_run_time >= 0.5:
			command.buttons |= DotFpsCommand.BUTTON_JUMP
			_kicked = true

	var _outcome := _player.simulate_tick(_tick, 1.0 / float(TICK_RATE), command, DotWeaponCommand.new())
	_tick += 1
	return false


func _process(delta: float) -> bool:
	if _scenario == "":
		return true
	if _scenario == "starting":
		return false

	_player.present(delta)

	if _driven < 0:
		return false

	var recorded := _tick - _driven
	if recorded > RECORD_TICKS:
		_finish_scenario()
		return _scenario == ""

	var camera := _player.camera
	var eye := camera.global_position
	var angles := camera.global_rotation_degrees
	var state := _player.controller.state
	_log.append("%d,%d,%.3f,%.4f,%.4f,%.4f,%.3f,%.3f,%.3f,%.3f,%d,%d,%.3f" % [
		_frame, _tick, Engine.get_physics_interpolation_fraction(), eye.x, eye.y, eye.z,
		angles.x, angles.y, angles.z, _player.wall_roll(), int(state.is_wall_running()),
		int(state.is_grounded()), state.horizontal_speed()])

	# The texture is the last COMPLETED frame (see screenshot.gd), so a frame saved here is
	# the one drawn a frame ago; the log is the frame being drawn. The sequence's spacing is
	# what matters, and that is exact.
	if _frame % SAVE_EVERY == 0:
		var image := root.get_texture().get_image()
		image.save_png(OUT_DIR.path_join("%s%s_%03d.png" % [_scenario, "_tp" if _third else "", _frame / SAVE_EVERY]))

	_frame += 1
	return false


func _finish_scenario() -> void:
	var file := FileAccess.open(OUT_DIR.path_join("%s.csv" % _scenario), FileAccess.WRITE)
	file.store_string("\n".join(_log) + "\n")
	file.close()
	print("wrote %s: %d frames, %d saved" % [_scenario, _frame, (_frame + SAVE_EVERY - 1) / SAVE_EVERY])
	_frame = 0
	_next_scenario()
