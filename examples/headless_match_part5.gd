extends "headless_match_part4.gd"

## `dm_pit`: the geometry, the bot that has to get out of the pit, and the mode gate.
func _test_pit() -> void:
	_section("dm_pit")

	var map := ArenaMap.dm_pit()

	_check(map.boxes.size() > 24, "the map has geometry", str(map.boxes.size()))
	_check(map.spawns.size() == 9, "and nine spawns", str(map.spawns.size()))

	# The invariant every map here is built around, restated for this one.
	_check(
		map.to_fps_body().boxes.size() == map.boxes.size()
			and map.to_trace().boxes.size() == map.boxes.size(),
		"all three representations hold the same boxes"
	)

	# Nobody spawns inside a wall: a 0.8 x 1.8 column at each spawn against every solid. `_test_map`'s weaker check (inside the
	# room, above the floor) passes a spawn buried in a stair tread, and this map has three staircases in a 28 m room.
	var buried := PackedStringArray()

	for index in range(map.spawns.size()):
		var at: Vector3 = map.spawns[index].origin
		var column := AABB(at + Vector3(-0.4, -0.05, -0.4), Vector3(0.8, 1.8, 0.8))

		for box in map.boxes:
			if box.intersects(column):
				buried.append("#%d at %s" % [index, str(at)])
				break

	_check(buried.is_empty(), "and no spawn is inside a solid", ", ".join(buried))

	# --- The property the map is for --------------------------------------

	var tagged := 0

	for index in range(map.spawns.size()):
		if map.spawn_tag(index) != &"":
			tagged += 1

	_check(tagged == 0, "every spawn is untagged, on purpose", "%d tagged" % tagged)

	# The lookout, climbed: a bot on the east arm facing east (yaw 270) holding forward and jump, grounded on the lookout's
	# top. Then why it exists: an eye on the lookout sees an eye on the perch, with no box between.
	var lookout_climber := ArenaPlayer.new()
	lookout_climber.name = "LookoutClimber"
	add_child(lookout_climber)
	lookout_climber.setup(ArenaPlayer.Mode.HEADLESS, map, 9004, "lookout climber")
	lookout_climber.controller.teleport(Vector3(11.6, 3.7, 4.0), 270.0, 0.0)

	var looking := false
	var look_tick := 0

	for step in range(64 * 4):
		var command := DotFpsCommand.new()
		command.yaw = 270.0
		command.move = Vector2(0.0, 1.0)
		command.set_button(DotFpsCommand.BUTTON_JUMP, true)
		lookout_climber.controller.apply_command(command)
		lookout_climber.controller.simulate_tick(look_tick, 1.0 / 64.0)
		look_tick += 1

		var on: Vector3 = lookout_climber.controller.state.position

		if lookout_climber.controller.state.is_grounded() and on.y > 4.45 and on.x > 12.5:
			looking = true
			break

	var stood: Vector3 = lookout_climber.controller.state.position
	_check(
		looking,
		"a bot climbs off the east arm onto the lookout",
		"ended at (%.1f, %.2f, %.1f)" % [stood.x, stood.y, stood.z]
	)

	lookout_climber.queue_free()
	remove_child(lookout_climber)

	var from_lookout := Vector3(13.25, 4.5 + 1.6, 4.0)
	var from_perch := Vector3(-10.0, 5.4 + 1.6, 10.0)
	var in_the_way := PackedStringArray()

	for box in map.boxes:
		if box.intersects_segment(from_lookout, from_perch):
			in_the_way.append(str(box))

	_check(
		in_the_way.is_empty(),
		"and from it a player sees the perch, and the perch sees them",
		", ".join(in_the_way)
	)

	var catalogue := ArenaMaps.catalogue()
	var def := catalogue.get_map(&"dm_pit")

	if not _check(def != null, "and it is in the catalogue"):
		return

	_check(
		not bool(def.meta.get("teams", true)),
		"whose entry records that it has no team spawns"
	)

	var ffa := ArenaMode.free_for_all()
	var team := _first_team_mode()

	_check(ArenaMaps.supports_mode(def, ffa), "a free-for-all can be played on it")

	if _check(team != null, "this game has a team mode to test the refusal with"):
		_check(
			not ArenaMaps.supports_mode(def, team),
			"and a team mode cannot -- the first map here that says so",
			String(team.id)
		)

		# The other two maps must still say yes, or the filter below is passing for
		# the wrong reason.
		_check(
			ArenaMaps.supports_mode(catalogue.get_map(&"dm_box"), team)
				and ArenaMaps.supports_mode(catalogue.get_map(&"dm_atrium"), team),
			"while the other two maps still can"
		)

	# A bot has to be able to get out of the pit, which an assertion about boxes cannot tell. The north-west stair is ten
	# treads of 0.36 that the movement should WALK; a too-tall tread stops the bot dead (measured on `dm_atrium` at 0.6).
	var holder := Node3D.new()
	holder.name = "PitBot"
	add_child(holder)

	var bot := ArenaPlayer.HeadlessController.new()
	bot.name = "Movement"
	bot.flat_body = map.to_fps_body()
	bot.drive = DotFpsController.Drive.EXTERNAL
	bot.tick_rate = TICK_RATE
	bot.tunables = ArenaPlayer.arena_tunables()
	bot.register_service = false
	bot.register_default_actions = false
	bot.body_ref = DotNodeRef.of_path(NodePath(".."))
	holder.add_child(bot)

	# At the bottom of the stair, facing west along it. Yaw 90 is -X in Godot's
	# -Z-forward convention, which is the direction the treads climb.
	bot.teleport(Vector3(-1.0, 0.2, -9.0), 90.0, 0.0)

	var delta := 1.0 / float(TICK_RATE)
	var highest := bot.state.position.y

	for tick in range(int(TICK_RATE * 4)):
		var command := DotFpsCommand.new()
		command.yaw = 90.0
		command.pitch = 0.0
		command.move = Vector2(0.0, 1.0)
		bot.apply_command(command)
		bot.simulate_tick(tick, delta)
		highest = maxf(highest, bot.state.position.y)

	# The ring's top face is 3.6. Anything at or above it means the bot walked the
	# whole stair; the failure this catches is a bot at 0.36 four seconds later.
	_check(
		highest >= 3.5,
		"a bot walks the north-west stair onto the catwalk",
		"reached %.2f m, ring is at 3.60" % highest
	)

	var on_ring := bot.state.position
	_check(
		on_ring.y >= 3.5 and on_ring.x <= -10.0,
		"and is standing on it at the end",
		"at %s" % str(on_ring)
	)

	# And across the bridge.
	bot.teleport(Vector3(0.0, 3.9, -10.0), 180.0, 0.0)

	var crossed := false

	for tick in range(int(TICK_RATE * 4)):
		var command := DotFpsCommand.new()
		command.yaw = 180.0
		command.pitch = 0.0
		command.move = Vector2(0.0, 1.0)
		bot.apply_command(command)
		bot.simulate_tick(int(TICK_RATE * 4) + tick, delta)

		if bot.state.position.z > 9.0 and bot.state.position.y > 3.0:
			crossed = true
			break

	_check(
		crossed,
		"and crosses the bridge without falling into the pit",
		"ended at %s" % str(bot.state.position)
	)

	# The crossing: the east-west gantry, driven the same way and asked SEPARATELY from the north-south one, because the two
	# are different boxes meeting different arms of the ring (`[gate-sweep-1]`: checking one instance of a shape and believing all).
	bot.teleport(Vector3(-10.0, 3.9, 0.0), -90.0, 0.0)

	var gantried := false

	for tick in range(int(TICK_RATE * 4)):
		var command := DotFpsCommand.new()
		# -90 is +X in Godot's -Z-forward convention, which is the way this one runs.
		command.yaw = -90.0
		command.pitch = 0.0
		command.move = Vector2(0.0, 1.0)
		bot.apply_command(command)
		bot.simulate_tick(int(TICK_RATE * 8) + tick, delta)

		if bot.state.position.x > 9.0 and bot.state.position.y > 3.0:
			gantried = true
			break

	_check(
		gantried,
		"and crosses the new east-west gantry the same way",
		"ended at %s" % str(bot.state.position)
	)

	holder.queue_free()
	remove_child(holder)

	# The shelf and the perch: both rises must be hops (a ledge 1.3 m up is drawn like one 0.9 m up and is a tier nobody
	# reaches, `[gate-sweep-1]`'s second question), then the second question about the third tier.
	var jump: float = ArenaPlayer.arena_tunables().jump_height

	# Both boxes found by their footprint rather than by an index into the list: `add_box` order is
	# an implementation detail and an index is a check that silently starts measuring a different.
	var shelf := AABB()
	var perch := AABB()
	var found_shelf := false
	var found_perch := false

	for box in map.boxes:
		if is_equal_approx(box.size.x, 4.0) and is_equal_approx(box.size.y, 4.5):
			shelf = box
			found_shelf = true
		elif is_equal_approx(box.size.x, 2.0) and is_equal_approx(box.size.y, 0.9):
			perch = box
			found_perch = true

	if _check(
		found_shelf and found_perch, "the shelf and the perch are in the box list"
	):
		# Rises read off the geometry, not written down a second time here — the
		# failure being caught is exactly a number changed there and not here.
		var ring_top := 3.6
		var shelf_top: float = shelf.position.y + shelf.size.y
		var perch_top: float = perch.position.y + perch.size.y
		var onto_shelf: float = shelf_top - ring_top
		var onto_perch: float = perch_top - shelf_top

		_check(
			onto_shelf < jump and onto_perch < jump,
			"both rises onto the third tier are hops rather than walls",
			"%.2f m then %.2f m against a %.2f m jump"
				% [onto_shelf, onto_perch, jump]
		)
		_check(
			perch.position.y <= shelf_top + 0.001,
			"and the perch stands ON the shelf rather than above a gap",
			"perch starts at %.2f, shelf ends at %.2f"
				% [perch.position.y, shelf_top]
		)

	if found_shelf:
		var west_slot: float = absf(shelf.position.x - (-11.0))
		var south_slot: float = absf(
			(shelf.position.z + shelf.size.z) - 11.0
		)

		_check(
			west_slot < 0.01 and south_slot < 0.01,
			"and is flush with both arms of the ring rather than slotted off them",
			"%.2f m west, %.2f m south" % [west_slot, south_slot]
		)

	if found_shelf and found_perch:
		_test_pit_shelf_stair(map, shelf, perch)

	_done()

