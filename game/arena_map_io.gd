extends Node
## A converted map's doors, lifts and buttons in the arena: dot-map's mover world built on every machine, the host's use key, and the client's mirror.
## A map with no movers gets none of this (`build` returns null), so it pays nothing per frame.

const CHANNEL := "arena.map_io"
const ArenaBspMap := preload("../maps/arena_bsp_map.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaPaths := preload("arena_paths.gd")
const ArenaContent := preload("arena_content.gd")

## The host's clock source and the client's mirror of it.
var world: DotMapWorld = null
var use: DotMapUse = null
var transport: DotMapStateTransport = DotMapStateTransport.new()
var is_authority := true
var game = null


## The world for the game's current map, or null when the map is built in, has no converted world, or has no movers.
## [param use_rules] is the game's one DotMapUse (its cvars outlive the map).
static func build(game, use_rules: DotMapUse):
	var plan := _plan(game)
	if plan.is_empty():
		return null
	return _finish(plan, game, use_rules, DotMapWorld.build(plan.mesh, plan.hooks, plan.options))


## [method build] in slices behind the loading cover: awaits [param slice] so no frame carries the whole world.
static func build_async(game, use_rules: DotMapUse, slice: DotFrameSlice):
	var plan := _plan(game)
	if plan.is_empty():
		return null
	var made: DotResult = await DotMapWorld.build_async(plan.mesh, plan.hooks, plan.options, slice)
	return _finish(plan, game, use_rules, made)


static func _plan(game) -> Dictionary:
	var map = game.map
	if map == null or not map.is_imported() or not ArenaMap.use_worlds:
		return {}
	var prefix := ArenaBspMap.world_prefix(String(map.id), map.manifest_path.get_base_dir())
	if prefix.is_empty():
		return {}
	var got: DotResult = DotMapBspMesh.load_prefix(prefix)
	if not got.ok:
		return {}
	var mesh: DotMapBspMesh = got.value
	if (mesh.manifest.get("movers", []) as Array).is_empty():
		return {}
	var node = load(ArenaPaths.rebase("res://game/arena_map_io.gd")).new()
	node.name = "MapIo"
	node.is_authority = game.is_authority
	var hooks := {}
	if game.is_authority:
		hooks["send_fn"] = node.transport.send
	var surfaces := ArenaPaths.rebase("res://assets/surfaces")
	return {"node": node, "mesh": mesh, "hooks": hooks, "options": {
		"movers_only": true, "environment": false, "props": false, "sounds": false,
		"draw": not DotPlatform.is_headless(), "authoritative": game.is_authority,
		"rate": game.tick_rate, "map_id": String(map.id),
		"surfaces_root": surfaces if DirAccess.dir_exists_absolute(surfaces) else DotMapSurfaces.DEFAULT_ROOT,
	}}


static func _finish(plan: Dictionary, game, use_rules: DotMapUse, made: DotResult):
	var node = plan.node
	if not made.ok:
		DotLog.warn(CHANNEL, "a map's movers would not build", {"map": String(game.map.id), "why": made.error.message})
		node.free()
		return null
	node.game = game
	node.world = made.value
	node.world.io.carry_fn = node._carry
	node.world.io.damage_fn = node._damage
	node.add_child(node.world)
	node.transport.flush_on(node.world.io)
	use_rules.attach(node.world)
	node.use = use_rules
	DotLog.debug(CHANNEL, "movers built", {"map": String(game.map.id), "authority": game.is_authority})
	return node


## The host runs the logic one tick with the living players as the bodies movers carry, push and crush.
func tick() -> void:
	if is_authority and world != null:
		world.step(bodies())


## Dot-map body dictionaries for the living players; `body` is the player id.
func bodies() -> Array:
	var out: Array = []
	if game == null:
		return out
	for id in game.player_ids():
		var p = game.player_for(id)
		if p == null or not p.is_alive() or p.controller == null:
			continue
		out.append({"id": id, "body": id, "position": p.controller.state.position,
				"height": p.controller.tunables.stand_height, "radius": p.controller.tunables.radius})
	return out


func _carry(body, velocity: Vector3, _mover) -> void:
	var p = game.player_for(int(body)) if game != null else null
	if p != null and p.controller != null:
		p.controller.state.position += velocity / float(game.tick_rate)


func _damage(body, amount: float, _kind: String, _attacker) -> void:
	var p = game.player_for(int(body)) if game != null else null
	if p == null or game.combat == null or not p.is_alive():
		return
	var damage := DotDamage.make(0, int(body), amount, game.combat.damage_type(ArenaContent.DAMAGE_WORLD))
	damage.tick = game._tick
	game.combat.apply_damage(damage)


## A client's mirror ticks with the physics clock between the host's messages.
func _physics_process(_delta: float) -> void:
	if not is_authority and world != null:
		world.io.advance(1)


func add_peer(peer: int) -> void:
	if is_authority and world != null:
		world.add_peer(peer)


func remove_peer(peer: int) -> void:
	if world != null:
		world.remove_peer(peer)


## Client side: one state payload from the host (a snapshot, a change list or a batch of them).
func receive(payload: Dictionary) -> void:
	if is_authority or world == null:
		return
	var list: Array = payload.get("messages", [payload]) if str(payload.get("type", "")) == DotMapStateTransport.TYPE_BATCH else [payload]
	for m in list:
		if m is Dictionary:
			var tick := int(m.get("tick", 0))
			if tick > world.io.now:
				world.io.now = tick
			var _r := world.apply_state(m)


## Presses the usable thing a player looks at in reach; true when there was one (so the key is spent), even if it was cooling down. Host only.
func press_for(player, id: int) -> bool:
	if not is_authority or use == null:
		return false
	var info := aim_of(player)
	if info.is_empty() or not bool(info["in_range"]):
		return false
	var _pressed := use.press_entity(int(info["index"]), id, id, info["at"])
	return true


## The prompt info for an eye at [param from] looking along [param dir], or empty.
func aim_from(from: Vector3, dir: Vector3) -> Dictionary:
	if use == null or world == null or not is_inside_tree():
		return {}
	return use.aim(world.get_world_3d().direct_space_state, from, dir)


func aim_of(player) -> Dictionary:
	return aim_from(player.muzzle_position(), player.aim_direction())


func describe() -> Dictionary:
	return {"authority": is_authority, "tick": world.io.now if world != null else -1, "payloads": transport.payloads}
