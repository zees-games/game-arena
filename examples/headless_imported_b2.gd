extends "headless_imported_b1.gd"

const ArenaMode := preload("../game/arena_mode.gd")
const ArenaModes := preload("../game/arena_modes.gd")
const ArenaPaths := preload("../game/arena_paths.gd")


const ArenaMapLighting := preload("../maps/arena_map_lighting.gd")
const ArenaDrops := preload("../game/arena_drops.gd")
const ArenaEvents := preload("../game/arena_events.gd")
const ArenaJail := preload("../maps/arena_jail.gd")

## The combat surf maps game-g2gfast imported, played as an arena deathmatch. [codeblock] godot
## --headless --path .


const BOTS := 6


const PLAY_SECONDS := 40.0


## A score limit small enough that six bots reach it inside [constant PLAY_SECONDS].
const SCORE_LIMIT := 4


const SECTIONS := 25
## Fixed checks, plus one audit check per imported map: the catalogue grows without this changing.
const CHECKS_FIXED := 153


func _finish() -> void:
	# Freed here, not left to the engine at exit: its bots' navigation RIDs and the
	# resources it holds are then released before the leak report.
	if _game != null:
		remove_child(_game)
		_game.free()
		_game = null

	_report_sections(_entered, _completed, _expected_sections(), _expected_checks())


## What a whole run enters and checks; a shard of it overrides these (headless_imported.gd).
func _expected_sections() -> int:
	return SECTIONS


func _expected_checks() -> int:
	return CHECKS_FIXED + ArenaMap.imported_ids().size()


func _test_catalogue() -> void:
	_section("found by its manifest, catalogued, and in the rotation by name")

	var ids := ArenaMap.imported_ids()
	_check(ids.has(MAP), "%s is found (%d combat surf maps: %s)" % [MAP, ids.size(), ids])

	var not_arena: Array[String] = []

	for id in ids:
		if str(ArenaImportedMaps.manifest(id).get("kind", "")) != "arena":
			not_arena.append(String(id))

	_check(not_arena.is_empty(),
		"and every map found says \"kind\": \"arena\" itself (%s do not)" % [not_arena])

	_check(ArenaMap.by_id(MAP) != null and ArenaMap.by_id(MAP).is_imported(),
		"ArenaMap.by_id builds it, as an imported map")

	ArenaMaps.imported_rotation = ArenaMaps.IMPORTED_ROTATION_DEFAULT
	var catalogue := ArenaMaps.catalogue()
	var def := catalogue.get_map(MAP)
	_check(def != null and bool(def.meta.get("imported", false)),
		"the catalogue carries it, marked imported")
	_check(def != null and def.version.begins_with("0.0.0-") and def.version.length() == 18,
		"at a version hashed from its manifest (%s)" % (def.version if def != null else "?"))

	var on: Array[String] = []

	for map in catalogue.maps:
		if bool(map.meta.get("imported", false)) and map.enabled:
			on.append(String(map.id))

	on.sort()
	_check(on.size() == ids.size(),
		"the default rotation offers every combat surf map found (%d of %d)" % [on.size(), ids.size()])

	ArenaMaps.imported_rotation = "all"
	ArenaMaps.apply_rotation(catalogue)
	var all_on := catalogue.maps.filter(
		func(m: DotMapDef) -> bool: return bool(m.meta.get("imported", false)) and m.enabled
	).size()
	ArenaMaps.imported_rotation = "none"
	ArenaMaps.apply_rotation(catalogue)
	var none_on := catalogue.maps.filter(
		func(m: DotMapDef) -> bool: return bool(m.meta.get("imported", false)) and m.enabled
	).size()
	ArenaMaps.imported_rotation = ArenaMaps.IMPORTED_ROTATION_DEFAULT
	_check(all_on == ids.size() and none_on == 0,
		"and `all` / `none` change it on a running catalogue (%d / %d)" % [all_on, none_on])

	_check(
		ArenaMaps.supports_mode(def, ArenaModes.by_id(&"ffa"))
		and ArenaMaps.supports_mode(def, ArenaModes.by_id(&"gungame"))
		and not ArenaMaps.supports_mode(def, ArenaModes.by_id(&"siege"))
		and not ArenaMaps.supports_mode(def, ArenaModes.by_id(&"koth")),
		"it hosts the deathmatch modes and refuses the ones built out of boxes"
	)

	_done()


