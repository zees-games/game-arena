extends DotGameCheckSuite

const ArenaMap := preload("../maps/arena_map.gd")
const ArenaBspMap := preload("../maps/arena_bsp_map.gd")
const ArenaLocalMaps := preload("../maps/arena_local_maps.gd")
const ArenaMaps := preload("../game/arena_maps.gd")
const ArenaClient := preload("../game/arena_client.gd")
const ArenaUserDir := preload("../game/arena_user_dir.gd")
const ArenaVoteSource := preload("../game/arena_vote_source.gd")
const ArenaVpk := preload("../game/arena_vpk.gd")
const ArenaVtf := preload("../game/arena_vtf.gd")
const ArenaSourceInstall := preload("../game/arena_source_install.gd")

## Maps copied in by hand (`ArenaLocalMaps`): a raw convert folder under `res://addons/maps/` or `user://maps/` is listed
## as `<name>_local` only while `ArenaMaps.list_local` is on (solo), and loads with spawns, a solid, movers and a drawn world.
## The fixture section runs everywhere; `-- --source=<a map's convert folder>` repeats it on a real conversion.
##
## [codeblock]
## ./game.sh test headless_local_maps
## ./game.sh test headless_local_maps -- --source=/path/to/gm_fork/convert
## godot --headless --path . res://examples/headless_local_maps.tscn -- --source=/path/to/cp_x_orig --source-game=/path/to/tf2
## [/codeblock]

const FIXTURE_DIR := "res://examples/local_maps"
## Folder names no player would choose, so a run only ever removes what it copied.
const RES_FOLDER := "res://addons/maps/zz_local_maps_suite"
const USER_FOLDER := "user://maps/zz_local_maps_suite"
## What a player drags onto the window comes from outside the maps roots: built here, then dropped.
const DROP_SOURCE := "user://zz_local_maps_suite_src"
const DROPPED_FOLDER := "user://maps/zz_local_maps_suite_drop"
const DROPPED_ZIP := "user://maps/zz_local_maps_suite.zip"
## The suite's own zip cache, so a run never wipes a player's unpacked zips.
const ZIP_CACHE := "user://zz_local_maps_suite_cache"
## A stand-in for the old game-arena user folder and the new one, for the copy `ArenaUserDir.migrate` makes.
const OLD_USER := "user://zz_local_maps_suite_old_user"
const NEW_USER := "user://zz_local_maps_suite_new_user"
## A download's `convert` folder is copied as `user://maps/<its map>/convert`; the suite's map is named so.
const LAYOUT_MAP := "zz_local_maps_suite_map"
## A made-up Source game install (synthetic VPKs written by the suite: no Valve file is in the repository).
const SOURCE_STEAM := "user://zz_local_maps_suite_steam"
const SOURCE_GAME := SOURCE_STEAM + "/steamapps/common/Team Fortress 2"

var _source := ""
## `--source-game=<a real Source game install>`: with a `--source` holding an `_orig` pack, drops it filled from there.
var _source_game := ""


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--source="):
			_source = a.trim_prefix("--source=")
		elif a.begins_with("--source-game="):
			_source_game = a.trim_prefix("--source-game=")
	_run.call_deferred()


func _run() -> void:
	var sections := 0
	_clean()
	_test_user_dir()
	sections += 1
	_clean()
	_test_listing()
	sections += 1
	_clean()
	_copy_tree(FIXTURE_DIR, RES_FOLDER.path_join("convert"), ["fixture.json", "fixture.bin"])
	_test_load(&"fixture_local", "res://addons/maps", true)
	sections += 1
	_clean()
	_copy_tree(FIXTURE_DIR, USER_FOLDER, ["fixture.json", "fixture.bin"])
	_test_load(&"fixture_local", "user://maps", true)
	sections += 1
	# Drops, zips and `_orig` need dot-map API 24; an older host plays copied folders only (ArenaLocalMaps.can_drop).
	if ArenaLocalMaps.can_drop():
		_clean()
		_test_drops()
		sections += 1
		_clean()
		await _test_drop_layouts()
		sections += 1
		_clean()
		_test_original()
		sections += 1
		_clean()
		await _test_source_install()
		sections += 1
	else:
		print("-- drops and _orig skipped: dot-map API %d < %d" % [DotAddonApi.build_level("dot_map"), ArenaLocalMaps.DROP_LEVEL])
	var planned := 8 if ArenaLocalMaps.can_drop() else 4
	if not _source.is_empty():
		var name := DotMapLocalMaps.prefix_in(_source).get_file()
		if not _check(not name.is_empty(), "the source holds a converted map", _source):
			_report_sections(sections, sections, planned)
			return
		var id := StringName(name + DotMapLocalMaps.ID_SUFFIX)
		_clean()
		_copy_tree(_source, RES_FOLDER.path_join("convert"))
		_test_load(id, "res://addons/maps", false)
		_clean()
		_copy_tree(_source, USER_FOLDER)
		_test_load(id, "user://maps", false)
		sections += 2
		if not _source_game.is_empty() and name.ends_with("_orig") and ArenaLocalMaps.can_drop():
			_clean()
			await _test_real_install(name)
			sections += 1
			planned += 1
	_clean()
	ArenaMaps.list_local = false
	_report_sections(sections, sections, planned if _source.is_empty() else planned + 2)


