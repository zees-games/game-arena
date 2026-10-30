extends "lossy_windows.gd"


func _ready() -> void:
	_verbose = "--verbose" in OS.get_cmdline_user_args()
	DotLog.set_level(DotLog.Level.INFO if _verbose else DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena: a real server and real ENet clients through real packet loss")
	DotPaths.remove_tree(DATA)
	Engine.physics_ticks_per_second = TICK_RATE

	if await _boot():
		if await _connect_everyone():
			for window in WINDOWS:
				await _measured(_play_window.bind(window))
			await _measured(_test_wall_moves)
			await _measured(_test_wall_hops)
			await _measured(_test_stamina_under_loss)
			await _measured(_test_teleport_under_loss)
			await _test_server_cvars_reach_the_client()
			await _test_ambient_cvars_reach_the_client()
			await _test_view_feel_and_packs_reach_the_client()
			await _test_loading_cover()
			await _test_leave()

	await _teardown()
	DotPaths.remove_tree(DATA)

	print("")
	_check(_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered])
	_check(_passed + _failed + 1 == CHECKS,
		"every check ran (%d of %d)" % [_passed + _failed + 1, CHECKS],
		"a section that aborted part-way stops adding checks, and only a total can show it")

	_report()


func _physics_process(delta: float) -> void:
	if not _driving:
		return

	_track_stall()

	# Server truth, as of the last tick the module ran.
	var server_tick := _game.current_tick()
	for label in _clients:
		var session := int(_clients[label]["session"])
		var body := _game.player_for(session)
		if body != null:
			if not _server_track.has(session):
				_server_track[session] = {}
			_server_track[session][server_tick] = body.controller.state.position

	for label in _clients:
		var c: Dictionary = _clients[label]
		var net: DotNetManager = c["net"]
		var bridge: ArenaNetBridge = c["bridge"]
		if net == null or not net.is_running():
			continue

		net.stats.roll()
		var ticks := net.clock.advance(delta)
		for i in range(ticks):
			if not net.clock.is_synced():
				continue
			var tick := net.clock.input_tick() - (ticks - 1 - i)
			var move := _command_a(tick) if label == "A" else _command_b(tick)
			var fire := DotWeaponCommand.new()
			bridge.client_tick(tick, move, fire)
			if bridge.link != null:
				bridge.link.send_input(bridge.encode_input(tick, move, fire))

			if label == "A" and _verbose:
				_w_sent_at[tick] = Time.get_ticks_usec()
			if label == "A":
				var own: ArenaPlayer = (c["game"] as ArenaGame).player_for(int(c["session"]))
				if own != null:
					_predicted[tick] = own.controller.state.position

	if _verbose and _clients.has("A") and _clients["A"].get("bridge") != null:
		var now_q := Time.get_ticks_msec() / 500
		if now_q != _last_half:
			_last_half = now_q
			var sent := ((_clients["A"]["bridge"] as ArenaNetBridge).link.inputs_sent)
			var got := int(_module().bridge.inputs_from.get(_peer_of("A"), 0))
			var throttle_client := -1
			var throttle_server := -1
			var stat := ClassDB.class_get_integer_constant(&"ENetPacketPeer", &"PEER_PACKET_THROTTLE")
			var cpeer: Object = (_clients["A"]["link"] as DotClientLink).multiplayer.multiplayer_peer
			if cpeer != null and cpeer.has_method("get_peer"):
				var p1: Object = cpeer.call("get_peer", 1)
				if p1 != null:
					throttle_client = int(p1.call("get_statistic", stat))
					var names := ["PEER_PACKET_THROTTLE_LIMIT", "PEER_PACKET_THROTTLE_ACCELERATION", "PEER_PACKET_THROTTLE_DECELERATION", "PEER_LAST_ROUND_TRIP_TIME", "PEER_ROUND_TRIP_TIME_VARIANCE", "PEER_LAST_ROUND_TRIP_TIME_VARIANCE"]
					var parts := PackedStringArray()
					for n in names:
						parts.append("%s=%d" % [n.trim_prefix("PEER_"), int(p1.call("get_statistic", ClassDB.class_get_integer_constant(&"ENetPacketPeer", StringName(n))))])
					print("        %s" % " ".join(parts))
			var enet: Object = _server_side.multiplayer.multiplayer_peer.get("enet")
			if enet != null:
				var pa: Object = enet.call("get_peer", _peer_of("A"))
				if pa != null:
					throttle_server = int(pa.call("get_statistic", stat))
			print("      half-second: A sent %d, server got %d, relay up %s; ENet throttle client %d server %d (of 32)" % [
				sent - _last_sent, got - _last_got, _relay.up.received, throttle_client, throttle_server])
			_last_sent = sent
			_last_got = got

	if not _w.is_empty():
		_sample_clock(server_tick)
		# What the server will find for A on the tick it runs next: there, a hole in what
		# arrived (lost, and not covered), or nothing that far yet (late).
		var buffer: DotNetInput.Buffer = _w["buffer"]
		var due := server_tick + 1
		var newest := buffer.newest()
		if _verbose:
			var slack := (newest.tick - server_tick) if newest != null else -99
			_w["slack"] = _w.get("slack", []) + [slack]
			if newest != null and not _w_seen_up.has(newest.tick) and _w_sent_at.has(newest.tick):
				_w_seen_up[newest.tick] = true
				var ms := float(Time.get_ticks_usec() - int(_w_sent_at[newest.tick])) / 1000.0
				_w["up_ms"] = _w.get("up_ms", []) + [ms]
		if buffer.peek(due) == null:
			if newest != null and newest.tick > due:
				_w["holes"] = int(_w.get("holes", 0)) + 1
			else:
				_w["not_yet"] = int(_w.get("not_yet", 0)) + 1


