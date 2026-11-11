extends "headless_ctf.gd"

## Carrying a flag: one-handed items only (bots too), the drop key throws the flag ahead of the aim,
## the dropped flag flies and rests upright on the floor, the cvars, and the carry state on the wire.

const ArenaFlagCarry := preload("../game/arena_flag_carry.gd")
const ArenaBots := preload("../game/arena_bots.gd")

const SECTIONS_CARRY := 7
const CHECKS_CARRY := 50


func _run() -> void:
	print("game-arena headless ctf carry")
	print("")

	await _test_one_hand()
	await _test_drop_key()
	await _test_carry_cvars()
	await _test_carry_wire()
	await _test_bot_carrier()
	await _test_bot_roles()
	await _test_bot_personas()

	_report_sections(_entered, _completed, SECTIONS_CARRY, CHECKS_CARRY)


## A command pair for [param id]: looking along its yaw, level, with [param fire] built by [param edit].
func _pair(game: ArenaGame, id: int, edit: Callable = Callable()) -> Array:
	var p := game.player_for(id)
	var move := DotFpsCommand.new()
	move.yaw = p.controller.state.yaw
	move.pitch = 0.0
	var fire := DotWeaponCommand.new()
	fire.yaw = move.yaw
	fire.pitch = move.pitch
	if edit.is_valid():
		edit.call(fire)
	return [move, fire]


func _ticks(game: ArenaGame, n: int, cmds: Callable = Callable()) -> void:
	for i in n:
		game.tick(cmds.call() if cmds.is_valid() else {})


## A game with team 1's first bot holding team 2's flag in an open spot, everyone else far away.
func _carrying(rules_edit: Callable = Callable()) -> Array:
	var game := _ctf_game(rules_edit)
	if game == null:
		return []
	var one := _team_ids(game, 1)
	for id in _team_ids(game, 2) + [one[1]]:
		_go(game, id, Vector3(900, 0, 900), 1)
	var thief: int = one[0]
	_go(game, thief, _stand_of(game, 2))
	_go(game, thief, Vector3(5, 0, 5), 2)
	return [game, thief]


func _test_one_hand() -> void:
	_section("ctf carry: one-handed items only")
	var got := _carrying()
	if got.is_empty():
		return
	var game: ArenaGame = got[0]
	var thief: int = got[1]
	var p := game.player_for(thief)
	_check(_flag(game, 2).carrier == str(thief) and p.flag_one_hand, "the carrier is marked one-handed")
	_ticks(game, TICK_RATE, func() -> Dictionary: return {thief: _pair(game, thief)})
	var allowed := ArenaFlagCarry.allowed_slots()
	_check(allowed.has(p.arsenal.current_slot()), "a two-handed gun in hand is put away for a one-handed item", str(p.arsenal.current_slot()))
	_ticks(game, TICK_RATE, func() -> Dictionary: return {thief: _pair(game, thief, func(f: DotWeaponCommand) -> void: f.slot = AwWeaponIds.SLOT_PRIMARY)})
	_check(allowed.has(p.arsenal.current_slot()), "the primary's key does nothing while carrying", str(p.arsenal.current_slot()))
	var seen := {}
	for i in 6:
		_ticks(game, 1, func() -> Dictionary: return {thief: _pair(game, thief, func(f: DotWeaponCommand) -> void: f.set_button(DotWeaponCommand.BUTTON_NEXT, true))})
		_ticks(game, TICK_RATE / 2, func() -> Dictionary: return {thief: _pair(game, thief)})
		seen[p.arsenal.current_slot()] = true
	var only_allowed := seen.keys().all(func(s: int) -> bool: return allowed.has(s))
	_check(only_allowed and seen.size() >= 2, "next weapon cycles through the one-handed items only", str(seen.keys()))
	_go(game, thief, _stand_of(game, 1))
	_check(not p.flag_one_hand, "a capture ends the rule")
	_ticks(game, TICK_RATE, func() -> Dictionary: return {thief: _pair(game, thief, func(f: DotWeaponCommand) -> void: f.slot = AwWeaponIds.SLOT_PRIMARY)})
	_check(p.arsenal.current_slot() == AwWeaponIds.SLOT_PRIMARY, "and the primary comes back", str(p.arsenal.current_slot()))
	await _free(game)
	_done()


