extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaEvents := preload("../game/arena_events.gd")
const ArenaEvent := preload("../game/arena_event.gd")
const ArenaKnifeEvents := preload("../game/arena_knife_events.gd")

## Knife throwing through the whole game: the aim key throws the knife in hand, a miss bounces
## and settles, an enemy hit kills and the knife stays in the body, walking over either picks
## it up, a team-mate is not killed; plus the MORE/KNIFE wire record. Run `headless_knife_throw`.

const TICK_RATE := 64
const EXPECTED_SECTIONS := 2
const EXPECTED_CHECKS := 26

var _checks := 0
var _failed := 0
var _entered := 0
var _finished := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	Engine.physics_ticks_per_second = TICK_RATE
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _first_on_team(game: ArenaGame, ids: Array, thrower: int, same: bool) -> int:
	for id in ids.slice(1):
		if (game.team_of(id) == game.team_of(thrower)) == same:
			return id
	return 0


## Puts each of [param where]'s ids at its spot and everybody else 30 m off, held there for three ticks.
func _place(game: ArenaGame, ids: Array, where: Dictionary) -> void:
	for _k in 3:
		for id in ids:
			var p = game.player_for(id)
			if p != null:
				p.controller.state.position = where.get(id, Vector3(30.0 + float(id), where.values()[0].y, 30.0))
				p.controller.state.velocity = Vector3.ZERO
		game.tick({})


## The knife back in [param id]'s hand, or false when they have none.
func _knife_in_hand(game: ArenaGame, id: int) -> bool:
	var arsenal: DotWeaponArsenal = game.player_for(id).arsenal
	var home := arsenal.catalogue.get_def(&"knife").slot
	for _try in 4:
		var held := arsenal.slot_at(home)
		if held != null and held.id() == &"knife":
			break
		if held != null:
			var _gone := arsenal.drop_from_slot(home)
		elif not arsenal.carries(&"knife"):
			var _given := arsenal.give(&"knife", true)
	arsenal.bring_to_hand(home)
	var now := arsenal.current_def()
	if now == null or now.id != &"knife":
		print("knife not in hand: slot %d holds %s, in hand %s" % [home, arsenal.weapons_in(home).map(func(w): return w.id()), now.id if now != null else &""])
	return now != null and now.id == &"knife"


## One tick with the aim key down along yaw/pitch, then one with it up.
func _press_aim(game: ArenaGame, id: int, yaw: float, pitch: float) -> void:
	var fire := DotWeaponCommand.new()
	fire.yaw = yaw
	fire.pitch = pitch
	fire.set_button(DotWeaponCommand.BUTTON_AIM, true)
	var move := DotFpsCommand.new()
	game.tick({id: [move, fire]})
	game.tick({})


## Ticks until the only knife stops flying (or [param seconds] pass); returns it, or null if none.
func _settle(game: ArenaGame, seconds: float, hold: Dictionary = {}) -> DotWeaponKnives.Knife:
	for _k in int(seconds * TICK_RATE):
		var all := game.knives.entries()
		if all.is_empty() or (all[0] as DotWeaponKnives.Knife).phase != DotWeaponKnives.Phase.FLY:
			break
		for id in hold:
			game.player_for(id).controller.state.position = hold[id]
		game.tick({})
		await get_tree().physics_frame
	var left := game.knives.entries()
	return left[0] if not left.is_empty() else null


