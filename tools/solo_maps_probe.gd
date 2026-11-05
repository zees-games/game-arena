extends SceneTree
## Solo's delivered path for every suggested pack, as a client with no map links takes it: fetch from the content origin, mount, build, count spawns and meshes.
## godot --headless --path . --script tools/solo_maps_probe.gd -- [<substring of a pack key>]

const ArenaMap := preload("res://maps/arena_map.gd")
const ArenaImportedMaps := preload("res://maps/arena_imported_maps.gd")
const ArenaMaps := preload("res://game/arena_maps.gd")


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var filter := OS.get_cmdline_user_args()[0] if OS.get_cmdline_user_args().size() > 0 else ""
	var cloud := DotGameStandaloneContent.install(root)
	if cloud == null:
		print("FAIL no content client")
		quit(1)
		return

	await process_frame
	var failed := 0
	var total := 0

	for key in ArenaMaps.STANDALONE_KEYS:
		if filter != "" and not key.contains(filter):
			continue

		total += 1
		var def := ArenaMaps.delivered_def(key)
		var res: DotResult = await ArenaMaps.mount_delivered(def, DotMapLoader.new(), null, true)

		if not res.ok:
			failed += 1
			print("FAIL %s: fetch/mount: %s" % [key, res.error.message if res.error != null else "?"])
			continue

		var map := ArenaMap.by_id(def.id)
		var spawns := map.spawns.size() if map != null else -1
		var meshes := 0

		if map != null:
			var scene := map.to_scene()
			root.add_child(scene)
			meshes = scene.find_children("*", "MeshInstance3D", true, false).size()
			scene.queue_free()

		var from := ArenaImportedMaps.manifest_path(def.id)
		var ok := map != null and spawns > 0 and meshes > 0
		failed += 0 if ok else 1
		print("%s %s: spawns %d meshes %d from %s" % ["ok  " if ok else "FAIL", key, spawns, meshes, from])

	print("probe: %d of %d failed" % [failed, total])
	quit(1 if failed > 0 else 0)
