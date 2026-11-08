extends "arena_map_state.gd"

## What a body with its feet at [param feet] on simulation tick [param tick] is sent through: a
## pit's `{box, to, yaw}`, or an empty dictionary for none. The pits as the map ships them, but
## through the jail when it has one and the jail is on. Both ends call this from the tick.
func pit_at(feet: Vector3, tick: int) -> Dictionary:
	for index in range(pits.size()):
		if (pits[index]["box"] as AABB).has_point(feet):
			if jail != null:
				return jail.resolve(index, tick)
			return pits[index]
	return {}

## Whether this is an imported map rather than a list of boxes.
func is_imported() -> bool:
	return manifest_path != ""

static func _movement() -> DotFpsTunables:
	if _tunables == null:
		_tunables = load(ArenaPaths.rebase("res://game/arena_player.gd")).arena_tunables()

	return _tunables

## The highest top face a player standing on flat ground can reach, in metres.
##
## [b]This is the number three maps in this game were built without.[/b] `jump_height`
## reads like the height of a thing you can get onto and it is the apex of the arc, so
## a crate at 1.5 with `jump_height` 1.25 looks like a 0.25 m stretch and is in fact a
## wall. `dm_atrium`'s south-east crates were 1.5, 3.0 and 4.6 from the day the map was
## written: a route the map's own documentation called "the fast way up" that nothing
## has ever climbed, because nothing had ever been asked to.
static func climb_limit() -> float:
	return _movement().climb_limit()

## The clear air a player running at full ground speed crosses in one jump, landing
## [param rise] metres higher than they left.
##
## [b]The landing height is the whole point of this function.[/b] The airtime everybody
## writes down is the time to fall back to the height you jumped FROM, and it is the
## wrong number for any route that climbs: at this game's numbers a player is airborne
## for 0.67 s flat and 0.40 s onto a step 1.2 m up, which is 6.1 m of reach against
## 3.6. `game-playground` sized a jump course with the first number, was 30% out, and
## was unfinishable past platform three from the day it was built — see `[reach-1]` in
## `nightly-todo.md`. `DotFpsTunables.jump_reach` is that arithmetic; this asks it of
## this game's movement.
##
## Returns 0.0 for a rise no jump reaches at all, which is the honest answer: there is
## no gap you can cross onto something you cannot get on top of.
static func jump_reach(rise: float) -> float:
	return _movement().jump_reach(rise)

## Declares that [param to_box] is meant to be reached from [param from_box].
##
## [b]The only hand-written part is which two boxes are a route.[/b] Everything
## measured about the climb comes off the boxes, so moving a crate moves the climb with
## it and `headless_match`'s sweep re-decides it. A climb is not checked against
## anything here — a map is content and content does not assert — it is checked in the
## suite, where failing is useful.
func add_climb(of_name: String, from_box: AABB, to_box: AABB) -> ArenaMap:
	climbs.append(Climb.between(of_name, from_box.abs(), to_box.abs()))
	return self

## Declares a route the walls make, from [param from_box]'s top to [param to_box]'s. See
## [member wall_routes]; [param kind] is `&"run"` or `&"jump"`.
func add_wall_route(
	of_name: String, kind: StringName, from_box: AABB, to_box: AABB, walls: Array[AABB]
) -> ArenaMap:
	wall_routes.append({
		"name": of_name, "kind": kind, "from": from_box.abs(), "to": to_box.abs(), "walls": walls,
	})
	return self

## Declares that nobody is meant to stand on [param box]'s top. See [member out_of_reach].
func add_out_of_reach(box: AABB) -> ArenaMap:
	out_of_reach.append(box.abs())
	return self

## The ground plane as a box, so that "off the floor" is an ordinary climb.
##
## Wide enough that its footprint contains every map, which is what makes the gap of a
## climb out of it zero — a player standing on the ground is already underneath whatever
## they are about to jump onto, and the only thing that decides the jump is the rise.
static func _floor_at(y: float) -> AABB:
	return AABB(Vector3(-1000.0, y - 1.0, -1000.0), Vector3(2000.0, 1.0, 2000.0))

