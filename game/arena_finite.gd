extends RefCounted

## Guards for numbers a peer, a bot or a recorded row can hand the killcam and the death fall as NaN or infinity.
## Local stand-in for a shared finite_or: dot-player-char has none yet.

## [param v] when finite, else [param fallback].
static func num(v: float, fallback: float = 0.0) -> float:
	return v if is_finite(v) else fallback


## [param v] when every component is finite, else [param fallback].
static func vec3(v: Vector3, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	return v if v.is_finite() else fallback


## [param v] as a unit vector, or [param fallback] when it is non-finite or too short to point anywhere.
static func dir(v: Vector3, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	return v.normalized() if v.is_finite() and v.length_squared() > 0.0001 else fallback


## [param d] with its direction and damage made finite (a zero direction is kept: it means "none").
static func death(d: DotPlayerDeath) -> DotPlayerDeath:
	if d == null:
		return DotPlayerDeath.new()
	d.direction = vec3(d.direction)
	d.damage = num(d.damage)
	return d