func _test_drop_key() -> void:
	_section("ctf carry: the drop key throws the flag ahead")
	var got := _carrying()
	if got.is_empty():
		return
	var game: ArenaGame = got[0]
	var thief: int = got[1]
	var p := game.player_for(thief)
	_ticks(game, TICK_RATE, func() -> Dictionary: return {thief: _pair(game, thief)})
	var slot := p.arsenal.current_slot()
	var drops := game.weapon_drops.count() if game.weapon_drops != null else 0
	var feet := p.controller.state.position
	var aim := p.aim_direction()
	aim.y = 0.0
	aim = aim.normalized()
	game.tick({thief: _pair(game, thief, func(f: DotWeaponCommand) -> void: f.set_button(DotWeaponCommand.BUTTON_DROP, true))})
	var flag := _flag(game, 2)
	_check(flag.state == DotObjectiveFlag.State.DROPPED, "the drop key drops the flag", str(flag.state))
	_check((flag.at - feet).dot(aim) > 0.4, "ahead of where the carrier aims", str(flag.at - feet))
	_check(p.arsenal.current_slot() == slot and (game.weapon_drops == null or game.weapon_drops.count() == drops), "and the weapon stays in hand")
	_check(ArenaFlagCarry.flying(game, 2), "the flag is in flight")
	_check(not p.flag_one_hand, "the rule ends with the flag")
	var heights: Array[float] = []
	for i in TICK_RATE * 3:
		game.tick({thief: _pair(game, thief)})
		heights.append(flag.at.y)
		if not ArenaFlagCarry.flying(game, 2):
			break
	_check(not ArenaFlagCarry.flying(game, 2), "it comes to rest", str(game.objectives.flag_motion))
	_check(absf(flag.at.y - feet.y) < 0.1, "on the floor", "%.2f against %.2f" % [flag.at.y, feet.y])
	var flat := Vector3(flag.at.x - feet.x, 0.0, flag.at.z - feet.z)
	_check(flat.dot(aim) > ArenaFlagCarry.REACH, "having slid on past the hand", str(flat))
	_check(flag.state == DotObjectiveFlag.State.DROPPED, "the dropper does not take it straight back", str(flag.carrier))
	await _free(game)
	_done()


