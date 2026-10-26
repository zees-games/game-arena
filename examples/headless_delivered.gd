extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMaps := preload("../game/arena_maps.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaImportedMaps := preload("../maps/arena_imported_maps.gd")
const ArenaMapDirector := preload("../game/arena_map_director.gd")

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
## `maps/imported` link. A client without the arena-surf-dm-maps link has only this path.
##
## [b]Not here[/b]: a networked announce (`headless_imported` accepts one) and the published
## packs on the site's origin, which need a tag and the owner's permission to publish.
##
## Skips, saying so, without the link. `-- --shot <path>` saves a frame (needs a renderer).

const MAP := &"surf_10x_reloaded_fixed"
const OWNER := "gamemann"
const VERSION := "1.0.4"
const ROOT := "user://arena_delivered_check"
## Inside the project, so the publisher finds the imported outputs the markers name; under
## `.godot`, which git ignores.
const STAGE := "res://.godot/arena_delivered_stage"
const SECTIONS := 4
## Without a frame; two more with `--shot`.
const CHECKS := 17

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0


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
	var source_manifest := ArenaImportedMaps.manifest_path(MAP)

	if source_manifest.is_empty():
		_line("no %s under %s — nothing to publish (link arena-surf-dm-maps)" % [MAP, ArenaImportedMaps.roots()[0]])
		get_tree().quit(0)
		return

	DotPaths.remove_tree(ROOT)
	DotPaths.remove_tree(STAGE)
	var keys := await _test_publish(source_manifest.get_base_dir())

	if not keys.is_empty():
		var game := await _test_fetch_and_build(keys)
		await _test_frame(game)
		await _test_leaves()
		_cleanup(game)

	_finish()


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

	return dest


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
	var textures := 0
	var strays := PackedStringArray()

	for node in scene.find_children("*", "MeshInstance3D", true, false):
		var mesh := (node as MeshInstance3D).mesh

		if mesh == null:
			continue

		meshes += 1

		for i in mesh.get_surface_count():
			var mat := (node as MeshInstance3D).get_surface_override_material(i) as ShaderMaterial

			if mat == null:
				continue

			for param in ["albedo_tex", "lightmap_tex"]:
				var tex := mat.get_shader_parameter(param) as Texture2D

				if tex == null:
					continue

				# The generated grid an untextured surface wears has no path, and is not a file.
				if tex.resource_path.is_empty():
					continue

				textures += 1

				if not tex.resource_path.begins_with(_mount):
					strays.append("%s:%s" % [param, tex.resource_path])

	_check(meshes > 0, "the map draws meshes (%d)" % meshes)
	_check(textures > 0 and strays.is_empty(),
		"%d textures and lightmaps, all resources of the pack%s" % [textures, "" if strays.is_empty() else ": " + ", ".join(strays.slice(0, 3))])
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


func _cleanup(game: ArenaGame) -> void:
	if game != null:
		remove_child(game)
		game.free()

	if _cloud != null:
		_cloud.queue_free()

	DotPaths.remove_tree(ROOT)
	DotPaths.remove_tree(STAGE)


func _finish() -> void:
	_line("")
	_line("%d sections, %d passed, %d failed" % [_completed, _passed, _failed])

	if _entered != SECTIONS or _completed != SECTIONS:
		_line("ERROR: %d sections entered and %d completed, %d expected." % [_entered, _completed, SECTIONS])
		get_tree().quit(1)
		return

	var expected := CHECKS + (2 if OS.get_cmdline_user_args().has("--shot") and DisplayServer.get_name() != "headless" else 0)

	if _passed + _failed != expected:
		_line("ERROR: %d checks ran, %d expected." % [_passed + _failed, expected])
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


func _section(title: String) -> void:
	_entered += 1
	_line("")
	_line("-- %s" % title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
