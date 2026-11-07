extends DotBotBrain

## dot-bot's brain with a cheaper candidate scan (cvar `bot_fast_sense`). The stock scan runs
## aim_point(), is_enemy(), a vector subtraction, length(), angle_to() and rad_to_deg() for
## every contact on every think, which is O(bots^2) per tick: at 128 bots it was a large part
## of the brain's ~200 us per bot. This keeps the same candidates and scores, but rejects on
## squared distance and the cone's cosine first and takes the angle only for a candidate.

## false runs the stock [method DotBotBrain._candidates].
static var fast_sense: bool = true


func _candidates(me: DotBotContact, all: Array, p: DotBotProfile, eye: Vector3, forward: Vector3, half: float, scores: PackedFloat32Array) -> Array[DotBotContact]:
	if not fast_sense or half <= 0.0 or half >= 180.0:
		return super._candidates(me, all, p, eye, forward, half, scores)
	var cand: Array[DotBotContact] = []
	var sight_sq := p.sight * p.sight
	var cos_half := cos(deg_to_rad(half))
	var me_id := me.id
	var me_team := me.team
	var ex := eye.x
	var ey := eye.y
	var ez := eye.z
	var fx := forward.x
	var fy := forward.y
	var fz := forward.z
	for item in all:
		var c := item as DotBotContact
		if c == null:
			continue
		if not c.alive:
			if c.id == target_id and _visible:
				_forget_target()
			continue
		# DotBotContact.is_enemy
		if c.id == me_id or (me_team != 0 and c.team != 0 and me_team == c.team):
			continue
		var pos := c.position
		var tx := pos.x - ex
		var ty := pos.y + c.aim_height - ey
		var tz := pos.z - ez
		var d_sq := tx * tx + ty * ty + tz * tz
		if d_sq > sight_sq:
			continue
		var d := sqrt(d_sq)
		if d > 0.01:
			var dot := (fx * tx + fy * ty + fz * tz) / d
			var tracking := _visible and c.id == target_id and dot > 0.0
			if dot < cos_half and d > CLOSE_NOTICE and not tracking:
				continue
			cand.append(c)
			scores.append(d * (1.0 + rad_to_deg(forward.angle_to(Vector3(tx, ty, tz))) / 60.0))
		else:
			cand.append(c)
			scores.append(d)
	return cand
