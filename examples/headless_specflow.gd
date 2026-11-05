extends DotGameCheckSuite

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaModule := preload("../game/arena_module.gd")
const ArenaNetBridge := preload("../game/arena_net_bridge.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

## Spectate then Play from the team menu, on a dedicated server with real sessions: `/teams spectate` and `/teams play` typed as a player, in a free-for-all.
## The world is asserted: the scoreboard row, the one player entity, the bot fill, who is alive.

var PORT := ArenaTestPorts.free_port()
const SERVER_DIR := "user://arena_specflow"
const TICK_RATE := 64

const SECTIONS := 3
const CHECKS := 24

var _entered := 0
var _completed := 0

var _server: DotServer = null
var _game: ArenaGame = null
var _module: ArenaModule = null
var _tick := 0

var _admin: DotClientSession = null
var _player: DotClientSession = null

## What the last command replied, to whoever typed it.
var _replies := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena: Spectate and Play from the team menu on a dedicated server")
	DotPaths.remove_tree(SERVER_DIR)
	if await _build():
		await _test_spectate_and_back()
		await _test_bot_fill()
		await _test_refusals()
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

	var config := _server_config()

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

	# The flags an operator's groups.yml hands out: the admin group has cheats, slay and
	# teleport; the moderator group has slay and teleport and NOT cheats.
	_admin = _adopt(4001, 71, "Boss", ["generic", "cheats"], 60)
	_player = _adopt(4003, 73, "Ada", [], 0)

	_step(8)
	return _game.player_for(73) != null and _game.player_for(71) != null


## A loopback server config whose files live in this run's own directory.
func _server_config() -> DotServerConfig:
	var config := DotServerConfig.new()
	config.hostname = "arena specflow"
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
	return config


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


func _teardown() -> void:
	if _server != null and is_instance_valid(_server):
		_server.shutdown("test over")
		remove_child(_server)
		_server.queue_free()

	if _game != null and is_instance_valid(_game):
		remove_child(_game)
		_game.queue_free()


## Types a `!command` into chat as [param speaker], and waits for the reply.
## Mirrors `DotChatManager._handle_command` minus the socket: `player_command` fires (where this game's services claim `!rtv` and the rest), then the line goes to the console
## with a CHAT context from the speaker's session; the reply sink is a list instead of an RPC, since an adopted session has no socket.
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
	# can arrive a frame after the command returned.
	await get_tree().process_frame
	await get_tree().process_frame
	return _replies.duplicate()


## Runs [param ticks] server ticks with Ada holding [param move].
func _step(ticks: int, move: DotFpsCommand = null) -> void:
	var command := move if move != null else DotFpsCommand.new()
	var behaviour := _module.bridge.behaviour_for(73)

	for _i in range(ticks):
		if behaviour != null:
			behaviour.last_move = command
		_tick += 1
		_module.bridge.server_tick(_tick)


func _move(forward: float, buttons: int = 0, yaw: float = 0.0) -> DotFpsCommand:
	var command := DotFpsCommand.new()
	command.move = Vector2(0.0, forward)
	command.yaw = yaw
	command.buttons = buttons
	return command


func _row(id: int) -> Variant:
	return _game.match_node.scoreboard.find(str(id))


func _entities(id: int) -> int:
	var n := 0
	for p in _game.players():
		if p.player_id == id:
			n += 1
	return n


func _humans_playing() -> int:
	var n := 0
	for id in [71, 73]:
		var r: Variant = _row(id)
		if r != null and r.present and not r.spectating:
			n += 1
	return n


## Types the switch as a player would, after the cooldown (mp_teamswitch_cooldown, default 5 s) has run out on the game clock.
func _switch(what: String) -> PackedStringArray:
	_step(340)
	return await _say(_player, "!teams " + what)


func _fill() -> void:
	_module._keep_bots()
	_step(2)


func _test_spectate_and_back() -> void:
	_section("spectate, then play")
	var ada := _game.player_for(73)
	_check(_game.mode.teams().is_empty(), "the mode is a free-for-all")
	_check(ada != null and ada.is_alive() and _entities(73) == 1, "Ada is alive, once")
	_row(73).kills = 2
	var out := await _switch("spectate")
	_step(4)
	_check(_row(73).spectating and not _game.player_for(73).is_alive(), "Spectate takes her out of play, body gone", " / ".join(out))
	_check(_row(73).present and _entities(73) == 1, "her scoreboard row stays and there is still one entity")
	_check(_game.spectate.is_spectating(73), "dot-spectate has her watching")
	_step(200)
	_check(not _game.player_for(73).is_alive(), "and she does not respawn by herself while out")
	var again := await _switch("play")
	_step(4)
	var back := _game.player_for(73)
	_check(not _row(73).spectating and back.is_alive(), "Play puts her back in, alive", " / ".join(again))
	_check(_entities(73) == 1, "with exactly one player entity, no duplicate")
	_check(_row(73).kills == 2 and _row(73).present, "the scoreboard row and the score are kept")
	_check(not _game.spectate.is_spectating(73), "and she is no longer watching")
	_check(_game.match_node.scoreboard.find("73") == _row(73), "one row for her, not two")
	_done()


func _test_bot_fill() -> void:
	_section("bot fill")
	_fill()
	var bots := _module.bridge.bot_ids()
	var want: int = _module._bot_quota.wanted(2, _server.config.max_players)
	_check(bots.size() == want, "the quota fills to the wanted bots for two people", "%d bots, wanted %d" % [bots.size(), want])
	var before := bots.duplicate()
	var _o := await _switch("spectate")
	_fill()
	_check(_module.bridge.bot_ids() == before, "a spectator still holds her slot: bots unchanged, none doubled", str(_module.bridge.bot_ids()))
	_check(_module.bridge.bot_ids().size() + 2 <= _server.config.max_players or _server.config.max_players <= 0, "people and bots stay inside the slots")
	var _p := await _switch("play")
	_fill()
	_check(_module.bridge.bot_ids() == before, "and coming back changes nothing", str(_module.bridge.bot_ids()))
	var seen := {}
	var dup := false
	for p in _game.players():
		if seen.has(p.player_id):
			dup = true
		seen[p.player_id] = true
	_check(not dup and _game.players().size() == 2 + before.size(), "no duplicate entity in the game", "%d players" % _game.players().size())
	_check(_humans_playing() == 2, "both people are playing again")
	for id in before:
		_check(_row(id) != null and not _row(id).spectating, "bot %d is on the board and playing" % id)
	_done()


func _test_refusals() -> void:
	_section("refusals")
	var r1 := await _switch("play")
	_check(" ".join(r1).length() > 0, "Play while playing is answered, not silent", " / ".join(r1))
	_check(_entities(73) == 1 and _game.player_for(73).is_alive(), "and nothing changed")
	var _s := await _switch("spectate")
	var r2 := await _switch("spectate")
	_check(" ".join(r2).length() > 0 and _row(73).spectating, "Spectate twice is answered and she stays out", " / ".join(r2))
	var _b := await _switch("play")
	_check(not _row(73).spectating and _entities(73) == 1, "Play brings her back once")
	_done()


