extends "headless_feel_b1.gd"

const ArenaPresentation := preload("../game/arena_presentation.gd")


## Offline: display rate and seconds.
const OFFLINE_FPS := 144
const OFFLINE_SECONDS := 5.0


## The room the open-floor check wants around a runner: half a width, and from just above
## the feet to a head and a margin over it.
const CLEAR_HALF_WIDTH := 0.7
const CLEAR_HEIGHT := 2.4


var _only := ""


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
	print("game-fatal-contact: what a player sees, frame by frame")
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
	# after it announced itself. Offline 5, moves 8, boot 5, connect 4, and 4 a window
	# (3 where the eye is not judged).
	if _only == "" and _completed == _entered:
		var expected := 5 + 8 + 5 + 4
		for window in WINDOWS:
			expected += 4 if bool(window[8]) else 3
		_check(_passed + _failed == expected, "every check ran (%d of %d)" % [_passed + _failed, expected])

	if not _not_judged.is_empty():
		print("WARNING: %d checks not judged because the machine was starved (load over the cores?); rerun on a quiet machine:" % _not_judged.size())
		for line in _not_judged:
			print("  --    %s" % line)
	_report_sections(_entered, _completed, _entered)


func _wait(seconds: float) -> void:
	await _until(func() -> bool: return false, seconds)


# --- Offline ----------------------------------------------------------------

## Zeroed so a nearby wall cannot be mistaken for bob or sway.
func _zero_wall_retract(client: Node) -> void:
	var p: ArenaPlayer = client.get("player")
	if p != null and p.weapons != null and p.weapons.view_model() != null:
		p.weapons.view_model().get("feel_rules").set("wall_retract", 0.0)


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
	_zero_wall_retract(client)
	# Out-of-sight bodies are presented every fourth frame; this measures every frame.
	ArenaPlayer.present_lod_enabled = false
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
	ArenaPlayer.present_lod_enabled = true
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

	# Up the stair: +x along z -12 from four metres short of the first tread; long enough for the 5.74 m/s run.
	_mover_command = _command(Vector2(0.0, 1.0), -90.0, 0)
	_mover_frames = []
	_measure()
	await _wait(2.6)
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
	# Own body: it trails the eye further the further down you look, or the open hips (the cut
	# where the belly bone is gone) fill the screen looking at your feet.
	_mover.own_body_mode = 1
	var back_level := _mover.own_body_back(0.0)
	var back_down := _mover.own_body_back(-85.0)
	_check(back_down > back_level + 0.3 and is_equal_approx(_mover.own_body_back(-20.0), back_level),
		"looking down: the own body stands %.2f m further back, and not at all for a glance" % (back_down - back_level),
		"level %.2f, down %.2f" % [back_level, back_down])
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
	# One step's smoothed rise takes the same frames at any speed while the mean falls with it, so the bound is 2.5 at the old 7.65 m/s run.
	var ratio_limit := 2.5 * 7.65 / ArenaPlayer.arena_tunables().max_speed
	_check(climb["ratio"] < ratio_limit, "the eye climbs the stair smoothly: no frame rises more than %.1fx the climb's average" % ratio_limit,
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
	_test_moves_rest(stair_starved, slide_starved, widen_slide, widen_run)


func _test_moves_rest(stair_starved: String, slide_starved: String, widen_slide: Dictionary, widen_run: Dictionary) -> void:
	_starved_reason = slide_starved if slide_starved != "" else stair_starved
	_check(widen_run["high"] < 0.05 and widen_slide["high"] > 1.0 and widen_slide["step"] < 0.15 and widen_slide["jerk"] < 0.04,
		"a run does not widen the view, a slide does, and it eases in",
		"run %.2f, slide %.2f degrees, largest step %.3f, largest change of a step %.4f" % [
			widen_run["high"], widen_slide["high"], widen_slide["step"], widen_slide["jerk"]])
	_starved_reason = ""
	_done()


# --- Reading a window ---------------------------------------------------------


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
