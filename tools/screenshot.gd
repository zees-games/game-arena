extends "screenshot_b1.gd"


## Renders a map to a PNG so a person can look at it.


func _initialize() -> void:
	# A scratch settings document, never this machine's real one (see
	# `ArenaPresentation.use_scratch_settings`): a render must not save into a player's file.
	var _scratch := ArenaPresentation.use_scratch_settings("screenshot")
	var args := OS.get_cmdline_user_args()
	var map_index := args.find("--map")
	var id := StringName(args[map_index + 1]) if map_index >= 0 and map_index + 1 < args.size() else &"dm_box"
	var mounted_at := args.find("--mounted")
	if mounted_at >= 0 and mounted_at + 1 < args.size():
		# A delivered map's directory (pack files unpacked), as `ensure` mounts it.
		var added := ArenaImportedMaps.add_mounted(id, args[mounted_at + 1])
		if not added.ok:
			push_error("--mounted: %s" % added.error.message)
	var map := ArenaMap.by_id(id)

	if map == null:
		push_error("no such map: %s. Known: %s" % [String(id), ArenaMap.ids()])
		quit(1)
		return

	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	# --no-bake draws a built-in map with its live lights, for before/after frames of a bake.
	ArenaMap.use_bakes = not args.has("--no-bake")
	ArenaMap.use_worlds = not args.has("--legacy")
	root.add_child(map.to_scene())
	_stage_packs.call_deferred(map)
	# The map's toys, as a client draws them: frozen where the map puts them. Built in the
	# first frame, because the box builds in the tree and nothing here is in it yet.
	if not map.toys.is_empty():
		_toy_box = DotPropBodyBox.new()
		_toy_box.name = "Toys"
		_toy_box.authoritative = false
		root.add_child(_toy_box)
		_toy_placements = map.toys

	# Drawn under the lighting the client builds for it: a sun of this tool's own says nothing about the game.
	root.add_child(ArenaMapLighting.build(map))

	_camera = Camera3D.new()
	_camera.fov = 70.0
	root.add_child(_camera)

	if args.has("--admin"):
		_stage_admin(map, id)
		return

	if args.has("--feel"):
		_stage_feel(map, id)
		return

	if args.has("--people"):
		_stage_people(map, id)
		return

	var action_at := args.find("--action")
	if action_at >= 0 and action_at + 2 < args.size():
		_stage_action(map, id, StringName(args[action_at + 1]), args[action_at + 2])
		return

	var glance_at := args.find("--glance")
	if glance_at >= 0:
		_stage_glance(map, id, args, glance_at)
		return

	if map.is_imported():
		_stage_imported(map, id)
		return

	var fx_at := args.find("--fx")
	if fx_at >= 0:
		var eye: Variant = _vector(args[fx_at + 1]) if fx_at + 2 < args.size() else null
		var aim_at: Variant = _vector(args[fx_at + 2]) if fx_at + 2 < args.size() else null
		if eye == null or aim_at == null:
			push_error("--fx wants <eye x,y,z> <aim at x,y,z>")
			quit(1)
			return
		_stage_fx(map, id, eye, aim_at)
		return

	var far := map.extent * 1.5

	# Three frames, because one camera angle is one thing you did not get wrong. An overview says
	# whether there is a map; eye level says whether it is a space a person could be inside of.
	_shots = [
		{
			"name": "%s_overview" % String(id),
			"from": Vector3(-far, map.extent * 1.15, -far),
			"at": Vector3.ZERO,
		},
		{
			"name": "%s_eye" % String(id),
			"from": Vector3(-map.extent * 0.72, 1.7, -map.extent * 0.55),
			"at": Vector3(0.0, 3.0, 0.0),
		},
		{
			"name": "%s_roof" % String(id),
			"from": Vector3(map.extent * 0.62, 12.0, map.extent * 0.62),
			"at": Vector3(0.0, 3.0, 0.0),
		},
	]

	# `--view <name> <x,y,z> <x,y,z>`, repeatable: one more frame. The three above stay fixed so renders compare across nights.
	_initialize_rest(args, id)
