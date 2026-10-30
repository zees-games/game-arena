extends RefCounted

## What a kill view records of the killer's screen beyond the camera: held weapon, ADS, shots, ammo, spread, hits.

const CHANNEL := "arena.killpov"
const HITS_META := &"kill_pov_hits"
const RECOIL_META := &"kill_pov_recoil"

## Aux slots, in the order [DotKillViewRing] records them; SIZE is the contract with the ring's AUX.
const WEAPON := 0
const ADS := 1
const FIRE_SEQ := 2
const FIRE_KIND := 3
const MAG := 4
const RESERVE := 5
const SPREAD := 6
const HITS := 7
const KICK_PITCH := 8
const KICK_YAW := 9
const FLAGS := 10
const SPEED := 11
const SIZE := 12

## Bits of FLAGS.
const GROUNDED := 1
const CROUCHED := 2
const SIGNED := 4

static var _ids: Dictionary = {}


## The twelve aux floats for [param p] (layout in [DotKillViewRing]): weapon, ads, fire count, reload, mag, reserve,
## spread, hits, the last shot's recoil pitch and yaw (0 when this end never saw the outcome), flags, ground speed.
## [param size] is the ring's AUX; a shorter ring (an older dot-replay) gets the slots it has, never an out-of-range write.
static func aux_of(p: Object, size: int = DotKillViewRing.AUX) -> PackedFloat32Array:
	var full := _aux_full(p)
	full.resize(size)
	return full


static func _aux_full(p: Object) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(SIZE)
	if p == null:
		return out
	var arsenal: Variant = p.get(&"arsenal")
	var weapons: Variant = p.get(&"weapons")
	var id := StringName(p.get(&"mirror_weapon")) if bool(p.get(&"mirrored")) else &""
	if arsenal != null and arsenal.current() != null:
		var slot: Variant = arsenal.current()
		id = slot.def.id
		out[MAG] = float(slot.magazine) if slot.def.magazine > 0 else 0.0
		out[RESERVE] = float(arsenal.ammo().count(slot.def.ammo_type)) if slot.def.ammo_type != &"" else 0.0
		out[SPREAD] = float(p.call(&"spread_degrees"))
	out[WEAPON] = float(int(String(id).hash() & 0xFFFFFF)) if id != &"" else 0.0
	out[ADS] = 1.0 if bool(p.get(&"aim_held")) else 0.0
	if bool(p.get(&"mirrored")):
		out[FIRE_SEQ] = float(int(p.get(&"mirror_fire_seq")) % 4096)
		out[FIRE_KIND] = float(int(p.get(&"mirror_fire_kind")))
	elif weapons != null:
		out[FIRE_SEQ] = float(int(weapons.fire_seq) % 4096)
		out[FIRE_KIND] = float(int(weapons.fire_kind))
		_watch_recoil(weapons as Object)
		var kick: Vector3 = (weapons as Object).get_meta(RECOIL_META, Vector3.ZERO)
		out[KICK_PITCH] = kick.x
		out[KICK_YAW] = kick.y
		out[FLAGS] = SIGNED if kick.z > 0.0 else 0
	out[HITS] = float(int(p.get_meta(HITS_META, 0)) % 4096)
	var controller: Variant = p.get(&"controller")
	if controller is DotFpsController and (controller as DotFpsController).state != null:
		var st := (controller as DotFpsController).state
		out[FLAGS] += (GROUNDED if st.is_grounded() else 0) + (CROUCHED if st.is_crouched() else 0)
		out[SPEED] = st.horizontal_speed()
	return out


## Keeps the rig's last shot's recoil (pitch, yaw, signed) where [method aux_of] reads it: the per-weapon
## recoil model's own output, wherever the outcome is decided (the server, the local player).
static func _watch_recoil(rig: Object) -> void:
	if rig.has_meta(RECOIL_META) or not rig.has_signal(&"used"):
		return
	rig.set_meta(RECOIL_META, Vector3.ZERO)
	rig.connect(&"used", func(outcome: Object) -> void:
		var r: Variant = outcome.get(&"recoil")
		if r is Vector2 and (r as Vector2).is_finite():
			rig.set_meta(RECOIL_META, Vector3(r.x, r.y, 1.0 if bool(outcome.get(&"recoil_signed")) else 0.0)))


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