func _process(_delta: float) -> void:
	if not _driving or _w.is_empty():
		return

	var a: Dictionary = _clients["A"]
	var net: DotNetManager = a["net"]
	net.interpolate_frame()
	_sample_render()


## A's clock: its own error, and its real lead over the server it shares a process with.
func _sample_clock(server_tick: int) -> void:
	var net: DotNetManager = _clients["A"]["net"]
	var clock := net.clock
	if not clock.is_synced():
		return

	var target := clock.server_tick() + int(clock.call("_target_lead"))
	var error := target - clock.tick
	# Against what the clock steers to: the server's input-lead report once it has one, which
	# the round trip's lead above is not any more (dot-net's `lead_error`).
	if clock.has_method(&"lead_error"):
		error = roundi(float(clock.call(&"lead_error")))
	var lead := clock.input_tick() - server_tick
	var t := float(Time.get_ticks_msec() - int(_w["started_ms"])) / 1000.0

	_w["clock_samples"].append([t, error, lead])
	if _verbose and int(t * 4.0) != int(_w.get("last_quarter", -1)):
		_w["last_quarter"] = int(t * 4.0)
		print("      t %.2f  error %d  lead %d  rtt %d  jitter %d  target lead %d  est %d  tick %d  server %d" % [
			t, error, lead, int(clock.rtt_ms()), int(clock.jitter_ms()), int(clock.call("_target_lead")),
			clock.server_tick(), clock.tick, server_tick])


## A's drawing of B, against where the server had B at that render time.
func _sample_render() -> void:
	var a: Dictionary = _clients["A"]
	var net: DotNetManager = a["net"]
	var b_session := int(_clients["B"]["session"])
	var seen := (a["game"] as ArenaGame).player_for(b_session)
	var track: Dictionary = _server_track.get(b_session, {})
	if seen == null or track.is_empty() or not net.clock.is_synced():
		return

	var drawn := seen.global_position
	# Exactly what `DotNetManager.interpolate_frame` hands the interpolator: the clock's
	# render alpha and what the receive timeline moved by re-anchoring that the drawing has
	# not followed yet, on a dot-net that has them (headless_feel says why).
	var alpha := clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0)
	var slip := 0.0
	if net.clock.has_method(&"render_alpha"):
		alpha = clampf(float(net.clock.call(&"render_alpha")), -1.0, 2.0)
		slip = float(net.clock.call(&"receive_slip"))
	var render_tick := float(net.clock.received_tick()) + alpha + slip \
		- net.interpolator.delay_ticks()
	var truth: Variant = _truth_at(track, render_tick)
	var now_ms := Time.get_ticks_msec()

	# The render timeline itself: it should advance by a frame's worth of ticks every
	# frame, never go back, and never leap. A timeline that steps back and forth draws a
	# remote player stuttering even when every position it is asked for is right, which
	# the jump measurement below cannot see because the truth moves back with it.
	var last_render: Variant = _w.get("last_render")
	if last_render != null:
		var step := render_tick - float(last_render)
		var expected := float(now_ms - int(_w["last_ms"])) / 1000.0 * float(TICK_RATE)
		if step < -0.01:
			_w["render_back"] = int(_w.get("render_back", 0)) + 1
			_w["render_back_max"] = maxf(float(_w.get("render_back_max", 0.0)), -step)
		_w["render_lurch_max"] = maxf(float(_w.get("render_lurch_max", 0.0)), absf(step - expected))
	_w["last_render"] = render_tick

	if truth != null:
		_w["render_errors"].append(drawn.distance_to(truth))

	var last: Variant = _w.get("last_drawn")
	var last_truth: Variant = _w.get("last_truth")
	if last != null and truth != null and last_truth != null:
		var moved := drawn.distance_to(last)
		var should := (truth as Vector3).distance_to(last_truth)
		_w["max_jump"] = maxf(float(_w["max_jump"]), moved - should)

		# A freeze: the drawing did not move while the truth did, frame after frame.
		if moved < 0.0005 and should > 0.002:
			if int(_w["freeze_since"]) < 0:
				_w["freeze_since"] = int(_w["last_ms"])
			_w["max_freeze_ms"] = maxi(int(_w["max_freeze_ms"]), now_ms - int(_w["freeze_since"]))
			if _verbose and now_ms - int(_w["freeze_since"]) > 150:
				var b_identity := (a["bridge"] as ArenaNetBridge).behaviour_for(b_session)
				var b_track: Variant = net.interpolator.get("_tracks").get(b_identity.identity.net_id) if b_identity != null else null
				print("      FREEZE %d ms: render %.2f received %d server %d newest-B %s applied %d drawn %s truth %s" % [
					now_ms - int(_w["freeze_since"]), render_tick, net.clock.received_tick(), _game.current_tick(),
					str(b_track.newest_tick()) if b_track != null else "-", net.ack_tick(), drawn, truth])
		else:
			_w["freeze_since"] = -1

	_w["last_drawn"] = drawn
	_w["last_truth"] = truth
	_w["last_ms"] = now_ms
	_w["frames"] = int(_w["frames"]) + 1