## The three maps each put one rule in the state it exists for: surf_mai_remix has a sun and a blue
## ambient of its own, surf_29_12_06 the editor's white ambient under a sky the table knows,
## surf_buck_wild a sky it packed.
func _test_worlds() -> void:
	_section("a map with a converted world is drawn from it, the rest keep their legacy meshes")
	var linked := ArenaBspMap.world_prefix("surf_grave_reloaded") != ""
	if not linked:
		_line("  (no res://worlds link: skipped)")
		for _i in 5:
			_check(true, "skipped without the link")
		_done()
		return
	var map := ArenaMap.by_id(&"surf_grave_reloaded")
	ArenaMap.use_worlds = true
	var drawn := map.to_scene()
	var world := drawn.get_node_or_null("World")
	_check(world != null and world.get_child_count() > 0, "surf_grave_reloaded is drawn from its world pack")
	_check(drawn.get_children().all(func(c: Node) -> bool: return not (c is MeshInstance3D)), "the legacy meshes are gone")
	drawn.free()
	ArenaMap.use_worlds = false
	var legacy := map.to_scene()
	_check(legacy.get_node_or_null("World") is MeshInstance3D and legacy.get_children().any(func(c: Node) -> bool: return c is MeshInstance3D), "with worlds off the legacy meshes are drawn")
	legacy.free()
	_check(ArenaBspMap.world_prefix("surf_no_such_map") == "", "a map without a world has no prefix")
	var mount := OS.get_temp_dir().path_join("arena_world_mount")
	var wdir := mount.path_join("worlds/surf_grave_reloaded")
	DirAccess.make_dir_recursive_absolute(wdir)
	for ext in ["json", "bin"]:
		FileAccess.open(wdir.path_join("surf_grave_reloaded." + ext), FileAccess.WRITE).store_string("x")
	_check(ArenaBspMap.world_prefix("surf_grave_reloaded", mount) == wdir.path_join("surf_grave_reloaded"), "a delivered map's own worlds/ wins over the linked root")
	_done()


func _test_prop_visuals() -> void:
	_section("no prop collides without a visual: every library model a world's prop names is mapped to a store file")
	var worlds := 0
	var no_store := 0
	var absent := 0
	var props := 0
	var unseen: Array[String] = []
	for root in [ArenaBspMap.WORLD_ROOT, ArenaBspMap.WORLD_ROOT_DM]:
		var base := ArenaPaths.rebase(root)
		for id in DirAccess.get_directories_at(base):
			var manifest := base.path_join(id).path_join(id + ".json")
			if not FileAccess.file_exists(manifest):
				continue
			var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest))
			if not doc is Dictionary:
				continue
			worlds += 1
			var licence: Dictionary = (doc as Dictionary).get("licence", {})
			# simplify_path is lexical and worlds/ is a link: follow the link first, as the importer's reader does.
			var store := DotMapBspMesh.real_dir(base.path_join(id)).path_join(str(licence.get("model_store", "model-library"))).simplify_path()
			if not DirAccess.dir_exists_absolute(store):
				# The gitignored model-library is not copied beside worlds/ when the project is offloaded
				# through absolute worktree links (gpu.sh only follows ../sibling links): nothing to resolve.
				no_store += 1
				continue
			var files := {}
			for row: Dictionary in licence.get("model_stand_ins", []):
				if row.has("store_file"):
					files[str(row["stand_in"])] = str(row["store_file"])
			for rec: Dictionary in (doc as Dictionary).get("props", []):
				var stand_in := str(rec.get("stand_in", ""))
				if not stand_in.begins_with("lib/") or rec.has("box"):
					continue
				props += 1
				if not files.has(stand_in):
					unseen.append("%s: %s" % [id, stand_in])
				elif not FileAccess.file_exists(store.path_join(files[stand_in])):
					# The store is gitignored fetched content: a box holding only some packs' models lacks the rest
					# (dm-maps worlds read the shared library of the surf pack). That is a content gap, not a bad manifest.
					absent += 1
	if worlds == 0:
		_line("  (no worlds linked: skipped)")
	if no_store > 0:
		_line("  (%d worlds without a linked model store: skipped)" % no_store)
	if absent > 0:
		_line("  (%d library props name a model this box's store does not hold: not judged)" % absent)
	_check(unseen.is_empty(), "%d library props over %d worlds all map to a store file" % [props, worlds], str(unseen.slice(0, 5)))
	_done()


