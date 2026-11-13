extends DotGameCheckSuite

const ArenaMap := preload("../maps/arena_map.gd")
const ArenaBspMap := preload("../maps/arena_bsp_map.gd")
const ArenaLocalMaps := preload("../maps/arena_local_maps.gd")
const ArenaMaps := preload("../game/arena_maps.gd")

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
	if not _source.is_empty():
		var name := DotMapLocalMaps.prefix_in(_source).get_file()
		if not _check(not name.is_empty(), "the source holds a converted map", _source):
			_report_sections(sections, sections, 3)
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
	_report_sections(sections, sections, 3 if _source.is_empty() else 5)


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


func _clean() -> void:
	_wipe(RES_FOLDER)
	_wipe(USER_FOLDER)
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
