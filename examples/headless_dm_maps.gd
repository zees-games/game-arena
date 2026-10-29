extends DotGameCheckSuite

const ArenaMap := preload("../maps/arena_map.gd")
const ArenaImportedMaps := preload("../maps/arena_imported_maps.gd")

## The deathmatch and gun game maps (arena-dm-maps, linked at maps/imported_dm): each in maps.json
## is discovered, answers to ArenaMap.by_id with its author's credit and spawns, and is walked,
## not surfed. Skips (exit 0, says so) without the link, a supported state.
##
## [codeblock]
## godot --headless --path . res://examples/headless_dm_maps.tscn
## [/codeblock]


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("arena — the deathmatch and gun game maps")
	var root := ProjectSettings.globalize_path("res://maps/imported_dm")
	var resolved := _resolve(root)
	var json_path := resolved.get_base_dir().path_join("maps.json")

	if resolved.is_empty() or not FileAccess.file_exists(json_path):
		print("no maps/imported_dm link — nothing to check (link arena-dm-maps)")
		get_tree().quit(0)
		return

	var listed: Array = JSON.parse_string(FileAccess.get_file_as_string(json_path)).get("maps", [])
	var found := 0
	var entered := 1
	print("-- every listed map loads, credited and walked")

	for entry: Dictionary in listed:
		var id := StringName(str(entry.id))

		if not ArenaImportedMaps.has(id):
			# Not converted on this machine: reported, not failed (content is delivered, not in git).
			print("  absent here: %s" % id)
			continue

		found += 1
		var map := ArenaMap.by_id(id)
		_check(map != null and map.is_imported() and map.author == str(entry.author),
			"%s is catalogued and credited to %s" % [id, entry.author])
		_check(map != null and map.spawns.size() > 0, "%s has spawns" % id)
		_check(map != null and map.movement_profile == &"", "%s is walked, not surfed" % id)

	_check(found > 0, "at least one listed map is present (%d of %d)" % [found, listed.size()])
	_report_sections(entered, entered, 1, 1 + 3 * found)


func _resolve(link: String) -> String:
	var out: Array = []

	if OS.execute("readlink", ["-f", link], out) != 0 or out.is_empty():
		return ""

	return str(out[0]).strip_edges()
