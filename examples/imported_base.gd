extends DotGameCheckSuite
## Shared state and the server-named section of headless_imported, split out for the file size gate.

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMaps := preload("../game/arena_maps.gd")
const ArenaImportedMaps := preload("../maps/arena_imported_maps.gd")
const ArenaMapDirector := preload("../game/arena_map_director.gd")

## The map the deathmatch is played on: the first of Christian's two.
const MAP := &"surf_10x_reloaded_fixed"

## The fake pack [method _test_server_named] mounts: an id no root has, under an owner no
## origin has, so nothing real is shadowed and nothing is fetched.
const DELIVERED_OWNER := "dot-test"
const DELIVERED_ID := &"dot_test_delivered_surf"
const DELIVERED_NOT_ARENA := &"dot_test_delivered_course"
const DELIVERED_VERSION := "1.0.0"

var _entered := 0
var _completed := 0

var _game: ArenaGame = null

func _ticks(count: int) -> void:
	for i in range(count):
		_game.tick({})

		if i % 16 == 0:
			await get_tree().physics_frame


func _section(title: String) -> void:
	_entered += 1
	_line("")
	_line("-- %s" % title)


func _done() -> void:
	_completed += 1


func _line(text: String) -> void:
	print(text)


# --- Named by the server ----------------------------------------------------------

## Stands in for a dot-server: `games.current_maps()` is all the director reads.
class StandInServer:
	extends RefCounted
	var games := StandInGames.new()


class StandInGames:
	extends RefCounted
	var maps := PackedStringArray()

	func current_maps() -> PackedStringArray:
		return maps


## The pack layout dot-cloud mounts: `<id>.json` and `<id>.bin` in the version directory. MAP's
## files under a new id, and a second manifest that says it is a timer course; no lightmap.
func _deliver_packs(mount: String, other: String) -> void:
	var source := ArenaImportedMaps.manifest_path(MAP)
	var text := FileAccess.get_file_as_string(source)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(mount))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(other))
	_write(mount.path_join("%s.json" % DELIVERED_ID),
		text.replace("\"id\": \"%s\"" % MAP, "\"id\": \"%s\"" % DELIVERED_ID))
	DirAccess.copy_absolute(source.get_basename() + ".bin", mount.path_join("%s.bin" % DELIVERED_ID))
	_write(other.path_join("%s.json" % DELIVERED_NOT_ARENA),
		text.replace("\"id\": \"%s\"" % MAP, "\"id\": \"%s\"" % DELIVERED_NOT_ARENA)
			.replace("\"kind\": \"arena\"", "\"kind\": \"course\""))


func _test_server_named() -> void:
	_section("a map only the server names is catalogued, built from its pack, and dropped")

	var key := "%s/%s@%s" % [DELIVERED_OWNER, DELIVERED_ID, DELIVERED_VERSION]
	var not_arena_key := "%s/%s@%s" % [DELIVERED_OWNER, DELIVERED_NOT_ARENA, DELIVERED_VERSION]
	var mount := "res://dot_cloud/%s/%s/%s" % [DELIVERED_OWNER, DELIVERED_ID, DELIVERED_VERSION]
	var other := "res://dot_cloud/%s/%s/%s" % [DELIVERED_OWNER, DELIVERED_NOT_ARENA, DELIVERED_VERSION]

	_deliver_packs(mount, other)

	var server := StandInServer.new()
	server.games.maps = PackedStringArray([key, not_arena_key])

	var director := ArenaMapDirector.new()
	director.game = _game
	director.server = server
	add_child(director)
	var ready := director.setup()
	var catalogue := director.session.catalogue if ready.ok else null
	var def := catalogue.get_map(DELIVERED_ID) if catalogue != null else null

	_check(def != null and not def.is_local() and String(def.content_id) == "%s/%s" % [DELIVERED_OWNER, DELIVERED_ID]
		and def.version == DELIVERED_VERSION,
		"it is in the catalogue as delivered content, at its pack version (%s)" % (
			"%s %s" % [def.content_id, def.version] if def != null else "absent"))
	_check(def != null and not ArenaImportedMaps.is_mounted(DELIVERED_ID)
		and not ArenaMap.imported_ids().has(DELIVERED_ID),
		"and is not read or registered at boot, nor listed as a local import")
	_check(catalogue != null and not catalogue.has(DELIVERED_NOT_ARENA),
		"a named pack whose manifest is not kind arena is skipped")

	# What a client that has never heard of it makes of the announce: dot-map takes an unknown
	# map only when it is delivered and its scene is inside its own mount, and the scene here
	# is the manifest in the pack. No session, so nothing the client knows can answer first.
	var client := DotMapSyncClient.new()
	var accepted: DotResult = client._accept(DotMapMessage.announce(def)["map"]) if def != null \
		else DotResult.fail(DotError.CODE_STATE, "no def")
	client.free()
	_check(accepted.ok and ArenaMaps.is_delivered(accepted.value),
		"a client that has never heard of it accepts the announce as delivered content%s" % (
			"" if accepted.ok else ": " + accepted.error.message))

	var changed: DotResult = await director.change_to(DELIVERED_ID)
	await get_tree().physics_frame
	_check(changed.ok, "the change to it succeeds%s" % ("" if changed.ok else ": " + changed.error.message))
	_check(_game.map != null and _game.map.id == DELIVERED_ID and _game.map.is_imported()
		and _game.map.manifest_path.begins_with(mount + "/"),
		"the game is on it, built from the mounted manifest (%s)" % (
			_game.map.manifest_path if _game.map != null else "no map"))
	var solid := _game.map.collision_root if _game.map != null else null
	_check(solid != null and solid.is_inside_tree() and solid.get_child_count() > 100,
		"with its brushes in the tree (%d shapes)" % (solid.get_child_count() if solid != null else -1))
	_check(_game.map != null and _game.map.movement_profile == &"surf" and _game.map.spawns.size() > 0,
		"on the surf profile, with the mapper's spawns (%d)" % (_game.map.spawns.size() if _game.map != null else 0))

	# Back to a built-in, then the owner drops it from the list.
	var _back: DotResult = await director.change_to(&"dm_box")
	server.games.maps = PackedStringArray()
	var adopted := director.adopt_server_maps()
	_check(not catalogue.has(DELIVERED_ID) and int(adopted.get("removed", 0)) == 1
		and not ArenaImportedMaps.is_mounted(DELIVERED_ID),
		"and gone when the server stops naming it (removed %d)" % int(adopted.get("removed", 0)))

	remove_child(director)
	director.free()
	_remove_tree("res://dot_cloud/%s" % DELIVERED_OWNER)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("res://dot_cloud"))

	_done()


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)

	if f != null:
		f.store_string(text)
		f.close()


## Deletes a directory and everything under it.
func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)

	if dir == null:
		return

	for name in dir.get_files():
		DirAccess.remove_absolute(path.path_join(name))

	for name in dir.get_directories():
		_remove_tree(path.path_join(name))

	DirAccess.remove_absolute(path)
