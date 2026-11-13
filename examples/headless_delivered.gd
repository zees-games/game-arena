extends DotGameCheckSuite

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMaps := preload("../game/arena_maps.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaImportedMaps := preload("../maps/arena_imported_maps.gd")
const ArenaBspMap := preload("../maps/arena_bsp_map.gd")
const ArenaMapDirector := preload("../game/arena_map_director.gd")
const ArenaContentGroups := preload("../game/arena_content_groups.gd")
const ArenaClientView := preload("../game/arena_client_view.gd")

## An arena map delivered the way a player gets it: published as a signed pack, fetched by a
## real [DotCloudClient], mounted, and built from the mount alone.
##
## [codeblock]
## godot --headless --path . res://examples/headless_delivered.tscn
## tools/render_delivered.sh        # the same, and a frame of the delivered map
## [/codeblock]
##
## [b]What this adds to `headless_imported`'s server-named section[/b], which hand-copies two
## files into a fake mount: the pack here is made by [DotCloudPublisher] from the real map
## folder (textures, lightmap and their imported outputs), the fetch is dot-cloud's own
## (verified against the suite's key), and the map is checked to read nothing from the
## `maps/imported` link. A client without the fc-surf-dm-maps link has only this path.
##
## [b]Not here[/b]: a networked announce (`headless_imported` accepts one) and the published
## packs on the site's origin, which need a tag and the owner's permission to publish.
##
## Skips, saying so, without the link, after the one section that needs none: the game pack
## leaves every map link out (`tools/publish.sh` MAP_LINKS). `-- --shot <path>` saves a frame (needs a renderer).

const MAP := &"surf_10x_reloaded_fixed"
const OWNER := "gamemann"
const VERSION := "1.0.4"
const ROOT := "user://arena_delivered_check"
## Inside the project, so the publisher finds the imported outputs the markers name; under
## `.godot`, which git ignores.
const STAGE := "res://.godot/arena_delivered_stage"
## Where the game-pack section stages its stand-in tree.
const PACK_ROOT := "user://arena_pack_maps_check"
## Where the per-map groups section publishes and mounts its stand-in pack.
const GROUPS_ROOT := "user://arena_map_groups_check"
const SECTIONS := 8
## Without a frame; two more with `--shot`.
const CHECKS := 36
## The groups section's mount checks, skipped (and not expected) on a dot-cloud before API 22.
const GROUP_MOUNT_CHECKS := 5

var _skipped := 0

var _entered := 0
var _completed := 0


## The browser shell's `dot_solo`, as far as a start map goes.
class StandInSolo:
	extends Node
	var start_map: StringName = &""


class StandInServer:
	extends RefCounted
	var games := StandInGames.new()


class StandInGames:
	extends RefCounted
	var maps := PackedStringArray()

	func current_maps() -> PackedStringArray:
		return maps


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	_line("arena — a combat surf map delivered as a signed pack")
	_test_game_pack_leaves_maps_out()
	_test_solo_start_map()
	var source_manifest := ArenaImportedMaps.manifest_path(MAP)

	if source_manifest.is_empty():
		_line("no %s under %s — nothing to publish (link arena-surf-dm-maps)" % [MAP, ArenaImportedMaps.roots()[0]])
		await _test_map_groups()
		get_tree().quit(1 if _failed > 0 else 0)
		return

	DotPaths.remove_tree(ROOT)
	DotPaths.remove_tree(STAGE)
	var keys := await _test_publish(source_manifest.get_base_dir())

	if not keys.is_empty():
		var game := await _test_fetch_and_build(keys)
		await _test_frame(game)
		await _test_leaves()
		_cleanup(game)

	_test_surf_keys()
	# Last: mounting a pack makes res:// pack-backed, so staging above must come first.
	await _test_map_groups()
	_finish()


## The site's "Play map" (`?map=`): the shell names a start map on `dot_solo`; a built-in one is
## the first map, anything else waits for the change after setup (a delivered pack's download).
func _test_solo_start_map() -> void:
	_section("a solo session's start map is the first map")
	var solo := StandInSolo.new()
	add_child(solo)
	DotRegistry.register(&"dot_solo", solo)
	solo.start_map = &"dm_pit"
	_check(ArenaClientView._startup_map().id == &"dm_pit", "a built-in start map is the first map")
	solo.start_map = &"surf_not_built_in"
	_check(ArenaClientView._solo_start_map() == "surf_not_built_in" and ArenaClientView._startup_map().id == &"dm_box",
		"a delivered one starts on dm_box, to change once set up")
	solo.start_map = &"../dm_pit"
	_check(ArenaClientView._solo_start_map() == "", "a start map that is not a map id is ignored")
	DotRegistry.unregister(&"dot_solo")
	solo.queue_free()
	_done()


## The game's own pack carries no maps: they are their own packs (docs/imported-maps.md), and
## the links to them were 547 of its 583 MiB until tools/publish.sh named them. Every
## `# bootstrap-link:` path in .gitignore must be in publish.sh's MAP_LINKS, and the publisher,
## given those as `--exclude-dir`, must drop a stand-in map tree and keep the game beside it.
func _test_game_pack_leaves_maps_out() -> void:
	_section("the game pack leaves every map link out (tools/publish.sh MAP_LINKS)")
	var links := _gitignore_links(FileAccess.get_file_as_string("res://.gitignore"))
	_check(links.size() >= 4, "the .gitignore names the map links (%s)" % ", ".join(links))
	var script := FileAccess.get_file_as_string("res://tools/publish.sh")
	var listed := PackedStringArray()
	var passed := false

	for line in script.split("\n"):
		if line.begins_with("MAP_LINKS=(") and line.ends_with(")"):
			listed = line.trim_prefix("MAP_LINKS=(").trim_suffix(")").split(" ", false)
		elif line.begins_with("X=(); for d in ") and line.contains("\"${MAP_LINKS[@]}\""):
			passed = true

	var missing := PackedStringArray()

	for link in links:
		if not listed.has(link):
			missing.append(link)

	_check(missing.is_empty(), "every link is in MAP_LINKS (missing: %s)" % ", ".join(missing))
	_check(passed, "publish.sh hands MAP_LINKS to the publisher as --exclude-dir")
	DotPaths.remove_tree(PACK_ROOT)
	var kept := PackedStringArray(["game/arena_game.gd", "maps/arena_map.gd", "maps/surf/x.surf.json"])
	var files := kept.duplicate()

	for link in listed:
		files.append(link.path_join("m").path_join("m.json"))

	for rel in files:
		DotPaths.ensure_parent_dir(PACK_ROOT.path_join(rel))
		DotPaths.write_text(PACK_ROOT.path_join(rel), "{}")

	var publisher := DotCloudPublisher.new()
	publisher.exclude_dirs.append_array(listed)
	var got := publisher._collect(PACK_ROOT)
	got.sort()
	kept.sort()
	_check(got == kept, "the publisher keeps the game and drops the maps (%s)" % ", ".join(got))
	DotPaths.remove_tree(PACK_ROOT)
	_done()


## Each map's own files (its bake, its bot rides) are the download group `map-<id>` (groups.json), so a
## client fetches only the map it plays: a stand-in pack of those paths is published with the real
## groups.json, mounted with one map's group, and topped up with another's as a map change does.
func _test_map_groups() -> void:
	_section("each map's own files are a download group (groups.json)")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://groups.json"))
	var groups: Dictionary = parsed if parsed is Dictionary else {}
	var files := PackedStringArray()
	for dir in ["lightmaps", "maps/surf"]:
		for rel in DotPaths.list_files_recursive("res://" + dir):
			if rel.ends_with(".res") or rel.ends_with(".surf.json"):
				files.append(dir.path_join(rel))
	var loose := PackedStringArray()
	for rel in files:
		var listed: Array = groups.get(ArenaContentGroups.group_for(StringName(rel.get_file().get_slice(".", 0))), [])
		if not listed.has(rel):
			loose.append(rel)
	_check(files.size() >= 8 and loose.is_empty(), "every bake and ride file is in its map's group (%d files; loose: %s)" % [files.size(), ", ".join(loose)])

	DotPaths.remove_tree(GROUPS_ROOT)
	var src := GROUPS_ROOT.path_join("src")
	for rel in files + PackedStringArray(["game/arena_game.gd"]):
		DotPaths.ensure_parent_dir(src.path_join(rel))
		DotPaths.write_text(src.path_join(rel), rel)
	DirAccess.copy_absolute(ProjectSettings.globalize_path("res://groups.json"), ProjectSettings.globalize_path(src.path_join("groups.json")))
	var pair := DotCloudSignature.generate_keypair()
	var publisher := DotCloudPublisher.new()
	publisher.content_id = "%s/arena-groups-check" % OWNER
	publisher.version = VERSION
	publisher.signing_key_pem = str(pair.value["private"]) if pair.ok else ""
	publisher.signing_key_id = "arena_groups"
	var published := publisher.publish(src, GROUPS_ROOT.path_join("dist").path_join(publisher.content_id))
	_check(published.ok, "the publisher accepts groups.json (no pattern matches nothing)%s" % ("" if published.ok else ": " + str(published.error)))

	if not published.ok or DotAddonApi.build_level("dot_cloud") < 22:
		_skipped = GROUP_MOUNT_CHECKS
		_line("dot-cloud %d has no top-up (needs 22); the mount checks are skipped" % DotAddonApi.build_level("dot_cloud"))
		DotPaths.remove_tree(GROUPS_ROOT)
		_done()
		return

	var config := DotCloudConfig.new()
	config.side = "both"
	config.cache_dir = GROUPS_ROOT.path_join("cache")
	config.require_signed_manifests = true
	config.trusted_keys = {"arena_groups": str(pair.value["public"])}
	var cloud := DotCloudClient.new()
	cloud.name = "GroupsCloud"
	cloud.config = config
	cloud.config_file = ""
	cloud.register_service = false
	cloud.local_search_dirs = PackedStringArray([GROUPS_ROOT.path_join("dist")])
	cloud.manifest_url_template = "{base}/{id}/manifest.json"
	add_child(cloud)
	var prefix := DotCloudClient.mount_prefix_for(StringName(publisher.content_id), VERSION).trim_suffix("/")
	var first: DotResult = await cloud.ensure(StringName(publisher.content_id), VERSION, ArenaContentGroups.groups_for(&"dm_box"))
	_check(first.ok and FileAccess.file_exists(prefix.path_join("game/arena_game.gd")), "a join on dm_box mounts the pack's code%s" % ("" if first.ok else ": " + str(first.error)))
	_check(FileAccess.file_exists(prefix.path_join("lightmaps/dm_box.res")), "and dm_box's bake")
	_check(not FileAccess.file_exists(prefix.path_join("lightmaps/dm_pit.res")) and not FileAccess.file_exists(prefix.path_join("maps/surf/surf_ski_2.surf.json")), "and no other map's files")
	var topped: DotResult = await cloud.call(&"ensure_groups_at", prefix.path_join("game"), ArenaContentGroups.groups_for(&"dm_pit"))
	_check(topped.ok and str(topped.value) == prefix and FileAccess.file_exists(prefix.path_join("lightmaps/dm_pit.res")), "a change to dm_pit tops up its bake%s" % ("" if topped.ok else ": " + str(topped.error)))
	_check(not FileAccess.file_exists(prefix.path_join("lightmaps/dm_atrium.res")), "and still not the maps nobody played")
	cloud.queue_free()
	await get_tree().process_frame
	DotPaths.remove_tree(GROUPS_ROOT)
	_done()


## The paths dot-bootstrap links (the pattern under each `# bootstrap-link:` line), without slashes.
static func _gitignore_links(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var armed := false

	for raw in text.split("\n"):
		var line := raw.strip_edges()

		if line.begins_with("# bootstrap-link:"):
			armed = true
		elif armed and not line.is_empty() and not line.begins_with("#"):
			out.append(line.trim_prefix("/").trim_suffix("/"))
			armed = false

	return out


## The signed pack, made from the real folder.
func _test_publish(source: String) -> Dictionary:
	_section("the map folder publishes as a signed pack")
	var pair := DotCloudSignature.generate_keypair()
	_check(pair.ok, "a signing key is made")

	if not pair.ok:
		_done()
		return {}

	var staged := _stage(source)
	_check(not staged.is_empty(), "the folder is staged without its resource uids")
	var publisher := DotCloudPublisher.new()
	publisher.content_id = "%s/%s" % [OWNER, MAP]
	publisher.version = VERSION
	publisher.signing_key_pem = str(pair.value["private"])
	publisher.signing_key_id = "arena_delivered"
	var out := ROOT.path_join("dist").path_join(publisher.content_id)
	var published := publisher.publish(staged, out)
	_check(published.ok, "it publishes%s" % ("" if published.ok else ": " + str(published.error)))
	_check(FileAccess.file_exists(out.path_join("manifest.json")), "with a manifest on the origin")
	_done()
	return pair.value if published.ok else {}


## A copy of the map folder whose `.import` markers carry no uid. This project already owns
## those uids through the maps/imported link, and a mount refuses a uid that is not its own; a
## client without the link does not, so the copy is that client's view of the same pack.
func _stage(source: String) -> String:
	var dest := STAGE.path_join(String(MAP))
	_stage_dir(source, dest)
	var world := ArenaBspMap.world_prefix(String(MAP))

	# The real pack carries worlds/<id>/ beside the map folder (tools/stage_packs.sh).
	if not world.is_empty():
		_stage_dir(world.get_base_dir(), dest.path_join("worlds").path_join(String(MAP)))

	return dest


func _stage_dir(source: String, dest: String) -> void:
	for rel in DotPaths.list_files_recursive(source):
		var from := source.path_join(rel)
		var to := dest.path_join(rel)
		DotPaths.ensure_parent_dir(to)

		if rel.ends_with(".import"):
			var kept := PackedStringArray()

			for line in FileAccess.get_file_as_string(from).split("\n"):
				if not line.begins_with("uid="):
					kept.append(line)

			DotPaths.write_text(to, "\n".join(kept))
		else:
			DirAccess.copy_absolute(from, ProjectSettings.globalize_path(to))


var _director: ArenaMapDirector = null
var _server: StandInServer = null
var _cloud: DotCloudClient = null
var _mount := ""


## The fetch and the build, through the director a server runs.
func _test_fetch_and_build(keys: Dictionary) -> ArenaGame:
	_section("a content client fetches it, and the game builds the map from the mount")

	var config := DotCloudConfig.new()
	config.side = "both"
	config.cache_dir = ROOT.path_join("cache")
	config.require_signed_manifests = true
	config.trusted_keys = {"arena_delivered": str(keys["public"])}
	_cloud = DotCloudClient.new()
	_cloud.name = "Cloud"
	_cloud.config = config
	_cloud.config_file = ""
	_cloud.local_search_dirs = PackedStringArray([ROOT.path_join("dist")])
	_cloud.manifest_url_template = "{base}/{id}/manifest.json"
	_cloud.register_service = false
	add_child(_cloud)
	DotRegistry.register(&"dot_cloud_client", _cloud)
	await get_tree().process_frame

	# A built-in first, so the first change is a change; the delivered map then replaces the
	# local import of its id (a client without the link has no other copy).
	var game := ArenaGame.new()
	game.tick_rate = 64
	game.headless = true
	game.is_authority = true
	game.register_service = false
	game.mode = ArenaMode.free_for_all(4)
	add_child(game)
	_check(game.setup(ArenaMap.by_id(&"dm_box")).ok, "the game starts on a built-in map")

	var key := "%s/%s@%s" % [OWNER, MAP, VERSION]
	var server := StandInServer.new()
	server.games.maps = PackedStringArray([key])
	var director := ArenaMapDirector.new()
	director.game = game
	director.server = server
	add_child(director)
	_check(director.setup().ok, "the director adopts the pack the server names")
	var def := director.session.catalogue.get_map(MAP)
	_check(def != null and not def.is_local(), "the catalogue lists the map as delivered content, not local")

	var changed: DotResult = await director.change_to(MAP)
	await get_tree().physics_frame
	_check(changed.ok, "the change succeeds%s" % ("" if changed.ok else ": " + changed.error.message))

	_mount = "res://dot_cloud/%s/%s/%s/" % [OWNER, MAP, VERSION]
	_check(_cloud.is_mounted(StringName("%s/%s" % [OWNER, MAP]), VERSION), "dot-cloud has the pack mounted")
	var map := game.map
	_check(map != null and map.id == MAP and map.is_imported(), "the game is on the map")
	_check(map != null and map.manifest_path.begins_with(_mount),
		"built from the manifest in the mount (%s)" % (map.manifest_path if map != null else "no map"))
	var solid := map.collision_root if map != null else null
	_check(solid != null and solid.is_inside_tree() and solid.get_child_count() > 100,
		"with its brushes in the tree (%d)" % (solid.get_child_count() if solid != null else -1))
	_check(map != null and map.movement_profile == &"surf" and map.spawns.size() > 0, "on the surf profile, with spawns")
	_done()
	_director = director
	_server = server
	return game


## Every texture, the lightmap and the mesh come from the mount; none from the link.
func _test_frame(game: ArenaGame) -> void:
	_section("everything drawn comes from the pack, and a frame renders")

	if game == null or game.map == null:
		_check(false, "there is a map to draw")
		_done()
		return

	var scene := game.map.to_scene()
	add_child(scene)
	var meshes := 0

	for node in scene.find_children("*", "MeshInstance3D", true, false):
		var mesh := (node as MeshInstance3D).mesh

		if mesh == null:
			continue

		meshes += 1

	_check(meshes > 0, "the map draws meshes (%d)" % meshes)
	var world := ArenaBspMap.world_prefix(MAP, _mount)
	_check(world.begins_with(_mount) and FileAccess.file_exists(world + ".bin"),
		"the world (textures, lightmaps, mesh) is read from the pack: %s" % world)
	_check(ArenaImportedMaps.manifest_path(MAP).begins_with(_mount),
		"the map's manifest resolves to the mount, not the maps/imported link")

	var args := OS.get_cmdline_user_args()
	var at := args.find("--shot")

	if at >= 0 and at + 1 < args.size() and DisplayServer.get_name() != "headless":
		await _shot(scene, game.map, args[at + 1])
	else:
		_line("   (no frame: needs a renderer and --shot <path>)")

	scene.queue_free()
	_done()


func _shot(scene: Node, map: ArenaMap, path: String) -> void:
	var camera := Camera3D.new()
	camera.far = 4000.0
	add_child(camera)
	camera.current = true
	var spawn: Vector3 = map.spawns[0].origin if not map.spawns.is_empty() else Vector3.ZERO
	camera.position = spawn + Vector3(0.0, 3.0, 0.0)
	camera.look_at(spawn + Vector3(0.0, 0.0, -40.0))

	for _i in 6:
		await get_tree().process_frame

	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path).get_base_dir())
	_check(image.save_png(path) == OK, "a frame is saved to %s" % path)
	var seen := {}

	for y in range(0, image.get_height(), 16):
		for x in range(0, image.get_width(), 16):
			seen[image.get_pixel(x, y).to_html(false)] = true

	_check(seen.size() > 40, "and is not a flat colour (%d distinct samples)" % seen.size())
	camera.queue_free()


