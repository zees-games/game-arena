extends DotCameraTool

## The arena's cameras against its real maps: the third-person view, and the spectator's
## chase camera (the one the play test found inside a wall). See dot-core's DotCameraTool.
##
##   tools/render_cameras.sh [map]        # dm_box by default; frames in screenshots/cameras/
##   godot --headless --path . --script tools/render_cameras.gd -- --no-render --map dm_atrium

const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMapLighting := preload("../maps/arena_map_lighting.gd")
const ArenaBspMap := preload("../maps/arena_bsp_map.gd")
const ArenaImportedMaps := preload("../maps/arena_imported_maps.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

var _map: ArenaMap = null


func _map_now() -> ArenaMap:
	if _map == null:
		var args := OS.get_cmdline_user_args()
		var at := args.find("--map")
		_map = ArenaMap.by_id(StringName(args[at + 1]) if at >= 0 and at + 1 < args.size() else &"dm_box")
		_name = "arena_%s" % String(_map.id)
	return _map


func _build_level() -> Node3D:
	var level := _map_now().to_scene()

	# An imported map's to_scene() is the drawn world only (its solid is the game's, see
	# ArenaMap.movement_body), so the cameras flew through every wall and the check read
	# "unprotected camera in or behind the level on 0 frames" as an unarmed FAIL. Give the level
	# the convex-hull solid the game collides with.
	if _map_now().is_imported():
		var manifest := ArenaImportedMaps.manifest(_map_now().id)
		var solid := ArenaBspMap.build_collision(manifest, _map_now().manifest_path.get_base_dir())
		level.add_child(solid)
		_map_now().collision_root = solid

	return level


func _build_lighting() -> Node3D:
	return ArenaMapLighting.build(_map_now())


func _pivots() -> Array[Vector3]:
	var out: Array[Vector3] = []
	# From where the game spawns somebody: a mapper's spawn can sit in a stair or a slab, and the
	# game lifts it clear at load (ArenaGame, `settle_spawns`). Flying from the raw point puts the
	# camera's pivot, the player's eye, inside solid, which no camera can answer for.
	if _map_now().is_imported():
		var _lifted := _map_now().settle_spawns(_map_now().movement_body(), ArenaPlayer.arena_tunables())
	var space := root.get_world_3d().direct_space_state
	var skipped := 0
	for spawn in _map_now().spawns:
		var eye: Vector3 = spawn.origin + Vector3.UP * 1.6
		# A spawn the game cannot clear (a mapper's spawn in a stair, 1.5 m under a slab) leaves
		# the eye in solid; DotCameraProbe wants a clear pivot, so that one is not a camera case.
		if DotCameraProbe.is_inside(space, eye, 0.18, _level_mask()):
			skipped += 1
			continue
		out.append(eye)
	if skipped > 0:
		print("camera tool: %d of %d spawns have the eye in solid even after the game's lift; not flown" % [skipped, _map_now().spawns.size()])
	return out


func _offsets() -> Dictionary:
	# The spectator's chase camera is dot-spectate's: 3.5 m behind the eye and 0.9 up (the
	# arena's rules), along the watched player's view.
	return {"third_person": ArenaPlayer.THIRD_PERSON_OFFSET, "chase": Vector3(0.0, 0.9, 3.5)}
