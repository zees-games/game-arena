extends Node

const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

## One real arena client of `tools/netchaos.sh`: the whole `arena.tscn` client over ENet to a
## remote server, a pilot that runs, strafes, jumps and shoots in the active window, and a JSON
## report of what it saw. A dropped link is rebuilt (a new session) and counted.
##
## godot --headless --path . res://tools/netchaos_client.tscn -- --server HOST:PORT --name A \
##     --start-at UNIX --active 30 --settle 6 --out report.json
##
## `--start-at` is on this machine's clock: every client waits in the game until then, so the
## active windows overlap and the settle comes after all of them.

const READY_SECONDS := 45.0
## Seconds a client stays connected after its report, so every report sees the full roster.
const LINGER_SEC := 3.0

var _server := "127.0.0.1:27210"
var _name := "A"
var _start_at := 0.0
var _active := 30.0
var _settle := 6.0
var _out := "netchaos_report.json"
var _fire := true

var _link: DotClientLink = null
var _client: Node = null
var _pilot: Node = null
var _dropped := false
var _gone_reason := ""

var _sessions := 0
var _disconnects: Array = []
var _join_seconds: Array = []
var _rejoin_seconds: Array = []
var _timeline: Array = []
var _corrections := 0
var _replays := 0
var _worst_error := 0.0
var _max_gap := 0.0
var _gap_clock := 0.0
var _last_received := -1
var _never_ready := false
var _gate_open := true
var _errors: PackedStringArray = []
var _sess_base := {"corrections": 0, "replays": 0}
var _spikes: Array = []
var _roster_seen: Dictionary = {}


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--server": _server = args[i + 1]
			"--name": _name = args[i + 1]
			"--start-at": _start_at = float(args[i + 1])
			"--active": _active = float(args[i + 1])
			"--settle": _settle = float(args[i + 1])
			"--out": _out = args[i + 1]
			"--fire": _fire = args[i + 1] != "0"
	name = "Netchaos"  # RPC paths must match the server's root name
	DotLog.set_level(DotLog.Level.WARN)
	var _scratch := ArenaPresentation.use_scratch_settings("netchaos_client_" + _name)
	_run.call_deferred()


func _now() -> float:
	return Time.get_unix_time_from_system()


func _join() -> bool:
	_sessions += 1
	_dropped = false
	_gone_reason = ""
	var began := _now()
	_link = DotClientLink.new()
	_link.name = "Server"
	_link.player_name = "nc_" + _name
	_link.transport_preference = "udp"
	_link.udp_address = _server
	add_child(_link)
	_link.disconnected.connect(func(reason: String) -> void:
		_dropped = true
		_gone_reason = reason)
	var spawned := [false]
	_link.spawned.connect(func() -> void: spawned[0] = true)
	_link.connect_to_server(_server)
	while not (spawned[0] or _link.is_playing()) and not _dropped and _now() - began < 40.0:
		await get_tree().create_timer(0.1).timeout
	if not (spawned[0] or _link.is_playing()):
		_errors.append("session %d never joined: %s" % [_sessions, _gone_reason])
		return false
	# After the join, as net_probe does: building the scene first or on game_changed never opened
	# the Arena link here. The server's first calls land before it exists: a few engine errors
	# the evaluator counts as the join race.
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("mouse_capture_override", true)
	add_child(_client)
	while _now() - began < READY_SECONDS and not _dropped:
		var cnet: DotNetManager = _client.get("net")
		if cnet != null and cnet.clock.is_synced() and _client.get("player") != null:
			_join_seconds.append(_now() - began)
			_sess_base = {"corrections": 0, "replays": 0}
			_last_received = -1
			return true
		await get_tree().create_timer(0.1).timeout
	_errors.append("session %d not ready after %.0f s (gate open %s)" % [_sessions, _now() - began, _gate_is_open()])
	return false


## The spawn snap on join is not a misprediction; judge corrections from the moment play starts.
func _forget_join_snap() -> void:
	var cnet: DotNetManager = _client.get("net")
	if cnet == null or cnet.predictor == null:
		return
	cnet.predictor.set("_worst_error", 0.0)
	_worst_error = 0.0
	var p := _prediction()
	_corrections = 0
	_replays = 0
	_sess_base = {"corrections": int(p.get("corrections", 0)), "replays": int(p.get("replays", 0))}


func _gate_is_open() -> bool:
	var g = _client.get("gate") if _client != null else null
	return g == null or g.is_open()


