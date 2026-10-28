extends "lossy_base.gd"
## The scripted drivers and the measured window of headless_lossy, split out for the file size gate.


## A runs forward, strafes left and right, and turns: a constant input is not an input.
func _command_a(tick: int) -> DotFpsCommand:
	if _wall_idle:
		if _hop_from >= 0:
			return _hop_command(tick - _hop_from)
		return _wall_command(tick - _wall_from if _wall_from >= 0 else -1)
	var move := DotFpsCommand.new()
	var strafe := 1.0 if (tick / 24) % 2 == 0 else -1.0
	move.move = Vector2(strafe * 0.6, 0.8)
	move.yaw = fmod(float(tick) * 1.4, 360.0)
	move.pitch = 0.0
	if _stam_from >= 0 and tick >= _stam_from:
		var k := (tick - _stam_from) % _ticks(200)
		if k < _ticks(120):
			move.buttons |= DotFpsCommand.BUTTON_SPRINT
		if k % _ticks(70) == 0:
			move.buttons |= DotFpsCommand.BUTTON_JUMP
	return move


## A's wall script on dm_box's north wall, by ticks into it: run east along the wall, jump,
## dash in the air (15 m/s along the wall, past `wall_run_min_speed`) and run the wall,
## jump off it 35 ticks later, then hold still once down. Read off the tick alone, so the
## server runs exactly the commands A predicted with. Before it starts (negative), stand.
func _wall_command(k: int) -> DotFpsCommand:
	var move := DotFpsCommand.new()
	move.yaw = -90.0
	if k < 0 or k > 120:
		return move
	move.move = Vector2(0.0, 1.0)
	if k == 12 or k == 50:
		move.buttons |= DotFpsCommand.BUTTON_JUMP
	if k == 15 or (_wall_hold_sprint and k > 15 and k < 100):
		move.buttons |= DotFpsCommand.BUTTON_SPRINT
	return move


## A holds forward into dm_box's east wall and hops, jump held and let go in uneven stretches.
## Read off the tick alone, so the server runs the commands A predicted with.
func _hop_command(k: int) -> DotFpsCommand:
	var move := DotFpsCommand.new()
	move.yaw = -90.0
	if k < 0:
		return move
	move.move = Vector2(0.0, 1.0)
	var at := 0
	var i := 0
	while true:
		var hold := 20 + (i * 7) % 30
		var rest := 5 + (i * 3) % 9
		if k < at + hold:
			move.buttons |= DotFpsCommand.BUTTON_JUMP
			return move
		if k < at + hold + rest:
			return move
		at += hold + rest
		i += 1
	return move


## B runs a circle: forward, turning at a steady rate, so its motion is smooth and known.
func _command_b(tick: int) -> DotFpsCommand:
	var move := DotFpsCommand.new()
	move.move = Vector2(0.0, 1.0)
	move.yaw = fmod(float(tick) * 1.0, 360.0)
	return move


func _begin_window() -> void:
	var a: Dictionary = _clients["A"]
	var net: DotNetManager = a["net"]
	var server_net: DotNetManager = _module().net
	var buffer := server_net.input_buffer_for(int((a["link"] as DotClientLink).multiplayer.get_unique_id()))

	_relay.reset_counts()
	net.interpolator.reset_counts()

	_w = {
		"started_ms": Time.get_ticks_msec(),
		"clock_samples": [],
		"render_errors": [],
		"max_jump": 0.0,
		"max_freeze_ms": 0,
		"freeze_since": -1,
		"last_drawn": null,
		"last_truth": null,
		"last_ms": Time.get_ticks_msec(),
		"frames": 0,
		"stats_lost": net.stats.snapshots_lost,
		"stats_received": net.stats.snapshots_received,
		"replays": int(net.predictor.get("_replays")),
		"corrections": int(net.predictor.get("_corrections_applied")),
		"snaps": int(net.clock.get("_snap_count")),
		"catch_ups": int(net.clock.get("_catch_up_count")),
		"starved": buffer.starved_count,
		"late": buffer.late_count,
		"first_tick": net.clock.input_tick(),
		"buffer": buffer,
		"inputs_sent": (a["bridge"] as ArenaNetBridge).link.inputs_sent,
		"b_inputs_sent": (_clients["B"]["bridge"] as ArenaNetBridge).link.inputs_sent,
		"a_inputs_got": int(_module().bridge.inputs_from.get(_peer_of("A"), 0)),
		"b_inputs_got": int(_module().bridge.inputs_from.get(_peer_of("B"), 0)),
		"inputs_received": _module().bridge.link.inputs_received,
		"snapshots_received": (a["bridge"] as ArenaNetBridge).link.snapshots_received,
	}