func _test_carry_cvars() -> void:
	_section("ctf carry: the settings")
	var cv := ArenaModule.FLAG_CARRY_CVARS
	_check(cv.has(&"arena_ctf_one_hand") and cv.has(&"arena_ctf_drop_key") and cv.has(&"arena_ctf_drop_speed") and cv.has(&"arena_ctf_flag_physics"),
		"one-hand, drop key, drop speed and flag physics are cvars")
	_check(ArenaFlagCarry.one_hand and ArenaFlagCarry.drop_key and ArenaFlagCarry.physics and ArenaFlagCarry.drop_speed == 4.0, "on by default, 4 m/s")

	ArenaFlagCarry.set_setting("physics", "0")
	var got := _carrying()
	if got.is_empty():
		ArenaFlagCarry.set_setting("physics", "1")
		return
	var game: ArenaGame = got[0]
	var thief: int = got[1]
	var feet := game.player_for(thief).controller.state.position
	game.tick({thief: _pair(game, thief, func(f: DotWeaponCommand) -> void: f.set_button(DotWeaponCommand.BUTTON_DROP, true))})
	var flag := _flag(game, 2)
	_check(flag.state == DotObjectiveFlag.State.DROPPED and not ArenaFlagCarry.flying(game, 2), "physics off: the flag drops without flying")
	_check(absf(flag.at.y - feet.y) < 0.1, "straight onto the floor", "%.2f against %.2f" % [flag.at.y, feet.y])
	ArenaFlagCarry.set_setting("physics", "1")
	await _free(game)

	ArenaFlagCarry.set_setting("drop_key", "0")
	ArenaFlagCarry.set_setting("one_hand", "0")
	got = _carrying()
	if got.is_empty():
		ArenaFlagCarry.set_setting("drop_key", "1")
		ArenaFlagCarry.set_setting("one_hand", "1")
		return
	game = got[0]
	thief = got[1]
	var p := game.player_for(thief)
	_check(not p.flag_one_hand, "one-hand off: the carrier keeps any gun")
	_ticks(game, TICK_RATE, func() -> Dictionary: return {thief: _pair(game, thief, func(f: DotWeaponCommand) -> void: f.slot = AwWeaponIds.SLOT_PRIMARY)})
	_check(p.arsenal.current_slot() == AwWeaponIds.SLOT_PRIMARY, "even the primary", str(p.arsenal.current_slot()))
	game.tick({thief: _pair(game, thief, func(f: DotWeaponCommand) -> void: f.set_button(DotWeaponCommand.BUTTON_DROP, true))})
	_check(_flag(game, 2).carrier == str(thief), "drop key off: the key does not drop the flag")
	ArenaFlagCarry.set_setting("drop_key", "1")
	ArenaFlagCarry.set_setting("one_hand", "1")
	await _free(game)
	_done()


func _test_carry_wire() -> void:
	_section("ctf carry: a client learns the rule and the flight")
	var got := _carrying()
	if got.is_empty():
		return
	var server: ArenaGame = got[0]
	var thief: int = got[1]
	server.tick({thief: _pair(server, thief, func(f: DotWeaponCommand) -> void: f.set_button(DotWeaponCommand.BUTTON_DROP, true))})
	var wire: Dictionary = JSON.parse_string(server.objectives.ctf_wire_text(server.current_tick(), true))
	_check(wire.has("fc") and int(wire["fc"]["oh"]) == 1, "the wire carries the one-hand rule", str(wire.get("fc")))
	_check((wire["fc"]["mv"] as Array).has(2.0) or (wire["fc"]["mv"] as Array).has(2), "and which flag flies")
	var client := ArenaGame.new()
	client.name = "CarryClient"
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
	client.objectives.apply_ctf_text(JSON.stringify(wire))
	_check(ArenaFlagCarry.flying(client, 2), "the client knows the flag is in flight")
	_check(ArenaFlagCarry.try_drop(client, thief, server.player_for(thief)) == false, "and never drops a flag itself")
	await _free(client)
	await _free(server)
	_done()


func _test_bot_carrier() -> void:
	_section("ctf carry: a bot carrier is one-handed too")
	var got := _carrying()
	if got.is_empty():
		return
	var game: ArenaGame = got[0]
	var thief: int = got[1]
	var bot := game.player_for(thief)
	var mind := ArenaBots.Mind.new()
	var slots := {}
	for i in TICK_RATE * 3:
		if _flag(game, 2).carrier != str(thief):
			break
		var cmd: Array = ArenaBots.think(game, bot, mind, game.current_tick() + 1, float(TICK_RATE))
		game.tick({thief: cmd})
		if i > TICK_RATE:
			slots[bot.arsenal.current_slot()] = true
	var allowed := ArenaFlagCarry.allowed_slots()
	_check(not slots.is_empty() and slots.keys().all(func(s: int) -> bool: return allowed.has(s)),
		"a thinking bot holding the flag only ever holds one-handed items", str(slots.keys()))
	_check(_flag(game, 2).carrier == str(thief), "and still carries it", str(_flag(game, 2).state))
	await _free(game)
	_done()


