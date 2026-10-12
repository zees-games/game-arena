extends DotCameraTool

## The arena's cameras against its real maps: the third-person view, and the spectator's
## chase camera (the one the play test found inside a wall). See dot-core's DotCameraTool.
##
##   tools/render_cameras.sh [map]        # dm_box by default; frames in screenshots/cameras/
##   godot --headless --path . --script tools/render_cameras.gd -- --no-render --map dm_atrium

const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMapLighting := preload("../maps/arena_map_lighting.gd")
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
	return _map_now().to_scene()


func _build_lighting() -> Node3D:
	return ArenaMapLighting.build(_map_now())


func _pivots() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for spawn in _map_now().spawns:
		out.append(spawn.origin + Vector3.UP * 1.6)
	return out


func _offsets() -> Dictionary:
	# The spectator's chase camera is dot-spectate's: 3.5 m behind the eye and 0.9 up (the
	# arena's rules), along the watched player's view.
	return {"third_person": ArenaPlayer.THIRD_PERSON_OFFSET, "chase": Vector3(0.0, 0.9, 3.5)}