## The highest horizontal speed [param bot] reaches in two seconds of holding forward, driven east
## over 30 m of flat south of `dm_atrium`'s yard (the first half second is discarded).
func _top_speed(
	bot: DotFpsController, jumping: bool, delta: float, tick_base: int
) -> float:
	bot.teleport(Vector3(0.0, 0.2, 24.0), 0.0, 0.0)

	var speed := 0.0

	for tick in range(TICK_RATE * 2):
		var command := DotFpsCommand.new()
		command.yaw = 0.0
		command.pitch = 0.0
		command.move = Vector2(1.0, 0.0)
		command.set_button(DotFpsCommand.BUTTON_JUMP, jumping)
		bot.apply_command(command)
		bot.simulate_tick(tick_base + tick, delta)

		if tick >= TICK_RATE / 2:
			var v: Vector3 = bot.state.velocity
			speed = maxf(speed, Vector2(v.x, v.z).length())

	return speed

## What a bot driven the way every bot here is driven MOVES at: `move = Vector2(0, 1)` walks,
## holding jump too is seven times slower (`auto_hop` leaves the ground the tick it lands.
func _test_bot_ground_speed() -> void:
	_section("what a bot actually travels at")

	var map := ArenaMap.dm_atrium()
	var tunables := ArenaPlayer.arena_tunables()

	var holder := Node3D.new()
	holder.name = "SpeedBot"
	add_child(holder)

	var bot := ArenaPlayer.HeadlessController.new()
	bot.name = "Movement"
	bot.flat_body = map.to_fps_body()
	bot.drive = DotFpsController.Drive.EXTERNAL
	bot.tick_rate = TICK_RATE
	bot.tunables = tunables
	bot.register_service = false
	bot.register_default_actions = false
	bot.body_ref = DotNodeRef.of_path(NodePath(".."))
	holder.add_child(bot)

	var delta := 1.0 / float(TICK_RATE)
	var walked := _top_speed(bot, false, delta, 0)
	var hopped := _top_speed(bot, true, delta, TICK_RATE * 4)

	# Printed rather than only asserted: a detail line shows only on failure, so an assertion alone would hide the
	# measurement again the moment it passed, which is how this was missed.
	print("  ..    walking %.2f m/s, hopping %.2f m/s, max_speed %.2f, air cap %.2f"
		% [walked, hopped, tunables.max_speed, tunables.max_air_wish_speed])

	_check(
		walked >= tunables.max_speed - 0.5,
		"a bot holding forward on open ground reaches the speed the tunables promise",
		"%.2f m/s against max_speed %.2f" % [walked, tunables.max_speed]
	)
	_check(
		hopped < walked * 0.5,
		"and the same bot holding jump does not, which is why no map check here holds it",
		"%.2f m/s, bled to max_air_wish_speed %.2f" % [hopped, tunables.max_air_wish_speed]
	)

	holder.queue_free()
	remove_child(holder)
	_done()

