extends "headless_lossy_b1.gd"

const SECTIONS := 15
const ShardArgs := preload("shard_args.gd")
## `-- --shard NAME` boots and connects its own server and plays one part, declaring [sections, checks]; `-- --merge LOG...`
## holds that every shard's log is there and that together they entered all SECTIONS.
## Every shard boots and connects: two sections each, which the merge counts once.
const SHARED_SECTIONS := 2
const SHARDS := {"windows": [5, 59], "moves": [6, 37], "rest": [8, 40]}


func _ready() -> void:
	_verbose = "--verbose" in OS.get_cmdline_user_args()
	DotLog.set_level(DotLog.Level.INFO if _verbose else DotLog.Level.ERROR)
	_run.call_deferred()


func _merge() -> void:
	var logs := ShardArgs.merge_logs()
	var missing := ShardArgs.missing(logs)
	_check(logs.size() == SHARDS.size() and missing.is_empty(), "every shard's log is there (%d logs)" % logs.size(), "missing %s" % [missing])
	var entered := ShardArgs.sections_entered(logs)
	_check(entered - SHARED_SECTIONS * (SHARDS.size() - 1) == SECTIONS, "the shards entered every section (%d, boot and connect counted once, of %d)" % [entered, SECTIONS])
	_report_sections(1, 1, 1)


func _run() -> void:
	print("game-fatal-contact: a real server and real ENet clients through real packet loss")
	if ShardArgs.is_merge():
		_merge()
		return
	var shard := ShardArgs.shard()
	DotPaths.remove_tree(DATA)
	Engine.physics_ticks_per_second = TICK_RATE

	if await _boot():
		if await _connect_everyone():
			if shard == "" or shard == "windows":
				for window in WINDOWS:
					await _measured(_play_window.bind(window))
			if shard == "" or shard == "moves":
				await _measured(_test_wall_moves)
				await _measured(_test_wall_hops)
				await _measured(_test_wall_pilot)
				# Right after the wall tests, as in the whole run: played on a fresh connection its first ticks snap the prediction.
				await _measured(_test_stamina_under_loss)
			if shard == "" or shard == "rest":
				await _measured(_test_teleport_under_loss)
				await _test_server_cvars_reach_the_client()
				await _test_ambient_cvars_reach_the_client()
				await _test_view_feel_and_packs_reach_the_client()
				await _test_loading_cover()
				await _test_leave()

	await _teardown()
	DotPaths.remove_tree(DATA)

	if shard == "":
		_report_sections(_entered, _completed, SECTIONS, CHECKS)
	else:
		_report_sections(_entered, _completed, SHARDS[shard][0], SHARDS[shard][1])


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

	_physics_rest(server_tick)


