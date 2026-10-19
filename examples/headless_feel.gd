extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaModule := preload("../game/arena_module.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")

## dot-net's lossy UDP relay, by path (it has no class_name).
const Relay := preload("res://addons/dot_net/testing/dot_net_udp_relay.gd")

## What a player SEES, frame by frame: the real client, offline and through a real socket.
##
## [codeblock]
## godot --headless --path . res://examples/headless_feel.tscn
## godot --headless --path . res://examples/headless_feel.tscn -- --verbose
## godot --headless --path . res://examples/headless_feel.tscn -- --only offline   # or moves, or a window's name
## [/codeblock]
##
## Every other suite asserts a simulated value, and a simulation-to-screen bug passes all of
## them (docs/testing.md). This one draws at a display rate (`Engine.max_fps`), not the tick
## rate, and samples what each rendered frame shows: the eye and the view, the view model's
## offset under the camera, and everybody else as this client draws them.
##
## - [b]Offline[/b], the real `ArenaClient` runs, strafes and turns among its bots, which run
##   circles (a bot that hunts shoots the player, and a death is not a measurement).
## - [b]Moves[/b]: a player of its own on dm_box, through `ArenaPlayer.present`, up the stair
##   at a run, a slide, a jump and a landing, a drop from 5 m and a strafe each way: the
##   camera's motion (landing dip, lean, widening) eases and never snaps.
## - [b]Connected[/b]: a dual-stack `DotServer` running `ArenaModule` with one bot whose every
##   command is written here (circles), and the real client over ENet through dot-net's relay,
##   in windows at 60 and 144 Hz, steady and then with loss and jitter. (The process draws
##   about 145 frames a second at most with a server in it, so no 240 Hz window.)
##
## Each frame's step is judged against the motion it was drawn on: the local eye and an
## offline bot against the step between their last two ticks, a connected bot against the
## server's own track at the render time the interpolator drew. Frames across a corner (a
## wall, a landing) are not judged: no one velocity says where they should have ended.
## Armed: each check fails with its fix taken out (docs/testing.md has the numbers).

const PORT := 27194
const DATA := "user://arena_feel"
const TICK_RATE := 64

## Offline: display rate and seconds.
const OFFLINE_FPS := 144
const OFFLINE_SECONDS := 5.0

## Connected windows: name, display fps, loss each way, delay each way (ms), jitter (ms),
## seconds, jump held, the delay each way the link changes to as the window starts (0:
## unchanged), whether the local eye is judged, and how far (metres) the bot's step may be
## off the server's motion in a frame.
##
## [b]The delay changing[/b] is what makes slips happen on purpose: a client's clock keeps a
## lead over the server that follows the round trip, and gains or gives it back by running
## its ticks a few percent short or long (drift), so for a second or two some physics frames
## run two ticks or none; and the receive timeline re-anchors a tick at a time. Left to
## chance that happens as a link settles or loses packets, which a window may or may not see.
##
## [b]The eye is judged while the link slows too.[/b] The server says in each snapshot how
## early the client's commands reach it (dot-net's input lead, `FEATURE_INPUT_LEAD`), and the
## clock gains the 30 ms by running its ticks a little short. Before that the lead followed
## ENet's smoothed round trip for seconds, the commands reached the server after their tick
## and the prediction was corrected dozens of times, the eye going backwards on 63-85 frames.
## The window prints how many commands came late and when the last did after the change.
## Snapshots arrive late then too, so the bot is extrapolated for a moment and eased back
## (4 cm, as with loss).
##
## Steady, 2 cm. With loss: a correction is eased, not hidden (3 cm for the eye), and a
## stalled snapshot stream is guessed along a line and eased back when it resumes (5.5 cm for
## the bot at 5% loss, 10 at 20%; it was 17 to 32 cm in one frame).
const WINDOWS := [
	["60 Hz display, steady 40 ms", 60, 0.0, 40.0, 0.0, 5.0, false, 0.0, true, 0.02],
	["144 Hz display, steady 40 ms, jumping", 144, 0.0, 40.0, 0.0, 5.0, true, 0.0, true, 0.02],
	["144 Hz display, 40 ms going to 70 ms", 144, 0.0, 40.0, 0.0, 5.0, false, 70.0, true, 0.05],
	["144 Hz display, 70 ms going to 40 ms", 144, 0.0, 70.0, 0.0, 5.0, false, 40.0, true, 0.02],
	["144 Hz display, 5% loss 30..80 ms", 144, 0.05, 55.0, 25.0, 6.0, false, 0.0, true, 0.055],
	["144 Hz display, 20% loss 30..80 ms", 144, 0.20, 55.0, 25.0, 6.0, false, 0.0, true, 0.10],
]

## Where the local runner's circle is centred: dm_box's open floor south of the stair and
## the pillar, nothing overhead and no wall within 5 m (the ledges and walkways are ceilings
## at 3.0, which a jump's head reaches). The circle is about 2.3 m across at a run; hopping
## drifts it a metre or two. `_check_open_floor` says if a runner did not stay clear.
const RUN_CENTRE := Vector3(11.75, 0.05, -17.25)

## The room the open-floor check wants around a runner: half a width, and from just above
## the feet to a head and a margin over it.
const CLEAR_HALF_WIDTH := 0.7
const CLEAR_HEIGHT := 2.4

## Degrees a second the player turns the mouse, and degrees a tick the bot turns.
const TURN_RATE := 240.0
const BOT_TURN := 2.0

## Ticks between jump presses in a jumping window: a hop is about 41 ticks in the air at
## 64 Hz, so each one runs about 11 ticks on the floor first.
const JUMP_EVERY := 52

var _verbose := false
var _only := ""

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _server_side: Node = null
var _server: DotServer = null
var _game: ArenaGame = null
var _relay = null
var _client_side: Node = null
var _link: DotClientLink = null
var _client: Node = null
var _bot_session := 0

var _driving := false
## Whether the window hops (see `_hold_movement`).
var _jumping := false
var _turning := false

## Server truth: session -> {server tick -> position}.
var _track: Dictionary = {}

## The window's measurements. Empty between windows.
var _w: Dictionary = {}
var _physics_since_render := 0
var _offline_bots: Dictionary = {}

## The standalone player the moves section drives, its command, its tick and its frames.
var _mover: ArenaPlayer = null
var _mover_command: DotFpsCommand = null
var _mover_tick := 1
var _mover_frames: Array = []
## The last landing's impact the mover's controller reported, m/s.
var _mover_impact := 0.0


class Early extends Node:
	var probe = null

	func _physics_process(_delta: float) -> void:
		probe._early_physics()

	func _process(delta: float) -> void:
		probe._early_process(delta)


class Late extends Node:
	var probe = null

	func _physics_process(_delta: float) -> void:
		probe._late_physics()

	func _process(delta: float) -> void:
		probe._late_process(delta)


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_verbose = "--verbose" in args
	var at := args.find("--only")
	if at >= 0 and at + 1 < args.size():
		_only = args[at + 1]
	DotLog.set_level(DotLog.Level.INFO if _verbose else DotLog.Level.ERROR)
	var _scratch := ArenaPresentation.use_scratch_settings("headless_feel")

	var early := Early.new()
	early.probe = self
	early.process_physics_priority = -1000
	early.process_priority = -1000
	add_child(early)
	var late := Late.new()
	late.probe = self
	late.process_physics_priority = 1000
	late.process_priority = 1000
	add_child(late)

	_run.call_deferred()