static func _truth_at(track: Dictionary, tick: float) -> Variant:
	var lo := int(floorf(tick))
	if not track.has(lo) or not track.has(lo + 1):
		return null
	return (track[lo] as Vector3).lerp(track[lo + 1], tick - float(lo))


## A wall run and a wall jump through the last window's 20% loss each way.
##
## [b]Everything a wall move reads next tick rides in `net_flags`[/b], and under real loss
## a client replays more ticks than anywhere else: a run predicted on A and not on the
## server, or a second jump off one wall allowed on one end, is a correction metres long
## and a player yanked off the wall. So A runs dm_box's north wall and jumps off it, from
## commands read off the tick alone, and the two ends have to agree: both run, both jump,
## A's prediction stays within the windows' 5 cm, and the predictor corrects almost
## nothing. A also has to hear each move exactly once (the signals the sounds hang on are
## not emitted in a replay).
func _test_wall_moves() -> void:
	_section("a wall run and a wall jump through 20% loss")

	var a: Dictionary = _clients["A"]
	var net: DotNetManager = a["net"]
	var session := int(a["session"])
	var server_a := _game.player_for(session)
	var own: ArenaPlayer = (a["game"] as ArenaGame).player_for(session)
	if not _check(server_a != null and own != null, "A is on both ends to run a wall with"):
		_done()
		return

	# Stand at the foot of the north wall's clear stretch, a hand off its face, and let the
	# client be told where it is before anything is measured.
	# The wall script dashes in the air to get past the wall run's speed, and the dash is off by
	# default now: turn it on for the server and let RULES carry it to A's prediction.
	var _dash_on := _server.console.set_cvar("arena_dash", "1")
	# The script is the classic run (jump, dash, run, jump off); the auto-start run would start a
	# second one on the first touch.
	var _auto_off := _server.console.set_cvar("arena_wall_run_auto", "0")
	await _until(func() -> bool: return own.controller.tunables.dash_enabled, RELIABLE_SECONDS)
	_wall_idle = true
	_wall_from = -1
	# Twice: the commands A sent before it went idle are still arriving for a few ticks after
	# the first teleport, and carried it up to a metre off the spot (and out of the wall's
	# reach) one run in two.
	for _i in range(2):
		server_a.controller.teleport(Vector3(-7.0, 0.1, -23.6), -90.0, 0.0)
		await _wait_game(0.75)

	var heard := {"runs": 0, "jumps": 0}
	var on_run := func(running: bool) -> void:
		if running:
			heard["runs"] += 1
	var on_jump := func() -> void: heard["jumps"] += 1
	own.controller.wall_run_changed.connect(on_run)
	own.controller.wall_jumped.connect(on_jump)
	var runs := server_a.controller.motor.wall_runs
	var jumps := server_a.controller.motor.wall_jumps
	var replays := int(net.predictor.get("_replays"))
	var corrections := int(net.predictor.get("_corrections_applied"))

	_wall_from = net.clock.input_tick() + 4
	await _wait_game(2.6)

	runs = server_a.controller.motor.wall_runs - runs
	jumps = server_a.controller.motor.wall_jumps - jumps
	replays = int(net.predictor.get("_replays")) - replays
	corrections = int(net.predictor.get("_corrections_applied")) - corrections
	own.controller.wall_run_changed.disconnect(on_run)
	own.controller.wall_jumped.disconnect(on_jump)

	var track: Dictionary = _server_track.get(session, {})
	var diffs: Array[float] = []
	for tick in range(_wall_from, _wall_from + 120):
		if _predicted.has(tick) and track.has(tick):
			diffs.append((_predicted[tick] as Vector3).distance_to(track[tick]))
	diffs.sort()
	var d95 := diffs[int(diffs.size() * 0.95)] if not diffs.is_empty() else -1.0
	var dmax := diffs[diffs.size() - 1] if not diffs.is_empty() else -1.0
	print("    the server's A: %d wall runs, %d wall jumps; A heard %d and %d" % [runs, jumps, heard["runs"], heard["jumps"]])
	print("    A's prediction over the %d ticks of it: p95 %.3f / max %.3f m; %d of %d replays corrected" % [
		diffs.size(), d95, dmax, corrections, replays])

	_check(runs == 1 and jumps == 1, "the server's A ran the wall once and jumped off it once",
		"%d runs, %d jumps" % [runs, jumps])
	_check(heard["runs"] == 1 and heard["jumps"] == 1,
		"and A predicted both, heard once each, never again from a replay",
		"%d runs, %d jumps" % [heard["runs"], heard["jumps"]])
	_check(diffs.size() > _ticks(100) and d95 >= 0.0 and d95 <= 0.05 and dmax <= 1.5,
		"A's prediction of it within 5 cm of the server's for 95% of its ticks",
		"%d ticks, p95 %.3f, max %.3f" % [diffs.size(), d95, dmax])
	_check(corrections <= maxi(3, replays / 10),
		"and corrected in no more than a tenth of the replays (%d of %d)" % [corrections, replays])

	_wall_idle = false
	_wall_from = -1
	var _dash_off := _server.console.set_cvar("arena_dash", "0")
	var _auto_on := _server.console.set_cvar("arena_wall_run_auto", "1")
	_done()