func _physics_rest(server_tick: int) -> void:
	if _clients.has("A") and _clients["A"].get("link") != null:
		var hop_buffer := _module().net.input_buffer_for(int((_clients["A"]["link"] as DotClientLink).multiplayer.get_unique_id()))
		if hop_buffer != null and hop_buffer.starved_count != _hop_starved_seen:
			# One entry per tick the server ran without a command: after a stall several run in one frame.
			for k in range(mini(8, hop_buffer.starved_count - _hop_starved_seen)):
				_hop_starved.append(server_tick - k)
			_hop_starved_seen = hop_buffer.starved_count
	if _hop_from >= 0:
		var predictor: Object = (_clients["A"]["net"] as DotNetManager).predictor
		var applied := int(predictor.get("_corrections_applied"))
		var input_tick := (_clients["A"]["net"] as DotNetManager).clock.input_tick()
		if _hop_clock_seen >= 0 and input_tick != _hop_clock_seen + 1:
			_hop_steps.append(Vector2i(server_tick - _hop_from, input_tick - _hop_clock_seen - 1))
		_hop_clock_seen = input_tick
		if applied != _hop_fix_seen:
			_hop_fixes.append([server_tick, float(predictor.get("_worst_error")), applied - _hop_fix_seen, int(predictor.get("_last_replay_ticks")), input_tick])
			_hop_fix_seen = applied
			predictor.set("_worst_error", 0.0)
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
	# Simulated seconds (physics frames), not wall seconds: a runner that stalls the process must not move
	# which samples count as "settled" (t >= 3) or how many a window takes; the stall itself is what
	# `_measured` looks for.
	var t := float(Engine.get_physics_frames() - int(_w["started_frame"])) / float(Engine.physics_ticks_per_second)

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
	await _moves_told(own)
	_wall_idle = true
	_wall_from = -1
	# Twice: the commands A sent before it went idle are still arriving for a few ticks after
	# the first teleport, and carried it up to a metre off the spot (and out of the wall's
	# reach) one run in two.
	var heard := {"runs": 0, "jumps": 0}
	var on_run: Callable
	var on_jump: Callable
	var runs := 0
	var jumps := 0
	var replays := 0
	var corrections := 0
	# Again when the server ran a tick of the script on another command than A's (see _edge_holes).
	for attempt in range(3):
		_wall_from = -1
		for _i in range(2):
			server_a.controller.teleport(Vector3(-7.0, 0.1, -23.6), -90.0, 0.0)
			await _wait_game(0.75)

		heard["runs"] = 0
		heard["jumps"] = 0
		on_run = func(running: bool) -> void:
			if running:
				heard["runs"] += 1
		on_jump = func() -> void: heard["jumps"] += 1
		own.controller.wall_run_changed.connect(on_run)
		own.controller.wall_jumped.connect(on_jump)
		runs = server_a.controller.motor.wall_runs
		jumps = server_a.controller.motor.wall_jumps
		replays = int(net.predictor.get("_replays"))
		corrections = int(net.predictor.get("_corrections_applied"))

		_wall_from = net.clock.input_tick() + 4
		await _wait_game(2.6)

		runs = server_a.controller.motor.wall_runs - runs
		jumps = server_a.controller.motor.wall_jumps - jumps
		replays = int(net.predictor.get("_replays")) - replays
		corrections = int(net.predictor.get("_corrections_applied")) - corrections
		own.controller.wall_run_changed.disconnect(on_run)
		own.controller.wall_jumped.disconnect(on_jump)
		var holes := _wall_holes(_wall_from)
		if holes.is_empty():
			break
		print("    the server ran ticks %s of the script (from %d) on a command A had changed: %s" % [
			holes, _wall_from, "once more" if attempt < 2 else "three times over"])

	await _test_wall_moves_part2(a, session, heard, runs, jumps, replays, corrections)


func _test_wall_moves_part2(a: Dictionary, session, heard, runs, jumps, replays, corrections) -> void:
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


## Hopping pinned against a wall replays the jump timers (coyote, buffer, cooldown): a rewind that kept
## the client's own jumped where the server had not, a correction metres high. So A hops into the east
## wall for six seconds, its prediction stays on the server's, and a rewind carries the timers.
func _test_wall_hops() -> void:
	await _hop_section("hopping pinned against a wall through 20% loss", false, 6.0)


## The same wall with the netchaos pilot's habits: the view swinging across the wall, strafes and held
## jumps in uneven stretches. A jump against the outer wall mispredicted there (netchaos lossy100 and
## awful400, corrections over a metre), so the prediction stays on the server's for a minute of it.
func _test_wall_pilot() -> void:
	await _hop_section("the pilot's hopping against a wall through 20% loss", true, 45.0)


func _hop_section(title: String, pilot: bool, seconds: float) -> void:
	_section(title)
	_hop_pilot = pilot

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
	_hop_fixes.clear()
	_hop_fix_seen = corrections

	_hop_from = net.clock.input_tick() + 4
	var worst_before := float(net.predictor.get("_worst_error"))
	net.predictor.set("_worst_error", 0.0)
	await _wait_game(seconds)
	var last := net.clock.input_tick()
	_wall_idle = false
	await _wait_game(0.5)

	replays = int(net.predictor.get("_replays")) - replays
	corrections = int(net.predictor.get("_corrections_applied")) - corrections
	# A correction that came down within a snapshot's trip of a hole on a changed command is the
	# hole's: the server did not run what A predicted with. The others are held to the limits.
	var hop_from := _hop_from
	var holes := _edge_holes(hop_from, last, func(t: int) -> DotFpsCommand:
		return _pilot_command(t - hop_from) if pilot else _hop_command(t - hop_from))
	var skip := _excused(holes, net)
	var track: Dictionary = _server_track.get(session, {})
	# ... and only where A's first prediction really was off the server's there: a replay that
	# moves a prediction which was right is the predictor's, hole or no hole.
	var off: Array[int] = []
	for tick: int in skip:
		if _predicted.has(tick) and track.has(tick) and (_predicted[tick] as Vector3).distance_to(track[tick]) > 0.02:
			off.append(tick)
	var worst := float(net.predictor.get("_worst_error"))
	var worst_all := worst
	var excused := 0
	for fix: Array in _hop_fixes:
		worst_all = maxf(worst_all, fix[1])
		var at_tick := int(fix[0])
		var near := func(h: int) -> bool: return h >= at_tick - _down_ticks() - 1 and h <= at_tick + 1
		if holes.any(near) and off.any(near):
			excused += int(fix[2])
		else:
			worst = maxf(worst, fix[1])
	net.predictor.set("_worst_error", maxf(worst_all, worst_before))

	await _hop_section_part2(pilot, a, own, replays, corrections, last, hop_from, holes, skip, track, off, worst, worst_all, excused)


