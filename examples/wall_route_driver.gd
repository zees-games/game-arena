extends RefCounted

## Drives a player along one of a map's declared wall routes ([member ArenaMap.wall_routes]),
## one command per tick, read off the player's own state.
##
## [codeblock]
## var driver := WallRouteDriver.new(route, &"walls")
## controller.teleport(driver.start, driver.yaw)
## motor.simulate(state, driver.next(state), step)   # every tick
## driver.made(state)                                 # landed on the route's end
## [/codeblock]
##
## [b]Read off the state, never off a clock[/b], so the same driver works on a bare motor,
## on a predicting client (fed its predicted state, which the server then simulates with
## the same commands) and in the frame-sequence render. Shared by `headless_match`,
## `headless_net` and `tools/render_wall_moves.gd`; no class_name, for pack delivery.
##
## The route's geometry says everything: which way it runs, which side the wall is on, where
## the edge is. `variant` is how the player tries it:
##
## - `&"walls"`: the intended way. A run is a slide into a jump off the edge, onto the wall;
##   a jump route is a jump at one wall and a jump off each wall in turn.
## - `&"plain"`, `&"slide"`, `&"dash"`, `&"jumpdash"`: a run route's gap tried without the
##   wall (a run and a jump, a slide-jump, a dash then a jump, a jump then a dash). Run with
##   the wall moves off, each must fall short, or the route is not a wall route.

var route: Dictionary = {}
var variant: StringName = &"walls"

## Where to put the player first, and which way to face.
var start: Vector3 = Vector3.ZERO
var yaw: float = 0.0

var _ticks := 0
var _jumped_at := -1
var _last_wall_jump := -100
var _wall_jumps := 0

# A run route: the axis it runs along and which way, the edge it leaves from.
var _axis := 0
var _dir := 1.0
var _edge := 0.0

# A jump route: which way the near wall is, as a strafe.
var _strafe := 0.0


func _init(of_route: Dictionary, how: StringName = &"walls") -> void:
	route = of_route
	variant = how
	var from: AABB = route["from"]
	var to: AABB = route["to"]
	var walls: Array = route["walls"]

	if route["kind"] == &"run":
		var wall: AABB = walls[0]
		var delta := to.get_center() - from.get_center()
		_axis = 0 if absf(delta.x) >= absf(delta.z) else 2
		var cross := 2 if _axis == 0 else 0
		_dir = signf(delta[_axis])
		_edge = from.end[_axis] if _dir > 0.0 else from.position[_axis]
		var side := signf(from.get_center()[cross] - wall.get_center()[cross])
		var face := wall.end[cross] if side > 0.0 else wall.position[cross]

		# Ten metres back from the edge, half a metre off the wall: the hull's 0.35 and
		# a hand's width, inside `wall_reach` (0.25) of the face.
		start[_axis] = _edge - _dir * 10.0
		start[cross] = face + side * 0.5
		start.y = from.end.y
		var forward := Vector3.ZERO
		forward[_axis] = _dir
		yaw = _yaw_of(forward)
	else:
		# Two walls side by side; the route climbs between them toward `to`.
		var a: AABB = walls[0]
		var b: AABB = walls[1]
		var centre := (a.get_center() + b.get_center()) * 0.5
		var apart := (b.get_center() - a.get_center()).abs()
		var across := 0 if apart.x >= apart.z else 2
		var along := 2 if across == 0 else 0
		var near: AABB = a if a.get_center()[across] < b.get_center()[across] else b
		var toward := signf(to.get_center()[along] - centre[along])
		var mouth := maxf(a.end[along], b.end[along]) if toward < 0.0 else minf(a.position[along], b.position[along])

		start[across] = near.end[across] + 0.36
		start[along] = mouth + toward * 0.4
		start.y = from.end.y
		var forward := Vector3.ZERO
		forward[along] = toward
		yaw = _yaw_of(forward)
		var right := forward.cross(Vector3.UP)
		var to_near := Vector3.ZERO
		to_near[across] = -1.0
		_strafe = signf(right.dot(to_near))


## The command for the tick about to run, from the player's state as it stands.
func next(state: DotFpsState) -> DotFpsCommand:
	var c := DotFpsCommand.new()
	c.yaw = yaw
	c.move = Vector2(0.0, 1.0)

	if state.wall_jumps_in_air > _wall_jumps:
		_last_wall_jump = _ticks
	_wall_jumps = state.wall_jumps_in_air

	if route["kind"] == &"run":
		_next_run(state, c)
	else:
		_next_jump(state, c)

	_ticks += 1
	return c


func _next_run(state: DotFpsState, c: DotFpsCommand) -> void:
	var left := (_edge - state.position[_axis]) * _dir

	if _jumped_at < 0:
		# The slide: pressed a metre and a bit before the edge, so the boost is fresh
		# when the jump comes; a slide bleeds about 9 m/s² and the run needs 9.5.
		if (variant == &"walls" or variant == &"slide") and left < 1.2:
			c.buttons |= DotFpsCommand.BUTTON_CROUCH
		if variant == &"dash" and left < 3.0 and left > 2.0:
			c.buttons |= DotFpsCommand.BUTTON_SPRINT
		if left < 0.5 and state.is_grounded():
			c.buttons |= DotFpsCommand.BUTTON_JUMP
			_jumped_at = _ticks
	elif variant == &"jumpdash" and _ticks == _jumped_at + 3:
		c.buttons |= DotFpsCommand.BUTTON_SPRINT


func _next_jump(state: DotFpsState, c: DotFpsCommand) -> void:
	if _jumped_at < 0:
		# Off the floor toward the near wall.
		c.move = Vector2(_strafe, 1.0)
		c.buttons |= DotFpsCommand.BUTTON_JUMP
		_jumped_at = _ticks
		return

	# A press every other tick once the rise is nearly spent and the last kick has carried
	# the player across: a press, not a hold, is what a wall jump answers.
	if (
		_ticks > _jumped_at + 6 and _ticks - _last_wall_jump > 6
		and not state.is_grounded() and _ticks % 2 == 0 and state.velocity.y < 2.0
	):
		c.buttons |= DotFpsCommand.BUTTON_JUMP


## Whether the jump has been made and the player is down again, wherever that is.
func finished(state: DotFpsState) -> bool:
	return _jumped_at >= 0 and _ticks > _jumped_at + 3 and state.is_grounded()


## Whether the player stands on the route's end.
func made(state: DotFpsState) -> bool:
	var to: AABB = route["to"]
	var at := state.position
	return (
		state.is_grounded() and absf(at.y - to.end.y) < 0.05
		and at.x >= to.position.x and at.x <= to.end.x
		and at.z >= to.position.z and at.z <= to.end.z
	)


## The view yaw that looks along [param forward]: `DotFpsMotor.forward_for` inverted.
static func _yaw_of(forward: Vector3) -> float:
	return rad_to_deg(atan2(-forward.x, -forward.z))
