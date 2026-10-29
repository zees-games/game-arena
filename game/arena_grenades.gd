extends RefCounted
## Utility grenades (flash, smoke, incendiary) on the server: arena_weapons' [AwUtilityZones] does the zones and
## blinds; this plugs arena's players, world trace and combat into it. Flight, bounce and frag damage stay in
## [ArenaProjectiles], which already does them with the thrower grace and hitbox sweeps.

const ArenaPlayer := preload("arena_player.gd")

const CHANNEL := "arena.grenades"

## arena_weapons API level that has AwUtilityZones (requires.floor.json).
const MIN_LEVEL := 4

## What an [signal effect] shows; the wire values live in the addon.
const Fx = AwUtilityZones.Fx

## `{fx, position, radius, seconds, victim}`: for the bridge to send and an offline client to show.
signal effect(info: Dictionary)

var game: Node = null
var rules: AwGrenadeRules = null
var zones: AwUtilityZones = null


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
	# Blast damage stays off: the incendiary's splash was resolved by the projectile layer already.
	var _events := zones.detonate(g, def)
	DotLog.debug(CHANNEL, "utility grenade went off", {"kind": String(g.kind), "at": at})


func _victims() -> Array:
	var out: Array = []
	for id in game.player_ids():
		var p: ArenaPlayer = game.player_for(id)
		if p != null and p.is_alive():
			out.append(AwUtilityZones.victim(id, p.controller.state.position, p.muzzle_position(), p.aim_direction()))
	return out


## World geometry only: a flash is stopped by a wall, not by someone standing in the way.
func _blocked(from: Vector3, direction: Vector3, dist: float) -> bool:
	return game.combat.trace.ray(from, direction, dist).ok()


## Goes through combat.apply_damage so friendly fire, self damage and armour are the rules every other hit follows.
func _damage(attacker: int, victim: int, amount: float, type: Variant, _weapon: StringName) -> void:
	var hit := DotDamage.make(attacker, victim, amount, game.combat.damage_type(type as StringName))
	hit.tick = game._tick
	var _dealt: DotDamage = game.combat.apply_damage(hit)