func _run() -> void:
	print("game-arena: what a player sees, frame by frame")
	DotPaths.remove_tree(DATA)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DATA))

	if _only == "" or "offline".contains(_only):
		await _test_offline()

	if _only == "" or "moves".contains(_only):
		await _test_moves()

	if _only != "offline" and _only != "moves" and await _boot() and await _connect():
		_driving = true
		for window in WINDOWS:
			if _only != "" and not str(window[0]).contains(_only):
				continue
			await _play_window(window)
	_driving = false
	await _teardown()

	# The total the section counter cannot be: a script error aborts the rest of a section
	# after it announced itself. Offline 5, moves 7, boot 5, connect 4, and 4 a window
	# (3 where the eye is not judged).
	if _only == "" and _completed == _entered:
		var expected := 5 + 7 + 5 + 4
		for window in WINDOWS:
			expected += 4 if bool(window[8]) else 3
		_check(_passed + _failed == expected, "every check ran (%d of %d)" % [_passed + _failed, expected])

	print("")
	print("%d passed, %d failed, %d of %d sections ran to their last line" % [
		_passed, _failed, _completed, _entered])
	for line in _failures:
		print("  FAIL  %s" % line)
	if not _not_judged.is_empty():
		print("WARNING: %d checks not judged because the machine was starved (load over the cores?); rerun on a quiet machine:" % _not_judged.size())
		for line in _not_judged:
			print("  --    %s" % line)
	get_tree().quit(1 if _failed > 0 or _completed != _entered else 0)


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


## Wall-clock seconds between drawn frames since the last [method _measure]: how the machine
## kept up, apart from what the game did with each frame.
var _wall: Array[float] = []
var _wall_last_us: int = 0
## Why the measurement being judged cannot be ("" when it can): see [method _starvation].
var _starved_reason: String = ""
## The checks a starved measurement left unjudged, with why.
var _not_judged: PackedStringArray = PackedStringArray()


## Starts a measurement's frame-time record.
func _measure() -> void:
	_wall.clear()


## Why the frames since [method _measure] cannot be judged at [param fps], or "".
##
## [b]A feel check reads frames, and a starved machine stalls them.[/b] Under load well over
## the core count (other suites, a build) a frame can take ten times its budget, and the
## eye, the lean and the bot then step by that much in one frame: the stair "jumps" 71 mm and
## the bot 226 mm, with nothing wrong in the game. More than one frame in twenty (and at least
## four) over twice the display's budget is a machine that was not keeping up; a real hitch is
## one or two frames, and stays judged.
func _starvation(fps: float) -> String:
	var budget := 1.0 / maxf(fps, 1.0)
	var over := 0
	var worst := 0.0
	for dt in _wall:
		if dt > budget * 2.0:
			over += 1
			worst = maxf(worst, dt)
	if _wall.size() >= 10 and over > maxi(3, _wall.size() / 20):
		return "%d of %d frames took over twice their %.1f ms budget, the worst %.0f ms" % [
			over, _wall.size(), budget * 1000.0, worst * 1000.0]
	return ""


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	elif _starved_reason != "":
		# Not judged: the frames this check reads were stalled by the machine, not the game
		# (arena-feel-starvation-1). Counted, so "every check ran" holds, and said loudly.
		_passed += 1
		_not_judged.append("%s -- %s" % [what, _starved_reason])
		print("  --    %s  NOT JUDGED, the machine was starved: %s%s" % [what, _starved_reason, "" if detail == "" else "  (%s)" % detail])
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s -- %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	return condition


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return bool(condition.call())


func _wait(seconds: float) -> void:
	await _until(func() -> bool: return false, seconds)


# --- Offline ----------------------------------------------------------------

func _test_offline() -> void:
	_section("offline at %d Hz: running, strafing and turning among the bots" % OFFLINE_FPS)
	var client: Node = (load("res://game/arena.tscn") as PackedScene).instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	add_child(client)
	_client = client
	Engine.max_fps = OFFLINE_FPS

	# Warmup places nobody until the match is live; wait for the player and two bots alive.
	var live := await _until(func() -> bool:
		var p: ArenaPlayer = client.get("player")
		var g: ArenaGame = client.get("game")
		if p == null or g == null or not p.is_alive() or g.match_node == null or g.match_node.state != DotMatch.State.LIVE:
			return false
		var alive := 0
		for other in g.players():
			if other != p and other.is_alive():
				alive += 1
		return alive >= 2, 40.0)
	_check(live, "the match goes live with the player and the bots placed")

	# The bots run circles rather than hunt: a bot that shoots the player measures a death.
	var bots: Dictionary = client.get("_bots")
	for id in bots:
		(bots[id] as ArenaPlayer).set_meta(&"bot_scripted", true)
	_offline_bots = bots
	_hold_movement(false)
	_turning = true
	_driving = true
	await _wait(1.0)
	_begin_window(0.0)
	await _wait(OFFLINE_SECONDS)
	var w := _end_window()
	_driving = false
	_turning = false
	_release_movement()

	_report_local(w)
	_report_others(w)
	_report_view_model(w)
	_starved_reason = str(w.get("starved_reason", ""))
	_check_local(w, 0.02)
	_check_others(w, "the bots are drawn between ticks: no frame more than %.1f cm off their motion", 0.02)
	_check_view_model(w)
	_starved_reason = ""

	_offline_bots = {}
	client.queue_free()
	_client = null
	await get_tree().process_frame
	await get_tree().process_frame
	_done()


## [b]Jump is pressed a tick in every [constant JUMP_EVERY], not held.[/b] Held, auto-hop
## leaves the ground on the tick it lands and the turning gains air speed every hop: 11 m/s
## at the start of a window, 24 at its end, a circle growing past 5 m and across half the
## map into the ledges and the east wall. Pressed again after a moment on the floor, every
## hop starts at a run's speed and the circle stays the size it was.
func _hold_movement(jump: bool) -> void:
	Input.action_press(&"dot_fps_forward")
	Input.action_press(&"dot_fps_right")
	_jumping = jump


func _release_movement() -> void:
	_jumping = false
	for action in [&"dot_fps_forward", &"dot_fps_right", &"dot_fps_jump"]:
		Input.action_release(action)


# --- The moves, through the one place the camera is written ------------------------

