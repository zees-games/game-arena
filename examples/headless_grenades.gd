extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaContent := preload("../game/arena_content.gd")
const ArenaEvents := preload("../game/arena_events.gd")
const ArenaGrenades := preload("../game/arena_grenades.gd")
const ArenaBots := preload("../game/arena_bots.gd")

## Utility grenades through the whole game: the loadout gate, the incendiary going off on contact, fire
## damage through arena's combat rules (enemy hurt, owner and team-mate not), the blind and cloud events, and
## the GRENADE_FX wire record.
##
## [codeblock]
## godot --headless --path . res://examples/headless_grenades.tscn
## [/codeblock]

const TICK_RATE := 64
const EXPECTED_CHECKS := 25

var _checks := 0
var _failed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	Engine.physics_ticks_per_second = TICK_RATE
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _run() -> void:
	_check(ArenaGrenades.supported(), "arena_weapons is at the level the glue needs", str(DotAddonApi.build_level("arena_weapons")))
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

	_test_loadout(game)

	var ids: Array = []
	for i in 6:
		var _added := game.add_player(10 + i, "P%d" % i)
		ids.append(10 + i)
	game.tick({})
	var thrower := int(ids[0])
	var mate := 0
	var enemy := 0
	for id in ids.slice(1):
		if game.team_of(id) == game.team_of(thrower) and mate == 0:
			mate = id
		elif game.team_of(id) != game.team_of(thrower) and enemy == 0:
			enemy = id
	_check(mate > 0 and enemy > 0, "a team-mate and an enemy", "%d %d" % [mate, enemy])
	_check(game.grenades != null, "the server game builds the grenade glue")

	var seen: Array = []
	game.grenade_effect.connect(func(info: Dictionary) -> void: seen.append(info))
	var floor_y := game.player_for(thrower).controller.state.position.y
	var here := Vector3(0.0, floor_y, 0.0)
	for id in ids:
		var far := Vector3(30.0 + float(id), floor_y, 30.0)
		game.player_for(id).controller.state.position = here if id in [thrower, mate, enemy] else far
	for _k in 3:
		for id in [thrower, mate, enemy]:
			game.player_for(id).controller.state.position = here
		game.tick({})

	var before := {}
	for id in [thrower, mate, enemy]:
		before[id] = game.combat.health_of(id).health

	var spawn := DotWeaponSpawn.new()
	spawn.id = &"incendiary"
	spawn.origin = here + Vector3(0.0, 1.5, 0.0)
	spawn.velocity = Vector3(0.0, -6.0, 0.0)
	spawn.gravity_scale = 1.0
	spawn.radius = 0.1
	spawn.fuse_ticks = TICK_RATE * 30
	spawn.life_ticks = TICK_RATE * 40
	spawn.damage_type = game.combat.damage_type(&"blast")
	spawn.owner_entity = thrower
	spawn.tick = game.current_tick()
	spawn.meta = {&"sticks": false}
	var went_off: Array = []
	game.projectiles.detonated.connect(func(at: Vector3, _s: DotWeaponSpawn) -> void: went_off.append(at))
	game.projectiles.launch(spawn)
	for _k in TICK_RATE:
		game.tick({})
		await get_tree().physics_frame
	_check(went_off.size() == 1, "the incendiary went off on first contact, long before its fuse", str(went_off.size()))
	var fires := seen.filter(func(i: Dictionary) -> bool: return int(i["fx"]) == ArenaGrenades.Fx.FIRE)
	_check(fires.size() == 1, "one fire zone was announced", str(fires.size()))
	_check(game.grenades.active_fires() == 1, "and is burning")

	for _k in TICK_RATE * 3:
		game.tick({})
		for id in [thrower, mate, enemy]:
			game.player_for(id).controller.state.position = here
		await get_tree().physics_frame
	_check(game.combat.health_of(enemy).health < float(before[enemy]), "the enemy standing in it burns", "%s -> %s" % [before[enemy], game.combat.health_of(enemy).health])
	_check(game.combat.health_of(mate).health >= float(before[mate]), "the team-mate does not (friendly_fire is off)")

	game.combat.rules.self_damage = false
	var owner_hp := game.combat.health_of(thrower).health
	for _k in TICK_RATE * 2:
		game.tick({})
		game.player_for(thrower).controller.state.position = here
		await get_tree().physics_frame
	_check(game.combat.health_of(thrower).health >= owner_hp, "the thrower does not burn with self_damage off")

	for _k in TICK_RATE * 8:
		game.tick({})
		await get_tree().physics_frame
	_check(game.grenades.active_fires() == 0, "the fire burns out")

	await _test_flash_and_smoke(game, thrower, enemy, here, seen)

	var ok := _failed == 0 and _checks == EXPECTED_CHECKS
	print("%d checks, %d failed (expected %d)" % [_checks, _failed, EXPECTED_CHECKS])
	get_tree().quit(0 if ok else 1)


