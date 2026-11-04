extends "headless_match_part10.gd"

## [b]The second map, walked rather than asserted.[/b]  A map is a rendered, playable thing and this
## family has shipped a 0 x 0 Control twice and a black screen once.
func _test_atrium() -> void:
	_section("dm_atrium")

	var map := ArenaMap.dm_atrium()

	_check(map.boxes.size() > 30, "the map has geometry", str(map.boxes.size()))
	_check(map.spawns.size() == 10, "and ten spawns", str(map.spawns.size()))

	# The catalogue duplication, which is the point of checking it: `ids()` lists names
	# and `by_id()` builds geometry, and a map added to one and not the other either
	# cannot be listed or cannot be loaded.
	var missing: Array[String] = []

	for id in ArenaMap.ids():
		if ArenaMap.by_id(id) == null:
			missing.append(String(id))

	_check(missing.is_empty(), "every listed map id builds", ", ".join(missing))
	_check(ArenaMap.by_id(&"dm_nosuchmap") == null, "and an unknown one does not")

	# One description, three representations — the same invariant `_test_map` checks
	# for dm_box, re-checked here because a second map is a second chance to write the
	# geometry twice.
	_check(
		map.to_fps_body().boxes.size() == map.boxes.size()
		and map.to_trace().boxes.size() == map.boxes.size(),
		"the movement and tracing backends have every box"
	)

	# [b]The shaft is open.[/b] A ray straight up from the plinth must reach the sky and one from
	# under the ring must not; a solid ring would pass every check above.
	var trace := map.to_trace()
	var up_shaft := trace.ray(Vector3(0.0, 2.0, 0.0), Vector3.UP, 40.0)
	var up_ring := trace.ray(Vector3(-8.0, 2.0, 0.0), Vector3.UP, 40.0)

	_check(not (up_shaft.ok() and up_shaft.blocked), "the atrium shaft is open to the sky")
	_check(up_ring.ok() and up_ring.blocked, "and the ring above the walkway is not")

	# [b]The walk.[/b] A controller on the yard floor at the foot of the north-west
	# stair, told to hold forward for four seconds. It has to end up on the roof, which
	# it can only do by climbing the eight steps.
	var walker := ArenaPlayer.new()
	walker.name = "Walker"
	add_child(walker)
	walker.setup(ArenaPlayer.Mode.HEADLESS, map, 9001, "walker")

	var start := Vector3(-22.0, 0.5, -2.0)
	walker.controller.teleport(start)

	var command := DotFpsCommand.new()
	# +X, which is up the stair. Held rather than re-aimed: a bot that steers is a bot
	# whose failure to arrive tells you nothing about the geometry.
	command.yaw = 0.0
	command.move = Vector2(1.0, 0.0)

	var tick_rate := 64
	var delta := 1.0 / float(tick_rate)
	var peak := start.y

	for tick in range(tick_rate * 4):
		walker.controller.apply_command(command)
		walker.controller.simulate_tick(tick, delta)
		peak = maxf(peak, walker.controller.state.position.y)

	var landed := walker.controller.state.position

	_check(
		peak > 4.0,
		"a bot holding forward at the north-west stair reaches the roof",
		"y %.2f -> peak %.2f, ended at (%.1f, %.2f, %.1f)"
			% [start.y, peak, landed.x, landed.y, landed.z]
	)
	_check(
		landed.x > start.x + 4.0,
		"and it got there by moving along the stair rather than up a wall",
		"x %.1f -> %.1f" % [start.x, landed.x]
	)

	# --- The south arcade ---------------------------------------------------  [b]The arcade is
	# COVER, which a box count cannot check.[/b] What makes it an arcade is that the sky is not
	# visible from under it and is visible from beside it.
	var under_arcade := trace.ray(Vector3(0.0, 1.0, 15.5), Vector3.UP, 40.0)
	var beside_arcade := trace.ray(Vector3(0.0, 1.0, 11.0), Vector3.UP, 40.0)
	var above_arcade := trace.ray(Vector3(0.0, 4.0, 15.5), Vector3.UP, 40.0)

	_check(
		under_arcade.ok() and under_arcade.blocked,
		"the south arcade is roofed against the ring above it"
	)
	_check(
		not (beside_arcade.ok() and beside_arcade.blocked),
		"and the yard two metres north of it is open sky"
	)
	_check(
		not (above_arcade.ok() and above_arcade.blocked),
		"and its own roof is a firing position rather than a crawlspace"
	)

	# The doorway cut in the bunker's east wall, checked from both sides of the cut.
	var through_door := trace.ray(Vector3(-18.0, 1.0, 15.5), Vector3.RIGHT, 8.0)
	var into_wall := trace.ray(Vector3(-18.0, 1.0, 10.5), Vector3.RIGHT, 8.0)

	_check(
		not (through_door.ok() and through_door.blocked),
		"the bunker's east wall is open where the arcade meets it"
	)
	_check(
		into_wall.ok() and into_wall.blocked,
		"and is still a wall either side of the doorway"
	)

	# [b]No spawn is inside a solid.[/b] The weaker version of this -- inside the room, above the
	# floor -- is what `_test_map` checks, and a spawn buried in a stair tread passes it.
	var buried := PackedStringArray()

	for index in range(map.spawns.size()):
		var at: Vector3 = map.spawns[index].origin
		var column := AABB(at + Vector3(-0.4, -0.05, -0.4), Vector3(0.8, 1.8, 0.8))

		for box in map.boxes:
			if box.intersects(column):
				buried.append("#%d at %s" % [index, str(at)])
				break

	_check(buried.is_empty(), "and no spawn is inside a solid", ", ".join(buried))

	# [b]The map moved, so the map's version moved, and only this map's.[/b] A record and a rotation
	# cooldown are both about a map AT a version.
	var versions := ArenaMaps.catalogue()

	# [b]All three moved on 2026-09-22, which is the first time that has happened and does not
	# weaken the check.[/b] They moved for one cause — every climb on every map was above the jump
	# apex — but they are still three separate changes to three separate maps.
	var expected := {&"dm_atrium": "1.7.1", &"dm_pit": "1.5.0", &"dm_box": "1.4.0"}
	var wrong := PackedStringArray()

	for id: StringName in expected:
		var def := versions.get_map(id)

		if def == null or def.version != expected[id]:
			wrong.append("%s at %s, wanted %s" % [
				id, "absent" if def == null else def.version, expected[id]
			])

	_check(
		wrong.is_empty(),
		"the catalogue carries every map at the version its geometry is at",
		"; ".join(wrong)
	)
	# [b]Was "two maps that moved by different amounts do not share a version", which is not a rule
	# versions keep.[/b] Two minor bumps on two maps land on the same string whenever they happen to
	# — dm_box went 1.1.0 -> 1.2.0 on 2026-09-24, where dm_atrium had been two days.
	_check(
		versions.get_map(&"dm_box").version != ArenaMaps.MAP_VERSION,
		"and a map that moved is not at the catalogue-wide default"
	)

	# [b]The stair onto the arcade roof, walked.[/b] Same shape as the north-west stair above and
	# for the same reason: ten treads of 0.36 is a number that only means anything once something
	# has climbed it. Driven north (-Z at yaw 0) from the back of the yard.
	walker.controller.teleport(Vector3(-8.0, 0.5, 28.0))

	var north := DotFpsCommand.new()
	north.yaw = 0.0
	north.move = Vector2(0.0, 1.0)

	var roof_peak := 0.5
	var on_roof := false

	for tick in range(tick_rate * 4):
		walker.controller.apply_command(north)
		walker.controller.simulate_tick(tick_rate * 4 + tick, delta)

		var at: Vector3 = walker.controller.state.position
		roof_peak = maxf(roof_peak, at.y)

		if at.y >= 3.5 and at.z >= 12.9 and at.z <= 18.1 and at.x >= -13.2 and at.x <= 12.0:
			on_roof = true

	_check(
		on_roof,
		"a bot walks the south stair onto the arcade roof",
		"peaked at %.2f, roof is at 3.60" % roof_peak
	)
	_check(
		roof_peak < 4.5,
		"and the roof is a tier of its own below the ring rather than part of it",
		"peaked at %.2f, ring is at 4.60" % roof_peak
	)

	# [b]The covered route, walked end to end.[/b] The arcade's whole reason is that a player can
	# get from the bunker to the foot of the crates without the ring seeing them, so the check is a
	# bot that starts inside the bunker, holds east, and comes out the far end.
	walker.controller.teleport(Vector3(-18.0, 0.5, 15.5))

	var east := DotFpsCommand.new()
	east.yaw = 0.0
	east.move = Vector2(1.0, 0.0)

	for tick in range(tick_rate * 6):
		walker.controller.apply_command(east)
		walker.controller.simulate_tick(tick_rate * 8 + tick, delta)

	var emerged: Vector3 = walker.controller.state.position

	_check(
		emerged.x > 8.0,
		"a bot crosses the arcade from the bunker to the crates without stopping",
		"x -18.0 -> %.1f" % emerged.x
	)
	_check(
		emerged.y < 1.0 and absf(emerged.z - 15.5) < 1.5,
		"and does it on the ground, in the lane, rather than over the top",
		"ended at %s" % str(emerged)
	)

	# --- The north-west keep ------------------------------------------------  [b]Cover, asked the
	# way the arcade's is: of the sky and of the ring.[/b] A room is the one shape a box count reads
	# identically whether it is a room or a solid block.
	var in_keep := Vector3(-15.25, 1.0, -12.0)
	var under_keep := trace.ray(in_keep, Vector3.UP, 40.0)
	var ring_eye := Vector3(-8.0, 4.6 + 1.6, -8.0)
	var ring_to_keep := false

	for box in map.boxes:
		if box.intersects_segment(ring_eye, in_keep + Vector3(0.0, 0.6, 0.0)):
			ring_to_keep = true

	_check(
		under_keep.ok() and under_keep.blocked and ring_to_keep,
		"the north-west keep is roofed, and the ring cannot see into it"
	)

	var over_keep := trace.ray(Vector3(-15.25, 5.6, -12.0), Vector3.UP, 40.0)

	_check(
		not (over_keep.ok() and over_keep.blocked),
		"and its roof is open sky, a firing position rather than a ceiling"
	)

	# The west slit: open at eye height, wall at the knee and over the head. A slit
	# that reached the floor would be a third doorway, and one that closed would put
	# back the blank wall the first render of the keep showed.
	var slit_eye := trace.ray(Vector3(-16.0, 1.6, -12.0), Vector3.LEFT, 4.0)
	var slit_knee := trace.ray(Vector3(-16.0, 0.6, -12.0), Vector3.LEFT, 4.0)
	var slit_head := trace.ray(Vector3(-16.0, 2.6, -12.0), Vector3.LEFT, 4.0)

	_check(
		not (slit_eye.ok() and slit_eye.blocked)
			and slit_knee.ok() and slit_knee.blocked
			and slit_head.ok() and slit_head.blocked,
		"and its west wall is a firing slit at eye height, wall above and below"
	)

	# [b]In at the north door and out at the south, walked.[/b] A doorway is a hole in a list of
	# boxes and a hole is invisible, so the only thing that says the room is a room is something
	# passing through it.
	var tunables := ArenaPlayer.arena_tunables()
	var keep_start := Vector3(-15.25, 0.2, -23.0)
	# Where the lane south of the keep ends for a bot holding south: the stair's side
	# at z -4, less the motor's 0.35 m radius.
	var keep_end_z := -4.35
	walker.controller.teleport(keep_start)

	var south := DotFpsCommand.new()
	south.yaw = 0.0
	south.move = Vector2(0.0, -1.0)

	var went_in := false
	var door_north_tick := -1
	var door_south_tick := -1

	for tick in range(tick_rate * 4):
		walker.controller.apply_command(south)
		walker.controller.simulate_tick(tick_rate * 16 + tick, delta)

		var at: Vector3 = walker.controller.state.position

		if at.z > -17.0 and at.z < -7.0 and at.x > -17.5 and at.x < -13.0 and at.y < 1.0:
			went_in = true

		if door_north_tick < 0 and at.z >= -18.0:
			door_north_tick = tick

		if door_south_tick < 0 and at.z >= -6.0:
			door_south_tick = tick

	var out_at: Vector3 = walker.controller.state.position
	var through := float(door_south_tick - door_north_tick) * delta
	var keep_speed := 12.0 / through if door_south_tick > door_north_tick and door_north_tick >= 0 else 0.0

	print("  ..    keep: covered %.1f of the %.1f m route; %.2f m/s door to door against max_speed %.2f"
		% [out_at.z - keep_start.z, keep_end_z - keep_start.z, keep_speed, tunables.max_speed])

	_check(
		went_in and out_at.z > -6.0 and out_at.y < 0.5,
		"a bot walks into the keep at its north door and out at its south",
		"inside %s, ended at %s" % [went_in, str(out_at)]
	)
	_check(
		keep_speed >= tunables.max_speed - 1.0,
		"and does it at running speed, not squeezing through",
		"%.2f m/s against max_speed %.2f" % [keep_speed, tunables.max_speed]
	)

	# [b]The roof, reached the only way it is reached: off the ring's north arm.[/b] Held west along
	# the arm and jump pressed at its west edge, which is what a player does -- holding jump the
	# whole way would bleed the run to the air cap, see `_test_bot_ground_speed`.
	var arm_start := Vector3(-2.0, 4.7, -8.0)
	walker.controller.teleport(arm_start)

	var west := DotFpsCommand.new()
	west.yaw = 0.0
	west.move = Vector2(-1.0, 0.0)

	var on_keep := false
	var takeoff_speed := 0.0
	var takeoff_x := 0.0

	for tick in range(tick_rate * 3):
		var at: Vector3 = walker.controller.state.position
		var jumping := at.x <= -9.4

		if jumping and takeoff_speed == 0.0:
			var v: Vector3 = walker.controller.state.velocity
			takeoff_speed = Vector2(v.x, v.z).length()
			takeoff_x = at.x

		west.set_button(DotFpsCommand.BUTTON_JUMP, jumping)
		walker.controller.apply_command(west)
		walker.controller.simulate_tick(tick_rate * 24 + tick, delta)

		var now: Vector3 = walker.controller.state.position

		if walker.controller.state.is_grounded() and now.y > 5.45 and now.x < -12.0:
			on_keep = true
			break

	var roof_at: Vector3 = walker.controller.state.position

	print("  ..    keep roof: covered %.1f m against the %.1f m to the roof's edge; took off at x %.2f doing %.2f m/s against max_speed %.2f"
		% [arm_start.x - roof_at.x, arm_start.x - (-12.0), takeoff_x, takeoff_speed,
			tunables.max_speed])

	_check(
		on_keep,
		"a bot runs the ring's north arm and jumps the alley onto the keep's roof",
		"ended at (%.1f, %.2f, %.1f), took off at %.2f m/s"
			% [roof_at.x, roof_at.y, roof_at.z, takeoff_speed]
	)

	# --- The east stair (1.5.0) ---------------------------------------------  Read back off the
	# box list: twelve treads at x 13..16, every rise and the step onto the landing under
	# `step_height`, the top tread flush with the landing.
	var east_treads: Array[AABB] = []
	var landing_box := AABB()

	for box in map.boxes:
		if is_equal_approx(box.position.x, 13.0) and is_equal_approx(box.size.x, 3.0) \
				and box.position.y < 0.001:
			east_treads.append(box)
		elif is_equal_approx(box.position.x, 10.0) and is_equal_approx(box.position.z, 6.0) \
				and is_equal_approx(box.size.y, 4.5):
			landing_box = box

	east_treads.sort_custom(func(a: AABB, b: AABB) -> bool: return a.position.z < b.position.z)

	var east_steep := PackedStringArray()
	var east_below := 0.0

	for tread in east_treads:
		if tread.size.y - east_below >= tunables.step_height:
			east_steep.append("%.2f at z %.2f" % [tread.size.y - east_below, tread.position.z])

		east_below = tread.size.y

	if not east_treads.is_empty() and landing_box.size.y - east_treads[-1].size.y >= tunables.step_height:
		east_steep.append("landing lip %.2f" % (landing_box.size.y - east_treads[-1].size.y))

	_check(
		east_treads.size() == 12 and east_steep.is_empty() and landing_box.size.y > 0.0
			and absf(east_treads[-1].end.z - landing_box.position.z) < 0.001,
		"the east stair is twelve walked treads, its top flush with the landing",
		"%d treads, steep: %s, top ends at z %.2f against the landing at %.2f" % [
			east_treads.size(), ", ".join(east_steep),
			east_treads[-1].end.z if not east_treads.is_empty() else 0.0,
			landing_box.position.z
		]
	)

	# Driven: from the yard north of the foot, facing south (yaw 180), forward held and
	# jump never pressed. The pace is foot (z = -4) to grounded on the landing.
	walker.controller.teleport(Vector3(14.5, 0.1, -5.0), 180.0, 0.0)

	var east_foot := -1
	var east_top := -1
	var east_top_z := 0.0
	var east_peak := 0.0

	for tick in range(tick_rate * 3):
		var step := DotFpsCommand.new()
		step.yaw = 180.0
		step.move = Vector2(0.0, 1.0)
		walker.controller.apply_command(step)
		walker.controller.simulate_tick(tick_rate * 40 + tick, delta)

		var at: Vector3 = walker.controller.state.position
		east_peak = maxf(east_peak, at.y)

		if east_foot < 0 and at.z >= -4.0:
			east_foot = tick

		if walker.controller.state.is_grounded() and at.y > 4.45 and at.z > 6.0:
			east_top = tick
			east_top_z = at.z
			break

	var east_time := float(east_top - east_foot) * delta
	var east_pace := (east_top_z + 4.0) / east_time if east_top > east_foot and east_foot >= 0 else 0.0
	var east_end: Vector3 = walker.controller.state.position

	print("  ..    east stair: foot to landing %.1f m in %.2f s, %.2f m/s against max_speed %.2f"
		% [east_top_z + 4.0, east_time, east_pace, tunables.max_speed])

	_check(
		east_top >= 0,
		"a bot walks up the east stair from the yard onto the landing, jump never pressed",
		"ended at (%.1f, %.2f, %.1f), peak %.2f" % [east_end.x, east_end.y, east_end.z, east_peak]
	)
	_check(
		east_pace >= tunables.max_speed - 1.5,
		"and climbs it at running pace",
		"%.2f m/s against max_speed %.2f" % [east_pace, tunables.max_speed]
	)

	# The trade: the perch looks down every tread. From its south-west corner, where
	# somebody watching the east yard stands -- from the middle of it the perch's own
	# edge hides the lower eight treads, which is the edge doing its job.
	var perch_eye := Vector3(16.4, 6.7 + 1.6, -4.4)
	var east_hidden := PackedStringArray()

	for index in range(east_treads.size()):
		var chest := Vector3(14.5, east_treads[index].end.y + 1.2, east_treads[index].get_center().z)
		var line := chest - perch_eye
		var hit := trace.ray(perch_eye, line.normalized(), line.length() - 0.05)

		if hit.ok() and hit.blocked:
			east_hidden.append("tread %d" % (index + 1))

	_check(
		east_hidden.is_empty(),
		"and the perch sees down every tread of it",
		", ".join(east_hidden)
	)

	# --- The rampart (1.6.0) ------------------------------------------------  Read back off the
	# box list: the walkway, the keep roof it leaves, the perch it reaches and the ring's north arm
	# it runs beside.
	var rampart := AABB()
	var keep_top := AABB()
	var perch_top := AABB()
	var north_arm := AABB()

	for box in map.boxes:
		if is_equal_approx(box.position.z, -15.0) and is_equal_approx(box.size.y, 0.6):
			rampart = box
		elif is_equal_approx(box.position.x, -18.5) and is_equal_approx(box.position.y, 4.9):
			keep_top = box
		elif is_equal_approx(box.position.x, 16.0) and is_equal_approx(box.size.y, 6.7):
			perch_top = box
		elif is_equal_approx(box.position.z, -10.0) and is_equal_approx(box.position.y, 4.0) \
				and is_equal_approx(box.size.x, 20.0):
			north_arm = box

	var off_roof := rampart.end.y - keep_top.end.y
	var onto_perch := perch_top.end.y - rampart.end.y
	var from_ring := rampart.end.y - north_arm.end.y

	_check(
		rampart.size.y > 0.0 and keep_top.size.y > 0.0 and perch_top.size.y > 0.0
			and is_equal_approx(rampart.position.x, keep_top.end.x)
			and is_equal_approx(rampart.end.z, perch_top.position.z)
			and rampart.end.x >= perch_top.position.x + 1.0
			and off_roof > 0.0 and off_roof < tunables.step_height,
		"the rampart is a walked step off the keep roof and runs flush to the perch's face",
		"x %.2f..%.2f z %.2f..%.2f top %.2f; keep roof ends x %.2f top %.2f; perch face z %.2f"
			% [rampart.position.x, rampart.end.x, rampart.position.z, rampart.end.z,
				rampart.end.y, keep_top.end.x, keep_top.end.y, perch_top.position.z]
	)
	_check(
		onto_perch >= tunables.step_height and onto_perch < ArenaMap.climb_limit()
			and from_ring > ArenaMap.climb_limit(),
		"the perch is a hop off it, and the ring is not",
		"%.2f onto the perch, %.2f up from the ring, climb limit %.2f"
			% [onto_perch, from_ring, ArenaMap.climb_limit()]
	)

	# Driven: on the keep roof, held east, jump never pressed. Pace is the roof's east
	# edge (x = -12) to x = 18, near the far end, and the bot must never drop under
	# the walkway's top on the way.
	walker.controller.teleport(Vector3(-15.25, 5.6, -13.5))

	var along := DotFpsCommand.new()
	along.yaw = 0.0
	along.move = Vector2(1.0, 0.0)

	var ramp_on := -1
	var ramp_end := -1
	var ramp_low := 99.0
	var ramp_end_x := 0.0

	for tick in range(tick_rate * 8):
		walker.controller.apply_command(along)
		walker.controller.simulate_tick(tick_rate * 44 + tick, delta)

		var at: Vector3 = walker.controller.state.position

		if ramp_on < 0 and at.x >= -12.0:
			ramp_on = tick

		if ramp_on >= 0:
			ramp_low = minf(ramp_low, at.y)

		if at.x >= 18.0:
			ramp_end = tick
			ramp_end_x = at.x
			break

	var ramp_time := float(ramp_end - ramp_on) * delta
	var ramp_pace := (ramp_end_x + 12.0) / ramp_time if ramp_end > ramp_on and ramp_on >= 0 else 0.0

	print("  ..    rampart: keep roof edge to x 18, %.1f m in %.2f s, %.2f m/s against max_speed %.2f, lowest %.2f"
		% [ramp_end_x + 12.0, ramp_time, ramp_pace, tunables.max_speed, ramp_low])

	_check(
		ramp_end >= 0 and ramp_low > rampart.end.y - 0.1,
		"a bot walks off the keep roof and along the rampart, jump never pressed",
		"reached x %.2f, lowest %.2f against the top at %.2f"
			% [walker.controller.state.position.x, ramp_low, rampart.end.y]
	)
	_check(
		ramp_pace >= tunables.max_speed - 1.5,
		"and crosses red's half on it at running pace",
		"%.2f m/s against max_speed %.2f" % [ramp_pace, tunables.max_speed]
	)

	# And the hop at the far end: from the walkway's north edge, held south, jump
	# pressed once it is within a stride of the perch's face. Grounded on the perch.
	walker.controller.teleport(Vector3(18.5, rampart.end.y + 0.1, -14.7))

	var hop := DotFpsCommand.new()
	hop.yaw = 0.0
	hop.move = Vector2(0.0, -1.0)

	var on_perch := false

	for tick in range(tick_rate * 2):
		var at: Vector3 = walker.controller.state.position
		hop.set_button(DotFpsCommand.BUTTON_JUMP, at.z >= -12.8)
		walker.controller.apply_command(hop)
		walker.controller.simulate_tick(tick_rate * 48 + tick, delta)

		var now: Vector3 = walker.controller.state.position

		if walker.controller.state.is_grounded() and now.y > perch_top.end.y - 0.05 and now.z > -12.0:
			on_perch = true
			break

	var hop_at: Vector3 = walker.controller.state.position

	_check(
		on_perch,
		"and hops off its east end onto the perch",
		"ended at (%.1f, %.2f, %.1f)" % [hop_at.x, hop_at.y, hop_at.z]
	)

	# The trade: the perch sees every metre of it. From the perch's north-west corner,
	# a chest every 3 m from the keep-roof end to the perch.
	var rampart_eye := Vector3(16.4, perch_top.end.y + 1.6, -11.6)
	var rampart_hidden := PackedStringArray()
	var rampart_x := -11.5

	while rampart_x < 16.0:
		var chest := Vector3(rampart_x, rampart.end.y + 1.2, -13.5)
		var line := chest - rampart_eye
		var hit := trace.ray(rampart_eye, line.normalized(), line.length() - 0.05)

		if hit.ok() and hit.blocked:
			rampart_hidden.append("x %.1f" % rampart_x)

		rampart_x += 3.0

	_check(
		rampart_hidden.is_empty(),
		"and the perch sees the whole length of it",
		", ".join(rampart_hidden)
	)

	walker.queue_free()
	remove_child(walker)

	await get_tree().process_frame
	_done()