## p95 and max distance between A's prediction and the server's A over input ticks [from, to).
func _prediction_gap(session: int, from: int, to: int) -> Array:
	var track: Dictionary = _server_track.get(session, {})
	var diffs: Array[float] = []
	for tick in range(from, to):
		if _predicted.has(tick) and track.has(tick):
			diffs.append((_predicted[tick] as Vector3).distance_to(track[tick]))
	diffs.sort()
	if diffs.is_empty():
		return [0, -1.0, -1.0]
	return [diffs.size(), diffs[int(diffs.size() * 0.95)], diffs[diffs.size() - 1]]


## [b]Stamina on, sprinting and wall-running through 20% loss.[/b] The arena has no stamina cvar (its
## sprint bit is the dash), so both ends' tunables are set the way a game that turned it on would.
## A drains to empty, waits out the refill delay and drains again, then runs the wall with sprint held.
func _test_stamina_under_loss() -> void:
	_section("sprint stamina and a wall run through 20% loss")

	var a: Dictionary = _clients["A"]
	var net: DotNetManager = a["net"]
	var session := int(a["session"])
	var server_a := _game.player_for(session)
	var own: ArenaPlayer = (a["game"] as ArenaGame).player_for(session)
	if not _check(server_a != null and own != null, "A is on both ends to sprint with"):
		_done()
		return

	for t: DotFpsTunables in [server_a.controller.tunables, own.controller.tunables]:
		t.stamina_enabled = true
		t.stamina_drain = 0.8
		t.stamina_recover = 0.5
		t.stamina_resume_at = 0.3
		t.stamina_exhaust_delay = 0.5
	var _dash_on := _server.console.set_cvar("arena_dash", "1")
	var _auto_off := _server.console.set_cvar("arena_wall_run_auto", "0")
	await _until(func() -> bool: return own.controller.tunables.dash_enabled, RELIABLE_SECONDS)

	var lows := {"min": 1.0, "exhausted": 0, "client_min": 1.0}
	var sample := func() -> void:
		lows["min"] = minf(lows["min"], server_a.controller.state.stamina)
		lows["client_min"] = minf(lows["client_min"], own.controller.state.stamina)
		if server_a.controller.state.stamina_exhausted:
			lows["exhausted"] += 1
	var tick_hook := func() -> void:
		sample.call()
	var replays := int(net.predictor.get("_replays"))
	var corrections := int(net.predictor.get("_corrections_applied"))
	net.predictor.set("_worst_error", 0.0)

	_stam_from = net.clock.input_tick() + 4
	var from := _stam_from
	var until := Engine.get_physics_frames() + 9 * Engine.physics_ticks_per_second
	var wall := Time.get_ticks_msec() + 72000
	while Engine.get_physics_frames() < until and Time.get_ticks_msec() < wall:
		await get_tree().physics_frame
		tick_hook.call()
	var last := net.clock.input_tick()
	_stam_from = -1
	await _wait_game(0.5)
	replays = int(net.predictor.get("_replays")) - replays
	corrections = int(net.predictor.get("_corrections_applied")) - corrections
	var open: Array = _prediction_gap(session, from, last)
	print("    stamina: the server's A fell to %.2f and was exhausted on %d frames; A's copy fell to %.2f" % [
		lows["min"], lows["exhausted"], lows["client_min"]])
	print("    A's prediction over %d ticks: p95 %.3f / max %.3f m; %d of %d replays corrected" % [
		open[0], open[1], open[2], corrections, replays])
	_check(lows["min"] < 0.05 and lows["exhausted"] > 10,
		"the sprint pattern really drained the server's A and exhausted it", "%.2f, %d frames" % [lows["min"], lows["exhausted"]])
	_check(open[0] > 5 * Engine.physics_ticks_per_second and open[1] >= 0.0 and open[1] <= 0.05 and open[2] <= 1.5,
		"A's prediction with stamina draining within 5 cm for 95% of its ticks",
		"%d ticks, p95 %.3f, max %.3f" % [open[0], open[1], open[2]])
	_check(corrections <= maxi(3, replays / 10),
		"and corrected in no more than a tenth of the replays (%d of %d)" % [corrections, replays])

	await _stamina_wall_run(server_a, session, net)

	_wall_hold_sprint = false
	_wall_idle = false
	_wall_from = -1
	for t: DotFpsTunables in [server_a.controller.tunables, own.controller.tunables]:
		t.stamina_enabled = false
	var _dash_off := _server.console.set_cvar("arena_dash", "0")
	var _auto_on := _server.console.set_cvar("arena_wall_run_auto", "1")
	_done()


