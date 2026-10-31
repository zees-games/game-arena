extends RefCounted

## Which weapon fills each of this game's roles, and which weapon packs add weapons. The game names a role (melee,
## secondary, primary, heavy, thrown), never a pack: any addon with `spawn_provider.gd` and a static `weapon_defs()`
## can fill them, so a zz pack can drive the arena and, the other way, arena-weapons can drive Zombie Zone.
##
## `weapons.own` (arena-weapons) is the game's whole gun set under plain ids, and zee's built-ins are dropped; other packs join
## prefixed. Without it zee-dot-weapons fills every role, as a fallback that keeps a game up. Tuned in
## `cfg/addons/game_arena_weapons/*.yml` (dot-core's DotAddonConfig, so an operator's cfg/server tier wins).

const CHANNEL := "arena.roles"
const ADDON := "game_arena_weapons"
const PROVIDER := "spawn_provider.gd"
const SOURCE_PREFIX := "arenapack:"
const OFF_ARG := "--arena-no-weapon-packs"

## Role -> the arsenal slot it fills (the pack's own `slot` decides, not its tags, which no two packs agree on).
const ROLE_SLOT := {
	&"melee": ZeeWeaponIds.SLOT_MELEE,
	&"secondary": ZeeWeaponIds.SLOT_SIDEARM,
	&"primary": ZeeWeaponIds.SLOT_PRIMARY,
	&"heavy": ZeeWeaponIds.SLOT_HEAVY,
	&"thrown": ZeeWeaponIds.SLOT_THROWN,
}

## Role -> the zee weapon that fills it when no pack does; its short name also picks a pack's `<prefix>_pistol` first.
const ROLE_DEFAULT := {
	&"melee": ZeeWeaponIds.KNIFE,
	&"secondary": ZeeWeaponIds.PISTOL,
	&"primary": ZeeWeaponIds.RIFLE,
	&"heavy": ZeeWeaponIds.LAUNCHER,
	&"thrown": ZeeWeaponIds.FRAG,
}

const AW_PREFIX := "aw_"
## Weapons the arena carried before arena-weapons owned the set, to what replaces them.
const RETIRED := {
	&"fists": &"knife", &"shiv": &"knife", &"hatchet": &"knife", &"mallet": &"knife", &"pickaxe": &"knife", &"spade": &"knife",
}

