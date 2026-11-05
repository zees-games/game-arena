extends "headless_match_part5.gd"

## `dm_box`'s upper level, climbed and walked by a bot rather than believed: from the floor up the
## west crates onto the ledge, one across each gantry, one up the north nest.
func _test_box_upper() -> void:
	_section("dm_box: the upper level, climbed")

	var map := ArenaMap.dm_box()

	# [b]The property dm_box exists for, asked of the whole list.[/b] Every box has a twin turned
	# half a circle about the origin, so every spawn scores identically.
	var unpaired := PackedStringArray()

	for box in map.boxes:
		var turned := AABB(
			Vector3(-box.end.x, box.position.y, -box.end.z), box.size
		)
		var twin := false

		for other in map.boxes:
			if other.is_equal_approx(turned):
				twin = true
				break

		if not twin:
			unpaired.append(str(box))

	_check(
		unpaired.is_empty(),
		"every box on dm_box has its twin turned half a circle about the middle",
		", ".join(unpaired)
	)

	var climber := ArenaPlayer.new()
	climber.name = "BoxClimber"
	add_child(climber)
	climber.setup(ArenaPlayer.Mode.HEADLESS, map, 9003, "box climber")

	var delta := 1.0 / 64.0
	var tick := 0

	# Floor, three crates, the west ledge: +Z (yaw 180) with jump up the crates, a quarter second
	# still on the top one, then -X (yaw 90) with jump.
	var start := Vector3(-15.75, 0.1, -7.8)
	climber.controller.teleport(start, 180.0, 0.0)

	var on_top_crate := false
	var on_ledge := false
	var settle := 16

	for step in range(64 * 20):
		var command := DotFpsCommand.new()
		command.yaw = 90.0 if on_top_crate else 180.0

		if on_top_crate and settle > 0:
			settle -= 1
		else:
			command.move = Vector2(0.0, 1.0)
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)

		climber.controller.apply_command(command)
		climber.controller.simulate_tick(tick, delta)
		tick += 1

		var at: Vector3 = climber.controller.state.position
		var grounded := climber.controller.state.is_grounded()

		if not on_top_crate and grounded and at.y > 2.65:
			on_top_crate = true

		if on_top_crate and grounded and at.y > 3.55 and at.x < -18.0:
			on_ledge = true
			break

	var ended: Vector3 = climber.controller.state.position

	_check(
		on_top_crate and on_ledge,
		"a bot climbs the west crates from the floor onto the west ledge",
		"top crate %s, ended at (%.1f, %.2f, %.1f)"
			% [on_top_crate, ended.x, ended.y, ended.z]
	)

	# Each gantry, ledge to ledge, clear of the nest step that fills its outer metre beside the pillar: the walkway past
	# it is the 1.5 m this leg walks.
	for leg in [
		{"name": "north", "from": Vector3(-20.0, 3.7, -8.9), "yaw": -90.0, "sign": 1.0},
		{"name": "south", "from": Vector3(20.0, 3.7, 8.9), "yaw": 90.0, "sign": -1.0},
	]:
		climber.controller.teleport(leg["from"], leg["yaw"], 0.0)
		var crossed := false

		for step in range(64 * 8):
			var command := DotFpsCommand.new()
			command.yaw = leg["yaw"]
			command.move = Vector2(0.0, 1.0)
			climber.controller.apply_command(command)
			climber.controller.simulate_tick(tick, delta)
			tick += 1

			var at: Vector3 = climber.controller.state.position

			if (
				climber.controller.state.is_grounded()
				and at.y > 3.55
				and at.x * float(leg["sign"]) > 18.5
			):
				crossed = true
				break

		var there: Vector3 = climber.controller.state.position

		_check(
			crossed,
			"and walks the %s gantry from one ledge to the other" % leg["name"],
			"ended at (%.1f, %.2f, %.1f)" % [there.x, there.y, there.z]
		)

	# The north nest: north (yaw 0) with jump from the gantry, 0.9 onto the step, 0.5 onto the pillar. Grounded on the
	# pillar's top is the arrival, for the reason `_test_crate_climb` gives about heights a jump only passes through.
	climber.controller.teleport(Vector3(4.0, 3.7, -8.4), 0.0, 0.0)
	var nested := false

	for step in range(64 * 6):
		var command := DotFpsCommand.new()
		command.yaw = 0.0
		command.move = Vector2(0.0, 1.0)
		command.set_button(DotFpsCommand.BUTTON_JUMP, true)
		climber.controller.apply_command(command)
		climber.controller.simulate_tick(tick, delta)
		tick += 1

		var at: Vector3 = climber.controller.state.position

		if climber.controller.state.is_grounded() and at.y > 4.95 and at.z < -10.5:
			nested = true
			break

	var perched: Vector3 = climber.controller.state.position

	_check(
		nested,
		"and climbs off the north gantry, up its step, onto the nest",
		"ended at (%.1f, %.2f, %.1f)" % [perched.x, perched.y, perched.z]
	)

	# The two nest stairs, walked and each separately: a turned box list meets a different gantry
	# (`[gate-sweep-1]`).
	var tunables := ArenaPlayer.arena_tunables()
	var trace := map.to_trace()

	for flight in [
		{"name": "north", "sign": 1.0, "up_yaw": -90.0, "across_yaw": 180.0},
		{"name": "south", "sign": -1.0, "up_yaw": 90.0, "across_yaw": 0.0},
	]:
		var s: float = flight["sign"]
		# In the stair's own frame (the north one's): the foot of the first tread is at
		# x -6.5 and the last tread ends against the pillar at x 2.5, z -13.5..-10.5.
		climber.controller.teleport(Vector3(s * -9.0, 0.1, s * -12.0), flight["up_yaw"], 0.0)

		var foot_tick := -1
		var top_tick := -1
		var top_x := 0.0

		for step in range(64 * 4):
			var command := DotFpsCommand.new()
			command.yaw = flight["up_yaw"]
			command.move = Vector2(0.0, 1.0)
			climber.controller.apply_command(command)
			climber.controller.simulate_tick(tick, delta)
			tick += 1

			var at: Vector3 = climber.controller.state.position
			var local_x := at.x * s

			if foot_tick < 0 and local_x >= -6.5:
				foot_tick = step

			if climber.controller.state.is_grounded() and at.y > 3.55:
				top_tick = step
				top_x = local_x
				break

		var climb_time := float(top_tick - foot_tick) * delta
		var climb_pace := (top_x + 6.5) / climb_time if top_tick > foot_tick and foot_tick >= 0 else 0.0
		var topped: Vector3 = climber.controller.state.position

		print("  ..    %s nest stair: %.1f m of stair in %.2f s, %.2f m/s against max_speed %.2f"
			% [flight["name"], top_x + 6.5, climb_time, climb_pace, tunables.max_speed])

		_check(
			top_tick >= 0,
			"a bot walks up the %s nest stair from the floor, jump never pressed" % flight["name"],
			"ended at (%.1f, %.2f, %.1f)" % [topped.x, topped.y, topped.z]
		)
		_check(
			climb_pace >= tunables.max_speed - 1.5,
			"and climbs it at running pace",
			"%.2f m/s against max_speed %.2f" % [climb_pace, tunables.max_speed]
		)

		# The run ends against the pillar rather than off the end of the stair: held on
		# for another half second, the bot is still standing on the top tread.
		for step in range(32):
			var command := DotFpsCommand.new()
			command.yaw = flight["up_yaw"]
			command.move = Vector2(0.0, 1.0)
			climber.controller.apply_command(command)
			climber.controller.simulate_tick(tick, delta)
			tick += 1

		var held: Vector3 = climber.controller.state.position

		_check(
			climber.controller.state.is_grounded() and held.y > 3.55 and held.x * s < 2.5,
			"and a run up it ends against the nest pillar, still on the top tread",
			"ended at (%.1f, %.2f, %.1f)" % [held.x, held.y, held.z]
		)

		var onto_gantry := false

		for step in range(64 * 2):
			var command := DotFpsCommand.new()
			command.yaw = flight["across_yaw"]
			command.move = Vector2(0.0, 1.0)
			climber.controller.apply_command(command)
			climber.controller.simulate_tick(tick, delta)
			tick += 1

			var at: Vector3 = climber.controller.state.position

			if climber.controller.state.is_grounded() and at.y > 3.55 and at.z * s > -9.5:
				onto_gantry = true
				break

		var across: Vector3 = climber.controller.state.position

		_check(
			onto_gantry,
			"and steps off its top tread onto the %s gantry" % flight["name"],
			"ended at (%.1f, %.2f, %.1f)" % [across.x, across.y, across.z]
		)

		# [b]The trade, traced.[/b] The stair climbs straight at the nest, so an eye on the nest
		# sees a player's chest on every tread of it.
		var eye := Vector3(s * 4.0, 5.0 + 1.6, s * -12.0)
		var hidden := PackedStringArray()

		for index in range(10):
			var chest := Vector3(s * (-6.05 + 0.9 * float(index)), 0.36 * float(index + 1) + 1.2, s * -12.0)
			var line := chest - eye
			var hit := trace.ray(eye, line.normalized(), line.length() - 0.05)

			if hit.ok() and hit.blocked:
				hidden.append("tread %d" % (index + 1))

		_check(
			hidden.is_empty(),
			"and the %s nest sees down every tread of its stair" % flight["name"],
			", ".join(hidden)
		)

	# The two corner stairs, read off the box list first (north-west frame: ten treads under
	# step_height, the top one flush with a landing flush with the west ledge).
	var corner_treads: Array[AABB] = []
	var corner_landing := AABB()

	for box in map.boxes:
		if (
			is_equal_approx(box.position.z, -24.0)
			and is_equal_approx(box.size.z, 3.0)
			and box.position.y == 0.0
			and box.position.x >= -17.51
			and box.end.x <= -8.49
		):
			corner_treads.append(box)

		if (
			is_equal_approx(box.position.x, -24.0)
			and is_equal_approx(box.position.z, -24.0)
			and is_equal_approx(box.end.y, 3.6)
		):
			corner_landing = box

	corner_treads.sort_custom(func(a: AABB, b: AABB) -> bool: return a.end.y < b.end.y)
	var corner_steep := PackedStringArray()
	var corner_floor := 0.0

	for tread in corner_treads:
		if tread.end.y - corner_floor >= tunables.step_height:
			corner_steep.append("%.2f -> %.2f" % [corner_floor, tread.end.y])

		corner_floor = tread.end.y

	_check(
		corner_treads.size() == 10 and corner_steep.is_empty(),
		"dm_box's north-west corner stair is ten treads, every rise under step_height",
		"%d treads; %s" % [corner_treads.size(), ", ".join(corner_steep)]
	)
	_check(
		corner_landing.has_volume()
			and not corner_treads.is_empty()
			and is_equal_approx(corner_treads[-1].position.x, corner_landing.end.x)
			and is_equal_approx(corner_treads[-1].end.y, corner_landing.end.y)
			and is_equal_approx(corner_landing.end.z, -18.0),
		"and its top tread is flush with a landing that is flush with the west ledge",
		"landing %s, top tread %s" % [corner_landing, corner_treads[-1] if not corner_treads.is_empty() else AABB()]
	)

	for corner in [
		{"name": "north-west", "sign": 1.0, "up_yaw": 90.0, "ledge_yaw": 180.0},
		{"name": "south-east", "sign": -1.0, "up_yaw": -90.0, "ledge_yaw": 0.0},
	]:
		var s: float = corner["sign"]
		climber.controller.teleport(Vector3(s * -6.0, 0.1, s * -22.5), corner["up_yaw"], 0.0)

		var foot_tick := -1
		var top_tick := -1
		var top_x := 0.0

		for step in range(64 * 4):
			var command := DotFpsCommand.new()
			command.yaw = corner["up_yaw"]
			command.move = Vector2(0.0, 1.0)
			climber.controller.apply_command(command)
			climber.controller.simulate_tick(tick, delta)
			tick += 1

			var at: Vector3 = climber.controller.state.position
			var local_x := at.x * s

			if foot_tick < 0 and local_x <= -8.5:
				foot_tick = step

			if climber.controller.state.is_grounded() and at.y > 3.55:
				top_tick = step
				top_x = local_x
				break

		var corner_time := float(top_tick - foot_tick) * delta
		var corner_pace := (-8.5 - top_x) / corner_time if top_tick > foot_tick and foot_tick >= 0 else 0.0
		var corner_top: Vector3 = climber.controller.state.position

		print("  ..    %s corner stair: %.1f m of stair in %.2f s, %.2f m/s against max_speed %.2f"
			% [corner["name"], -8.5 - top_x, corner_time, corner_pace, tunables.max_speed])

		_check(
			top_tick >= 0,
			"a bot walks up the %s corner stair from the floor, jump never pressed" % corner["name"],
			"ended at (%.1f, %.2f, %.1f)" % [corner_top.x, corner_top.y, corner_top.z]
		)
		_check(
			corner_pace >= tunables.max_speed - 1.5,
			"and climbs it at running pace",
			"%.2f m/s against max_speed %.2f" % [corner_pace, tunables.max_speed]
		)

		# Held on for a second and a half — more than the 6.5 m of landing takes — the run ends
		# against the side wall, still at ledge height, not in the corner below.
		for step in range(96):
			var command := DotFpsCommand.new()
			command.yaw = corner["up_yaw"]
			command.move = Vector2(0.0, 1.0)
			climber.controller.apply_command(command)
			climber.controller.simulate_tick(tick, delta)
			tick += 1

		var corner_held: Vector3 = climber.controller.state.position

		_check(
			climber.controller.state.is_grounded()
				and corner_held.y > 3.55
				and corner_held.x * s < -23.0,
			"and a run up it carries on across the landing to the wall, still at ledge height",
			"ended at (%.1f, %.2f, %.1f)" % [corner_held.x, corner_held.y, corner_held.z]
		)

		var onto_ledge := false

		for step in range(64 * 2):
			var command := DotFpsCommand.new()
			command.yaw = corner["ledge_yaw"]
			command.move = Vector2(0.0, 1.0)
			climber.controller.apply_command(command)
			climber.controller.simulate_tick(tick, delta)
			tick += 1

			var at: Vector3 = climber.controller.state.position

			if climber.controller.state.is_grounded() and at.y > 3.55 and at.z * s > -16.0:
				onto_ledge = true
				break

		var on_stub: Vector3 = climber.controller.state.position

		_check(
			onto_ledge,
			"and turns off the landing onto the %s ledge's end" % ("west" if s > 0.0 else "east"),
			"ended at (%.1f, %.2f, %.1f)" % [on_stub.x, on_stub.y, on_stub.z]
		)

		# The trade: the nest on this side of the room sees a chest on every tread.
		var corner_eye := Vector3(s * 4.0, 5.0 + 1.6, s * -12.0)
		var corner_hidden := PackedStringArray()

		for index in range(10):
			var chest := Vector3(
				s * (-17.05 + 0.9 * float(9 - index)), 0.36 * float(index + 1) + 1.2, s * -22.5
			)
			var line := chest - corner_eye
			var hit := trace.ray(corner_eye, line.normalized(), line.length() - 0.05)

			if hit.ok() and hit.blocked:
				corner_hidden.append("tread %d" % (index + 1))

		_check(
			corner_hidden.is_empty(),
			"and the nest on its side of the room sees every tread of it",
			", ".join(corner_hidden)
		)

	climber.queue_free()
	remove_child(climber)
	_done()

