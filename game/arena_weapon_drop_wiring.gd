extends RefCounted
## How the arena feeds the shared dropped-weapon layer: building it, the drop key, and the drop on death.


## The weapon layer, on both sides: the server simulates it, a client draws what it is told.
static func build(game) -> void:
	var layer := DotWeaponDrops.new()
	layer.name = "WeaponDrops"
	layer.rules = game.weapon_drop_rules
	layer.is_authority = game.is_authority
	# `game.headless` is the collision backend and is true on every client; a screen decides drawing.
	layer.draws = not DotPlatform.is_headless()
	layer.collision_mask = game.ragdoll_rules.collision_mask
	layer.keep_slots = [AwWeaponIds.SLOT_MELEE]
	layer.team_of = func(pid: int) -> int: return game.team_of(pid) if not game.teams().is_empty() else 0
	layer.look_of = look
	game.weapon_drops = layer
	game.add_child(layer)


## Weapons worth parking a drop body for: every one with art, the same set the first-person warm-up walks.
static func prewarm_ids() -> Array:
	return AwWeaponArtTable.table().keys()


## Parks one body per weapon of [param ids] from index [param from] until [param until_msec]; returns the next index. Under the loading cover, a slice a frame, so the first throw builds nothing.
static func prewarm_step(game, ids: Array, from: int, until_msec: int) -> int:
	var next := from
	while next < ids.size() and Time.get_ticks_msec() < until_msec and game.weapon_drops != null:
		game.weapon_drops.prewarm(ids[next], 1)
		next += 1
	return next


static func teardown(game) -> void:
	if game.weapon_drops != null:
		game.remove_child(game.weapon_drops)
		game.weapon_drops.queue_free()
		game.weapon_drops = null
	game.drop_held.clear()
	game.use_held.clear()


## The drop key's rising edge throws the weapon in hand along the aim; the use key's takes the
## dropped weapon looked at; with `sv_weapon_drop_auto` an empty slot also takes one in reach.
static func input(game, id: int, player, pair: Array) -> void:
	if not game.is_authority or pair.size() < 2 or pair[1] == null:
		return
	hook_shots(game)
	var held: bool = (pair[1] as DotWeaponCommand).is_pressed(DotWeaponCommand.BUTTON_DROP)
	var was: bool = game.drop_held.get(id, false)
	game.drop_held[id] = held
	var use_now: bool = (pair[1] as DotWeaponCommand).is_pressed(DotWeaponCommand.BUTTON_USE)
	var used: bool = game.use_held.get(id, false)
	game.use_held[id] = use_now
	# One key, one target: a map button or door looked at in reach wins; else the weapon on the floor.
	if use_now and not used and game.map_io != null and game.map_io.press_for(player, id):
		return
	if game.weapon_drops == null:
		return
	var def := class_def_of(game, id)
	var velocity: Vector3 = player.controller.state.velocity
	if held and not was:
		var _id: int = game.weapon_drops.throw(player.arsenal, player.muzzle_position(), player.aim_direction(), id, def, velocity)
	elif _use_hold(game, id, player, def, use_now):
		pass
	elif game.weapon_drops.rules.resolve(def).auto_pickup and game.weapon_drops.count() > 0:
		var _taken: int = game.weapon_drops.take_for(player.arsenal, player.controller.state.position + Vector3.UP * 0.5, id, def)