func _play_window(window: Array) -> void:
	var title := String(window[0])
	var loss := float(window[1])
	var seconds := float(window[4])
	_section("%s each way, %d..%d ms, %d seconds" % [
		title, int(window[2] - window[3]), int(window[2] + window[3]), int(seconds)])

	_relay.set_impairment(true, loss, float(window[2]), float(window[3]))
	_relay.set_impairment(false, loss, float(window[2]), float(window[3]))

	# Two seconds to settle at the new rate before anything is measured.
	await _until(func() -> bool: return false, 2.0)
	_begin_window()

	var notices_from := _sent_notices.size()
	var chat_from := _sent_chat.size()
	var kills_from := _sent_kills.size()
	var a_chat_from := _sent_a_chat.size()
	var got_notices_from := _got_notices.size()
	var got_chat_from := _got_chat.size()
	var got_kills_from := _got_kills.size()
	var got_a_chat_from := _got_a_chat.size()

	var started := Time.get_ticks_msec()
	var next_notice := started
	var next_chat := started + 150
	var next_a_chat := started + 300
	var next_slay := started + 500
	var link_a: DotClientLink = _clients["A"]["link"]

	while Time.get_ticks_msec() - started < int(seconds * 1000.0):
		var now := Time.get_ticks_msec()
		if now >= next_notice:
			var text := "seq-%d" % _sent_notices.size()
			_sent_notices.append(text)
			_module().bridge.send_event(0, ArenaEvents.Kind.NOTICE, ArenaEvents.write_notice(text))
			next_notice += 250
		if now >= next_chat:
			var line := "chat-%d" % _sent_chat.size()
			_sent_chat.append(line)
			_server.chat.broadcast_system(line)
			next_chat += 400
		if now >= next_a_chat:
			var said := "a-says-%d" % _sent_a_chat.size()
			_sent_a_chat.append(said)
			link_a.send_chat(said)
			next_a_chat += 3500
		if now >= next_slay:
			var dummy := _game.player_for(DUMMY_ID)
			if dummy != null and dummy.is_alive():
				ArenaModTools.slay(_game, StringName(str(DUMMY_ID)))
				next_slay += 900
			elif dummy != null:
				_game.respawn_player(DUMMY_ID)
				next_slay += 300
		await get_tree().process_frame

	# Everything sent in the window gets RELIABLE_SECONDS to land; the wait ends the moment
	# it has. A drop fails "still connected" above. Twenty failed one run in twenty
	# (2026-10-09). ENet doubles a reliable command's resend timeout every time it goes
	# unacknowledged, and a resend fails if the data OR its acknowledgement is lost: 36% a try at 20% each
	# way, not 20%. Five failures in a row, about one command in a hundred and seventy (a
	# window sends a few hundred), is 31 resend timeouts of ~230 ms, seven seconds; everything
	# behind it on the channel waits too, because ENet delivers a channel in order. Six
	# seconds was written for 20% a try and failed a run in eight on exactly that (2026-10-09).
	# Late is allowed; lost, duplicated or reordered is not, and that is what is checked.
	await _until(func() -> bool:
		return _got_notices.size() - got_notices_from >= _sent_notices.size() - notices_from \
			and _got_kills.size() - got_kills_from >= _sent_kills.size() - kills_from \
			and _got_chat.size() - got_chat_from >= _sent_chat.size() - chat_from \
			and _got_a_chat.size() - got_a_chat_from >= _sent_a_chat.size() - a_chat_from,
		RELIABLE_SECONDS)

	_measure_window(title, loss,
		_sent_notices.slice(notices_from), _got_notices.slice(got_notices_from),
		_sent_kills.slice(kills_from), _got_kills.slice(got_kills_from),
		_sent_chat.slice(chat_from), _got_chat.slice(got_chat_from),
		_sent_a_chat.slice(a_chat_from), _got_a_chat.slice(got_a_chat_from))
	_w = {}
	_done()