func _test_lighting() -> void:
	_section("an imported map is lit from its manifest's lighting block")

	var own := _lit(&"surf_mai_remix")
	var sun := own.get_node_or_null("Sun") as DirectionalLight3D
	var want := DotLightRig.sun_rotation(-60.0, 51.0)
	_check(
		sun != null and sun.rotation.is_equal_approx(want)
			and sun.light_color.is_equal_approx(Color(0.9490196, 0.8784314, 0.7176471)),
		"its sun is the map's: the manifest's angle and colour, not the old fixed sun"
	)
	var own_env := _environment(own)
	_check(
		own_env != null and own_env.background_mode == Environment.BG_SKY
			and own_env.ambient_light_color.is_equal_approx(Color(0.4117647, 0.5882353, 0.7294118)),
		"its sky and ambient are the map's own, not a flat grey-blue background"
	)
	own.free()

	var white := _lit(&"surf_29_12_06")
	var white_top := _sky_top(white)
	var table_top: Color = ArenaMapLighting.SKY_TOPS["sky_day01_01"]
	_check(
		white_top.is_equal_approx(table_top) or _sky_is_panorama(white),
		"a white ambient draws the sky its name says, not a white dome (%s)" % white_top
	)
	white.free()

	var packed := _lit(&"surf_buck_wild")
	var packed_env := _environment(packed)
	var packed_sky := packed_env.sky.sky_material as ShaderMaterial if packed_env != null and packed_env.sky != null else null
	# The published packs carry no sky face files (stripped of source textures), so the faces cannot
	# load and the map keeps the fallback sky: a gradient/cloud or the family panorama, never a hole.
	var faces_drawn := packed_sky != null and packed_sky.get_shader_parameter("face_up") is Texture2D
	_check(
		faces_drawn or (packed_env != null and packed_env.background_mode == Environment.BG_SKY
			and packed_env.sky != null and (_sky_top(packed).a > 0.0 or _sky_is_panorama(packed))),
		"a map whose packed sky faces are gone (stripped pack) keeps the fallback sky instead of a hole"
	)

	var builtin := ArenaMapLighting.build(ArenaMap.by_id(&"dm_box"))
	var builtin_top: Array = ArenaMap.DAYLIGHT["sky_top"]
	_check(
		_sky_top(builtin).is_equal_approx(Color(float(builtin_top[0]), float(builtin_top[1]), float(builtin_top[2]))),
		"a built-in map still draws its own sky_top"
	)
	_check(
		packed.get_node_or_null("Sun") != null and builtin.get_node_or_null("Sun") != null,
		"both kinds of map have a sun to light the players"
	)
	packed.free()
	builtin.free()
	_done()


func _lit(id: StringName) -> Node3D:
	return ArenaMapLighting.build(ArenaMap.by_id(id))


func _environment(root: Node3D) -> Environment:
	for child in root.get_children():
		if child is WorldEnvironment:
			return (child as WorldEnvironment).environment
	return null


func _sky_is_panorama(root: Node3D) -> bool:
	var env := _environment(root)
	return env != null and env.sky != null and env.sky.sky_material is PanoramaSkyMaterial


func _sky_top(root: Node3D) -> Color:
	var env := _environment(root)
	if env != null and env.sky != null and env.sky.sky_material is ShaderMaterial:
		# The cloud sky (arena_sky.gdshader) keeps the rig's zenith colour as a parameter.
		var zenith = (env.sky.sky_material as ShaderMaterial).get_shader_parameter("top_colour")
		return zenith if zenith is Color else Color(0, 0, 0, 0)
	if env == null or env.sky == null or not (env.sky.sky_material is ProceduralSkyMaterial):
		return Color(0, 0, 0, 0)
	return (env.sky.sky_material as ProceduralSkyMaterial).sky_top_color


## Water materials among the meshes a client would draw (the server never builds the visual).
func _water_drawn() -> int:
	var drawn := 0
	var level := _game.map.to_scene()
	for node: Node in level.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		for i in range(mesh_instance.get_surface_override_material_count()):
			var m := mesh_instance.get_surface_override_material(i)
			if m != null and m.has_meta(&"water"):
				drawn += 1
	level.free()
	return drawn