## Client, every frame: the panel over the dropped weapon looked at, and the circle while the use key is held.
static func update_panel(client, pressed: bool, delta: float) -> void:
	var game = client.game
	var player = client.player
	var view: DotWeaponPickupView = client.get_meta(&"pickup_view") if client.has_meta(&"pickup_view") else null
	var hold: DotWeaponUseHold = client.get_meta(&"pickup_hold") if client.has_meta(&"pickup_hold") else null
	if view == null:
		view = DotWeaponPickupView.new()
		view.name = "PickupView"
		view.visible = false
		game.add_child(view)
		hold = DotWeaponUseHold.new()
		client.set_meta(&"pickup_view", view)
		client.set_meta(&"pickup_hold", hold)
	var info := {}
	if game.weapon_drops != null and player != null and player.is_alive() and player.arsenal != null and game.weapon_drops.count() > 0:
		info = game.weapon_drops.prompt_for(player.arsenal, player.camera.global_position, -player.camera.global_basis.z, game.weapon_drop_class_of(player.player_id), game.team_of(player.player_id) if not game.teams().is_empty() else 0)
	hold.hold_time = game.weapon_drops.rules.hold_time if game.weapon_drops != null else 0.6
	var _event := hold.step(pressed, delta, not info.is_empty() and (info.get("mode", "") == "ammo" or bool(info.get("hold", false))))
	var fill := hold.progress
	if client.hud != null:
		view.key_text = String(client.hud.keys.get(&"use", "E"))
	view.name_of = func(id: StringName) -> String:
		var def: Variant = player.arsenal.catalogue.get_def(id)
		return def.name_or_id() if def != null else String(id)
	# One ring: the crosshair's. The panel's own world circle stays off (fill 0), or two rings fill at once.
	view.show_prompt(info, 0.0)
	if client.hud != null and client.hud.crosshair != null:
		client.hud.crosshair.hold_progress = fill


## Lets every traced shot and splash push a dropped weapon (a splash not through a wall); idempotent, as the trace is built later than the layer.
static func hook_shots(game) -> void:
	if game.weapon_drops == null or game.combat == null or not game.combat.trace is DotTrace:
		return
	var trace: DotTrace = game.combat.trace
	if trace.ray_observer.is_valid():
		return
	var drops: DotWeaponDrops = game.weapon_drops
	drops.can_see = trace.line_of_sight
	trace.ray_observer = func(from: Vector3, dir: Vector3, dist: float) -> void:
		if drops.count() == 0:
			return
		var found := drops.raycast(from, from + dir * dist)
		if not found.is_empty():
			var _pushed := drops.hit(int(found["id"]), found["point"], dir, 3.0)
	trace.sphere_observer = func(centre: Vector3, radius: float) -> void:
		if drops.count() > 0:
			var _n := drops.blast(centre, radius, 8.0)


## The use key on a dropped weapon: the shared rules in [DotWeaponUseKey].
static func _use_hold(game, id: int, player, def: DotPlayerClassDef, pressed: bool) -> bool:
	var keys: Dictionary = game.get_meta(&"use_keys", {})
	game.set_meta(&"use_keys", keys)
	var key: DotWeaponUseKey = keys.get(id)
	if key == null:
		key = DotWeaponUseKey.new()
		keys[id] = key
	return key.step(game.weapon_drops, player.arsenal, player.muzzle_position(), player.aim_direction(), id, pressed,
		game.get_physics_process_delta_time(), def, game.team_of(id) if not game.teams().is_empty() else 0)


static func class_def_of(game, id: int) -> DotPlayerClassDef:
	if game.player_stack == null or game.player_stack.classes == null:
		return null
	return game.player_stack.classes.def_of(str(id))


static func look(weapon_id: StringName) -> Node3D:
	var art: Variant = AwWeaponArtTable.table().get(weapon_id)
	if not (art is AwWeaponVisual):
		return null
	var model := AwWorldModel.new()
	# Its wall probe would slide the mesh out of the collision box beside any wall or step.
	model.wall_response = false
	var _drawn := model.equip(art as AwWeaponVisual)
	return model


## Called by the player as it dies, before its arsenal is disabled (a dead arsenal gives up nothing).
static func drop_for_death(game, player) -> void:
	if game.weapon_drops == null or not game.is_authority:
		return
	var state: Variant = player.controller.state
	var _gun: Variant = game.weapon_drops.drop_dead(player.arsenal, state.position + Vector3.UP, state.velocity * 0.5 + Vector3.UP * 2.0, player.player_id, class_def_of(game, player.player_id))
