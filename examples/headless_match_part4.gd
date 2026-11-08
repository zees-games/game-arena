extends "headless_match_part3.gd"

const ArenaTestToys := preload("arena_test_toys.gd")

## dot-props' toys on the built-in maps, on a headless authority: every map's built, clear of its
## boxes and spawns; a walk into a ball sends it on; a shot pushes it and is still the combat's.
func _test_toys() -> void:
	_section("the maps' toys")
	var bad: Array = []
	var game: ArenaGame = null
	# dm_box last, and kept: each game's level and toys share this one physics space, so the
	# others are freed before the next is built.
	for id: StringName in [&"dm_atrium", &"dm_pit", &"dm_box"]:
		var map: ArenaMap = ArenaTestToys.give(ArenaMap.by_id(id))
		var g := ArenaGame.new()
		g.name = "ToyGame_%s" % id
		g.tick_rate = TICK_RATE
		g.headless = true
		g.register_service = false
		# A world of its own: every other game this suite has built is in the default one,
		# on dm_box, and its level would be under these toys too.
		var view := SubViewport.new()
		view.own_world_3d = true
		view.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(view)
		_toy_views.append(view)
		view.add_child(g)
		var ready := g.setup(map)
		if not ready.ok or g.toys == null:
			bad.append("%s: %s" % [id, str(ready.error)])
			g.get_parent().remove_child(g)
			g.queue_free()
			continue
		if g.toys.count() != map.toys.size() or map.toys.is_empty() or not g.toys.missing.is_empty():
			bad.append("%s: %d of %d built" % [id, g.toys.count(), map.toys.size()])
		for toy in g.toys.toys:
			var box := AABB(toy.global_position + Vector3(-0.6, 0.05, -0.6), Vector3(1.2, 1.2, 1.2))
			for b in map.boxes:
				if b.intersects(box):
					bad.append("%s: %s %d in a box" % [id, toy.def["id"], toy.index])
					break
			for spawn in map.spawns:
				if Vector2(spawn.origin.x - toy.global_position.x, spawn.origin.z - toy.global_position.z).length() < 2.4:
					bad.append("%s: %s %d on a spawn" % [id, toy.def["id"], toy.index])
		for _i in range(120):
			await get_tree().physics_frame
		for toy in g.toys.toys:
			if toy.body.global_position.distance_to(toy.rest.origin) > 0.5:
				bad.append("%s: %s %d strayed to %s" % [id, toy.def["id"], toy.index, toy.body.global_position.snapped(Vector3.ONE * 0.1)])
		if id == &"dm_box":
			game = g
		else:
			g.get_parent().remove_child(g)
			g.free()
	_check(bad.is_empty() and game != null, "every built-in map's toys are built, clear of its boxes and spawns, and stay put", "; ".join(bad.slice(0, 6)))
	if game == null:
		_done()
		return

	game.start(0)
	var _a := game.add_player(950, "Kicker")
	var _b := game.add_player(951, "Target")
	game.match_node.rules.respawn_delay_sec = 120.0
	_go_live(game)
	var ball := game.toys.toy(0)
	var b0 := ball.body.global_position

	# Walked into.
	var kicker := game.player_for(950)
	_stand(game, 950, b0 + Vector3(-0.8, -0.5, 0.0))
	for _i in range(10):
		kicker.controller.state.velocity = Vector3(6.0, 0.0, 0.0)
		game._advance_toys(1.0 / float(TICK_RATE))
		await get_tree().physics_frame
	for _i in range(30):
		await get_tree().physics_frame
	_check(ball.body.global_position.x > b0.x + 0.5, "a player walking into a beach ball sends it on ahead",
		"%.2f m" % (ball.body.global_position.x - b0.x))

	# Shot: the ball goes, and the combat's own trace sees straight through where it stood, so
	# the shot goes on to whoever is behind it: a toy is never cover.
	var other := game.toys.toy(1)
	var o0 := other.body.global_position
	var shot := DotShot.new()
	shot.attacker = 950
	shot.tick = game.current_tick()
	shot.origin = o0 + Vector3(0.0, 0.0, 6.0)
	shot.direction = Vector3(0.0, 0.0, -1.0)
	shot.damage = 20.0
	shot.max_range = 40.0
	var clear_through := game.combat.trace.line_of_sight(shot.origin, o0 + Vector3(0.0, 0.0, -2.0))
	game._shoot_toys([shot] as Array[DotShot])
	for _i in range(30):
		await get_tree().physics_frame
	_check(other.body.global_position.z < o0.z - 0.4 and clear_through,
		"a shot pushes the ball it passes, and the combat's trace sees through it: a toy is no cover",
		"moved %.2f m, trace clear %s" % [o0.z - other.body.global_position.z, str(clear_through)])

	# A rocket's blast beside the barrel.
	var barrel := game.toys.toy(3)
	var r0 := barrel.body.global_position
	var spawn := DotWeaponSpawn.new()
	spawn.splash_radius = 4.0
	game._on_detonated_near_toys(r0 + Vector3(-1.5, 0.0, 0.0), spawn)
	for _i in range(30):
		await get_tree().physics_frame
	_check(barrel.body.global_position.distance_to(r0) > 0.3, "a blast throws the barrel beside it", "%.2f m" % barrel.body.global_position.distance_to(r0))

	# Live again: home.
	game._on_match_state_changed(DotMatch.State.WARMUP, DotMatch.State.LIVE)
	await get_tree().physics_frame
	_check(ball.body.global_position.distance_to(ball.rest.origin) < 0.05 and barrel.body.global_position.distance_to(barrel.rest.origin) < 0.05,
		"a round going live puts every toy home")

	var _off := game.toy_rules.set_cvar(DotPropToyRules.CVAR_ENABLED, "0")
	_check(not ball.visible and game.toys.shot_along(o0 + Vector3(0, 0.4, 6), Vector3(0, 0, -1), 20.0, 20.0, 1) == -1,
		"sv_toys 0 takes them away")
	var _on := game.toy_rules.set_cvar(DotPropToyRules.CVAR_ENABLED, "1")
	game.get_parent().remove_child(game)
	game.queue_free()
	for view: Node in _toy_views:
		remove_child(view)
		view.queue_free()
	_toy_views.clear()
	_done()

