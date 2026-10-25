extends DotGameNetchaosClient

const ArenaNetBridge := preload("../game/arena_net_bridge.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaSolidBody := preload("../game/arena_solid_body.gd")

## The arena's side of `tools/netchaos.sh` (dot-game's DotGameNetchaosClient).


func _configure() -> void:
	ArenaNetBridge.solid_trace = OS.get_environment("NC_SOLID_TRACE") == "1"
	client_scene = "res://game/arena.tscn"
	fire_action = &"arena_fire"


func _prepare(label: String) -> Variant:
	return ArenaPresentation.use_scratch_settings(label)


func _contacts() -> int:
	return ArenaSolidBody.hull_stops