## The real `_orig` pack in `--source`, dropped with the real install in `--source-game` (read in place, cached in the
## user folder): what it filled and what is still a stand-in, as the drop says it.
func _test_real_install(name: String) -> void:
	print("-- %s filled from the install at %s" % [name, _source_game])
	var t := Time.get_ticks_msec()
	var found := ArenaSourceInstall.archives(_source_game)
	if not _check(not found.is_empty(), "the install has archives", _source_game):
		return
	var sets: Array = ArenaSourceInstall.open_install(_source_game)
	var files := 0
	for v: Variant in sets:
		files += (v as ArenaVpk).entries.size()
	print("   %d archives, %d materials/textures listed in %d ms: %s" % [found.size(), files, Time.get_ticks_msec() - t, ", ".join(found)])
	var src: Variant = JSON.parse_string(FileAccess.get_file_as_string(DotMapLocalMaps.prefix_in(_source) + ".json"))
	var before: Array = ((src as Dictionary).get("original_textures", {}) as Dictionary).get("missing", []) if src is Dictionary else []
	var target := "user://maps".path_join(name)
	var had := DirAccess.dir_exists_absolute(target)
	ArenaMaps.list_local = true
	var local_maps: Object = DotMapLocalMaps
	var player_cache: Variant = local_maps.get(&"zip_cache")
	local_maps.set(&"zip_cache", ZIP_CACHE)
	var client := ArenaClient.new()
	client._menu_catalogue = ArenaMaps.catalogue()
	client.source_game_path = _source_game
	t = Time.get_ticks_msec()
	var said: String = await client.import_dropped(PackedStringArray([_source]))
	print("   dropped in %d ms: %s" % [Time.get_ticks_msec() - t, said])
	var prefix := DotMapLocalMaps.prefix_in(target)
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(prefix + ".json"))
	var orig: Dictionary = (data as Dictionary).get("original_textures", {}) if data is Dictionary else {}
	var filled: Array = orig.get("filled", [])
	var missing: Array = orig.get("missing", [])
	print("   filled %d of %d: %s\n   still stand-ins: %s" % [filled.size(), before.size(), ", ".join(filled), ", ".join(missing)])
	_check(not filled.is_empty() and filled.size() + missing.size() == before.size(), "the install fills some of the missing ones",
		"%d filled, %d missing of %d" % [filled.size(), missing.size(), before.size()])
	_check(said.contains("%d filled from your game install" % filled.size()), "and the drop says so", said)
	var drawn := 0
	for m: Variant in filled:
		if FileAccess.file_exists(prefix.get_base_dir().path_join("textures/orig/%s.png" % ArenaVtf.safe_name(str(m)))):
			drawn += 1
	_check(drawn == filled.size(), "each filled one is a texture in the pack", "%d of %d" % [drawn, filled.size()])
	local_maps.set(&"zip_cache", player_cache)
	client.free()
	if not had:
		_wipe(target)


func _test_listing() -> void:
	print("-- listed in solo only")
	_copy_tree(FIXTURE_DIR, RES_FOLDER.path_join("convert"), ["fixture.json", "fixture.bin"])
	ArenaMaps.list_local = false
	_check(not ArenaMaps.catalogue().has(&"fixture_local"), "a server's catalogue never lists a local map")
	ArenaMaps.list_local = true
	var cat := ArenaMaps.catalogue()
	_check(cat.has(&"fixture_local"), "a solo catalogue lists the copy as fixture_local")
	var def := cat.get_map(&"fixture_local") if cat.has(&"fixture_local") else null
	_check(def != null and def.display_name.ends_with(DotMapLocalMaps.TAG), "titled (local)",
		"" if def == null else def.display_name)
	_check(def != null and def.version.begins_with("0.0.0-"), "versioned by its bytes")
	var rows := ArenaMaps.menu_rows(cat, &"", null, [])
	_check(rows.any(func(row: Dictionary) -> bool: return row["id"] == "map:fixture_local"), "the solo menu offers it")
	ArenaMaps.apply_rotation(cat)
	_check(def != null and def.enabled, "a rotation setting does not hide it")


func _test_load(id: StringName, root: String, fixture: bool) -> void:
	print("-- %s from %s" % [id, root])
	ArenaMaps.list_local = true
	var entry := ArenaLocalMaps.entry(id)
	_check(str(entry.get("root", "")) == root, "found under %s" % root, str(entry))
	var map := ArenaMap.by_id(id)
	if not _check(map != null and map.local_prefix != "" and map.is_imported(), "by_id builds the local map"):
		return
	_check(map.display_name.ends_with(DotMapLocalMaps.TAG), "its title says local", map.display_name)
	_check(map.spawns.size() > 0, "it has spawns", str(map.spawns.size()))
	_check(map.bounds.size.x > 0.0 and map.bounds.size.z > 0.0, "it has bounds", str(map.bounds))
	_check(ArenaBspMap.world_prefix(String(id), map.manifest_path.get_base_dir()) == map.local_prefix,
		"its world is the copied folder")
	var solid := map.to_collision()
	_check(solid != null and solid.get_child_count() > 0, "its solid has shapes",
		"" if solid == null else str(solid.get_child_count()))
	if solid != null:
		solid.free()
	var drawn := map.to_scene()
	_check(drawn != null and drawn.get_child_count() > 0, "its world is drawn", "" if drawn == null else str(drawn.get_child_count()))
	if drawn != null:
		drawn.free()
	if fixture:
		# The fixture names no spawns: the one start is generated on its floor; its door is a mover.
		var got := ArenaLocalMaps.mesh(entry)
		_check(got != null and got.manifest.get("movers", []).size() == 2, "the copy's movers are read")


