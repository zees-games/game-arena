extends RefCounted

## The stock textures a dropped `<map>_orig` pack lacks, read from the player's OWN Source game install. LOCAL ONLY.
##
## A BSP carries only its author's custom textures; the game's own (most of a TF2 map) live in the game's VPK archives,
## which we may not redistribute, so a converted pack lists them in `original_textures.missing` and draws free stand-ins.
## When the player has the game installed, [method fill] reads each missing material from their archives (`ArenaVpk`,
## `ArenaVtf`), caches it as a PNG under `user://source_cache` (the game-fatal-contact folder: `%APPDATA%` on Windows,
## `~/.local/share` on Linux), copies it into the pack's `textures/orig/` in `user://maps` and points the pack's surfaces
## at it. It refuses any pack outside `user://`: nothing read here may reach the repository or a published pack.
##
## Where the game is: the `source_game_path` setting (General > Local maps, or the console command of that name), else the
## usual Steam folders on Windows, Linux (also Flatpak and Snap) and macOS, and each Steam library they list.

const Vpk := preload("arena_vpk.gd")
const Vtf := preload("arena_vtf.gd")

const SETTING := &"source_game_path"
## Decoded textures, per install: never inside the project.
const CACHE_DIR := "user://source_cache"
## Where an `_orig` pack keeps its textures (dot-map-convert `origtex.DIR`).
const ORIG_DIR := "textures/orig"
## The games looked for under each Steam library, in order.
const GAMES := ["Team Fortress 2"]
## Mod folders whose archives are searched first, then the rest of the install's folders by name.
const FOLDERS_FIRST := ["tf", "tf2", "hl2"]
const MAX_SIDE := 512

## Install folder -> the opened archives (an Array of `ArenaVpk`), read once per run.
static var _opened: Dictionary = {}


## The install to read: [param configured] when set (even when it has no archives, so a wrong path is said, not
## replaced), else the first usual Steam folder that has any. Empty when there is none.
static func find_install(configured: String) -> String:
	configured = configured.strip_edges().replace("\\", "/").rstrip("/")
	if configured != "":
		return configured
	for root in candidates():
		if not archives(root).is_empty():
			return root
	return ""


## Every folder a Steam install of [constant GAMES] is usually in, existing or not.
static func candidates() -> PackedStringArray:
	var steam := PackedStringArray()
	var home := OS.get_environment("HOME") if OS.get_environment("HOME") != "" else OS.get_environment("USERPROFILE")
	for program_files in [OS.get_environment("ProgramFiles(x86)"), OS.get_environment("ProgramFiles"),
			"C:/Program Files (x86)", "C:/Program Files"]:
		if str(program_files) != "":
			steam.append(str(program_files).replace("\\", "/").path_join("Steam"))
	if home != "":
		for sub in [".steam/steam", ".steam/root", ".local/share/Steam", ".var/app/com.valvesoftware.Steam/.local/share/Steam",
				"snap/steam/common/.local/share/Steam", "Library/Application Support/Steam"]:
			steam.append(home.replace("\\", "/").path_join(sub))
	var libraries := PackedStringArray()
	for root in steam:
		if not libraries.has(root):
			libraries.append(root)
		for lib in library_folders(FileAccess.get_file_as_string(root.path_join("steamapps/libraryfolders.vdf"))):
			if not libraries.has(lib):
				libraries.append(lib)
	var out := PackedStringArray()
	for lib in libraries:
		for game: String in GAMES:
			out.append(lib.path_join("steamapps/common").path_join(game))
	return out


## The library folders a Steam `libraryfolders.vdf` [param vdf] names.
static func library_folders(vdf: String) -> PackedStringArray:
	var out := PackedStringArray()
	for m in RegEx.create_from_string("\"path\"\\s+\"([^\"]+)\"").search_all(vdf):
		out.append(m.get_string(1).replace("\\\\", "/").replace("\\", "/").rstrip("/"))
	return out


## The `*_dir.vpk` archives of the install at [param root], mod folders ([constant FOLDERS_FIRST]) first. [param root] may
## be the game folder, one of its mod folders (`tf`) or a `_dir.vpk` itself.
static func archives(root: String) -> PackedStringArray:
	var out := PackedStringArray()
	if root.ends_with("_dir.vpk"):
		if FileAccess.file_exists(root):
			out.append(root)
		return out
	if ["tf", "hl2"].has(root.get_file().to_lower()):
		root = root.get_base_dir()
	if DirAccess.dir_exists_absolute(root):
		_collect(root, 2, out)
	return out


## Appends the non-sound `_dir.vpk` files of [param dir], then those of its subfolders [param depth] levels down, mod
## folders first: two levels cover both `Team Fortress 2/tf/` and a server's `tf2/tf/` + `tf2/hl2/`.
static func _collect(dir: String, depth: int, out: PackedStringArray) -> void:
	# open, not get_files_at: a folder we may not read (a server's own) is skipped without an engine error.
	var access := DirAccess.open(dir)
	if access == null:
		return
	var files := access.get_files()
	files.sort()
	for f in files:
		if f.ends_with("_dir.vpk") and not f.contains("_sound_"):
			out.append(dir.path_join(f))
	if depth <= 0:
		return
	var subs := Array(access.get_directories())
	subs.sort()
	var ordered: Array = []
	for first: String in FOLDERS_FIRST:
		if subs.has(first):
			ordered.append(first)
	for sub: String in subs:
		if not ordered.has(sub) and not sub.begins_with("."):
			ordered.append(sub)
	for sub: String in ordered:
		_collect(dir.path_join(sub), depth - 1, out)


