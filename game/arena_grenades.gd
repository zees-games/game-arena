extends RefCounted
## Utility grenades (flash, smoke, incendiary) on the server: arena_weapons' [AwUtilityZones] does the zones and
## blinds; this plugs arena's players, world trace and combat into it. Flight, bounce and frag damage stay in
## [ArenaProjectiles], which already does them with the thrower grace and hitbox sweeps.

const ArenaPlayer := preload("arena_player.gd")
const ArenaBots := preload("arena_bots.gd")

const CHANNEL := "arena.grenades"

## arena_weapons API level that has AwUtilityZones (requires.floor.json).
const MIN_LEVEL := 4

## dot-bot API level that has DotBotBrain.blind_for and the world's sight blockers.
const BOT_LEVEL := 8

## dot-npc API level that has DotNpcInstance.blind_for and DotNpcSenses.add_sight_blocker.
const NPC_LEVEL := 6

## What an [signal effect] shows; the wire values live in the addon.
const Fx = AwUtilityZones.Fx

## `{fx, position, radius, seconds, victim}`: for the bridge to send and an offline client to show.
signal effect(info: Dictionary)

var game: Node = null
var rules: AwGrenadeRules = null
var zones: AwUtilityZones = null

## Where the grenade being resolved went off and how far it reaches: which monsters [method _victims] offers.
var _reach_at := Vector3.ZERO
var _reach := 0.0


## Whether this build of arena_weapons can do it; the glue stays off below that.
static func supported() -> bool:
	return DotAddonApi.build_level("arena_weapons") >= MIN_LEVEL


static func utility_ids(defs: Array) -> Array[StringName]:
	return AwUtilityZones.utility_ids(defs)


## Starts following [param p_game]'s projectile layer. Server only; the game builds one per map.
func attach(p_game: Node) -> void:
	game = p_game
	if rules == null:
		rules = AwGrenadeRules.new()
	zones = AwUtilityZones.new()
	zones.rules = rules
	zones.victims = _victims
	zones.los = AwUtilityZones.los_from_ray(_blocked)
	zones.damage = _damage
	zones.effect.connect(effect.emit)
	game.projectiles.detonated.connect(_on_detonated)


func active_fires() -> int:
	return zones.active_fires() if zones != null else 0


func describe() -> Dictionary:
	return zones.describe() if zones != null else {}


## Once per game tick, server side.
func tick(delta: float) -> void:
	if zones != null:
		zones.tick(delta)


func _on_detonated(at: Vector3, spawn: DotWeaponSpawn) -> void:
	var def: DotWeaponDef = ArenaPlayer.weapon_catalogue().get_def(spawn.id)
	if not AwUtilityZones.is_utility(def):
		return

	var g := AwGrenade.from_spawn(spawn, def, rules)
	g.position = at
	_reach_at = at
	_reach = float(def.params.get(&"effect_radius", 0.0))
	# Blast damage stays off: the incendiary's splash was resolved by the projectile layer already.
	_tell_bots(zones.detonate(g, def), at)
	DotLog.debug(CHANNEL, "utility grenade went off", {"kind": String(g.kind), "at": at})


## A flashed bot goes blind for the ledger's seconds; a smoke cloud blocks every bot's line of sight.
func _tell_bots(events: Array, at: Vector3) -> void:
	_tell_monsters(events, at)

	if DotAddonApi.build_level("dot_bot") < BOT_LEVEL:
		return

	var world := ArenaBots.world_for(game)
	var now := float(game.current_tick()) / float(game.tick_rate)

	for e: Dictionary in events:
		match String(e["event"]):
			"blind":
				var brain: DotBotBrain = world.brains.get(int(e["victim"]))
				if brain != null:
					brain.blind_for(now, zones.ledger.remaining(int(e["victim"])), at)
			"smoke":
				var _id := world.add_sight_blocker(at + Vector3(0.0, 1.6, 0.0), float(e["radius"]), now + float(e["seconds"]))


## Flashed monsters lose sight for the ledger's seconds; a smoke cloud blocks the horde's sight, hearing passes.
func _tell_monsters(events: Array, at: Vector3) -> void:
	var horde: Node = game.horde
	if DotAddonApi.build_level("dot_npc") < NPC_LEVEL or horde == null or horde.senses == null:
		return

	for e: Dictionary in events:
		match String(e["event"]):
			"blind":
				var npc: DotNpcInstance = _monster_for(int(e["victim"]))
				if npc != null:
					npc.blind_for(horde.spawner.now(), zones.ledger.remaining(int(e["victim"])))
			"smoke":
				var _id: int = horde.senses.add_sight_blocker(at + Vector3(0.0, 1.6, 0.0), float(e["radius"]), float(e["seconds"]))


func _monster_for(entity: int) -> DotNpcInstance:
	if not DotEntity.is_kind(entity, DotEntity.KIND_NPC):
		return null

	for npc in game.horde.spawner.npcs_near(_reach_at, _reach + 1.0):
		if game.horde.entity_id_for(npc) == entity:
			return npc

	return null


func _victims() -> Array:
	var out: Array = []
	for id in game.player_ids():
		var p: ArenaPlayer = game.player_for(id)
		if p != null and p.is_alive():
			out.append(AwUtilityZones.victim(id, p.controller.state.position, p.muzzle_position(), p.aim_direction()))

	if DotAddonApi.build_level("dot_npc") >= NPC_LEVEL and game.horde != null and game.horde.spawner != null and _reach > 0.0:
		for npc in game.horde.spawner.npcs_near(_reach_at, _reach):
			var entity: int = game.horde.entity_id_for(npc)
			if entity == 0 or not npc.is_alive():
				continue

			var feet: Vector3 = npc.position()
			var forward := -(npc.node as Node3D).global_transform.basis.z if npc.node is Node3D else Vector3.FORWARD
			out.append(AwUtilityZones.victim(entity, feet, feet + Vector3(0.0, npc.def.eye_height, 0.0), forward))

	return out


## World geometry only: a flash is stopped by a wall, not by someone standing in the way.
func _blocked(from: Vector3, direction: Vector3, dist: float) -> bool:
	return game.combat.trace.ray(from, direction, dist).ok()


## Goes through combat.apply_damage so friendly fire, self damage and armour are the rules every other hit follows.
func _damage(attacker: int, victim: int, amount: float, type: Variant, _weapon: StringName) -> void:
	var hit := DotDamage.make(attacker, victim, amount, game.combat.damage_type(type as StringName))
	hit.tick = game._tick
	var _dealt: DotDamage = game.combat.apply_damage(hit)
