extends "headless_match_part2.gd"

## Capture the flag end to end: scripted bots carry flags on a real game, two and three teams, drop and return, both limits, the fallback bases, authored flag stands and the replicated state.

const SECTIONS_CTF := 7
const CHECKS_CTF := 58


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena headless ctf")
	print("")

	await _test_flow()
	await _test_drop_and_return()
	await _test_limits()
	await _test_three_teams()
	await _test_bases()
	await _test_replication()
	await _test_cvars()

	_report_sections(_entered, _completed, SECTIONS_CTF, CHECKS_CTF)


func _ctf_game(rules_edit: Callable = Callable(), map: ArenaMap = null, ids: Array = [910, 911, 912, 913]) -> ArenaGame:
	var game := ArenaGame.new()
	game.name = "CtfGame"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	if rules_edit.is_valid():
		rules_edit.call(game.ctf_rules)
	game.mode = ArenaMode.capture_the_flag(3)
	add_child(game)
	var ready := game.setup(map if map != null else ArenaMap.dm_atrium())
	if not _check(ready.ok, "a capture-the-flag game sets up", str(ready.error)):
		game.queue_free()
		remove_child(game)
		return null
	game.start(0)
	for id: int in ids:
		var _p := game.add_player(id, "Bot%d" % id)
	_go_live(game)
	return game


func _free(game: ArenaGame) -> void:
	game.queue_free()
	remove_child(game)
	await get_tree().process_frame


func _team_ids(game: ArenaGame, team: int) -> Array[int]:
	var out: Array[int] = []
	for id in game.player_ids():
		if game.team_of(id) == team:
			out.append(id)
	return out


func _flag(game: ArenaGame, team: int) -> DotObjectiveFlag:
	return game.objectives.ctf.flag_of(team)


## Scripted bots: put one on a spot and tick, as a bot that walked there would have.
func _go(game: ArenaGame, id: int, at: Vector3, ticks: int = 3) -> void:
	for i in ticks:
		_stand(game, id, at)
		game.tick({})


func _stand_of(game: ArenaGame, team: int) -> Vector3:
	return _flag(game, team).def.area.centre


func _test_flow() -> void:
	_section("ctf: bots take the enemy flag home and score")
	var game := _ctf_game()
	if game == null:
		return
	var ctf := game.objectives.ctf
	var one := _team_ids(game, 1)
	var two := _team_ids(game, 2)
	_check(one.size() == 2 and two.size() == 2, "four bots, two sides of two")
	_check(ctf != null and ctf.flags().size() == 2, "two flags from the map's spawns")
	var thief := one[0]
	_go(game, two[0], Vector3(900, 0, 900))
	_go(game, two[1], Vector3(900, 0, 900))
	_go(game, one[1], Vector3(-900, 0, 900))
	_go(game, thief, _stand_of(game, 2))
	_check(_flag(game, 2).carrier == str(thief), "a bot on the enemy stand takes the flag")
	var tunables := game.player_for(thief).controller.tunables
	var base: float = tunables.get_meta("arena_base_speed")
	_check(is_equal_approx(tunables.max_speed, base * game.ctf_rules.carrier_speed), "and runs slower for it")
	_go(game, thief, Vector3.ZERO)
	_check(_flag(game, 2).carrier == str(thief) and ctf.scores[1] == 0, "carrying across the middle scores nothing")
	_go(game, thief, _stand_of(game, 1))
	_check(ctf.scores[1] == 1 and _flag(game, 2).is_home(), "bringing it to its own stand scores and returns the flag")
	_check(game.match_node.scoreboard.team_score(1) > 0, "dot-match has the point through report_objective")
	_check(is_equal_approx(tunables.max_speed, base), "and the slowdown ends")
	await _free(game)
	_done()


