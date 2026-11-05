extends "arena_map_part1.gd"

## The second arena: an open-roofed building in a yard, and three ways onto its roof.
##
## [b]Deliberately not a variation on `dm_box`, and `dm_box` was deliberately not
## extended.[/b] That map is symmetric on purpose — every spawn scores identically for
## the spawn selector, which is the tie its name-based tie-break exists for — so growing
## a wing onto it would take away the one property it is there to hold. This is the
## other half of that: asymmetric, vertical, and with routes that are not each other's
## mirror.
##
## The shape is one central building whose roof is a ring around an open shaft. Standing
## on the ring you can shoot down into the middle; standing in the middle you can be
## shot from four sides, and the two doorways are the only way out at floor level. That
## is the whole map — everything else is a way of getting up there:
##
## - [b]the north-west stair[/b], eight steps, walkable, the route that costs nothing
##   and is the one everybody can see you take;
## - [b]the south-east crates[/b], five jumps, faster, and it leaves you on the far
##   side from the stair. [b]Three jumps until 2026-09-22, and unclimbable for every
##   one of those days[/b] — the steps were 1.5 m against a 1.25 m jump apex;
## - [b]the north-east perch[/b], reached only from the roof by three 0.7 m hops. It
##   looks over the shaft from above the ring, and it is the only place on the map with
##   no cover at all — the trade the height is paid for.
##
## The south-west bunker is the ground-level answer to all of it: three walls at chest
## height, open to the west, the one place a player can break line of sight from the
## roof without leaving the yard — and since the arcade was added, the one place that
## leads somewhere.
##
## [b]The south arcade[/b] is the map's second layer and the reason the bunker is worth
## walking to. A colonnade 25 m long and 5 m deep runs east from a doorway cut in the
## bunker's east wall to the foot of the south-east crates, roofed at 3.6 and carried on
## piers that stand only at its two long edges. It is cover from the ring and from
## nothing else. Its roof is a firing position 0.4 m below the ring, reached by a ten
## tread stair at the back of the yard or by stepping across from the crates.
##
## [b]The north-west keep[/b] (2026-09-27) is the same answer for the other half: until
## it, all the ground the ring cannot see was in the south, which is blue's. A roofed
## room with a doorway at each end and a firing slit to the west, and a roof at 5.5 --
## over the ring -- reached by one jump west off the ring's north arm.
static func dm_atrium() -> ArenaMap:
	var map := ArenaMap.new()
	map.id = &"dm_atrium"
	map.display_name = "dm_atrium"
	map.extent = 30.0
	map.wall_height = 12.0

	# --- The building ------------------------------------------------------
	#
	# A square ring of wall, 20 m across the outside, 1.5 m thick, 4 m tall, with one
	# 6 m doorway in the middle of each side. Built as eight segments rather than four
	# walls with holes in them, because a hole is not a box and everything downstream
	# of this list understands only boxes.
	const WALL_H := 4.0
	const WALL_T := 1.5

	# North and south, split around a doorway from x -3 to 3.
	for z in [-10.0, 8.5]:
		map.add_box(AABB(Vector3(-10.0, 0.0, z), Vector3(7.0, WALL_H, WALL_T)))
		map.add_box(AABB(Vector3(3.0, 0.0, z), Vector3(7.0, WALL_H, WALL_T)))

	# West and east, split around a doorway from z -3 to 3.
	for x in [-10.0, 8.5]:
		map.add_box(AABB(Vector3(x, 0.0, -8.5), Vector3(WALL_T, WALL_H, 5.5)))
		map.add_box(AABB(Vector3(x, 0.0, 3.0), Vector3(WALL_T, WALL_H, 5.5)))

	# The roof, as a ring 4 m wide with a 12 x 12 shaft open in the middle. Overhangs
	# the wall inward by 2.5 m, so a player on the ring is standing over the room and
	# a player in the room has to step out from under it to shoot back.
	var ring_south := AABB(Vector3(-10.0, WALL_H, 6.0), Vector3(20.0, 0.6, 4.0))

	map.add_box(AABB(Vector3(-10.0, WALL_H, -10.0), Vector3(20.0, 0.6, 4.0)))
	map.add_box(ring_south)
	map.add_box(AABB(Vector3(-10.0, WALL_H, -6.0), Vector3(4.0, 0.6, 12.0)))
	map.add_box(AABB(Vector3(6.0, WALL_H, -6.0), Vector3(4.0, 0.6, 12.0)))

	# A plinth under the shaft. Something to land on from the ring, and the only cover
	# inside a room with four doorways pointed at it.
	map.add_box(AABB(Vector3(-3.0, 0.0, -3.0), Vector3(6.0, 1.0, 6.0)))

	# --- North-west stair --------------------------------------------------
	#
	# Thirteen steps of 0.36, which is under `DotFpsTunables.step_height` (0.4) and so
	# is walked rather than jumped — the point of this route being the one that costs
	# nothing. [b]Measured, not assumed:[/b] the first draft used 0.6 and a bot holding
	# forward stopped dead against the first tread, four seconds of walking for 0.8 m of
	# travel, which is what `headless_match` now catches.
	#
	# Each step is a full-height box rather than a tread, because a tread with air under
	# it is two boxes and the analytic body would let a player stand in the gap.
	#
	# [b]The top tread is flush with the building's west face, x = -10.[/b] It stopped
	# 0.75 m short until 2026-09-24, which left a 0.75 m slot between the stair's end
	# and the wall's north segment — narrower than the 0.8 m a player is, and running
	# from the yard straight to the west doorway, so from the ground it read as a way
	# in. `[gate-sweep-1]`'s slot rule found it. Flush, the walk onto the ring is a
	# step across with no air under it as well.
	for index in range(13):
		map.add_box(AABB(
			Vector3(-19.75 + float(index) * 0.75, 0.0, -4.0),
			Vector3(0.75, 0.36 * float(index + 1), 4.0)
		))

	# --- South-east crates -------------------------------------------------
	#
	# [b]Rebuilt 2026-09-22, because the route this map advertises as its fast way up
	# has never once been climbed.[/b] It was three crates at 1.5, 3.0 and 4.6, and
	# every one of those steps is a 1.5 m rise against a jump whose APEX is 1.25 — so
	# a player could not get onto the first crate, let alone the roof. Nothing caught
	# it in the year it stood there: the box count was right, the three
	# representations agreed, no spawn was buried in it, and not one check in the
	# suite had ever asked a bot to climb it. See [method jump_reach] and `[reach-1]`.
	#
	# Five crates now, 0.9 m apart, each 0.5 m of clear air north of the last. That is
	# 72% of [method climb_limit] per step and a tenth of the reach per gap, so the
	# route is a rhythm rather than a series of stretches — which is what "the fast way
	# up" was always supposed to mean. It costs two more crates and it is the first
	# version of this route a player can use.
	#
	# The stack climbs NORTH up the east side rather than north-west across the corner,
	# for the join below: the fourth crate's top is 3.6, the arcade roof's top is 3.6,
	# and they stand 0.5 m apart. The arcade's east end is a step across at the same
	# height in both directions, which is what that route was always documented to be
	# and what a stack of the wrong heights had quietly made one-way.
	# [b]A straight column rather than a diagonal across the corner, and that was a
	# bot's doing.[/b] The first rebuild stepped 1 m west as well as 4 m north per
	# crate, which is a 14° diagonal, and a bot aimed down it reached the third crate
	# and walked off the west edge of the fourth — 2.5 m of shared face is plenty to
	# land on and not enough to keep walking along when the surface under you keeps
	# moving sideways. A column is a route a player can hold one key down and climb,
	# which is what "the fast way up" has to mean before it can mean anything else.
	var crates: Array[AABB] = []

	for step in range(4):
		crates.append(AABB(
			Vector3(12.5, 0.0, 24.0 - float(step) * 4.0),
			Vector3(3.5, 0.9 * float(step + 1), 3.5)
		))
		map.add_box(crates[step])

	# [b]The landing: the fifth step up, and a platform rather than a fifth crate.[/b]
	# It is 6 m by 5.5 at 4.5, filling the outside of the building's south-east corner
	# and touching the roof ring along the whole 4 m of its south arm that reaches x
	# 10. A crate the size of the other four would have been the same height and still
	# useless: a bot that climbed it stood at z 11.4 — a metre and a half south of the
	# band of the ring that is actually adjacent — and walked west off it into the
	# yard, which is exactly what happened on the first attempt at this. A route's last
	# step has to overlap what it joins, not merely reach its height near it.
	#
	# It must not be wider still: the column has to stand clear of the arcade's east
	# end, and a box reaching further south would bury the last pier and grow through
	# the arcade roof.
	var landing := AABB(Vector3(10.0, 0.0, 6.0), Vector3(6.0, 4.5, 5.5))

	map.add_box(landing)

	map.add_climb("dm_atrium: the yard onto the first crate", _floor_at(0.0), crates[0])

	for step in range(1, 4):
		map.add_climb(
			"dm_atrium: crate %d onto crate %d" % [step, step + 1],
			crates[step - 1],
			crates[step]
		)

	map.add_climb("dm_atrium: the top crate onto the landing", crates[3], landing)

	# --- North-east perch --------------------------------------------------
	#
	# Only from the roof, and only by jumping: 4.6 -> 5.3 -> 6.0 -> 6.7. Nothing on the
	# ground reaches it, which is what stops it being the place everyone stands.
	var perch_boxes: Array[AABB] = [
		AABB(Vector3(11.0, 0.0, -9.0), Vector3(2.5, 5.3, 3.0)),
		AABB(Vector3(13.5, 0.0, -9.0), Vector3(2.5, 6.0, 3.0)),
		AABB(Vector3(16.0, 0.0, -12.0), Vector3(5.0, 6.7, 8.0)),
	]

	for box in perch_boxes:
		map.add_box(box)

	# 4.6 -> 5.3 -> 6.0 -> 6.7, all off the ring's east arm. These three were the only
	# climbs on this map that were ever inside what the movement can do, which is why
	# the sweep in `headless_match` has to cover the routes that LOOK fine as well as
	# the ones somebody is suspicious of.
	map.add_climb(
		"dm_atrium: the ring onto the first perch step",
		AABB(Vector3(6.0, WALL_H, -6.0), Vector3(4.0, 0.6, 12.0)),
		perch_boxes[0]
	)
	map.add_climb("dm_atrium: the perch's second step", perch_boxes[0], perch_boxes[1])
	map.add_climb("dm_atrium: the perch itself", perch_boxes[1], perch_boxes[2])

	# The top of the crates onto the roof ring's south-east corner. 0.1 m, which is
	# under `step_height` and is therefore walked — a route that ends in a jump you
	# might miss is a route that ends at the bottom of it.
	map.add_climb("dm_atrium: the landing onto the roof ring", landing, ring_south)

	# --- South-west bunker -------------------------------------------------
	#
	# Three walls at 2.5, open to the west. Was the only ground-level cover from the
	# ring; since the arcade below it is the west end of a covered route rather than a
	# dead end, and its east wall is split around a 4 m doorway at z 14..18 to let that
	# route through. The doorway is exactly the arcade's clear span between piers, so a
	# player leaving the bunker is under cover the moment they are through it.
	map.add_box(AABB(Vector3(-24.0, 0.0, 8.0), Vector3(12.0, 2.5, 1.2)))
	map.add_box(AABB(Vector3(-24.0, 0.0, 19.0), Vector3(12.0, 2.5, 1.2)))
	map.add_box(AABB(Vector3(-13.2, 0.0, 8.0), Vector3(1.2, 2.5, 6.0)))
	map.add_box(AABB(Vector3(-13.2, 0.0, 18.0), Vector3(1.2, 2.5, 2.2)))

	# --- The south arcade --------------------------------------------------
	#
	# [b]Added because the map had one answer to the roof and it was "do not be in the
	# yard".[/b] Everything above is a way UP; the ring overhangs, sees the whole yard,
	# and the bunker was the only square of ground it cannot see -- a corner to hide in
	# with nowhere to go from it. The arcade is the missing half: 25 m of roofed ground
	# running east from that bunker to the foot of the south-east crates, so the route
	# from the map's safest corner to its fastest way up is under cover for all of it.
	#
	# [b]A colonnade rather than a tunnel, and that is the whole balance of it.[/b] The
	# piers stand at the two long edges only, so the arcade is opaque from ABOVE and
	# open from the SIDES: it beats the ring and it does not beat a player standing in
	# the yard beside it. A solid box here would have been a safe corridor across the
	# middle of the map, which is a worse map than no corridor at all.
	#
	# Its roof is the second thing it is for. The top face is 3.6 -- deliberately 0.4
	# UNDER the building's ring at 4.0 -- so the arcade roof is a firing position that
	# overlooks the south yard and is itself overlooked. Whoever holds the ring still
	# holds the map; they now have somewhere to be shot at from.
	#
	# Three ways on and off it, and none of them is the same as another:
	#
	# - [b]the south stair[/b], ten treads of 0.36, walked rather than jumped, out in
	#   the open at the back of the yard and the slowest thing on the map;
	# - [b]the east end[/b], a step across onto the fourth south-east crate, level with
	#   it, which joins the arcade to the five-jump route to the ring;
	# - [b]down[/b], anywhere, which is what stops the roof being a place to camp.
	const ARC_X := -13.2
	const ARC_W := 25.2
	const ARC_Z := 13.0
	const ARC_D := 5.0
	const ARC_Y := 3.0
	const ARC_T := 0.6
	const PIER := 1.5

	var arcade_roof := AABB(Vector3(ARC_X, ARC_Y, ARC_Z), Vector3(ARC_W, ARC_T, ARC_D))

	map.add_box(arcade_roof)

	# [b]The east end, in both directions.[/b] The arcade roof's top is 3.6 and so is
	# the fourth crate's, and they stand 0.5 m apart — declared as two climbs rather
	# than one because a route is not symmetric just because its geometry is: a step
	# ACROSS is a rise of zero each way here, and the day either top face moves this
	# says so twice. Before the crates were rebuilt this join went down 0.6 onto a
	# crate at 3.0 and could not be climbed back, which made the arcade a one-way
	# street that the map's own notes described as a connection.
	map.add_climb("dm_atrium: the arcade roof onto the crates", arcade_roof, crates[3])
	map.add_climb("dm_atrium: the crates onto the arcade roof", crates[3], arcade_roof)

	# Five piers on each long edge. 4 m of daylight between them, which is wider than
	# the building's doorways -- the arcade is meant to be shot into, and a colonnade
	# you cannot see through is the tunnel this is not.
	#
	# [b]The last pair is flush with the crate column, x 11 to 12.5.[/b] It stood at
	# 10.5 to 12 until 2026-09-24, half a metre short of the crates, which left two 0.5
	# m slots between pier and crate that looked from inside the arcade like its east
	# way out and that no player fits through. `[gate-sweep-1]`'s slot rule found both.
	# The half metre of pier past the roof's end sits in the gap the step across to the
	# crates jumps, 0.6 m under it, where nothing can stand.
	for index in range(5):
		var pier_x := -11.0 + float(index) * 5.5

		map.add_box(AABB(Vector3(pier_x, 0.0, ARC_Z), Vector3(PIER, ARC_Y, PIER)))
		map.add_box(AABB(
			Vector3(pier_x, 0.0, ARC_Z + ARC_D - PIER), Vector3(PIER, ARC_Y, PIER)
		))

	# The south stair. Ten treads of 0.36 climbing north, the last one's north face
	# flush with the arcade roof's south edge at z 18 -- a stair that stops half a metre
	# short is a stair with a hole at the top of it, which reads as falling through the
	# map. 0.36 rather than anything larger for the reason the north-west stair gives:
	# it is under `DotFpsTunables.step_height`, so it is WALKED, and a bot holding
	# forward climbs it instead of stopping dead against the first tread.
	for index in range(10):
		map.add_box(AABB(
			Vector3(-10.0, 0.0, 26.1 - float(index) * 0.9),
			Vector3(4.0, 0.36 * float(index + 1), 0.9)
		))

	# --- The north-west keep -----------------------------------------------
	#
	# [b]Added 2026-09-27 (1.4.0), because the arcade answered the roof for one half of
	# the map only.[/b] Spawns here are tagged by the sign of z, and every piece of
	# ground cover the ring cannot see -- the bunker, the arcade -- is in the south,
	# blue's half. Red started in a 60 x 20 m north yard with the ring on one side, the
	# perch on the other and nothing to stand behind. The keep is red's answer, and it
	# is not the arcade again: a closed room rather than a colonnade, and its roof is a
	# high point rather than a tier under the ring.
	#
	# - [b]Inside[/b], a 4.5 x 10 m room with a doorway at each end, north to the yard
	#   and south to the foot of the north-west stair. Roofed, so nothing on the ring or
	#   the perch sees into it, and walled, so the only way to shoot into it is down a
	#   doorway -- which is what makes it cover rather than a shed.
	# - [b]On top[/b], a 6.5 x 12 m roof at 5.5, 0.9 over the ring, so whoever holds the
	#   ring is no longer the highest person in the north-west. Reached from the
	#   ring's north arm, by a 2 m jump west across the alley. Nothing on the ground
	#   climbs it, which is what stops the room below and the roof above being one
	#   position held from both ends.
	#
	# [b]The two gaps are the load-bearing numbers.[/b] The alley between the keep and
	# the building is 2 m and the lane between the keep and the stair is 2 m. Either one
	# under 0.8 is a slot nothing can walk through (`[gate-sweep-1]`); either one past
	# [method jump_reach] of a 0.9 m rise (4.6 m) is a roof nobody reaches. 2 m is a
	# walkable alley from below and one easy jump from above. It is also why the keep
	# is not flush with the building: a keep flush with it is a 0.9 m step up off the
	# ring with nothing to jump, which makes the roof part of the ring.
	#
	# No spawn was added: five red and five blue is what this map ships, and red's
	# (-25, -22) is a ten-second walk from the north doorway already.
	const KEEP_X := -18.5
	const KEEP_W := 6.5
	const KEEP_Z := -18.0
	const KEEP_D := 12.0
	const KEEP_H := 4.9
	const KEEP_T := 1.0
	const KEEP_DOOR := 2.5
	const KEEP_DOOR_H := 3.0
	const KEEP_ROOF := 0.6

	# The doorway's west jamb, so the door is centred on the keep's width.
	var door_x := KEEP_X + (KEEP_W - KEEP_DOOR) * 0.5
	var jamb_w := (KEEP_W - KEEP_DOOR) * 0.5

	# North and south faces, each split around its doorway with a lintel over it.
	for z in [KEEP_Z, KEEP_Z + KEEP_D - KEEP_T]:
		map.add_box(AABB(Vector3(KEEP_X, 0.0, z), Vector3(jamb_w, KEEP_H, KEEP_T)))
		map.add_box(AABB(
			Vector3(door_x + KEEP_DOOR, 0.0, z), Vector3(jamb_w, KEEP_H, KEEP_T)
		))
		map.add_box(AABB(
			Vector3(door_x, KEEP_DOOR_H, z),
			Vector3(KEEP_DOOR, KEEP_H - KEEP_DOOR_H, KEEP_T)
		))

	# The east face, solid, between the two ends. It looks across the 2 m alley at the
	# building's wall, and an opening there would be one nobody can use.
	map.add_box(AABB(
		Vector3(KEEP_X + KEEP_W - KEEP_T, 0.0, KEEP_Z + KEEP_T),
		Vector3(KEEP_T, KEEP_H, KEEP_D - 2.0 * KEEP_T)
	))

	# [b]The west face has a firing slit, and the two heights are the whole design of
	# it.[/b] Solid, this face was a blank 12 m wall -- the first render showed a room
	# that reads from outside exactly like a block. The slit is 4 m long at eye height:
	# the sill at 1.2 is OVER [method climb_limit] (1.125), so nobody vaults through it
	# and the keep keeps two ways in; the opening is 0.8, UNDER a crouching player
	# (0.9), so the sill is not a ledge anybody can crouch in either. Measured: at 1.0
	# the survey finds 3 m² of sill it can reach, which is a shelf inside a wall that
	# nobody designed. It
	# faces the west yard and the foot of the stair, which is where somebody coming for
	# the keep on foot comes from.
	const SLIT_Z := KEEP_Z + KEEP_D * 0.5 - 2.0
	const SLIT_L := 4.0
	const SLIT_SILL := 1.2
	const SLIT_TOP := 2.0

	map.add_box(AABB(
		Vector3(KEEP_X, 0.0, KEEP_Z + KEEP_T),
		Vector3(KEEP_T, KEEP_H, SLIT_Z - KEEP_Z - KEEP_T)
	))
	map.add_box(AABB(
		Vector3(KEEP_X, 0.0, SLIT_Z + SLIT_L),
		Vector3(KEEP_T, KEEP_H, KEEP_Z + KEEP_D - KEEP_T - SLIT_Z - SLIT_L)
	))
	map.add_box(AABB(Vector3(KEEP_X, 0.0, SLIT_Z), Vector3(KEEP_T, SLIT_SILL, SLIT_L)))
	map.add_box(AABB(
		Vector3(KEEP_X, SLIT_TOP, SLIT_Z), Vector3(KEEP_T, KEEP_H - SLIT_TOP, SLIT_L)
	))

	# The roof covers the walls' tops as well as the room, so no wall top is a ledge.
	var keep_roof := AABB(
		Vector3(KEEP_X, KEEP_H, KEEP_Z), Vector3(KEEP_W, KEEP_ROOF, KEEP_D)
	)

	map.add_box(keep_roof)

	# The ring's north arm onto the roof: 0.9 up, 2 m across, west. Read off the boxes;
	# the arm here is the same AABB the roof ring was built with above.
	map.add_climb(
		"dm_atrium: the ring's north arm onto the keep",
		AABB(Vector3(-10.0, WALL_H, -10.0), Vector3(20.0, 0.6, 4.0)),
		keep_roof
	)

	# --- The east stair ------------------------------------------------------
	#
	# [b]Added 2026-10-01 (1.5.0), because the east yard was the one part of this map
	# with no way up of its own.[/b] A player in the 14 x 10 m yard between the perch and
	# the landing -- spawn (26, -4) stands in it -- had the north-west stair 40 m away
	# or the crates' five jumps round the corner. Twelve treads of 0.36 now climb SOUTH
	# from the yard floor at z = -4 to the landing's north face at z = 6, 3 m wide at x
	# 13..16: walked, not jumped, the number dm_box's and dm_pit's stairs use.
	#
	# [b]Ending flush against the landing is the load-bearing decision.[/b] The top
	# tread is 4.32, 0.18 under the landing, so a player holding forward walks off the
	# stair onto it without a jump and the landing's own 0.1 step puts them on the
	# ring. Stopped short, the run leaves the top tread into the corridor behind it.
	#
	# [b]The trade is the perch.[/b] The perch's top is 2.4 m over the top tread and 2 m
	# north-east of the foot, so whoever holds it looks down the whole stair -- the walked
	# way up from the east yard is the most watched one, like the nest stairs on
	# dm_box. And it stands 3 m off the building's east wall, so the east doorway opens
	# onto a 3 m corridor rather than closing; 2 m clear of the perch's first steps, so
	# the foot is a pocket a player fits in rather than a slot.
	#
	# No spawn was added or moved: (26, -4) is 10 m east of the foot already.
	const EAST_STAIR_X := 13.0
	const EAST_STAIR_W := 3.0
	const EAST_STAIR_Z := -4.0
	const EAST_STAIR_TREADS := 12
	var east_tread := (landing.position.z - EAST_STAIR_Z) / float(EAST_STAIR_TREADS)

	for index in range(EAST_STAIR_TREADS):
		map.add_box(AABB(
			Vector3(EAST_STAIR_X, 0.0, EAST_STAIR_Z + float(index) * east_tread),
			Vector3(EAST_STAIR_W, 0.36 * float(index + 1), east_tread)
		))

	# --- The rampart (1.6.0) -----------------------------------------------
	#
	# Added 2026-10-04. [b]The perch had one way on and the keep's roof had none
	# off.[/b] The perch (6.7) was reached only from the ring's east arm, up its two
	# steps, so whoever held it watched one approach; the keep's roof (5.5) was a high
	# point a player jumped onto and then had nowhere to go from but down. The
	# rampart is a 3 m walkway across red's half that joins them: from the keep roof's
	# east edge (x = -12) to the perch's north-east corner (x = 21), along z -15..-12,
	# 2 m north of the ring's north arm and flush with the perch's north face.
	#
	# [b]Every number is a step or a hop the map already uses.[/b] Its top is the keep
	# roof plus 0.36 (5.86), so walking off the roof onto it is the walked rise every
	# stair here is built from, and the perch is a 0.84 hop off its east end — the same
	# size as the ring-to-shelf and gantry-to-nest hops on the other two maps. From the
	# ring it is 1.26 up across a 2 m alley, over the jump's apex: the rampart is
	# joined at its two ends and nowhere along its length, so it is a route rather
	# than a second ring.
	#
	# The trade is the one every way onto a high point makes here: it runs straight
	# at the perch, so whoever holds the perch sees all 33 m of it (`headless_match`
	# traces a chest along its length), and the keep-roof end is the far end of a
	# duel rather than a back door. Three piers carry it, 8 m apart, a metre square
	# and centred under it, so the north yard underneath stays open floor. No spawn
	# was added or moved.
	const RAMPART_Z := -15.0
	const RAMPART_T := 0.6
	const RAMPART_PIER := 1.0

	var rampart_top := keep_roof.end.y + 0.36
	var rampart := AABB(
		Vector3(keep_roof.end.x, rampart_top - RAMPART_T, RAMPART_Z),
		Vector3(
			perch_boxes[2].end.x - keep_roof.end.x, RAMPART_T,
			perch_boxes[2].position.z - RAMPART_Z
		)
	)

	map.add_box(rampart)

	for pier_x in [-4.5, 3.5, 11.5]:
		map.add_box(AABB(
			Vector3(
				pier_x, 0.0,
				rampart.get_center().z - RAMPART_PIER * 0.5
			),
			Vector3(RAMPART_PIER, rampart.position.y, RAMPART_PIER)
		))

	map.add_climb("dm_atrium: the rampart onto the perch", rampart, perch_boxes[2])

	# --- The north gallery (1.7.0) -------------------------------------------
	#
	# Added 2026-10-10, for the wall run and the wall jump. Two ledges against the north
	# wall with a 9 m gap between them, and a chimney up onto the first. Both are
	# shortcuts: each ledge has a walked stair, so the survey (which asks only the
	# ordinary movement) reaches everything, and the walls only make it faster.
	#
	# [b]The gap is crossed by running the north wall and by nothing else.[/b] The high
	# ledge (2.52) runs east to x -18, the low one (1.80) starts at x -6. Measured with
	# the motor (`headless_match`'s *the north gallery, run and climbed*): a plain run
	# and jump lands 3 m short, a slide-jump 5 m short, a dash-jump 1 m short, and a
	# slide-jump onto the wall lands 2 m onto the low ledge. The 0.72 m drop is what the
	# run needs: it levels off and sinks slowly (`wall_run_gravity_scale`), so a run
	# between two ledges of one height arrives below the far top and hits its face.
	# One-way, east, on purpose: back west is the stairs.
	#
	# [b]The chimney is climbed by two wall jumps and by nothing else.[/b] Two arms 2.4 m
	# apart stand out from the high ledge's south face, at the ledge's height, so their
	# tops are part of the ledge and nothing new is standable. 2.52 is over the climb
	# limit (1.125); a jump off one arm and then the other peaks at about 2.9. One jump
	# off each wall is all `wall_jump_max_per_wall` (1) allows, which is why it is two
	# walls and not one.
	#
	# Watched from above, like every way up here: the rampart (5.86) is 11 m south of
	# the ledges and the keep roof (5.5) beside the chimney. No spawn was added or moved.
	const GAL_Z := -30.0
	const GAL_D := 4.0
	const GAL_HIGH := 2.52
	const GAL_LOW := 1.80
	const GAL_TREAD := 0.75

	var gallery_high := AABB(Vector3(-30.0, 0.0, GAL_Z), Vector3(12.0, GAL_HIGH, GAL_D))
	var gallery_low := AABB(Vector3(-9.0, 0.0, GAL_Z), Vector3(15.0, GAL_LOW, GAL_D))
	map.add_box(gallery_high)
	map.add_box(gallery_low)

	# The high ledge's stair: six treads climbing north along the west wall, the top one
	# (2.16) flush with the ledge's south face, one walked step under it.
	for index in range(6):
		map.add_box(AABB(
			Vector3(-30.0, 0.0, gallery_high.end.z + float(5 - index) * GAL_TREAD),
			Vector3(3.0, 0.36 * float(index + 1), GAL_TREAD)
		))

	# The low ledge's stair: four treads down east along the north wall from its end.
	for index in range(4):
		map.add_box(AABB(
			Vector3(gallery_low.end.x + float(index) * GAL_TREAD, 0.0, GAL_Z),
			Vector3(GAL_TREAD, 0.36 * float(4 - index), 3.0)
		))

	# The chimney: the east arm flush with the ledge's east end, so the gap's west face
	# runs on unbroken; 2.4 m between the arms, 3 m deep.
	var chimney_west := AABB(Vector3(-22.4, 0.0, gallery_high.end.z), Vector3(1.0, GAL_HIGH, 3.0))
	var chimney_east := AABB(Vector3(-19.0, 0.0, gallery_high.end.z), Vector3(1.0, GAL_HIGH, 3.0))
	map.add_box(chimney_west)
	map.add_box(chimney_east)

	var north_wall := AABB(Vector3(-32.0, 0.0, -32.0), Vector3(64.0, map.wall_height, 2.0))
	map.add_wall_route("dm_atrium: along the north wall over the gallery gap",
		&"run", gallery_high, gallery_low, [north_wall])
	map.add_wall_route("dm_atrium: up the chimney onto the gallery",
		&"jump", _floor_at(0.0), gallery_high, [chimney_west, chimney_east])

	map.paint_zones.append({
		"name": "gallery",
		"region": AABB(Vector3(-30.5, 0.0, -30.5), Vector3(40.0, 4.0, 9.5)),
		"colour": ArenaMapPaint.AQUA,
	})

	map.add_perimeter()

	# --- Spawns ------------------------------------------------------------
	#
	# Ten, and deliberately NOT on a circle. `dm_box` puts eight on one, which makes
	# every spawn score the same and is the point of that map; here they are scattered
	# around the yard at real distances from each other so the furthest-from-danger rule
	# has something to actually pick. Two are on the roof ring, because a map with three
	# routes up should not make every fight start at the bottom of them.
	var points: Array[Vector3] = [
		Vector3(-25.0, 0.1, -22.0),
		Vector3(-4.0, 0.1, -24.0),
		Vector3(22.0, 0.1, -25.0),
		Vector3(26.0, 0.1, -4.0),
		Vector3(25.0, 0.1, 21.0),
		Vector3(2.0, 0.1, 25.0),
		Vector3(-20.0, 0.1, 23.0),
		Vector3(-26.0, 0.1, 2.0),
		Vector3(-8.0, WALL_H + 0.7, -8.0),
		Vector3(8.0, WALL_H + 0.7, 8.0),
	]

	for at in points:
		# Facing the building, which is where the fight is. Flattened to the horizontal
		# because a spawn looking down at its own feet is a spawn you have to correct
		# before you can play, and the two roof spawns would otherwise do exactly that.
		var to_centre := Vector3(-at.x, 0.0, -at.z)

		if to_centre.length_squared() < 0.001:
			to_centre = Vector3.FORWARD

		# By the sign of z, which on this map is the long axis: the two sides start at
		# opposite ends of the atrium with the building between them. A point sitting on
		# the axis is untagged, so it stays a shared fallback rather than being given
		# arbitrarily to one side.
		var tag := &""

		if at.z < -0.5:
			tag = &"red"
		elif at.z > 0.5:
			tag = &"blue"

		map.add_spawn(
			Transform3D(Basis.looking_at(to_centre.normalized(), Vector3.UP), at), tag
		)

	# The keep is one colour, lavender, the north side's: by the compass alone it would
	# be the west side's pink, which is the stair beside it, and "the keep" and "pink
	# stairs" are two places a player has to be able to tell apart. Paint only.
	map.paint_zones.append({
		"name": "keep",
		"region": AABB(Vector3(-19.0, 0.0, -18.5), Vector3(7.5, 6.0, 13.0)),
		"colour": ArenaMapPaint.LAVENDER,
	})

	# Toys (loose only, see [member toys]): balls in the open courts, barrels by the east
	# wall, tyres in two corners.
	map.toys = [
		{"toy": "beach_ball", "at": [10.0, 0.0, -18.0]},
		{"toy": "beach_ball", "at": [-22.0, 0.0, 12.0]},
		{"toy": "football", "at": [4.0, 0.0, -2.0]},
		{"toy": "barrel", "at": [24.0, 0.0, 10.0]},
		{"toy": "barrel", "at": [24.8, 0.0, 10.7], "yaw": 40.0},
		{"toy": "tyre", "at": [-24.0, 0.0, -12.0], "yaw": 30.0},
		{"toy": "tyre", "at": [8.0, 0.0, 28.0], "yaw": 80.0},
	]
	# Packs (two health, two ammo, off the building): clear of every box, off the spawns.
	map.add_pack(PACK_HEALTH, Vector3(-8.0, 0.0, 0.0))
	map.add_pack(PACK_HEALTH, Vector3(12.0, 0.0, -12.0))
	map.add_pack(PACK_AMMO, Vector3(12.0, 0.0, 0.0))
	map.add_pack(PACK_AMMO, Vector3(-4.0, 0.0, -12.0))

	return map