## The instant weapon change after a spawn (dot-loadout's DotLoadoutInstantSwap): at once when
## nobody is near and nobody fired, and the reasons it is refused.
func _test_instant_loadout() -> void:
	_section("instant loadout after spawn")
	var game := ArenaGame.new()
	game.name = "InstantGame"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.team_deathmatch(50)
	add_child(game)
	var ready := game.setup(ArenaMap.dm_atrium())
	if not _check(ready.ok, "an instant-loadout game sets up", str(ready.error)):
		game.queue_free()
		remove_child(game)
		return
	game.start(0)
	var cmd: Object = game.loadout_command
	if not _check(cmd != null and cmd.get(&"instant") != null, "the game has the instant-swap rule"):
		game.queue_free()
		remove_child(game)
		return
	_check(bool(cmd.get(&"instant").get(&"enabled")), "it is on by default in Arena")
	var _a := game.add_player(900, "Swapper")
	var _b := game.add_player(901, "Other")
	game.match_node.rules.respawn_delay_sec = 120.0
	_go_live(game)
	var key := ArenaGame.storage_key(900)
	var other := game.player_for(901)
	var me := game.player_for(900)
	other.global_position = me.global_position + Vector3(200.0, 0.0, 0.0)
	var facts: Dictionary = game.loadout_instant_facts(key)
	_check(float(facts["enemy_dist"]) > 100.0 and float(facts["since_spawn"]) >= 0.0, "facts: far enemy, recent spawn", str(facts))
	cmd.set(&"applied_fn", Callable())
	var rule: Object = cmd.get(&"instant")
	rule.set(&"cooldown", 10.0)
	var res: Dictionary = await cmd.call(&"choose", null, key, {"primary": "rifle"})
	_check(bool(res["ok"]) and bool(res["now"]), "a change with nobody near applies at once", str(res))
	res = await cmd.call(&"choose", null, key, {"primary": "rifle"})
	_check(not bool(res["now"]) and "cooldown" in str(res["text"]), "a second one is on cooldown", str(res))
	rule.call(&"forget", key)
	other.global_position = me.global_position + Vector3(3.0, 0.0, 0.0)
	res = await cmd.call(&"choose", null, key, {"primary": "rifle"})
	_check(not bool(res["now"]) and "enemy" in str(res["text"]), "an enemy near refuses it", str(res))
	other.global_position = me.global_position + Vector3(200.0, 0.0, 0.0)
	game._fired_tick[900] = game._tick
	res = await cmd.call(&"choose", null, key, {"primary": "rifle"})
	_check(not bool(res["now"]) and "fired" in str(res["text"]), "having just fired refuses it", str(res))
	game._fired_tick.erase(900)
	rule.set(&"enabled", false)
	res = await cmd.call(&"choose", null, key, {"primary": "rifle"})
	_check(not bool(res["now"]), "with the cvar off it waits for the next spawn", str(res))
	game.queue_free()
	remove_child(game)
	_done()
