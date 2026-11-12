extends DotGameCheckSuite

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaModule := preload("../game/arena_module.gd")

## The part every live-server suite repeats: a real [DotServer] on a free loopback port with
## [ArenaModule] loaded by path, sessions adopted without a socket, ticks driven by the suite.
## [method _boot_server] is the bring-up; the rest is plumbing a check calls.

var _entered := 0
var _completed := 0

var _server: DotServer = null
var _game: ArenaGame = null
var _module: ArenaModule = null
var _tick := 0

## What the last command replied, to whoever typed it.
var _replies := PackedStringArray()


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


## Boots the game and the server and loads the module. False (after printing why) when any
## step fails. [param dir] is this run's own directory, wiped by the caller on the way in
## and out.
func _boot_server(hostname: String, port: int, dir: String, tick_rate: int) -> bool:
	print("")
	print("booting")

	_game = ArenaGame.new()
	_game.name = "Arena"
	_game.tick_rate = tick_rate
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
	config.hostname = hostname
	config.port = port
	config.bind_address = "127.0.0.1"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % dir
	config.bans_path = "%s/bans.json" % dir
	config.audit_log_path = "%s/audit.jsonl" % dir
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

	# This run's own store, which the directory is wiped with on the way in and out. Left
	# unset the module falls back to the one a real server enforces, and every run filed
	# its slaps and blinds against userid 73 there — and then read them back.
	ArenaModule.punishments_file = "%s/punishments.json" % dir
	var loaded: DotResult = await _server.modules.load_module("res://game/arena_module.gd")

	if not loaded.ok:
		print("  the module would not load: %s" % str(loaded.error))
		return false

	_module = _server.modules.get_module("arena") as ArenaModule

	var store: Object = _module.services.moderation.store \
		if _module != null and _module.services != null and _module.services.moderation != null \
		else null
	var store_path := str(store.get("path")) if store != null else ""
	_check(store_path.begins_with(dir),
		"the live tools write to this run's own store, not the one a real server enforces",
		store_path)

	# This suite drives the ticks itself, so a check can say exactly how many ran.
	_module.set_physics_process(false)

	# Snapshots go nowhere. Adopted sessions have no peer behind them, so the netcode's real
	# send would be an engine RPC error per peer per tick, burying the output. The tick path
	# is otherwise the real one.
	_module.net.send_fn = func(_peer: int, _payload: PackedByteArray, _delivery: int) -> void:
		pass

	return true


func _adopt(
	peer: int, userid: int, display_name: String, flags: Array, immunity: int
) -> DotClientSession:
	var session := DotClientSession.new()
	session.peer_id = peer
	session.userid = userid
	session.display_name = display_name
	session.permissions = PackedStringArray(flags)
	session.immunity = immunity
	var _adopted := _server.adopt_session(session)
	_server.events.fire("client_spawn", {"userid": userid, "name": display_name})
	return session


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


## Types a `!command` into chat as [param speaker], and waits for the reply: what
## `DotChatManager._handle_command` does minus the socket. `player_command` fires, then the
## line goes to the console with a CHAT context; the reply sink is a list instead of an RPC.
func _say(speaker: DotClientSession, line: String) -> PackedStringArray:
	_replies.clear()
	var trimmed := line.trim_prefix("!").strip_edges()
	var tokens := DotConsole.tokenize(trimmed)

	var event := _server.events.fire("player_command", {
		"userid": speaker.userid,
		"name": speaker.display_name,
		"command": tokens[0].to_lower(),
		"args": Array(tokens).slice(1),
		"session": speaker,
	})

	if event.cancelled:
		_replies.append("(claimed by the game before the console saw it)")
		return _replies.duplicate()

	var sink := func(text: String) -> void: _replies.append(text)
	var ctx := speaker.make_context(
		tokens[0].to_lower(), PackedStringArray(Array(tokens).slice(1)),
		DotCmdContext.Source.CHAT, sink
	)
	var _ran := _server.console.execute(trimmed, ctx)

	# The handlers are coroutines — a punishment store may be a remote one — so the reply
	# can arrive a frame after the command returned. And a respawn or restart is held for the
	# next server tick (arena_tick_gate.gd): two physics frames are past its top.
	await get_tree().physics_frame
	await get_tree().physics_frame
	await get_tree().process_frame
	await get_tree().process_frame
	return _replies.duplicate()