## The wall script with sprint held through the run, so stamina and the wall-run cooldown both move.
func _stamina_wall_run(server_a: ArenaPlayer, session: int, net: DotNetManager) -> void:
	var replays := 0
	var corrections := 0
	var from := 0
	_wall_idle = true
	_wall_from = -1
	for _i in range(2):
		server_a.controller.teleport(Vector3(-7.0, 0.1, -23.6), -90.0, 0.0)
		await _wait_game(0.75)
	var runs := server_a.controller.motor.wall_runs
	replays = int(net.predictor.get("_replays"))
	corrections = int(net.predictor.get("_corrections_applied"))
	_wall_hold_sprint = true
	_wall_from = net.clock.input_tick() + 4
	from = _wall_from
	await _wait_game(2.6)
	runs = server_a.controller.motor.wall_runs - runs
	replays = int(net.predictor.get("_replays")) - replays
	corrections = int(net.predictor.get("_corrections_applied")) - corrections
	var wall: Array = _prediction_gap(session, from, from + 120)
	print("    wall run with sprint held: %d runs; prediction over %d ticks p95 %.3f / max %.3f m; %d of %d replays corrected" % [
		runs, wall[0], wall[1], wall[2], corrections, replays])
	_check(runs >= 1, "the server's A wall-ran with sprint held", "%d runs" % runs)
	_check(wall[0] > _ticks(100) and wall[1] >= 0.0 and wall[1] <= 0.05 and wall[2] <= 1.5,
		"A's prediction of the wall run with stamina on within 5 cm for 95% of its ticks",
		"%d ticks, p95 %.3f, max %.3f" % [wall[0], wall[1], wall[2]])
	_check(corrections <= maxi(3, replays / 10),
		"and corrected in no more than a tenth of the replays (%d of %d)" % [corrections, replays])