func _teardown() -> void:
	_fold_prediction()
	if _pilot != null:
		_pilot.queue_free()
		_pilot = null
	if _client != null:
		_client.queue_free()
	if _link != null:
		_link.queue_free()
	_client = null
	_link = null
	await get_tree().process_frame
	await get_tree().process_frame


func _fold_prediction() -> void:
	var p := _prediction()
	_corrections += int(p.get("corrections", 0)) - _sess_base["corrections"]
	_replays += int(p.get("replays", 0)) - _sess_base["replays"]
	_worst_error = maxf(_worst_error, float(str(p.get("worst_error", "0")).trim_suffix(" m")))
	_sess_base = {"corrections": int(p.get("corrections", 0)), "replays": int(p.get("replays", 0))}


func _prediction() -> Dictionary:
	if _client == null:
		return {}
	var cnet: DotNetManager = _client.get("net")
	if cnet == null or cnet.predictor == null:
		return {}
	return cnet.predictor.describe()


func _sample() -> void:
	var cnet: DotNetManager = _client.get("net")
	if cnet == null:
		return
	var p := _prediction()
	_worst_error = maxf(_worst_error, float(str(p.get("worst_error", "0")).trim_suffix(" m")))
	_timeline.append({
		"t": snappedf(_now() - _start_at, 0.1),
		"rtt_p50": snappedf(cnet.stats.rtt_percentile(0.5), 0.1),
		"rtt_p95": snappedf(cnet.stats.rtt_percentile(0.95), 0.1),
		"snap_lost": cnet.stats.snapshots_lost,
		"snap_recv": cnet.stats.snapshots_received,
		"out_of_order": cnet.stats.out_of_order,
		"corrections": _corrections + int(p.get("corrections", 0)) - _sess_base["corrections"],
		"worst_error": _worst_error,
		"gap_max": snappedf(_max_gap, 0.01),
		"fps": Engine.get_frames_per_second(),
	})


## Each correction over SPIKE_M with what the link and clock looked like, so a spike in the
## report says whether it was a respawn, a blackout or a bump. Reads and clears the predictor's
## worst each frame, which keeps [member _worst_error] the run's maximum.
const SPIKE_M := 0.5


func _watch_corrections() -> void:
	var cnet: DotNetManager = _client.get("net") if _client != null else null
	if cnet == null or cnet.predictor == null:
		return
	var e: float = cnet.predictor.get("_worst_error")
	if e <= 0.0:
		return
	cnet.predictor.set("_worst_error", 0.0)
	_worst_error = maxf(_worst_error, e)
	if e < SPIKE_M or _spikes.size() >= 40 or _now() < _start_at:
		return
	var p := cnet.predictor.describe()
	var c := cnet.clock.describe()
	var player = _client.get("player")
	_spikes.append({"t": snappedf(_now() - _start_at, 0.01), "error_m": snappedf(e, 0.001),
		"replayed": p.get("last_replay_ticks"), "snaps": p.get("snaps"), "alive": player != null and player.is_alive(),
		"tick": c.get("tick"), "received_tick": c.get("received_tick"), "lead": c.get("lead"),
		"catch_ups": c.get("catch_ups"), "clock_snaps": c.get("snaps"), "lost_ms": c.get("lost_ms"),
		"snap_lost": cnet.stats.snapshots_lost, "out_of_order": cnet.stats.out_of_order,
		"gap_s": snappedf(_gap_clock, 0.01), "last_mismatch": str(p.get("last_mismatch"))})


func _watch_roster() -> void:
	var game = _client.get("game") if _client != null else null
	if game == null:
		return
	for who: ArenaPlayer in game.players():
		if not _roster_seen.has(who.display_name):
			_roster_seen[who.display_name] = snappedf(_now() - _start_at, 0.01)


func _watch_gap(delta: float) -> void:
	if _client == null:
		return
	var cnet: DotNetManager = _client.get("net")
	if cnet == null:
		return
	var received: int = cnet.stats.snapshots_received
	if received != _last_received:
		_last_received = received
		_gap_clock = 0.0
	else:
		_gap_clock += delta
		_max_gap = maxf(_max_gap, _gap_clock)


func _wait_until(unix: float) -> void:
	var next_sample := 0.0
	var last := Time.get_ticks_usec()
	while _now() < unix and not _dropped:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		_watch_gap((now - last) / 1e6)
		_watch_corrections()
		_watch_roster()
		last = now
		next_sample -= (now - last) / 1e6 + get_process_delta_time()
		if next_sample <= 0.0:
			next_sample = 1.0
			_sample()


