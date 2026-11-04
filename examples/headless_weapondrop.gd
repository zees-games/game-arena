extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
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
const EXPECTED_CHECKS := 31

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

	await _run_end(game, drops, player, rules)
## The second half of the weapon drop checks.


func _run_end(game: ArenaGame, drops: DotWeaponDrops, player: ArenaPlayer, rules: DotWeaponDropRules) -> void:
	var victim := game.player_for(22)
	victim.controller.state.position = Vector3(30.0, victim.controller.state.position.y, 30.0)
	await _run_middle(game, drops, player, rules)


func _run_middle(game: ArenaGame, drops: DotWeaponDrops, player: ArenaPlayer, rules: DotWeaponDropRules) -> void:
	var before := drops.count()
	var fatal := DotDamage.make(21, 22, 5000.0, game.combat.damage_type(&""))
	game.combat.health_of(22).spawn_protection_ticks = 0
	game.combat.apply_damage(fatal)
	game.tick({})
	_check(drops.count() == before + 1, "a kill leaves the dead player's weapon lying", "%d -> %d" % [before, drops.count()])
	_check(game.drops_weapon_on_death(), "and the client skips its look-alike prop")

	rules.max_count = 1
	rules.pickup_radius = 0.0
	player.hold(AwWeaponIds.SLOT_SIDEARM)
	await _step(game, 21, true, 1)
	await _step(game, 21, false, 2)
	_check(drops.count() == 1, "sv_weapon_drop_max 1 keeps one, the oldest cleaned first", str(drops.count()))

	# Shots, splash, tap and hold on the lone drop left by the cap test.
	rules.max_count = 0
	rules.hold_time = 0.1
	var snap := drops.snapshot()[0] as Dictionary
	var lie_id: int = snap["id"]
	var lie_body: Node3D = drops.get("_entries")[lie_id]["body"]
	for _k in TICK_RATE * 3:
		await _step(game, 21, false, 1)
	var rest_at := lie_body.global_position
	var tr: DotTrace = game.combat.trace
	var awake_before: int = drops.active_count()
	var _miss := tr.ray(rest_at + Vector3(3.0, 1.0, 0.0), Vector3.DOWN, 5.0)
	_check(drops.active_count() == awake_before, "a trace that misses wakes nothing", str(drops.active_count()))
	var _hit := tr.ray(rest_at + Vector3(0.0, 1.0, 0.0), Vector3.DOWN, 5.0)
	_check(drops.active_count() > 0, "a traced shot (bullets, projectiles, melee) wakes a dropped weapon")
	_check(lie_body.linear_velocity.length() > 0.0 or lie_body.global_position != rest_at, "and moves it", str(lie_body.linear_velocity))
	for _k in TICK_RATE * 4:
		await _step(game, 21, false, 1)
	_check(drops.active_count() == 0, "the shot drop comes to rest again", str(drops.active_count()))
	var _spl := tr.sphere_overlap(lie_body.global_position, 3.0, game.combat.hitbox_sets(), true)
	await _run_second(game, drops, player, rules, snap)