## Every climb on every map, against what the movement can do.
func _test_reach() -> void:
	_section("what a player can climb")

	var tunables := ArenaPlayer.arena_tunables()

	# The deliberate copy, and the check that the copies agree: a map is content (`by_id` runs with no player in the tree),
	# so the numbers it sizes itself against cannot be read off the player class.
	_check(
		is_equal_approx(ArenaMap.MOVE_SPEED, tunables.max_speed)
		and is_equal_approx(ArenaMap.JUMP_HEIGHT, tunables.jump_height)
		and is_equal_approx(ArenaMap.MOVE_GRAVITY, tunables.gravity)
		and is_equal_approx(ArenaMap.STEP_HEIGHT, tunables.step_height),
		"the numbers the maps are sized against are the ones the server applies",
		"map %.2f/%.2f/%.2f/%.2f vs tunables %.2f/%.2f/%.2f/%.2f" % [
			ArenaMap.MOVE_SPEED, ArenaMap.JUMP_HEIGHT, ArenaMap.MOVE_GRAVITY,
			ArenaMap.STEP_HEIGHT, tunables.max_speed, tunables.jump_height,
			tunables.gravity, tunables.step_height
		]
	)

	# Printed rather than only asserted, as `_test_bot_ground_speed` explains: a detail line shows only on failure. These
	# four numbers are all a map here may ask for.
	print("  ..    a jump peaks at %.2f m; climb limit %.2f m; reach %.2f m flat, "
		% [ArenaMap.JUMP_HEIGHT, ArenaMap.climb_limit(), ArenaMap.jump_reach(0.0)]
		+ "%.2f m onto the limit" % ArenaMap.jump_reach(ArenaMap.climb_limit()))

	var too_high := PackedStringArray()
	var too_far := PackedStringArray()
	var total := 0

	for id in ArenaMap.ids():
		var map := ArenaMap.by_id(id)

		if map == null:
			continue

		for climb in map.climbs:
			total += 1

			# A rise at or under `step_height` is walked and has no airborne phase to spend on a gap, so it is legal only when the
			# boxes touch. dm_atrium's ring is a 0.1 m step with no gap; `jump_reach(0.1)` would call a stair a jump.
			var walked: bool = climb.rise <= ArenaMap.STEP_HEIGHT and climb.gap <= 0.001

			if walked:
				continue

			if climb.rise > ArenaMap.climb_limit():
				too_high.append("%s rises %.2f m" % [climb.name, climb.rise])
				continue

			var reach := ArenaMap.jump_reach(climb.rise)

			if climb.gap > reach:
				too_far.append(
					"%s crosses %.2f m with %.2f m of reach" % [climb.name, climb.gap, reach]
				)

	_check(total >= 20, "every map declares the climbs it expects", "%d climbs" % total)
	_check(
		too_high.is_empty(),
		"and no climb on any map asks for more height than a jump has",
		"; ".join(too_high)
	)
	_check(
		too_far.is_empty(),
		"and none asks a player to cross more air than they can carry",
		"; ".join(too_far)
	)
	_done()

