extends DotTracePhysics
## The physics shot trace with the jail glass rule: a ray fired from inside the cell is stopped by the glass layer, one from outside passes it.

## The rule and the cell; null or an empty cell leaves the trace as DotTracePhysics.
var glass: DotMapGlassSight = null
var _sight_query := false
var _base_mask := 1


func _world_ray(from: Vector3, direction: Vector3, max_distance: float) -> DotHitbox.Hit:
	if glass == null or glass.glass_mask == 0:
		return super(from, direction, max_distance)
	_base_mask = collision_mask
	# Sight has its own switch (sv_glass_block_sight, applied by sight_fn); a shot uses sv_glass_block_shots.
	collision_mask = (_base_mask & ~glass.glass_mask) if _sight_query else glass.shot_mask(from, _base_mask)
	var hit := super(from, direction, max_distance)
	collision_mask = _base_mask
	return hit


func line_of_sight(from: Vector3, to: Vector3) -> bool:
	_sight_query = true
	var seen := super(from, to)
	_sight_query = false
	return seen
