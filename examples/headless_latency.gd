extends "lossy_windows.gd"
## `cl_latency_baseline` against a real arena server over real ENet on loopback: 0.2 s on the client adds
## about 0.4 s to the round trip, and the server's `sv_allow_client_latency 0` takes it back off.
## `--legacy` is the control: the client drives its frame the way it did before the bridge carried the
## delay (nothing releases the held snapshots, inputs skip the delay), and the checks fail.

const LAG := 0.2
const SETTLE := 3.0
const SAMPLE := 5.0
const SECTIONS := 6

var _legacy := false
var _sent_at: Dictionary = {}
var _seen: Dictionary = {}
var _up_ms: Array[float] = []
var _down_ms: Array[float] = []
var _sampling := false
var _checks := 0


func _ready() -> void:
	_legacy = "--legacy" in OS.get_cmdline_user_args()
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena: cl_latency_baseline over real ENet, against a real server")
	DotPaths.remove_tree(DATA)
	Engine.physics_ticks_per_second = TICK_RATE
	if await _boot() and await _connect_one():
		await _measure_all()
	await _teardown()
	DotPaths.remove_tree(DATA)
	_report_sections(_entered, _completed, SECTIONS, _passed + _failed)


func _connect_one() -> bool:
	_section("a client connects to the server's UDP port")
	var a := await _connect_client("A", _server.config.effective_enet_port())
	_clients["A"] = a
	var ok := _check(a.get("bridge") != null and int(a["session"]) != 0, "A connects and is told who it is", str(a.get("error", "")))
	_driving = ok
	_done()
	return ok


func _measure_all() -> void:
	var a: Dictionary = _clients["A"]
	var net: DotNetManager = a["net"]
	var link: DotClientLink = a["link"]
	var _followed := net.latency.follow_cvars(link)
	_section("baseline: no added latency")
	var base := await _window(a)
	_report_window("baseline", base)
	_check(not net.latency.delaying(), "the client adds nothing by default")
	_done()

	_section("cl_latency_baseline 0.2 raises the round trip by about 0.4 s")
	_check(net.latency.set_cvar("cl_latency_baseline", str(LAG)), "cl_latency_baseline takes seconds")
	var lagged := await _window(a)
	_report_window("lag 0.2", lagged)
	var rise: float = lagged["round_trip"] - base["round_trip"]
	_check(absf(rise - LAG * 2000.0) <= 120.0, "the round trip rose %.0f ms (want %.0f +-120)" % [rise, LAG * 2000.0])
	_check(lagged["up"] - base["up"] >= LAG * 1000.0 * 0.6, "inputs reach the server %.0f ms later" % (lagged["up"] - base["up"]))
	_check(lagged["down"] - base["down"] >= LAG * 1000.0 * 0.6, "snapshots reach the client %.0f ms later" % (lagged["down"] - base["down"]))
	_check(lagged["rtt"] - base["rtt"] >= 300.0, "the clock's round trip follows it (%.0f -> %.0f ms)" % [base["rtt"], lagged["rtt"]])
	_check(lagged["late"] <= 3, "the lead absorbs it: %d of the inputs arrived late" % lagged["late"])
	_done()

	_section("sv_allow_client_latency 0 on the server drops it back")
	var _off := _server.console.set_cvar("sv_allow_client_latency", "0")
	var heard := await _until(func() -> bool: return not net.latency.allowed, RELIABLE_SECONDS)
	_check(heard, "the client hears the server's switch")
	var forced := await _window(a)
	_report_window("forbidden", forced)
	_check(net.latency.effective() == 0.0 and net.latency.requested == LAG, "the effective baseline is 0 and the request is kept")
	_check(absf(forced["round_trip"] - base["round_trip"]) <= 120.0, "the round trip is back near baseline (%.0f vs %.0f ms)" % [forced["round_trip"], base["round_trip"]])
	_done()

	_section("sv_allow_client_latency 1 gives it back")
	var _on := _server.console.set_cvar("sv_allow_client_latency", "1")
	var _back := await _until(func() -> bool: return net.latency.allowed, RELIABLE_SECONDS)
	var again := await _window(a)
	_report_window("allowed again", again)
	_check(again["round_trip"] - base["round_trip"] >= LAG * 2000.0 - 120.0, "the request applies again (+%.0f ms)" % (again["round_trip"] - base["round_trip"]))
	_done()


## Plays SETTLE seconds, then samples SAMPLE seconds; medians in ms.
func _window(a: Dictionary) -> Dictionary:
	var net: DotNetManager = a["net"]
	await _until(func() -> bool: return false, SETTLE)
	_up_ms.clear()
	_down_ms.clear()
	var buffer := _module().net.input_buffer_for(_peer_of("A"))
	var late0 := buffer.late_count
	_sampling = true
	await _until(func() -> bool: return false, SAMPLE)
	_sampling = false
	var up := _median(_up_ms)
	var down := _median(_down_ms)
	return {"up": up, "down": down, "round_trip": up + down, "rtt": net.clock.rtt_ms(),
		"enet": ArenaNetBridge.link_rtt_ms(a["link"]), "late": buffer.late_count - late0, "n": _up_ms.size()}


func _report_window(label: String, w: Dictionary) -> void:
	print("    %-13s up %4.0f ms  down %4.0f ms  round trip %4.0f ms  clock rtt %4.0f ms  ENet rtt %3.0f ms  late %d  (%d samples)" % [
		label, w["up"], w["down"], w["round_trip"], w["rtt"], w["enet"], w["late"], w["n"]])


static func _median(values: Array[float]) -> float:
	if values.is_empty():
		return INF
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


func _physics_process(delta: float) -> void:
	if not _driving:
		return
	var a: Dictionary = _clients["A"]
	var net: DotNetManager = a["net"]
	var bridge: ArenaNetBridge = a["bridge"]
	if net == null or not net.is_running():
		return
	net.stats.roll()
	if not _legacy:
		bridge.advance_latency(delta)
	var ticks := net.clock.advance(delta)
	for i in range(ticks):
		if not net.clock.is_synced():
			continue
		var tick := net.clock.input_tick() - (ticks - 1 - i)
		var move := _command_a(tick)
		var fire := DotWeaponCommand.new()
		bridge.client_tick(tick, move, fire)
		_sent_at[tick] = Time.get_ticks_usec()
		if _legacy:
			bridge.link.send_input(bridge.encode_input(tick, move, fire))
		else:
			bridge.send_input(tick, move, fire)

	# Uplink: when the server first sees each tick of A's. Downlink: the age of the newest snapshot A has applied,
	# against the server's real tick, both in this process.
	var newest := _module().net.input_buffer_for(_peer_of("A")).newest()
	if newest != null and not _seen.has(newest.tick) and _sent_at.has(newest.tick):
		_seen[newest.tick] = true
		if _sampling:
			_up_ms.append(float(Time.get_ticks_usec() - int(_sent_at[newest.tick])) / 1000.0)
	if _sampling:
		_down_ms.append(float(_game.current_tick() - net.clock.received_tick()) * 1000.0 / float(TICK_RATE))


func _teardown() -> void:
	_driving = false
	var link: DotClientLink = _clients["A"]["link"] if _clients.has("A") else null
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
