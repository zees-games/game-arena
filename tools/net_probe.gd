extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")

## Bytes per second, snapshot size, rtt and rate-limiter starvation for one real client
## against a dual-stack server with N hunting bots, over real loopback ENet (no relay, so
## nothing but the game's own limiter can queue a packet).
##
## [codeblock]
## godot --headless --path . res://tools/net_probe.tscn -- --bots 12 --seconds 20 [--budget 0] [--pps 0]
## [/codeblock]
##
## `--budget` and `--pps` override `per_client_budget` / `per_client_packet_rate` on the
## server's DotNetConfig after boot, so a before/after is one flag. Prints one line a second
## and a summary; it asserts nothing.

const PORT := 27196
const DATA := "user://arena_net_probe"

var _bots := 8
var _seconds := 20.0
var _budget := -1
var _pps := -1
## --aoi players,radius,far_distance,far_every,far_tiers: the relevance rings (arena_net_aoi.gd); unset is the shipped defaults.
var _aoi: PackedStringArray = PackedStringArray()

## --fake N: N extra synthetic peers (no observer entity, unreliable sends dropped, acks 2 snapshots late) on the server, to measure per-peer snapshot cost without N full clients.
var _fake := 0
## --workers N: DotNetConfig.snapshot_workers; unset keeps the server's own (sv_snapshot_workers' default).
var _workers := -2
var _native := 1
var _noshort := false
var _fake_sent := [0, 0]
var _server: DotServer = null
var _game: ArenaGame = null
var _module = null
var _net: DotNetManager = null
var _client: Node = null
var _cnet: DotNetManager = null
var _link: DotClientLink = null
var _config: DotServerConfig = null


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--bots": _bots = int(args[i + 1])
			"--seconds": _seconds = float(args[i + 1])
			"--budget": _budget = int(args[i + 1])
			"--pps": _pps = int(args[i + 1])
			"--workers": _workers = int(args[i + 1])
			"--native": _native = int(args[i + 1])
			"--noshort": _noshort = true
			"--fake": _fake = int(args[i + 1])
			"--aoi": _aoi = String(args[i + 1]).split(",")
	DotLog.set_level(DotLog.Level.ERROR)
	var _scratch := ArenaPresentation.use_scratch_settings("net_probe")
	_run.call_deferred()


func _run() -> void:
	await _boot_server()
	_tune_server()
	await _connect_client()
	await _wait_alive()
	await _install_fakes()
	await _measure_and_report()
	_link.disconnect_from_server("done")
	await get_tree().create_timer(0.3).timeout
	DotPaths.remove_tree(DATA)
	get_tree().quit()


func _boot_server() -> void:
	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), server_side.get_path())

	_game = ArenaGame.new()
	_game.name = "Arena"
	_game.tick_rate = 64
	_game.score_limit = 0
	_game.time_limit_sec = 0.0
	_game.warmup_sec = 0.0
	_game.headless = true
	_game.register_service = true
	server_side.add_child(_game)
	_game.setup(ArenaMap.dm_box())

	_config = DotServerConfig.new()
	_config.hostname = "net probe"
	_config.port = PORT
	_config.max_players = 256
	_config.bind_address = "127.0.0.1"
	_config.transport_mode = "dual"
	_config.rcon_password = ""
	_config.admins_path = "%s/admins.json" % DATA
	_config.bans_path = "%s/bans.json" % DATA
	_config.audit_log_path = "%s/audit.jsonl" % DATA
	_config.hibernate_when_empty = false
	_config.startup_config = ""
	_config.autoexec_config = ""
	_config.query_enabled = false
	_config.enet_share_udp_port = false
	_config.stdin_console_enabled = false
	_config.log_level = "error"
	_server = DotServer.new()
	_server.name = "Server"
	_server.config = _config
	_server.config_file = ""
	_server.auto_boot = false
	server_side.add_child(_server)
	await _server.boot()
	await _server.modules.load_module("res://game/arena_module.gd")