func _test_loads() -> bool:
	_section("the game loads it, with its solid in the tree")

	_game = ArenaGame.new()
	_game.tick_rate = TICK_RATE
	_game.headless = true
	_game.is_authority = true
	_game.register_service = false
	_game.mode = ArenaMode.free_for_all(SCORE_LIMIT)
	# The game's own export, which outranks the mode's when it is set (and is, by default).
	_game.score_limit = SCORE_LIMIT
	add_child(_game)

	var map := ArenaMap.by_id(MAP)
	var res := _game.setup(map)
	_check(res.ok, "setup succeeds%s" % ("" if res.ok else ": " + res.error.message))

	if not res.ok:
		_done()
		return false

	var manifest := ArenaImportedMaps.manifest(MAP)
	var info: Dictionary = manifest.get("collision", {})
	var expected := int(info.get("hull_count", 0)) + (
		1 if int(info.get("displacement_index_count", 0)) > 0 else 0
	)
	var solid := _game.map.collision_root
	# Clip and fence hulls sit in their own bodies (shots pass them), so count the shapes below the root.
	var shapes := -1
	if solid != null:
		shapes = solid.find_children("*", "CollisionShape3D", true, false).size()
	_check(solid != null and solid.is_inside_tree() and shapes == expected,
		"one shape per brush is in the tree (%d of %d)" % [shapes, expected])
	_check(_game.combat.trace is DotTracePhysics,
		"the shots trace the physics space, not a box list")
	_check(_game.match_node.spawn_points().size() == _game.map.spawns.size()
		and _game.map.spawns.size() == (manifest.get("spawns", []) as Array).size(),
		"every spawn the mapper placed is a spawn point (%d)" % _game.map.spawns.size())

	# Water the map shipped no texture for is drawn as water (arena_bsp_water.gdshader), one
	# material per such surface. Armed by skipping the water branch in _material_for.
	var water_wanted := 0
	for entry: Dictionary in manifest.get("surfaces", []):
		var shipped: Variant = entry.get("texture", null)
		if shipped is String and not (shipped as String).is_empty():
			continue
		if ArenaBspMap.is_water_material(str(entry.get("material", ""))):
			water_wanted += 1
	var water_drawn := _water_drawn()
	_check(water_wanted > 0 and water_drawn == water_wanted,
		"its untextured water is drawn as water (%d of %d)" % [water_drawn, water_wanted])

	_game.match_node.rules.warmup_sec = 0.0
	_game.freeze_sec = 0.0
	_game.match_node.rules.countdown_sec = 0.0

	for i in range(BOTS):
		var added := _game.add_player(i + 1, "bot%d" % (i + 1))

		if not added.ok:
			_check(false, "bot %d joined: %s" % [i + 1, added.error.message])
			_done()
			return false

	var first := _game.player_for(1)
	# Inside the solid-players wrapper (`arena_solid_body.gd`), which only adds the others.
	var map_body: Variant = first.controller.flat_body.get(&"inner")
	_check(map_body is DotFpsPhysicsBody
		and (map_body as DotFpsPhysicsBody).is_bound(),
		"a player moves against the physics space, bound before the first tick")

	_game.start(0)
	_done()
	return true


func _test_spawns_on_the_floor() -> void:
	_section("players appear on the map's own spawns, standing on its floor")

	await _ticks(TICK_RATE)

	var alive := 0
	var on_spawn := 0
	var grounded := 0
	var floored := 0
	var worst := 0.0

	for player in _game.players():
		if not player.is_alive():
			continue

		alive += 1
		var feet := player.controller.state.position
		var nearest := INF

		for at in _game.map.spawns:
			var flat := Vector2(at.origin.x - feet.x, at.origin.z - feet.z)
			nearest = minf(nearest, flat.length())

		worst = maxf(worst, nearest)

		if nearest < 0.5:
			on_spawn += 1

		if player.controller.state.is_grounded():
			grounded += 1

		var down := _game.combat.trace.ray(feet + Vector3.UP * 0.5, Vector3.DOWN, 1.0)

		if down.blocked:
			floored += 1

	_check(alive == BOTS, "every bot is alive a second in (%d of %d)" % [alive, BOTS])
	_check(on_spawn == alive,
		"each on one of the mapper's spawns (furthest %.2f m from one)" % worst)
	_check(grounded == alive, "grounded (%d of %d)" % [grounded, alive])
	_check(floored == alive, "with the map's floor under their feet (%d of %d)" % [floored, alive])

	_done()