## Drives [param route] through a bare motor on [param body]: `made`, `at`, `runs`, `jumps`, and
## `worst_on_wall`.
func _drive_route(map: ArenaMap, body: DotFpsBody, route: Dictionary, how: StringName, walls: bool) -> Dictionary:
	var t := ArenaPlayer.arena_tunables()
	if not walls:
		t.wall_run_enabled = false
		t.wall_jump_enabled = false
		t.wall_slide_speed = 0.0
	var motor := DotFpsMotor.new(t, body)
	var driver := WallRouteDriver.new(route, how)
	var state := DotFpsState.new()
	state.position = driver.start
	state.yaw = driver.yaw
	state.mode = DotFpsState.Mode.AIR
	var step := 1.0 / float(TICK_RATE)

	# Settle onto the start, standing still.
	for _i in range(16):
		var idle := DotFpsCommand.new()
		idle.yaw = driver.yaw
		motor.simulate(state, idle, step)

	# How the run treats the velocity: what the entry tick changed against what easing the arriving
	# vertical speed allows, the largest rise from one tick's change to the next (a jolt.
	var dt := step
	var entry_excess := -INF
	var jolt := 0.0
	var along_moved := 0.0
	var along := -1.0
	var previous_change := INF
	var was_running := false
	var before := state.velocity
	var ticks := 0
	while ticks < 400 and not driver.finished(state):
		motor.simulate(state, driver.next(state), step)
		ticks += 1
		var running := state.is_wall_running()
		var change := (state.velocity - before).length()
		if running and not was_running:
			entry_excess = change - (absf(before.y) * t.wall_run_vertical_damping * dt + t.gravity * dt) * 1.05
			along = state.horizontal_speed()
		elif (running or was_running) and not state.is_grounded():
			# The tick a run ends counts, unless it ends on the floor: a landing is the floor's.
			jolt = maxf(jolt, change - previous_change)
		if running:
			along_moved = maxf(along_moved, absf(state.horizontal_speed() - along))
		previous_change = change
		was_running = running
		before = state.velocity

	return {
		"made": driver.made(state), "at": state.position, "runs": motor.wall_runs,
		"jumps": motor.wall_jumps, "entry_excess": entry_excess, "jolt": jolt,
		"along_moved": along_moved,
	}

