extends RefCounted
## Utility grenades (flash, smoke, incendiary) on the server: arena_weapons' [AwGrenadeBlast] decides what a
## blast does, this turns it into blinds, clouds and fire zones. Flight, bounce and frag damage stay in
## [ArenaProjectiles], which already does them with the thrower grace and hitbox sweeps.

const ArenaPlayer := preload("arena_player.gd")

const CHANNEL := "arena.grenades"

## arena_weapons API level that has AwGrenadeBlast and the grenade defs (requires.floor.json).
const MIN_LEVEL := 3

## What an [signal effect] shows. Wire values, so only ever appended to.
enum Fx { SMOKE, FIRE, BLIND }

## Seconds between a fire zone's damage pulses.
const FIRE_PULSE := 0.5
## How far above or below a fire's origin a body still stands in it.
const FIRE_HEIGHT := 2.0
const FIRE_TYPE := &"fire"
const UTILITY_KINDS: Array[StringName] = [&"flash", &"smoke", &"incendiary"]

## `{fx, position, radius, seconds, victim}`: for the bridge to send and an offline client to show.
signal effect(info: Dictionary)

var game: Node = null
var rules: AwGrenadeRules = null

var _fires: Array[Dictionary] = []
var _smokes: Array[Dictionary] = []


## Whether this build of arena_weapons can do it; the glue stays off below that.
static func supported() -> bool:
	return DotAddonApi.build_level("arena_weapons") >= MIN_LEVEL


## The loadout ids of the utility weapons in [param defs], whatever the pack calls them.
static func utility_ids(defs: Array) -> Array[StringName]:
	var out: Array[StringName] = []
	for def: DotWeaponDef in defs:
		if UTILITY_KINDS.has(StringName(def.params.get(&"kind", &""))):
			out.append(def.id)
	return out


## Starts following [param p_game]'s projectile layer. Server only; the game builds one per map.
func attach(p_game: Node) -> void:
	game = p_game
	if rules == null:
		rules = AwGrenadeRules.new()
	game.projectiles.detonated.connect(_on_detonated)


func active_fires() -> int:
	return _fires.size()


func describe() -> Dictionary:
	return {"fires": _fires.size(), "smokes": _smokes.size()}


func _on_detonated(at: Vector3, spawn: DotWeaponSpawn) -> void:
	var def: DotWeaponDef = ArenaPlayer.weapon_catalogue().get_def(spawn.id)
	if def == null or not UTILITY_KINDS.has(StringName(def.params.get(&"kind", &""))):
		return

	var g := AwGrenade.from_spawn(spawn, def, rules)
	g.position = at
	# Only what the blast adds: the incendiary's splash was resolved by the projectile layer already.
	for ev in AwGrenadeBlast.detonate(g, def, _victims(), _line_clear):
		match String(ev["event"]):
			"blind":
				_emit(Fx.BLIND, at, 0.0, float(ev["seconds"]), int(ev["victim"]))
			"smoke":
				_smokes.append({"until": float(ev["seconds"])})
				_emit(Fx.SMOKE, at, float(ev["radius"]), float(ev["seconds"]), 0)
			"fire":
				_fires.append({
					"position": at, "radius": float(ev["radius"]), "left": float(ev["seconds"]),
					"dps": float(ev["dps"]), "owner": int(ev["owner"]), "pulse": 0.0,
				})
				_emit(Fx.FIRE, at, float(ev["radius"]), float(ev["seconds"]), 0)
	DotLog.debug(CHANNEL, "utility grenade went off", {"kind": String(g.kind), "at": at})


## Once per game tick, server side.
func tick(delta: float) -> void:
	for i in range(_smokes.size() - 1, -1, -1):
		_smokes[i]["until"] = float(_smokes[i]["until"]) - delta
		if float(_smokes[i]["until"]) <= 0.0:
			_smokes.remove_at(i)

	for i in range(_fires.size() - 1, -1, -1):
		var zone := _fires[i]
		zone["left"] = float(zone["left"]) - delta
		zone["pulse"] = float(zone["pulse"]) - delta
		if float(zone["pulse"]) <= 0.0:
			zone["pulse"] = FIRE_PULSE
			_burn(zone)
		if float(zone["left"]) <= 0.0:
			_fires.remove_at(i)


## Damage goes through combat.apply_damage so friendly fire, self damage and armour are the
## rules every other hit follows, with the thrower as the attacker.
func _burn(zone: Dictionary) -> void:
	var at: Vector3 = zone["position"]
	for v in _victims():
		var feet: Vector3 = v["position"]
		if Vector2(feet.x - at.x, feet.z - at.z).length() >= float(zone["radius"]) or absf(feet.y - at.y) > FIRE_HEIGHT:
			continue
		var damage := DotDamage.make(
			int(zone["owner"]), int(v["id"]), float(zone["dps"]) * FIRE_PULSE, game.combat.damage_type(FIRE_TYPE)
		)
		damage.tick = game._tick
		var _dealt: DotDamage = game.combat.apply_damage(damage)


func _victims() -> Array:
	var out: Array = []
	for id in game.player_ids():
		var p: ArenaPlayer = game.player_for(id)
		if p != null and p.is_alive():
			out.append({
				"id": id, "position": p.controller.state.position,
				"eye": p.muzzle_position(), "forward": p.aim_direction(),
			})
	return out


## World geometry only: a flash is stopped by a wall, not by someone standing in the way.
func _line_clear(from: Vector3, to: Vector3) -> bool:
	var offset := to - from
	var dist := offset.length()
	if dist <= 0.0:
		return true
	var hit: DotHitbox.Hit = game.combat.trace.ray(from, offset / dist, dist)
	return not hit.ok()


func _emit(fx: int, at: Vector3, radius: float, seconds: float, victim: int) -> void:
	effect.emit({"fx": fx, "position": at, "radius": radius, "seconds": seconds, "victim": victim})