var _lowest := INF
var _out_of_bounds := 0
var _inside := 0
var _kills := 0
var _ended := false


func _test_deathmatch() -> void:
	_section("a deathmatch is played on it")

	# Into containers: a lambda captures a scalar by value, and a counter incremented in
	# one stays zero outside it (docs/gdscript-hazards.md).
	var kills: Array[int] = [0]
	var leader_at_end: Array[int] = [-1]
	_game.player_killed.connect(func(_entry: DotKillFeed.Entry) -> void: kills[0] += 1)
	_game.match_node.state_changed.connect(
		func(_from: Variant, to: Variant) -> void:
			# Read now, at the transition: the next match zeroes the scoreboard.
			if int(to) == DotMatch.State.MATCH_END and leader_at_end[0] < 0:
				var best := 0
				for record in _game.match_node.scoreboard.players():
					best = maxi(best, record.kills)
				leader_at_end[0] = best
	)

	var ticks := int(PLAY_SECONDS * TICK_RATE)
	var started := Time.get_ticks_msec()
	var grounded_samples := 0
	var samples := 0
	var bounds := _game.map.bounds.grow(1.0)
	var probe := DotFpsPhysicsBody.for_node(_game.map.collision_root)
	var tunables := ArenaPlayer.arena_tunables()

	for tick in range(ticks):
		_game.tick(_commands_for_tick(tick))

		if tick % 8 != 0:
			if tick % 64 == 0:
				await get_tree().physics_frame
			continue

		for player in _game.players():
			if not player.is_alive():
				continue

			var feet := player.controller.state.position
			samples += 1
			_lowest = minf(_lowest, feet.y)

			if not bounds.has_point(feet):
				_out_of_bounds += 1

			if player.controller.state.is_grounded():
				grounded_samples += 1

			# Inside a brush: the hull, a few centimetres up off the floor it rests on,
			# overlaps solid. Up, because a hull resting on a floor touches it.
			if _in_solid(probe, feet, tunables):
				_inside += 1
				_line("     DEBUG inside at %s v %s grounded %s tick %d" % [feet, player.controller.state.velocity, player.controller.state.is_grounded(), tick])

		if leader_at_end[0] >= 0:
			break

	_kills = kills[0]
	_ended = leader_at_end[0] >= 0
	var took := Time.get_ticks_msec() - started
	_line("     %d samples, %d grounded, lowest feet %.1f m (the map's floor is %.1f), %d kills, %.1f s for %.0f s of play" % [
		samples, grounded_samples, _lowest, _game.map.bounds.position.y, _kills,
		took / 1000.0, PLAY_SECONDS
	])

	_check(samples > 0 and grounded_samples > samples / 4,
		"players stand on the map most of the time (%d of %d samples grounded)" % [grounded_samples, samples])
	_check(_out_of_bounds == 0, "nobody leaves the map's bounds (%d samples outside)" % _out_of_bounds)
	_check(_lowest > _game.map.bounds.position.y - 1.0,
		"nobody falls through the floor (lowest %.1f m)" % _lowest)
	_check(_inside == 0, "nobody ends up inside a brush (%d samples)" % _inside)
	_check(_kills > 0, "players kill each other (%d)" % _kills)
	_check(_ended, "and the score limit (%d) ends the round" % SCORE_LIMIT)

	_check(leader_at_end[0] >= SCORE_LIMIT,
		"won on frags: the leader had %d at the end" % leader_at_end[0])

	_done()