## A player of its own on dm_box, drawn through `ArenaPlayer.present` at the display rate:
## up the stair at a run, a slide, a jump and its landing. What each frame's eye did.
func _test_moves() -> void:
	_section("moves at %d Hz: up dm_box's stair at a run, a slide, a jump and a landing" % OFFLINE_FPS)
	Engine.physics_ticks_per_second = TICK_RATE
	Engine.max_fps = OFFLINE_FPS
	var map := ArenaMap.dm_box()
	_mover = ArenaPlayer.new()
	_mover.name = "Mover"
	_mover.setup(ArenaPlayer.Mode.HEADLESS, map, 7, "Mover")
	add_child(_mover)
	_mover.spawn(Transform3D(Basis(), Vector3(-12.0, 0.05, -12.0)), 0)
	_mover.attach_camera(100.0)
	_mover.controller.landed.connect(func(impact: float) -> void: _mover_impact = maxf(_mover_impact, impact))
	await get_tree().physics_frame
	# The first tick runs after the tree is up; a teleport before it is undone (see
	# tools/render_wall_moves.gd).
	_mover.controller.teleport(Vector3(-12.0, 0.05, -12.0), -90.0, 0.0)

	# Up the stair: +x along z -12 from four metres short of the first tread.
	_mover_command = _command(Vector2(0.0, 1.0), -90.0, 0)
	_mover_frames = []
	_measure()
	await _wait(1.6)
	var stair := _mover_frames.duplicate()
	var stair_starved := _starvation(OFFLINE_FPS)

	# A slide on the floor: back to open ground, run, then duck.
	_mover.controller.teleport(Vector3(-16.0, 0.05, 6.0), -90.0, 0.0)
	_mover_command = _command(Vector2(0.0, 1.0), -90.0, 0)
	await _wait(0.8)
	_mover_frames = []
	_measure()
	_mover_command = _command(Vector2(0.0, 1.0), -90.0, DotFpsCommand.BUTTON_CROUCH)
	await _wait(0.6)
	var slide := _mover_frames.duplicate()
	var slide_starved := _starvation(OFFLINE_FPS)

	# A jump and its landing.
	_mover_command = _command(Vector2(0.0, 0.0), -90.0, 0)
	await _wait(0.6)
	_mover_frames = []
	_mover_command = _command(Vector2(0.0, 0.0), -90.0, DotFpsCommand.BUTTON_JUMP)
	await _wait(0.1)
	_mover_command = _command(Vector2(0.0, 0.0), -90.0, 0)
	await _wait(1.0)
	var jump := _mover_frames.duplicate()

	# A drop from five metres over open floor, standing: the landing dip.
	_mover.controller.teleport(Vector3(10.0, 5.05, -12.0), 0.0, 0.0)
	_mover_command = _command(Vector2.ZERO, 0.0, 0)
	_mover_frames = []
	_measure()
	_mover_impact = 0.0
	await _wait(1.4)
	var drop := _mover_frames.duplicate()
	var drop_starved := _starvation(OFFLINE_FPS)
	var drop_impact := _mover_impact

	# Strafing on the same floor: right, then left, then still.
	_mover.controller.teleport(Vector3(10.0, 0.05, -12.0), 0.0, 0.0)
	await _wait(0.3)
	_mover_frames = []
	_measure()
	_mover_command = _command(Vector2(1.0, 0.0), 0.0, 0)
	await _wait(0.8)
	_mover_command = _command(Vector2(-1.0, 0.0), 0.0, 0)
	await _wait(0.8)
	_mover_command = _command(Vector2.ZERO, 0.0, 0)
	await _wait(0.6)
	var strafe := _mover_frames.duplicate()
	var strafe_starved := _starvation(OFFLINE_FPS)

	_mover_command = null
	_mover.queue_free()
	_mover = null

	var climb := _vertical(stair, func(f: Dictionary) -> bool:
		var p: Vector3 = f["pos"]
		return f["grounded"] and p.x > -6.5 and p.x < 2.4)
	print("    stair: %d frames on the treads, eye rise per frame mean %.1f mm  max %.1f mm  (max/mean %.1f); top %.2f m" % [
		climb["n"], climb["mean"] * 1000.0, climb["max"] * 1000.0, climb["ratio"], climb["top"]])
	var sliding := _vertical(slide, func(_f: Dictionary) -> bool: return true)
	print("    slide: eye drop per frame max %.1f mm; %d frames sliding" % [
		-sliding["min"] * 1000.0, slide.filter(func(f: Dictionary) -> bool: return f["sliding"]).size()])
	var hop := _vertical(jump, func(_f: Dictionary) -> bool: return true)
	print("    jump: eye up per frame max %.1f mm, down max %.1f mm, largest change of vertical step %.1f mm" % [
		hop["max"] * 1000.0, -hop["min"] * 1000.0, hop["jerk"] * 1000.0])

	_check(climb["n"] > 40 and climb["top"] > 3.0, "the run goes up the stair", "%d frames, top %.2f m" % [climb["n"], climb["top"]])
	_starved_reason = stair_starved
	_check(climb["ratio"] < 2.5, "the eye climbs the stair smoothly: no frame rises more than 2.5x the climb's average",
		"max %.1f mm against a mean of %.1f mm" % [climb["max"] * 1000.0, climb["mean"] * 1000.0])
	_starved_reason = ""

	# The camera's motion (`ArenaPlayer.camera_motion_picks`): each eases, none snaps.
	if _verbose:
		for f in drop.slice(0, drop.size(), 12):
			print("      drop frame: pos %s grounded %s dip %.4f" % [f["pos"], f["grounded"], f["dip"]])
	var dip := _motion_track(drop, "dip")
	var landed_at := -1
	for i in range(1, drop.size()):
		if drop[i]["grounded"] and not drop[i - 1]["grounded"]:
			landed_at = i
			break
	var after_rise := 0.0
	if landed_at > 0:
		for i in range(landed_at + 1, drop.size()):
			after_rise = maxf(after_rise, float((drop[i]["eye"] as Vector3).y - (drop[i - 1]["eye"] as Vector3).y))
	print("    drop: landed at %.1f m/s; dip deepest %.1f mm, largest change in a frame %.1f mm; eye up in a frame after landing max %.1f mm" % [
		drop_impact, -dip["low"] * 1000.0, dip["step"] * 1000.0, after_rise * 1000.0])
	var lean := _motion_track(strafe, "roll")
	var widen_slide := _motion_track(slide, "widen")
	var widen_run := _motion_track(stair, "widen")
	print("    strafe: roll %.2f..%.2f degrees, largest change in a frame %.3f, largest change of that %.4f" % [
		lean["low"], lean["high"], lean["step"], lean["jerk"]])
	print("    widening: running %.2f degrees at most; slide up to %.2f, largest change in a frame %.3f, of that %.4f" % [
		widen_run["high"], widen_slide["high"], widen_slide["step"], widen_slide["jerk"]])
	_starved_reason = drop_starved
	_check(dip["low"] < -0.02 and dip["step"] < -dip["low"] * 0.35,
		"a landing from 5 m dips the eye and no frame moves the dip more than a third of its depth",
		"deepest %.1f mm, largest frame %.1f mm" % [-dip["low"] * 1000.0, dip["step"] * 1000.0])
	_check(landed_at > 0 and after_rise < 0.004, "and the eye comes back up gently: under 4 mm a frame",
		"%.1f mm" % (after_rise * 1000.0))
	_starved_reason = strafe_starved
	_check(lean["high"] > 0.7 and lean["low"] < -0.7 and maxf(lean["high"], -lean["low"]) <= 7.0,
		"a strafe leans the view both ways, within the 7 degree bound",
		"%.2f..%.2f" % [lean["low"], lean["high"]])
	_check(lean["step"] < 0.1 and lean["jerk"] < 0.02,
		"and the lean eases: under 0.1 degrees a frame, its rate changing under 0.02 a frame, even reversing",
		"largest turn in a frame %.3f, largest change of that %.4f degrees" % [lean["step"], lean["jerk"]])
	_starved_reason = slide_starved if slide_starved != "" else stair_starved
	_check(widen_run["high"] < 0.05 and widen_slide["high"] > 1.0 and widen_slide["step"] < 0.15 and widen_slide["jerk"] < 0.04,
		"a run does not widen the view, a slide does, and it eases in",
		"run %.2f, slide %.2f degrees, largest step %.3f, largest change of a step %.4f" % [
			widen_run["high"], widen_slide["high"], widen_slide["step"], widen_slide["jerk"]])
	_starved_reason = ""
	_done()