func _test_drops() -> void:
	print("-- dropped onto the window: a folder, a zip, and junk")
	ArenaMaps.list_local = true
	var local_maps: Object = DotMapLocalMaps  # API 24 by name, so this parses on API 23
	var player_cache: Variant = local_maps.get(&"zip_cache")
	local_maps.set(&"zip_cache", ZIP_CACHE)
	var client := ArenaClient.new()
	client._menu_catalogue = ArenaMaps.catalogue()
	_check(not client._menu_catalogue.has(&"fixture_local"), "nothing local before the drop")
	_copy_tree(FIXTURE_DIR, DROP_SOURCE.path_join("zz_local_maps_suite_drop"), ["fixture.json", "fixture.bin"])
	var said := client.on_maps_dropped(_drop(DROP_SOURCE.path_join("zz_local_maps_suite_drop")))
	_check(DirAccess.dir_exists_absolute(DROPPED_FOLDER), "the folder is copied into user://maps")
	_check(client._menu_catalogue.has(&"fixture_local"), "M lists the dropped map without a rebuild")
	_check(said.begins_with("Added ") and said.contains(DotMapLocalMaps.TAG), "the player is told it was added", said)
	var rows := ArenaMaps.menu_rows(client._menu_catalogue, &"", null, [])
	_check(rows.any(func(row: Dictionary) -> bool: return row["id"] == "map:fixture_local"), "the solo menu offers the drop")
	_wipe(DROPPED_FOLDER)

	var zip_path := DROP_SOURCE.path_join("zz_local_maps_suite.zip")
	_check(_zip_fixture(zip_path), "a zip of the convert folder is made")
	said = client.on_maps_dropped(_drop(zip_path))
	_check(FileAccess.file_exists(DROPPED_ZIP), "the zip is copied into user://maps")
	_check(said.begins_with("Added "), "a dropped zip is added", said)
	var entry := ArenaLocalMaps.entry(&"fixture_local")
	_check(str(entry.get("zip", "")) == DROPPED_ZIP, "found as the zip", str(entry))
	var map := ArenaMap.by_id(&"fixture_local")
	_check(map != null and map.local_prefix.begins_with(ZIP_CACHE), "by_id builds it from the unpacked zip",
		"" if map == null else map.local_prefix)
	if map != null:
		_check(ArenaBspMap.world_prefix("fixture_local", map.manifest_path.get_base_dir()) == map.local_prefix,
			"its world is the unpacked folder")
		var solid := map.to_collision()
		_check(solid != null and solid.get_child_count() > 0, "the zipped map has a solid")
		if solid != null:
			solid.free()

	var junk := DROP_SOURCE.path_join("notes.txt")
	var f := FileAccess.open(junk, FileAccess.WRITE)
	f.store_string("not a map")
	f.close()
	var before := client._menu_catalogue.size()
	said = client.on_maps_dropped(_drop(junk))
	_check(said.begins_with("Could not import notes.txt: "), "a bad drop is said with its reason", said)
	_check(client._menu_catalogue.size() == before, "a bad drop adds no row")
	_check(not FileAccess.file_exists("user://maps/notes.txt"), "a bad drop copies nothing")

	ArenaMaps.list_local = false
	var server_cat := ArenaMaps.catalogue()
	_check(not ArenaMaps.add_local(server_cat, &"fixture_local") and not server_cat.has(&"fixture_local"),
		"a server catalogue never takes a dropped map")
	ArenaMaps.list_local = true
	local_maps.set(&"zip_cache", player_cache)
	client.free()