## dot-core's [DotCollisionAudit] over every built-in map as a client draws it: drawn geometry with
## no shape near it is a wall a player walks into.
func _test_collision_audit() -> void:
	_section("every map: nothing drawn is walked through")

	for id in ArenaMap.ids():
		var map := ArenaMap.by_id(id)
		var world := Node3D.new()
		world.add_child(map.to_scene())
		world.add_child(map.to_collision())
		add_child(world)

		var res := DotCollisionAudit.audit(world, true)
		var found := 0
		var examined := 0

		if res.ok:
			var report: DotCollisionAudit = res.value
			found = report.count()
			examined = report.examined
			print("  %s: %d findings of %d examined" % [id, found, examined])

			for line in report.describe_lines().slice(1, 12):
				print("  %s" % line)

		_check(res.ok and found == 0 and examined > 0, "%s: nothing drawn is walked through" % id,
			"" if res.ok else res.error.message)
		world.queue_free()
		await get_tree().physics_frame

	_done()

## `[gate-sweep-1]`, asked of every map over its box list: can a player pass every gap that looks
## like a way through (faces under 0.8 m apart, a jump the map does not declare).
func _test_survey() -> void:
	_section("every map: slots and reach, as a rule")

	for id in ArenaMap.ids():
		var map := ArenaMap.by_id(id)

		if map == null:
			continue

		var slots := ArenaMapSurvey.slots(map)
		var closed := PackedStringArray()
		var tight := 0

		for slot in slots:
			if slot["closed"]:
				closed.append("%.2f m on %s between %s and %s" % [
					slot["gap"], slot["axis"], map.boxes[slot["a"]], map.boxes[slot["b"]]
				])
			else:
				tight += 1

		var surveyed := ArenaMapSurvey.reach(map)
		var unexplained := ArenaMapSurvey.unexplained(map, surveyed)
		var lost := PackedStringArray()

		for region in unexplained:
			lost.append("%.1f m² at y %.2f, %s..%s" % [
				region["area"], region["height"], region["from"], region["to"]
			])

		print("  ..    %s: %.0f m² standable, %.0f reached, %.1f unreached (%d declared "
			% [id, surveyed["standable"], surveyed["reached"], surveyed["unreached"],
				map.out_of_reach.size()]
			+ "out of reach), %.1f trapped; %d closed slots, %d tight (0.8-1.05 m)"
			% [surveyed["trapped"], closed.size(), tight])

		_check(
			closed.is_empty(),
			"%s: no gap that looks like a way through is narrower than a player" % id,
			"; ".join(closed)
		)
		_check(
			surveyed["spawns_reached"] == map.spawns.size(),
			"%s: every spawn stands on ground the flood fill reaches" % id,
			"%d of %d" % [surveyed["spawns_reached"], map.spawns.size()]
		)
		# A spawn whose eye looks at a wall from under 2.5 m is a player who respawns with
		# their nose against it (dm_box's two axis spawns did, a metre from a 2.7 m crate).
		var nosed := PackedStringArray()
		for at in map.spawns:
			var eye := at.origin + Vector3.UP * 1.6
			var ahead := eye + (-at.basis.z) * 2.5
			for box in map.boxes:
				if box.intersects_segment(eye, ahead) != null:
					nosed.append(str(at.origin))
					break
		_check(nosed.is_empty(), "%s: no spawn faces a wall within 2.5 m" % id, "; ".join(nosed))
		_check(
			unexplained.is_empty(),
			"%s: every surface nobody can reach is one the map says is out of reach" % id,
			"; ".join(lost)
		)
		_check(
			float(surveyed["trapped"]) < 0.01,
			"%s: and nowhere a player can reach is somewhere they cannot leave" % id,
			"%.2f m²: %s" % [surveyed["trapped"], str(surveyed["trapped_regions"])]
		)

	# --- The survey itself, shown the three things it is for ---------------

	var bad := ArenaMap.new()
	bad.id = &"survey_fixture"
	bad.extent = 8.0
	bad.wall_height = 6.0
	# Two walls 0.5 m apart, the slot dm_pit's shelf would have made.
	bad.add_box(AABB(Vector3(-7.0, 0.0, 4.0), Vector3(4.0, 2.0, 1.0)))
	bad.add_box(AABB(Vector3(-7.0, 0.0, 5.5), Vector3(4.0, 2.0, 1.0)))
	# A tower 4 m high with nothing to climb it by — 2 m over the courtyard's wall tops too, which a
	# 3 m tower was not: the survey jumped onto it from the wall, correctly.
	var tower := AABB(Vector3(4.0, 0.0, 4.0), Vector3(2.0, 4.0, 2.0))
	bad.add_box(tower)
	# A courtyard walled at 2 m, reached over its west wall from a 1 m crate and left
	# by nothing: 2 m is over the climb limit from inside.
	bad.add_box(AABB(Vector3(0.0, 0.0, -4.0), Vector3(0.5, 2.0, 4.0)))
	bad.add_box(AABB(Vector3(3.5, 0.0, -4.0), Vector3(0.5, 2.0, 4.0)))
	bad.add_box(AABB(Vector3(0.0, 0.0, -4.5), Vector3(4.0, 2.0, 0.5)))
	bad.add_box(AABB(Vector3(0.0, 0.0, 0.0), Vector3(4.0, 2.0, 0.5)))
	bad.add_box(AABB(Vector3(-1.5, 0.0, -3.0), Vector3(1.5, 1.0, 2.0)))
	bad.add_perimeter()
	bad.add_spawn(Transform3D(Basis(), Vector3(-5.0, 0.1, -5.0)))

	var found := false

	for slot in ArenaMapSurvey.slots(bad):
		if slot["closed"] and absf(float(slot["gap"]) - 0.5) < 0.01:
			found = true

	_check(found, "the survey finds a 0.5 m slot when there is one")

	var fixture := ArenaMapSurvey.reach(bad)
	var tower_lost := false

	for region in ArenaMapSurvey.unexplained(bad, fixture):
		if is_equal_approx(float(region["height"]), 4.0):
			tower_lost = true

	_check(tower_lost, "and a tower nothing climbs, as floor nobody reaches")

	bad.add_out_of_reach(tower)
	var still := 0

	for region in ArenaMapSurvey.unexplained(bad, fixture):
		if is_equal_approx(float(region["height"]), 4.0):
			still += 1

	_check(still == 0, "and stops calling it a fault once the map declares it")
	_check(
		float(fixture["trapped"]) > 2.0,
		"and a walled courtyard you can drop into and not leave, as a trap",
		"%.2f m² trapped" % fixture["trapped"]
	)
	_done()