func _test_content_rest(schema: DotLoadoutSchema, unowned: DotLoadout) -> void:
	unowned.set_item(&"primary", AwWeaponIds.LAUNCHER)
	unowned.set_item(&"secondary", AwWeaponIds.PISTOL)
	_check(
		not DotLoadoutValidator.validate(
			unowned, schema, DotLoadoutEntitlements.none()
		).ok,
		"and refuses the launcher to a player who has not unlocked it"
	)
	_done()

# --- Content ---------------------------------------------------------------

func _test_content() -> void:
	_section("content")

	for weapon in ArenaContent.weapons():
		_check(
			weapon.validate().ok,
			"%s is a valid weapon" % weapon.id,
			str(weapon.validate().error)
		)

	var catalogue := ArenaContent.catalogue()
	_check(catalogue.validate().ok, "the item catalogue validates")

	var schema := ArenaContent.loadout_schema()
	_check(schema.validate().ok, "the loadout schema validates",
		str(schema.validate().error))

	# Every weapon must be reachable from a loadout. A content set where a weapon exists and no
	# loadout can name it is a weapon nobody will ever hold, and nothing reports it.
	var everything := DotLoadoutEntitlements.everything()
	var reachable := {}

	for slot in schema.slot_ids():
		for item in schema.choices_for(slot, everything):
			reachable[item.id] = true

	for weapon in ArenaContent.weapons():
		_check(
			reachable.has(weapon.id),
			"%s can be put in a loadout" % weapon.id
		)

	# Free by default; a server that prices weapons gets the budget enforced.
	var greedy := DotLoadout.empty(&"arena")
	greedy.set_item(&"melee", AwWeaponIds.KNIFE)
	greedy.set_item(&"primary", AwWeaponIds.LAUNCHER)
	greedy.set_item(&"secondary", AwWeaponIds.REVOLVER)
	greedy.set_item(&"thrown", AwWeaponIds.FRAG)
	greedy.set_item(&"gear", &"armour")
	_check(
		DotLoadoutValidator.validate(greedy, schema, everything).ok,
		"a heavy with armour and a grenade is free by default"
	)
	var launcher := schema.catalogue.find(AwWeaponIds.LAUNCHER)
	launcher.cost = 6
	schema.point_budget = 5
	_check(
		not DotLoadoutValidator.validate(greedy, schema, everything).ok,
		"a server that prices the launcher and sets a budget refuses it"
	)
	launcher.cost = 0
	schema.point_budget = 0

	var sensible := DotLoadout.empty(&"arena")
	sensible.set_item(&"melee", AwWeaponIds.KNIFE)
	sensible.set_item(&"primary", AwWeaponIds.RIFLE)
	sensible.set_item(&"secondary", AwWeaponIds.PISTOL)
	sensible.set_item(&"thrown", AwWeaponIds.FRAG)
	sensible.set_item(&"gear", &"armour")
	_check(
		DotLoadoutValidator.validate(sensible, schema, everything).ok,
		"and permits a normal one"
	)

	# A melee weapon in the primary slot is a player who spawns with nothing to shoot.
	var saved := DotLoadout.empty(&"arena")
	saved.set_item(&"primary", AwWeaponIds.RIFLE)
	saved.set_item(&"secondary", AwWeaponIds.PISTOL)
	var _changes := DotLoadoutValidator.conform(saved, schema, everything)
	_check(
		saved.item_in(&"melee") == ArenaWeaponRoles.resolve(&"melee")
		and saved.item_in(&"thrown") == ArenaWeaponRoles.resolve(&"thrown")
		and saved.item_in(&"primary") == AwWeaponIds.RIFLE
		and DotLoadoutValidator.validate(saved, schema, everything).ok,
		"an old primary-and-sidearm loadout gains a knife and a frag and keeps its choices"
	)
	_check(
		schema.default_loadout().item_in(&"thrown") == ArenaWeaponRoles.resolve(&"thrown"),
		"and the default loadout has a grenade in it, which an optional slot never put there"
	)

	var knives := DotLoadout.empty(&"arena")
	knives.set_item(&"primary", AwWeaponIds.KNIFE)
	knives.set_item(&"secondary", AwWeaponIds.PISTOL)
	_check(
		not DotLoadoutValidator.validate(knives, schema, everything).ok,
		"and refuses a knife as a primary"
	)

	# The launcher is the one paid item, so an unentitled player must not get it — which is dot-
	# loadout's default and is worth checking here because this game's entitlement source is the.
	var unowned := DotLoadout.empty(&"arena")
	_test_content_rest(schema, unowned)