## What the owner dropped: a download's `convert` folder (`<map>.bsp`, SOURCE.txt and `convert/` beside it), a whole download
## with the pack deeper than dot-map looks, and a map named like a shipped one; each is said on screen and listed in M.
func _test_drop_layouts() -> void:
	print("-- dropped layouts: a download's convert folder, a deep folder, a shipped map's name")
	ArenaMaps.list_local = true
	var local_maps: Object = DotMapLocalMaps
	var player_cache: Variant = local_maps.get(&"zip_cache")
	local_maps.set(&"zip_cache", ZIP_CACHE)
	var client := ArenaClient.new()
	client._menu_catalogue = ArenaMaps.catalogue()
	# No game install, whatever the machine has: _test_source_install fills from a fixture one.
	client.source_game_path = DROP_SOURCE.path_join("no_such_install")
	var download := DROP_SOURCE.path_join("download")
	_pack_as(download.path_join("convert"), LAYOUT_MAP)
	_touch(download.path_join(LAYOUT_MAP + ".bsp"))
	_touch(download.path_join("SOURCE.txt"))
	# A copy from before this fix, at user://maps/convert, would be found first: it goes.
	var had_bare := DirAccess.dir_exists_absolute("user://maps/convert")
	if not had_bare:
		_pack_as("user://maps/convert", LAYOUT_MAP)
	var said: String = await client.import_dropped(PackedStringArray([ProjectSettings.globalize_path(download.path_join("convert"))]))
	var id := StringName(LAYOUT_MAP + DotMapLocalMaps.ID_SUFFIX)
	var title := LAYOUT_MAP + DotMapLocalMaps.TAG
	_check(DotMapLocalMaps.prefix_in("user://maps".path_join(LAYOUT_MAP).path_join("convert")) != "",
		"a dropped convert folder is copied as user://maps/<map>/convert")
	if not had_bare:
		_check(not DirAccess.dir_exists_absolute("user://maps/convert"), "and an older bare convert copy of it is gone")
	_check(said.begins_with("Added %s. Press M and pick %s.\n" % [title, title]), "the player is told the title to pick", said)
	_check(said.ends_with("Copied to %s." % ProjectSettings.globalize_path("user://maps".path_join(LAYOUT_MAP).path_join("convert"))),
		"and the folder it was copied to", said)
	_check(client.last_drop_said == said, "and it is what was last said on screen", client.last_drop_said)
	_check(client._menu_catalogue.has(id), "M lists it at once")
	_check(str(ArenaLocalMaps.entry(id).get("dir", "")).begins_with("user://maps".path_join(LAYOUT_MAP)), "found there",
		str(ArenaLocalMaps.entry(id)))
	_wipe("user://maps".path_join(LAYOUT_MAP))

	var deep := DROP_SOURCE.path_join("deep")
	_pack_as(deep.path_join("a/b/convert"), LAYOUT_MAP)
	said = await client.import_dropped(PackedStringArray([ProjectSettings.globalize_path(deep) + "/"]))
	_check(said.begins_with("Added " + title), "a pack three folders down is found", said)
	_check(DotMapLocalMaps.prefix_in("user://maps".path_join(LAYOUT_MAP).path_join("convert")) != "",
		"and copied as user://maps/<map>/convert")
	_wipe("user://maps".path_join(LAYOUT_MAP))

	# A download converted with --orig-textures: the <map>_orig pack beside the free one is the one taken, and what it lacks is said.
	var orig_tree := DROP_SOURCE.path_join("orig/convert")
	var orig_name := LAYOUT_MAP + "_orig"
	var licence := {"licence": {"models": [{"count": 3}]}}
	_pack_as(orig_tree, LAYOUT_MAP, licence)
	_pack_as(orig_tree.path_join(orig_name), orig_name, licence.merged({"original_textures":
		{"from_base": 1, "from_pak": 0, "missing": ["tfcustoms/color_grey", "brick/brickwall003"]}}))
	said = await client.import_dropped(PackedStringArray([ProjectSettings.globalize_path(orig_tree.get_base_dir())]))
	_check(client._menu_catalogue.has(StringName(orig_name + DotMapLocalMaps.ID_SUFFIX)),
		"a download with a <map>_orig pack imports that one", said)
	_check(DotMapLocalMaps.prefix_in("user://maps".path_join(orig_name)) != "", "copied as user://maps/<map>_orig")
	_check(said.contains("2 of 3 original textures missing") and said.contains("tfcustoms/color_grey, brick/brickwall003"),
		"and says which original textures it lacks", said)
	_check(said.contains("3 props are stand-in models"), "and that its props are stand-ins", said)
	_wipe("user://maps".path_join(orig_name))
	_wipe(orig_tree.path_join(orig_name))
	said = await client.import_dropped(PackedStringArray([ProjectSettings.globalize_path(orig_tree)]))
	_check(said.contains("uses free stand-in textures: the drop has no %s folder" % orig_name),
		"a free pack alone says it has none of the map's own textures", said)
	_wipe("user://maps".path_join(LAYOUT_MAP))

	var empty := DROP_SOURCE.path_join("empty/a")
	DirAccess.make_dir_recursive_absolute(empty)
	said = await client.import_dropped(PackedStringArray([ProjectSettings.globalize_path(empty.get_base_dir())]))
	_check(said.begins_with("Could not import empty: "), "a folder with no map in it is said with its reason", said)

	var shipped := StringName()
	for def: DotMapDef in client._menu_catalogue.maps:
		if not bool(def.meta.get("local", false)) and def.enabled \
				and not DirAccess.dir_exists_absolute("user://maps".path_join(String(def.id))):
			shipped = def.id
			break
	if _check(shipped != &"", "the catalogue has a shipped map"):
		_pack_as(DROP_SOURCE.path_join("same/convert"), String(shipped))
		said = await client.import_dropped(PackedStringArray([ProjectSettings.globalize_path(DROP_SOURCE.path_join("same/convert"))]))
		var local_id := StringName(String(shipped) + DotMapLocalMaps.ID_SUFFIX)
		_check(client._menu_catalogue.has(shipped) and client._menu_catalogue.has(local_id),
			"a map named like a shipped one is listed beside it", said)
		var label := ""
		for row: Dictionary in ArenaMaps.menu_rows(client._menu_catalogue, &"", null, []):
			if row["id"] == "map:%s" % local_id:
				label = str(row["name"])
		_check(label.ends_with(DotMapLocalMaps.TAG), "its M row says (local)", label)
		# The solo server's M rows (ArenaVoteSource): a local map whatever is played, nothing the mode cannot host.
		var source: Object = ArenaVoteSource.of(client._menu_catalogue, null, null)
		var listed := PackedStringArray()
		for choice: DotVoteChoice in source.call(&"choices"):
			listed.append(String(choice.id))
		_check(listed.has("map:%s" % local_id), "the solo server's M lists the local map in any mode", str(listed.size()))
		_check(not listed.has("map:%s" % shipped), "and not a map the mode cannot host")
		_wipe("user://maps".path_join(String(shipped)))

	ArenaMaps.list_local = false
	said = await client.import_dropped(PackedStringArray(["C:\\Users\\x\\Downloads\\%s\\convert" % LAYOUT_MAP]))
	_check(said.begins_with("convert: dropped maps play in solo only"), "a server's client says drops are solo only", said)
	ArenaMaps.list_local = true
	local_maps.set(&"zip_cache", player_cache)
	client.free()