func _test_loadout(game: ArenaGame) -> void:
	var cat := ArenaContent.catalogue()
	var flash := cat.find(&"flash")
	_check(flash != null and not flash.free, "the flash is not a free item")
	var off: DotLoadoutEntitlements = game.loadouts.entitlement_source.call("k")
	_check(not off.allows(flash), "sv_grenade_utility 0: the flash is refused")
	_check(off.allows(cat.find(&"frag")), "and the frag grenade stays free")
	game.utility_grenades = true
	var on: DotLoadoutEntitlements = game.loadouts.entitlement_source.call("k")
	_check(on.allows(flash) and on.allows(cat.find(&"smoke")) and on.allows(cat.find(&"incendiary")), "sv_grenade_utility 1: flash, smoke and incendiary are allowed")
	game.utility_grenades = false


func _test_flash_and_smoke(game: ArenaGame, thrower: int, enemy: int, here: Vector3, seen: Array) -> void:
	seen.clear()
	var victim := game.player_for(enemy)
	victim.spawn(Transform3D(Basis(), here), game.team_of(enemy))
	game.tick({})
	var eye := victim.muzzle_position()
	var bots := ArenaBots.world_for(game)
	var brain := DotBotBrain.new(enemy, DotBotSettings.new())
	bots.brains[enemy] = brain
	for kind in [&"flash", &"smoke"]:
		var s := DotWeaponSpawn.new()
		s.id = kind
		s.origin = eye + victim.aim_direction() * 2.0
		s.velocity = Vector3.ZERO
		s.gravity_scale = 0.0
		s.radius = 0.1
		s.fuse_ticks = 2
		s.life_ticks = TICK_RATE * 5
		s.damage_type = game.combat.damage_type(&"blast")
		s.owner_entity = thrower
		s.tick = game.current_tick()
		s.meta = {&"sticks": false}
		game.projectiles.launch(s)
	for _k in 8:
		game.tick({})
		await get_tree().physics_frame
	var blinds := seen.filter(func(i: Dictionary) -> bool: return int(i["fx"]) == ArenaGrenades.Fx.BLIND and int(i["victim"]) == enemy)
	var clouds := seen.filter(func(i: Dictionary) -> bool: return int(i["fx"]) == ArenaGrenades.Fx.SMOKE)
	_check(not blinds.is_empty() and float(blinds[0]["seconds"]) > 0.0, "a flash thrown at someone's face blinds them", str(blinds.size()))
	_check(clouds.size() == 1 and float(clouds[0]["radius"]) > 0.0, "a smoke grenade announces one cloud", str(clouds.size()))
	var now := float(game.current_tick()) / float(game.tick_rate)
	_check(brain.is_blind(now), "a flashed bot's brain is blind for the ledger's seconds")
	_check(bots.sight_blockers.size() == 1 and not bots.line_of_sight(Vector3(0.0, 4.0, -9.0), Vector3(0.0, 4.0, 5.0)) and bots.line_of_sight(Vector3(0.0, 40.0, -9.0), Vector3(0.0, 40.0, 5.0)), "the smoke cloud blocks the bots' line of sight")
	var self_hp_ok: bool = game.combat.health_of(enemy).health > 0.0
	_check(self_hp_ok, "neither deals damage on its own")


func _test_wire() -> void:
	var bytes := ArenaEvents.write_grenade_fx(ArenaGrenades.Fx.BLIND, Vector3(12.5, 1.0, -30.0), 0.0, 3.5, 7)
	var back := ArenaEvents.read_grenade_fx(DotNetReader.new(bytes))
	_check(bool(back["ok"]) and int(back["fx"]) == ArenaGrenades.Fx.BLIND and int(back["victim"]) == 7, "GRENADE_FX round-trips its kind and victim")
	_check(absf(float(back["seconds"]) - 3.5) < 0.1 and (back["position"] as Vector3).distance_to(Vector3(12.5, 1.0, -30.0)) < 0.5, "and its seconds and position")
	var smoke := ArenaEvents.read_grenade_fx(DotNetReader.new(ArenaEvents.write_grenade_fx(ArenaGrenades.Fx.SMOKE, Vector3.ZERO, 6.0, 14.0, 0)))
	_check(absf(float(smoke["radius"]) - 6.0) < 0.3 and absf(float(smoke["seconds"]) - 14.0) < 0.6, "a cloud keeps its radius and duration")
	var soft := ArenaEvents.read_grenade_fx(DotNetReader.new(ArenaEvents.write_grenade_fx(ArenaGrenades.Fx.BLIND, Vector3.ZERO, 0.0, 3.0, 7, 0.4)))
	_check(absf(float(soft["strength"]) - 0.4) < 0.04 and absf(float(back["strength"]) - 1.0) < 0.001, "GRENADE_FX carries the flash strength, full by default")
	_check(ArenaEvents.Kind.GRENADE_FX == ArenaEvents.Kind.STOMP + 1, "the kind is appended right after STOMP")