## How [param key] of the camera's motion moved over [param frames]: its range, its largest
## change in a frame and the largest change of that change (a corner in its motion).
static func _motion_track(frames: Array, key: String) -> Dictionary:
	var low := INF
	var high := -INF
	var step := 0.0
	var jerk := 0.0
	for i in range(frames.size()):
		var v := float(frames[i][key])
		low = minf(low, v)
		high = maxf(high, v)
		if i > 0:
			var d := v - float(frames[i - 1][key])
			step = maxf(step, absf(d))
			if i > 1:
				jerk = maxf(jerk, absf(d - (float(frames[i - 1][key]) - float(frames[i - 2][key]))))
	return {"low": low, "high": high, "step": step, "jerk": jerk}


static func _command(move: Vector2, yaw: float, buttons: int) -> DotFpsCommand:
	var command := DotFpsCommand.new()
	command.move = move
	command.yaw = yaw
	command.buttons = buttons
	return command


## The eye's vertical steps over [param frames] that [param keep] accepts.
static func _vertical(frames: Array, keep: Callable) -> Dictionary:
	var rises := []
	var jerk := 0.0
	var top := -INF
	var last_rise: Variant = null
	for i in range(1, frames.size()):
		var f: Dictionary = frames[i]
		if not bool(keep.call(f)) or not bool(keep.call(frames[i - 1])):
			last_rise = null
			continue
		var rise := float((f["eye"] as Vector3).y - (frames[i - 1]["eye"] as Vector3).y)
		rises.append(rise)
		top = maxf(top, float((f["pos"] as Vector3).y))
		if last_rise != null:
			jerk = maxf(jerk, absf(rise - float(last_rise)))
		last_rise = rise
	var total := 0.0
	var high := -INF
	var low := INF
	for r in rises:
		total += float(r)
		high = maxf(high, float(r))
		low = minf(low, float(r))
	var mean := total / float(maxi(1, rises.size()))
	return {"n": rises.size(), "mean": mean, "max": high, "min": low, "jerk": jerk,
		"ratio": high / mean if mean > 0.0 else INF, "top": top}


# --- Boot and connect -----------------------------------------------------------

func _module() -> ArenaModule:
	return _server.modules.get_module("arena") as ArenaModule if _server != null else null


func _boot() -> bool:
	_section("a dual-stack arena server with a bot running circles, and the relay in front of it")

	_server_side = Node.new()
	_server_side.name = "ServerSide"
	add_child(_server_side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), _server_side.get_path())

	_game = ArenaGame.new()
	_game.name = "Arena"
	_game.tick_rate = TICK_RATE
	_game.score_limit = 0
	_game.time_limit_sec = 0.0
	_game.headless = true
	_game.register_service = true
	_server_side.add_child(_game)
	var ready := _game.setup(ArenaMap.dm_box())
	if not _check(ready.ok, "the arena sets up", str(ready.error)):
		_done()
		return false

	var config := DotServerConfig.new()
	config.hostname = "arena feel"
	config.port = PORT
	config.bind_address = "127.0.0.1"
	config.transport_mode = "dual"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % DATA
	config.bans_path = "%s/bans.json" % DATA
	config.audit_log_path = "%s/audit.jsonl" % DATA
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""
	config.query_enabled = false
	config.enet_share_udp_port = false
	config.stdin_console_enabled = false
	config.log_level = "info" if _verbose else "error"

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	_server_side.add_child(_server)

	var booted: DotResult = await _server.boot()
	if not _check(booted.ok, "the server boots", str(booted.error)):
		_done()
		return false

	ArenaModule.punishments_file = "%s/punishments.json" % DATA
	var loaded: DotResult = await _server.modules.load_module("res://game/arena_module.gd")
	if not _check(loaded.ok, "the arena module loads", str(loaded.error)):
		_done()
		return false

	# No quota bots: they would shoot the player being measured. One bot of our own, whose
	# every command is written here, so its path is known tick for tick.
	var quota: DotBotQuota = _module().get("_bot_quota")
	if quota != null and quota.mode_cvar != null:
		quota.mode_cvar.force_set("off")
	var bridge = _module().bridge
	_bot_session = bridge.add_bot("Circles")
	(bridge.get("_bot_minds") as Dictionary).erase(_bot_session)
	_check(_bot_session != 0, "the server seats a bot for the client to watch")

	_relay = Relay.new()
	_relay.seed = 20261011
	var relayed: DotResult = _relay.start(0, "127.0.0.1", config.effective_enet_port())
	_check(relayed.ok, "the relay listens in front of UDP %d" % config.effective_enet_port(), str(relayed.error))
	_done()
	return relayed.ok and _bot_session != 0