## The fixture as map [param map_name] in [param dir]: `<name>.json` naming `<name>.bin`.
## The fixture pack as [param map_name] in [param dir], with [param extra] keys added to its json.
func _pack_as(dir: String, map_name: String, extra: Dictionary = {}) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var json := FileAccess.get_file_as_string(FIXTURE_DIR.path_join("fixture.json")).replace("\"fixture.bin\"", "\"%s.bin\"" % map_name)
	if not extra.is_empty():
		var data: Dictionary = JSON.parse_string(json)
		data.merge(extra, true)
		json = JSON.stringify(data)
	var f := FileAccess.open(dir.path_join(map_name + ".json"), FileAccess.WRITE)
	f.store_string(json)
	f.close()
	var _copied := DirAccess.copy_absolute(FIXTURE_DIR.path_join("fixture.bin"), dir.path_join(map_name + ".bin"))


func _touch(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("x")
	f.close()


## `DotMapLocalMaps.accept_dropped` (API 24), called so the suite still parses on an older host.
## The user folder is game-fatal-contact, and the first run copies the old game-arena folder's maps and settings in.
func _test_user_dir() -> void:
	_check(ArenaUserDir.is_ours(), "project.godot names the user folder %s" % ArenaUserDir.DIR_NAME,
		str(ProjectSettings.get_setting("application/config/custom_user_dir_name", "")))
	_check(OS.get_user_data_dir().get_file() == ArenaUserDir.DIR_NAME, "user:// is the game-fatal-contact folder",
		OS.get_user_data_dir())
	_check(ArenaUserDir.old_dir().ends_with("app_userdata/game-arena"), "the old folder is Godot's app_userdata/game-arena",
		ArenaUserDir.old_dir())
	_write(OLD_USER.path_join("settings/video.cfg"), "old")
	_write(OLD_USER.path_join("maps/gm_fork/convert/manifest.json"), "{}")
	_write(OLD_USER.path_join("maps/kept.json"), "old")
	_write(OLD_USER.path_join(".hidden"), "old")
	_write(OLD_USER.path_join("shader_cache/x.bin"), "cache")
	_write(NEW_USER.path_join("maps/kept.json"), "new")
	var copied := ArenaUserDir.copy_tree(ProjectSettings.globalize_path(OLD_USER), ProjectSettings.globalize_path(NEW_USER))
	_check(copied == 3, "three files are copied (settings, a map, a hidden file)", str(copied))
	_check(FileAccess.get_file_as_string(NEW_USER.path_join("settings/video.cfg")) == "old", "settings are copied")
	_check(FileAccess.file_exists(NEW_USER.path_join("maps/gm_fork/convert/manifest.json")), "a local map is copied")
	_check(FileAccess.get_file_as_string(NEW_USER.path_join("maps/kept.json")) == "new", "a file already there is kept")
	_check(not DirAccess.dir_exists_absolute(NEW_USER.path_join("shader_cache")), "the shader cache is not copied")
	_check(FileAccess.file_exists(OLD_USER.path_join("maps/kept.json")), "the old folder is left as it was")


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)


func _drop(path: String) -> Dictionary:
	var local_maps: Object = DotMapLocalMaps
	return local_maps.call(&"accept_dropped", PackedStringArray([ProjectSettings.globalize_path(path)]))


func _test_original() -> void:
	print("-- <map>_orig draws with its own textures, locally only")
	_check(ArenaLocalMaps.is_original(&"gm_fork_orig_local"), "a local _orig pack is original")
	_check(not ArenaLocalMaps.is_original(&"gm_fork_local"), "a plain local map is not")
	_check(not ArenaLocalMaps.is_original(&"gm_fork_orig"), "a shipped or delivered id never is")
	var got := DotMapBspMesh.load_prefix(FIXTURE_DIR.path_join("fixture"))
	if not _check(got.ok, "the fixture mesh reads"):
		return
	for pair in [["gm_fork_orig_local", true], ["fixture_local", false], ["surf_x_orig", false]]:
		var drawn := Node3D.new()
		var plan := ArenaBspMap._draw_plan(drawn, pair[0], got)
		_check(not plan.is_empty() and bool(plan.options.get("original_textures", false)) == pair[1],
			"%s draws original textures: %s" % [pair[0], pair[1]])
		drawn.free()


