extends DotGameCheckSuite

const ArenaMap := preload("../maps/arena_map.gd")
const ArenaBspMap := preload("../maps/arena_bsp_map.gd")
const ArenaLocalMaps := preload("../maps/arena_local_maps.gd")
const ArenaMaps := preload("../game/arena_maps.gd")
const ArenaClient := preload("../game/arena_client.gd")

## Maps copied in by hand (`ArenaLocalMaps`): a raw convert folder under `res://addons/maps/` or `user://maps/` is listed
## as `<name>_local` only while `ArenaMaps.list_local` is on (solo), and loads with spawns, a solid, movers and a drawn world.
## The fixture section runs everywhere; `-- --source=<a map's convert folder>` repeats it on a real conversion.
##
## [codeblock]
## ./game.sh test headless_local_maps
## ./game.sh test headless_local_maps -- --source=/path/to/gm_fork/convert
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

var _source := ""


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--source="):
			_source = a.trim_prefix("--source=")
	_run.call_deferred()


func _run() -> void:
	var sections := 0
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
		_test_original()
		sections += 1
	else:
		print("-- drops and _orig skipped: dot-map API %d < %d" % [DotAddonApi.build_level("dot_map"), ArenaLocalMaps.DROP_LEVEL])
	var planned := 5 if ArenaLocalMaps.can_drop() else 3
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
	_clean()
	ArenaMaps.list_local = false
	_report_sections(sections, sections, planned if _source.is_empty() else planned + 2)


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
	_check(said.begins_with("Not a map: notes.txt: "), "a bad drop is said with its reason", said)
	_check(client._menu_catalogue.size() == before, "a bad drop adds no row")
	_check(not FileAccess.file_exists("user://maps/notes.txt"), "a bad drop copies nothing")

	ArenaMaps.list_local = false
	var server_cat := ArenaMaps.catalogue()
	_check(not ArenaMaps.add_local(server_cat, &"fixture_local") and not server_cat.has(&"fixture_local"),
		"a server catalogue never takes a dropped map")
	ArenaMaps.list_local = true
	local_maps.set(&"zip_cache", player_cache)
	client.free()


## `DotMapLocalMaps.accept_dropped` (API 24), called so the suite still parses on an older host.
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
	_wipe(ZIP_CACHE)
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
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	for n in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(n))
	DirAccess.remove_absolute(dir)
