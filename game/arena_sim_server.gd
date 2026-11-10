extends Node

const ArenaConfig := preload("arena_config.gd")
const ArenaGame := preload("arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaModule := preload("arena_module.gd")
const ArenaSimOwner := preload("arena_sim_owner.gd")

## The authoritative game of a solo session in its own process (`--sim_host 1`, [ArenaSimHost]): a loopback dedicated server the solo client spawns and joins, so the 66 Hz simulation never runs on the render thread. The same [ArenaModule] a public server runs.
## Launch flags (after `--`): `--port N --bots N --map ID --mode ID --ready PATH`. It writes PATH once it accepts players, and quits a few seconds after its player left.

const CHANNEL := "arena.sim_server"
const REPORT_SEC := 5.0
const GONE_SEC := 5.0
const NEVER_SEC := 120.0

var _server: DotServer = null
var _joined := false
var _alone_sec := 0.0
var _since_check := 0.0


func _ready() -> void:
	var port := int(_arg("--port", "0"))
	var bots := int(_arg("--bots", "0"))
	if port <= 0:
		_die("no --port")
		return
	var data := "user://sim_host"
	var _made := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(data))

	var game := ArenaGame.new()
	game.name = "Arena"
	game.is_authority = true
	game.headless = true
	game.register_service = true
	# The solo cfg layers, lenient as solo reads them: a typo must not stop a single-player game.
	var binder := ArenaConfig.make_binder(game.config, "user://cfg/arena.json")
	DotLog.result(CHANNEL, "config", binder.load_layers())
	game.config_binder = binder
	game.tick_rate = game.config.tick_rate
	var mode := _arg("--mode", "")
	if mode != "":
		game.mode_id = StringName(mode)
	add_child(game)
	var map := ArenaMap.by_id(StringName(_arg("--map", "")))
	var built := game.setup(map if map != null else ArenaMap.dm_box())
	if not built.ok:
		_die("the arena could not be built: %s" % built.error.message)
		return
	# As ArenaServer does: without it the boot map's match stays IDLE (nobody spawns, no
	# rounds) until the first host_change restarts it (owner batch 2026-11-10, item 11).
	game.start(0)

	var config := _server_config(port, game.tick_rate, data)
	var server := DotServer.new()
	server.name = "Server"
	server.config = config
	server.config_file = ""
	server.auto_boot = false
	add_child(server)
	var booted: DotResult = await server.boot()
	if not booted.ok:
		_die("boot: %s" % booted.error.message)
		return
	var loaded: DotResult = await server.modules.load_module("res://game/arena_module.gd")
	if not loaded.ok:
		_die("module: %s" % loaded.error.message)
		return
	var module := server.modules.get_module("arena") as ArenaModule
	var quota: DotBotQuota = module.get("_bot_quota")
	if quota != null and quota.mode_cvar != null:
		quota.mode_cvar.force_set("fixed")
		quota.quota_cvar.force_set(str(bots))
		quota.empty_cvar.force_set("1")
	for i in bots:
		var _id: int = module.bridge.add_bot("Bot %d" % (i + 1))
	var owner_node := ArenaSimOwner.new()
	owner_node.name = "Owner"
	add_child(owner_node)
	owner_node.setup(server, module)

	var ready_path := _arg("--ready", "")
	if ready_path != "":
		var f := FileAccess.open(ready_path, FileAccess.WRITE)
		if f != null:
			var _stored := f.store_string(str(config.effective_enet_port()))
			f.close()
	_server = server
	print("SIM_HOST ready map=%s mode=%s bots=%d" % [String(game.map.id), String(game.mode.id), bots])
	_report(module.net)


## The loopback server config for the solo host: [param data] holds its admin, ban and audit files.
static func _server_config(port: int, tickrate: int, data: String) -> DotServerConfig:
	var config := DotServerConfig.new()
	config.hostname = "solo"
	config.port = port
	config.tickrate = tickrate
	config.max_players = 64
	config.bind_address = "127.0.0.1"
	config.transport_mode = "dual"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % data
	config.bans_path = "%s/bans.json" % data
	config.audit_log_path = "%s/audit.jsonl" % data
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""
	config.query_enabled = false
	config.enet_share_udp_port = false
	config.stdin_console_enabled = false
	# Only the owner chats here, and the menus ask over chat (B, the team screen's 2 s refresh): the
	# public 20 a minute refused them with "sending messages too quickly" (owner batch 2026-11-10).
	config.chat_rate_per_minute = 240
	config.log_level = "warn"
	return config


func _process(delta: float) -> void:
	# A solo client that crashed cannot tell its server to stop: the server ends once its one remote
	# player is gone for a while, or when none ever came. (A process cannot ask after its parent.)
	_since_check += delta
	if _since_check < 1.0 or _server == null:
		return
	_alone_sec = 0.0 if _remote_players() > 0 else _alone_sec + _since_check
	_since_check = 0.0
	_joined = _joined or _alone_sec == 0.0
	if _alone_sec >= (GONE_SEC if _joined else NEVER_SEC):
		get_tree().quit(0)


func _remote_players() -> int:
	var count := 0
	for session: DotClientSession in _server.sessions():
		if not session.local:
			count += 1
	return count


## Every few seconds, one line: the tick rate held and what a tick cost (dot-net server counters).
func _report(net: DotNetManager) -> void:
	var last: Dictionary = net.perf_counters()
	var t0 := Time.get_ticks_usec()
	while is_inside_tree():
		await get_tree().create_timer(REPORT_SEC).timeout
		var now: Dictionary = net.perf_counters()
		var secs := (Time.get_ticks_usec() - t0) / 1.0e6
		var ticks := maxi(1, int(now[&"server_ticks"]) - int(last[&"server_ticks"]))
		print("SIM_HOST %.1f ticks/s of %d | sim %.3f ms/tick send %.3f ms/tick" % [
			ticks / secs, Engine.physics_ticks_per_second,
			(int(now[&"server_sim_usec"]) - int(last[&"server_sim_usec"])) / 1000.0 / ticks,
			(int(now[&"server_send_usec"]) - int(last[&"server_send_usec"])) / 1000.0 / ticks])
		last = now
		t0 = Time.get_ticks_usec()


func _die(why: String) -> void:
	printerr("arena sim server: ", why)
	get_tree().quit(1)


static func _arg(flag: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find(flag)
	return args[index + 1] if index >= 0 and index + 1 < args.size() else fallback