func _run() -> void:
	_test_wire()

	var game := ArenaGame.new()
	game.name = "G"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.team_deathmatch()
	add_child(game)
	var ready := game.setup(ArenaMap.dm_atrium())
	_check(ready.ok, "a team game sets up", str(ready.error))
	game.start(0)
	var ids: Array = []
	for i in 6:
		var _added := game.add_player(10 + i, "P%d" % i)
		ids.append(10 + i)
	game.tick({})
	_entered += 1
	var thrower := int(ids[0])
	var mate := _first_on_team(game, ids, thrower, true)
	var enemy := _first_on_team(game, ids, thrower, false)
	_check(game.knives != null and mate > 0 and enemy > 0, "the game builds the knives layer; a mate and an enemy", "%d %d" % [mate, enemy])
	var events: Array = []
	game.knives.changed.connect(func(id: int, _o: int, phase: int, _v: int, _a: Vector3, _m: Vector3) -> void: events.append([id, phase]))

	var floor_y: float = game.player_for(thrower).controller.state.position.y
	var here := Vector3(0.0, floor_y, 0.0)

	# A throw at the floor ahead: gone from the hand, bounces, and settles on the floor.
	_place(game, ids, {thrower: here})
	_check(_knife_in_hand(game, thrower), "the thrower has the knife in hand")
	_press_aim(game, thrower, 0.0, -35.0)
	var thrown := game.knives.count()
	_check(thrown == 1 and not game.player_for(thrower).arsenal.carries(&"knife"), "the aim key throws it: one knife out, none in the arsenal", str(thrown))
	var miss: DotWeaponKnives.Knife = await _settle(game, 6.0, {thrower: here})
	_check(miss != null and miss.phase == DotWeaponKnives.Phase.REST, "the miss comes to rest", str(miss.phase if miss != null else -1))
	_check(miss != null and miss.bounces >= 1, "after bouncing", str(miss.bounces if miss != null else -1))
	_check(miss != null and absf(miss.at.y - floor_y) < 0.4, "on the floor", "%s vs %s" % [miss.at if miss != null else Vector3.ZERO, floor_y])

	# Walking over it picks it up.
	var lying: Vector3 = miss.at if miss != null else here
	_place(game, ids, {thrower: Vector3(lying.x, floor_y, lying.z) + Vector3(0.4, 0.0, 0.0)})
	_check(game.player_for(thrower).arsenal.carries(&"knife") and game.knives.count() == 0, "walking over the knife on the floor picks it up")

	# Disabled: the aim key does not throw.
	game.knife_rules["enabled"] = false
	_place(game, ids, {thrower: here})
	var _again := _knife_in_hand(game, thrower)
	_press_aim(game, thrower, 0.0, -35.0)
	_check(game.knives.count() == 0 and game.player_for(thrower).arsenal.carries(&"knife"), "arena_knife_throw 0 keeps the knife in hand")
	game.knife_rules["enabled"] = true

	# At an enemy 6 m ahead: dead outright, the knife stays in them.
	var target := here + Vector3(0.0, 0.0, -6.0)
	_place(game, ids, {thrower: here, enemy: target})
	var hp_before: float = game.combat.health_of(enemy).health
	_check(hp_before > 50.0 and game.combat.health_of(enemy).alive, "the enemy stands there unhurt", str(hp_before))
	var eye: Vector3 = game.player_for(thrower).muzzle_position()
	var chest := target + Vector3(0.0, 1.1, 0.0)
	var pitch := rad_to_deg(atan2(chest.y - eye.y, eye.distance_to(Vector3(chest.x, eye.y, chest.z))))
	var _held := _knife_in_hand(game, thrower)
	events.clear()
	_press_aim(game, thrower, 0.0, pitch)
	var stuck: DotWeaponKnives.Knife = await _settle(game, 2.0, {enemy: target})
	_check(not game.combat.health_of(enemy).alive, "the thrown knife kills the enemy outright", str(game.combat.health_of(enemy).health))
	_check(stuck != null and stuck.phase == DotWeaponKnives.Phase.STUCK and stuck.victim == enemy, "and stays stuck in them", str(stuck.phase if stuck != null else -1))
	_check(stuck != null and stuck.at.distance_to(target) < 1.5, "at the body", str(stuck.at if stuck != null else Vector3.ZERO))
	_check(events.any(func(e: Array) -> bool: return int(e[1]) == DotWeaponKnives.Phase.STUCK), "the layer said so (a STUCK change for the wire)")
	for _k in 4:
		game.tick({})
	_check(game.knives.count() == 1, "the embedded knife stays while nobody comes for it")

	# Pickup off for the moment: walking over the body leaves it there.
	game.knife_rules["pickup"] = 0.0
	var body: Vector3 = stuck.at if stuck != null else target
	_place(game, ids, {thrower: Vector3(body.x, floor_y, body.z)})
	_check(game.knives.count() == 1 and not game.player_for(thrower).arsenal.carries(&"knife"), "arena_knife_throw_pickup 0 leaves it in the body")
	game.knife_rules["pickup"] = 1.0
	_place(game, ids, {thrower: Vector3(body.x, floor_y, body.z)})
	_check(game.knives.count() == 0 and game.player_for(thrower).arsenal.carries(&"knife"), "walking over the body takes the knife out of it")
	_check(events.any(func(e: Array) -> bool: return int(e[1]) == DotWeaponKnives.Phase.GONE), "and the layer said it went")

	# A team-mate: friendly fire is off, so the knife bounces off and they live.
	var mate_at := here + Vector3(0.0, 0.0, -6.0)
	_place(game, ids, {thrower: here, mate: mate_at})
	var _held2 := _knife_in_hand(game, thrower)
	_press_aim(game, thrower, 0.0, pitch)
	var off: DotWeaponKnives.Knife = await _settle(game, 6.0, {mate: mate_at})
	_check(game.combat.health_of(mate).alive, "a thrown knife does not kill a team-mate")
	_check(off != null and off.phase != DotWeaponKnives.Phase.STUCK, "it bounces off instead of sticking", str(off.phase if off != null else -1))

	# The speed rule: a slow throw is still flying where a fast one would have landed.
	if off != null:
		_place(game, ids, {thrower: Vector3(off.at.x, floor_y, off.at.z)})
	game.knife_rules["speed"] = 10.0
	_place(game, ids, {thrower: here})
	var _held3 := _knife_in_hand(game, thrower)
	_press_aim(game, thrower, 0.0, 0.0)
	var slow: DotWeaponKnives.Knife = game.knives.entries()[0] if game.knives.count() == 1 else null
	_check(slow != null and absf(slow.velocity.length() - 10.0) < 1.0, "arena_knife_throw_speed sets the throw speed", str(slow.velocity.length() if slow != null else -1.0))
	game.knife_rules["speed"] = 40.0
	_finished += 1

	print("%d sections entered, %d finished" % [_entered, _finished])
	var ok := _failed == 0 and _entered == EXPECTED_SECTIONS and _finished == EXPECTED_SECTIONS and _checks == EXPECTED_CHECKS
	print("%d checks, %d failed (expected %d)" % [_checks, _failed, EXPECTED_CHECKS])
	get_tree().quit(0 if ok else 1)