func _test_source_install() -> void:
	print("-- an _orig pack's missing stock textures come from the player's own install, locally only")
	_check(ArenaVpk.crc32("123456789".to_ascii_buffer()) == 0xCBF43926, "VPK CRC-32 is zlib's",
		"%x" % ArenaVpk.crc32("123456789".to_ascii_buffer()))
	_check(ArenaVtf.safe_name("maps/cp_x/Concrete/Floor001_12_-3_40") == "concrete_floor001", "a cubemap-patched name is its base",
		ArenaVtf.safe_name("maps/cp_x/Concrete/Floor001_12_-3_40"))
	var keys := ArenaVtf.vmt_keys("\"LightmappedGeneric\"\n{\n\t\"$baseTexture\" \"Concrete/Floor\" // a comment\n\t$surfaceprop concrete\n}")
	_check(keys.get("$basetexture") == "Concrete/Floor" and keys.get("$surfaceprop") == "concrete", "a VMT's keys are read", str(keys))
	_check(Array(ArenaSourceInstall.library_folders("\"libraryfolders\"\n{\n\t\"1\"\n\t{\n\t\t\"path\"\t\t\"D:\\\\SteamLibrary\"\n\t}\n}")) \
		== ["D:/SteamLibrary"], "a Steam libraryfolders.vdf's libraries are read",
		str(ArenaSourceInstall.library_folders("\"path\"\t\t\"D:\\\\SteamLibrary\"")))

	# The fixture install: tf/tf2_textures_dir.vpk (VPK v2) and its part _000. A VMT stored in the dir names an RGBA8888
	# VTF in the part (green, its smaller mips blue); a patch VMT includes a base naming a DXT1 VTF (red) partly preloaded.
	var green := _vtf_rgba(4, 4, 3, Color8(20, 200, 30), Color8(0, 0, 255))
	var red := _vtf_dxt1(8, 8, 0xF800)
	var tf := SOURCE_GAME.path_join("tf")
	_write_vpk(tf.path_join("tf2_textures"), {
		"materials/concrete/concretefloor001.vmt": [("\"LightmappedGeneric\"\n{\n\t\"$basetexture\" \"Concrete/ConcreteFloor001\"\n}"
			).to_utf8_buffer(), -1, 0],
		"materials/concrete/concretefloor001.vtf": [green, 0, 0],
		"materials/metal/metalwall001.vmt": [("\"patch\"\n{\n\tinclude \"materials\\metal\\metalwall_base.vmt\"\n\tinsert\n\t{\n\t}\n}"
			).to_utf8_buffer(), -1, 0],
		"materials/metal/metalwall_base.vmt": ["\"VertexLitGeneric\" { \"$basetexture\" \"metal/metalwall_red\" }".to_utf8_buffer(), 0, 10],
		"materials/metal/metalwall_red.vtf": [red, 0, 40],
	})
	DirAccess.make_dir_recursive_absolute(SOURCE_GAME.path_join("bin"))
	var install := ProjectSettings.globalize_path(SOURCE_GAME)
	_check(Array(ArenaSourceInstall.archives(install)) == [install.path_join("tf/tf2_textures_dir.vpk")], "the install's archives are found",
		str(ArenaSourceInstall.archives(install)))
	_check(ArenaSourceInstall.archives(install.path_join("tf")) == ArenaSourceInstall.archives(install), "also from its tf folder")
	_check(ArenaSourceInstall.archives(install.get_base_dir()) == ArenaSourceInstall.archives(install),
		"and from the folder above it (a server's tf2/ + hl2/)", str(ArenaSourceInstall.archives(install.get_base_dir())))
	_check(ArenaSourceInstall.find_install(install + "/") == install, "a set path wins, its trailing / dropped")
	var vpk := ArenaVpk.new()
	if not _check(vpk.open(install.path_join("tf/tf2_textures_dir.vpk")), "the fixture VPK opens", vpk.error):
		return
	_check(vpk.entries.size() == 5 and vpk.has("Materials/Metal/MetalWall001.vmt"), "and lists its 5 files", str(vpk.entries.keys()))
	_check(vpk.read("materials/metal/metalwall_red.vtf") == red, "a preloaded file reads whole from its part")
	var img := ArenaVtf.image(vpk.read("materials/concrete/concretefloor001.vtf"))
	_check(img != null and img.get_size() == Vector2i(4, 4) and img.get_pixel(3, 3).to_rgba32() == Color8(20, 200, 30).to_rgba32(),
		"an RGBA8888 VTF decodes its largest mip", ArenaVtf.error if img == null else str(img.get_pixel(3, 3)))
	img = ArenaVtf.image(green, 2)
	_check(img != null and img.get_size() == Vector2i(2, 2) and img.get_pixel(0, 0).to_rgba32() == Color8(0, 0, 255).to_rgba32(),
		"and a smaller mip when it is too big", ArenaVtf.error if img == null else str(img.get_size()))
	img = ArenaVtf.image(red)
	_check(img != null and img.get_size() == Vector2i(8, 8) and img.get_pixel(5, 6).r > 0.95 and img.get_pixel(5, 6).g < 0.05,
		"a DXT1 VTF decodes", ArenaVtf.error if img == null else str(img.get_pixel(5, 6)))
	var bad := ArenaVpk.new()
	_write_vpk(SOURCE_GAME.path_join("broken/bad"), {"materials/x.vtf": [red, 0, 0]}, true)
	_check(bad.open(SOURCE_GAME.path_join("broken/bad_dir.vpk")) and bad.read("materials/x.vtf").is_empty()
		and bad.error.begins_with("crc mismatch"), "a file that fails its CRC is not read", bad.error)
	DirAccess.remove_absolute(SOURCE_GAME.path_join("broken/bad_dir.vpk"))
	DirAccess.remove_absolute(SOURCE_GAME.path_join("broken/bad_000.vpk"))
	DirAccess.remove_absolute(SOURCE_GAME.path_join("broken"))

	# Dropped with the install set: two of three filled, the third still a stand-in, and the drop says so.
	ArenaMaps.list_local = true
	var local_maps: Object = DotMapLocalMaps
	var player_cache: Variant = local_maps.get(&"zip_cache")
	local_maps.set(&"zip_cache", ZIP_CACHE)
	var client := ArenaClient.new()
	client._menu_catalogue = ArenaMaps.catalogue()
	client.source_game_path = install
	var orig_name := LAYOUT_MAP + "_orig"
	var tree := DROP_SOURCE.path_join("orig/convert")
	_pack_as(tree.path_join(orig_name), orig_name, {"licence": {"models": []}, "original_textures":
		{"from_base": 1, "from_pak": 0, "textures": 1, "missing": ["concrete/concretefloor001", "metal/metalwall001", "dev/nothere"]}})
	var said: String = await client.import_dropped(PackedStringArray([ProjectSettings.globalize_path(tree)]))
	var prefix := DotMapLocalMaps.prefix_in("user://maps".path_join(orig_name))
	_check(said.contains("1 of 4 original textures missing") and said.contains("using free stand-ins: dev/nothere."),
		"the drop says what is still a stand-in", said)
	_check(said.contains("2 filled from your game install (%s): concrete/concretefloor001, metal/metalwall001." % install),
		"and what its game install filled", said)
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(prefix + ".json"))
	var orig: Dictionary = (data as Dictionary).get("original_textures", {}) if data is Dictionary else {}
	_check(orig.get("missing") == ["dev/nothere"] and orig.get("filled") == ["concrete/concretefloor001", "metal/metalwall001"]
		and int(orig.get("textures", 0)) == 3, "the pack's json lists them", str(orig))
	var pack_dir := prefix.get_base_dir()
	var floor_png := Image.load_from_file(pack_dir.path_join("textures/orig/concrete_concretefloor001.png"))
	_check(floor_png != null and floor_png.get_pixel(0, 0).to_rgba32() == Color8(20, 200, 30).to_rgba32(),
		"the texture is in the pack's textures/orig", pack_dir)
	_check(FileAccess.file_exists(pack_dir.path_join("textures/orig/metal_metalwall001.png")), "the included one too")
	var drawn_as := {}
	var surfaces: Array = (data as Dictionary).get("surfaces", []) if data is Dictionary else []
	for s: Variant in surfaces:
		drawn_as[str((s as Dictionary).get("material"))] = str((s as Dictionary).get("orig", ""))
	_check(drawn_as.get("metal/metalwall001") == "textures/orig/metal_metalwall001.png", "and its surfaces draw it", str(drawn_as))
	var cache := ArenaSourceInstall.cache_dir(install)
	_check(cache.begins_with("user://") and FileAccess.file_exists(cache.path_join("concrete_concretefloor001.png")),
		"decoded textures are cached in the user folder", cache)

	# Never into the project: a res:// pack is refused, and the project holds no Valve file and no textures/orig.
	var refused := ArenaSourceInstall.fill("res://addons/maps/x/x_orig", install)
	_check(not refused["ok"] and str(refused["error"]).begins_with("refused"), "a pack outside the user folder is refused",
		str(refused["error"]))
	var found := PackedStringArray()
	_valve_files("res://", found)
	_check(found.is_empty(), "the project holds no .vpk, .vtf, .vmt, .mdl or textures/orig", ", ".join(found))
	var ignored := FileAccess.get_file_as_string("res://.gitignore").split("\n")
	var unlisted := PackedStringArray()
	for line in ["*.vpk", "*.vtf", "*.vmt", "*.mdl", "textures/orig/"]:
		if not ignored.has(line):
			unlisted.append(line)
	_check(unlisted.is_empty(), "and .gitignore keeps them out", ", ".join(unlisted))

	_wipe("user://maps".path_join(orig_name))
	_wipe(cache)
	ArenaMaps.list_local = false
	local_maps.set(&"zip_cache", player_cache)
	client.free()