func _test_map() -> void:
	_section("map")

	var map := ArenaMap.dm_box()

	_check(map.boxes.size() > 8, "the map has geometry", str(map.boxes.size()))
	_check(map.spawns.size() >= 4, "and spawn points", str(map.spawns.size()))

	# The whole point of ArenaMap: one description, three representations, and they
	# cannot disagree because they are generated from the same list.
	var body := map.to_fps_body()
	var trace := map.to_trace()

	_check(
		body.boxes.size() == map.boxes.size(),
		"the movement backend has every box",
		"%d vs %d" % [body.boxes.size(), map.boxes.size()]
	)
	_check(
		trace.boxes.size() == map.boxes.size(),
		"and so does the shot-tracing one"
	)

	# Both must agree that the perimeter is solid. A wall the shots pass through but
	# the players do not is exactly the drift the single description prevents.
	var outward := trace.ray(Vector3(0.0, 2.0, 0.0), Vector3.RIGHT, 100.0)
	_check(
		outward.ok() and outward.blocked,
		"a shot at the outer wall is stopped"
	)
	_check(
		outward.distance < map.extent + 3.0,
		"at the wall rather than beyond it",
		"%.1f m" % outward.distance
	)

	# Every spawn must be inside the room and above the floor. A spawn outside the
	# perimeter is a player who appears in the void.
	var outside := 0
	for at in map.spawns:
		if absf(at.origin.x) > map.extent or absf(at.origin.z) > map.extent:
			outside += 1
		if at.origin.y < map.floor_y:
			outside += 1
	_check(outside == 0, "every spawn is inside the room", "%d outside" % outside)

	# The generated dev texture, so the "no art assets" claim is checked rather than
	# asserted in a comment.
	var texture := ArenaMap.dev_texture(64, 16)
	_check(texture != null and texture.get_width() == 64, "the dev texture generates")
	_done()