func _hop_section_part2(pilot: bool, a: Dictionary, own: ArenaPlayer, replays, corrections, last, hop_from, holes, skip, track: Dictionary, off: Array[int], worst, worst_all, excused) -> void:
	var diffs: Array[float] = []
	var ticks := 0
	var pinned := 0
	var hops := 0
	var low := true
	for tick in range(_hop_from, last):
		if _predicted.has(tick) and track.has(tick):
			var at: Vector3 = track[tick]
			ticks += 1
			if not skip.has(tick):
				diffs.append((_predicted[tick] as Vector3).distance_to(at))
			if pilot and (_predicted[tick] as Vector3).distance_to(at) > 0.02:
				var cmd := _pilot_command(tick - _hop_from)
				print("      off by %.3f at tick %d (k %d): predicted %s, server %s, jump %s; server starved at %s" % [
					(_predicted[tick] as Vector3).distance_to(at), tick, tick - _hop_from, _predicted[tick], at,
					cmd.buttons & DotFpsCommand.BUTTON_JUMP != 0, _hop_starved.filter(func(t: int) -> bool: return absi(t - tick) < 40)])
			if at.x > 23.0:
				pinned += 1
			if low and at.y > 0.5:
				hops += 1
			low = at.y < 0.1 if not low else low and at.y <= 0.5
	diffs.sort()
	var d95 := diffs[int(diffs.size() * 0.95)] if not diffs.is_empty() else -1.0
	var dmax := diffs[diffs.size() - 1] if not diffs.is_empty() else -1.0
	print("    the server's A left the floor %d times; %d of %d ticks at the wall" % [hops, pinned, ticks])
	print("    A's prediction over %d ticks: p95 %.3f / max %.3f m; %d of %d replays corrected (%d after a hole, the worst of all %.3f m), the worst of the rest by %.3f m" % [
		diffs.size(), d95, dmax, corrections, replays, excused, worst_all, worst])
	corrections -= excused
	if corrections > 0:
		print("      corrections [server tick, metres, count, ticks replayed, input tick] %s from %d; holes %s; all starved %s; clock steps %s" % [
			_hop_fixes, hop_from, holes, _hop_starved.filter(func(t: int) -> bool: return t >= hop_from - 3), _hop_steps.map(func(v: Vector2i) -> String: return "%d:%+d" % [v.x, v.y])])
	_hop_steps.clear()
	_hop_clock_seen = -1

	_check(hops >= 5 and pinned > ticks / 2,
		"the server's A hopped against the wall", "%d hops, %d of %d ticks there" % [hops, pinned, ticks])
	_check(diffs.size() > 4 * Engine.physics_ticks_per_second and d95 >= 0.0 and d95 <= 0.05 and dmax <= 0.5,
		"A's prediction of it within 5 cm for 95% of its ticks, never half a metre off",
		"%d ticks, p95 %.3f, max %.3f" % [diffs.size(), d95, dmax])
	_check(replays >= 30 and corrections <= (4 if pilot else 1) and worst <= 0.25,
		"and every replay from the middle of a hop lands where the server's A is",
		"%d of %d replays corrected, the worst by %.3f m" % [corrections, replays, worst])

	_check_exact_roundtrip(a, own)

	_hop_from = -1
	_hop_pilot = false
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
