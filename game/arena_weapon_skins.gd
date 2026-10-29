extends RefCounted

## Dresses this game's weapons, by role, with the models of any installed weapon pack. The game never names a pack,
## a model or a weapon id here: a pack that has `addons/<name>/spawn_provider.gd` with a static `role_art()`
## (role -> {model, muzzle, motion, view}) is applied; none installed, the weapons keep zee-dot-weapons' own art.
## Rows are plain data, so a pack needs no zee class in its signatures.

const Roles := preload("arena_weapon_roles.gd")
const Paths := preload("arena_paths.gd")
const CHANNEL := "arena.skins"
const PROVIDER := "spawn_provider.gd"
const OFF_ARG := "--arena-no-weapon-skins"
const DRESSER := &"arena_skins"

## Pack folder names applied by the last [method apply], in order.
static var applied: PackedStringArray = PackedStringArray()
## role -> art row, the later pack winning; re-applied by the table's dresser on every rebuild.
static var _rows: Dictionary = {}


## Rebuilds zee's art table and dresses it from every pack under [param root] (just those in [param only] when given); returns the pack names applied.
## Later packs (by folder name) win a role, with a DEBUG line saying so.
static func apply(root: String = "res://addons", only: PackedStringArray = PackedStringArray()) -> PackedStringArray:
	applied = PackedStringArray()
	_rows = {}
	ZeeWeaponArtTable.remove_dresser(DRESSER)
	# Registering a pack source drops the art cache, which would erase this dressing if it came later.
	Roles.ensure()
	ZeeWeaponArtTable.drop_cache()

	if OS.get_cmdline_user_args().has(OFF_ARG) or OS.get_cmdline_args().has(OFF_ARG):
		DotLog.info(CHANNEL, "weapon skins are off", {"arg": OFF_ARG})
		return applied

	var owner_of := {}
	var table := ZeeWeaponArtTable.table()

	for pack in _packs(root):
		if not only.is_empty() and not only.has(pack["name"]):
			continue

		var rows: Dictionary = pack["script"].call(&"role_art")
		var n := 0

		for role: Variant in rows:
			if not table.get(StringName(str(role))) is ZeeWeaponArt:
				continue

			if owner_of.has(role):
				DotLog.debug(CHANNEL, "a later pack takes a role", {"role": role, "from": owner_of[role], "to": pack["name"]})

			_rows[StringName(str(role))] = rows[role]
			owner_of[role] = pack["name"]
			n += 1

		applied.append(str(pack["name"]))
		DotLog.info(CHANNEL, "weapon skin pack applied", {"pack": pack["name"], "roles": n})

	# Registered, not applied once: a later add_source / keep_only rebuilds the table and would drop plain edits.
	if not _rows.is_empty():
		ZeeWeaponArtTable.add_dresser(DRESSER, Callable(load(Paths.rebase("res://game/arena_weapon_skins.gd")), &"dress"))

	return applied


## Back to zee's own art.
static func clear() -> void:
	applied = PackedStringArray()
	_rows = {}
	ZeeWeaponArtTable.remove_dresser(DRESSER)
	ZeeWeaponArtTable.drop_cache()


## The table's dresser: gives every role with a row its pack model.
static func dress(table: Dictionary) -> void:
	for role: StringName in _rows:
		var art: Variant = table.get(role)

		if art is ZeeWeaponArt:
			ZeeArtDress.apply(art as ZeeWeaponArt, _rows[role] as Dictionary)
			DotLog.debug(CHANNEL, "role dressed", {"role": role, "model": (art as ZeeWeaponArt).model_path})


static func describe_lines() -> PackedStringArray:
	return PackedStringArray(["weapon skins: %s" % (", ".join(applied) if not applied.is_empty() else "none (zee art)")])


static func _packs(root: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []

	if not DirAccess.dir_exists_absolute(root):
		return out

	var names := DirAccess.get_directories_at(root)
	names.sort()

	for dir in names:
		var path := root.path_join(dir).path_join(PROVIDER)

		if not ResourceLoader.exists(path):
			continue

		var script := load(path) as GDScript

		if script != null and script.has_method(&"role_art"):
			out.append({"name": dir, "script": script})

	return out