## The bots: walk at the nearest opponent's bearing, aim at them and hold the trigger.
## `headless_match`'s fixture, with a strafe so they move.
func _commands_for_tick(tick: int) -> Dictionary:
	var commands := {}

	for player in _game.players():
		if not player.is_alive():
			continue

		var target: ArenaPlayer = null
		var best := INF

		for other in _game.players():
			if other == player or not other.is_alive():
				continue

			var d := player.muzzle_position().distance_to(other.muzzle_position())

			if d < best:
				best = d
				target = other

		var move := DotFpsCommand.new()
		var fire := DotWeaponCommand.new()

		if target != null:
			var to_target := (target.muzzle_position() - player.muzzle_position()).normalized()
			move.yaw = rad_to_deg(atan2(-to_target.x, -to_target.z))
			move.pitch = rad_to_deg(asin(clampf(to_target.y, -1.0, 1.0)))
			fire.set_button(DotWeaponCommand.BUTTON_ATTACK, true)
			move.move = Vector2(sin(float(tick) * 0.05 + float(player.player_id)), 0.6)

		move.sanitise()
		fire.sanitise()
		commands[player.player_id] = [move, fire]

	return commands


## Set by `-- --fallout=<map id>`: the one map the walk-off check visits.
var _fallout_only := ""


## General detector for a destination nobody can leave: a teleport aimed behind a button-moved
## door seals whoever lands there. Every combat surf map drops a player on each big destination
## and walks eight headings; a failing map wants an `open_doors` entry or a note why not.
func _test_fallout_all() -> void:
	_section("every combat surf map: a faller at a big teleport destination can walk away")

	var sealed: Array[String] = []
	var report: Array[String] = []
	var player := _fresh(2)

	for id in ArenaMap.imported_ids():
		if _fallout_only != "" and String(id) != _fallout_only:
			continue
		var changed := _game.change_map(ArenaMap.by_id(id))
		if not changed.ok:
			sealed.append("%s (does not load)" % id)
			continue

		var order: Array[int] = []
		for index in range(_game.map.pits.size()):
			order.append(index)
		order.sort_custom(func(a: int, b: int) -> bool:
			return (_game.map.pits[a]["box"] as AABB).get_volume() > (_game.map.pits[b]["box"] as AABB).get_volume())

		var tried: Array[Vector3] = []
		for index in order:
			if tried.size() >= FALLOUT_PER_MAP:
				break
			var cell: Vector3 = _game.map.pits[index]["to"]
			var fresh := true
			for seen in tried:
				if seen.distance_to(cell) < 1.0:
					fresh = false
			if not fresh:
				continue
			tried.append(cell)

			var best := 0.0
			var best_yaw := 0.0
			var tries: Array[String] = []
			for heading in range(8):
				var yaw := heading * 45.0
				# A respawn, not just a teleport: crouch, modifiers and loadout left by earlier
				# sections change the walking speed and so the reach.
				_game.respawn_player(2)
				player = _game.player_for(2)
				player.controller.teleport(cell, yaw, 0.0)
				_game.tick({})
				var start := player.controller.state.position
				var reach := 0.0
				var lowest := start.y
				for tick in range(int(TICK_RATE * FALLOUT_WALK)):
					var move := DotFpsCommand.new()
					move.yaw = yaw
					move.move = Vector2(0.0, 1.0)
					move.sanitise()
					_game.tick({player.player_id: [move, DotWeaponCommand.new()]})
					var here := player.controller.state.position
					# Only ground counts: a body walked off a ledge keeps its sideways
					# speed through the whole fall, which is not a way out of a cell.
					if player.controller.state.is_grounded():
						reach = maxf(reach, Vector2(here.x - start.x, here.z - start.z).length())
					lowest = minf(lowest, here.y)
					if reach >= FALLOUT_OUT_AT:
						break
				# An edge to walk off is out as well: what a cell has is walls all round and a roof,
				# and a platform open to the sky has a fall, which the map's catch-all makes a
				# drop back into the fight.
				if reach < FALLOUT_OUT_AT and start.y - lowest >= 3.0:
					reach = FALLOUT_OUT_AT
				if reach > best:
					best = reach
					best_yaw = yaw
				tries.append("heading %d: reach %.1f, fell %.1f m, end %s, mode %s" % [heading, reach, start.y - lowest, player.controller.state.position.snapped(Vector3.ONE * 0.1), player.controller.state.mode])
				if best >= FALLOUT_OUT_AT:
					break
			report.append("%s pit %d -> (%.0f, %.0f, %.0f): got %.1f m (yaw %.0f)" % [
				id, index, cell.x, cell.y, cell.z, best, best_yaw])
			if best < FALLOUT_OUT_AT:
				sealed.append("%s pit %d" % [id, index])
				for line in tries:
					_line("       " + line)

	for line in report:
		_line("     " + line)

	_check(sealed.is_empty(), "no destination seals its faller in (%s)" % [sealed])

	_done()


