extends SceneTree

const ArenaAvatars := preload("../game/arena_avatars.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMapLighting := preload("../maps/arena_map_lighting.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

## Frame sequences of what `headless_feel` measures, to look at: drawn at 144 frames a second
## against 64 ticks (`--fixed-fps 144`), so the interpolation fraction runs 0, 0.44, 0.89 as
## it does on a 144 Hz screen.
##
## [codeblock]
## tools/render_feel.sh                 # all three
## tools/render_feel.sh bot stairs      # some
## tools/render_feel.sh bot --stepped   # the bot drawn at its ticks: the control
## [/codeblock]
##
## - `bot`: standing still, a bot running across the view eight metres away, every frame for a
##   quarter of a second. Each frame's step across the screen should be the same.
## - `run`: running and turning on open floor, the view model's bob and sway, every third frame.
## - `stairs`: up dm_box's stair at a run, every third frame; the eye should climb, not hop.
## - `landing`: a drop from 5 m onto open floor, every frame from just before the landing; the
##   eye should go on down a little and come back, not stop dead or jump.
## - `strafe`: strafing right, then left, every third frame; the horizon should lean into it
##   and back, gently, about a degree.
## - `slide`: a run, then a slide, every third frame; the view should widen a little and lean.
##
## Writes `screenshots/feel/<scenario>_NNN.png`, `<scenario>.csv` (every frame) and, with
## PIL, `<scenario>_sheet.png`; `render_feel.sh` prints the largest change of step per frame.

const OUT_DIR := "screenshots/feel"
const TICK_RATE := 64

var _map: ArenaMap = null
var _player: ArenaPlayer = null
var _bot: ArenaPlayer = null
var _scenarios: Array[String] = []
var _scenario := ""
var _tick := 1
var _frame := 0
var _frames := 0
var _save_every := 1
var _log: PackedStringArray = []
var _hands: ZeeViewModel = null
## Physics frames to let a scenario settle before it is recorded.
var _settle := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for name in ["bot", "run", "stairs", "landing", "strafe", "slide"]:
		if args.is_empty() or args.has(name):
			_scenarios.append(name)

	Engine.physics_ticks_per_second = TICK_RATE
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	_map = ArenaMap.dm_box()
	root.add_child(_map.to_scene())
	root.add_child(ArenaMapLighting.build(_map))

	_player = ArenaPlayer.new()
	_player.name = "You"
	_player.setup(ArenaPlayer.Mode.HEADLESS, _map, 7, "You")
	root.add_child(_player)
	_player.spawn(Transform3D(Basis(), Vector3(0.0, 0.05, 20.0)), 0)
	_player.attach_camera(100.0)
	_player.camera.current = true

	_bot = ArenaPlayer.new()
	_bot.name = "Bot"
	_bot.setup(ArenaPlayer.Mode.HEADLESS, _map, 8, "Bot")
	root.add_child(_bot)
	_bot.spawn(Transform3D(Basis(), Vector3(0.0, 0.05, -20.0)), 0)
	_bot.attach_body_mesh(Color(0.85, 0.35, 0.3), ArenaAvatars.stock_avatar(&"arena-player-00000008"))
	# `--stepped` draws the bot where its last tick left it, as every bot was drawn offline
	# before `interpolate_body`: the control the sheet is compared with.
	_bot.interpolate_body = not OS.get_cmdline_user_args().has("--stepped")
	_scenario = "starting"


## The hands, once the player's nodes are in the tree (the rig asks for paths).
func _arm() -> void:
	_hands = ZeeViewModel.new()
	_hands.name = "Hands"
	_player.camera.add_child(_hands)
	_player.arm_first_person(_hands, true)
	_player.give_default_loadout()


func _next_scenario() -> void:
	if _scenarios.is_empty():
		_scenario = ""
		return
	_scenario = _scenarios.pop_front()
	_frame = 0
	match _scenario:
		"bot":
			# The open south-east floor: the bot runs east four metres in front of the view.
			_player.controller.teleport(Vector3(16.0, 0.05, -8.0), 0.0, 0.0)
			_bot.controller.teleport(Vector3(8.0, 0.05, -12.0), -90.0, 0.0)
			_settle = 40
			_frames = 36
			_save_every = 1
		"run":
			_player.controller.teleport(Vector3(15.0, 0.05, -13.0), 0.0, 0.0)
			_bot.controller.teleport(Vector3(-16.0, 0.05, -20.0), 0.0, 0.0)
			_settle = 40
			_frames = 108
			_save_every = 3
		"stairs":
			_player.controller.teleport(Vector3(-12.0, 0.05, -12.0), -90.0, 0.0)
			_settle = 8
			_frames = 120
			_save_every = 3
		"landing":
			# Looking north over the open south floor, 5 m up; the landing is about 0.67 s in.
			_player.controller.teleport(Vector3(10.0, 5.05, -4.0), 180.0, 0.0)
			_bot.controller.teleport(Vector3(-16.0, 0.05, -20.0), 0.0, 0.0)
			_settle = 38
			_frames = 72
			_save_every = 2
		"strafe":
			_player.controller.teleport(Vector3(10.0, 0.05, -12.0), 0.0, 0.0)
			_settle = 20
			_frames = 216
			_save_every = 6
		"slide":
			# West along the open lane at z -17, between the pillars and the south stair.
			_player.controller.teleport(Vector3(13.0, 0.05, -17.0), 90.0, 0.0)
			_settle = 40
			_frames = 144
			_save_every = 4
	_log = PackedStringArray(["frame,tick,alpha,eye_x,eye_y,eye_z,bot_x,bot_z,bot_screen_x,hands_x,hands_y,roll,dip,fov"])


func _command(move: Vector2, yaw: float) -> DotFpsCommand:
	var command := DotFpsCommand.new()
	command.move = move
	command.yaw = yaw
	return command


func _physics_process(_delta: float) -> bool:
	if _scenario == "starting":
		_arm()
		_next_scenario()
	if _scenario == "":
		return true

	var mine := DotFpsCommand.new()
	var theirs := _command(Vector2.ZERO, -90.0)
	match _scenario:
		"bot":
			mine = _command(Vector2.ZERO, 0.0)
			theirs = _command(Vector2(0.0, 1.0), -90.0)
		"run":
			# Forward and right, turning: a circle on open floor.
			mine = _command(Vector2(1.0, 1.0), wrapf(float(_tick) * 3.0, -180.0, 180.0))
		"stairs":
			mine = _command(Vector2(0.0, 1.0), -90.0)
		"landing":
			mine = _command(Vector2.ZERO, 180.0)
		"strafe":
			# Right for 0.75 s, then left, then still (the scenario's frames, at 144 a second).
			var side := 1.0 if _frame < 108 else -1.0
			mine = _command(Vector2(side, 0.0) if _frame < 200 else Vector2.ZERO, 0.0)
		"slide":
			mine = _command(Vector2(0.0, 1.0), 90.0)
			if _settle <= 0 and _frame >= 24:
				mine.buttons = DotFpsCommand.BUTTON_CROUCH

	var _a := _player.simulate_tick(_tick, 1.0 / float(TICK_RATE), mine, DotWeaponCommand.new())
	var _b := _bot.simulate_tick(_tick, 1.0 / float(TICK_RATE), theirs, DotWeaponCommand.new())
	_tick += 1
	if _settle > 0:
		_settle -= 1
	return false


func _process(delta: float) -> bool:
	if _scenario == "":
		return true
	if _scenario == "starting":
		return false

	# The view turns once a frame, as the client's sampler turns it (`ArenaPlayer.view_now`);
	# drawn at the ticks' yaw the sway would be kicked once a tick and zigzag.
	if _scenario == "run":
		var turned := float(_tick - 1) - 1.0 + Engine.get_physics_interpolation_fraction()
		_player.view_now = Vector2(wrapf(turned * 3.0, -180.0, 180.0), 0.0)
	else:
		_player.view_now = null
	_player.present(delta)
	_bot.present(delta)
	if _settle > 0:
		return false

	if _frame >= _frames:
		_finish_scenario()
		return _scenario == ""

	var camera := _player.camera
	var eye := camera.global_position
	var body := _bot.body_mesh.global_position + Vector3(0.0, 1.0, 0.0)
	var screen_x := camera.unproject_position(body).x if not camera.is_position_behind(body) else NAN
	var hands := _hands.get("_animated") as Node3D if _hands != null else null
	var offset := hands.transform.origin if hands != null else Vector3.ZERO
	var motion := _player.camera_motion
	_log.append("%d,%d,%.3f,%.4f,%.4f,%.4f,%.4f,%.4f,%.2f,%.5f,%.5f,%.4f,%.5f,%.3f" % [
		_frame, _tick, Engine.get_physics_interpolation_fraction(), eye.x, eye.y, eye.z,
		body.x, body.z, screen_x, offset.x, offset.y,
		motion.roll() if motion != null else 0.0, motion.eye_drop() if motion != null else 0.0,
		camera.fov])

	# The texture is the last completed frame (see screenshot.gd): a saved frame is the one
	# drawn a frame ago. The spacing is what matters, and that is exact.
	if _frame % _save_every == 0:
		root.get_texture().get_image().save_png(
			OUT_DIR.path_join("%s_%03d.png" % [_scenario, _frame / _save_every]))
	_frame += 1
	return false


func _finish_scenario() -> void:
	var file := FileAccess.open(OUT_DIR.path_join("%s.csv" % _scenario), FileAccess.WRITE)
	file.store_string("\n".join(_log) + "\n")
	file.close()
	print("wrote %s: %d frames" % [_scenario, _frame])
	_next_scenario()
