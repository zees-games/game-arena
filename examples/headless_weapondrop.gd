extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaContent := preload("../game/arena_content.gd")
const ArenaMode := preload("../game/arena_mode.gd")

## Dropped weapons through the whole game: the drop key throws the gun in hand, the thrower's empty
## slot takes it back once the delay is up, a rule turns the key off, a kill leaves the dead player's
## weapon lying, and the cap removes the oldest first.
##
## [codeblock]
## godot --headless --path . res://examples/headless_weapondrop.tscn
## [/codeblock]

const TICK_RATE := 64
const EXPECTED_CHECKS := 17

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


func _press(down: bool, button: int = DotWeaponCommand.BUTTON_DROP) -> DotWeaponCommand:
	var c := DotWeaponCommand.new()
	c.set_button(button, down)
	return c


func _step(game: ArenaGame, id: int, down: bool, ticks: int, button: int = DotWeaponCommand.BUTTON_DROP) -> void:
	for _k in ticks:
		game.tick({id: [DotFpsCommand.new(), _press(down, button)]})
		await get_tree().physics_frame


func _meshes(node: Node) -> int:
	var n := 1 if node is MeshInstance3D and (node as MeshInstance3D).is_visible_in_tree() else 0
	for c in node.get_children():
		n += _meshes(c)
	return n


func _run() -> void:
	var game := ArenaGame.new()
	game.name = "G"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.team_deathmatch()
	add_child(game)
	var ready := game.setup(ArenaMap.dm_atrium())
	_check(ready.ok, "a game sets up", str(ready.error))
	game.start(0)
	var _a := game.add_player(21, "A")
	var _b := game.add_player(22, "B")
	game.tick({})
	var drops := game.weapon_drops
	_check(drops != null and drops.is_authority, "the server game builds the weapon layer")
	var player := game.player_for(21)
	player.controller.state.position = Vector3(0.0, player.controller.state.position.y, 0.0)
	game.player_for(22).controller.state.position = Vector3(40.0, player.controller.state.position.y, 40.0)

	player.give_default_loadout()
	game.player_for(22).give_default_loadout()
	game.tick({})
	var rules := game.weapon_drop_rules
	rules.key_enabled = false
	await _step(game, 21, true, 3)
	await _step(game, 21, false, 2)
	_check(drops.count() == 0, "sv_weapon_drop_key 0: the key throws nothing")
	rules.key_enabled = true

	var held_id: StringName = player.arsenal.current().id()
	rules.auto_pickup = true
	await _step(game, 21, true, 1)
	await _step(game, 21, true, 3)
	_check(drops.count() == 1, "the key throws the weapon in hand, once per press", str(drops.count()))
	var now = player.arsenal.current()
	_check(now == null or now.id() != held_id, "and it is out of the player's hands")
	await _step(game, 21, false, 1)

	for _k in TICK_RATE * 3:
		if drops.count() > 0:
			player.controller.state.position = (drops.snapshot()[0]["at"] as Transform3D).origin
		await _step(game, 21, false, 1)
	var back = player.arsenal.current()
	_check(drops.count() == 0, "an empty slot in reach picks it back up", str(drops.count()))
	_check(back != null, "and the player holds a weapon again")

	rules.auto_pickup = false
	drops.draws = true
	player.hold(ArenaContent.DEFAULT_SLOT)
	var gun = player.arsenal.current()
	gun.magazine = 7
	var gun_slot: int = gun.def.slot
	await _step(game, 21, true, 1)
	await _step(game, 21, false, 1)
	_check(drops.count() == 1, "the key throws the gun for the use test", str(drops.count()))
	var lying: Node3D = drops.get("_entries").values()[0]["body"]
	for _k in TICK_RATE * 2:
		await _step(game, 21, false, 1)
	_check(_meshes(lying) > 0, "a dropped weapon has a visible mesh after it lands", str(_meshes(lying)))
	_check(absf(-lying.global_basis.z.y) < 0.8, "and it lies down rather than standing on end")
	player.controller.state.position = lying.global_position + Vector3(0.0, 0.0, 0.5)
	await _step(game, 21, false, TICK_RATE)
	_check(drops.count() == 1, "with auto pickup off, standing on it takes nothing", str(drops.count()))
	await _step(game, 21, true, 2, DotWeaponCommand.BUTTON_USE)
	await _step(game, 21, false, 2, DotWeaponCommand.BUTTON_USE)
	_check(drops.count() == 0, "the use key picks it up", str(drops.count()))
	var back_gun = player.arsenal.weapons_in(gun_slot)
	_check(not back_gun.is_empty() and back_gun[0].magazine == 7, "with the magazine it lay with", str(back_gun[0].magazine if not back_gun.is_empty() else -1))

	player.hold(ArenaContent.DEFAULT_SLOT)
	rules.pickup_radius = 0.0
	await _step(game, 21, true, 1)
	await _step(game, 21, false, 1)
	var thrown := drops.count()
	_check(thrown == 1, "a thrown weapon with pickup off stays on the floor", str(thrown))
	rules.pickup_radius = 1.4

	var victim := game.player_for(22)
	victim.controller.state.position = Vector3(30.0, victim.controller.state.position.y, 30.0)
	var before := drops.count()
	var fatal := DotDamage.make(21, 22, 5000.0, game.combat.damage_type(&""))
	game.combat.health_of(22).spawn_protection_ticks = 0
	game.combat.apply_damage(fatal)
	game.tick({})
	_check(drops.count() == before + 1, "a kill leaves the dead player's weapon lying", "%d -> %d" % [before, drops.count()])
	_check(game.drops_weapon_on_death(), "and the client skips its look-alike prop")

	rules.max_count = 1
	rules.pickup_radius = 0.0
	player.hold(ZeeWeaponIds.SLOT_SIDEARM)
	await _step(game, 21, true, 1)
	await _step(game, 21, false, 2)
	_check(drops.count() == 1, "sv_weapon_drop_max 1 keeps one, the oldest cleaned first", str(drops.count()))

	var ok := _failed == 0 and _checks == EXPECTED_CHECKS
	print("%d checks, %d failed (expected %d)" % [_checks, _failed, EXPECTED_CHECKS])
	get_tree().quit(0 if ok else 1)
