extends RefCounted
## `--use`: the local player at a converted map's jail button, once with the "[E] Use" prompt up and once after the press with the door open.

const BUTTON := 39
const DOOR := 293


## The shots, or empty when the map has no movers or no spot reaches the button.
static func stage(game, local, hud) -> Array[Dictionary]:
	var mio = game.map_io
	if mio == null:
		return []
	var button: Vector3 = mio.world.io.entity_of(BUTTON).origin(mio.world.io)
	var eye := Vector3.ZERO
	for dir: Vector3 in [Vector3.UP, Vector3.LEFT, Vector3.RIGHT, Vector3.BACK, Vector3.FORWARD]:
		var at: Vector3 = button + dir * 1.2
		var hit: Dictionary = mio.aim_from(at, (button - at).normalized())
		if not hit.is_empty() and bool(hit["in_range"]) and int(hit["index"]) == BUTTON:
			eye = at
			break
	if eye == Vector3.ZERO:
		return []
	local.controller.state.position = eye - Vector3(0.0, 1.6, 0.0)
	var aim := func() -> void:
		local.camera.global_position = eye
		local.camera.look_at(button, Vector3.UP if absf((button - eye).normalized().y) < 0.95 else Vector3.BACK)
		local.camera.current = true
		hud.use_hint = String(mio.aim_from(eye, (button - eye).normalized()).get("label", ""))
	var press := func() -> void:
		aim.call()
		var _p: bool = mio.press_for(local, local.player_id)
		for _t in 64 * 4:
			game.tick({})
		var door: DotMapEntity = mio.world.io.entity_of(DOOR)
		var at: Vector3 = door.node.global_position if door.node != null else button
		local.camera.global_position = at + Vector3(0.0, 1.5, 2.5)
		local.camera.look_at(at, Vector3.UP)
		hud.use_hint = ""
	var shots: Array[Dictionary] = [
		{"name": "use_prompt", "local": true, "arm": aim, "wait": 8},
		{"name": "use_door_open", "local": true, "arm": press, "wait": 8},
	]
	return shots
