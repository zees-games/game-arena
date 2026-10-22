extends Node

const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMapLighting := preload("../maps/arena_map_lighting.gd")

## Writes one bake scene per built-in map for dot-lighting's baker: the level built exactly as a
## client builds it (every box with its UV2), the map's sun and sky, a LightmapGI added and the
## map's fingerprint recorded. tools/bake_lightmaps.sh runs this and then the bake.
##
##   xvfb-run -a godot --path . res://tools/lightmap_scenes.tscn -- --out=res://lightbake_work [--maps=dm_box,dm_pit]
##
## Under a display, not --headless: a headless process keeps no mesh data to save.
##
## [b]What the bake sees.[/b] The boxes and the floor. The sun gives only its bounce
## (BAKE_DYNAMIC) because it stays live; the fill is left out (BAKE_DISABLED), being already
## "more sky". Changing any of that changes what a bake means: bump ArenaMap.BAKE_VERSION.

## Per map: LightmapGI settings for DotLightBake.prepare, over "default".
const SETTINGS := {
	"default": {"quality": LightmapGI.BAKE_QUALITY_HIGH, "bounces": 3, "texel_scale": 1.0, "ambient_gain": 1.0, "bounce_energy": 1.0},
}


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.substr(name.length() + 3)
	return fallback


func _run() -> void:
	var out := _arg("out", "res://lightbake_work")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	var wanted := _arg("maps", "")
	var written := 0
	ArenaMap.use_bakes = false

	for id: StringName in ArenaMap.ids():
		if wanted != "" and not wanted.split(",").has(String(id)):
			continue

		var map := ArenaMap.by_id(id)

		if map == null or map.is_imported():
			continue

		var scene := _bake_scene(map)
		var path := out.path_join("%s.tscn" % id)
		var packed := PackedScene.new()
		packed.pack(scene)
		var saved := ResourceSaver.save(packed, path)
		print("LIGHTMAP_SCENE %s %s %s" % ["ok" if saved == OK else "fail", id, path])
		written += 1 if saved == OK else 0
		scene.free()

	get_tree().quit(0 if written > 0 else 1)


func _bake_scene(map: ArenaMap) -> Node3D:
	var root := Node3D.new()
	root.name = "Bake"
	var settings: Dictionary = (SETTINGS["default"] as Dictionary).duplicate()
	settings.merge(SETTINGS.get(String(map.id), {}), true)

	if FileAccess.file_exists("res://tools/lb_override.json"):
		settings.merge(JSON.parse_string(FileAccess.get_file_as_string("res://tools/lb_override.json")), true)

	# The level's StaticBody3Ds become plain holders: the lightmap names a mesh by its path from
	# the LightmapGI, which is a child of the level there and of this root here.
	var level := map.to_scene()

	for body in level.get_children():
		var mesh := body.get_node_or_null("Mesh") as MeshInstance3D

		if mesh == null:
			continue

		var holder := Node3D.new()
		holder.name = body.name
		holder.transform = (body as Node3D).transform
		var copy := MeshInstance3D.new()
		copy.name = mesh.name
		copy.mesh = mesh.mesh
		copy.material_override = mesh.material_override
		copy.gi_mode = GeometryInstance3D.GI_MODE_STATIC
		holder.add_child(copy)
		root.add_child(holder)

	level.free()
	var lighting := ArenaMapLighting.build(map)
	root.add_child(lighting)

	for node in lighting.get_children():
		if node is DirectionalLight3D:
			# The sun first (DotLightRig adds it before the fill).
			node.light_bake_mode = Light3D.BAKE_DYNAMIC if node == lighting.get_child(0) else Light3D.BAKE_DISABLED

	var gi := DotLightBake.prepare(root, map.light_fingerprint(), ArenaMap.BAKE_PATH % String(map.id), settings)
	gi.bounce_indirect_energy = float(settings.get("bounce_energy", 1.0))
	var world := lighting.get_node_or_null("Lighting") as WorldEnvironment

	if world != null and float(settings.get("ambient_gain", 1.0)) != 1.0:
		gi.environment_mode = LightmapGI.ENVIRONMENT_MODE_CUSTOM_COLOR
		gi.environment_custom_color = world.environment.ambient_light_color
		gi.environment_custom_energy = world.environment.ambient_light_energy * float(settings["ambient_gain"])

	_own(root, root)
	print("LIGHTMAP_SCENE meshes %s %d" % [map.id, root.get_child_count()])
	return root


func _own(node: Node, owner_node: Node) -> void:
	for child in node.get_children():
		child.owner = owner_node
		_own(child, owner_node)