func _measure_window(
	title: String, loss: float,
	sent_notices: Array, got_notices: Array,
	sent_kills: Array, got_kills: Array,
	sent_chat: Array, got_chat: Array,
	sent_a_chat: Array, got_a_chat: Array
) -> void:
	var a: Dictionary = _clients["A"]
	var net: DotNetManager = a["net"]
	var link: DotClientLink = a["link"]
	var said: Dictionary = _relay.describe()

	# --- connection ---
	# Both ends. A client whose server has dropped it does not find out until its own ENet
	# gives up, so asking only the client passed a window in which the server had
	# disconnected A and A had heard nothing for seconds (2026-10-09: ENet's own peer
	# timeouts, now dot-core's DotTransportENet.peer_timeout_*).
	var a_session := int(a["session"])
	var on_server := _game.player_for(a_session) != null
	_check(link.phase == DotClientLink.Phase.PLAYING and String(a["gone"][0]) == "" and on_server,
		"%s: A is still connected and playing, on both ends" % title,
		"gone: '%s', on the server: %s" % [a["gone"][0], on_server])
	var injected_down := float(_relay.down.loss_ratio())
	var injected_up := float(_relay.up.loss_ratio())
	_check(absf(injected_down - loss) < 0.06 and absf(injected_up - loss) < 0.06,
		"%s: the relay injected it (down %.3f, up %.3f)" % [title, injected_down, injected_up])

	# --- the clock ---
	var samples: Array = _w["clock_samples"]
	var settled_errors: Array[int] = []
	var leads: Array[int] = []
	for s in samples:
		if float(s[0]) >= 3.0:
			settled_errors.append(int(s[1]))
		leads.append(int(s[2]))
	var worst_error := 0
	for e in settled_errors:
		worst_error = maxi(worst_error, absi(e))
	var min_lead := 1 << 30
	var max_lead := -(1 << 30)
	for l in leads:
		min_lead = mini(min_lead, l)
		max_lead = maxi(max_lead, l)
	var snaps := int(net.clock.get("_snap_count")) - int(_w["snaps"])
	var catch_ups := int(net.clock.get("_catch_up_count")) - int(_w["catch_ups"])
	var buffer: DotNetInput.Buffer = _w["buffer"]
	var late := buffer.late_count - int(_w["late"])
	var starved := buffer.starved_count - int(_w["starved"])
	var ticks_run := net.clock.input_tick() - int(_w["first_tick"])
	print("    clock: settled error within +-%d ticks over %d samples; real lead %d..%d ticks; %d snaps, %d catch-ups; rtt %d ms, jitter %d ms" % [
		worst_error, settled_errors.size(), min_lead, max_lead, snaps, catch_ups,
		int(net.clock.rtt_ms()), int(net.clock.jitter_ms())])
	if net.clock.has_method(&"describe_lead"):
		print("    input lead: %s" % net.clock.call(&"describe_lead"))
	print("    server's input buffer for A: %d late, %d starved of %d ticks (%.1f%%)" % [
		late, starved, ticks_run, 100.0 * float(starved) / float(maxi(1, ticks_run))])
	print("    before each server tick, A's input for it was: a hole %d times, not there yet %d times" % [
		int(_w.get("holes", 0)), int(_w.get("not_yet", 0))])
	if _verbose:
		var hist := {}
		for v in _w.get("slack", []):
			hist[v] = int(hist.get(v, 0)) + 1
		var keys := hist.keys()
		keys.sort()
		var parts := PackedStringArray()
		for k in keys:
			parts.append("%d:%d" % [k, hist[k]])
		print("    newest buffered input minus server tick, per physics frame: %s" % " ".join(parts))
		var sent_ticks: Array = _w_sent_at.keys()
		sent_ticks.sort()
		var skipped := 0
		for i in range(1, sent_ticks.size()):
			skipped += maxi(0, int(sent_ticks[i]) - int(sent_ticks[i - 1]) - 1)
		print("    A's input ticks sent so far: %d, %d skipped over" % [sent_ticks.size(), skipped])
		var up: Array = _w.get("up_ms", [])
		up.sort()
		if not up.is_empty():
			print("    A's input, sent to first seen in the server's buffer: p10 %.0f p50 %.0f p90 %.0f max %.0f ms (%d)" % [
				up[int(up.size() * 0.1)], up[up.size() / 2], up[int(up.size() * 0.9)], up[up.size() - 1], up.size()])
		var down: Array = _w.get("down_ticks", [])
		down.sort()
		if not down.is_empty():
			print("    a snapshot's age on arrival at A, in server ticks: p10 %d p50 %d p90 %d max %d (%d)" % [
				down[int(down.size() * 0.1)], down[down.size() / 2], down[int(down.size() * 0.9)], down[down.size() - 1], down.size()])
	var a_link := (a["bridge"] as ArenaNetBridge).link
	var b_sent := (_clients["B"]["bridge"] as ArenaNetBridge).link.inputs_sent - int(_w["b_inputs_sent"])
	print("    per peer at the server: A %d of %d, B %d of %d" % [
		int(_module().bridge.inputs_from.get(_peer_of("A"), 0)) - int(_w["a_inputs_got"]),
		a_link.inputs_sent - int(_w["inputs_sent"]),
		int(_module().bridge.inputs_from.get(_peer_of("B"), 0)) - int(_w["b_inputs_got"]), b_sent])
	print("    the relay: up %d datagrams, %d passed on; down %d, %d passed on; A's link took %d snapshots" % [
		_relay.up.received, _relay.up.delivered, _relay.down.received, _relay.down.delivered,
		a_link.snapshots_received - int(_w["snapshots_received"])])
	_check(worst_error <= 3 and snaps == 0,
		"%s: A's clock error settles within 3 ticks and never snaps" % title,
		"+-%d, %d snaps" % [worst_error, snaps])
	# The number every input fix here moved: the share of the server's ticks that had this
	# client's command when they ran. Without the resent copies a lost packet is a tick on a
	# guess (20% at 20% loss); without ENet's own round trip the first seconds are late; with
	# ENet's throttle left as it is the first five are mostly dropped before the wire; and
	# without a poll in the flight time a steady link is late on every tick.
	var in_time := 1.0 - float(starved) / float(maxi(1, ticks_run))
	_check(in_time >= 0.97 and late <= ticks_run / 100,
		"%s: the server had A's command for %.1f%% of its ticks, %d late" % [title, in_time * 100.0, late],
		"real lead %d..%d ticks" % [min_lead, max_lead])

	# --- A's drawing of B ---
	var errors: Array = _w["render_errors"]
	errors.sort()
	var p50 := float(errors[errors.size() / 2]) if not errors.is_empty() else -1.0
	var p95 := float(errors[int(errors.size() * 0.95)]) if not errors.is_empty() else -1.0
	var worst := float(errors[errors.size() - 1]) if not errors.is_empty() else -1.0
	var extrapolated := net.interpolator.extrapolation_count()
	var sampled := net.interpolator.sample_count()
	print("    A draws B: %d frames, off the server's B at the render time by p50 %.3f / p95 %.3f / max %.3f m; longest freeze %d ms; largest jump past B's own motion %.3f m; %d of %d samples extrapolated, %d stalls; delay %.1f ticks" % [
		int(_w["frames"]), p50, p95, worst, int(_w["max_freeze_ms"]), float(_w["max_jump"]),
		extrapolated, sampled, net.interpolator.stall_count(), net.interpolator.delay_ticks()])
	print("    A's render timeline: went back %d times (at most %.2f ticks); the largest step off a frame's worth was %.2f ticks" % [
		int(_w.get("render_back", 0)), float(_w.get("render_back_max", 0.0)), float(_w.get("render_lurch_max", 0.0))])
	_check(int(_w["frames"]) > 100, "%s: A drew B, frame after frame" % title, "%d" % int(_w["frames"]))
	_check(int(_w["max_freeze_ms"]) <= 100,
		"%s: B never freezes on A's screen while moving (longest %d ms)" % [title, int(_w["max_freeze_ms"])])
	_check(float(_w["max_jump"]) <= 0.5,
		"%s: and never jumps more than half a metre past its own motion (%.3f m)" % [title, float(_w["max_jump"])])
	_check(p95 >= 0.0 and p95 <= 0.1,
		"%s: drawn within 10 cm of where the server had B at that time, 95%% of frames (%.3f m)" % [title, p95])
	_check(int(_w.get("render_back", 0)) <= 2 and float(_w.get("render_back_max", 0.0)) <= 1.05,
		"%s: the render timeline goes back at most twice, a tick at most (%d, %.2f)" % [
			title, int(_w.get("render_back", 0)), float(_w.get("render_back_max", 0.0))])
	var share := float(extrapolated) / float(maxi(1, sampled))
	_check(sampled > 0 and share <= 0.25,
		"%s: at least three frames in four drawn between two snapshots (%.0f%% extrapolated)" % [title, share * 100.0])

	# --- A's own prediction ---
	var track: Dictionary = _server_track.get(int(a["session"]), {})
	var diffs: Array[float] = []
	for tick in _predicted:
		if int(tick) >= int(_w["first_tick"]) and track.has(tick):
			diffs.append((_predicted[tick] as Vector3).distance_to(track[tick]))
	diffs.sort()
	var d50 := diffs[diffs.size() / 2] if not diffs.is_empty() else -1.0
	var d95 := diffs[int(diffs.size() * 0.95)] if not diffs.is_empty() else -1.0
	var dmax := diffs[diffs.size() - 1] if not diffs.is_empty() else -1.0
	var replays := int(net.predictor.get("_replays")) - int(_w["replays"])
	var corrections := int(net.predictor.get("_corrections_applied")) - int(_w["corrections"])
	var rate := float(corrections) / float(maxi(1, replays))
	print("    A's prediction against the server's A, %d ticks: p50 %.3f / p95 %.3f / max %.3f m; %d of %d replays corrected (%.1f%%), worst ever %s" % [
		diffs.size(), d50, d95, dmax, corrections, replays, rate * 100.0,
		net.predictor.describe()["worst_error"]])
	_check(diffs.size() > _ticks(200), "%s: A predicted, and the server ran the same ticks" % title,
		"%d" % diffs.size())
	_check(d95 >= 0.0 and d95 <= 0.05 and dmax <= 1.5 and rate <= 0.1,
		"%s: A's prediction within 5 cm of the server's for 95%% of ticks, corrected in %.0f%% of replays" % [title, rate * 100.0],
		"p95 %.3f, max %.3f" % [d95, dmax])

	# --- what DotNetStats says ---
	var lost := net.stats.snapshots_lost - int(_w["stats_lost"])
	var received := net.stats.snapshots_received - int(_w["stats_received"])
	var reported := float(lost) / float(maxi(1, lost + received))
	print("    DotNetStats: %d snapshots received, %d inferred lost: %.3f, against %.3f injected" % [
		received, lost, reported, injected_down])
	_check(absf(reported - injected_down) <= 0.05,
		"%s: DotNetStats reports a loss near the injected one (%.3f vs %.3f)" % [title, reported, injected_down])

	# --- reliable streams ---
	_check(not sent_notices.is_empty() and got_notices == sent_notices,
		"%s: %d numbered notices, each exactly once and in order" % [title, sent_notices.size()],
		"" if got_notices == sent_notices else "got %d: %s" % [got_notices.size(), _missing(sent_notices, got_notices)])
	_check(not sent_kills.is_empty() and got_kills == sent_kills,
		"%s: %d kills on the feed, each exactly once and in order" % [title, sent_kills.size()],
		"" if got_kills == sent_kills else "sent %s got %s" % [sent_kills, got_kills])
	_check(not sent_chat.is_empty() and got_chat == sent_chat
			and not sent_a_chat.is_empty() and got_a_chat == sent_a_chat,
		"%s: %d chat lines down and %d of A's own up and back, each exactly once and in order" % [
			title, sent_chat.size(), sent_a_chat.size()],
		"" if got_chat == sent_chat and got_a_chat == sent_a_chat
			else "down %d/%d, A's %s vs %s" % [got_chat.size(), sent_chat.size(), got_a_chat, sent_a_chat])

	if _verbose:
		print("    relay: %s" % said)


## What [param got] lacks of [param sent], has twice, or has out of order, in a line.
static func _missing(sent: Array, got: Array) -> String:
	var lacks: Array = []
	for item in sent:
		if not got.has(item):
			lacks.append(item)
	var twice: Array = []
	for item in got:
		if got.count(item) > 1 and not twice.has(item):
			twice.append(item)
	return "missing %s, twice %s, first %s, last %s" % [lacks, twice,
		got[0] if not got.is_empty() else "-", got[got.size() - 1] if not got.is_empty() else "-"]