## [b]The server teleports A while it moves.[/b] A hop of 1 m is eased; one of many metres is a snap by
## design (dot-net's reconcile_snap_distance). Either way A must end where the server's A is and
## stay there: one snap at most per teleport, then replays that agree.
func _test_teleport_under_loss() -> void:
	_section("a server teleport of a moving player through 20% loss")

	var a: Dictionary = _clients["A"]
	var net: DotNetManager = a["net"]
	var session := int(a["session"])
	var server_a := _game.player_for(session)
	var own: ArenaPlayer = (a["game"] as ArenaGame).player_for(session)
	if not _check(server_a != null and own != null, "A is on both ends to teleport"):
		_done()
		return

	var snap_distance: float = net.config.reconcile_snap_distance
	var targets: Array[Vector3] = [Vector3(-7.0, 0.1, -23.6), Vector3(21.0, 0.1, -21.0)]
	for i in range(targets.size()):
		var near := i == 0
		await _wait_game(1.0)
		var at: Vector3 = server_a.controller.state.position
		var to: Vector3 = targets[i]
		if near:
			# The first is a hop under the snap distance, from wherever A is: along +X by 1 m.
			to = at + Vector3(1.0, 0.0, 0.0)
		else:
			# The farther target: A's own position differs from the server's by the lead, so one
			# within a metre or two of the snap distance snaps or not by where the circle was.
			var other: Vector3 = targets[0] if to == targets[1] else targets[1]
			if at.distance_to(other) > at.distance_to(to):
				to = other
		var moved := at.distance_to(to)
		var snaps := int(net.predictor.get("_snaps"))
		server_a.controller.teleport(to, server_a.controller.state.yaw, 0.0)
		var input0 := net.clock.input_tick()
		await _wait_game(3.0)
		snaps = int(net.predictor.get("_snaps")) - snaps
		var settled := input0 + _ticks(64)
		var gap: Array = _prediction_gap(session, settled, net.clock.input_tick() - _ticks(8))
		var track: Dictionary = _server_track.get(session, {})
		var end := net.clock.input_tick() - _ticks(8)
		while end > settled and not (_predicted.has(end) and track.has(end)):
			end -= 1
		var shown: float = (_predicted[end] as Vector3).distance_to(track[end]) if _predicted.has(end) and track.has(end) else -1.0
		print("    teleport %.1f m: %d snaps; after settling p95 %.3f / max %.3f m over %d ticks; at the last common tick A is %.3f m from the server's A" % [
			moved, snaps, gap[1], gap[2], gap[0], shown])
		_check(snaps <= (1 if moved > snap_distance else 0),
			"a %.1f m teleport %s" % [moved, "snaps at most once" if moved > snap_distance else "is eased, never snapped"],
			"%d snaps" % snaps)
		_check(gap[0] > _ticks(40) and gap[1] <= 0.05 and gap[2] <= 0.5,
			"and A's prediction is back within 5 cm of the server's A for the ticks after", "%d ticks, p95 %.3f, max %.3f" % [gap[0], gap[1], gap[2]])
		_check(shown >= 0.0 and shown <= 0.05,
			"A ends in the same place as the server's A, tick for tick", "%.3f m apart" % shown)
	_done()


# --- The end ----------------------------------------------------------------

## [b]A seat whose client has not lifted its cover cannot be harmed, and can once it does.[/b]
## C joins and says nothing (a client still loading its level); the server's own damage path
## is then asked to hurt it, by a hazard (the world, attacker 0) and by A's weapon-style hit,
## and must refuse both. C then sends the cover report on the real wire and the same hit lands.
func _test_loading_cover() -> void:
	_section("a client behind its loading cover is not harmed, and is once it lifts")
	var c := await _connect_client("C", _server.config.effective_enet_port(), false)
	_clients["C"] = c
	if not _check(c.get("bridge") != null and int(c["session"]) != 0, "C connects",
			str(c.get("error", ""))):
		_done()
		return

	var id := int(c["session"])
	var roster: DotGameRoster = _module().loading
	var victim: ArenaPlayer = _game.player_for(id)
	_check(victim != null and roster != null and roster.is_loading(id) and not _game.can_be_harmed(id),
		"the server holds C as loading from its spawn", str(roster.describe()) if roster != null else "no roster")

	var type: DotDamageType = _game.combat.damage_type(ArenaContent.DAMAGE_WORLD)
	var before := victim.health.health if victim != null else 0.0
	var world_hit := DotDamage.make(0, id, 10.0, type)
	world_hit.tick = _game.current_tick()
	var _dealt_world := _game.combat.apply_damage(world_hit)
	var hit := DotDamage.make(_peer_session("A"), id, 10.0, type)
	hit.tick = _game.current_tick()
	var _dealt_hit := _game.combat.apply_damage(hit)
	_check(victim != null and victim.health.health == before and victim.is_alive(),
		"a hazard and another player's hit both do nothing to it",
		"%s -> %s" % [before, victim.health.health if victim != null else -1.0])

	# Spawn protection exempts world damage, so the world hit landing after the lift (and not
	# before) is what shows the cover, not protection, was the veto.
	DotGameClient.report_cover(c["link"], false)
	var lifted := await _until(func() -> bool: return not roster.is_loading(id), RELIABLE_SECONDS)
	_check(lifted and _game.can_be_harmed(id), "its cover report crosses the wire and ends the loading state")

	var after_lift := victim.health.health if victim != null else 0.0
	var late_hit := DotDamage.make(0, id, 10.0, type)
	late_hit.tick = _game.current_tick()
	var _dealt_late := _game.combat.apply_damage(late_hit)
	_check(victim != null and victim.health.health < after_lift,
		"and the same hit now lands", "%s -> %s" % [after_lift, victim.health.health if victim != null else -1.0])

	# A bot or a seat the roster does not hold is never loading.
	_check(not roster.is_loading(DUMMY_ID) and _game.can_be_harmed(DUMMY_ID),
		"a seat the roster does not hold is always harmable")

	_game.loading_fn = Callable()
	_check(_game.can_be_harmed(id), "a game with no loading_fn (offline) harms everyone")
	_game.loading_fn = roster.is_loading

	(c["link"] as DotClientLink).disconnect_from_server("done")
	(c["net"] as DotNetManager).stop()
	var gone := await _until(func() -> bool: return _game.player_for(id) == null, RELIABLE_SECONDS)
	_check(gone and not roster.is_loading(id), "C leaves and the roster forgets it")
	_done()


