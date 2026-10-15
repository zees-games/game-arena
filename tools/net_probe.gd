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
var _server: DotServer = null
var _game: ArenaGame = null


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--bots": _bots = int(args[i + 1])
			"--seconds": _seconds = float(args[i + 1])
			"--budget": _budget = int(args[i + 1])
			"--pps": _pps = int(args[i + 1])
	DotLog.set_level(DotLog.Level.ERROR)
	var _scratch := ArenaPresentation.use_scratch_settings("net_probe")
	_run.call_deferred()


func _run() -> void:
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

	var config := DotServerConfig.new()
	config.hostname = "net probe"
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
	config.log_level = "error"
	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	server_side.add_child(_server)
	await _server.boot()
	await _server.modules.load_module("res://game/arena_module.gd")

	var module = _server.modules.get_module("arena")
	var quota: DotBotQuota = module.get("_bot_quota")
	if quota != null and quota.mode_cvar != null:
		quota.mode_cvar.force_set("off")
	var net: DotNetManager = module.net
	if _game.match_node.state == DotMatch.State.IDLE:
		_game.start(0)
	if _budget >= 0:
		net.config.per_client_budget = _budget
	if _pps >= 0:
		net.config.per_client_packet_rate = _pps
	for i in range(_bots):
		module.bridge.add_bot("Probe%d" % i)

	var client_side := Node.new()
	client_side.name = "ClientSide"
	add_child(client_side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), client_side.get_path())
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Probe"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % config.effective_enet_port()
	client_side.add_child(link)
	link.connect_to_server("127.0.0.1:%d" % PORT)
	var spawned := [false]
	link.spawned.connect(func() -> void: spawned[0] = true)
	var joined := 0.0
	while not (spawned[0] or link.is_playing()) and joined < 30.0:
		await get_tree().create_timer(0.1).timeout
		joined += 0.1
	var client := (load("res://game/arena.tscn") as PackedScene).instantiate()
	client.set("mouse_capture_override", true)
	client_side.add_child(client)

	var waited := 0.0
	while waited < 40.0:
		var cnet: DotNetManager = client.get("net")
		if cnet != null and cnet.clock.is_synced() and client.get("player") != null:
			break
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	var cnet: DotNetManager = client.get("net")
	print("connected after %.1fs, %d players, budget=%d pps=%d" % [
		waited, -1,
		net.config.per_client_budget, net.config.per_client_packet_rate])

	# Let the match come alive, then reset the windows so warm-up is not averaged in.
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
	var cg = client.get("game")
	var seen := 0
	var live_state := -1
	if cg != null:
		seen = cg.players().size()
		live_state = int(cg.match_node.state) if cg.match_node != null else -2
	print("client sees %d players, match state %d; server match state %d" % [seen, live_state, int(_game.match_node.state)])
	net.stats.roll()
	cnet.stats.roll()
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
			print("t=%2d down=%6d B/s %3d pkt/s use=%s starved=%d | client rtt p50=%d p95=%d recv=%d B/s avg_pkt=%d" % [
				int(t), int(d.get("bytes_per_sec", 0)), int(d.get("packets_per_sec", 0)),
				str(d.get("utilisation", "?")), int(d.get("starved", 0)),
				int(cnet.stats.rtt_percentile(0.5)), int(rtt),
				int(cnet.stats.bytes_received_per_sec), int(cnet.stats.average_packet_bytes())])
	print("SUMMARY bots=%d peak_down=%d B/s peak_rtt_p95=%d ms starved=%d fps=%.0f worst_frame=%.1f ms lost=%d" % [
		_bots, int(peak_down), int(peak_rtt), int(net.budget.describe_peer(net.budget.peer_ids()[0]).get("starved", 0)),
		frames / maxf(t, 0.001), worst_frame, cnet.stats.snapshots_lost])
	link.disconnect_from_server("done")
	await get_tree().create_timer(0.3).timeout
	DotPaths.remove_tree(DATA)
	get_tree().quit()