const DEFAULTS := {
	"weapons": {
		# Pack folders under res://addons whose weapons join the catalogue ([] = none, zee alone); a missing one is skipped.
		"packs": ["arena_weapons"],
		# The pack that owns the plain ids (`rifle`, not `aw_rifle`) and replaces zee's built-ins; "" keeps zee's.
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
## Weapon ids packs added, in registration order: the wire numbers after zee's.
static var pack_ids: Array[StringName] = []
## The pack registered under plain ids in the last [method scan], or "" (zee's built-ins stand).
static var own_pack: String = ""
static var _own_script: GDScript = null
static var _classed: Array[StringName] = []
static var _by_role: Dictionary = {}
static var _sources: Array[StringName] = []
## Overrides `weapons.packs` when not empty (tests and a console).
static var force_packs: Array = []
static var _scanned := false


## Registers the packs named in `weapons.packs` and settles every role. Safe to call again; both ends call it, so both hold one list.
static func scan(from: String = "") -> void:
	clear()
	_scanned = true

	if OS.get_cmdline_user_args().has(OFF_ARG) or OS.get_cmdline_args().has(OFF_ARG):
		DotLog.info(CHANNEL, "weapon packs are off", {"arg": OFF_ARG})
		return

	var res := DotAddonConfig.load_dir(ADDON, DEFAULTS)
	config = res.value if res.ok else DEFAULTS.duplicate(true)

	if not res.ok:
		DotLog.warn(CHANNEL, "the weapon pack settings do not load, defaults used", {"why": res.error.message})

	var base := from if from != "" else root
	var wanted: Array = force_packs if not force_packs.is_empty() else DotAddonConfig.get_value(config, "weapons.packs", [])
	var excluded: Array = DotAddonConfig.get_value(config, "weapons.exclude", [])
	var own := str(DotAddonConfig.get_value(config, "weapons.own", ""))
	var dirs := ZeePackScan.provider_dirs(base, PROVIDER)
	var own_script: GDScript = null

	# arena_weapons owns its definitions from API level 2; an older build falls back to zee's set (requires.floor.json).
	var own_ready := DotAddonApi.build_level("arena_weapons") >= 2
	if not own_ready and own == "arena_weapons":
		DotLog.warn(CHANNEL, "arena_weapons is older than API level 2; zee's weapons stand in", {"level": DotAddonApi.build_level("arena_weapons")})

	if own != "" and own_ready and wanted.has(own) and dirs.has(own):
		own_script = ZeePackScan.load_provider(CHANNEL, own, base.path_join(own).path_join(PROVIDER), true)

	if own_script != null and own_script.has_method(&"set_id_prefix"):
		own_script.call(&"set_id_prefix", "")
		ZeeWeaponPack.keep_only([])
		own_pack = own
		_own_script = own_script
	elif own != "":
		DotLog.error(CHANNEL, "the game's own weapon pack is missing; zee's weapons stand in", {"pack": own})

	var taken: Array = [] if own_pack != "" else ZeeWeaponIds.all().duplicate()
	if own_pack != "":
		dirs.remove_at(dirs.find(own_pack))
		dirs.insert(0, own_pack)

	for dir in dirs:
		if not wanted.has(dir):
			continue

		var script := own_script if dir == own_pack else ZeePackScan.load_provider(CHANNEL, dir, base.path_join(dir).path_join(PROVIDER), true)

		if script == null:
			continue

		var kept := PackedStringArray()

		for def in ZeePackScan.kept(ZeePackScan.defs_of(ZeeWeaponDamage.table(), script), excluded, taken):
			if taken.has(def.id):
				continue

			taken.append(def.id)
			pack_ids.append(def.id)
			kept.append(String(def.id))

		if kept.is_empty():
			continue

		var source := StringName(SOURCE_PREFIX + dir)
		ZeePackSource.register(source, script, Callable(ZeePackScan, &"defs_of").bind(script))
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
			ZeeWeaponSound.set_class(id, classes[id])
			_classed.append(id)


static func clear() -> void:
	for id in _classed:
		ZeeWeaponSound.set_class(id, &"")

	_classed.clear()

	for source in _sources:
		ZeePackSource.unregister(source)

	_sources.clear()

	if own_pack != "":
		ZeeWeaponPack.keep_only(null)
		_own_script.call(&"set_id_prefix", str(_own_script.get_script_constant_map().get("DEFAULT_PREFIX", "aw_")))
		_own_script = null
		own_pack = ""

	packs = PackedStringArray()
	pack_ids.clear()
	_by_role.clear()
	config = DEFAULTS.duplicate(true)
	_scanned = false


## The weapon id that fills [param role]; the zee default when no pack does.
static func resolve(role: StringName) -> StringName:
	ensure()
	return _by_role.get(role, ROLE_DEFAULT.get(role, &""))


## Every id that has a wire number: zee's (a plain-id pack reuses them), then the packs' new ones.
static func wire_ids() -> Array[StringName]:
	ensure()
	var out := ZeeWeaponIds.all().duplicate()

	for id in pack_ids:
		if not out.has(id):
			out.append(id)

	return out


## Today's id for a weapon id a client remembered: the pack's `aw_` ids and the retired melee weapons.
static func alias(id: StringName) -> StringName:
	ensure()
	var s := String(id)

	if own_pack != "" and s.begins_with(AW_PREFIX) and pack_ids.has(StringName(s.trim_prefix(AW_PREFIX))):
		return StringName(s.trim_prefix(AW_PREFIX))

	return RETIRED.get(id, id) if own_pack != "" else id


static func describe_lines() -> PackedStringArray:
	var out := PackedStringArray(["weapon packs: %s" % (", ".join(packs) if not packs.is_empty() else "none (zee)")])

	for role: StringName in ROLE_DEFAULT:
		out.append("  %s -> %s" % [role, resolve(role)])

	return out


static func _settle() -> void:
	var by_id := {}

	for def in ZeeWeaponPack.weapons(ZeeWeaponDamage.table()):
		by_id[def.id] = def

	var forced: Dictionary = DotAddonConfig.get_value(config, "weapons.roles", {})

	for role: StringName in ROLE_SLOT:
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

	if pack_ids.has(named) and by_id.has(named) and (by_id[named] as DotWeaponDef).slot == int(ROLE_SLOT[role]):
		return named

	return ZeePackRoles.first_for_slot(pack_ids, by_id, int(ROLE_SLOT[role]), ROLE_DEFAULT[role])
