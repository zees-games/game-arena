extends DotGameNetchaosClient

const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaSolidBody := preload("../game/arena_solid_body.gd")

## The arena's side of `tools/netchaos.sh` (dot-game's DotGameNetchaosClient).


func _configure() -> void:
	client_scene = "res://game/arena.tscn"
	fire_action = &"arena_fire"


func _prepare(label: String) -> Variant:
	return ArenaPresentation.use_scratch_settings(label)


func _contacts() -> int:
	return ArenaSolidBody.hull_stops
