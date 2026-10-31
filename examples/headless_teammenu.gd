extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaTeamMenu := preload("../game/arena_team_menu.gd")

## The team menu's server half in this game: the cards come from config, N teams, free-for-all, refusals, spectate always, and the switch itself.
##
## [codeblock]
## godot --headless --path . res://examples/headless_teammenu.tscn
## [/codeblock]

const EXPECTED_CHECKS := 58
const EXPECTED_SECTIONS := 7

var _checks := 0
var _failed := 0
var _sections := 0
var _now := 100.0
var _cvars := {}
var _menus: Array[ArenaTeamMenu] = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _add(n: String, v: Variant, d: String, f: int) -> DotConVar:
	var cv := DotConVar.new(n, str(v), d, f)
	_cvars[n] = cv
	return cv


func _cv(n: String, v: String) -> void:
	(_cvars[n] as DotConVar).force_set(v)


func _game(mode: ArenaMode) -> ArenaGame:
	var game := ArenaGame.new()
	game.name = "G%d" % get_child_count()
	game.tick_rate = 64
	game.headless = true
	game.register_service = false
	game.mode = mode
	add_child(game)
	var _s := game.setup(ArenaMap.dm_atrium())
	game.start(0)
	return game


func _menu(game: ArenaGame) -> ArenaTeamMenu:
	_cvars.clear()
	var menu := ArenaTeamMenu.new()
	menu.bind(game, _add, null)
	_menus.append(menu)
	menu.server.clock_fn = func() -> float: return _now
	return menu


func _names(data: Dictionary) -> Array:
	var out: Array = []
	for t: Dictionary in data["teams"]:
		out.append(t["name"])
	return out