## The shipped arena: a square room, a raised centre, four pillars, two ledges, and
## since 2026-09-24 two gantries joining the ledges and a nest on two of the pillars —
## and since 2026-09-29 a walked stair from the floor to the foot of each nest.
##
## Symmetric on purpose. A symmetric map makes every spawn point score identically for
## the spawn selector, which is exactly the tie its name-based tie-break exists for —
## so the map that ships is also the map that exercises it.
static func dm_box() -> ArenaMap:
	var map := ArenaMap.new()
	map.id = &"dm_box"
	map.display_name = "dm_box"
	map.extent = 24.0
	map.wall_height = 8.0

	# The raised middle. Two steps up, so stair stepping is exercised by walking at it.
	map.add_box(AABB(Vector3(-6.0, 0.0, -6.0), Vector3(12.0, 1.0, 12.0)))
	map.add_box(AABB(Vector3(-7.0, 0.0, -7.0), Vector3(14.0, 0.5, 14.0)))

	# Four pillars, off the diagonals so they break sightlines rather than framing them.
	# The two at x ±12 stand beside the crate stacks and nobody stands on them — see
	# the nests below for why those two and not the others.
	for corner in [Vector2(-12.0, -4.0), Vector2(12.0, 4.0), Vector2(-4.0, 12.0), Vector2(4.0, -12.0)]:
		var pillar := AABB(
			Vector3(corner.x - 1.5, 0.0, corner.y - 1.5), Vector3(3.0, 5.0, 3.0)
		)
		map.add_box(pillar)

		if absf(corner.x) > 10.0:
			map.add_out_of_reach(pillar)

	# Two ledges along opposite walls, top face at 3.6.
	#
	# [b]6.5 m deep, and the last half metre is for the crates.[/b] They were 6, which
	# left a metre of air between the top crate and the ledge — too far for a player
	# hopping up with jump held (see the crates below). The crates cannot move toward
	# the wall instead: the spawns on the x axis stand at ±18, and a crate there is a
	# player spawning with their nose against a 2.7 m box. So the ledge reaches out to
	# meet them, and the axis spawns stand under its lip, which is cover.
	var west_ledge := AABB(Vector3(-map.extent, 3.0, -18.0), Vector3(6.5, 0.6, 36.0))
	var east_ledge := AABB(Vector3(map.extent - 6.5, 3.0, -18.0), Vector3(6.5, 0.6, 36.0))

	map.add_box(west_ledge)
	map.add_box(east_ledge)

	# --- Getting onto them -------------------------------------------------
	#
	# [b]This comment used to read "reachable from the pillars" and they were not
	# reachable from anywhere.[/b] The pillars are 5 m tall against a 1.25 m jump
	# APEX, so nothing has ever stood on one; the ledges are at 3.6 with the raised
	# middle at 1.0 as the next highest thing on the map. Both ledges have been
	# geometry a player can be shot from and cannot get to since the day dm_box was
	# written, and every check over this map passed the whole time, because a box
	# count cannot tell a platform from a ceiling. See [method jump_reach].
	#
	# Three crates to each ledge, 0.9 at a time to 2.7 and a fourth 0.9 onto the
	# ledge itself — 72% of the apex per step, so each is a jump and none is a
	# stretch. Each crate is 0.5 m of clear air on from the last, the number the other
	# two maps use.
	#
	# [b]It was 1.0 m until 2026-09-24, and no bot could climb it.[/b] A metre is a
	# fifth of what a RUNNING jump crosses at this rise, and it is too far for a
	# player hopping up with jump held: auto-hop leaves the ground on the tick it
	# lands, air speed caps at 1.2 m/s, and a hop that happens to start in the middle
	# of a 2.5 m crate carries 0.6 m — so the bot fell into the gap between the first
	# two crates and stood at the foot of a 1.8 m wall. `headless_match` drives the
	# whole climb now; the route has to work for the way a player climbs a stack, not
	# only for the way they cross a gap.
	#
	# [b]Mirrored, and that is not decoration.[/b] This map is symmetric so that every
	# spawn scores identically for the spawn selector, which is the tie its name-based
	# tie-break exists to break — it is the property dm_box ships FOR, and the reason
	# the arcade went on dm_atrium instead. A route added to one wall and not the
	# other would take that away for the sake of a shortcut.
	for side in [-1.0, 1.0]:
		var previous := AABB()

		for step in range(3):
			var top := 0.9 * float(step + 1)
			var crate := AABB(
				Vector3(
					-17.0 if side < 0.0 else 14.5,
					0.0,
					# Mirrored about z 0 through the CENTRE, not the corner: signing a
					# corner reflects the box onto the wrong side of itself and the two
					# walls stop being each other's mirror, which is the one thing this
					# map may not lose.
					side * (6.25 - float(step) * 3.0) - 1.25
				),
				Vector3(2.5, top, 2.5)
			)
			map.add_box(crate)

			if step == 0:
				map.add_climb("dm_box: the floor onto the first crate", _floor_at(0.0), crate)
			else:
				map.add_climb("dm_box: crate %d onto crate %d" % [step, step + 1], previous, crate)

			previous = crate

		map.add_climb(
			"dm_box: the top crate onto the %s ledge" % ["west" if side < 0.0 else "east"],
			previous,
			west_ledge if side < 0.0 else east_ledge
		)

	# --- The gantries and the two nests (2026-09-24) -----------------------
	#
	# [b]The ledges were two dead ends.[/b] Once the crates made them reachable, each
	# was 36 m of high ground with one way on and every way off being down: a player
	# who climbed one had nowhere to go but back into the room. Two gantries now cross
	# the room between them at ledge height, north and south of the raised middle, so
	# the upper level is a LOOP — ledge, gantry, ledge, gantry — and holding it is a
	# matter of moving along it rather than standing at the top of a stair.
	#
	# Each gantry passes one of the two pillars that stand north and south of the
	# middle, and carries a single 0.9 m step against it. The pillar's top is 5.0,
	# 1.4 over the gantry and so out of reach from it; the step makes it 0.9 then 0.5,
	# and the two pillar tops become the map's third tier — a 3 m nest over the middle
	# that sees both ledges, both gantries and the whole floor, and that every one of
	# those sees back. The other two pillars stay out of reach on purpose: they stand
	# beside the crate stacks, and a nest there would be a nest at the top of the
	# route up, which is the one place on this map a nest should not be.
	#
	# [b]Point-symmetric, like everything else on this map.[/b] The north gantry and
	# its nest are the south gantry and its nest turned half a circle about the
	# origin, so every spawn still scores identically for the spawn selector — the
	# property dm_box exists for. `headless_match` asserts the whole box list is its
	# own half-turn rather than trusting this paragraph.
	#
	# The gantry is 2.5 m wide and flush with the pillar's face, so the step can sit on
	# it against the pillar and still leave 1.5 m of walkway beside it; set 0.5 m off
	# the pillar instead, the step would have had to hang over that half metre of air
	# or leave a slot between gantry and pillar that looks, from the floor, like a way
	# up. Its far edge is 0.5 m clear of the nearest crate stack, which is what stops a
	# player jumping up the first crate from striking their head on it.
	const GANTRY_Y := 3.0
	const GANTRY_T := 0.6
	const GANTRY_W := 2.5
	const NEST_STEP := 0.9

	for side in [-1.0, 1.0]:
		# side -1 is the north gantry (z -10.5..-8), side +1 its turn about the origin.
		var gantry := AABB(
			Vector3(west_ledge.end.x, GANTRY_Y, 8.0 if side > 0.0 else -8.0 - GANTRY_W),
			Vector3(east_ledge.position.x - west_ledge.end.x, GANTRY_T, GANTRY_W)
		)
		# The pillar this gantry passes: (4, -12) for the north one, (-4, 12) for the
		# south. Its face toward the middle is the gantry's outer edge.
		var pillar := AABB(
			Vector3(side * -4.0 - 1.5, 0.0, side * 12.0 - 1.5), Vector3(3.0, 5.0, 3.0)
		)
		var step := AABB(
			Vector3(pillar.position.x, GANTRY_Y, 9.5 if side > 0.0 else -10.5),
			Vector3(3.0, GANTRY_T + NEST_STEP, 1.0)
		)

		map.add_box(gantry)
		map.add_box(step)

		var which := "south" if side > 0.0 else "north"

		map.add_climb("dm_box: the west ledge onto the %s gantry" % which, west_ledge, gantry)
		map.add_climb("dm_box: the %s gantry onto the east ledge" % which, gantry, east_ledge)
		map.add_climb("dm_box: the east ledge onto the %s gantry" % which, east_ledge, gantry)
		map.add_climb("dm_box: the %s gantry onto the west ledge" % which, gantry, west_ledge)
		map.add_climb("dm_box: the %s gantry onto its nest step" % which, gantry, step)
		map.add_climb("dm_box: the %s nest step onto the pillar" % which, step, pillar)

	# --- The two nest stairs (2026-09-29) ----------------------------------
	#
	# [b]Every way onto the upper loop was a jump, and every one was at a wall.[/b] The
	# crates stand against the ledges at x ±17, so the loop could be joined only at its
	# two ends, by somebody who could chain four jumps, and never from the middle of the
	# room where most of the fighting is. A stair is the walked way up: slower to read
	# from the top, open to anybody, and in the open.
	#
	# Ten treads of 0.36 — under `DotFpsTunables.step_height` (0.4), so held forward
	# climbs it; the number and the reason are dm_atrium's and dm_pit's — each 0.9 deep,
	# running along the gantry's outer face and climbing TOWARD the nest pillar. The last
	# tread is at 3.6, flush with the gantry beside it, and its far face is flush with the
	# pillar's west face at x 2.5.
	#
	# [b]Ending against the pillar is the load-bearing decision.[/b] A stair running
	# beside a gantry ends in air if it ends anywhere else: a player running up it at
	# 9 m/s leaves the top tread before they have turned onto the walkway, which reads as
	# the stair throwing them off. Against the pillar the run ends at a wall, the gantry
	# is one step to the side, and the nest step is 0.9 above it. That is also the trade:
	# the stair climbs straight at the nest, so whoever holds the nest looks down the
	# whole of it — `headless_match` traces that — and the fastest way to the third tier
	# is the most watched 9 m on the map.
	#
	# 3 m wide, z -13.5..-10.5, the pillar's own width: narrower would leave a lip of
	# pillar face at the top that is a corner to catch on, and it keeps the floor between
	# the stair and the north wall 10.5 m wide, well clear of the spawn at (0, -18).
	#
	# [b]Built as the north stair and its half-turn, not as two stairs.[/b] The half-turn
	# of a box is computed from the box, so the property this map ships for — every box
	# has a twin turned about the origin — holds by construction rather than by two
	# lists of numbers agreeing.
	const STAIR_TREADS := 10
	const STAIR_RISE := 0.36
	const STAIR_DEPTH := 0.9
	const STAIR_Z := -13.5
	const STAIR_W := 3.0
	const STAIR_TOP_X := 2.5

	for index in range(STAIR_TREADS):
		var tread := AABB(
			Vector3(
				STAIR_TOP_X - float(STAIR_TREADS - index) * STAIR_DEPTH, 0.0, STAIR_Z
			),
			Vector3(STAIR_DEPTH, STAIR_RISE * float(index + 1), STAIR_W)
		)
		map.add_box(tread)
		map.add_box(AABB(Vector3(-tread.end.x, 0.0, -tread.end.z), tread.size))

	# --- The two corner stairs (2026-10-02) --------------------------------
	#
	# [b]Each ledge ended in a stub.[/b] The gantries meet the ledges at |z| 8..10.5 and
	# the ledges run on to |z| 18, so every ledge carried 7.5 m of high ground past its
	# last junction that led nowhere: walked into, it was a corner to be cornered in. And
	# the floor at the two ends of the room — where three of the eight spawns stand — had
	# only the nest stairs, which climb toward the middle. The corner stair is the end
	# zone's way up the other way, out to the wall: ten treads of 0.36 (walked, the
	# number every stair here uses), 0.9 deep and 3 m wide, along the north wall from
	# x -8.5 climbing WEST to a landing that carries the west ledge on into the corner.
	#
	# [b]The landing is the load-bearing box.[/b] The top tread meets it flush at x -17.5
	# and the landing runs on to the west wall, so a run up the stair ends against a wall
	# 6.5 m on, standing at ledge height, and the ledge is one turn south. Without it the
	# stair ends in the air beside the ledge's stub and a player running up it at 9 m/s
	# drops 3.6 m into the corner. It is a box from 3.0 like the ledge it extends, so the
	# corner under it stays floor — a 3 m pocket open to the south.
	#
	# The trade: the stair runs along the wall in the open end of the room, and the north
	# nest looks down every tread of it. Half-turned for the south-east corner, so the
	# property dm_box ships for holds by construction; the other two corners keep their
	# stubs, which is what a half-turn rather than a mirror gives.
	const CORNER_TREADS := 10
	const CORNER_RISE := 0.36
	const CORNER_DEPTH := 0.9
	const CORNER_W := 3.0

	var corner_landing := AABB(
		Vector3(-map.extent, GANTRY_Y, -map.extent),
		Vector3(west_ledge.size.x, GANTRY_T, west_ledge.position.z + map.extent)
	)
	map.add_box(corner_landing)
	map.add_box(AABB(
		Vector3(-corner_landing.end.x, corner_landing.position.y, -corner_landing.end.z),
		corner_landing.size
	))

	for index in range(CORNER_TREADS):
		var tread := AABB(
			Vector3(
				corner_landing.end.x + float(CORNER_TREADS - 1 - index) * CORNER_DEPTH,
				0.0,
				-map.extent
			),
			Vector3(CORNER_DEPTH, CORNER_RISE * float(index + 1), CORNER_W)
		)
		map.add_box(tread)
		map.add_box(AABB(Vector3(-tread.end.x, 0.0, -tread.end.z), tread.size))

	map.add_perimeter()

	# Eight spawns around the outside, facing the middle. Enough that a full server is
	# not spawning two people on one point, and far enough apart that the
	# furthest-from-danger rule has something to choose between.
	# Tagged by hemisphere rather than alternately, so a team mode starts the two
	# sides at opposite ends rather than interleaved around one circle.
	for index in range(8):
		var angle := TAU * float(index) / 8.0
		var at := Vector3(cos(angle) * 18.0, 0.1, sin(angle) * 18.0)
		var facing := -at.normalized()
		# The two on the x axis stand a metre from the foot of the tallest crate (2.7 m,
		# x 14.5..17, z -1..1.5), so "facing the middle" is a spawn with its nose against a
		# wall at eye height (found by looking at a respawn frame). Turn them along the
		# wall instead, the half-turn twin of each other so the map stays symmetric.
		if absf(at.z) < 0.01:
			facing = Vector3(0.0, 0.0, -signf(at.x))
		map.add_spawn(
			Transform3D(Basis.looking_at(facing, Vector3.UP), at),
			&"red" if index < 4 else &"blue"
		)

	# No toys: a deathmatch map keeps its floor clear (ArenaTestToys gives the tests theirs).
	# Packs (health either side of the middle, ammo north and south): clear of every box, off the spawns.
	map.add_pack(PACK_HEALTH, Vector3(-8.0, 0.0, 0.0))
	map.add_pack(PACK_HEALTH, Vector3(8.0, 0.0, 0.0))
	map.add_pack(PACK_AMMO, Vector3(0.0, 0.0, -8.0))
	map.add_pack(PACK_AMMO, Vector3(0.0, 0.0, 8.0))

	return map
