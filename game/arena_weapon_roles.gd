extends RefCounted

## Which weapon fills each of this game's roles, and which weapon packs add weapons. The game names a role (melee,
## secondary, primary, heavy, thrown), never a pack: any addon with `spawn_provider.gd` and a static `weapon_defs()`
## can fill them, so a zz pack can drive the arena and, the other way, arena-weapons can drive Zombie Zone.
##
## Off by default: with `weapons.packs` empty nothing is registered and zee-dot-weapons fills every role. Tuned in
## `cfg/addons/game_arena_weapons/*.yml` (dot-core's DotAddonConfig, so an operator's cfg/server tier wins).

const ArenaPaths := preload("arena_paths.gd")

const CHANNEL := "arena.roles"
const ADDON := "game_arena_weapons"
const PROVIDER := "spawn_provider.gd"
const SOURCE_PREFIX := "arenapack:"
const OFF_ARG := "--arena-no-weapon-packs"
const SELF_PATH := "res://game/arena_weapon_roles.gd"

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

const DEFAULTS := {
	"weapons": {
		# Pack folders under res://addons whose weapons join the catalogue ([] = none, zee alone).
		"packs": [],
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
	var dirs := DirAccess.get_directories_at(base)
	dirs.sort()

	for dir in dirs:
		var path := base.path_join(dir).path_join(PROVIDER)

		if not wanted.has(dir) or not ResourceLoader.exists(path):
			continue

		var script := load(path) as GDScript

		if script == null or not script.has_method(&"weapon_defs"):
			DotLog.warn(CHANNEL, "a weapon pack has no weapon_defs", {"pack": dir})
			continue

		var kept := PackedStringArray()

		for def in _defs(ZeeWeaponDamage.table(), script):
			if not excluded.has(String(def.id)) and not ZeeWeaponIds.all().has(def.id) and not pack_ids.has(def.id):
				pack_ids.append(def.id)
				kept.append(String(def.id))

		if kept.is_empty():
			continue

		var source := StringName(SOURCE_PREFIX + dir)
		var me := _me()
		ZeeWeaponPack.add_source(source, Callable(me, &"_defs").bind(script))
		ZeeWeaponArtTable.add_source(source, Callable(me, &"_art").bind(script))
		_sources.append(source)
		packs.append(dir)
		DotLog.info(CHANNEL, "weapon pack registered", {"pack": dir, "weapons": kept.size()})

	_settle()


static func ensure() -> void:
	if not _scanned:
		scan()


static func clear() -> void:
	for source in _sources:
		ZeeWeaponPack.remove_source(source)
		ZeeWeaponArtTable.remove_source(source)

	_sources.clear()
	packs = PackedStringArray()
	pack_ids.clear()
	_by_role.clear()
	config = DEFAULTS.duplicate(true)
	_scanned = false


## The weapon id that fills [param role]; the zee default when no pack does.
static func resolve(role: StringName) -> StringName:
	ensure()
	return _by_role.get(role, ROLE_DEFAULT.get(role, &""))


## Every id that has a wire number: zee's, then the packs'.
static func wire_ids() -> Array[StringName]:
	ensure()
	var out := ZeeWeaponIds.all().duplicate()
	out.append_array(pack_ids)
	return out


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
	var first := &""
	var suffix := "_" + String(ROLE_DEFAULT[role])

	for id in pack_ids:
		var def: DotWeaponDef = by_id.get(id)

		if def == null or def.slot != int(ROLE_SLOT[role]):
			continue

		if String(id).ends_with(suffix):
			return id

		if first == &"":
			first = id

	return first


static func _me() -> GDScript:
	return load(ArenaPaths.rebase(SELF_PATH)) as GDScript


## A source Callable must be a static method, never a lambda.
static func _defs(types: Dictionary, provider: GDScript) -> Array[DotWeaponDef]:
	return provider.call(&"weapon_defs", types)


## The pack's art: its `weapon_art()` when it has one, else the zee gun of the same slot under the pack weapon's id, dressed from `art_rows()`.
static func _art(provider: GDScript) -> Array[ZeeWeaponArt]:
	if provider.has_method(&"weapon_art"):
		return provider.call(&"weapon_art")

	var out: Array[ZeeWeaponArt] = []
	var rows: Dictionary = provider.call(&"art_rows") if provider.has_method(&"art_rows") else {}

	for def in provider.call(&"weapon_defs", ZeeWeaponDamage.table()):
		var copy: ZeeWeaponArt

		# Built, never read from the table: this runs while the table is being built.
		match def.slot:
			ZeeWeaponIds.SLOT_SIDEARM:
				copy = ZeeWeaponArtTable.pistol()
			ZeeWeaponIds.SLOT_HEAVY:
				copy = ZeeWeaponArtTable.launcher()
			ZeeWeaponIds.SLOT_MELEE:
				copy = ZeeWeaponArtTable.knife()
			ZeeWeaponIds.SLOT_THROWN:
				copy = ZeeWeaponArtTable.frag()
			_:
				copy = ZeeWeaponArtTable.rifle()

		copy.id = def.id
		ZeeArtDress.apply(copy, rows.get(def.id, {}))
		out.append(copy)

	return out