func _run_second(game: ArenaGame, drops: DotWeaponDrops, player: ArenaPlayer, rules: DotWeaponDropRules, snap: Dictionary) -> void:
	_check(drops.active_count() > 0, "an explosion's sphere wakes it too")

	var held_def: StringName = StringName(str((snap["state"] as Dictionary).get("id", "")))
	var other := &""
	for cid in player.arsenal.catalogue.ids_in_slot(AwWeaponIds.SLOT_SIDEARM):
		if cid != held_def:
			other = cid
			break
	for _k in TICK_RATE * 3:
		await _step(game, 21, false, 1)
	player.arsenal.give(other)
	player.hold(AwWeaponIds.SLOT_SIDEARM)
	drops.clear()
	var aim_at: Vector3 = player.muzzle_position() + player.aim_direction() * 1.0
	drops.rules.pickup_delay = 0.0
	var d2 := drops.spawn(snap["state"], aim_at, Vector3.ZERO, 22)
	var pr := drops.prompt_for(player.arsenal, player.muzzle_position(), player.aim_direction(), game.weapon_drop_class_of(21), game.team_of(21) if not game.teams().is_empty() else 0)
	_check(pr.get("mode", "") == "swap", "a different weapon in the slot is offered as a swap", str(pr))
	await _step(game, 21, true, 2, DotWeaponCommand.BUTTON_USE)
	await _step(game, 21, false, 2, DotWeaponCommand.BUTTON_USE)
	var swapped = player.arsenal.current()
	_check(not drops.has_drop(d2) and player.arsenal.carries(held_def) and not player.arsenal.carries(other), "a tap on a different weapon in the slot replaces it", str(swapped.id() if swapped != null else ""))
	_check(drops.count() == 1, "while the old one lies on the floor", str(drops.count()))

	# The world panel: shown for a drop the player looks at, hidden out of reach.
	drops.clear()
	drops.rules.pickup_delay = 0.0
	var eye: Vector3 = player.muzzle_position()
	var _d3 := drops.spawn(snap["state"], eye + player.aim_direction() * 1.2, Vector3.ZERO, 22)
	var view := DotWeaponPickupView.new()
	add_child(view)
	var seen := drops.prompt_for(player.arsenal, eye, player.aim_direction(), game.weapon_drop_class_of(21))
	view.show_prompt(seen, 0.0)
	_check(not seen.is_empty() and view.visible, "a looked-at drop shows the panel", str(seen))
	_check(view.text_for(seen).contains("[E]"), "with the key named in the text", view.text_for(seen))
	var away := drops.prompt_for(player.arsenal, eye + Vector3(60.0, 0.0, 0.0), player.aim_direction(), game.weapon_drop_class_of(21))
	view.show_prompt(away, 0.0)
	_check(away.is_empty() and not view.visible, "and out of reach it hides")
	view.queue_free()

	# A splash is stopped by a wall: find a blocked and an open spot round one centre in the real level.
	drops.clear()
	_check(drops.can_see.is_valid(), "the arena gives the drop layer its sight check")
	var trace: DotTrace = game.combat.trace
	var centre := Vector3.ZERO
	var wall_spot := Vector3.INF
	var open_spot := Vector3.INF
	for cx in range(-20, 21, 4):
		for cz in range(-20, 21, 4):
			var c := Vector3(cx, 1.5, cz)
			var w := Vector3.INF
			var o := Vector3.INF
			for k in 24:
				var dir := Vector3.RIGHT.rotated(Vector3.UP, TAU * k / 24.0)
				var spot: Vector3 = c + dir * 4.0
				if trace.line_of_sight(c, spot):
					o = spot if o == Vector3.INF else o
				else:
					w = spot if w == Vector3.INF else w
			if w != Vector3.INF and o != Vector3.INF and wall_spot == Vector3.INF:
				centre = c
				wall_spot = w
				open_spot = o
	_check(wall_spot != Vector3.INF and open_spot != Vector3.INF, "the level has a wall and an open line near the centre", "%s %s" % [wall_spot, open_spot])
	drops.rules.blast_scale = 1.0
	var behind := drops.spawn(snap["state"], wall_spot, Vector3.ZERO, 22)
	var open_id := drops.spawn(snap["state"], open_spot, Vector3.ZERO, 22)
	await get_tree().physics_frame
	var hidden_body: RigidBody3D = drops._entries[behind]["body"]
	var open_body: RigidBody3D = drops._entries[open_id]["body"]
	hidden_body.linear_velocity = Vector3.ZERO
	open_body.linear_velocity = Vector3.ZERO
	var _pushed_n := drops.blast(centre, 6.0, 10.0)
	_check(hidden_body.linear_velocity.length() < 0.001 and open_body.linear_velocity.length() > 0.5, "a blast pushes the drop in the open and leaves the one behind a wall", "%s %s" % [hidden_body.linear_velocity, open_body.linear_velocity])

	var ok := _failed == 0 and _checks == EXPECTED_CHECKS
	print("%d checks, %d failed (expected %d)" % [_checks, _failed, EXPECTED_CHECKS])
	get_tree().quit(0 if ok else 1)