func _connect() -> bool:
	_section("the real client connects through the relay")
	_set_link(WINDOWS[0])

	_client_side = Node.new()
	_client_side.name = "ClientSide"
	add_child(_client_side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), _client_side.get_path())

	_link = DotClientLink.new()
	_link.name = "Server"
	_link.player_name = "Watcher"
	_link.transport_preference = "udp"
	_link.udp_address = "127.0.0.1:%d" % _relay.port()
	_client_side.add_child(_link)
	_link.connect_to_server("127.0.0.1:%d" % PORT)

	var spawned := [false]
	_link.spawned.connect(func() -> void: spawned[0] = true)
	await _until(func() -> bool: return spawned[0] or _link.is_playing(), 30.0)

	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("mouse_capture_override", true)
	_client_side.add_child(_client)

	# **The cover lifts on the server's map, never on the placeholder the client boots on.**
	# A connected client builds dm_box and learns the server's map a round trip after READY.
	# Its gate let go of the map at boot, so the cover lifted on dm_box and came back for the
	# real map: a joiner on dm_atrium saw and walked the wrong level for 140 ms (100 ms each
	# way), and the cover report made the server count the seat loaded while it was not.
	# The server here is on dm_box, so this asks the order, not the map: was the server's
	# map in when the gate first opened?
	var map_in := [false]
	var opened_on := [""]
	var extras: Node = _client.get("extras")
	var gate: DotLoadGate = _client.get("gate")
	if extras != null:
		extras.connect("map_changed", func(_m: DotMapDef) -> void: map_in[0] = true)
	if gate != null:
		gate.opened.connect(func() -> void:
			if opened_on[0] == "":
				opened_on[0] = "after the server's map" if map_in[0] else "before the server's map")

	var playing := await _until(func() -> bool:
		var p: ArenaPlayer = _client.get("player")
		var net: DotNetManager = _client.get("net")
		return p != null and p.is_alive() and net != null and net.clock.is_synced(), 40.0)
	_check(playing, "the client adopts its player and is alive", "transport %s" % _link.transport_used)
	var sees := await _until(func() -> bool: return _remote_bot() != null and _remote_bot().is_alive(), 30.0)
	_check(sees, "and sees the server's bot")
	await _until(func() -> bool: return opened_on[0] != "", 10.0)
	_check(opened_on[0] == "after the server's map",
		"its loading cover first lifted once the server had named its map", opened_on[0])
	_check(Engine.physics_ticks_per_second == TICK_RATE, "the engine steps physics at the server's rate",
		str(Engine.physics_ticks_per_second))

	# Both runners into open floor, where their circles meet no wall: a wall turns a step
	# into a corner, and a frame across a corner is not a measurement of anything drawn.
	# The client's copy of itself is corrected once, here, before anything is measured.
	_place_on_circle(_game.player_for(_bot_session), Vector3(-16.0, 0.05, 14.0), 4.0)
	var me := _client.get("player") as ArenaPlayer
	_place_on_circle(_game.player_for(me.player_id) if me != null else null, RUN_CENTRE, 2.2, -45.0, false)
	_done()
	return playing and sees


## Puts [param p] (on the server) where the circle it runs is centred on [param centre]:
## [param radius] metres from it, square to the way it is heading. [param heading] is the
## heading's angle off the yaw in degrees (-45 for forward and right held), and
## [param turns_left] says which side the centre is on: a runner whose yaw grows turns
## toward (-cos, 0, sin) of its heading, one whose yaw shrinks the other way.
##
## [b]The local runner's yaw shrinks.[/b] The mouse moves right, and it holds forward and
## right. Until 2026-10-12 it was placed as if it turned left, so every window's circle was
## centred 4.4 m off, under the east ledge's lip and against the east wall: the jumping
## window's apex hit the ledge's underside, and the "eye" check measured a ceiling bump and
## a wall slide, which client and server disagree about by a few centimetres, and failed on a
## correction whenever a loaded machine lined one up with a judged frame.
func _place_on_circle(p: ArenaPlayer, centre: Vector3, radius: float, heading: float = 0.0,
		turns_left: bool = true) -> void:
	if p == null:
		return
	var h := deg_to_rad(p.controller.state.yaw + heading)
	var at := centre + Vector3(cos(h), 0.0, -sin(h)) * radius * (1.0 if turns_left else -1.0)
	p.controller.teleport(at, p.controller.state.yaw, p.controller.state.pitch)
	p.global_position = at


func _remote_bot() -> ArenaPlayer:
	if _client == null:
		return null
	var g: ArenaGame = _client.get("game")
	return g.player_for(_bot_session) if g != null else null


func _set_link(window: Array) -> void:
	_relay.up.configure(float(window[2]), float(window[3]), float(window[4]))
	_relay.down.configure(float(window[2]), float(window[3]), float(window[4]))


func _teardown() -> void:
	if _link != null:
		_link.disconnect_from_server("done")
	for _i in range(10):
		await get_tree().process_frame
	if _relay != null:
		_relay.stop()
	if _server != null and _server.has_method("shutdown"):
		_server.shutdown("done")
	for _i in range(10):
		await get_tree().process_frame
	DotPaths.remove_tree(DATA)


# --- Drivers ----------------------------------------------------------------

func _early_physics() -> void:
	if _jumping:
		if Engine.get_physics_frames() % JUMP_EVERY == 0:
			Input.action_press(&"dot_fps_jump")
		else:
			Input.action_release(&"dot_fps_jump")
	if _mover != null and _mover_command != null:
		var _outcome := _mover.simulate_tick(_mover_tick, 1.0 / float(TICK_RATE), _mover_command, DotWeaponCommand.new())
		_mover_tick += 1
	for id in _offline_bots:
		var bot: ArenaPlayer = _offline_bots[id]
		if not is_instance_valid(bot):
			continue
		var move := DotFpsCommand.new()
		move.move = Vector2(0.0, 1.0)
		move.yaw = wrapf(float(bot.controller.state.tick) * BOT_TURN + float(id) * 90.0, -180.0, 180.0)
		bot.set_meta(&"bot_move", move)
		bot.set_meta(&"bot_fire", DotWeaponCommand.new())
	# The server hears its clients once a tick, as a dedicated server does.
	if _server_side != null:
		var api := get_tree().get_multiplayer(_server_side.get_path())
		if api != null and api.has_multiplayer_peer():
			api.poll()
	if _game == null or _bot_session == 0:
		return
	var behaviour = _module().bridge.behaviour_for(_bot_session) if _module() != null else null
	if behaviour == null:
		return
	var move := DotFpsCommand.new()
	move.move = Vector2(0.0, 1.0)
	move.yaw = wrapf(float(_game.current_tick()) * BOT_TURN, -180.0, 180.0)
	behaviour.last_move = move
	behaviour.last_fire = DotWeaponCommand.new()


func _late_physics() -> void:
	_physics_since_render += 1
	if _game == null:
		return
	var tick := _game.current_tick()
	for p in _game.players():
		var track: Dictionary = _track.get(p.player_id, {})
		track[tick] = p.controller.state.position
		_track[p.player_id] = track


func _early_process(delta: float) -> void:
	if not _driving or not _turning or _client == null:
		return
	var p: ArenaPlayer = _client.get("player")
	if p == null:
		return
	var tunables := p.controller.tunables
	var per_count := tunables.mouse_sensitivity * tunables.mouse_sensitivity_x if tunables != null else 0.022
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(TURN_RATE * delta / maxf(per_count, 1e-6), 0.0)
	_client._unhandled_input(motion)


