extends DotFpsBody

## A player's movement body: the map's own ([member inner]), plus the other players' standing
## hulls while players are solid (`mp_solidplayers`, dot-player-controller's
## [DotPlayerBodyRules] on the game).
##
## [b]Why not dot-player-controller's hull.[/b] Every other first-person game gives each body
## a capsule in the physics space ([method DotPlayerBodyRules.apply_hull]) and lets the
## motor's physics sweep stop at it. Arena's movement is analytic: a built-in map moves
## players against its box list ([DotFpsFlatBody]) on the server and on every predicting
## client, so a capsule in the physics space reached neither, and players and bots walked
## through each other with the cvar at 1. So the others are boxes in one more flat body,
## filled per sweep from where they stand now.
##
## [b]Only the sweep sees them.[/b] [method overlaps] and [method rest_contact] answer for
## the map alone, so two players who start inside each other (a shared spawn, a teleport)
## are never pushed or held: the slab sweep ignores a box it starts inside, they walk apart,
## and are solid once clear. That is the family's rule (`pass_out_mask`).
##
## [b]Prediction.[/b] A client predicts its own player against the others where it last
## heard they are, and replays against the same, so a replay agrees with itself; it can
## differ from the server by a few centimetres while two players lean on each other, which
## the reconcile corrects, as [DotPlayerBodyRules] says of the physics hull.

## The map's body: what [method overlaps], [method rest_contact] and the world half of every
## sweep are asked of.
var inner: DotFpsBody = null

## Returns the hulls to stop at, `Array[AABB]` (feet at `position.y`), the mover's own left
## out; empty when players are not solid. Asked once per sweep.
var hulls_fn: Callable = Callable()

## The collider id a hull is reported under (the motor reads it as `ground_id` when a player
## lands on a head). Far above any box or plane id the map bodies hand out.
const HULL_ID_BASE := 1 << 24

var _hulls := DotFpsFlatBody.new()


func _init() -> void:
	# No floor of its own: the map's floor is the inner body's.
	_hulls.floor_y = -INF


## [param map_body] wrapped, its mask, exclusions and pass-out layers taken over: the
## controller writes those to the body it was handed (this one), and [method _sync] hands
## them on, so an imported map's physics body asks exactly what it asked unwrapped.
func wrap(map_body: DotFpsBody, hulls: Callable) -> DotFpsBody:
	inner = map_body
	hulls_fn = hulls
	if map_body != null:
		collision_mask = map_body.collision_mask
		exclude = map_body.exclude
		pass_out_mask = map_body.pass_out_mask
	return self


func _sync() -> void:
	inner.collision_mask = collision_mask
	inner.exclude = exclude
	inner.pass_out_mask = pass_out_mask


func sweep(from: Vector3, motion: Vector3, height: float, radius: float) -> Hit:
	if inner != null:
		_sync()
	var world: Hit = inner.sweep(from, motion, height, radius) if inner != null else Hit.miss()

	if not hulls_fn.is_valid():
		return world

	var boxes: Array = hulls_fn.call()
	if boxes.is_empty():
		return world

	_hulls.boxes.clear()
	for box: AABB in boxes:
		_hulls.boxes.append(box)

	var other := _hulls.sweep(from, motion, height, radius)
	if not other.hit or (world.hit and world.fraction <= other.fraction):
		return world

	other.collider_id = HULL_ID_BASE + (other.collider_id - DotFpsFlatBody.box_id(0))
	return other


func overlaps(at: Vector3, height: float, radius: float) -> bool:
	if inner == null:
		return false
	_sync()
	return inner.overlaps(at, height, radius)


func rest_contact(at: Vector3, height: float, radius: float) -> Hit:
	if inner == null:
		return Hit.miss()
	_sync()
	return inner.rest_contact(at, height, radius)


## The standing hull of a player whose feet are at [param feet].
static func hull_at(feet: Vector3, height: float, radius: float) -> AABB:
	return AABB(feet - Vector3(radius, 0.0, radius), Vector3(radius * 2.0, height, radius * 2.0))


func describe() -> Dictionary:
	var out := {"implementation": "ArenaSolidBody", "hulls": _hulls.boxes.size()}
	if inner != null:
		out["inner"] = inner.describe()
	return out