func _test_jail() -> void:
	_section("the jail: a fall lands in it, the button opens the gate, then it shuts and cools down")

	var jail: RefCounted = _game.map.jail
	var falls: Array[int] = []
	for index: int in jail.roles:
		if int(jail.roles[index]) == ArenaJail.Role.FALL:
			falls.append(index)
	_check(jail != null and falls.size() >= 2 and not jail.exit_indices.is_empty(),
		"found by its shape: %d pits fall into it, %d ways out" % [falls.size(), jail.exit_indices.size()])

	# One second open, two shut: short enough to run out in a suite, whole ticks all the same.
	_game.jail_rules["open"] = 1.0
	_game.jail_rules["cooldown"] = 2.0
	var told: Array[int] = [0]
	var counter := func() -> void: told[0] += 1
	_game.jail_changed.connect(counter)
	_game.apply_jail_rules()
	_check(jail.open_ticks == TICK_RATE and jail.cooldown_ticks == 2 * TICK_RATE,
		"the rules are in ticks (%d open, %d shut)" % [jail.open_ticks, jail.cooldown_ticks])

	var player := _fresh(2)
	var fall_box: AABB = _game.map.pits[falls[0]]["box"]
	player.controller.teleport(fall_box.get_center(), 0.0, 0.0)
	_game.tick({})
	var button: AABB = jail.button_box()
	var at := player.controller.state.position
	_check(at.distance_to(jail.cell()) < 0.5 and at.distance_to(button.get_center()) > 5.0,
		"a fall lands in the cell, not at the button (%.1f m from the cell)" % at.distance_to(jail.cell()))

	player.controller.teleport(button.get_center(), 0.0, 0.0)
	var told_before: int = told[0]
	_game.tick({})
	_check(jail.opened_at >= 0 and jail.is_open(player.controller.state.tick) and told[0] > told_before,
		"standing on the button opens the gate, and says so")
	_check((player.controller.state.position - button.get_center()).length() < 1.0,
		"and the button itself no longer sends anybody anywhere")

	var gate: Dictionary = _game.map.pits[jail.exit_indices[0]]
	player.controller.teleport((gate["box"] as AABB).get_center(), 0.0, 0.0)
	_game.tick({})
	_check(player.controller.state.position.distance_to(gate["to"]) < 0.5,
		"open, the way out is a way out")

	var ticks_open := 0
	while jail.is_open(player.controller.state.tick) and ticks_open < 4 * TICK_RATE:
		_game.tick({})
		ticks_open += 1
	_check(absi(ticks_open - TICK_RATE) <= 3, "it shuts after its open time (%d ticks of %d)" % [ticks_open, TICK_RATE])

	player.controller.teleport((gate["box"] as AABB).get_center(), 0.0, 0.0)
	_game.tick({})
	_check(player.controller.state.position.distance_to(jail.cell()) < 0.5,
		"shut, a walk into the way out puts the player back in the cell")

	var first_opened: int = jail.opened_at
	player.controller.teleport(button.get_center(), 0.0, 0.0)
	_game.tick({})
	_check(jail.opened_at == first_opened, "the button does nothing while it cools down")

	var waited := 0
	while not jail.can_press(player.controller.state.tick) and waited < 6 * TICK_RATE:
		_game.tick({})
		waited += 1
	player.controller.teleport(button.get_center(), 0.0, 0.0)
	_game.tick({})
	_check(jail.opened_at > first_opened, "and works again once it has (%d ticks later)" % waited)

	jail.enabled = false
	var fall_pit: Dictionary = _game.map.pit_at(fall_box.get_center(), player.controller.state.tick)
	_check(fall_pit == _game.map.pits[falls[0]] and _game.map.pit_at(button.get_center(), 0) == _game.map.pits[jail.button_index],
		"with arena_jail off every volume does what the map shipped")
	jail.enabled = true

	var wire := ArenaEvents.read_jail(DotNetReader.new(ArenaEvents.write_jail(true, 640, 1280, 4321)))
	var shut_tick := 4321 + 640
	_game.apply_jail_state(wire)
	_check(bool(wire["ok"]) and jail.opened_at == 4321 and jail.is_open(4321 + 10) and not jail.is_open(shut_tick),
		"the gate's state survives the wire, so a client predicts the same door")
	_game.jail_changed.disconnect(counter)
	_game.jail_rules["open"] = 10.0
	_game.jail_rules["cooldown"] = 20.0
	_game.apply_jail_rules()
	jail.opened_at = -1
	_done()