## After everything that writes the camera: what this frame shows.
func _late_process(delta: float) -> void:
	var now_us := Time.get_ticks_usec()
	if _wall_last_us > 0:
		_wall.append(float(now_us - _wall_last_us) / 1000000.0)
	_wall_last_us = now_us
	var physics := _physics_since_render
	_physics_since_render = 0
	if _mover != null and _mover.camera != null:
		_mover.present(delta)
		var st := _mover.controller.state
		var motion := _mover.camera_motion
		_mover_frames.append({"dt": delta, "eye": _mover.camera.global_position,
			"grounded": st.is_grounded(), "sliding": st.is_sliding(), "pos": st.position,
			"dip": motion.eye_drop() if motion != null else 0.0,
			"roll": motion.roll() if motion != null else 0.0,
			"widen": motion.fov_added() if motion != null else 0.0})
	if _w.is_empty() or _client == null:
		return
	var server_buffer := _server_buffer()
	if server_buffer != null and server_buffer.late_count + server_buffer.starved_count > int(_w.get("late_seen", 1 << 30)):
		_w["late_seen"] = server_buffer.late_count + server_buffer.starved_count
		_w["last_late_ms"] = Time.get_ticks_msec() - int(_w["started"])
	var p: ArenaPlayer = _client.get("player")
	if p == null or p.camera == null or not p.is_alive():
		_w["last"] = null
		return
	var eye := p.camera.global_position
	var yaw := p.camera.global_rotation_degrees.y
	var frame := {
		"dt": delta, "eye": eye, "yaw": yaw, "vel": _segment_velocity(p),
		"physics": physics, "vm": _view_model_offset(p), "others": {},
		"tick": (_client.get("net") as DotNetManager).clock.tick if _client.get("net") != null else 0,
		"drift": float((_client.get("net") as DotNetManager).clock.get("_drift_scale")) if _client.get("net") != null else 1.0,
		"slip": float((_client.get("net") as DotNetManager).clock.get("_slip")) if _client.get("net") != null else 0.0,
		"slip_rate": float((_client.get("net") as DotNetManager).clock.get("_slip_recovery")) if _client.get("net") != null else 0.0,
		"alpha": p.get("drawn_alpha"), "frac": Engine.get_physics_interpolation_fraction(),
		"offset": p.drawn_offset,
	}
	var g: ArenaGame = _client.get("game")
	for other in g.players():
		if other == p or not other.is_alive():
			continue
		frame["others"][other.player_id] = {
			"drawn": other.body_mesh.global_position if other.body_mesh != null else other.global_position,
			"vel": _segment_velocity(other),
			"render": _render_tick(),
		}
	(_w["frames"] as Array).append(frame)


## The velocity of the stretch of motion a frame is drawn on: from the previous tick's
## position to this one's, which is what interpolation between them moves along. The state's
## own velocity is the wrong reference wherever a tick changed it (a wall, a landing).
static func _segment_velocity(p: ArenaPlayer) -> Vector3:
	var previous := p.controller.render_state(0.0).position
	return (p.controller.state.position - previous) * float(p.controller.tick_rate)


## The view model's animated offset under the camera: sway, bob, kick.
static func _view_model_offset(p: ArenaPlayer) -> Variant:
	if p.weapons == null or p.weapons.view_model() == null:
		return null
	var animated: Node3D = p.weapons.view_model().get("_animated")
	return animated.transform.origin if animated != null else null


## The render tick the interpolator drew at this frame (connected only), the same arithmetic
## as `DotNetManager.interpolate_frame`; -1 offline.
func _render_tick() -> float:
	var net: DotNetManager = _client.get("net")
	if net == null or net.interpolator == null:
		return -1.0
	var alpha := clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0)
	if net.clock.has_method(&"render_alpha"):
		alpha = clampf(float(net.clock.call(&"render_alpha")), -1.0, 2.0)
	var slip := float(net.clock.call(&"receive_slip")) if net.clock.has_method(&"receive_slip") else 0.0
	return float(net.clock.received_tick()) + alpha + slip - net.interpolator.delay_ticks()


func _begin_window(_unused: float) -> void:
	_measure()
	_w = {"frames": [], "started": Time.get_ticks_msec(), "last": null, "tick0": _game.current_tick() if _game != null else 0}
	var net: DotNetManager = _client.get("net")
	if net != null:
		_w["corrections"] = int(net.predictor.get("_corrections_applied"))
		_w["snaps"] = int(net.clock.get("_snap_count"))
		_w["catch_ups"] = int(net.clock.get("_catch_up_count"))
		var buffer := _server_buffer()
		_w["late"] = buffer.late_count if buffer != null else 0
		_w["starved"] = buffer.starved_count if buffer != null else 0
		_w["late_seen"] = int(_w["late"]) + int(_w["starved"])
		_w["last_late_ms"] = -1
		net.interpolator.reset_counts()


## The server's buffer of this client's commands, for how many came late or not at all.
func _server_buffer() -> DotNetInput.Buffer:
	var module := _module()
	if module == null or _link == null:
		return null
	var server_net: DotNetManager = module.get("net")
	return server_net.input_buffer_for(_link.multiplayer.get_unique_id()) if server_net != null else null


func _end_window() -> Dictionary:
	var w := _w
	_w = {}
	w["starved_reason"] = _starvation(float(Engine.max_fps))
	if str(w["starved_reason"]) != "":
		print("    frames: the machine was starved (%s); a failing check here is not judged" % w["starved_reason"])
	w["tick1"] = _game.current_tick() if _game != null else 0
	w["seconds"] = float(Time.get_ticks_msec() - int(w["started"])) / 1000.0
	return w


# --- Reading a window ---------------------------------------------------------