func _tune_server() -> void:
	_module = _server.modules.get_module("arena")
	var quota: DotBotQuota = _module.get("_bot_quota")
	if quota != null and quota.mode_cvar != null:
		# "off" is wanted = 0: the quota removes every bot a second later (arena-128-scale-1).
		quota.mode_cvar.force_set("fixed")
		quota.quota_cvar.force_set(str(_bots))
		quota.empty_cvar.force_set("1")
	_net = _module.net
	if _game.match_node.state == DotMatch.State.IDLE:
		_game.start(0)
	DotNetBehaviour.native_encode_shortcuts = not _noshort
	if _workers >= -1:
		_net.config.snapshot_workers = _workers
	_net.config.native = _native != 0
	if _budget >= 0:
		_net.config.per_client_budget = _budget
	if _pps >= 0:
		_net.config.per_client_packet_rate = _pps
	if _aoi.size() == 5 and _module.get("net_aoi") != null:
		var cv: Dictionary = _module.net_aoi._cvars
		for k in ["min_players", "radius", "far_distance", "far_every", "far_tiers"]:
			(cv[k] as DotConVar).force_set(_aoi[["min_players", "radius", "far_distance", "far_every", "far_tiers"].find(k)])
	for i in range(_bots):
		_module.bridge.add_bot("Probe%d" % i)


func _connect_client() -> void:
	var client_side := Node.new()
	client_side.name = "ClientSide"
	add_child(client_side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), client_side.get_path())
	_link = DotClientLink.new()
	_link.name = "Server"
	_link.player_name = "Probe"
	_link.transport_preference = "udp"
	_link.udp_address = "127.0.0.1:%d" % _config.effective_enet_port()
	client_side.add_child(_link)
	_link.connect_to_server("127.0.0.1:%d" % PORT)
	var spawned := [false]
	_link.spawned.connect(func() -> void: spawned[0] = true)
	var joined := 0.0
	while not (spawned[0] or _link.is_playing()) and joined < 30.0:
		await get_tree().create_timer(0.1).timeout
		joined += 0.1
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("mouse_capture_override", true)
	client_side.add_child(_client)

	var waited := 0.0
	while waited < 40.0:
		var cnet: DotNetManager = _client.get("net")
		if cnet != null and cnet.clock.is_synced() and _client.get("player") != null:
			break
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	_cnet = _client.get("net")
	print("connected after %.1fs, %d players, budget=%d pps=%d" % [
		waited, -1,
		_net.config.per_client_budget, _net.config.per_client_packet_rate])


## Let the match come alive, then reset the windows so warm-up is not averaged in.
func _wait_alive() -> void:
	var alive := 0
	var spin := 0.0
	while spin < 20.0:
		alive = 0
		for other in _game.players():
			if other.is_alive():
				alive += 1
		if alive >= _bots + 1:
			break
		await get_tree().create_timer(0.25).timeout
		spin += 0.25
	print("alive on the server: %d of %d after %.1fs" % [alive, _bots + 1, spin])
	var cg = _client.get("game")
	var seen := 0
	var live_state := -1
	if cg != null:
		seen = cg.players().size()
		live_state = int(cg.match_node.state) if cg.match_node != null else -2
	print("client sees %d players, match state %d; server match state %d" % [seen, live_state, int(_game.match_node.state)])
	_net.stats.roll()
	_cnet.stats.roll()
	_module.call("_refresh_aoi")