func _test_leaves() -> void:
	_section("a pack the server stops naming leaves the catalogue")
	var _away: DotResult = await _director.change_to(&"dm_box")
	_server.games.maps = PackedStringArray()
	var adopted := _director.adopt_server_maps()
	var back := _director.session.catalogue.get_map(MAP)
	_check(int(adopted.get("removed", 0)) == 1 and back != null and back.is_local(),
		"it is dropped, and this machine's own import of the id put back (%d removed)" % int(adopted.get("removed", 0)))
	_done()


func _test_surf_keys() -> void:
	_section("the published surf packs are in the solo list, under their manifest ids")
	var def := ArenaMaps.delivered_def("gamemann/arena-surf-dm-maps-surf_10x_final@1.2.3")
	_check(def != null and String(def.id) == "surf_10x_final", "the pack prefix is stripped from the map id (%s)" % (String(def.id) if def != null else "null"))
	_check(ArenaMaps.is_delivered(def), "a prefixed surf pack counts as delivered (is_delivered)")
	var surf := 0
	for key in ArenaMaps.STANDALONE_KEYS:
		if key.begins_with("gamemann/" + ArenaMaps.PACK_PREFIX) and key.ends_with("@1.2.3"):
			surf += 1
	_check(surf == 39, "STANDALONE_KEYS holds 39 surf packs (%d)" % surf)
	var listed := ArenaMaps.standalone_keys(null)
	_check("gamemann/arena-surf-dm-maps-surf_10x_final@1.2.3" in listed, "standalone_keys() lists a surf pack")
	_check(listed.size() >= surf, "standalone_keys() lists at least all of them (%d)" % listed.size())
	_done()


func _cleanup(game: ArenaGame) -> void:
	if game != null:
		remove_child(game)
		game.free()

	if _cloud != null:
		_cloud.queue_free()

	DotPaths.remove_tree(ROOT)
	DotPaths.remove_tree(STAGE)


func _finish() -> void:
	var expected := CHECKS - _skipped + (2 if OS.get_cmdline_user_args().has("--shot") and DisplayServer.get_name() != "headless" else 0)
	_report_sections(_entered, _completed, SECTIONS, expected)


func _section(title: String) -> void:
	_entered += 1
	_line("")
	_line("-- %s" % title)


func _done() -> void:
	_completed += 1


func _line(text: String) -> void:
	print(text)
