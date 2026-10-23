extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMaps := preload("../game/arena_maps.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaModes := preload("../game/arena_modes.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaImportedMaps := preload("../maps/arena_imported_maps.gd")
const ArenaBspMap := preload("../maps/arena_bsp_map.gd")
const ArenaBots := preload("../game/arena_bots.gd")
const ArenaContent := preload("../game/arena_content.gd")
const ArenaMapDirector := preload("../game/arena_map_director.gd")
const ArenaMapLighting := preload("../maps/arena_map_lighting.gd")
const ArenaSurf := preload("../game/arena_surf.gd")
const ArenaSurfRides := preload("../game/arena_surf_rides.gd")
const ArenaDrops := preload("../game/arena_drops.gd")
const ArenaEvents := preload("../game/arena_events.gd")
const ArenaJail := preload("../maps/arena_jail.gd")

## The combat surf maps game-g2gfast imported, played as an arena deathmatch.
##
## [codeblock]
## godot --headless --path . res://examples/headless_imported.tscn
## [/codeblock]
##
## [b]Every other suite here plays a list of boxes, and an imported map is not one.[/b] Its
## movement and its shots are physics queries against a few thousand convex brushes that
## the game puts in the tree on every machine, its spawns are the mapper's, its pits are
## teleports, and its air control is the genre's. Not one of those is reachable from
## `headless_match`, which is why this file exists: a map that loads and that nobody can
## stand on passes every check written for the built-ins.
##
## What it asserts, on [constant MAP] (the first map in the default rotation):
##
## - the map is found by its manifest's kind and catalogued, in or out of the rotation;
## - the game loads it with its solid in the tree and the physics backends bound to it;
## - every player appears on one of the map's OWN spawn points, standing on its floor;
## - bots ride its ramps: the map's ride edges (`maps/surf/<id>.surf.json`) are in their
##   routes, a bot handed one rides it to the platform below and lands alive, and a roaming bot's
##   own route hands it one; on the rotation's own maps ([constant ROTATION_RIDE_MAPS]) a bot
##   rides one across the map, several flights long, and lands alive;
## - a deathmatch is played on it for [constant PLAY_SECONDS] seconds and nobody falls
##   through, leaves the map or ends up inside a brush, and kills are scored until the
##   score limit ends the round;
## - the surf air control is on there, back off on a built-in map, and back on again;
## - a pit sends a player where it aims, and the floor under the map catches anybody past it;
## - the map's own mechanics run: a booster throws a player at its speed, water is swum in
##   (and sunk in, and climbed out of), a ladder is climbed;
## - a hurt volume on [constant HURT_MAP] hurts through dot-combat, every half second, and
##   kills as the world, and a negative one heals;
## - a map is lit from its manifest's `lighting` block (its sun, its sky by name where the
##   ambient is the editor's white, its own six sky faces where it packed them), on a
##   dot-lighting that draws `sky_top` and on one that does not;
## - as a sweep, every combat surf map found builds and puts its spawns on a floor;
## - and a map only the SERVER names (a pack key in `games.current_maps()`, on a fake mount
##   under `res://dot_cloud/`) is catalogued as delivered without being fetched, is built from
##   the mount on a change, is gone when the server stops naming it, and a named pack that is
##   not `"kind": "arena"` is skipped.
##
## [b]Skips, loudly, when the maps are not linked[/b] — a checkout without arena-surf-dm-maps
## plays the built-ins only, which is a supported state (dot-ci has no link). It is allowed
## to skip; it is not allowed to pass: the exit code is 0 and the line says why.

const TICK_RATE := 64
const BOTS := 6

## The map the deathmatch is played on: the first of Christian's two.
const MAP := &"surf_10x_reloaded_fixed"

const PLAY_SECONDS := 40.0

## A score limit small enough that six bots reach it inside [constant PLAY_SECONDS].
const SCORE_LIMIT := 4

## The map whose hurt volumes are checked: MAP has none.
const HURT_MAP := &"surf_xiv_v2a"

const SECTIONS := 23
## 102 fixed, plus one audit check per imported map: the catalogue grows without this changing.
const CHECKS_FIXED := 152

## The fake pack [method _test_server_named] mounts: an id no root has, under an owner no
## origin has, so nothing real is shadowed and nothing is fetched.
const DELIVERED_OWNER := "dot-test"
const DELIVERED_ID := &"dot_test_delivered_surf"
const DELIVERED_NOT_ARENA := &"dot_test_delivered_course"
const DELIVERED_VERSION := "1.0.0"

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0

var _game: ArenaGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	_line("arena — imported combat surf maps")
	_line("")

	if ArenaMap.imported_ids().is_empty():
		_line("no imported maps under %s — nothing to check" % ArenaImportedMaps.roots()[0])
		_line("  link arena-surf-dm-maps: dot-bootstrap/bootstrap.sh --links game-arena")
		get_tree().quit(0)
		return

	_test_catalogue()
	_test_lighting()

	if not await _test_loads():
		_finish()
		return

	# `-- --rides`: only the recorded rides, for working on them (the suite's own totals then do not hold).
	if OS.get_cmdline_user_args().has("--rides"):
		await _test_recorded_rides()
		get_tree().quit(1 if _failed > 0 else 0)
		return

	# `-- --band`: only the bots' band, for measuring it (the suite's own totals then do not hold).
	if OS.get_cmdline_user_args().has("--band"):
		await _test_bot_band()
		get_tree().quit(1 if _failed > 0 else 0)
		return

	await _test_spawns_on_the_floor()
	await _test_deathmatch()
	await _test_bot_routes()
	_test_surf_movement()
	_test_ramp()
	_test_pits()
	_test_jail()
	_test_shots()
	_test_mechanics()
	await _test_hurt()
	await _test_surf_rides()
	await _test_fallout()
	await _test_fallout_all()
	await _test_rotation_rides()
	await _test_bot_band()
	await _test_recorded_rides()
	await _test_every_map()
	await _test_collision_audit()
	await _test_packs()
	await _test_server_named()

	_finish()


func _finish() -> void:
	# Freed here, not left to the engine at exit: its bots' navigation RIDs and the
	# resources it holds are then released before the leak report.
	if _game != null:
		remove_child(_game)
		_game.free()
		_game = null

	_line("")
	_line("%d sections, %d passed, %d failed" % [_completed, _passed, _failed])

	if _entered != SECTIONS or _completed != SECTIONS:
		_line("ERROR: %d sections entered and %d completed, %d expected." % [
			_entered, _completed, SECTIONS
		])
		get_tree().quit(1)
		return

	if _passed + _failed != CHECKS_FIXED + ArenaMap.imported_ids().size():
		_line("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS_FIXED + ArenaMap.imported_ids().size()
		])
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


# --- The catalogue ---------------------------------------------------------

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


# --- Loading ---------------------------------------------------------------

# --- Lighting --------------------------------------------------------------