func _run() -> void:
	# 1. Two teams, names from the stock pair.
	_sections += 1
	var game := _game(ArenaMode.team_deathmatch())
	var _a := game.add_player(31, "A")
	var _b := game.add_player(32, "B")
	var menu := _menu(game)
	var server: Variant = menu.server
	var data: Dictionary = server.menu_for(31)
	_check(not data["ffa"] and data["teams"].size() == 2, "two teams: two cards", str(_names(data)))
	_check(_names(data) == ["Red", "Blue"], "and the stock names")
	_check(data["spectate_ok"] and data["enabled"], "spectate is offered and the menu is enabled")
	var counts := 0
	for t: Dictionary in data["teams"]:
		counts += int(t["count"])
	_check(counts == 2, "the counts add up to the players in the match", str(counts))
	var mine := game.team_of(31)
	_check(mine in [1, 2], "a joining player was put on a team", str(mine))
	var other := 3 - mine
	var cards_current := 0
	for t: Dictionary in data["teams"]:
		if t["current"]:
			cards_current += 1
	_check(cards_current == 1, "exactly one card is marked as the current team")

	# 2. Names and colours from config; more names than the mode has makes more teams.
	_sections += 1
	_cv("mp_team_names", "Alpha,Beta,Gamma,Delta")
	_cv("mp_team_colours", "#ff0000,#00ff00,#0000ff")
	data = server.menu_for(31)
	_check(data["teams"].size() == 4, "four names in mp_team_names make four teams", str(_names(data)))
	_check(_names(data) == ["Alpha", "Beta", "Gamma", "Delta"], "named from the config")
	_check(data["teams"][1]["colour"] == "00ff00" and data["teams"][3]["colour"] == ArenaTeamMenu.PALETTE[3].trim_prefix("#"), "colours from config, then the palette", str(data["teams"][1]["colour"]))
	_cv("mp_team_names", "Home,Away")
	data = server.menu_for(31)
	_check(_names(data).slice(0, 2) == ["Home", "Away"], "renaming is live", str(_names(data)))
	_check(game.teams()[0].display_name == "Home", "and reaches the team manager the scoreboard reads")
	_cv("mp_team_names", "Alpha,Beta,Gamma,Delta")

	# 3. A switch is validated on the server.
	_sections += 1
	_cv("mp_teamswitch_cooldown", "5")
	var res: DotResult = server.request(31, "3")
	_check(res.ok and game.team_of(31) == 3, "a switch to a team with room works", str(game.team_of(31)))
	_check(game.player_for(31).team == 3, "and the player's own team follows")
	_check(game.player_for(31).is_alive(), "without killing them (mp_teamswitch_kill 0)")
	res = server.request(31, "4")
	_check(not res.ok and game.team_of(31) == 3, "a second switch inside the cooldown is refused", res.error.message if res.error != null else "")
	_check(server.menu_for(31)["wait"] > 0.0, "the menu says how long to wait")
	_now += 6.0
	res = server.request(31, "3")
	_check(not res.ok, "the team you are on is refused")
	res = server.request(31, "9")
	_check(not res.ok, "a team that does not exist is refused")
	res = server.request(31, "bogus")
	_check(not res.ok, "so is a word that is not a choice")
	_cv("mp_team_max", "1")
	res = server.request(32, "3")
	_check(not res.ok and "full" in res.error.message.to_lower(), "a full team is refused", res.error.message if res.error != null else "")
	_check(bool(server.menu_for(32)["teams"][2]["closed"] != ""), "and its card says so")
	_cv("mp_team_max", "0")
	_cv("mp_teamswitch_imbalance", "0")
	res = server.request(32, "3")
	_check(not res.ok, "the imbalance limit refuses a team already ahead", res.error.message if res.error != null else "")
	_cv("mp_teamswitch_imbalance", "-1")
	_now += 6.0
	res = server.request(32, "3")
	_check(res.ok and game.team_of(32) == 3, "with no imbalance limit it goes through")
	_cv("mp_teamswitch_enabled", "0")
	_now += 6.0
	res = server.request(32, "1")
	_check(not res.ok and not server.menu_for(32)["enabled"], "mp_teamswitch_enabled 0 shuts the menu")
	_cv("mp_teamswitch_enabled", "1")
	_cv("mp_teamswitch_kill", "1")
	_now += 6.0
	res = server.request(32, "1")
	_check(res.ok and not game.player_for(32).is_alive(), "mp_teamswitch_kill 1 kills the player who switches")
	_check(game.match_node.scoreboard.record_for("32").deaths == 0, "and counts no death against them")
	_cv("mp_teamswitch_kill", "0")
	_cv("mp_teamswitch_imbalance", "1")

	# 4. Spectate is always there, and back.
	_sections += 1
	_now += 6.0
	res = server.request(31, "spectate")
	var record := game.match_node.scoreboard.record_for("31")
	_check(res.ok and record.spectating, "spectate takes a team player out of play")
	_check(not game.player_for(31).is_alive(), "their body is gone")
	_check(server.menu_for(31)["spectating"], "and the menu knows")
	_check(not bool(server.menu_for(31)["teams"][2]["current"]), "no team card is current while spectating")
	res = server.request(31, "spectate")
	_check(not res.ok, "spectating twice is refused")
	_now += 6.0
	res = server.request(31, "auto")
	_check(res.ok and not record.spectating and game.player_for(31).is_alive(), "auto brings them back to the smallest team, alive")
	_cv("mp_teamswitch_spectate", "0")
	_check(not server.menu_for(31)["spectate_ok"], "mp_teamswitch_spectate 0 hides it")
	_cv("mp_teamswitch_spectate", "1")
	_check(other in [1, 2], "the other stock team exists")

	# 5. Free-for-all: play and spectate only.
	_sections += 1
	var ffa := _game(ArenaMode.free_for_all())
	var _c := ffa.add_player(41, "C")
	var ffa_menu := _menu(ffa)
	data = ffa_menu.server.menu_for(41)
	_check(data["ffa"] and data["teams"].is_empty(), "a free-for-all has no team cards")
	_check(data["spectate_ok"], "but spectate is offered")
	res = ffa_menu.server.request(41, "play")
	_check(not res.ok, "play while already playing is refused")
	_now += 6.0
	res = ffa_menu.server.request(41, "spectate")
	_check(res.ok and ffa.match_node.scoreboard.record_for("41").spectating, "spectate works in a free-for-all")
	_check(ffa_menu.server.menu_for(41)["spectating"], "and the menu shows Play next")
	_now += 6.0
	res = ffa_menu.server.request(41, "play")
	_check(res.ok and ffa.player_for(41).is_alive() and not ffa.match_node.scoreboard.record_for("41").spectating, "play puts them back in, alive")

	# 6. Eight is the most; the mode stays in charge of its own count.
	_sections += 1
	var big := _game(ArenaMode.team_deathmatch())
	var _d := big.add_player(51, "D")
	var big_menu := _menu(big)
	_cv("mp_team_names", "A,B,C,D,E,F,G,H,I,J")
	data = big_menu.server.menu_for(51)
	_check(data["teams"].size() == 8, "ten names make eight teams, the most", str(data["teams"].size()))
	_check(ArenaMode.team_deathmatch().teams().size() == 2 and ArenaMode.free_for_all().teams().is_empty(), "the modes still say two teams and none")
	var four := ArenaMode.team_deathmatch()
	four.team_count = 4
	_check(four.teams().size() == 4 and four.teams()[2].spawn_tag == &"", "a four-team mode builds four, the extra two on the shared spawn pool")

	# 7. Offline: the menu's own callables (no server, no console) run the same rules.
	_sections += 1
	for mode: ArenaMode in [ArenaMode.free_for_all(), ArenaMode.team_deathmatch()]:
		var solo := _game(mode)
		var _me := solo.add_player(71, "Me")
		var _bot := solo.add_player(72, "Bot")
		var local := ArenaTeamMenu.new()
		var pair := local.bind_local(solo, func() -> int: return 71)
		_menus.append(local)
		local.server.clock_fn = func() -> float: return _now
		var offer: Dictionary = pair[0].call()
		var tag := "offline %s: " % ("ffa" if mode.teams().is_empty() else "teams")
		_check(offer["ffa"] == mode.teams().is_empty() and offer["spectate_ok"] and offer["enabled"], tag + "the offer works with no server", str(offer.keys()))
		var rec := solo.match_node.scoreboard.record_for("71")
		var deaths := rec.deaths
		var kills_other := solo.match_node.scoreboard.record_for("72").kills
		var r: DotResult = pair[1].call("spectate")
		_check(r.ok and rec.spectating and not solo.player_for(71).is_alive(), tag + "Spectate leaves play with no body left", str(r.error.message if r.error else ""))
		_check(rec.deaths == deaths and solo.match_node.scoreboard.record_for("72").kills == kills_other, tag + "leaving scores no death and gives no kill credit")
		_check(solo.spectate.is_spectating(71) and pair[0].call()["spectating"], tag + "dot-spectate has them, and the menu offers Play")
		if not mode.teams().is_empty():
			var on_teams := 0
			for t in solo.match_node.teams.teams:
				on_teams += solo.match_node.teams.count_on(t.id) if not t.is_spectator else 0
			_check(on_teams == 1, tag + "team counts no longer include them", str(on_teams))
		_now += 10.0
		r = pair[1].call("play" if mode.teams().is_empty() else "auto")
		_check(r.ok and not rec.spectating and solo.player_for(71).is_alive(), tag + "Play puts them back in, spawned")
		_check(not solo.spectate.is_spectating(71) and rec.present, tag + "no longer watching, still on the scoreboard")
		_now += 10.0
		r = pair[1].call("play" if mode.teams().is_empty() else "spectate")
		_check(r.ok or mode.teams().is_empty(), tag + "a second choice is answered")

	# The menu and its server point at each other; release() breaks the cycle so the exit check stays clean.
	for m in _menus:
		m.release()
	_menus.clear()
	_cvars.clear()
	var ok := _failed == 0 and _checks == EXPECTED_CHECKS and _sections == EXPECTED_SECTIONS
	print("%d checks, %d failed (expected %d), %d sections (expected %d)" % [_checks, _failed, EXPECTED_CHECKS, _sections, EXPECTED_SECTIONS])
	get_tree().quit(0 if ok else 1)