## The walls' routes on every map, driven through the motor.
func _test_wall_routes() -> void:
	_section("every map: the wall routes, run and climbed")

	var routes := 0
	for id in ArenaMap.ids():
		var map := ArenaMap.by_id(id)
		var body := map.to_fps_body()

		for route: Dictionary in map.wall_routes:
			routes += 1
			var name: String = route["name"]
			var made := _drive_route(map, body, route, &"walls", true)
			var wall_move: int = made["runs"] if route["kind"] == &"run" else made["jumps"]
			_check(made["made"] and wall_move >= (1 if route["kind"] == &"run" else 2),
				"%s: made, the intended way" % name,
				"at %s, %d runs, %d wall jumps" % [made["at"], made["runs"], made["jumps"]])
			var without := _drive_route(map, body, route, &"walls", false)
			_check(not without["made"], "%s: and not with the wall moves off" % name, "at %s" % without["at"])

			if route["kind"] == &"run":
				var crossed := PackedStringArray()
				for how in [&"plain", &"slide", &"dash", &"jumpdash"]:
					var tried := _drive_route(map, body, route, how, false)
					if tried["made"]:
						crossed.append(String(how))
				_check(crossed.is_empty(), "%s: nothing but the wall crosses it" % name,
					"crossed by %s" % ", ".join(crossed))
				var gravity_tick := ArenaPlayer.arena_tunables().gravity / float(TICK_RATE)
				_check(float(made["along_moved"]) < 0.01,
					"%s: the run never touches the speed along the wall" % name,
					"moved %.3f m/s" % made["along_moved"])
				_check(float(made["entry_excess"]) <= 0.0 and float(made["jolt"]) <= gravity_tick * 1.05,
					"%s: the vertical is eased, never set: no tick's change grows on the last by over a tick of gravity" % name,
					"entry %.3f over the ease, worst growth %.3f m/s against %.3f" % [made["entry_excess"], made["jolt"], gravity_tick])

	_check(routes >= 2, "the maps declare wall routes (%d)" % routes)

	# The trade every way up on dm_atrium makes: the gallery is watched from higher.
	var atrium := ArenaMap.dm_atrium()
	var trace := atrium.shot_trace()
	var hidden := PackedStringArray()
	var rampart_eye := Vector3(-4.0, 5.86 + 1.6, -13.5)
	for route: Dictionary in atrium.wall_routes:
		if route["kind"] != &"run":
			continue
		for ledge: AABB in [route["from"], route["to"]]:
			var x := ledge.position.x + 1.0
			while x < ledge.end.x:
				var chest := Vector3(x, ledge.end.y + 1.2, ledge.get_center().z)
				var line := chest - rampart_eye
				var hit := trace.ray(rampart_eye, line.normalized(), line.length() - 0.05)
				if hit.ok() and hit.blocked:
					hidden.append("ledge at x %.1f" % x)
				x += 3.0
		for climb: Dictionary in atrium.wall_routes:
			if climb["kind"] != &"jump":
				continue
			var walls: Array = climb["walls"]
			var top := Vector3(
				((walls[0] as AABB).get_center().x + (walls[1] as AABB).get_center().x) * 0.5,
				(climb["to"] as AABB).end.y + 1.2, (walls[0] as AABB).get_center().z
			)
			var keep_eye := Vector3(-18.0, 5.5 + 1.6, -17.6)
			var line := top - keep_eye
			var hit := trace.ray(keep_eye, line.normalized(), line.length() - 0.05)
			if hit.ok() and hit.blocked:
				hidden.append("the chimney's top")
	_check(hidden.is_empty(), "dm_atrium: the rampart sees all of the gallery, and the keep roof the chimney's top",
		", ".join(hidden))
	_done()