func _test_drop_and_return() -> void:
	_section("ctf: a dead carrier drops, a team-mate returns")
	var game := _ctf_game(func(r: DotObjectiveCtfRules) -> void:
		r.return_sec = 4
		r.drop_sec = 1)
	if game == null:
		return
	var announced: Array = []
	game.ctf_announced.connect(func(t: String) -> void: announced.append(t))
	var one := _team_ids(game, 1)
	var two := _team_ids(game, 2)
	for id in two + [one[1]]:
		_go(game, id, Vector3(900, 0, 900), 1)
	var thief := one[0]
	_go(game, thief, _stand_of(game, 2))
	_check(_flag(game, 2).carrier == str(thief), "taken")
	_go(game, thief, Vector3(5, 0, 5))
	_kill_through_combat(game, two[0], thief)
	game.tick({})
	var flag := _flag(game, 2)
	_check(flag.state == DotObjectiveFlag.State.DROPPED, "the carrier's death drops the flag")
	_check(not announced.is_empty(), "and the server announces it", str(announced))
	_go(game, two[1], flag.at)
	_check(flag.is_home(), "its own team touching it returns it")
	_go(game, thief, _stand_of(game, 2))
	_go(game, thief, Vector3(5, 0, 5), 1)
	_kill_through_combat(game, two[0], thief)
	game.tick({})
	for i in 5 * TICK_RATE:
		game.tick({})
	_check(flag.is_home(), "left alone, a dropped flag goes home after the return time")
	await _free(game)
	_done()


func _test_limits() -> void:
	_section("ctf: capture limit and time limit end the match")
	var game := _ctf_game(func(r: DotObjectiveCtfRules) -> void: r.capture_limit = 2)
	if game == null:
		return
	game.apply_match_limits()
	_check(game.match_node.rules.score_limit == 2, "the capture limit is the match's score limit")
	var one := _team_ids(game, 1)
	for id in _team_ids(game, 2) + [one[1]]:
		_go(game, id, Vector3(900, 0, 900), 1)
	for i in 2:
		_go(game, one[0], _stand_of(game, 2))
		_go(game, one[0], _stand_of(game, 1))
	_check(game.objectives.ctf.scores[1] == 2 and game.objectives.ctf.winner == 1, "the second capture ends the flag game for team 1")
	for i in 3:
		game.tick({})
	_check(not game.match_node.is_live(), "and the match is over")
	await _free(game)

	var timed := _ctf_game(func(r: DotObjectiveCtfRules) -> void:
		r.capture_limit = 0
		r.time_limit_sec = 5)
	if timed == null:
		return
	timed.apply_match_limits()
	_check(timed.match_node.rules.score_limit == 0 and timed.match_node.rules.time_limit_sec == 5.0, "a time limit with no capture limit", "%s %s" % [timed.match_node.rules.score_limit, timed.match_node.rules.time_limit_sec])
	for i in 7 * TICK_RATE:
		timed.tick({})
	_check(not timed.match_node.is_live(), "ends the match when it runs out")
	await _free(timed)
	_done()


func _test_three_teams() -> void:
	_section("ctf: three teams")
	var edit := func(r: DotObjectiveCtfRules) -> void: r.team_count = 3
	var game := _ctf_game(edit, null, [910, 911, 912])
	if game == null:
		return
	_check(game.mode.team_count == 3 and game.objectives.ctf.flags().size() == 3, "three sides and three flags")
	var bases: Array[Vector3] = []
	for t in [1, 2, 3]:
		bases.append(_stand_of(game, t))
	_check(bases[0].distance_to(bases[1]) > 5.0 and bases[1].distance_to(bases[2]) > 5.0 and bases[0].distance_to(bases[2]) > 5.0, "the stands are apart")
	var by_team := {}
	for id in game.player_ids():
		by_team[game.team_of(id)] = id
	_check(by_team.size() == 3, "each bot is on its own side", str(by_team))
	var thief: int = by_team[1]
	for t in [2, 3]:
		_go(game, by_team[t], Vector3(900, 0, 900 + t), 1)
	_go(game, thief, _stand_of(game, 3))
	_check(_flag(game, 3).carrier == str(thief), "team 1 takes team 3's flag")
	_go(game, thief, _stand_of(game, 1))
	_check(game.objectives.ctf.scores[1] == 1 and game.objectives.ctf.scores[3] == 0, "and scores it at team 1's own stand")
	await _free(game)
	_done()


func _test_bases() -> void:
	_section("ctf: where the stands go")
	var game := _ctf_game()
	if game == null:
		return
	var sites: Array[DotSpawnSite] = game.player_stack.spawns.sites()
	var stand := DotSpawnSite.point(&"auth_flag", Vector3(7, 1, 7), 0.0, &"1")
	stand.meta[DotSpawnPointDef.META_KIND] = "flag"
	game.player_stack.spawns.add_site(stand)
	_check(sites.size() > 2, "the map has spawn sites")
	var bases := game.objectives.ctf_bases()
	_check(bases[1] == Vector3(7, 1, 7), "a flag spawn placed for team 1 is where team 1's stand goes")
	_check(bases[2] != bases[1], "and team 2 keeps the middle of its own spawns")
	var hit := game.player_stack.spawns.choose(DotSpawnRequest.make("910", &"", &"", game.current_tick(), {"kind": "player"}))
	_check(not hit.ok or (hit.value as DotSpawnChoice).site.id != &"auth_flag", "nobody respawns on a flag stand")
	await _free(game)

	var box := _ctf_game(Callable(), ArenaMap.dm_box())
	if box == null:
		return
	var fb := box.objectives.ctf_bases()
	_check(fb.size() == 2 and (fb[1] as Vector3).distance_to(fb[2]) > 4.0, "a map without flag or team spawns still gets two bases apart")
	await _free(box)
	_done()


