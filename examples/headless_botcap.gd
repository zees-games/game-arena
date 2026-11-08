extends DotGameCheckSuite

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaModule := preload("../game/arena_module.gd")
const ArenaNetBridge := preload("../game/arena_net_bridge.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaTestPorts := preload("test_ports.gd")

## `bot_quota N` with `sv_maxplayers 0` (unlimited) spawns exactly N bots, for N past every number a cap might hide at (16, 32, 64, 255, 256). No silent clamp.
## Run: [code]godot --headless --path . res://examples/headless_botcap.tscn[/code]

var PORT := ArenaTestPorts.free_port()
const SERVER_DIR := "user://arena_botcap"
const TICK_RATE := 64

const SECTIONS := 1
const CHECKS := 17

var _entered := 0
var _completed := 0

var _server: DotServer = null
var _game: ArenaGame = null
var _module: ArenaModule = null
var _tick := 0


## What the last command replied, to whoever typed it.
var _replies := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena: bot_quota spawns exactly N bots")
	DotPaths.remove_tree(SERVER_DIR)
	if await _build():
		await _test_counts()
	_teardown()
	DotPaths.remove_tree(SERVER_DIR)
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _build() -> bool:
	print("")
	print("booting")

	_game = ArenaGame.new()
	_game.name = "Arena"
	_game.tick_rate = TICK_RATE
	_game.score_limit = 100
	_game.headless = true
	_game.register_service = true
	add_child(_game)

	if not _game.setup(ArenaMap.dm_box()).ok:
		print("  the arena would not set up")
		return false

	# Straight to a live round, so nothing the match does on its own — a warmup, a round
	# start respawning everybody — moves a body in the middle of a check about where it is.
	_game.match_node.rules.warmup_sec = 0.0
	_game.match_node.rules.countdown_sec = 0.0
	_game.match_node.rules.min_players = 1

	var config := DotServerConfig.new()
	config.hostname = "arena botcap"
	config.port = PORT
	config.bind_address = "127.0.0.1"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % SERVER_DIR
	config.bans_path = "%s/bans.json" % SERVER_DIR
	config.audit_log_path = "%s/audit.jsonl" % SERVER_DIR
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""
	config.query_enabled = false

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	add_child(_server)

	var booted: DotResult = await _server.boot()

	if not booted.ok:
		print("  the server would not boot: %s" % str(booted.error))
		return false

	# This run's own store, which `SERVER_DIR` is wiped with on the way in and out. Left
	# unset the module falls back to the one a real server enforces, and every run filed
	# its slaps and blinds against userid 73 there — and then read them back.
	ArenaModule.punishments_file = "%s/punishments.json" % SERVER_DIR
	var loaded: DotResult = await _server.modules.load_module("res://game/arena_module.gd")

	if not loaded.ok:
		print("  the module would not load: %s" % str(loaded.error))
		return false

	_module = _server.modules.get_module("arena") as ArenaModule

	var store: Object = _module.services.moderation.store \
		if _module != null and _module.services != null and _module.services.moderation != null \
		else null
	var store_path := str(store.get("path")) if store != null else ""
	_check(store_path.begins_with(SERVER_DIR),
		"the live tools write to this run's own store, not the one a real server enforces",
		store_path)

	# This suite drives the ticks itself, so a check can say exactly how many ran.
	_module.set_physics_process(false)
	_game.match_node.rules.min_players = 1

	# Snapshots go nowhere: the three sessions are adopted (dot-server's way to fill the session table without a socket), so a real send
	# would be an engine RPC error per peer per tick, burying this suite's output. The tick path is otherwise the real one.
	_module.net.send_fn = func(_peer: int, _payload: PackedByteArray, _delivery: int) -> void:
		pass

	_step(2)
	return true


func _cmd(line: String) -> void:
	var ctx := DotCmdContext.console("", PackedStringArray())
	var _r := _server.console.execute(line, ctx)


func _teardown() -> void:
	if _server != null and is_instance_valid(_server):
		_server.shutdown("test over")
		remove_child(_server)
		_server.queue_free()

	if _game != null and is_instance_valid(_game):
		remove_child(_game)
		_game.queue_free()


func _step(n: int) -> void:
	for i in n:
		_tick += 1
		_module.bridge.server_tick(_tick)


func _test_counts() -> void:
	_section("bot_quota is not clamped")
	_cmd("sv_maxplayers 0")
	_cmd("bot_quota_mode fixed")
	_check(_server.config.max_players == 0, "sv_maxplayers 0 is unlimited")
	for n in [16, 17, 32, 64, 128, 256, 300]:
		_cmd("bot_quota %d" % n)
		_module._keep_bots()
		_step(2)
		var bots := _module.bridge.bot_ids()
		_check(bots.size() == n, "bot_quota %d spawns %d bots" % [n, n], "%d bots" % bots.size())
		_check(_game.players().size() == n, "and the game holds %d players" % n, "%d" % _game.players().size())
	_cmd("bot_quota 0")
	_module._keep_bots()
	_check(_module.bridge.bot_ids().is_empty(), "bot_quota 0 removes them all")
	_done()