func _run() -> void:
	var finish := _start_at + _active + _settle
	var t0 := _now()
	var ok := await _join()
	if not ok:
		_never_ready = true
	var drops_started := 0.0
	while ok and _now() < finish:
		if _now() >= _start_at and _pilot == null and _now() < _start_at + _active:
			_forget_join_snap()
			_pilot = Pilot.new()
			_pilot.fire = _fire
			_client.add_child(_pilot)
		if _pilot != null and _now() >= _start_at + _active:
			_pilot.queue_free()
			_pilot = null
		await _wait_until(minf(_now() + 1.0, finish))
		if _dropped:
			drops_started = _now()
			_disconnects.append({"at": snappedf(drops_started - _start_at, 0.1), "reason": _gone_reason})
			await _teardown()
			var rejoined := false
			for attempt in range(5):
				if await _join():
					rejoined = true
					break
				await _teardown()
			if not rejoined:
				_never_ready = true
				ok = false
			else:
				_rejoin_seconds.append(snappedf(_now() - drops_started, 0.1))
	_report(t0)
	# Clients finish up to a few hundred ms apart; leaving at once had the first one's LEAVE
	# reach the others before their own report, which read as a lost roster entry.
	if ok:
		await get_tree().create_timer(LINGER_SEC).timeout
	get_tree().quit()


func _report(t0: float) -> void:
	var out := {"name": _name, "server": _server, "unix": _now(), "start_at": _start_at,
		"connected": not _never_ready and _client != null, "sessions": _sessions,
		"join_seconds": _join_seconds, "disconnects": _disconnects, "rejoin_seconds": _rejoin_seconds,
		"errors": _errors, "timeline": _timeline, "spikes": _spikes, "roster_seen": _roster_seen}
	if _client != null:
		_fold_prediction()
		var cnet: DotNetManager = _client.get("net")
		var player = _client.get("player")
		var game = _client.get("game")
		out["gate_open"] = _gate_is_open()
		out["link_playing"] = _link != null and _link.is_playing()
		out["clock_synced"] = cnet != null and cnet.clock.is_synced()
		if player != null:
			var pos: Vector3 = player.controller.state.position
			out["self"] = {"pos": [pos.x, pos.y, pos.z], "alive": player.is_alive(), "name": player.display_name}
		var others := {}
		if game != null:
			for who: ArenaPlayer in game.players():
				if who != player:
					var gp: Vector3 = who.global_position
					others[who.display_name] = [gp.x, gp.y, gp.z, who.is_alive()]
		out["others"] = others
		if cnet != null:
			out["stats"] = {"snap_recv": cnet.stats.snapshots_received, "snap_lost": cnet.stats.snapshots_lost,
				"loss_rate": cnet.stats.loss_rate(), "out_of_order": cnet.stats.out_of_order,
				"decode_failures": cnet.stats.decode_failures, "rtt_p50": cnet.stats.rtt_percentile(0.5),
				"rtt_p95": cnet.stats.rtt_percentile(0.95)}
	out["prediction"] = {"corrections": _corrections, "replays": _replays, "worst_error_m": _worst_error}
	out["max_snapshot_gap_s"] = _max_gap
	var f := FileAccess.open(_out, FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	print("netchaos client %s: report written (%d sessions, %d corrections, worst %.3f m, gap %.2f s)" % [
		_name, _sessions, _corrections, _worst_error, _max_gap])


class Pilot extends Node:
	var fire := true
	var _t := 0.0
	var _next := 0.0
	var _rng := RandomNumberGenerator.new()

	func _ready() -> void:
		_rng.randomize()
		Input.action_press(&"dot_fps_forward")
		if fire:
			Input.action_press(&"arena_fire")

	func _exit_tree() -> void:
		for a: StringName in [&"dot_fps_forward", &"dot_fps_left", &"dot_fps_right", &"dot_fps_jump", &"arena_fire"]:
			Input.action_release(a)

	func _process(delta: float) -> void:
		_t += delta
		var turn := InputEventMouseMotion.new()
		turn.relative = Vector2(sin(_t * 0.7) * 6.0, sin(_t * 1.3) * 1.5)
		Input.parse_input_event(turn)
		if _t < _next:
			return
		_next = _t + _rng.randf_range(0.3, 1.2)
		for a: StringName in [&"dot_fps_left", &"dot_fps_right", &"dot_fps_jump"]:
			Input.action_release(a)
		match _rng.randi_range(0, 3):
			0: Input.action_press(&"dot_fps_left")
			1: Input.action_press(&"dot_fps_right")
			2: Input.action_press(&"dot_fps_jump")