func _peer_session(label: String) -> int:
	return int(_clients[label]["session"])


func _test_leave() -> void:
	_section("B leaves, and A is told once")

	var b: Dictionary = _clients["B"]
	var b_session := int(b["session"])
	var a_game: ArenaGame = _clients["A"]["game"]
	(b["link"] as DotClientLink).disconnect_from_server("done")
	var b_net: DotNetManager = b["net"]
	b_net.stop()

	# RELIABLE_SECONDS: the link is still at the last window's 20% loss. Ten failed a CI
	# release run (v0.1.6) on exactly that tail; the wait ends when A is told.
	var gone := await _until(func() -> bool: return a_game.player_for(b_session) == null, RELIABLE_SECONDS)
	_check(gone, "A's B is gone once the server has seen the disconnect",
		"the server has %d sessions and %s B in its game" % [
			_server.sessions().size(), "still has" if _game.player_for(b_session) != null else "no longer has"])
	_check(_a_saw_added.count(b_session) == 1, "and was never added a second time",
		str(_a_saw_added))
	_done()


func _teardown() -> void:
	_driving = false

	for label in _clients:
		var c: Dictionary = _clients[label]
		var link: DotClientLink = c["link"]
		if link != null and is_instance_valid(link):
			link.disconnect_from_server("test over")

	await get_tree().process_frame

	for label in _clients:
		var side: Node = _clients[label]["side"]
		if side != null and is_instance_valid(side):
			remove_child(side)
			side.queue_free()
	_clients.clear()

	if _relay != null:
		_relay.stop()

	await get_tree().process_frame

	if _server != null and is_instance_valid(_server):
		_server.shutdown("test over")

	if _server_side != null and is_instance_valid(_server_side):
		remove_child(_server_side)
		_server_side.queue_free()

	await get_tree().process_frame


