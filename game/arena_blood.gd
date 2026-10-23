extends DotFxBlood
## Blood on the surface behind a body the local player hit, from the HIT event the server already sends.


## The server confirmed a hit on [param victim] at [param point], seen from [param from]. Null for a victim that is not a body.
func on_body_hit(victim: int, point: Vector3, from: Vector3, reach: float = 4.0) -> Node3D:
	var kind := DotEntity.kind_of(victim)
	if kind != DotEntity.KIND_PLAYER and kind != DotEntity.KIND_NPC:
		return null
	return splat_behind(from, point, reach, 0.8)