func _test_crate_climb() -> void:
	_section("dm_atrium: the crates, climbed")

	var map := ArenaMap.dm_atrium()

	var climber := ArenaPlayer.new()
	climber.name = "Climber"
	add_child(climber)
	climber.setup(ArenaPlayer.Mode.HEADLESS, map, 9002, "climber")

	# On the yard floor south of the first crate. The column runs north up x 12.5..16,
	# so the bot starts in the middle of it and holds north.
	var start := Vector3(14.2, 0.5, 29.0)
	climber.controller.teleport(start)

	var tick_rate := 64
	var delta := 1.0 / float(tick_rate)
	var peak := start.y
	var top_of_stack := false
	var on_the_ring := false

	# Two held directions, and the switch is the honest part: the column climbs north and the ring
	# is west of its top, so north and jump until up, then west and no jump.
	for tick in range(tick_rate * 24):
		var command := DotFpsCommand.new()
		command.yaw = 0.0
		command.pitch = 0.0

		if top_of_stack:
			# North-west, not west: the bot arrives at the landing's south-east corner and the ring's adjacent 4 m is its northern
			# half, so due west crosses x 10 south of anything and falls into the yard.
			command.move = Vector2(-1.0, 1.0).normalized()
		else:
			command.move = Vector2(0.0, 1.0)
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)

		climber.controller.apply_command(command)
		climber.controller.simulate_tick(tick, delta)

		var at: Vector3 = climber.controller.state.position
		peak = maxf(peak, at.y)

		# Standing on the top of the stack is `is_grounded`, not a height band: a bot that never
		# reached the fifth crate crosses 4.45 twice on its way past.
		if (
			not top_of_stack
			and climber.controller.state.is_grounded()
			and at.y > 4.45
			and at.z < 12.0
		):
			top_of_stack = true

		# And on the roof ring itself: the landing's top is 4.5 and the ring's 4.6, so height is not decisive; x is, because the
		# landing's west face IS the ring's east edge at x 10. Grounded, above the landing, west of it.
		if (
			top_of_stack
			and climber.controller.state.is_grounded()
			and at.y > 4.55
			and at.x < 9.9
		):
			on_the_ring = true
			break

	var at: Vector3 = climber.controller.state.position

	print("  ..    the climber reached y %.2f, ended at (%.1f, %.2f, %.1f)"
		% [peak, at.x, at.y, at.z])

	_check(
		top_of_stack,
		"a bot holding north and jump at the south-east crates climbs all five",
		"peak y %.2f, ended at (%.1f, %.2f, %.1f)" % [peak, at.x, at.y, at.z]
	)
	_check(
		on_the_ring,
		"and walking west off the landing puts it on the roof ring",
		"ended at (%.1f, %.2f, %.1f)" % [at.x, at.y, at.z]
	)

	climber.queue_free()
	remove_child(climber)
	_done()