func _test_wire() -> void:
	_entered += 1
	var bytes := ArenaKnifeEvents.write_knife(7, 12, DotWeaponKnives.Phase.STUCK, 13, Vector3(12.5, 1.25, -30.0), Vector3(0.0, -0.6, 0.8))
	var reader := DotNetReader.new(bytes)
	_check(ArenaKnifeEvents.read_more(reader) == ArenaKnifeEvents.More.KNIFE, "MORE leads with the KNIFE sub-kind")
	var back := ArenaKnifeEvents.read_knife(reader)
	_check(bool(back["ok"]) and int(back["id"]) == 7 and int(back["owner"]) == 12 and int(back["victim"]) == 13, "KNIFE round-trips its id, owner and victim")
	_check(int(back["phase"]) == DotWeaponKnives.Phase.STUCK and (back["at"] as Vector3).distance_to(Vector3(12.5, 1.25, -30.0)) < 0.05, "and its phase and position")
	_check((back["motion"] as Vector3).distance_to(Vector3(0.0, -0.6, 0.8)) < 0.05, "and its motion")
	_check(ArenaEvents.Kind.MORE == ArenaEvents.Kind.TEAM + 1 and ArenaEvent.fits(), "MORE is appended after TEAM and the kinds still fit")
	_finished += 1
