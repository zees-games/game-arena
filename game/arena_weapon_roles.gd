extends RefCounted

## Which weapon fills each of this game's roles, and which weapon packs add weapons. The game names a role (melee,
## secondary, primary, heavy, thrown), never a pack: any addon with `spawn_provider.gd` and a static `weapon_defs()`
## can fill them, so a zz pack can drive the arena and, the other way, arena-weapons can drive Zombie Zone.
##
## `weapons.own` (arena-weapons) is the game's whole gun set under plain ids and is always registered first; `weapons.packs`
## names the packs that join after it, prefixed. A missing own pack is an error: the arena then has no weapons. Tuned in
## `cfg/addons/game_arena_weapons/*.yml` (dot-core's DotAddonConfig, so an operator's cfg/server tier wins).

const CHANNEL := "arena.roles"
const ADDON := "game_arena_weapons"
const PROVIDER := "spawn_provider.gd"
const SOURCE_PREFIX := "arenapack:"
const OFF_ARG := "--arena-no-weapon-packs"

## Role -> the arsenal slot it fills (the pack's own `slot` decides, not its tags, which no two packs agree on).
static func role_slot(role: StringName) -> int:
	use_layout()
	match role:
		&"melee":
			return AwWeaponIds.SLOT_MELEE
		&"secondary":
			return AwWeaponIds.SLOT_SIDEARM
		&"primary":
			return AwWeaponIds.SLOT_PRIMARY
		&"heavy":
			return AwWeaponIds.big_gun_slot()
	return AwWeaponIds.thrown_slot()


const ROLES: Array[StringName] = [&"melee", &"secondary", &"primary", &"heavy", &"thrown"]


## Grenades on key 4 and heavies on 5; must run before any weapon table is built, on both ends.
static func use_layout() -> void:
	AwWeaponIds.use_thrown_before_heavy()

## Role -> the weapon that fills it when no pack does; its short name also picks a pack's `<prefix>_pistol` first.
const ROLE_DEFAULT := {
	&"melee": AwWeaponIds.KNIFE,
	&"secondary": AwWeaponIds.PISTOL,
	&"primary": AwWeaponIds.RIFLE,
	&"heavy": AwWeaponIds.LAUNCHER,
	&"thrown": AwWeaponIds.FRAG,
}

const AW_PREFIX := "aw_"
## Weapons the arena carried before arena-weapons owned the set, to what replaces them.
const RETIRED := {
	&"fists": &"knife", &"shiv": &"knife", &"hatchet": &"knife", &"mallet": &"knife", &"pickaxe": &"knife", &"spade": &"knife",
}

const DEFAULTS := {
	"weapons": {
		# Pack folders under res://addons whose weapons join the own pack's ([] = none); a missing one is skipped.
		"packs": ["arena_weapons"],
		# The pack that owns the plain ids (`rifle`, not `aw_rifle`): the game's own set, registered first.
		"own": "arena_weapons",
		# Weapon ids kept out of the catalogue.
		"exclude": [],
		# role -> weapon id, over the automatic choice (the first enabled pack's weapon for that slot).
		"roles": {},
	},
}

static var root: String = "res://addons"
static var config: Dictionary = DEFAULTS.duplicate(true)
## Pack folders registered by the last [method scan], in order.
static var packs: PackedStringArray = PackedStringArray()
## Weapon ids packs added, in registration order (the own pack's first).
static var pack_ids: Array[StringName] = []
## The pack registered under plain ids in the last [method scan], or "" when it is missing.
static var own_pack: String = ""
static var _own_script: GDScript = null
static var _classed: Array[StringName] = []
static var _by_role: Dictionary = {}
static var _sources: Array[StringName] = []
## Overrides `weapons.packs` when not empty (tests and a console).
static var force_packs: Array = []
static var _scanned := false
## Bumped by every [method clear]; caches of the weapon table compare it to know the pack set changed.
static var generation := 0


## Registers the packs named in `weapons.packs` and settles every role. Safe to call again; both ends call it, so both hold one list.
static func scan(from: String = "") -> void:
	use_layout()
	clear()
	_scanned = true

	var res := DotAddonConfig.load_dir(ADDON, DEFAULTS)
	config = res.value if res.ok else DEFAULTS.duplicate(true)

	if not res.ok:
		DotLog.warn(CHANNEL, "the weapon pack settings do not load, defaults used", {"why": res.error.message})

	var base := from if from != "" else root
	var wanted: Array = force_packs if not force_packs.is_empty() else DotAddonConfig.get_value(config, "weapons.packs", [])

	# The off switch drops the extra packs only; the own pack is the game's weapons.
	if OS.get_cmdline_user_args().has(OFF_ARG) or OS.get_cmdline_args().has(OFF_ARG):
		DotLog.info(CHANNEL, "extra weapon packs are off", {"arg": OFF_ARG})
		wanted = []

	var excluded: Array = DotAddonConfig.get_value(config, "weapons.exclude", [])
	var own := str(DotAddonConfig.get_value(config, "weapons.own", ""))
	var dirs := AwPackScan.provider_dirs(base, PROVIDER)
	var own_script: GDScript = null

	if own != "" and dirs.has(own):
		own_script = AwPackScan.load_provider(CHANNEL, own, base.path_join(own).path_join(PROVIDER), true)

	if own_script != null and own_script.has_method(&"set_id_prefix"):
		own_script.call(&"set_id_prefix", "")
		own_pack = own
		_own_script = own_script
		dirs.remove_at(dirs.find(own_pack))
		dirs.insert(0, own_pack)
		wanted = wanted.duplicate()
		wanted.append(own_pack)
	else:
		DotLog.error(CHANNEL, "the game's own weapon pack is missing; the arena has no weapons", {"pack": own})

	var taken: Array = []

	for dir in dirs:
		if not wanted.has(dir):
			continue

		var script := own_script if dir == own_pack else AwPackScan.load_provider(CHANNEL, dir, base.path_join(dir).path_join(PROVIDER), true)

		if script == null:
			continue

		var kept := PackedStringArray()

		for def in AwPackScan.kept(AwPackScan.defs_of(AwWeaponDamage.table(), script), excluded, taken):
			if taken.has(def.id):
				continue

			taken.append(def.id)
			pack_ids.append(def.id)
			kept.append(String(def.id))

		if kept.is_empty():
			continue

		var source := StringName(SOURCE_PREFIX + dir)
		AwPackSource.register(source, script, Callable(AwPackScan, &"defs_of").bind(script))
		_sources.append(source)
		packs.append(dir)
		_class_sounds(script, kept)
		DotLog.info(CHANNEL, "weapon pack registered", {"pack": dir, "weapons": kept.size()})

	_settle()


