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
	layer.keep_slots = [ZeeWeaponIds.SLOT_MELEE]
	layer.team_of = func(pid: int) -> int: return game.team_of(pid) if not game.teams().is_empty() else 0
	layer.look_of = look
	game.weapon_drops = layer
	game.add_child(layer)


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
	elif use_now and not used and game.weapon_drops.count() > 0:
		var _used: int = game.weapon_drops.use(player.arsenal, player.muzzle_position(), player.aim_direction(), id, def)
	elif game.weapon_drops.rules.resolve(def).auto_pickup and game.weapon_drops.count() > 0:
		var _taken: int = game.weapon_drops.take_for(player.arsenal, player.controller.state.position + Vector3.UP * 0.5, id, def)


static func class_def_of(game, id: int) -> DotPlayerClassDef:
	if game.player_stack == null or game.player_stack.classes == null:
		return null
	return game.player_stack.classes.def_of(str(id))


static func look(weapon_id: StringName) -> Node3D:
	var art: Variant = ZeeWeaponArtTable.table().get(weapon_id)
	if not (art is ZeeWeaponArt):
		return null
	var model := ZeeWorldModel.new()
	var _drawn := model.equip(art as ZeeWeaponArt)
	return model


## Called by the player as it dies, before its arsenal is disabled (a dead arsenal gives up nothing).
static func drop_for_death(game, player) -> void:
	if game.weapon_drops == null or not game.is_authority:
		return
	var state: Variant = player.controller.state
	var _gun: Variant = game.weapon_drops.drop_dead(player.arsenal, state.position + Vector3.UP, state.velocity * 0.5 + Vector3.UP * 2.0, player.player_id, class_def_of(game, player.player_id))