func _test_replication() -> void:
	_section("ctf: the server decides, the client mirrors")
	var server := _ctf_game()
	if server == null:
		return
	var client := ArenaGame.new()
	client.name = "CtfClient"
	client.tick_rate = TICK_RATE
	client.headless = true
	client.register_service = false
	client.is_authority = false
	client.mode = ArenaMode.capture_the_flag(3)
	add_child(client)
	var ready := client.setup(ArenaMap.dm_atrium())
	if not _check(ready.ok, "a client game sets up", str(ready.error)):
		await _free(server)
		return
	var one := _team_ids(server, 1)
	for id in _team_ids(server, 2) + [one[1]]:
		_go(server, id, Vector3(900, 0, 900), 1)
	_go(server, one[0], _stand_of(server, 2))
	var text: String = server.objectives.ctf_wire_text(server.current_tick(), true)
	_check(text != "", "the server has state to send")
	client.objectives.apply_ctf_text(text)
	var mirrored := client.objectives.ctf.flag_of(2)
	_check(mirrored.state == DotObjectiveFlag.State.CARRIED and mirrored.carrier == str(one[0]), "the client sees the carrier")
	_check(is_equal_approx(client.objectives.speed_scale(one[0]), server.ctf_rules.carrier_speed), "and applies the same slowdown")
	var before := mirrored.state
	var clock := client.objectives.ctf.live_ticks
	client.objectives.tick(0.0)
	_check(mirrored.state == before and client.objectives.ctf.live_ticks == clock, "a client never simulates a flag")
	_go(server, one[0], _stand_of(server, 1))
	client.objectives.apply_ctf_text(server.objectives.ctf_wire_text(server.current_tick(), true))
	_check(client.objectives.ctf.scores[1] == 1 and mirrored.is_home(), "a capture arrives as a score")
	server.objectives.apply_ctf_text(text)
	_check(server.objectives.ctf.scores[1] == 1, "and the server ignores a state sent to it")
	_check(server.objectives.ctf_wire_text(server.current_tick()) == "", "an unchanged state is not sent again at once")
	_check(ArenaEvents.Kind.keys().has("CTF"), "the CTF event kind exists")
	# A real dedicated-server client never has the mode set locally: its own `mode` is the default (free-for-all)
	# and the server's arrives as RULES mode_index. The flag layer has to follow that.
	var real := ArenaGame.new()
	real.name = "CtfRealClient"
	real.tick_rate = TICK_RATE
	real.headless = true
	real.register_service = false
	real.is_authority = false
	add_child(real)
	var real_ready := real.setup(ArenaMap.dm_atrium())
	_check(real_ready.ok and real.objectives == null, "a client left on the default mode has no flag layer")
	real.set_movement_rules({"mode_index": ArenaModes.ids().find(&"ctf")})
	_check(real.objectives != null and real.objectives.ctf != null, "and builds it the moment the server says capture the flag")
	real.objectives.apply_ctf_text(text)
	_check(real.objectives.ctf.flag_of(2).state == DotObjectiveFlag.State.CARRIED, "and then mirrors the server's flags")
	await _free(real)
	await _free(client)
	await _free(server)
	_done()


func _test_cvars() -> void:
	_section("ctf: every number is a cvar")
	var module_keys := ArenaModule.CTF_CVARS.keys()
	for key: String in ArenaModule.CTF_CVARS:
		_check(DotObjectiveCtfRules.new().get(ArenaModule.CTF_CVARS[key][0]) != null, "%s names a rule" % key)
	_check(module_keys.size() == 8, "capture limit, time limit, return, drop, carrier speed, friendly return, flag at home and teams")
	var rules := DotObjectiveCtfRules.new()
	_check(rules.validate().ok and rules.team_count == 2 and rules.capture_limit == 3, "the defaults are two teams and three captures")
	_done()
