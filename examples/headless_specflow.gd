extends "arena_server_suite.gd"

const ArenaNetBridge := preload("../game/arena_net_bridge.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaTestPorts := preload("test_ports.gd")

## Spectate then Play from the team menu, on a dedicated server with real sessions: `/teams spectate` and `/teams play` typed as a player, in a free-for-all.
## The world is asserted: the scoreboard row, the one player entity, the bot fill, who is alive.

var PORT := ArenaTestPorts.free_port()
const SERVER_DIR := "user://arena_specflow"
const TICK_RATE := 64

const SECTIONS := 3
const CHECKS := 24



var _admin: DotClientSession = null
var _player: DotClientSession = null



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


func _build() -> bool:
	if not await _boot_server("arena specflow", PORT, SERVER_DIR, TICK_RATE):
		return false

	# The flags an operator's groups.yml hands out: the admin group has cheats, slay and
	# teleport; the moderator group has slay and teleport and NOT cheats.
	_admin = _adopt(4001, 71, "Boss", ["generic", "cheats"], 60)
	_player = _adopt(4003, 73, "Ada", [], 0)

	_step(8)
	return _game.player_for(73) != null and _game.player_for(71) != null


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
	_check(_game.spectate.is_spectating(str(73)), "dot-spectate has her watching")
	_step(200)
	_check(not _game.player_for(73).is_alive(), "and she does not respawn by herself while out")
	var again := await _switch("play")
	_step(4)
	var back := _game.player_for(73)
	_check(not _row(73).spectating and back.is_alive(), "Play puts her back in, alive", " / ".join(again))
	_check(_entities(73) == 1, "with exactly one player entity, no duplicate")
	_check(_row(73).kills == 2 and _row(73).present, "the scoreboard row and the score are kept")
	_check(not _game.spectate.is_spectating(str(73)), "and she is no longer watching")
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