func _test_packs() -> void:
	_section("the shift powerup is off, and a map's packs heal, refill and come back")

	var game := ArenaGame.new()
	game.tick_rate = TICK_RATE
	game.headless = true
	game.is_authority = true
	game.register_service = false
	game.mode = ArenaMode.free_for_all(SCORE_LIMIT)
	add_child(game)
	var res := game.setup(ArenaMap.by_id(&"dm_box"))
	_check(res.ok, "a map with packs loads")
	var _added := game.add_player(1, "a")
	var player := game.player_for(1)
	game.respawn_player(1)

	_check(not player.controller.tunables.dash_enabled and not ArenaPlayer.arena_tunables().dash_enabled,
		"the dash is off by default (arena_dash turns it on)")
	_check(game.drops.pack_count() == game.map.packs.size() and game.map.packs.size() >= 4
		and game.drops.packs_available() == game.map.packs.size(),
		"every pack the map places is out (%d)" % game.map.packs.size())
	_check(ArenaMap.PACK_HEALTH == ArenaDrops.Kind.HEALTH and ArenaMap.PACK_AMMO == ArenaDrops.Kind.AMMO,
		"the map and the drops layer number the pack kinds alike")

	var health_at := Vector3.ZERO
	var ammo_at := Vector3.ZERO
	for pack: Dictionary in game.map.packs:
		if int(pack["kind"]) == ArenaMap.PACK_HEALTH and health_at == Vector3.ZERO:
			health_at = pack["at"]
		if int(pack["kind"]) == ArenaMap.PACK_AMMO and ammo_at == Vector3.ZERO:
			ammo_at = pack["at"]

	# At full health a health pack stays where it is, for someone who needs it.
	player.controller.teleport(health_at, 0.0, 0.0)
	var out := game.drops.packs_available()
	game.tick({})
	_check(game.drops.packs_available() == out, "a health pack is left alone by somebody at full health")

	player.health.health = player.health.max_health - 40.0
	player.controller.teleport(health_at, 0.0, 0.0)
	game.tick({})
	_check(player.health.health > player.health.max_health - 40.0 and game.drops.packs_available() == out - 1,
		"hurt, they take it and are healed (%.0f)" % player.health.health)

	var respawn_ticks := int(round(game.drops.pack_respawn_sec * float(TICK_RATE)))
	player.controller.teleport(Vector3(0.0, 40.0, 0.0), 0.0, 0.0)
	for _i in range(respawn_ticks + 2):
		game.tick({})
	_check(game.drops.packs_available() == out, "and it comes back after its respawn time (%d ticks)" % respawn_ticks)

	var slot_id: int = player.arsenal.slots()[0]
	for s in player.arsenal.slots():
		var def: DotWeaponDef = player.arsenal.slot_at(s).def
		if def != null and def.uses_ammo() and def.ammo_type != &"" and not def.infinite_reserve and def.reserve_cap() > 0:
			slot_id = s
			break
	var held: DotWeaponDef = player.arsenal.slot_at(slot_id).def
	player.arsenal.ammo().set_count(held.ammo_type, 0)
	player.controller.teleport(ammo_at, 0.0, 0.0)
	game.tick({})
	var got := player.arsenal.ammo().count(held.ammo_type)
	_check(got > 0 and got <= held.reserve_cap(), "an ammo pack refills a reserve that was empty (%d of %d)" % [got, held.reserve_cap()])

	game.drop_rules["packs"] = false
	game.apply_drop_rules()
	_check(game.drops.pack_count() == 0, "arena_packs 0 takes them all away")
	remove_child(game)
	game.free()
	_done()


static func _in_solid(body: DotFpsPhysicsBody, feet: Vector3, tunables: DotFpsTunables) -> bool:
	var height := tunables.stand_height - 0.2
	return body.overlaps(feet + Vector3.UP * (0.1 + height * 0.5), height, tunables.radius - 0.05)