static func ensure() -> void:
	if not _scanned:
		scan()


## Gives each of a pack's guns the sound class it names (a provider's `sound_classes()`), so its lmg is not the rifle.
static func _class_sounds(script: GDScript, kept: PackedStringArray) -> void:
	if not script.has_method(&"sound_classes"):
		return

	var classes: Dictionary = script.call(&"sound_classes")

	for id: StringName in classes:
		if kept.has(String(id)):
			AwWeaponSound.set_class(id, classes[id])
			_classed.append(id)


static func clear() -> void:
	generation += 1
	for id in _classed:
		AwWeaponSound.set_class(id, &"")

	_classed.clear()

	for source in _sources:
		AwPackSource.unregister(source)

	_sources.clear()

	if own_pack != "":
		_own_script.call(&"set_id_prefix", str(_own_script.get_script_constant_map().get("DEFAULT_PREFIX", "aw_")))
		_own_script = null
		own_pack = ""

	packs = PackedStringArray()
	pack_ids.clear()
	_wire_cache = []
	_wire_cache_size = -1
	_by_role.clear()
	config = DEFAULTS.duplicate(true)
	_scanned = false


## The weapon id that fills [param role]; the default when no pack does.
static func resolve(role: StringName) -> StringName:
	ensure()
	return _by_role.get(role, ROLE_DEFAULT.get(role, &""))


## Every id that has a wire number: the append-only [method AwWeaponIds.all] (the own pack reuses them), then the packs' new ones.
static func wire_ids() -> Array[StringName]:
	ensure()
	# Built once per pack set: every player's pull asked for it (a 27-id array, a copy and a scan) each tick.
	# The list only changes when the pack ids do, and a caller only reads it.
	if _wire_cache_size == pack_ids.size() and not _wire_cache.is_empty():
		return _wire_cache
	var out := AwWeaponIds.all().duplicate()

	for id in pack_ids:
		if not out.has(id):
			out.append(id)

	_wire_cache = out
	_wire_cache_size = pack_ids.size()
	_wire_index.clear()
	for i in out.size():
		_wire_index[out[i]] = i
	return out


## [param id]'s place in [method wire_ids], or -1.
static func wire_index(id: StringName) -> int:
	var _ids := wire_ids()
	return _wire_index.get(id, -1)


static var _wire_cache: Array[StringName] = []
static var _wire_cache_size: int = -1
static var _wire_index: Dictionary = {}


## Today's id for a weapon id a client remembered: the pack's `aw_` ids and the retired melee weapons.
static func alias(id: StringName) -> StringName:
	ensure()
	var s := String(id)

	if own_pack != "" and s.begins_with(AW_PREFIX) and pack_ids.has(StringName(s.trim_prefix(AW_PREFIX))):
		return StringName(s.trim_prefix(AW_PREFIX))

	return RETIRED.get(id, id) if own_pack != "" else id


static func describe_lines() -> PackedStringArray:
	var out := PackedStringArray(["weapon packs: %s" % (", ".join(packs) if not packs.is_empty() else "none")])

	for role: StringName in ROLE_DEFAULT:
		out.append("  %s -> %s" % [role, resolve(role)])

	return out


static func _settle() -> void:
	var by_id := {}

	for def in AwWeaponCatalogue.weapons(AwWeaponDamage.table()):
		by_id[def.id] = def

	var forced: Dictionary = DotAddonConfig.get_value(config, "weapons.roles", {})

	for role: StringName in ROLES:
		var named := StringName(str(forced.get(String(role), "")))

		if named != &"" and by_id.has(named):
			_by_role[role] = named
			continue

		var pick := _auto(role, by_id)

		if pick != &"":
			_by_role[role] = pick


## The first registered pack weapon for [param role]'s slot, one called `<prefix>_<default's name>` before the rest.
static func _auto(role: StringName, by_id: Dictionary) -> StringName:
	var named: StringName = ROLE_DEFAULT[role]

	if pack_ids.has(named) and by_id.has(named) and (by_id[named] as DotWeaponDef).slot == role_slot(role):
		return named

	return AwPackRoles.first_for_slot(pack_ids, by_id, role_slot(role), ROLE_DEFAULT[role])