## Valve's file kinds and `textures/orig` folders under [param dir], into [param found]. Skips what is not this
## repository's: `.godot`, the linked addons and map repositories (.gitignore), and the suite's own leftovers.
func _valve_files(dir: String, found: PackedStringArray) -> void:
	for skip in ["res://.godot", "res://addons", "res://maps/imported", "res://maps/imported_dm", "res://worlds",
			"res://worlds_dm", "res://dot_cloud", "res://build", "res://lightbake_work", "res://android"]:
		if dir == skip:
			return
	if dir.ends_with("textures/orig"):
		found.append(dir)
	for f in DirAccess.get_files_at(dir):
		if f.get_extension().to_lower() in ["vpk", "vtf", "vmt", "mdl"]:
			found.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_valve_files(dir.path_join(d), found)


## A VPK v2 at [param base]`_dir.vpk` (and `_000.vpk`) holding [param files]: path -> [bytes, part (-1 in the dir),
## bytes preloaded in the tree]; each CRC is off by one when [param bad_crc].
func _write_vpk(base: String, files: Dictionary, bad_crc := false) -> void:
	var by_ext := {}
	for path: String in files:
		var folders: Dictionary = by_ext.get_or_add(path.get_extension(), {})
		(folders.get_or_add(path.get_base_dir(), []) as Array).append(path)
	var tree := PackedByteArray()
	var in_dir := PackedByteArray()
	var part := PackedByteArray()
	for ext: String in by_ext:
		tree.append_array(_cstr(ext))
		for folder: String in by_ext[ext]:
			tree.append_array(_cstr(folder))
			for path: String in by_ext[ext][folder]:
				var bytes: PackedByteArray = files[path][0]
				var preloaded: int = files[path][2]
				var body := bytes.slice(preloaded)
				var stored := in_dir if int(files[path][1]) < 0 else part
				var e := PackedByteArray()
				e.resize(18)
				e.encode_u32(0, ArenaVpk.crc32(bytes) ^ (1 if bad_crc else 0))
				e.encode_u16(4, preloaded)
				e.encode_u16(6, ArenaVpk.IN_DIR if int(files[path][1]) < 0 else 0)
				e.encode_u32(8, stored.size())
				e.encode_u32(12, body.size())
				e.encode_u16(16, 0xFFFF)
				tree.append_array(_cstr(path.get_file().get_basename()))
				tree.append_array(e)
				tree.append_array(bytes.slice(0, preloaded))
				if int(files[path][1]) < 0:
					in_dir.append_array(body)
				else:
					part.append_array(body)
			tree.append(0)
		tree.append(0)
	tree.append(0)
	var head := PackedByteArray()
	head.resize(28)
	head.encode_u32(0, ArenaVpk.SIG)
	head.encode_u32(4, 2)
	head.encode_u32(8, tree.size())
	head.encode_u32(12, in_dir.size())
	DirAccess.make_dir_recursive_absolute(base.get_base_dir())
	var f := FileAccess.open(base + "_dir.vpk", FileAccess.WRITE)
	f.store_buffer(head + tree + in_dir)
	f.close()
	f = FileAccess.open(base + "_000.vpk", FileAccess.WRITE)
	f.store_buffer(part)
	f.close()