func _test_bot_roles() -> void:
	_section("ctf carry: thinking bots know the flags and take team jobs")
	var got := _carrying()
	if got.is_empty():
		return
	var game: ArenaGame = got[0]
	var thief: int = got[1]
	# The shares alone decide here; _test_bot_personas has the leans.
	ArenaBots.personas_mode = ArenaBots.PERSONAS_OFF
	var minds := {}
	for id in game.player_ids():
		minds[id] = ArenaBots.Mind.new()
	for i in TICK_RATE:
		var cmds := {}
		for id: int in minds:
			cmds[id] = ArenaBots.think(game, game.player_for(id), minds[id], game.current_tick() + 1, float(TICK_RATE))
		game.tick(cmds)
	var objective := ArenaBots.world_for(game).objective
	_check(objective != null and objective.active and objective.has_flag(1) and objective.has_flag(2), "the bots' world holds both flags")
	if objective == null:
		await _free(game)
		return
	_check(objective.carrier_of(2) == thief and objective.state_of(2) == DotBotObjective.CARRIED, "and who carries one", str(objective.carrier_of(2)))
	_check(objective.capture_for(1).distance_to(_stand_of(game, 1)) < 0.01, "a carrier scores on its own stand", str(objective.capture_for(1)))
	var red := objective.roles_in(1)
	var blue := objective.roles_in(2)
	_check(red[DotBotObjective.ATTACK] == 1 and red[DotBotObjective.DEFEND] == 1, "two bots on a side: one attacks, one defends", str(red))
	_check(blue[DotBotObjective.ATTACK] == 1 and blue[DotBotObjective.DEFEND] == 1, "on both sides", str(blue))
	var goal: DotBotGoal = (minds[thief] as ArenaBots.Mind).brain.goal
	_check(goal.kind == &"capture" and goal.urgent, "the carrier's job is to run it home", "%s %s" % [goal.kind, goal.urgent])
	ArenaBots.forget(game, thief)
	_check(objective.role_of(thief) == DotBotObjective.ROAM, "a bot that left gives its job up")
	ArenaBots.personas_mode = ""
	await _free(game)
	_done()


func _test_bot_personas() -> void:
	_section("ctf carry: every bot is dealt its own character, and bot_personas off shares one")
	var game := _ctf_game()
	if game == null:
		return
	ArenaBots.personas_mode = ""
	var minds := {}
	for id in game.player_ids():
		minds[id] = ArenaBots.Mind.new()
	var think_all := func() -> void:
		for i in 3:
			var cmds := {}
			for id: int in minds:
				cmds[id] = ArenaBots.think(game, game.player_for(id), minds[id], game.current_tick() + 1, float(TICK_RATE))
			game.tick(cmds)
	think_all.call()
	var base := DotBotSettings.of(game)
	var ids := {}
	var own := true
	var no_faster := true
	var aims := {}
	for id: int in minds:
		var mind: ArenaBots.Mind = minds[id]
		if mind.persona == null or mind.settings == null or mind.brain.settings != mind.settings:
			own = false
			continue
		ids[mind.persona.id] = true
		aims[snappedf(mind.settings.profile.aim_error, 0.001)] = true
		no_faster = no_faster and mind.settings.profile.turn_rate <= base.profile.turn_rate
	_check(own, "each bot thinks with settings of its own")
	_check(ids.size() == minds.size(), "%d bots get %d different personas" % [minds.size(), ids.size()], str(ids.keys()))
	_check(aims.size() == minds.size(), "and aim differently", str(aims.keys()))
	_check(no_faster, "none turns faster than bot_turn_rate")
	var _hard := base.set_difficulty("hard")
	think_all.call()
	var first: ArenaBots.Mind = minds[minds.keys()[0]]
	_check(first.settings.profile.preset_name == "hard", "a bot_difficulty change reaches every persona", first.settings.profile.preset_name)
	ArenaBots.personas_mode = ArenaBots.PERSONAS_OFF
	think_all.call()
	_check(first.persona == null and first.brain.settings == base, "bot_personas off: the brain is made again on the shared settings")
	ArenaBots.personas_mode = ""
	await _free(game)
	_done()
