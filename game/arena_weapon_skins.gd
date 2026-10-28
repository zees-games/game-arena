extends RefCounted

## Dresses this game's weapons, by role, with the models of any installed weapon pack. The game never names a pack,
## a model or a weapon id here: a pack that has `addons/<name>/spawn_provider.gd` with a static `role_art()`
## (role -> {model, muzzle, motion, view}) is applied; none installed, the weapons keep zee-dot-weapons' own art.
## Rows are plain data, so a pack needs no zee class in its signatures.

const CHANNEL := "arena.skins"
const PROVIDER := "spawn_provider.gd"
const OFF_ARG := "--arena-no-weapon-skins"

## Pack folder names applied by the last [method apply], in order.
static var applied: PackedStringArray = PackedStringArray()


## Rebuilds zee's art table and dresses it from every pack under [param root] (just those in [param only] when given); returns the pack names applied.
## Later packs (by folder name) win a role, with a DEBUG line saying so.
static func apply(root: String = "res://addons", only: PackedStringArray = PackedStringArray()) -> PackedStringArray:
	applied = PackedStringArray()
	ZeeWeaponArtTable.drop_cache()

	if OS.get_cmdline_user_args().has(OFF_ARG) or OS.get_cmdline_args().has(OFF_ARG):
		DotLog.info(CHANNEL, "weapon skins are off", {"arg": OFF_ARG})
		return applied

	var table := ZeeWeaponArtTable.table()
	var owner_of := {}

	for pack in _packs(root):
		if not only.is_empty() and not only.has(pack["name"]):
			continue

		var rows: Dictionary = pack["script"].call(&"role_art")
		var n := 0

		for role: Variant in rows:
			var art: Variant = table.get(StringName(str(role)))

			if not art is ZeeWeaponArt:
				continue

			if owner_of.has(role):
				DotLog.debug(CHANNEL, "a later pack takes a role", {"role": role, "from": owner_of[role], "to": pack["name"]})

			ZeeArtDress.apply(art as ZeeWeaponArt, rows[role] as Dictionary)
			owner_of[role] = pack["name"]
			n += 1

		applied.append(str(pack["name"]))
		DotLog.info(CHANNEL, "weapon skin pack applied", {"pack": pack["name"], "roles": n})

	return applied


## Back to zee's own art.
static func clear() -> void:
	applied = PackedStringArray()
	ZeeWeaponArtTable.drop_cache()


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