func _cstr(s: String) -> PackedByteArray:
	var out := s.to_utf8_buffer()
	out.append(0)
	return out


## A VTF 7.2 header (80 bytes, no thumbnail) for a [param w] x [param h] image of [param mips] in [param format].
func _vtf_head(w: int, h: int, format: int, mips: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(80)
	out.encode_u32(0, 0x00465456)  # "VTF\0"
	out.encode_u32(4, 7)
	out.encode_u32(8, 2)
	out.encode_u32(12, 80)
	out.encode_u16(16, w)
	out.encode_u16(18, h)
	out.encode_u16(24, 1)
	out.encode_float(48, 1.0)
	out.encode_s32(52, format)
	out[56] = mips
	out.encode_s32(57, -1)
	out.encode_u16(63, 1)
	return out


## An RGBA8888 VTF: its largest mip [param top], the smaller ones [param rest] (stored smallest first).
func _vtf_rgba(w: int, h: int, mips: int, top: Color, rest: Color) -> PackedByteArray:
	var out := _vtf_head(w, h, 0, mips)
	for m in range(mips - 1, -1, -1):
		var c := top if m == 0 else rest
		for _i in maxi(1, w >> m) * maxi(1, h >> m):
			out.append_array(PackedByteArray([c.r8, c.g8, c.b8, c.a8]))
	return out


## A one-mip DXT1 VTF, every block colour0 [param rgb565].
func _vtf_dxt1(w: int, h: int, rgb565: int) -> PackedByteArray:
	var out := _vtf_head(w, h, 13, 1)
	for _b in (w / 4) * (h / 4):
		var block := PackedByteArray()
		block.resize(8)
		block.encode_u16(0, rgb565)
		out.append_array(block)
	return out


func _zip_fixture(zip_path: String) -> bool:
	DirAccess.make_dir_recursive_absolute(zip_path.get_base_dir())
	var zip := ZIPPacker.new()
	if zip.open(zip_path) != OK:
		return false
	for n in ["fixture.json", "fixture.bin"]:
		zip.start_file("convert/" + n)
		zip.write_file(FileAccess.get_file_as_bytes(FIXTURE_DIR.path_join(n)))
		zip.close_file()
	return zip.close() == OK


func _clean() -> void:
	_wipe(RES_FOLDER)
	_wipe(USER_FOLDER)
	_wipe(DROP_SOURCE)
	_wipe(DROPPED_FOLDER)
	_wipe("user://maps".path_join(LAYOUT_MAP))
	if DotMapLocalMaps.prefix_in("user://maps/convert").get_file() == LAYOUT_MAP:
		_wipe("user://maps/convert")
	_wipe(ZIP_CACHE)
	_wipe(SOURCE_STEAM)
	_wipe(ArenaSourceInstall.cache_dir(ProjectSettings.globalize_path(SOURCE_GAME)))
	_wipe("user://maps".path_join(LAYOUT_MAP + "_orig"))
	_wipe(OLD_USER)
	_wipe(NEW_USER)
	DirAccess.remove_absolute(DROPPED_ZIP)
	for parent in ["res://addons/maps"]:
		if DirAccess.dir_exists_absolute(parent) and DirAccess.get_directories_at(parent).is_empty() \
				and DirAccess.get_files_at(parent).is_empty():
			DirAccess.remove_absolute(parent)


func _copy_tree(from_dir: String, to_dir: String, only: Array = []) -> int:
	DirAccess.make_dir_recursive_absolute(to_dir)
	var count := 0
	for n in DirAccess.get_files_at(from_dir):
		if (only.is_empty() or only.has(n)) and DirAccess.copy_absolute(from_dir.path_join(n), to_dir.path_join(n)) == OK:
			count += 1
	if only.is_empty():
		for d in DirAccess.get_directories_at(from_dir):
			count += _copy_tree(from_dir.path_join(d), to_dir.path_join(d))
	return count


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	var d := DirAccess.open(dir)
	d.include_hidden = true
	for sub in d.get_directories():
		_wipe(dir.path_join(sub))
	for n in d.get_files():
		DirAccess.remove_absolute(dir.path_join(n))
	DirAccess.remove_absolute(dir)