## Hopping pinned against a wall replays the jump timers (coyote, buffer, cooldown): a rewind
## that kept the client's own jumped where the server had not, a correction metres high. So A
## hops into the east wall for six seconds, its prediction stays on the server's, and a rewind
## carries the timers.
func _test_wall_hops() -> void:
	_section("hopping pinned against a wall through 20% loss")

	var a: Dictionary = _clients["A"]
	var net: DotNetManager = a["net"]
	var session := int(a["session"])
	var server_a := _game.player_for(session)
	var own: ArenaPlayer = (a["game"] as ArenaGame).player_for(session)
	if not _check(server_a != null and own != null, "A is on both ends to hop with"):
		_done()
		return

	_wall_idle = true
	_hop_from = -1
	for _i in range(2):
		server_a.controller.teleport(Vector3(21.0, 0.1, -21.0), -90.0, 0.0)
		await _wait_game(0.75)

	var replays := int(net.predictor.get("_replays"))
	var corrections := int(net.predictor.get("_corrections_applied"))

	_hop_from = net.clock.input_tick() + 4
	var worst_before := float(net.predictor.get("_worst_error"))
	net.predictor.set("_worst_error", 0.0)
	await _wait_game(6.0)
	var last := net.clock.input_tick()
	_wall_idle = false
	await _wait_game(0.5)

	replays = int(net.predictor.get("_replays")) - replays
	corrections = int(net.predictor.get("_corrections_applied")) - corrections
	var worst := float(net.predictor.get("_worst_error"))
	net.predictor.set("_worst_error", maxf(worst, worst_before))

	var track: Dictionary = _server_track.get(session, {})
	var diffs: Array[float] = []
	var pinned := 0
	var hops := 0
	var low := true
	for tick in range(_hop_from, last):
		if _predicted.has(tick) and track.has(tick):
			var at: Vector3 = track[tick]
			diffs.append((_predicted[tick] as Vector3).distance_to(at))
			if at.x > 23.0:
				pinned += 1
			if low and at.y > 0.5:
				hops += 1
			low = at.y < 0.1 if not low else low and at.y <= 0.5
	diffs.sort()
	var d95 := diffs[int(diffs.size() * 0.95)] if not diffs.is_empty() else -1.0
	var dmax := diffs[diffs.size() - 1] if not diffs.is_empty() else -1.0
	print("    the server's A left the floor %d times; %d of %d ticks at the wall" % [hops, pinned, diffs.size()])
	print("    A's prediction: p95 %.3f / max %.3f m; %d of %d replays corrected, the worst by %.3f m" % [
		d95, dmax, corrections, replays, worst])

	_check(hops >= 5 and pinned > diffs.size() / 2,
		"the server's A hopped against the wall", "%d hops, %d of %d ticks there" % [hops, pinned, diffs.size()])
	_check(diffs.size() > 4 * Engine.physics_ticks_per_second and d95 >= 0.0 and d95 <= 0.05 and dmax <= 0.5,
		"A's prediction of it within 5 cm for 95% of its ticks, never half a metre off",
		"%d ticks, p95 %.3f, max %.3f" % [diffs.size(), d95, dmax])
	_check(replays >= 30 and corrections <= 1 and worst <= 0.25,
		"and every replay from the middle of a hop lands where the server's A is",
		"%d of %d replays corrected, the worst by %.3f m" % [corrections, replays, worst])

	_check_exact_roundtrip(a, own)

	_hop_from = -1
	_done()


## A's bridge keeps the jump timers, the wall-run cooldown and the stamina across a rewind.
func _check_exact_roundtrip(a: Dictionary, own: ArenaPlayer) -> void:
	# A rewind lands on a tick in the middle of a hop only rarely in six seconds, so the timers'
	# trip through A's own exact copy is checked directly too.
	var behaviour: Object = ((a["bridge"] as Object).get("_behaviours") as Dictionary).get(int(a["session"]))
	var said := own.controller.state.duplicate_state()
	said.time_since_grounded = 0.375
	said.time_since_jump = 1.25
	said.time_since_jump_pressed = 0.5
	var kept: PackedFloat32Array = behaviour.get("net_exact")
	behaviour.call("_pull_exact", said)
	var rewound := said.duplicate_state()
	rewound.time_since_grounded = 0.0
	rewound.time_since_jump = 0.0
	rewound.time_since_jump_pressed = 1000.0
	behaviour.call("_push_exact", rewound)
	behaviour.set("net_exact", kept)
	_check(rewound.time_since_grounded == 0.375 and rewound.time_since_jump == 1.25
			and rewound.time_since_jump_pressed == 0.5,
		"a rewind restores the jump timers, not the client's own",
		"%.3f %.3f %.3f" % [rewound.time_since_grounded, rewound.time_since_jump, rewound.time_since_jump_pressed])

	# Wall-run cooldown and stamina: the same trip, which the quantised copy never carried.
	var drained := own.controller.state.duplicate_state()
	drained.wall_run_cooldown_left = 0.3
	drained.stamina = 0.25
	drained.stamina_exhausted = true
	drained.stamina_delay_left = 0.5
	kept = behaviour.get("net_exact")
	behaviour.call("_pull_exact", drained)
	var fresh := drained.duplicate_state()
	fresh.wall_run_cooldown_left = 0.0
	fresh.stamina = 1.0
	fresh.stamina_exhausted = false
	fresh.stamina_delay_left = 0.0
	behaviour.call("_push_exact", fresh)
	behaviour.set("net_exact", kept)
	_check(is_equal_approx(fresh.wall_run_cooldown_left, 0.3) and is_equal_approx(fresh.stamina, 0.25)
			and fresh.stamina_exhausted and is_equal_approx(fresh.stamina_delay_left, 0.5),
		"a rewind restores the wall-run cooldown and the stamina",
		"%.3f %.3f %s %.3f" % [fresh.wall_run_cooldown_left, fresh.stamina, fresh.stamina_exhausted, fresh.stamina_delay_left])
