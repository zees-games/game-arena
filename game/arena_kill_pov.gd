extends RefCounted

## What a kill view records of the killer's screen beyond the camera: held weapon, ADS, shots, ammo, spread, hits.

const CHANNEL := "arena.killpov"
const HITS_META := &"kill_pov_hits"

static var _ids: Dictionary = {}


## The eight aux floats for [param p] (layout in [DotKillViewRing]): weapon, ads, fire count, reload, mag, reserve, spread, hits.
static func aux_of(p: Object) -> PackedFloat32Array:
	var out := PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	if p == null:
		return out
	var arsenal: Variant = p.get(&"arsenal")
	var weapons: Variant = p.get(&"weapons")
	var id := StringName(p.get(&"mirror_weapon")) if bool(p.get(&"mirrored")) else &""
	if arsenal != null and arsenal.current() != null:
		var slot: Variant = arsenal.current()
		id = slot.def.id
		out[4] = float(slot.magazine) if slot.def.magazine > 0 else 0.0
		out[5] = float(arsenal.ammo().count(slot.def.ammo_type)) if slot.def.ammo_type != &"" else 0.0
		out[6] = float(p.call(&"spread_degrees"))
	out[0] = float(int(String(id).hash() & 0xFFFFFF)) if id != &"" else 0.0
	out[1] = 1.0 if bool(p.get(&"aim_held")) else 0.0
	if weapons != null:
		out[2] = float(int(weapons.fire_seq) % 4096)
	out[7] = float(int(p.get_meta(HITS_META, 0)) % 4096)
	return out


## Counts a confirmed hit against its attacker, so the replay can flash the crosshair when it lands.
static func count_hit(attacker: int, _victim: int, _amount: float, _point: Vector3, _headshot: bool, _lethal: bool, game: Node) -> void:
	var who: Object = game.call(&"player_for", attacker)
	if who != null:
		who.set_meta(HITS_META, int(who.get_meta(HITS_META, 0)) + 1)


## Counts hits on [param game] once, however many kill views ask.
static func watch_hits(game: Node) -> void:
	if not game.has_meta(HITS_META):
		game.set_meta(HITS_META, true)
		game.connect(&"hit_confirmed", func(a: int, v: int, n: float, at: Vector3, h: bool, l: bool) -> void: count_hit(a, v, n, at, h, l, game))


## The weapon id an aux hash names, or empty.
static func weapon_of(hash_value: float) -> StringName:
	if _ids.is_empty():
		for k: Variant in ZeeWeaponArtTable.table().keys():
			_ids[int(String(k).hash() & 0xFFFFFF)] = StringName(k)
	return _ids.get(int(hash_value), &"")