## The three maps each put one rule in the state it exists for: surf_mai_remix has a sun and
## a blue ambient of its own, surf_29_12_06 the editor's white ambient under a sky the
## table knows, surf_buck_wild a sky it packed. Until 2026-10-11 every imported map got
## one fixed sun and a flat grey-blue, whatever its manifest said.
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
		white_top.is_equal_approx(table_top),
		"a white ambient draws the sky its name says, not a white dome (%s)" % white_top
	)
	white.free()

	var packed := _lit(&"surf_buck_wild")
	var packed_env := _environment(packed)
	var packed_sky := packed_env.sky.sky_material as ShaderMaterial if packed_env != null and packed_env.sky != null else null
	_check(
		packed_sky != null and packed_sky.get_shader_parameter("face_up") is Texture2D,
		"a map that packed its six sky faces draws them"
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


func _sky_top(root: Node3D) -> Color:
	var env := _environment(root)
	if env == null or env.sky == null or not (env.sky.sky_material is ProceduralSkyMaterial):
		return Color(0, 0, 0, 0)
	return (env.sky.sky_material as ProceduralSkyMaterial).sky_top_color


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
	_check(solid != null and solid.is_inside_tree() and solid.get_child_count() == expected,
		"one shape per brush is in the tree (%d of %d)" % [
			solid.get_child_count() if solid != null else -1, expected
		])
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
	var water_drawn := 0
	# Drawn the way a client draws it: the server never builds the visual.
	var level := _game.map.to_scene()
	for drawn: Node in level.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := drawn as MeshInstance3D
		for i in range(mesh_instance.get_surface_override_material_count()):
			var m := mesh_instance.get_surface_override_material(i)
			if m != null and m.has_meta(&"water"):
				water_drawn += 1
	level.free()
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


# --- Spawns ----------------------------------------------------------------

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


# --- The deathmatch ----------------------------------------------------------

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


# --- Surf movement -------------------------------------------------------------

func _test_bot_routes() -> void:
	_section("bots route round the brushes, from a mesh baked off the tick")

	# The deathmatch above asked for routes, so the bake started there; it lands on a later
	# frame. Armed by returning null from ArenaBots.World._nav_for_map (routes empty, as before).
	var world := ArenaBots.world_for(_game)
	var spawns: Array[Transform3D] = _game.map.spawns
	var a := spawns[0].origin
	var b := a
	for spawn in spawns:
		if spawn.origin.distance_to(a) > b.distance_to(a):
			b = spawn.origin
	var route := world.route(a, b)
	var frames := 0
	while world.is_route_pending() and frames < 1200:
		await get_tree().process_frame
		frames += 1
	route = world.route(a, b)
	_check(not world.is_route_pending() and route.size() >= 2,
		"the mesh lands and gives a route between spawns %.0f m apart (%d corners, %d frames waited)" % [a.distance_to(b), route.size(), frames])

	# From that spawn to every other: every leg clear at knee height. A combat surf map is two
	# halves joined by ramps and drops, which a walking mesh does not hold, so a route to the
	# far half ends at the edge of this one (the bot walks straight on from there); the near
	# half is reached in full.
	var trace := _game.combat.trace
	var clear := 0
	var reached := 0
	var furthest := 0.0
	var short_but_closer := 0
	for spawn in spawns:
		if spawn.origin == a:
			continue
		var way := world.route(a, spawn.origin)
		var ok := way.size() >= 2
		var from := a
		for corner in way:
			ok = ok and trace.line_of_sight(from + Vector3.UP * 0.5, corner + Vector3.UP * 0.5)
			from = corner
		clear += 1 if ok else 0
		if way.size() >= 2 and way[way.size() - 1].distance_to(spawn.origin) < 1.0:
			reached += 1
			furthest = maxf(furthest, a.distance_to(spawn.origin))
		elif way.size() >= 2 and way[way.size() - 1].distance_to(spawn.origin) < a.distance_to(spawn.origin):
			short_but_closer += 1
	_check(clear == spawns.size() - 1,
		"a route to every other spawn, every leg clear of the brushes (%d of %d)" % [clear, spawns.size() - 1])
	_check(reached > 0 and furthest > 5.0 and reached + short_but_closer == spawns.size() - 1,
		"its own half reached in full (%d spawns, the furthest %.0f m), the far half's routes end nearer than they start (%d)" % [reached, furthest, short_but_closer])
	_done()


## The map the ride check plays: the first combat surf map with planned rides (see
## docs/imported-maps.md, "Bots ride the ramps", for why not [constant MAP]).
const RIDE_MAP := &"surf_ski_2"
## Its starts, and how many must land.
const RIDE_STARTS := 3
const RIDE_LANDING := 2
## How long a roaming bot is given to take a ride of its own accord, seconds.
const ROAM_SECONDS := 90.0


## The rotation's maps with planned rides, each ridden as [constant RIDE_MAP] is (one edge,
## [constant ROTATION_RIDE_STARTS] starts). Their rides are several flights long, which is why they were
## the last to get any; see docs/imported-maps.md, "Which maps have rides".
const ROTATION_RIDE_MAPS: Array[StringName] = [&"surf_10x_reloaded_fixed", &"surf_snipers_island", &"surf_the_flow"]
## Their starts, and how many must land. Wider than [constant RIDE_STARTS] on purpose: 10x's
## edge lands 55% of live rides (`tools/surf_rides.tscn --measure`; the misses clip a
## teleport near the end), so 2 of 3 would fail a working ride two runs in five, while
## 2 of 6 fails about one in fifteen and still catches a ride that has stopped working.
const ROTATION_RIDE_STARTS := 6
## Per planned edge in file order (10x: edges 0, 2 and 5 of the file, the last to the far platform 22).
## Measured live 55%, 45% and 40% (`tools/surf_rides.tscn --measure`), and 2 of 6 starts landed on
## each here; 2 is the bar for the same reason as before, and a ride that has stopped working lands none.
const ROTATION_RIDE_LANDING: Array = [1, 2, 2]
## surf_snipers_island's three edges go from the pads its teleports put a player on down to the
## island with the spawns (0.6 to 1.7 s, 64 to 107 m); they land 100% of simulated and live rides
## (`--measure`), so five of six is the bar and one miss is tolerated.
const SNIPERS_RIDE_LANDING: Array = [5, 5, 5]
## surf_the_flow's two edges go from each spawn platform (16 spawns on each) down to the floor island
## the teleports land on (3.2 to 3.5 s); 100% simulated and 95% to 100% live (`--measure`), so five of six.
const FLOW_RIDE_LANDING: Array = [5, 5]


## Bots ride the ramps (`game/arena_surf.gd`): the edges are linked into the mesh, a route to a
## platform below crosses one, a bot handed it by its route lands on the far platform alive from
## [constant RIDE_STARTS] starts (the edge's own and perturbed ones), and a bot left to roam
## is handed one by its own route.
func _test_surf_rides() -> void:
	_section("bots ride a ramp to another platform, aiming as they go")
	var rode := await _ride_on(RIDE_MAP, 0, RIDE_STARTS, [RIDE_LANDING])
	if rode.is_empty():
		_check(false, "nor take one of its own accord")
		_done()
		return
	var surf: ArenaSurf = rode["surf"]
	var edge: ArenaSurf.Edge = rode["edge"]
	await _roam_takes_ride(surf, edge.from, int(rode["tick"]))
	_done()


## A bot alone on the map, put at [param start], roams until its own route hands it a ride.
func _roam_takes_ride(surf: ArenaSurf, start: Vector3, tick: int) -> int:
	# Of its own accord: a bot on a spawn platform roams, and its routes cross the edges.
	var roamer := _game.player_for(5)
	if not roamer.is_alive():
		_game.respawn_player(5)
	roamer.controller.teleport(start, 0.0, 0.0)
	# The roamer alone on the map, and the others back afterwards. The ride check above parked them
	# on this same start platform (pushed about by each other's hulls, so where each ends up
	# depends on where the deathmatch left it), and a roamer that sees one fights instead of
	# roaming: it strafes off the platform's lip onto the ramp with no ride, falls, and the map's
	# fall-out teleport puts it on a closed ledge above the spawns that no route leaves. Whether
	# this check passed hung on where four idle bots stood. It is about routes, not fights.
	var others: Array[int] = []
	for other in _game.players():
		if other.player_id != 5:
			others.append(other.player_id)
	for id in others:
		_game.remove_player(id)
	var roam_mind := ArenaBots.Mind.new()
	roam_mind.seed = 5
	var begun_before := surf.begun
	var landed_before := surf.landed
	for t in range(int(ROAM_SECONDS * TICK_RATE)):
		_game.tick({5: ArenaBots.think(_game, roamer, roam_mind, tick, float(TICK_RATE))})
		tick += 1
		if t % 32 == 0:
			await get_tree().physics_frame
		if surf.begun > begun_before and roam_mind.ride == null:
			break
	for id in others:
		_game.add_player(id, "bot%d" % id)
	# Whether it lands is the check above; this one is that its own route hands it a ride.
	_check(surf.begun > begun_before,
		"a roaming bot's own route hands it a ride (%d begun, %d landed)" % [surf.begun - begun_before, surf.landed - landed_before])
	return tick


## Players' rides are recorded when the server turns it on, replayed on the real motor, and a bot
## rides the verified recording: off by default, bots never recorded, one cap and one target.
func _test_recorded_rides() -> void:
	_section("players' rides are recorded, harvested on the motor and ridden by a bot")
	var changed := _game.change_map(ArenaMap.by_id(RIDE_MAP))
	var world := ArenaBots.world_for(_game)
	var _first := world.route(Vector3.ZERO, Vector3.ONE)
	var frames := 0
	while world.is_route_pending() and frames < 1200:
		await get_tree().process_frame
		frames += 1
	var surf: ArenaSurf = world.surf_for_map() if changed.ok else null
	var planned: Array = surf.edges.filter(func(e: ArenaSurf.Edge) -> bool: return e.linked) if surf != null else []
	if planned.is_empty():
		_check(false, "%s has a linked ride edge to record" % RIDE_MAP)
		_done()
		return
	var edge: ArenaSurf.Edge = planned[0]

	# Off until the config says so, and the two numbers are the recorder's own.
	var started := _game.start_ride_recording()
	var rides: RefCounted = _game.surf_rides
	_check(started.ok and rides != null and not rides.is_on() and not rides.demo.record,
		"ride recording is off by default (%s)" % ("ok" if started.ok else started.error.message))
	var cfg := DotBotDemoConfig.new()
	cfg.store = "memory"
	cfg.cap = 7
	cfg.target = 3
	cfg.record = false
	var shared := ArenaSurfRides.ride_config_for(cfg)
	_check(shared.cap == 7 and shared.target == 3, "the harvest's cap and target are bot_record_cap and bot_record_target (%d, %d)" % [shared.cap, shared.target])
	cfg.cap = DotBotDemoConfig.new().cap
	cfg.target = DotBotDemoConfig.new().target
	var store := DotBotDemoStoreMemory.new()
	var fresh: RefCounted = ArenaSurfRides.new()
	var ready: DotResult = fresh.call(&"setup", _game, cfg, store, float(TICK_RATE))
	_check(ready.ok, "a recorder and its ride book are built over a store")
	# release() breaks the callables that point back at the recorder, or it outlives the run.
	rides.call(&"release")
	_game.surf_rides = fresh
	rides = fresh

	var human_id := 4
	var human := _game.player_for(human_id)
	var aside: Vector3 = edge.to + Vector3(30.0, 0.0, 0.0)
	for other in _game.players():
		if other.player_id != human_id and other.player_id != 5 and other.is_alive():
			other.controller.teleport(aside + Vector3(float(other.player_id), 0.0, 0.0), 0.0, 0.0)
	var tick := 40000
	tick = await _ride_as_player(human, edge, surf, tick, 1)
	_check(rides.recorder.recorded == 0 and rides.kept == 0, "with recording off a ride is recorded by nobody (%d)" % rides.recorder.recorded)

	cfg.record = true
	var starts := 6
	tick = await _ride_as_player(human, edge, surf, tick, starts)
	var flushed: DotResult = await rides.recorder.flush_all()
	_check(rides.kept >= 2 and rides.recorder.recorded == rides.kept,
		"real players' rides are recorded when on (%d kept of %d starts, %d discarded %s)" % [rides.kept, starts, rides.discarded, str(rides.why_not)])
	_check(flushed.ok and rides.recorder.written == rides.kept and rides.recorder.queued() == 0,
		"and written to the store (%d written)" % rides.recorder.written)
	var counts: DotResult = await store.counts(rides.recorder.map_id, rides.recorder.map_version, ArenaSurfRides.KIND)
	var key: String = rides.edge_key(edge)
	_check(counts.ok and counts.value.has(key), "filed under the edge's island key %s (%s)" % [key, str(counts.value.keys()) if counts.ok else "no counts"])

	var state_back := ArenaSurfRides.decode_state(JSON.parse_string(JSON.stringify(ArenaSurfRides.encode_state(human.controller.state))))
	_check(state_back.equals(human.controller.state, 0.001) and state_back.mode == human.controller.state.mode,
		"a motor state survives the store's JSON")

	var harvest: DotBotRideHarvest = rides.harvest_on(human.controller)
	var done: DotResult = await harvest.harvest(store, rides.recorder.map_id, rides.recorder.map_version, ArenaSurfRides.KIND, key)
	var verified_total: int = harvest.verified + rides.harvested
	_check(harvest.ready().ok and done.ok and verified_total >= 1,
		"replayed on the real motor, %d of %d recorded rides land (%d rejected)" % [verified_total, rides.kept, harvest.rejected])

	# A bot rides the verified recording, and is never recorded itself.
	var recorded_before: int = rides.recorder.recorded
	var rebuilt := DotBotRideBook.new(rides.ride_config)
	rebuilt.set_map(rides.recorder.map_id, rides.recorder.map_version)
	rides.book = rebuilt
	var loaded: DotResult = await rebuilt.load_edge(store, ArenaSurfRides.KIND, key, rides.schema, float(TICK_RATE))
	rides._edge_keys[edge.id] = key
	_check(loaded.ok and rebuilt.recorded_count(key) >= 1, "the book holds %d verified recordings of the edge" % rebuilt.recorded_count(key))
	var bot := _game.player_for(5)
	bot.set_meta(&"bot", true)
	if not bot.is_alive():
		_game.respawn_player(5)
	surf.rides = rides
	human.controller.teleport(aside + Vector3(-6.0, 0.0, 0.0), 0.0, 0.0)
	var landed_before := surf.landed
	var source := ""
	var ridden := 0
	# Recordings begin where their players stood, some off-centre or moving, so a bot standing still at the lip lands with some and not others.
	for attempt in range(8):
		if surf.landed > landed_before:
			break
		bot.controller.teleport(edge.from, edge.course.reference_yaw(), 0.0)
		var mind := ArenaBots.Mind.new()
		mind.seed = 9 + attempt
		var intent := DotBotIntent.new()
		intent.ride = edge.id
		ridden = 0
		while ridden < int(ArenaSurf.RIDE_SECONDS * TICK_RATE) + 4:
			surf.steer(bot, mind, intent, tick, float(TICK_RATE))
			if mind.ride == null:
				break
			source = str((mind.ride as DotBotSurfRide).picked.get("source", ""))
			var move := DotFpsCommand.new()
			intent.write_move(move)
			_game.tick({5: [move, DotWeaponCommand.new()]})
			tick += 1
			ridden += 1
			if ridden % 32 == 0:
				await get_tree().physics_frame
	_check(source == DotBotRideBook.RECORDED and surf.landed > landed_before,
		"a bot rides a recorded line to the platform below (%s, %s, %d ticks)" % [source, "landed" if surf.landed > landed_before else "did not land", ridden])
	_check(rides.recorder.recorded == recorded_before and rides.begun == rides.kept + rides.discarded,
		"and the bot is not recorded (%d recorded before and after)" % recorded_before)
	bot.remove_meta(&"bot")
	surf.rides = null
	fresh.call(&"release")
	_game.surf_rides = null
	_done()


## [param player] rides [param edge] [param count] times on the planned cache, from the lip or (with [param spread]) from perturbed starts, as a person's commands would be.
func _ride_as_player(player: ArenaPlayer, edge: ArenaSurf.Edge, surf: ArenaSurf, tick: int, count: int, spread: bool = false) -> int:
	var rng := RandomNumberGenerator.new()
	rng.seed = 91
	for k in range(count):
		if not player.is_alive():
			_game.respawn_player(player.player_id)
		var at := edge.from
		var velocity := Vector3.ZERO
		if k > 0 and spread:
			var forward := DotFpsMotor.forward_for(edge.course.reference_yaw())
			at += Vector3(-forward.z, 0.0, forward.x) * rng.randf_range(-0.8, 0.8)
			velocity = DotFpsMotor.forward_for(edge.course.reference_yaw() + rng.randf_range(-60.0, 60.0)) * rng.randf_range(2.0, 8.0)
		player.controller.teleport(at, edge.course.reference_yaw(), 0.0)
		player.controller.state.velocity = velocity
		var mind := ArenaBots.Mind.new()
		mind.seed = 300 + k
		mind.ride = DotBotSurfRide.new().begin(edge.cache, edge.course, surf._sim_for(edge, player.controller), tick, float(TICK_RATE))
		var ticks := 0
		while mind.ride != null and ticks < int(ArenaSurf.RIDE_SECONDS * TICK_RATE) + 4:
			_game.tick({player.player_id: ArenaBots.think(_game, player, mind, tick, float(TICK_RATE))})
			tick += 1
			ticks += 1
			if ticks % 32 == 0:
				await get_tree().physics_frame
		var st := player.controller.state
		# A few ticks standing on the far platform, which is where a recorded ride ends.
		for _s in range(8):
			_game.tick({player.player_id: ArenaBots.think(_game, player, ArenaBots.Mind.new(), tick, float(TICK_RATE))})
			tick += 1
	return tick


## The rotation's own rides: [constant ROTATION_RIDE_MAPS], each map's first planned edge.
func _test_rotation_rides() -> void:
	_section("bots ride the rotation maps' ramps across the map")
	var tick := 0
	for map_id in ROTATION_RIDE_MAPS:
		var need: Array = ROTATION_RIDE_LANDING
		if map_id == &"surf_snipers_island":
			need = SNIPERS_RIDE_LANDING
		elif map_id == &"surf_the_flow":
			need = FLOW_RIDE_LANDING
		var rode := await _ride_on(map_id, tick, ROTATION_RIDE_STARTS, need)
		tick = int(rode.get("tick", tick)) + 64

		if (map_id == &"surf_snipers_island" or map_id == &"surf_the_flow") and not rode.is_empty():
			# The way in is the other half of the loop: from a spawn on the island a bot walks into a
			# teleport, lands on a pad and rides down, so its own route must hand it a ride.
			tick = await _roam_takes_ride(rode["surf"], _game.map.spawns[0].origin, tick)
	_done()


## The maps with planned rides, each played by six bots that roam and fight.
const BAND_MAPS: Array[StringName] = [&"surf_snipers_island", &"surf_the_flow", &"surf_10x_reloaded_fixed"]
## How long the bots are given on each, seconds of play.
const BAND_SECONDS := 90.0
## What six bots must do in that time. They are bands and not records: the mesh lands when the
## machine finishes it, so no two runs play alike. The floors are set well under what one run
## measured (90 s, six bots: 30 to 47 kills, 1,700 to 6,800 m walked, 1 to 6 platforms, 4 to 16
## rides; surf_snipers_island sometimes stays on one island while still riding), to catch bots that stand still, never meet, or never take a ride.
const BAND_ISLANDS_MIN := 1
const BAND_KILLS_MIN := 10
const BAND_METRES_MIN := 800.0
const BAND_RIDES_MIN := 1


## Bots as they play: [method ArenaBots.think] for all six on every map with ride edges, for
## [constant BAND_SECONDS]. They must roam (several platforms stood on, metres covered, a ride
## taken), fight (kills landed) and stay inside the map.
func _test_bot_band() -> void:
	_section("six bots roam and fight on every map with rides")
	var tick := 100000
	for map_id in BAND_MAPS:
		if ArenaMap.by_id(map_id) == null:
			_check(false, "%s is in the catalogue to be played" % map_id)
			_check(false, "so its bots cannot fight")
			_check(false, "nor stay in bounds")
			continue
		var changed := _game.change_map(ArenaMap.by_id(map_id))
		var world := ArenaBots.world_for(_game)
		var _first := world.route(Vector3.ZERO, Vector3.ONE)
		var frames := 0
		while world.is_route_pending() and frames < 1200:
			await get_tree().process_frame
			frames += 1
		var surf: ArenaSurf = world.surf_for_map() if changed.ok else null
		var kills: Array[int] = [0]
		var on_kill := func(_entry: DotKillFeed.Entry) -> void: kills[0] += 1
		_game.player_killed.connect(on_kill)
		var minds := {}
		var last := {}
		var metres := 0.0
		var islands := {}
		var outside := 0
		var bounds := _game.map.bounds.grow(1.0)
		var begun_before := surf.begun if surf != null else 0
		for player in _game.players():
			var mind := ArenaBots.Mind.new()
			mind.seed = 900 + player.player_id
			minds[player.player_id] = mind
		# Bots are random: a window that ended before the bar was met runs on, up to three times over, before it is judged.
		var t := -1
		var base_ticks := int(BAND_SECONDS * TICK_RATE)
		while t + 1 < base_ticks or (t + 1 < base_ticks * 3 and not (metres >= BAND_METRES_MIN and islands.size() >= BAND_ISLANDS_MIN and ((surf.begun - begun_before) if surf != null else 0) >= BAND_RIDES_MIN and kills[0] >= BAND_KILLS_MIN)):
			t += 1
			var commands := {}
			for player in _game.players():
				if player.is_alive():
					commands[player.player_id] = ArenaBots.think(_game, player, minds[player.player_id], tick, float(TICK_RATE))
			_game.tick(commands)
			tick += 1
			if t % 8 == 0:
				for player in _game.players():
					if not player.is_alive():
						last.erase(player.player_id)
						continue
					var feet := player.controller.state.position
					if not bounds.has_point(feet):
						outside += 1
					if last.has(player.player_id):
						var step: float = (feet - last[player.player_id]).length()
						# A teleport or a fall-out is not a walk.
						if step < 20.0:
							metres += step
					last[player.player_id] = feet
					if surf != null:
						var at: int = surf.nav.island_at(feet, 1.0)
						if at >= 0:
							islands[at] = true
			if t % 32 == 0:
				await get_tree().physics_frame
		_game.player_killed.disconnect(on_kill)
		var rides := (surf.begun - begun_before) if surf != null else 0
		_line("     %s: %d kills, %.0f m walked, %d platforms stood on, %d rides begun, %d samples out of bounds" % [
			map_id, kills[0], metres, islands.size(), rides, outside])
		_check(metres >= BAND_METRES_MIN and islands.size() >= BAND_ISLANDS_MIN and rides >= BAND_RIDES_MIN,
			"%s: the bots roam (%.0f m walked, %d platforms, %d rides)" % [map_id, metres, islands.size(), rides])
		_check(kills[0] >= BAND_KILLS_MIN, "%s: the bots fight (%d kills in %.0f s)" % [map_id, kills[0], float(t + 1) / TICK_RATE])
		_check(outside == 0, "%s: nobody leaves the map (%d samples outside)" % [map_id, outside])
	_done()


## Loads [param map_id], waits for its mesh, checks its planned edges are linked and that a
## route crosses the first, then rides that edge from [param starts] starts, [param need] of
## which must land. Returns
## the map's surf, the edge and the tick reached, or nothing when there was nothing to ride.
func _ride_on(map_id: StringName, tick: int, starts: int, need: Array) -> Dictionary:
	var changed := _game.change_map(ArenaMap.by_id(map_id))
	var world := ArenaBots.world_for(_game)
	# The mesh bakes in the background from the first route asked; the rides are linked when
	# it lands.
	var _first := world.route(Vector3.ZERO, Vector3.ONE)
	var frames := 0
	while world.is_route_pending() and frames < 1200:
		await get_tree().process_frame
		frames += 1
	var surf: ArenaSurf = world.surf_for_map() if changed.ok else null
	var planned: Array = surf.edges.filter(func(e: ArenaSurf.Edge) -> bool: return e.cache.size() > 0) if surf != null else []
	var linked := not planned.is_empty() and planned.all(func(e: ArenaSurf.Edge) -> bool: return e.linked)
	_check(linked, "%s's planned ride edges are linked into the bots' mesh (%s)" % [map_id,
		str(surf.describe()) if surf != null else "no cache at %s" % ArenaSurf.path_for(map_id)])
	if not linked:
		_check(false, "so no route crosses one")
		_check(false, "nor does a bot ride one")
		return {}
	var rode := {}
	for k in range(need.size()):
		# Planned edge k (in file order) must land need[k] of the starts; 0 skips it.
		if k < planned.size() and int(need[k]) > 0:
			rode = await _ride_edge(map_id, world, surf, planned[k], tick, starts, int(need[k]))
			tick = int(rode.get("tick", tick)) + 64
	return rode


## One planned [param edge]: the route crosses it, then a bot rides it from [param starts] starts.
func _ride_edge(map_id: StringName, world: ArenaBots.World, surf: ArenaSurf, edge: ArenaSurf.Edge, tick: int, starts: int, need: int) -> Dictionary:
	var way := world.route_detail(edge.from, edge.to)
	_check((way["rides"] as PackedInt32Array).has(edge.id),
		"the route from its platform to the one below crosses ride edge %d (%d corners)" % [edge.id, (way["points"] as PackedVector3Array).size()])

	var id := 4
	var bot := _game.player_for(id)
	# Everybody else off the ramp's line: players are solid (mp_solidplayers), and one standing on
	# the start platform is a wall the planned rides never met. A bot that rides into somebody is
	# a game, not this check.
	var aside: Vector3 = surf.edges[surf.edges.size() - 1].to if surf.edges.size() > 1 else edge.to + Vector3(30.0, 0.0, 0.0)
	for other in _game.players():
		if other.player_id != id and other.player_id != 5 and other.is_alive():
			other.controller.teleport(aside + Vector3(float(other.player_id), 0.0, 0.0), 0.0, 0.0)
	var landed := 0
	var alive := 0
	var notes: Array[String] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 41
	# A long, chaotic ride lands about half its starts, so a bare 'need of starts' fails on chance alone:
	# while short of the bar, spend up to four times the starts before judging.
	var k := -1
	while k + 1 < starts or (landed < need and k + 1 < starts * 4):
		k += 1
		if not bot.is_alive():
			_game.respawn_player(id)
		var at := edge.from
		var velocity := Vector3.ZERO
		if k > 0:
			var forward := DotFpsMotor.forward_for(edge.course.reference_yaw())
			at += Vector3(-forward.z, 0.0, forward.x) * rng.randf_range(-0.8, 0.8)
			velocity = DotFpsMotor.forward_for(edge.course.reference_yaw() + rng.randf_range(-60.0, 60.0)) * rng.randf_range(2.0, 8.0)
		bot.controller.teleport(at, edge.course.reference_yaw(), 0.0)
		bot.controller.state.velocity = velocity
		var mind := ArenaBots.Mind.new()
		mind.seed = 77 + k
		# What the route hands it when it reaches the edge's start.
		mind.ride = DotBotSurfRide.new().begin(edge.cache, edge.course, surf._sim_for(edge, bot.controller), tick, float(TICK_RATE))
		var before := surf.landed
		var ticks := 0
		while mind.ride != null and ticks < int(ArenaSurf.RIDE_SECONDS * TICK_RATE) + 4:
			_game.tick({id: ArenaBots.think(_game, bot, mind, tick, float(TICK_RATE))})
			tick += 1
			ticks += 1
			if ticks % 32 == 0:
				await get_tree().physics_frame
		var feet := bot.controller.state.position
		var made_it := surf.landed > before and surf.nav.on_island(edge.course.landing_island, feet, 0.6)
		landed += 1 if made_it else 0
		alive += 1 if made_it and bot.is_alive() else 0
		notes.append("%s %.2f s at %s" % ["landed" if made_it else "missed", float(ticks) / TICK_RATE, str(feet.round())])
	_line("     edge %d, %.0f m: %s" % [edge.id, edge.from.distance_to(edge.to), "; ".join(notes)])
	_check(landed >= need and alive == landed,
		"a bot rides it to the platform below and lands alive (%d of %d, %d needed)" % [landed, k + 1, need])
	return {"surf": surf, "edge": edge, "tick": tick}


func _test_surf_movement() -> void:
	_section("the surf air control is on here, off on a built-in map, and on again")

	var player := _game.player_for(1)
	var surf := ArenaPlayer.SURF_TUNABLES
	var arena := ArenaPlayer.arena_tunables()
	_check(_matches(player, surf, 150.0),
		"on %s: air_accelerate %.0f, air cap %.3f m/s, gravity %.2f" % [
			MAP, player.controller.tunables.air_accelerate,
			player.controller.tunables.max_air_wish_speed, player.controller.tunables.gravity
		])

	var to_box := _game.change_map(ArenaMap.dm_box())
	_check(to_box.ok and is_equal_approx(player.controller.tunables.air_accelerate, arena.air_accelerate)
		and is_equal_approx(player.controller.tunables.max_air_wish_speed, arena.max_air_wish_speed)
		and is_equal_approx(player.controller.tunables.gravity, arena.gravity),
		"on dm_box: back to the arena's own (%.0f, %.2f, %.0f)" % [
			player.controller.tunables.air_accelerate,
			player.controller.tunables.max_air_wish_speed, player.controller.tunables.gravity
		])
	_check(_game.map.collision_root == null and _game._world_collision == null,
		"and the imported solid went with the map")

	var back := _game.change_map(ArenaMap.by_id(MAP))
	_check(back.ok and _matches(player, surf, 150.0), "back on %s: on again" % MAP)

	_game.set_movement_rules({"surf_air_accelerate": 400.0})
	_check(is_equal_approx(player.controller.tunables.air_accelerate, 400.0),
		"arena_surf_airaccelerate reaches a player on the map (%.0f)" % player.controller.tunables.air_accelerate)

	_game.set_movement_rules({"surf": 0.0})
	_check(is_equal_approx(player.controller.tunables.air_accelerate, arena.air_accelerate)
		and is_equal_approx(player.controller.tunables.gravity, arena.gravity),
		"and arena_surf 0 plays it with the arena's own")

	_game.set_movement_rules({"surf": 1.0, "surf_air_accelerate": 150.0})
	_check(_matches(player, surf, 150.0), "and 1 puts the genre's back")

	_done()


func _matches(player: ArenaPlayer, surf: Dictionary, air: float) -> bool:
	var t := player.controller.tunables
	return (
		is_equal_approx(t.air_accelerate, air)
		and is_equal_approx(t.max_air_wish_speed, float(surf["max_air_wish_speed"]))
		and is_equal_approx(t.gravity, float(surf["gravity"]))
		and is_equal_approx(t.jump_height, float(surf["jump_height"]))
	)


# --- A ramp ------------------------------------------------------------------------

func _test_ramp() -> void:
	_section("a ramp is ridden, not stood on")

	var face := _steepest_big_ramp()
	_check(not face.is_empty(), "the map has a surf ramp (a face between %.0f and 75 degrees, %.0f m² of it)" % [
		ArenaPlayer.arena_tunables().max_slope_angle, float(face.get("area", 0.0))
	])

	if face.is_empty():
		_check(false, "so nothing could ride it")
		_check(false, "or slide down it")
		_done()
		return

	var normal: Vector3 = face["normal"]
	var player := _game.player_for(3)

	if not player.is_alive():
		_game.respawn_player(3)

	# Half a metre off the face, along its normal, and dropped: the hull lands ON the ramp.
	var start: Vector3 = face["centre"] + normal * 0.5
	player.controller.teleport(start, 0.0, 0.0)

	var grounded := 0
	var touching := 0
	var top_speed := 0.0
	var no_input := {3: [DotFpsCommand.new(), DotWeaponCommand.new()]}

	for i in range(TICK_RATE):
		_game.tick(no_input)
		var state := player.controller.state

		if state.is_grounded():
			grounded += 1

		# On the face: within a hand of its plane, above it.
		var height_over := normal.dot(state.position - (face["centre"] as Vector3))
		if height_over < 0.6 and height_over > -0.2:
			touching += 1

		top_speed = maxf(top_speed, state.velocity.length())

	var dropped := start.y - player.controller.state.position.y
	_line("     %d ticks on the face, %d grounded, top speed %.1f m/s, %.1f m down" % [
		touching, grounded, top_speed, dropped
	])
	_check(touching > TICK_RATE / 4 and grounded == 0,
		"the player rides it: %d ticks against the face and not one standing on it" % touching)
	_check(top_speed > 8.0 and dropped > 3.0,
		"and slides down it, picking up speed (%.1f m/s, %.1f m)" % [top_speed, dropped])

	_done()


## The biggest triangle of the map's own drawn RAMP surfaces whose slope is one the
## movement cannot stand on: `{centre, normal, area}`, or empty.
func _steepest_big_ramp() -> Dictionary:
	var manifest := ArenaImportedMaps.manifest(MAP)
	var dir := ArenaImportedMaps.manifest_path(MAP).get_base_dir()
	var blob := FileAccess.get_file_as_bytes(dir.path_join("%s.bin" % MAP))
	var limit := cos(deg_to_rad(ArenaPlayer.arena_tunables().max_slope_angle + 3.0))
	var best := {}
	var best_area := 0.0

	for entry: Variant in manifest.get("surfaces", []):
		var surface: Dictionary = entry

		if str(surface.get("role", "")) != "RAMP":
			continue

		var vcount := int(surface.get("vertex_count", 0))
		var icount := int(surface.get("index_count", 0))
		var floats := blob.slice(int(surface["vertex_offset"]),
			int(surface["vertex_offset"]) + vcount * ArenaBspMap.VERTEX_FLOATS * 4).to_float32_array()
		var indices := blob.slice(int(surface["index_offset"]),
			int(surface["index_offset"]) + icount * 4).to_int32_array()

		for t in range(0, icount - 2, 3):
			var p: Array[Vector3] = []

			for k in range(3):
				var o := int(indices[t + k]) * ArenaBspMap.VERTEX_FLOATS
				p.append(Vector3(floats[o], floats[o + 1], floats[o + 2]) * ArenaBspMap.METRES_PER_UNIT)

			var cross := (p[1] - p[0]).cross(p[2] - p[0])
			var area := cross.length() * 0.5

			if area <= best_area:
				continue

			# Either winding: the face a player lands on points up.
			var normal := cross.normalized()
			if normal.y < 0.0:
				normal = -normal

			if normal.y >= limit or normal.y < 0.26:
				continue

			best_area = area
			best = {"centre": (p[0] + p[1] + p[2]) / 3.0, "normal": normal, "area": area}

	return best


# --- Pits ----------------------------------------------------------------------

func _test_pits() -> void:
	_section("a pit sends a player where it aims, and the floor under the map catches")

	var pits := _game.map.pits
	_check(not pits.is_empty(), "the map has teleport volumes (%d)" % pits.size())

	var player := _game.player_for(2)

	if not player.is_alive():
		_game.respawn_player(2)

	var pit: Dictionary = pits[0]
	var box: AABB = pit["box"]
	player.controller.teleport(box.get_center(), 0.0, 0.0)
	_game.tick({})
	var at := player.controller.state.position
	_check(at.distance_to(pit["to"]) < 0.5,
		"stepped into one, the player is at its destination (%.2f m off)" % at.distance_to(pit["to"]))

	var under := _game.map.bounds.position - Vector3(-1.0, ArenaPlayer.FALL_OUT_DEPTH + 5.0, -1.0)
	player.controller.teleport(under, 0.0, 0.0)
	_game.tick({})
	var spawn: Transform3D = _game.map.spawns[0]
	_check(player.controller.state.position.distance_to(spawn.origin) < 0.5,
		"fallen out of the bottom of the map, back at a spawn")

	_done()


# --- The fall-out cell ---------------------------------------------------------------

## surf_ski_2's catch-all floor teleport aims at a roofed cell whose only way out is a door
## that the map's button opens. The importer runs no outputs, so the door stayed shut and
## whoever fell (a bot, in the ride check) was stuck there for good; the map's zones file now
## opens it (`open_doors`). Armed: with the door back in the import nobody leaves the cell.
func _test_fallout() -> void:
	_section("surf_ski_2: a fall into the floor catch-all lands in the cell, and the way out is open")

	var changed := _game.change_map(ArenaMap.by_id(RIDE_MAP))
	_check(changed.ok, "the map loads")
	if not changed.ok:
		_done()
		return

	var catch_all := -1
	var biggest := 0.0
	for index in range(_game.map.pits.size()):
		var volume: float = (_game.map.pits[index]["box"] as AABB).get_volume()
		if volume > biggest:
			biggest = volume
			catch_all = index
	var pit: Dictionary = _game.map.pits[catch_all]
	var cell: Vector3 = pit["to"]

	var player := _fresh(2)
	player.controller.teleport((pit["box"] as AABB).get_center(), 0.0, 0.0)
	_game.tick({})
	var at := player.controller.state.position
	_check(at.distance_to(cell) < 0.5,
		"the floor catch-all puts a faller in the cell (%.2f m off)" % at.distance_to(cell))

	# The cell's door is in its +z wall (Source's -y): walk at it, yaw 180 being +z.
	var door_z := cell.z + 6.2
	var out_at := -1
	# Four seconds: the shut door was walked round in about twelve, sliding along it to a
	# corner, which is not a way out a bot's route would take.
	for tick in range(TICK_RATE * 4):
		var move := DotFpsCommand.new()
		move.yaw = 180.0
		move.move = Vector2(0.0, 1.0)
		move.sanitise()
		_game.tick({player.player_id: [move, DotWeaponCommand.new()]})
		if player.controller.state.position.z > door_z:
			out_at = tick
			break
	_check(out_at >= 0,
		"walked out through the door (%s; ended %.1f, %.1f, %.1f)" % [
			"after %d ticks" % out_at if out_at >= 0 else "never",
			player.controller.state.position.x, player.controller.state.position.y,
			player.controller.state.position.z])

	_done()


## How far from a fall-out destination a faller must get to count as out, in metres: the
## ski_2 cell is about 12 m across, and the ground past its door is open for far more.
const FALLOUT_OUT_AT := 12.0
## Seconds spent walking each of eight headings from a destination.
const FALLOUT_WALK := 4.0
## Destinations tried per map, biggest volume first: the catch-all under the map is the one
## everybody reaches, and a second is the jail or pit someone is sent to on purpose.
const FALLOUT_PER_MAP := 2

## [b]General detector for a destination nobody can leave.[/b] The importer runs no outputs,
## so a door or floor that only a button moves stays as it rests, and a teleport aimed behind
## one seals whoever lands there. For every combat surf map this takes its biggest volumes
## (the floor catch-all first), drops a player on each destination and walks the eight
## headings in turn; the destination is open when some heading carries the player
## [constant FALLOUT_OUT_AT] metres off along the ground or off an edge, three metres down. A map listed
## here that fails wants an `open_doors` entry in game-g2gfast's zones file (README there) or
## a note saying why not. The scan that finds candidates in the .bsp is
## `game-g2gfast/tools/teleport_traps.py`.
func _test_fallout_all() -> void:
	_section("every combat surf map: a faller at a big teleport destination can walk away")

	var sealed: Array[String] = []
	var report: Array[String] = []
	var player := _fresh(2)

	for id in ArenaMap.imported_ids():
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
			for heading in range(8):
				var yaw := heading * 45.0
				player = _fresh(2)
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
				if best >= FALLOUT_OUT_AT:
					break
			report.append("%s pit %d -> (%.0f, %.0f, %.0f): got %.1f m (yaw %.0f)" % [
				id, index, cell.x, cell.y, cell.z, best, best_yaw])
			if best < FALLOUT_OUT_AT:
				sealed.append("%s pit %d" % [id, index])

	for line in report:
		_line("     " + line)

	_check(sealed.is_empty(), "no destination seals its faller in (%s)" % [sealed])

	_done()


# --- The jail ------------------------------------------------------------------------

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


# --- Packs and the dash ----------------------------------------------------------------

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


# --- Shots ---------------------------------------------------------------------

func _test_shots() -> void:
	_section("shots stop at the map's walls")

	var trace := _game.combat.trace
	var spawn: Transform3D = _game.map.spawns[0]
	var eye := spawn.origin + Vector3.UP * 1.6
	var blocked := 0
	var nearest := INF

	# Eight directions out of a spawn room: a room has walls, and a trace that hit none of
	# them would be one passing through the map.
	for i in range(8):
		var angle := TAU * float(i) / 8.0
		var hit := trace.ray(eye, Vector3(sin(angle), 0.0, cos(angle)), 200.0)

		if hit.blocked:
			blocked += 1
			nearest = minf(nearest, hit.distance)

	_check(blocked >= 6, "a shot out of the spawn room hits a wall in %d of 8 directions" % blocked)
	_check(trace.ray(eye, Vector3.DOWN, 5.0).blocked, "and the floor under the spawn")

	_done()


# --- The map's mechanics ------------------------------------------------------------

func _test_mechanics() -> void:
	_section("the map's own mechanics run: a booster, water, a ladder")

	var mech := _game.map.mechanics
	_check(mech != null and not mech.pushes.is_empty() and not mech.water.is_empty()
		and not mech.ladders.is_empty(),
		"the manifest's mechanics are read (%s)" % (mech.describe_lines()[0] if mech != null else "none"))

	if mech == null:
		for _i in range(5):
			_check(false, "so nothing could run")
		_done()
		return

	var player := _fresh(4)
	var probe := DotFpsPhysicsBody.for_node(_game.map.collision_root)
	var tunables := player.controller.tunables
	var idle := {4: [DotFpsCommand.new(), DotWeaponCommand.new()]}

	# A booster: the strongest sideways push lying on a floor. Stood on, it carries the
	# player along it and, on leaving, throws them on at its speed.
	var booster := {}
	for p: Dictionary in mech.pushes:
		var push: Vector3 = p["push"]
		var flat := Vector2(push.x, push.z).length()
		if not p["once"] and (p["box"] as AABB).size.y < 0.5 \
				and flat > Vector2(booster.get("push", Vector3.ZERO).x, booster.get("push", Vector3.ZERO).z).length():
			booster = p
	var box: AABB = booster["box"]
	var speed := (booster["push"] as Vector3).length()
	player.controller.teleport(Vector3(box.get_center().x, box.end.y + 0.02, box.get_center().z), 0.0, 0.0)
	var fastest := 0.0
	for _i in range(TICK_RATE):
		_game.tick(idle)
		fastest = maxf(fastest, player.controller.state.horizontal_speed())
	_line("     booster %.1f m/s at %s: fastest %.1f m/s" % [speed, box.get_center(), fastest])
	_check(fastest > speed * 0.9 and fastest < speed * 1.3,
		"a booster throws a player at its speed (%.1f m/s against %.1f)" % [fastest, speed])

	# Water: the deepest pool with clear water at its middle. A player put in it to the
	# chest swims; pressing nothing they sink, slowly; holding jump they come out of it.
	var pool := AABB()
	var feet := Vector3.ZERO
	var depth := player.swim.waist + 0.3
	# Most of these maps' water is a sheet a few centimetres deep over a pit; the pool is
	# the deepest one a player can be in to the waist, at a spot in it clear of solid.
	for w in mech.water:
		if w.size.x < 3.0 or w.size.z < 3.0 or w.size.y < 1.5 or w.size.y <= pool.size.y:
			continue
		for i in range(1, 8):
			for j in range(1, 8):
				var at := Vector3(w.position.x + w.size.x * i / 8.0, w.end.y - depth,
					w.position.z + w.size.z * j / 8.0)
				if not _in_solid(probe, at, tunables):
					pool = w
					feet = at
					break
			if pool == w:
				break
	player.controller.teleport(feet, 0.0, 0.0)
	_game.tick(idle)
	var swimming := player.controller.state.mode == player.swim.mode_id
	var top := player.controller.state.position.y
	for _i in range(TICK_RATE / 2):
		_game.tick(idle)
	var sunk := top - player.controller.state.position.y
	var sink_speed := -player.controller.state.velocity.y
	_check(swimming and player.controller.state.mode == player.swim.mode_id,
		"put in water to the chest, the player swims (mode %s)" % player.controller.motor.mode_name(player.controller.state.mode))
	_check(sunk > 0.2 and sunk < 0.9 and sink_speed < 2.0,
		"and pressing nothing sinks, slowly: %.2f m in half a second, %.2f m/s" % [sunk, sink_speed])
	var jump := DotFpsCommand.new()
	jump.set_button(DotFpsCommand.BUTTON_JUMP, true)
	var held := {4: [jump, DotWeaponCommand.new()]}
	var out_at := -1
	for i in range(TICK_RATE * 2):
		_game.tick(held)
		var s := player.controller.state
		if s.mode != player.swim.mode_id and s.position.y + player.swim.waist > pool.end.y:
			out_at = i
			break
	_check(out_at >= 0, "and holding jump comes up out of it (%s)" % (
		"%.2f s" % (float(out_at) / TICK_RATE) if out_at >= 0 else "still in after 2 s"))

	# A ladder: walked into from whichever side is clear, facing it, looking up.
	var climbed := 0.0
	var on_ladder := 0
	var tried := 0
	var best_at := Vector3.ZERO
	var best_climb: Dictionary = {}
	for rung in mech.ladders:
		if rung.size.y < 2.5:
			continue
		var thin_x := rung.size.x < rung.size.z
		for side: float in [1.0, -1.0]:
			var away := Vector3(side, 0.0, 0.0) if thin_x else Vector3(0.0, 0.0, side)
			var face := rung.get_center() + away * ((rung.size.x if thin_x else rung.size.z) * 0.5)
			var at := Vector3(face.x, rung.position.y + 0.3, face.z) + away * (tunables.radius + 0.05)
			if _in_solid(probe, at, tunables):
				continue
			tried += 1
			player.controller.teleport(at, rad_to_deg(atan2(away.x, away.z)), 0.0)
			var climb := DotFpsCommand.new()
			climb.move = Vector2(0.0, 1.0)
			climb.yaw = rad_to_deg(atan2(away.x, away.z))
			climb.pitch = 40.0
			var up := {4: [climb, DotWeaponCommand.new()]}
			var from := at.y
			var on := 0
			var high := from
			for _i in range(TICK_RATE):
				_game.tick(up)
				if player.controller.state.mode == player.ladder.mode_id:
					on += 1
				high = maxf(high, player.controller.state.position.y)
			if high - from > climbed:
				climbed = high - from
				on_ladder = on
				best_at = at
				best_climb = up
		if climbed > 2.0:
			break
	_line("     ladders tried from %d sides: climbed %.2f m, %d ticks on" % [tried, climbed, on_ladder])
	_check(on_ladder > TICK_RATE / 2 and climbed > 2.0,
		"a ladder is climbed: %.2f m up it in a second, %d ticks on it" % [climbed, on_ladder])

	# A replay of the ticks before a jump-off: the mode's jump-off tick is still the later
	# one, and a prediction replaying an earlier tick must take the ladder as the server
	# did then. Armed by counting the gap without the `since >= 0`.
	var grabbed := false
	if not best_climb.is_empty():
		player.controller.teleport(best_at, 0.0, 0.0)
		player.controller.state.mode = DotFpsState.Mode.AIR
		player.ladder._jumped_off_tick = player.ladder.now + 6
		for _i in range(4):
			_game.tick(best_climb)
			grabbed = grabbed or player.controller.state.mode == player.ladder.mode_id
		player.ladder._jumped_off_tick = -1000
	_check(grabbed, "a replayed tick before a jump-off still takes the ladder")

	_done()


## A player alive and out of their spawn protection, standing still.
func _fresh(id: int) -> ArenaPlayer:
	var player := _game.player_for(id)
	if not player.is_alive():
		_game.respawn_player(id)
	return player


# --- Hurt ----------------------------------------------------------------------------

func _test_hurt() -> void:
	_section("a hurt volume hurts through dot-combat, kills as the world, and heals")

	var changed := _game.change_map(ArenaMap.by_id(HURT_MAP))
	var mech := _game.map.mechanics if changed.ok else null

	# Volumes clear of the map's teleports, because a hurt sheet over a pit (most of them,
	# on most of these maps) sends the player away before a second pulse can land.
	var hurts: Dictionary = {}
	var heals: Dictionary = {}
	if mech != null:
		for h: Dictionary in mech.hurt:
			var box: AABB = h["box"]
			var amount := float(h["damage"])
			var over_pit := false
			for pit in _game.map.pits:
				if (pit["box"] as AABB).intersects(box):
					over_pit = true
			if over_pit:
				continue
			var area := box.size.x * box.size.z
			if amount > 0.0 and amount <= 200.0 and (hurts.is_empty() or area > float(hurts["area"])):
				h["area"] = area
				hurts = h
			if amount < 0.0:
				heals = h

	_check(not hurts.is_empty() and not heals.is_empty(),
		"on %s, a hurt volume and a healing one clear of its teleports (%d volumes)" % [
			HURT_MAP, mech.hurt.size() if mech != null else 0])

	if hurts.is_empty() or heals.is_empty():
		for _i in range(5):
			_check(false, "so nothing could hurt")
		_done()
		return

	_game.match_node.rules.warmup_sec = 0.0
	_game.freeze_sec = 0.0
	_game.match_node.rules.countdown_sec = 0.0
	var player := _fresh(5)
	var idle := {5: [DotFpsCommand.new(), DotWeaponCommand.new()]}
	# Past the spawn protection the map change gave everybody: this is about the hurt.
	await _ticks(_game.match_node.spawn_protection_ticks() + 2)

	var dealt: Array[DotDamage] = []
	var on_damage := func(d: DotDamage) -> void:
		if d.victim == 5:
			dealt.append(d)
	_game.combat.damage_applied.connect(on_damage)
	var feed: Array[DotKillFeed.Entry] = []
	var on_kill := func(e: DotKillFeed.Entry) -> void:
		if e.victim_key == "5":
			feed.append(e)
	_game.player_killed.connect(on_kill)

	var per_second := float(hurts["damage"])
	var pulse := per_second * ArenaMap.ArenaMapMechanics.HURT_INTERVAL
	var before := player.health.health
	_stand_in(player, hurts["box"])
	_game.tick(idle)
	var first := before - player.health.health
	_check(player.is_alive() and is_equal_approx(first, pulse),
		"stepping into a %.0f-a-second volume takes %.0f at once (%.1f, %.0f left)" % [
			per_second, pulse, first, player.health.health])
	_check(dealt.size() == 1 and dealt[0].attacker == 0 and dealt[0].type != null
		and dealt[0].type.id == ArenaContent.DAMAGE_WORLD,
		"through dot-combat, as world damage (%d events, attacker %d, type %s)" % [
			dealt.size(), dealt[0].attacker if not dealt.is_empty() else -1,
			dealt[0].type.id if not dealt.is_empty() and dealt[0].type != null else &"?"])

	# Out of it for a tick and straight back in takes nothing new: the half second is the
	# volume's, not restarted by leaving it (a hop or a bob across a thin sheet's edge was a
	# full pulse every re-entry). Armed by erasing the due tick on leaving.
	player.controller.teleport(_game.map.spawns[0].origin, 0.0, 0.0)
	_game.tick(idle)
	_stand_in(player, hurts["box"])
	_game.tick(idle)
	_check(is_equal_approx(before - player.health.health, pulse),
		"stepping out and back in a tick later takes no second pulse (%.0f off in all)" % [
			before - player.health.health])

	# The next pulse is half a second on, and not a tick sooner: then a second one, which
	# from a full 100 at 50 a pulse is the death.
	var interval := roundi(ArenaMap.ArenaMapMechanics.HURT_INTERVAL * TICK_RATE)
	for _i in range(interval - 3):
		_game.tick(idle)
	var held := player.health.health
	_game.tick(idle)
	_line("     %.0f/s: %.0f off at once, %.0f left half a second less a tick later, then %s" % [
		per_second, first, held, "dead" if not player.is_alive() else "%.0f" % player.health.health])
	_check(is_equal_approx(held, before - pulse) and (
			not player.is_alive() or is_equal_approx(player.health.health, before - pulse * 2.0)),
		"the next pulse lands half a second later and not a tick sooner (%.0f, then %.0f)" % [
			held, player.health.health])
	_check(feed.size() == (0 if player.is_alive() else 1) and (feed.is_empty() or feed[0].killer_key == ""),
		"and a death in it is the world's in the kill feed (%d entries, killer \"%s\")" % [
			feed.size(), feed[0].killer_key if not feed.is_empty() else "-"])

	# A negative amount heals: hurt once, out of it for a tick, into the healing volume.
	_game.respawn_player(5)
	await _ticks(_game.match_node.spawn_protection_ticks() + 2)
	player = _fresh(5)
	_stand_in(player, hurts["box"])
	_game.tick(idle)
	var hurt_to := player.health.health
	player.controller.teleport(_game.map.spawns[0].origin, 0.0, 0.0)
	_game.tick(idle)
	_stand_in(player, heals["box"])
	_game.tick(idle)
	var healed := player.health.health - hurt_to
	_check(is_equal_approx(healed, -float(heals["damage"]) * ArenaMap.ArenaMapMechanics.HURT_INTERVAL),
		"a volume of %.0f a second heals %.1f a pulse (%.1f)" % [
			float(heals["damage"]), -float(heals["damage"]) * 0.5, healed])

	_game.combat.damage_applied.disconnect(on_damage)
	_game.player_killed.disconnect(on_kill)
	_done()


## Puts [param player] standing on the top of [param box], in the middle of it.
func _stand_in(player: ArenaPlayer, box: AABB) -> void:
	player.controller.teleport(Vector3(box.get_center().x, box.end.y + 0.02, box.get_center().z), 0.0, 0.0)


# --- Every map -------------------------------------------------------------------

func _test_every_map() -> void:
	_section("every combat surf map builds and puts its spawns on a floor")

	var built := 0
	var bad: Array[String] = []
	var report: Array[String] = []

	for id in ArenaMap.imported_ids():
		var map := ArenaMap.by_id(id)
		var solid := map.to_collision()
		add_child(solid)
		map.collision_root = solid
		await get_tree().physics_frame

		if solid.get_child_count() > 0:
			built += 1

		var body := map.movement_body() as DotFpsPhysicsBody
		# Its own collision layer, and the body asks only that one. The game from the
		# earlier sections still has its map loaded in this same physics world, and a
		# spawn of the map under test standing where that map has a wall was counted
		# stuck: surf_akai_final, 24 of 32, and none when checked on its own (2026-10-09).
		if solid is CollisionObject3D:
			(solid as CollisionObject3D).collision_layer = ISOLATED_LAYER
		body.collision_mask = ISOLATED_LAYER
		var trace := map.shot_trace()
		if "collision_mask" in trace:
			trace.set("collision_mask", ISOLATED_LAYER)
		var tunables := ArenaPlayer.arena_tunables()
		var floored := 0
		var stuck := 0
		# What the game does at load, so what is checked is what a player is put on.
		var lifted := map.settle_spawns(body, tunables)

		for at in map.spawns:
			if trace.ray(at.origin + Vector3.UP * 0.5, Vector3.DOWN, 3.0).blocked:
				floored += 1

			if _in_solid(body, at.origin, tunables):
				stuck += 1

		report.append("%s %d/%d spawns floored, %d spawns and destinations lifted out of solid, %d still in it" % [
			id, floored, map.spawns.size(), lifted, stuck
		])

		# Most, not all: a mapper's spawn can be a few units off the floor or in a wall, and
		# dot-spawn's director only ever needs enough good ones. Half bad is a broken import.
		if map.spawns.size() < 8 or floored * 4 < map.spawns.size() * 3 or stuck * 4 > map.spawns.size():
			bad.append(String(id))

		remove_child(solid)
		solid.free()

	for line in report:
		_line("     " + line)

	_check(built == ArenaMap.imported_ids().size(),
		"every one builds a solid (%d of %d)" % [built, ArenaMap.imported_ids().size()])
	_check(bad.is_empty(), "and three in four of its spawns stand on a floor, clear of solid (%s fail)" % [bad])

	_done()


## dot-core's [DotCollisionAudit] over every imported map as a client draws it (the drawn brushes
## beside the collision the game builds): geometry with no shape near it is a wall a player
## walks into. Fails on any finding; what is meant to be walked through is opted out in
## `arena_bsp_map.gd` with the reason.
func _test_collision_audit() -> void:
	_section("every imported map: nothing drawn is walked through")

	for id in ArenaMap.imported_ids():
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
			_line("     %s: %d findings of %d examined" % [id, found, examined])

			for line in report.describe_lines().slice(1, 12):
				_line("       %s" % line)

		_check(res.ok and found == 0 and examined > 0, "%s: nothing drawn is walked through%s" % [id, "" if res.ok else " (" + res.error.message + ")"])
		world.queue_free()
		await get_tree().physics_frame

	_done()


# --- Named by the server ----------------------------------------------------------

## Stands in for a dot-server: `games.current_maps()` is all the director reads.
class StandInServer:
	extends RefCounted
	var games := StandInGames.new()


class StandInGames:
	extends RefCounted
	var maps := PackedStringArray()

	func current_maps() -> PackedStringArray:
		return maps


func _test_server_named() -> void:
	_section("a map only the server names is catalogued, built from its pack, and dropped")

	var key := "%s/%s@%s" % [DELIVERED_OWNER, DELIVERED_ID, DELIVERED_VERSION]
	var not_arena_key := "%s/%s@%s" % [DELIVERED_OWNER, DELIVERED_NOT_ARENA, DELIVERED_VERSION]
	var mount := "res://dot_cloud/%s/%s/%s" % [DELIVERED_OWNER, DELIVERED_ID, DELIVERED_VERSION]
	var other := "res://dot_cloud/%s/%s/%s" % [DELIVERED_OWNER, DELIVERED_NOT_ARENA, DELIVERED_VERSION]

	# The pack layout dot-cloud mounts: `<id>.json` and `<id>.bin` directly in the version
	# directory. MAP's files under a new id (the manifest's own `id` names the mesh), and a
	# second manifest that says it is a timer course. No lightmap or textures: a dedicated
	# server builds the solid only.
	var source := ArenaImportedMaps.manifest_path(MAP)
	var text := FileAccess.get_file_as_string(source)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(mount))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(other))
	_write(mount.path_join("%s.json" % DELIVERED_ID),
		text.replace("\"id\": \"%s\"" % MAP, "\"id\": \"%s\"" % DELIVERED_ID))
	DirAccess.copy_absolute(source.get_basename() + ".bin", mount.path_join("%s.bin" % DELIVERED_ID))
	_write(other.path_join("%s.json" % DELIVERED_NOT_ARENA),
		text.replace("\"id\": \"%s\"" % MAP, "\"id\": \"%s\"" % DELIVERED_NOT_ARENA)
			.replace("\"kind\": \"arena\"", "\"kind\": \"course\""))

	var server := StandInServer.new()
	server.games.maps = PackedStringArray([key, not_arena_key])

	var director := ArenaMapDirector.new()
	director.game = _game
	director.server = server
	add_child(director)
	var ready := director.setup()
	var catalogue := director.session.catalogue if ready.ok else null
	var def := catalogue.get_map(DELIVERED_ID) if catalogue != null else null

	_check(def != null and not def.is_local() and String(def.content_id) == "%s/%s" % [DELIVERED_OWNER, DELIVERED_ID]
		and def.version == DELIVERED_VERSION,
		"it is in the catalogue as delivered content, at its pack version (%s)" % (
			"%s %s" % [def.content_id, def.version] if def != null else "absent"))
	_check(def != null and not ArenaImportedMaps.is_mounted(DELIVERED_ID)
		and not ArenaMap.imported_ids().has(DELIVERED_ID),
		"and is not read or registered at boot, nor listed as a local import")
	_check(catalogue != null and not catalogue.has(DELIVERED_NOT_ARENA),
		"a named pack whose manifest is not kind arena is skipped")

	# What a client that has never heard of it makes of the announce: dot-map takes an unknown
	# map only when it is delivered and its scene is inside its own mount, and the scene here
	# is the manifest in the pack. No session, so nothing the client knows can answer first.
	var client := DotMapSyncClient.new()
	var accepted: DotResult = client._accept(DotMapMessage.announce(def)["map"]) if def != null \
		else DotResult.fail(DotError.CODE_STATE, "no def")
	client.free()
	_check(accepted.ok and ArenaMaps.is_delivered(accepted.value),
		"a client that has never heard of it accepts the announce as delivered content%s" % (
			"" if accepted.ok else ": " + accepted.error.message))

	var changed: DotResult = await director.change_to(DELIVERED_ID)
	await get_tree().physics_frame
	_check(changed.ok, "the change to it succeeds%s" % ("" if changed.ok else ": " + changed.error.message))
	_check(_game.map != null and _game.map.id == DELIVERED_ID and _game.map.is_imported()
		and _game.map.manifest_path.begins_with(mount + "/"),
		"the game is on it, built from the mounted manifest (%s)" % (
			_game.map.manifest_path if _game.map != null else "no map"))
	var solid := _game.map.collision_root if _game.map != null else null
	_check(solid != null and solid.is_inside_tree() and solid.get_child_count() > 100,
		"with its brushes in the tree (%d shapes)" % (solid.get_child_count() if solid != null else -1))
	_check(_game.map != null and _game.map.movement_profile == &"surf" and _game.map.spawns.size() > 0,
		"on the surf profile, with the mapper's spawns (%d)" % (_game.map.spawns.size() if _game.map != null else 0))

	# Back to a built-in, then the owner drops it from the list.
	var _back: DotResult = await director.change_to(&"dm_box")
	server.games.maps = PackedStringArray()
	var adopted := director.adopt_server_maps()
	_check(not catalogue.has(DELIVERED_ID) and int(adopted.get("removed", 0)) == 1
		and not ArenaImportedMaps.is_mounted(DELIVERED_ID),
		"and gone when the server stops naming it (removed %d)" % int(adopted.get("removed", 0)))

	remove_child(director)
	director.free()
	_remove_tree("res://dot_cloud/%s" % DELIVERED_OWNER)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("res://dot_cloud"))

	_done()


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)

	if f != null:
		f.store_string(text)
		f.close()


## Deletes a directory and everything under it.
func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)

	if dir == null:
		return

	for name in dir.get_files():
		DirAccess.remove_absolute(path.path_join(name))

	for name in dir.get_directories():
		_remove_tree(path.path_join(name))

	DirAccess.remove_absolute(path)


# --- Plumbing ------------------------------------------------------------------

## Whether a standing hull with its feet at [param feet] is inside solid.
##
## The query's capsule is placed by its CENTRE, so it is lifted half a height; and it is
## a little shorter and thinner than the player's, because a hull resting on a floor or
## against a wall touches it, and "touching" is not "inside".
## The physics layer [method _test_every_map] puts each map on, which nothing else uses.
const ISOLATED_LAYER := 1 << 19


static func _in_solid(body: DotFpsPhysicsBody, feet: Vector3, tunables: DotFpsTunables) -> bool:
	var height := tunables.stand_height - 0.2
	return body.overlaps(feet + Vector3.UP * (0.1 + height * 0.5), height, tunables.radius - 0.05)


func _ticks(count: int) -> void:
	for i in range(count):
		_game.tick({})

		if i % 16 == 0:
			await get_tree().physics_frame


func _section(title: String) -> void:
	_entered += 1
	_line("")
	_line("-- %s" % title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
