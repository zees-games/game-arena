extends DotGameCheckSuite

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaMapDirector := preload("../game/arena_map_director.gd")

## A combat surf map as a real client gets it: fetched over HTTPS from the site's CDN, verified
## against the shipped production key, mounted and built, with no `maps/imported` link.
##
## [codeblock]
## godot --headless --path . res://examples/published_check.tscn
## [/codeblock]
##
## Not in `game.sh test`: it needs the network and the published packs. Skips (exit 0), saying so,
## when the origin is unreachable. Reads nothing from the `maps/imported` link by construction:
## run it from a checkout without the link to prove that.

const MAP := &"surf_10x_reloaded_fixed"
const PACK := "arena-surf-dm-maps-surf_10x_reloaded_fixed"
const OWNER := "gamemann"
const VERSION := "1.2.0"
const ORIGIN := "https://dotgames.org/content"
const KEYS := "res://addons/dot_game/data/content.json"
const ROOT := "user://arena_published_check"
const SECTIONS := 1
const CHECKS := 10

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
	print("arena: a combat surf map from the published CDN")
	var probe := HTTPRequest.new()
	add_child(probe)
	probe.request("%s/%s/%s/%s/manifest.json" % [ORIGIN, OWNER, PACK, VERSION])
	var answer: Array = await probe.request_completed
	probe.queue_free()

	if int(answer[0]) != HTTPRequest.RESULT_SUCCESS:
		print("origin unreachable (result %d): nothing to check" % int(answer[0]))
		get_tree().quit(0)
		return

	DotPaths.remove_tree(ROOT)
	print("\n-- a client fetches the published pack under the production key, and the game builds it")
	var shipped: Variant = JSON.parse_string(FileAccess.get_file_as_string(KEYS))
	_check(shipped is Dictionary and (shipped as Dictionary).has("trusted_keys"), "the shipped trust list is read")

	var config := DotCloudConfig.new()
	config.side = "both"
	config.cache_dir = ROOT.path_join("cache")
	config.require_signed_manifests = true
	config.trusted_keys = (shipped as Dictionary)["trusted_keys"]
	var cloud := DotCloudClient.new()
	cloud.name = "Cloud"
	cloud.config = config
	cloud.config_file = ""
	cloud.register_service = false
	cloud.http_base_urls = PackedStringArray([ORIGIN])
	add_child(cloud)
	DotRegistry.register(&"dot_cloud_client", cloud)
	await get_tree().process_frame

	var game := ArenaGame.new()
	game.tick_rate = 64
	game.headless = true
	game.is_authority = true
	game.register_service = false
	game.mode = ArenaMode.free_for_all(4)
	add_child(game)
	_check(game.setup(ArenaMap.by_id(&"dm_box")).ok, "the game starts on a built-in map")

	var server := StandInServer.new()
	server.games.maps = PackedStringArray(["%s/%s@%s" % [OWNER, PACK, VERSION]])
	var director := ArenaMapDirector.new()
	director.game = game
	director.server = server
	add_child(director)
	_check(director.setup().ok, "the director adopts the pack the server names")
	var changed: DotResult = await director.change_to(MAP)
	await get_tree().physics_frame
	if not changed.ok:
		print("  cause: %s" % changed.error)
	_check(changed.ok, "the change succeeds%s" % ("" if changed.ok else ": " + changed.error.message))
	_check(cloud.is_mounted(StringName("%s/%s" % [OWNER, PACK]), VERSION), "dot-cloud has the signed pack mounted")

	var map := game.map
	_check(map != null and map.id == MAP and map.is_imported(), "the game is on the map")
	_check(map != null and map.manifest_path.begins_with("res://dot_cloud/"), "built from the mount (%s)" % (map.manifest_path if map != null else "none"))
	_check(map != null and map.manifest_path.find("maps/imported") < 0, "nothing from the maps/imported link")
	var solid := map.collision_root if map != null else null
	_check(solid != null and solid.get_child_count() > 100, "with its brushes in the tree (%d)" % (solid.get_child_count() if solid != null else -1))
	_check(map != null and map.movement_profile == &"surf" and map.spawns.size() > 0, "on the surf profile, with spawns")

	remove_child(game)
	game.free()
	cloud.queue_free()
	DotPaths.remove_tree(ROOT)
	_report_sections(1, 1, SECTIONS, CHECKS)