func _install_fakes() -> void:
	if _fake <= 0:
		return
	var net := _net
	var schema := net.messages.schema_payload()
	var orig_send: Callable = net.send_fn
	var fakes := {}
	for i in _fake:
		var fid := 5000 + i
		net.add_peer(fid)
		var _r := net.receive(schema, fid)
		fakes[fid] = true
	net.send_fn = func(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
		if fakes.has(peer_id):
			_fake_sent[0] += 1
			_fake_sent[1] += payload.size()
			return
		orig_send.call(peer_id, payload, delivery)
	var acks: Array = []
	net.snapshot_sent.connect(func(tick: int, _n: int) -> void:
		acks.append(tick)
		if acks.size() > 2:
			var acked: int = acks.pop_front()
			for fid: int in fakes:
				var _a := net.receive_ack(fid, acked))
	await get_tree().create_timer(2.0).timeout


func _measure_and_report() -> void:
	var net := _net
	var cnet := _cnet
	var perf0: Dictionary = net.perf_counters()
	var sum_down := 0.0
	var n_down := 0
	var t := 0.0
	var peak_rtt := 0.0
	var peak_down := 0.0
	var worst_frame := 0.0
	var frames := 0
	var last := Time.get_ticks_usec()
	var next_print := 1.0
	while t < _seconds:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		worst_frame = maxf(worst_frame, (now - last) / 1000.0)
		last = now
		frames += 1
		t += get_process_delta_time()
		if t >= next_print:
			next_print += 1.0
			var peers := net.budget.peer_ids()
			var d: Dictionary = net.budget.describe_peer(peers[0]) if peers.size() > 0 else {}
			var rtt := cnet.stats.rtt_percentile(0.95)
			peak_rtt = maxf(peak_rtt, rtt)
			peak_down = maxf(peak_down, float(d.get("bytes_per_sec", 0)))
			sum_down += float(d.get("bytes_per_sec", 0))
			n_down += 1
			print("t=%2d down=%6d B/s %3d pkt/s use=%s starved=%d | client rtt p50=%d p95=%d recv=%d B/s avg_pkt=%d" % [
				int(t), int(d.get("bytes_per_sec", 0)), int(d.get("packets_per_sec", 0)),
				str(d.get("utilisation", "?")), int(d.get("starved", 0)),
				int(cnet.stats.rtt_percentile(0.5)), int(rtt),
				int(cnet.stats.bytes_received_per_sec), int(cnet.stats.average_packet_bytes())])
	print("SUMMARY bots=%d peak_down=%d B/s peak_rtt_p95=%d ms starved=%d fps=%.0f worst_frame=%.1f ms lost=%d" % [
		_bots, int(peak_down), int(peak_rtt), int(net.budget.describe_peer(net.budget.peer_ids()[0]).get("starved", 0)),
		frames / maxf(t, 0.001), worst_frame, cnet.stats.snapshots_lost])
	var perf1: Dictionary = net.perf_counters()
	var nticks := maxi(1, int(perf1[&"server_ticks"]) - int(perf0[&"server_ticks"]))
	print("AOI active=%s players=%d mean_down=%d B/s send_ms_per_tick=%.3f sim_ms_per_tick=%.3f ticks=%d entities=%d" % [
		str(_module.net_aoi.active), _game.players().size(), int(sum_down / maxf(n_down, 1)),
		(int(perf1[&"server_send_usec"]) - int(perf0[&"server_send_usec"])) / 1000.0 / nticks,
		(int(perf1[&"server_sim_usec"]) - int(perf0[&"server_sim_usec"])) / 1000.0 / nticks,
		nticks, net.registry.all().size()])
	var snaps := maxi(1, int(perf1[&"snap_snapshots"]) - int(perf0[&"snap_snapshots"]))
	var ph := ""
	for k in ["prepare", "reads", "interest", "build", "thaw", "begin", "nint", "submit", "join", "apply"]:
		ph += " %s=%.3f" % [k, (int(perf1[StringName("snap_%s_usec" % k)]) - int(perf0[StringName("snap_%s_usec" % k)])) / 1000.0 / snaps]
	print("PHASES clients=%d native=%s workers=%d ms/snapshot:%s fake_bytes_per_snapshot=%d" % [
		1 + _fake, net._native_note, net.config.snapshot_workers, ph,
		int(_fake_sent[1] / maxf(float(snaps) * maxf(_fake, 1), 1.0))])