## The bytes of [param material]'s base texture (its VMT's `$basetexture`, through one patch `include`) from
## [param sets], first archive first; empty when no archive has it.
static func material_vtf(sets: Array, material: String) -> PackedByteArray:
	var path := Vtf.clean_material(material)
	var vmt := _read(sets, "materials/%s.vmt" % path)
	if vmt.is_empty():
		return _read(sets, "materials/%s.vtf" % path)
	var keys := Vtf.vmt_keys(vmt.get_string_from_utf8())
	if not keys.has("$basetexture") and keys.has("include"):
		var included := _read(sets, str(keys["include"]).to_lower().replace("\\", "/").lstrip("/"))
		keys = Vtf.vmt_keys(included.get_string_from_utf8()) if not included.is_empty() else keys
	var basetexture := str(keys.get("$basetexture", "")).to_lower().replace("\\", "/").strip_edges().trim_suffix(".vtf")
	return _read(sets, "materials/%s.vtf" % basetexture.lstrip("/")) if basetexture != "" else PackedByteArray()


static func _read(sets: Array, path: String) -> PackedByteArray:
	for vpk: Vpk in sets:
		if vpk.has(path):
			var got := vpk.read(path)
			if not got.is_empty():
				return got
	return PackedByteArray()


## The opened archives of [param install] (cached for the run); empty when it has none.
static func open_install(install: String) -> Array:
	if _opened.has(install):
		return _opened[install]
	var sets: Array = []
	for path in archives(install):
		var vpk := Vpk.new()
		if vpk.open(path, PackedStringArray(["vmt", "vtf"])) and not vpk.entries.is_empty():
			sets.append(vpk)
	_opened[install] = sets
	return sets


## Where [param install]'s decoded textures are cached: under the user folder, one folder per install.
static func cache_dir(install: String) -> String:
	return CACHE_DIR.path_join("%s_%s" % [install.get_file().to_snake_case().left(24), install.md5_text().left(10)])


## Fills what the `_orig` pack at [param prefix] (`user://maps/…/<name>`, no extension) lacks from [param install].
## Returns {ok, filled: [material], missing: [material], install, error}; the pack's json then says the same in
## `original_textures` (`from_install`, `filled`, `install`, `missing`), which `ArenaClient.looks_line` reads.
static func fill(prefix: String, install: String) -> Dictionary:
	var out := {"ok": false, "filled": [], "missing": [], "install": install, "error": ""}
	if not prefix.begins_with("user://"):
		out["error"] = "refused: %s is not in the user folder (the game's own textures never go into the project or a pack)" % prefix
		return out
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(prefix + ".json"))
	if not parsed is Dictionary or not (parsed as Dictionary).get("original_textures") is Dictionary:
		out["error"] = "%s has no original_textures" % prefix.get_file()
		return out
	var data: Dictionary = parsed
	var orig: Dictionary = data["original_textures"]
	var missing: Array = orig.get("missing", [])
	out["missing"] = missing.duplicate()
	if missing.is_empty():
		out["ok"] = true
		return out
	var sets := open_install(install) if install != "" else []
	orig["install"] = install
	if sets.is_empty():
		out["error"] = "no Source game archives (*_dir.vpk) at %s" % install if install != "" else "no Source game install found"
		_save(prefix, data)
		return out
	var cache := cache_dir(install)
	DirAccess.make_dir_recursive_absolute(cache)
	DirAccess.make_dir_recursive_absolute(prefix.get_base_dir().path_join(ORIG_DIR))
	var filled: Array = orig.get("filled", [])
	var left: Array = []
	var by_material := {}
	for m: Variant in missing:
		var name := Vtf.safe_name(str(m))
		var cached := cache.path_join(name + ".png")
		if not FileAccess.file_exists(cached):
			var img := Vtf.image(material_vtf(sets, str(m)), MAX_SIDE)
			if img == null or img.save_png(cached) != OK:
				left.append(m)
				continue
		var rel := ORIG_DIR.path_join(name + ".png")
		if DirAccess.copy_absolute(cached, prefix.get_base_dir().path_join(rel)) != OK:
			left.append(m)
			continue
		by_material[str(m)] = rel
		filled.append(m)
	for s: Variant in data.get("surfaces", []):
		if s is Dictionary and by_material.has(str((s as Dictionary).get("material", ""))):
			(s as Dictionary)["orig"] = by_material[str((s as Dictionary)["material"])]
	orig["missing"] = left
	orig["filled"] = filled
	orig["from_install"] = filled.size()
	orig["textures"] = int(orig.get("textures", 0)) + by_material.size()
	_save(prefix, data)
	out["ok"] = true
	out["filled"] = by_material.keys()
	out["missing"] = left
	return out


## [method fill] on every local `_orig` pack in `user://maps`; one result per pack, each with its `title`.
static func fill_all(install: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry: Dictionary in DotMapLocalMaps.scan(PackedStringArray(["user://maps"])):
		var prefix := str(entry.get("prefix", ""))
		if str(entry.get("name", "")).to_lower().ends_with("_orig") and not entry.has("zip") and prefix.begins_with("user://"):
			var one := fill(prefix, install)
			one["title"] = str(entry.get("title", entry.get("id", "")))
			out.append(one)
	return out


static func _save(prefix: String, data: Dictionary) -> void:
	var f := FileAccess.open(prefix + ".json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data, "", true, true))
