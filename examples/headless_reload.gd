extends Node
## A module reload leaves ONE link under the server, and a real ENet client still hears it.
##
## The bridge's link sits under the [DotServer] node (RPCs route by path), so nothing freed it
## when the module unloaded: the next load added a second, Godot renamed the live one
## `@Node@n`, and every RPC to a real client was dropped without an error. The suite reloads
## the module twice, then joins a real client and asks for the HELLO, which is a server RPC.
## [DotGameLink] is the fix; break it (a bare `add_child` in `open_link`) and this fails.

const ArenaEvents := preload("../game/arena_events.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaModule := preload("../game/arena_module.gd")
const ArenaNetBridge := preload("../game/arena_net_bridge.gd")
const ArenaNetLink := preload("../game/arena_net_link.gd")

const PORT := 27096
const DATA := "user://arena_reload"
const TICK_RATE := 64
const MODULE := "res://game/arena_module.gd"
const CHECKS := 11

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _server_side: Node = null
var _server: DotServer = null
var _game: ArenaGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena: a module reload leaves one live link")
	DotPaths.remove_tree(DATA)
	Engine.physics_ticks_per_second = TICK_RATE
	if await _boot():
		await _test_reload()
		await _test_client_hears_the_server()
	if _server != null:
		_server.shutdown("done")
	await get_tree().process_frame
	DotPaths.remove_tree(DATA)

	print("")
	_check(_completed == _entered and _entered == 3,
		"every section ran to its last line (%d of %d)" % [_completed, _entered])
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	if _passed + _failed != CHECKS + 1:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, CHECKS + 1])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s: %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	return condition


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().physics_frame
	return bool(condition.call())


func _module() -> ArenaModule:
	return _server.modules.get_module("arena") as ArenaModule


## What a reload resets: no quota bots, or one could meet the client and change the section.
func _quiet_the_bots() -> void:
	var quota: DotBotQuota = _module().get("_bot_quota")
	if quota != null and quota.mode_cvar != null:
		quota.mode_cvar.force_set("off")


func _boot() -> bool:
	_section("an arena server boots")
	_server_side = Node.new()
	_server_side.name = "ServerSide"
	add_child(_server_side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), _server_side.get_path())

	_game = ArenaGame.new()
	_game.name = "Arena"
	_game.tick_rate = TICK_RATE
	_game.score_limit = 0
	_game.time_limit_sec = 0.0
	_game.headless = true
	_game.register_service = true
	_server_side.add_child(_game)
	if not _check(_game.setup(ArenaMap.dm_box()).ok, "the arena sets up"):
		_done()
		return false

	var config := DotServerConfig.new()
	config.hostname = "arena reload"
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
	_server_side.add_child(_server)
	var booted: DotResult = await _server.boot()
	if not _check(booted.ok, "the server boots on %d" % PORT, str(booted.error)):
		_done()
		return false
	ArenaModule.punishments_file = "%s/punishments.json" % DATA
	var loaded: DotResult = await _server.modules.load_module(MODULE)
	_check(loaded.ok, "the module loads", str(loaded.error))
	_done()
	return loaded.ok


func _links() -> int:
	var count := 0
	for child in _server.get_children():
		if child is ArenaNetLink:
			count += 1
	return count


func _test_reload() -> void:
	_section("two reloads leave one link, under the name the client routes to")
	for _i in range(2):
		_check(_server.modules.unload_module("arena").ok, "the module unloads")
		_check((await _server.modules.load_module(MODULE)).ok, "and loads again")
	await get_tree().process_frame
	await get_tree().process_frame
	_quiet_the_bots()
	var links := _links()
	_check(links == 1 and _server.has_node(NodePath(String(ArenaNetLink.NODE_NAME))),
		"exactly one link, named %s (%d)" % [ArenaNetLink.NODE_NAME, links])
	_done()


func _test_client_hears_the_server() -> void:
	_section("a real client still gets the server's RPCs")
	var side := Node.new()
	side.name = "ClientSide"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Reloader"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % _server.config.effective_enet_port()
	side.add_child(link)
	var spawned := [false]
	link.spawned.connect(func() -> void: spawned[0] = true)
	link.connect_to_server("127.0.0.1:%d" % PORT)
	await _until(func() -> bool: return spawned[0] or link.phase == DotClientLink.Phase.FAILED, 30.0)
	if not _check(spawned[0], "the client signs on"):
		_done()
		return
	DotGameClient.report_cover(link, false)

	var game := ArenaGame.new()
	game.name = "Game"
	game.is_authority = false
	game.headless = true
	game.register_service = false
	side.add_child(game)
	game.setup(ArenaMap.dm_box())
	var net := DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.service_scope = &"reload_client"
	net.local_peer_id = side.multiplayer.get_unique_id()
	net.auto_tick = false
	net.config_file = ""
	var cfg := DotNetConfig.new()
	cfg.tick_rate = game.tick_rate
	cfg.snapshot_rate = ArenaGame.NET_SNAPSHOT_RATE
	cfg.enable_prediction = true
	cfg.enable_lag_compensation = false
	cfg.max_entities_per_snapshot = 64
	cfg.world_extent = ArenaGame.NET_WORLD_EXTENT
	net.config = cfg
	side.add_child(net)
	net.setup()
	var bridge := ArenaNetBridge.new()
	bridge.name = "Bridge"
	side.add_child(bridge)
	bridge.attach(game, net)
	bridge.open_link(link)
	net.messages.seal()
	var hello := [0]
	bridge.hello_received.connect(func(info: Dictionary) -> void: hello[0] = int(info["session_id"]))
	net.start()
	bridge.send_request(ArenaEvents.Ask.READY)
	var heard := await _until(func() -> bool: return hello[0] != 0, 20.0)
	_check(heard, "the client hears the server's HELLO over the reloaded link")
	_check(_links() == 1, "and there is still exactly one link under the server (%d)" % _links())
	link.disconnect_from_server("done")
	await get_tree().process_frame
	side.queue_free()
	_done()
