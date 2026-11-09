extends "headless_ctf.gd"

## Carrying a flag: one-handed items only (bots too), the drop key throws the flag ahead of the aim,
## the dropped flag flies and rests upright on the floor, the cvars, and the carry state on the wire.

const ArenaFlagCarry := preload("../game/arena_flag_carry.gd")
const ArenaBots := preload("../game/arena_bots.gd")

const SECTIONS_CARRY := 5
const CHECKS_CARRY := 35


func _run() -> void:
	print("game-arena headless ctf carry")
	print("")

	await _test_one_hand()
	await _test_drop_key()
	await _test_carry_cvars()
	await _test_carry_wire()
	await _test_bot_carrier()

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
