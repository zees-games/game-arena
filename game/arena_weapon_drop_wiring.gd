extends RefCounted
## How the arena feeds the shared dropped-weapon layer: building it, the drop key, and the drop on death.


## The weapon layer, on both sides: the server simulates it, a client draws what it is told.
static func build(game) -> void:
	var layer := DotWeaponDrops.new()
	layer.name = "WeaponDrops"
	layer.rules = game.weapon_drop_rules
	layer.is_authority = game.is_authority
	layer.draws = not game.headless
	layer.collision_mask = game.ragdoll_rules.collision_mask
	layer.keep_slots = [ZeeWeaponIds.SLOT_MELEE]
	layer.look_of = look
	game.weapon_drops = layer
	game.add_child(layer)


static func teardown(game) -> void:
	if game.weapon_drops != null:
		game.remove_child(game.weapon_drops)
		game.weapon_drops.queue_free()
		game.weapon_drops = null
	game.drop_held.clear()


## The drop key's rising edge throws the weapon in hand along the aim; every tick an empty slot
## takes a dropped weapon in reach, which is also how the swap works.
static func input(game, id: int, player, pair: Array) -> void:
	if game.weapon_drops == null or not game.is_authority or pair.size() < 2 or pair[1] == null:
		return
	var held: bool = (pair[1] as DotWeaponCommand).is_pressed(DotWeaponCommand.BUTTON_DROP)
	var was: bool = game.drop_held.get(id, false)
	game.drop_held[id] = held
	var def := class_def_of(game, id)
	var velocity: Vector3 = player.controller.state.velocity
	if held and not was:
		var _id: int = game.weapon_drops.throw(player.arsenal, player.muzzle_position(), player.aim_direction(), id, def, velocity)
	elif game.weapon_drops.count() > 0:
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