static func _pct(values: Array, p: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return float(sorted[clampi(int(roundf(p * float(sorted.size() - 1))), 0, sorted.size() - 1)])


## The local eye against its own speed, and the view against the mouse.
func _local(w: Dictionary, limit: float = 0.02) -> Dictionary:
	var frames: Array = w["frames"]
	var ratios := []
	var offs := []
	var turns := []
	var backward := 0
	for i in range(1, frames.size()):
		var a: Dictionary = frames[i - 1]
		var b: Dictionary = frames[i]
		var dt: float = b["dt"]
		var step: Vector3 = b["eye"] - a["eye"]
		var v: Vector3 = b["vel"]
		var flat := Vector3(v.x, 0.0, v.z)
		var speed := flat.length()
		# Judged only where the motion is the same on both sides of the frame: a frame that
		# crosses a corner (a wall, a landing) moved along two steps, and no single
		# velocity says where it should have ended.
		var steady := (v - (a["vel"] as Vector3)).length() < 1.5
		if speed > 1.0 and dt > 0.0 and step.length() < 0.5 and steady:
			var along := Vector3(step.x, 0.0, step.z).dot(flat / speed)
			ratios.append(along / (speed * dt))
			if along < -0.0005:
				backward += 1
			# Less 15% of the step: after a slip the drawing runs up to a tenth fast or slow
			# while it is taken up (DotNetClock.render_alpha), and is drawn along the tick
			# before, whose velocity this is not. A slip not taken up is a whole step.
			#
			# [b]And less what the clock does on purpose.[/b] While it gains lead its ticks run
			# up to 12% short (`_drift_scale` 0.88: the player moves 14% faster in real time)
			# and a slip is taken up at twice that (`_slip_recovery` 0.27), so the eye runs up
			# to half as fast again for a few frames by design. Judged against real time alone,
			# a frame of that on open floor at a run was 2.4-2.9 cm "off" in about one 40->70
			# window in four; a still or doubled frame is a whole step, which this still is.
			var clock_share := absf(1.0 / maxf(float(b.get("drift", 1.0)), 0.01) - 1.0)
			if absf(float(b.get("slip", 0.0))) > 1e-6 or absf(float(a.get("slip", 0.0))) > 1e-6:
				clock_share += float(b.get("slip_rate", 0.0))
			offs.append(maxf(0.0, (Vector3(step.x, 0.0, step.z) - flat * dt).length() - (0.15 + clock_share) * speed * dt))
			if offs[-1] > limit and _verbose:
				print("      alpha %s frac %.3f offset %s" % [b["alpha"], b["frac"], b["offset"]])
				print("      local off frame %d: ticks %d drift %.4f slip %.3f -> %.3f at %.3f dt %.4f physics %d step %s vel %s prev vel %s eye %s" % [i, int(b["tick"]) - int(a["tick"]), b["drift"], float(a.get("slip", 0.0)), float(b.get("slip", 0.0)), float(b.get("slip_rate", 0.0)), dt, b["physics"], step, v, a["vel"], b["eye"]])
		if dt > 0.0:
			turns.append(absf(wrapf(float(b["yaw"]) - float(a["yaw"]), -180.0, 180.0)) / (TURN_RATE * dt))
	var jumps := 0
	for o in offs:
		if float(o) > limit:
			jumps += 1
	var still := 0
	var double := 0
	var median_turn := _pct(turns, 0.5)
	for t in turns:
		if float(t) < 0.5 * median_turn:
			still += 1
		elif float(t) > 1.5 * median_turn:
			double += 1
	return {"ratios": ratios, "offs": offs, "jumps": jumps, "backward": backward,
		"turns": turns, "still": still, "double": double}


func _report_local(w: Dictionary) -> void:
	var l := _local(w)
	var frames: Array = w["frames"]
	print("    %d frames in %.1f s (%.0f fps)" % [frames.size(), w["seconds"], frames.size() / maxf(0.001, w["seconds"])])
	print("    local eye: motion per frame / expected p5 %.2f  p50 %.2f  p95 %.2f; backward %d; off steady p50 %.1f mm  p99 %.1f mm  max %.1f mm; %d frames > 2 cm" % [
		_pct(l["ratios"], 0.05), _pct(l["ratios"], 0.5), _pct(l["ratios"], 0.95), l["backward"],
		_pct(l["offs"], 0.5) * 1000.0, _pct(l["offs"], 0.99) * 1000.0, _pct(l["offs"], 1.0) * 1000.0, l["jumps"]])
	print("    view: %d of %d frames turned under half the median, %d over 1.5x" % [l["still"], (l["turns"] as Array).size(), l["double"]])


func _check_view_turns(w: Dictionary) -> void:
	var l := _local(w)
	_check(l["still"] == 0 and l["double"] == 0, "the view turned evenly on every frame the mouse moved",
		"%d still, %d double of %d" % [l["still"], l["double"], (l["turns"] as Array).size()])


func _check_local(w: Dictionary, limit: float) -> void:
	_check_view_turns(w)
	var l := _local(w, limit)
	_check(l["jumps"] == 0 and l["backward"] == 0,
		"the eye moved with the player on every frame: none more than %d cm off, none backwards" % roundi(limit * 100.0),
		"%d off, %d backwards, max %.1f mm" % [l["jumps"], l["backward"], _pct(l["offs"], 1.0) * 1000.0])


## Everybody else as drawn: each frame's step against the step their motion asked for.
##
## Offline the truth is their own simulated velocity; connected, the server's track at the
## render tick this frame and the last were drawn at.
func _others(w: Dictionary, limit: float = 0.02) -> Dictionary:
	var frames: Array = w["frames"]
	var offs := []
	var errors := []
	var back := 0
	for i in range(1, frames.size()):
		var a: Dictionary = frames[i - 1]
		var b: Dictionary = frames[i]
		var dt: float = b["dt"]
		for id in b["others"]:
			if not (a["others"] as Dictionary).has(id):
				continue
			var now: Dictionary = b["others"][id]
			var was: Dictionary = a["others"][id]
			var step: Vector3 = (now["drawn"] as Vector3) - (was["drawn"] as Vector3)
			if step.length() > 0.5:
				continue
			var rt: float = now["render"]
			if rt < 0.0:
				var v: Vector3 = now["vel"]
				if Vector3(v.x, 0.0, v.z).length() > 1.0 and (v - (was["vel"] as Vector3)).length() < 1.5:
					offs.append((Vector3(step.x, 0.0, step.z) - Vector3(v.x, 0.0, v.z) * dt).length())
				continue
			var prev_rt: float = was["render"]
			if rt < prev_rt - 0.001:
				back += 1
				if _verbose:
					print("      bot render time back at frame %d: %.4f -> %.4f ticks (dt %.4f)" % [i, prev_rt, rt, dt])
			var track: Dictionary = _track.get(id, {})
			var t_now: Variant = _truth_at(track, rt)
			var t_was: Variant = _truth_at(track, prev_rt)
			if t_now == null or t_was == null or _teleported_near(track, int(rt)):
				continue
			var truth_step: Vector3 = (t_now as Vector3) - (t_was as Vector3)
			# Less a tenth of the step itself: positions arrive on a 7.8 mm grid and are
			# blended along chords of a curve, which at 60 Hz (15 cm a frame) is up to
			# 2.6 cm of a perfectly drawn frame. A hitch is a whole step.
			offs.append(maxf(0.0, (step - truth_step).length() - 0.1 * truth_step.length()))
			if _verbose and float(offs[-1]) > 0.02:
				print("      bot off frame %d: %.1f mm; dt %.4f render %.2f -> %.2f; drawn step %s truth step %s" % [
					i, float(offs[-1]) * 1000.0, dt, prev_rt, rt, step, truth_step])
			errors.append((now["drawn"] as Vector3).distance_to(t_now))
	var hitches := 0
	for o in offs:
		if float(o) > limit:
			hitches += 1
	return {"offs": offs, "errors": errors, "hitches": hitches, "back": back}


func _report_others(w: Dictionary) -> void:
	var o := _others(w)
	print("    others: step off their motion p50 %.1f mm  p95 %.1f mm  p99 %.1f mm  max %.1f mm; %d of %d frames > 2 cm; drawn vs truth p50 %.3f m  p95 %.3f m  max %.3f m; render back %d" % [
		_pct(o["offs"], 0.5) * 1000.0, _pct(o["offs"], 0.95) * 1000.0, _pct(o["offs"], 0.99) * 1000.0,
		_pct(o["offs"], 1.0) * 1000.0, o["hitches"], (o["offs"] as Array).size(),
		_pct(o["errors"], 0.5), _pct(o["errors"], 0.95), _pct(o["errors"], 1.0), o["back"]])


func _check_others(w: Dictionary, what: String, limit: float, back_allowed: int = 0) -> void:
	var o := _others(w, limit)
	_check((o["offs"] as Array).size() > 50 and o["hitches"] == 0 and o["back"] <= back_allowed,
		what % (limit * 100.0),
		"%d of %d frames over, max %.1f mm, render back %d" % [
			o["hitches"], (o["offs"] as Array).size(), _pct(o["offs"], 1.0) * 1000.0, o["back"]])


static func _truth_at(track: Dictionary, tick: float) -> Variant:
	var lo := int(floorf(tick))
	if not track.has(lo) or not track.has(lo + 1):
		return null
	return (track[lo] as Vector3).lerp(track[lo + 1], tick - float(lo))


static func _teleported_near(track: Dictionary, tick: int) -> bool:
	for t in range(tick - 16, tick + 16):
		if track.has(t) and track.has(t + 1) and (track[t] as Vector3).distance_to(track[t + 1]) > 0.5:
			return true
	return false


## The view model's offset: its acceleration frame to frame, which a bob or sway that steps
## at the tick or buzzes faster than a footfall shows as a large second difference.
func _view_model(w: Dictionary) -> Dictionary:
	var frames: Array = w["frames"]
	var jerks := []
	for i in range(2, frames.size()):
		var c: Variant = frames[i - 2]["vm"]
		var a: Variant = frames[i - 1]["vm"]
		var b: Variant = frames[i]["vm"]
		if a == null or b == null or c == null:
			continue
		var dt: float = frames[i]["dt"]
		# Scaled to 144 Hz, so windows at other rates read on one scale.
		var k := pow((1.0 / 144.0) / maxf(dt, 1e-4), 2.0)
		jerks.append((((b as Vector3) - (a as Vector3)) - ((a as Vector3) - (c as Vector3))).length() * k)
	return {"jerks": jerks}


func _report_view_model(w: Dictionary) -> void:
	var v := _view_model(w)
	print("    view model: second difference (at 144 Hz) p50 %.2f mm  p99 %.2f mm  max %.2f mm" % [
		_pct(v["jerks"], 0.5) * 1000.0, _pct(v["jerks"], 0.99) * 1000.0, _pct(v["jerks"], 1.0) * 1000.0])


func _check_view_model(w: Dictionary) -> void:
	var v := _view_model(w)
	_check((v["jerks"] as Array).size() > 50 and _pct(v["jerks"], 0.99) < 0.001,
		"the view model's bob and sway are smooth at a run: p99 second difference under 1 mm a frame",
		"p99 %.2f mm" % (_pct(v["jerks"], 0.99) * 1000.0))


# --- A connected window -------------------------------------------------------

## Both runners stayed on open floor through the window: nothing of the map within
## [constant CLEAR_HALF_WIDTH] of them or over their heads, by the server's own track. Every
## other check here judges a frame against one velocity, which a wall or a ceiling breaks;
## a runner that drifted into one is measuring the wall (see `_place_on_circle`).
func _check_open_floor(w: Dictionary) -> void:
	var me: ArenaPlayer = _client.get("player")
	var touched := PackedStringArray()
	var ticks := 0
	for who in [me.player_id if me != null else 0, _bot_session]:
		var track: Dictionary = _track.get(who, {})
		for t in range(int(w["tick0"]), int(w["tick1"]) + 1):
			if not track.has(t):
				continue
			ticks += 1
			var at: Vector3 = track[t]
			var room := AABB(at + Vector3(-CLEAR_HALF_WIDTH, 0.05, -CLEAR_HALF_WIDTH),
				Vector3(CLEAR_HALF_WIDTH * 2.0, CLEAR_HEIGHT, CLEAR_HALF_WIDTH * 2.0))
			for box in _game.map.boxes:
				if room.intersects(box):
					touched.append("%s at %s by %s" % ["runner" if who != _bot_session else "bot", at, box])
					break
	if _verbose and me != null:
		var tr: Dictionary = _track.get(me.player_id, {})
		var lo := Vector3(INF, INF, INF)
		var hi := -lo
		var speeds := []
		for t in range(int(w["tick0"]), int(w["tick1"])):
			if tr.has(t) and tr.has(t + 1):
				lo = lo.min(tr[t])
				hi = hi.max(tr[t])
				var d: Vector3 = (tr[t + 1] as Vector3) - (tr[t] as Vector3)
				speeds.append(Vector2(d.x, d.z).length() * TICK_RATE)
		print("    runner's track: x %.1f..%.1f  z %.1f..%.1f; speed p5 %.1f  p50 %.1f  max %.1f m/s" % [
			lo.x, hi.x, lo.z, hi.z, _pct(speeds, 0.05), _pct(speeds, 0.5), _pct(speeds, 1.0)])
	_check(ticks > 100 and touched.is_empty(), "both runners stayed on open floor, clear of walls and ceilings",
		"%d ticks, %d near the map%s" % [ticks, touched.size(), (": " + touched[0]) if not touched.is_empty() else ""])


func _play_window(window: Array) -> void:
	_section("%s" % window[0])
	_set_link(window)
	Engine.max_fps = int(window[1])
	# Every window starts on its circle, wherever the last one ended (see `_place_on_circle`).
	var me := _client.get("player") as ArenaPlayer
	_place_on_circle(_game.player_for(me.player_id) if me != null else null, RUN_CENTRE, 2.2, -45.0, false)
	_hold_movement(bool(window[6]))
	_turning = true
	await _wait(1.5)

	_relay.reset_counts()
	if float(window[7]) > 0.0:
		var changed := window.duplicate()
		changed[3] = window[7]
		_set_link(changed)
	_begin_window(0.0)
	await _wait(float(window[5]))
	var w := _end_window()
	_turning = false
	_release_movement()

	var net: DotNetManager = _client.get("net")
	var corrections := int(net.predictor.get("_corrections_applied")) - int(w["corrections"])
	_report_local(w)
	_report_others(w)
	_report_view_model(w)
	var buffer := _server_buffer()
	print("    prediction: %d corrections; server had the command late %d, starved %d; clock rtt %d ms, lead %d, snaps %d, catch-ups %d" % [
		corrections, buffer.late_count - int(w["late"]) if buffer != null else -1,
		buffer.starved_count - int(w["starved"]) if buffer != null else -1, int(net.clock.rtt_ms()),
		net.clock.tick - _game.current_tick(), int(net.clock.get("_snap_count")) - int(w["snaps"]),
		int(net.clock.get("_catch_up_count")) - int(w["catch_ups"])])
	# When a command last came late or not at all, from the window's start (the link changes
	# there): how long the clock took to settle on the new path.
	print("    input lead: %s; the last late or missing command %s" % [
		net.clock.call(&"describe_lead") if net.clock.has_method(&"describe_lead") else "from the round trip",
		"none" if int(w.get("last_late_ms", -1)) < 0 else "%.2f s in" % (float(w["last_late_ms"]) / 1000.0)])
	if _verbose:
		print("    interpolator %s; relay %s" % [net.interpolator.describe(), _relay.describe()])

	# Where the runners went is judged under the same rule: stalled frames turn the circle
	# unevenly and a starved runner drifts into the stair (measured, 2026-10-12).
	_starved_reason = str(w.get("starved_reason", ""))
	_check_open_floor(w)
	var lossy := float(window[2]) > 0.0
	if bool(window[8]):
		_check_local(w, 0.03 if lossy else 0.02)
	else:
		_check_view_turns(w)
	# A lost snapshot can put the render time back a hair once or twice.
	_check_others(w, "the bot is drawn smoothly: no frame's step more than %.1f cm off the server's motion",
		float(window[9]), 3 if lossy else 0)
	_starved_reason = ""
	_done()