## The built-in maps' paint and lighting.
func _test_map_look() -> void:
	_section("map paint and lighting")

	var painted := 0
	var materials := {}
	var roles := {}
	var geometry_kept := true

	for id in ArenaMap.ids():
		var map := ArenaMap.by_id(id)
		var before := map.boxes.duplicate()
		var level := map.to_scene()

		for child in level.get_children():
			for mesh in child.get_children():
				if mesh is MeshInstance3D and (mesh as MeshInstance3D).material_override != null:
					painted += 1
					materials[(mesh as MeshInstance3D).material_override] = true

		for box in map.boxes:
			roles[ArenaMapPaint.role_of(box, map.extent)] = true

		geometry_kept = geometry_kept and map.boxes == before
		level.free()

	var expected := 0
	for id in ArenaMap.ids():
		expected += ArenaMap.by_id(id).boxes.size() + 1
	_check(painted == expected, "every box and the floor is drawn with a material", "%d of %d" % [painted, expected])
	_check(geometry_kept, "painting a map leaves its box list as it was")

	# Baked light: every built-in map has a lightmap made from these boxes (a stale one is drawn
	# with live light and a WARN, so the check is what keeps a box edit from shipping unbaked).
	if ArenaMap.can_bake():
		var all_baked := true
		var stale := PackedStringArray()

		for id in ArenaMap.ids():
			var map := ArenaMap.by_id(id)
			var data := ResourceLoader.load(ArenaMap.BAKE_PATH % String(id)) as LightmapGIData if ResourceLoader.exists(ArenaMap.BAKE_PATH % String(id)) else null

			if data == null or str(data.get_meta(&"dot_light_fingerprint", "")) != map.light_fingerprint():
				all_baked = false
				stale.append(String(id))

		_check(all_baked, "every built-in map has a bake made from its current boxes (tools/bake_lightmaps.sh)", ", ".join(stale))
		var sample := ArenaMap.lightmap_box(Vector3(2, 3, 4), false)
		_check(
			(sample.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2] as PackedVector2Array).size() == 36 and sample.lightmap_size_hint != Vector2i.ZERO,
			"a lightmapped box carries a second UV set and a size hint"
		)
		_check(ArenaMap.dm_box().light_fingerprint() == ArenaMap.dm_box().light_fingerprint(), "a map's bake fingerprint is the same on every build")
	_check(materials.size() < painted / 4, "boxes of one colour share one material", "%d materials for %d boxes" % [materials.size(), painted])
	_check(
		roles.has(ArenaMapPaint.Role.WALL) and roles.has(ArenaMapPaint.Role.TREAD) and roles.has(ArenaMapPaint.Role.COVER),
		"the maps have walls, stairs and cover, so all three colours are in use",
		str(roles.keys())
	)

	# Colour by place: the four sides of a map are four different pastels, so the wall
	# behind a fight says which side it is on.
	var sides := {}
	for at in [Vector3(0, 0, -20), Vector3(20, 0, 0), Vector3(0, 0, 20), Vector3(-20, 0, 0)]:
		sides[ArenaMapPaint.zone_colour(at, [] as Array[Dictionary], 24.0).to_html()] = true
	_check(sides.size() == 4, "the four sides are four colours", str(sides.size()))

	var atrium := ArenaMap.dm_atrium()
	_check(
		ArenaMapPaint.zone_colour(Vector3(-15.0, 2.0, -12.0), atrium.paint_zones, atrium.extent) == ArenaMapPaint.LAVENDER,
		"dm_atrium's keep is its own named zone"
	)
	_check(
		ArenaMapPaint.zone_colour(Vector3(-20.0, 1.0, -27.0), atrium.paint_zones, atrium.extent) == ArenaMapPaint.AQUA,
		"and so is its north gallery, the wall-run ledges"
	)

	var lit := ArenaMapLighting.build(atrium)
	var env: Environment = null
	var sun: DirectionalLight3D = null
	var fill: DirectionalLight3D = null
	for child in lit.get_children():
		if child is WorldEnvironment:
			env = (child as WorldEnvironment).environment
		elif child is DirectionalLight3D and child.name == "Sun":
			sun = child
		elif child is DirectionalLight3D and child.name == "Fill":
			fill = child
	_check(sun != null and sun.shadow_enabled, "a built-in map has a sun that casts shadows")
	# dot-lighting's painted(): the shade's shape comes from a shadowless fill where the
	# Compatibility renderer has no occlusion, and the grade from the adjustment pass.
	_check(fill != null and not fill.shadow_enabled and env != null and env.adjustment_enabled,
		"and a shadowless fill and a grade (dot-lighting's painted())")
	_check(
		env != null and env.background_mode == Environment.BG_SKY and env.sky != null,
		"and a sky, not a flat background"
	)
	_check(
		env != null and env.tonemap_mode != Environment.TONE_MAPPER_LINEAR and env.glow_enabled,
		"tone-mapped, with glow"
	)
	var top: Array = atrium.lighting["sky_top"]
	var sky_material := env.sky.sky_material as ShaderMaterial if env != null and env.sky != null else null
	var zenith = sky_material.get_shader_parameter("top_colour") if sky_material != null else null
	_check(
		zenith is Color and zenith.is_equal_approx(Color(top[0], top[1], top[2])),
		"whose zenith is the map's own sky_top"
	)
	lit.free()
	_done()