# --- Building --------------------------------------------------------------

func _build() -> void:
	_section("bringing up the match")

	_game = ArenaGame.new()
	_game.name = "Arena"
	# Throwaway achievement store, or a persisted file from an earlier run seeds the lifetime totals.
	var ach_dir := ProjectSettings.globalize_path("user://headless_match_achievements")
	OS.move_to_trash(ach_dir) if DirAccess.dir_exists_absolute(ach_dir) else null
	_game.progress_dir = ach_dir
	_game.tick_rate = TICK_RATE
	_game.score_limit = SCORE_LIMIT
	_game.time_limit_sec = 0.0
	_game.headless = true
	_game.is_authority = true
	_game.register_service = false
	add_child(_game)

	var ready := _game.setup(ArenaMap.dm_box())
	_check(ready.ok, "the game sets up", str(ready.error))

	# Warmup and countdown out of the way: this test is about the match, and waiting
	# out thirteen real seconds of clock at 64 Hz is 832 ticks of nothing.
	_game.match_node.rules.warmup_sec = 0.0
	_game.match_node.rules.countdown_sec = 0.0
	_game.match_node.rules.respawn_delay_sec = 1.0
	_game.match_node.rules.intermission_sec = 0.5
	_game.match_node.rules.match_end_sec = 0.5

	_game.player_killed.connect(func(entry: DotKillFeed.Entry) -> void:
		_kills.append(entry)
	)
	_game.player_spawned.connect(func(player: ArenaPlayer) -> void:
		_spawns.append(player.player_id)
	)
	_game.match_state_changed.connect(
		func(_from: DotMatch.State, to: DotMatch.State) -> void:
			_states.append(DotMatch.State.keys()[to])
	)

	for index in range(BOTS):
		var added := _game.add_player(index + 1, "Bot %d" % (index + 1))
		_check(added.ok, "bot %d joins" % (index + 1), str(added.error))

	_game.start(0)
	_check(_game.match_node.state != DotMatch.State.IDLE, "the match starts")

	# Let the first tick run so the round goes live and everyone is spawned in.
	_game.tick({})
	await get_tree().process_frame
	_done()