## `dm_pit`'s shelf stair, the pit floor to the third tier, walked.
func _test_pit_shelf_stair(map: ArenaMap, shelf: AABB, perch: AABB) -> void:
	var tunables := ArenaPlayer.arena_tunables()
	var shelf_top: float = shelf.position.y + shelf.size.y
	var shelf_east: float = shelf.position.x + shelf.size.x
	var treads: Array[AABB] = []
	var south_east_foot := AABB()

	for box in map.boxes:
		if is_equal_approx(box.position.z, 7.5) and is_equal_approx(box.size.z, 3.0) \
				and box.position.x < 2.0 - 0.001:
			treads.append(box)
		elif is_equal_approx(box.position.x, 2.0) and is_equal_approx(box.position.z, 7.5):
			south_east_foot = box

	treads.sort_custom(func(a: AABB, b: AABB) -> bool: return a.size.y < b.size.y)

	if not _check(treads.size() == 11, "dm_pit: the shelf stair has eleven boxes, the landing under the bridge one of them", str(treads.size())):
		return

	var steep := PackedStringArray()
	var below: float = south_east_foot.size.y

	for tread in treads:
		var rise: float = tread.size.y - below

		if rise >= tunables.step_height:
			steep.append("%.2f at x %.2f" % [rise, tread.position.x])

		below = tread.size.y

	var lip: float = shelf_top - treads[-1].size.y
	steep.append_array(PackedStringArray() if lip < tunables.step_height else PackedStringArray(["shelf lip %.2f" % lip]))

	_check(
		steep.is_empty(),
		"and every rise on it, the shelf's lip included, is under step_height",
		", ".join(steep)
	)
	_check(
		absf(treads[-1].position.x - shelf_east) < 0.001
			and absf(treads[0].end.x - south_east_foot.position.x) < 0.001
			and treads[0].size.y > south_east_foot.size.y,
		"and it runs flush from the shelf to the south-east stair's first tread",
		"top tread at x %.2f against the shelf at %.2f; foot ends at %.2f, the other stair starts at %.2f"
			% [treads[-1].position.x, shelf_east, treads[0].end.x, south_east_foot.position.x]
	)

	# Headroom: the north-south bridge crosses the lane. Every tread with a box over
	# it keeps `stand_height` clear, or the stair is a wall at the height of a head.
	var low := PackedStringArray()

	for tread in treads:
		for box in map.boxes:
			if box.position.y >= tread.end.y - 0.001 and box.position.x < tread.end.x \
					and box.end.x > tread.position.x and box.position.z < tread.end.z \
					and box.end.z > tread.position.z:
				var clear: float = box.position.y - tread.end.y

				if clear < tunables.stand_height:
					low.append("%.2f over the tread at x %.2f" % [clear, tread.position.x])

	_check(
		low.is_empty(),
		"and a player stands upright on every tread, under the bridge included",
		", ".join(low)
	)

	var walker := ArenaPlayer.new()
	walker.name = "ShelfStairWalker"
	add_child(walker)
	walker.setup(ArenaPlayer.Mode.HEADLESS, map, 9005, "shelf stair walker")

	var delta := 1.0 / 64.0
	var tick := 0

	# From the pit floor: step south onto the lowest tread (the south-east stair's first, 0.36), stop, turn west and walk
	# up. Arrival is grounded above 4.45 west of the shelf's east face. No jump anywhere.
	walker.controller.teleport(Vector3(2.45, 0.1, 6.0), 180.0, 0.0)

	for step in range(20):
		var command := DotFpsCommand.new()
		command.yaw = 180.0
		command.move = Vector2(0.0, 1.0)
		walker.controller.apply_command(command)
		walker.controller.simulate_tick(tick, delta)
		tick += 1

	for step in range(24):
		var command := DotFpsCommand.new()
		command.yaw = 90.0
		walker.controller.apply_command(command)
		walker.controller.simulate_tick(tick, delta)
		tick += 1

	var in_valley: Vector3 = walker.controller.state.position
	var from_floor := false

	for step in range(64 * 3):
		var command := DotFpsCommand.new()
		command.yaw = 90.0
		command.move = Vector2(0.0, 1.0)
		walker.controller.apply_command(command)
		walker.controller.simulate_tick(tick, delta)
		tick += 1

		var at: Vector3 = walker.controller.state.position

		if walker.controller.state.is_grounded() and at.y > shelf_top - 0.05 and at.x < shelf_east:
			from_floor = true
			break

	var ended: Vector3 = walker.controller.state.position

	_check(
		from_floor and in_valley.y > 0.3,
		"a bot steps off the pit floor into the valley and walks up onto the shelf",
		"valley at (%.1f, %.2f, %.1f), ended at (%.1f, %.2f, %.1f)"
			% [in_valley.x, in_valley.y, in_valley.z, ended.x, ended.y, ended.z]
	)

	# The valley end to end: from the east arm facing west (yaw 90), forward only, down the south-east stair and up the shelf
	# stair. The time from the stair's foot (x = 2) to standing on the shelf is the pace.
	walker.controller.teleport(Vector3(12.5, 3.7, 9.0), 90.0, 0.0)

	var left_arm := -1
	var foot := -1
	var top := -1
	var top_x := 0.0
	var lowest := 99.0

	for step in range(64 * 5):
		var command := DotFpsCommand.new()
		command.yaw = 90.0
		command.move = Vector2(0.0, 1.0)
		walker.controller.apply_command(command)
		walker.controller.simulate_tick(tick, delta)
		tick += 1

		var at: Vector3 = walker.controller.state.position
		lowest = minf(lowest, at.y)

		if left_arm < 0 and at.x < 11.0:
			left_arm = step

		if foot < 0 and at.x <= 2.0:
			foot = step

		if walker.controller.state.is_grounded() and at.y > shelf_top - 0.05 and at.x < shelf_east:
			top = step
			top_x = at.x
			break

	var climb_time := float(top - foot) * delta
	var pace := (2.0 - top_x) / climb_time if top > foot and foot >= 0 else 0.0
	var route_time := float(top - left_arm) * delta if top > left_arm and left_arm >= 0 else 0.0
	var arrived: Vector3 = walker.controller.state.position

	print("  ..    dm_pit shelf stair: east arm to shelf %.1f m in %.2f s, down to %.2f; "
		% [11.0 - top_x, route_time, lowest]
		+ "stair %.1f m in %.2f s, %.2f m/s against max_speed %.2f"
		% [2.0 - top_x, climb_time, pace, tunables.max_speed])

	_check(
		top >= 0 and lowest < 0.8,   # the foot box is 0.72; a running hull may skip the 0.36 tread under it
		"a bot runs the valley from the east arm down and up onto the shelf, jump never pressed",
		"ended at (%.1f, %.2f, %.1f), lowest %.2f" % [arrived.x, arrived.y, arrived.z, lowest]
	)
	_check(
		pace >= tunables.max_speed - 1.5,
		"and climbs the shelf stair at running pace",
		"%.2f m/s against max_speed %.2f" % [pace, tunables.max_speed]
	)

	# Held on for another half second the run ends against the perch, still on the
	# shelf; and one hop from there is the perch.
	for step in range(32):
		var command := DotFpsCommand.new()
		command.yaw = 90.0
		command.move = Vector2(0.0, 1.0)
		walker.controller.apply_command(command)
		walker.controller.simulate_tick(tick, delta)
		tick += 1

	var held: Vector3 = walker.controller.state.position

	_check(
		walker.controller.state.is_grounded() and held.y > shelf_top - 0.05
			and held.x > perch.end.x,
		"and the run ends against the perch, standing on the shelf",
		"ended at (%.1f, %.2f, %.1f)" % [held.x, held.y, held.z]
	)

	var perched := false

	for step in range(64 * 2):
		var command := DotFpsCommand.new()
		command.yaw = 90.0
		command.move = Vector2(0.0, 1.0)
		command.set_button(DotFpsCommand.BUTTON_JUMP, true)
		walker.controller.apply_command(command)
		walker.controller.simulate_tick(tick, delta)
		tick += 1

		var at: Vector3 = walker.controller.state.position

		if walker.controller.state.is_grounded() and at.y > perch.end.y - 0.05:
			perched = true
			break

	var hopped: Vector3 = walker.controller.state.position

	_check(
		perched,
		"and one hop from there is the perch, so the floor's stair leads to the top tier",
		"ended at (%.1f, %.2f, %.1f)" % [hopped.x, hopped.y, hopped.z]
	)

	walker.queue_free()
	remove_child(walker)

	# --- The trade, traced ----------------------------------------------------
	var trace := map.to_trace()
	var eye := Vector3(perch.get_center().x, perch.end.y + 1.6, perch.get_center().z)
	var hidden := PackedStringArray()

	# The one tread east of the north-south bridge is behind it from the perch, and
	# that is the valley's only cover: the stair proper is everything west of it.
	for index in range(treads.size()):
		if treads[index].position.x >= 1.0 - 0.001:
			continue

		var chest := Vector3(treads[index].get_center().x, treads[index].end.y + 1.2, 9.0)
		var line := chest - eye
		var hit := trace.ray(eye, line.normalized(), line.length() - 0.05)

		if hit.ok() and hit.blocked:
			hidden.append("tread %d" % (index + 1))

	_check(
		hidden.is_empty(),
		"and the perch sees down every tread of the shelf stair west of the bridge",
		", ".join(hidden)
	)
