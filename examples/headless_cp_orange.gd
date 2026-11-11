extends DotGameCheckSuite

const ArenaGame := preload("../game/arena_game.gd")
const ArenaFlagView := preload("../game/arena_flag_view.gd")
const ArenaHud := preload("../game/arena_hud.gd")
const ArenaObjectives := preload("../game/arena_objectives.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMaps := preload("../game/arena_maps.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaModes := preload("../game/arena_modes.gd")
const ArenaBots := preload("../game/arena_bots.gd")
const ArenaImportedMaps := preload("../maps/arena_imported_maps.gd")
const ArenaBspMap := preload("../maps/arena_bsp_map.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

## cp-orange-x3 (fc-dm-maps), a large control point map: its team spawns are red and blue, the
## manifest lists the modes it hosts, and CTF puts the flags where `flag_spawns` says. Skips
## (exit 0, says so) when the map is not linked at maps/imported_dm.

const MAP := &"cp-orange-x3"
const BOTS := 12

var _game: ArenaGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("arena — cp-orange-x3: team spawns, modes, flags, routes")

	if not ArenaImportedMaps.has(MAP):
		print("no %s under maps/imported_dm — nothing to check (link arena-dm-maps)" % MAP)
		_report_sections(0, 0, 0, -1)
		return

	print("-- the manifest's spawns, modes and flags reach the map")
	var map := ArenaMap.by_id(MAP)
	var red := 0
	var blue := 0
	for index in map.spawns.size():
		match map.spawn_tag(index):
			&"red": red += 1
			&"blue": blue += 1
	_check(red == 16 and blue == 16, "16 red and 16 blue spawns carry their side (%d, %d)" % [red, blue])
	_check(map.spawns.size() - red - blue == 0, "every spawn belongs to a side (the editor leftovers are dropped)")
	_check(map.flag_homes.has("red") and map.flag_homes.has("blue") and map.flag_homes["red"].distance_to(map.flag_homes["blue"]) > 60.0,
		"a flag home per side, more than 60 m apart")
	_check(map.modes.has("ctf") and map.modes.has("tdm"), "the map lists ctf and tdm")

	print("-- the flags sit on the circular capture plates just outside each spawn, both sides identical")
	# The plates are the map's cap_point_base props under control points 1 (red) and 5 (blue), at the manifest's
	# `control_points` origins; the flags are authored on them, well past each side's spawn block.
	var centre := {"red": Vector3.ZERO, "blue": Vector3.ZERO}
	var count := {"red": 0, "blue": 0}
	for index in map.spawns.size():
		var tag := String(map.spawn_tag(index))
		if centre.has(tag):
			centre[tag] += map.spawns[index].origin
			count[tag] += 1
	for tag in centre:
		centre[tag] /= maxf(float(count[tag]), 1.0)
	var fr: Vector3 = map.flag_homes["red"]
	var fb: Vector3 = map.flag_homes["blue"]
	var own_red := Vector2(fr.x - centre["red"].x, fr.z - centre["red"].z).length()
	var own_blue := Vector2(fb.x - centre["blue"].x, fb.z - centre["blue"].z).length()
	_check(own_red > 10.0 and own_red < 40.0 and own_blue > 10.0 and own_blue < 40.0,
		"each flag is just outside its own spawn block (%.1f m, %.1f m)" % [own_red, own_blue])
	_check(absf(own_red - own_blue) < 1.0, "the two flags are the same distance from their spawns")
	var mid := (fr + fb) * 0.5
	var spun := Vector2(2.0 * mid.x - centre["red"].x, 2.0 * mid.z - centre["red"].z)
	_check(spun.distance_to(Vector2(centre["blue"].x, centre["blue"].z)) < 1.5 and absf(fr.y - fb.y) < 0.3,
		"the red side turned half a turn about the plates' midpoint is the blue side")
	var plate_red := Vector3(1164.64, -2052.75, -6222.64) * 0.01905
	var plate_blue := Vector3(-2623.36, -2052.75, -888.64) * 0.01905
	_check(Vector2(fr.x - plate_red.x, fr.z - plate_red.z).length() < 0.5 and Vector2(fb.x - plate_blue.x, fb.z - plate_blue.z).length() < 0.5,
		"each flag stands on its capture plate (within 0.5 m of the plate centre)")

	await _run_part2(map, red, blue)


func _run_part2(map: ArenaMap, red: int, blue: int) -> void:
	print("-- spawns stand on a floor")
	var space := get_viewport().world_3d.direct_space_state
	_game = _new_game(ArenaMode.team_deathmatch(5))
	_check(_game != null, "team deathmatch sets up on it")
	var floored := 0
	for spawn in _game.map.spawns:
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(spawn.origin + Vector3.UP * 1.0, spawn.origin + Vector3.DOWN * 1.5))
		floored += 1 if not hit.is_empty() else 0
		if hit.is_empty():
			print("  no ground under %s" % spawn.origin)
	_check(floored == _game.map.spawns.size(), "every spawn has ground within 1.5 m below (%d of %d)" % [floored, _game.map.spawns.size()])

	print("-- the sky stops shots as before but takes no marks")
	var skies := get_tree().get_nodes_in_group(ArenaBspMap.SKY_GROUP)
	_check(not skies.is_empty(), "the sky brushes are marked by their own area (%d)" % skies.size())
	var sky_area := (skies[0] if not skies.is_empty() else null) as Area3D
	var world_body := (sky_area.get_parent() if sky_area != null else null) as StaticBody3D
	_check(sky_area != null and world_body != null and sky_area.collision_layer == ArenaBspMap.SKY_BIT \
		and world_body.collision_layer & ArenaBspMap.SKY_BIT == 0, "on a layer of its own, beside the world body")
	_check(sky_area != null and str(sky_area.get_meta(&"hull_kind", "")) == "sky", "tagged hull_kind sky, which the weapon effects skip")
	var world_shapes := {}
	for shape: Node in (world_body.get_children() if world_body != null else []):
		if shape is CollisionShape3D:
			world_shapes[(shape as CollisionShape3D).shape] = true
	var kept := 0
	for shape: Node in (sky_area.get_children() if sky_area != null else []):
		kept += 1 if world_shapes.has((shape as CollisionShape3D).shape) else 0
	_check(sky_area != null and kept > 0 and kept == sky_area.get_child_count(),
		"the world body still holds every sky hull (hit results and the nav bake unchanged)")
	# The spawn rooms are roofed, so the shots go up from open ground: a grid of points dropped from under the sky's top
	# brush. A drop that lands on the sky's bottom brush is outside the playable map and is skipped; a shot up counts once
	# it reaches the underside of the top sky brush (roof).
	var corners := PackedVector3Array()
	var roof := -INF
	for shape: Node in (sky_area.get_children() if sky_area != null else []):
		var points := ((shape as CollisionShape3D).shape as ConvexPolygonShape3D).points
		corners.append_array(points)
		var low := INF
		for p in points:
			low = minf(low, p.y)
		roof = maxf(roof, low)
	var sky_box := AABB(corners[0], Vector3.ZERO) if not corners.is_empty() else AABB()
	for p in corners:
		sky_box = sky_box.expand(p)
	var up_sky := 0
	var marked_sky := 0
	var grounds := 0
	for gx in 16:
		for gz in 16:
			var top := Vector3(sky_box.position.x + sky_box.size.x * (gx + 0.5) / 16.0, sky_box.end.y - 3.0,
				sky_box.position.z + sky_box.size.z * (gz + 0.5) / 16.0)
			var down := space.intersect_ray(PhysicsRayQueryParameters3D.create(top, Vector3(top.x, sky_box.position.y - 1.0, top.z)))
			if down.is_empty() or ArenaBspMap.on_sky(space, down.position, Vector3.DOWN):
				continue
			grounds += 1
			var from: Vector3 = down.position + Vector3.UP * 1.0
			var up := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + Vector3.UP * 4000.0))
			if up.is_empty() or up.collider != world_body:
				continue
			if up.position.y < roof - 0.1:
				continue
			up_sky += 1
			marked_sky += 0 if ArenaBspMap.on_sky(space, up.position, Vector3.UP) else 1
	_check(up_sky > 0, "a shot straight up from open ground still stops on the sky (%d of %d grounds)" % [up_sky, grounds])
	_check(up_sky > 0 and marked_sky == 0, "every such hit reads as sky, so it gets no decal (%d missed)" % marked_sky)
	_check(grounds > 0, "some ground under the sky does not read as sky (%d)" % grounds)

	await _run_part3(red, blue)


func _run_part3(red: int, blue: int) -> void:
	print("-- the modes it hosts are the listed ones")
	var def := ArenaMaps.catalogue().get_map(MAP)
	_check(def != null and ArenaMaps.supports_mode(def, ArenaModes.by_id(&"tdm")) and ArenaMaps.supports_mode(def, ArenaModes.by_id(&"ctf")) \
		and ArenaMaps.supports_mode(def, ArenaModes.by_id(&"ffa")), "tdm, ctf and ffa are supported")
	_check(def != null and not ArenaMaps.supports_mode(def, ArenaModes.by_id(&"siege")) and not ArenaMaps.supports_mode(def, ArenaModes.by_id(&"koth")),
		"siege and koth are not")

	print("-- team deathmatch spawns each side at its own end")
	_game.match_node.rules.warmup_sec = 0.0
	_game.freeze_sec = 0.0
	_game.match_node.rules.countdown_sec = 0.0
	for i in BOTS:
		var added := _game.add_player(i + 1, "bot%d" % (i + 1))
		_check(added.ok, "bot %d joined" % (i + 1))
	_game.start(0)
	for i in BOTS:
		var _r := _game.respawn_player(i + 1)
	var tag_of := {}
	for team in _game.teams():
		tag_of[team.id] = String(team.spawn_tag)
	var right := 0
	var sides := {}
	for i in BOTS:
		var id := i + 1
		var team := _game.team_of(id)
		sides[team] = true
		var at: Vector3 = _game.player_for(id).controller.state.position
		var nearest_tag := ""
		var best := INF
		for index in _game.map.spawns.size():
			var d := at.distance_to(_game.map.spawns[index].origin)
			if d < best:
				best = d
				nearest_tag = String(_game.map.spawn_tag(index))
		right += 1 if nearest_tag == tag_of.get(team, "?") else 0
	_check(sides.size() == 2, "the bots fall on two sides")
	_check(right == BOTS, "each bot stands on a spawn of its own side's tag (%d of %d)" % [right, BOTS])

	await _run_part4(red, blue)


func _run_part4(red: int, blue: int) -> void:
	print("-- bots route between the two bases over the baked mesh")
	var world := ArenaBots.world_for(_game)
	var a := Vector3.ZERO
	var b := Vector3.ZERO
	for index in _game.map.spawns.size():
		if _game.map.spawn_tag(index) == &"red":
			a = _game.map.spawns[index].origin
		elif _game.map.spawn_tag(index) == &"blue":
			b = _game.map.spawns[index].origin
	var frames := 0
	while not world.warm() and frames < 6000:
		await get_tree().process_frame
		frames += 1
	# A route is a stretch toward the goal, so two points are joined if repeated legs from where each ends arrive.
	var flag_red: Vector3 = _game.map.flag_homes["red"]
	var flag_blue: Vector3 = _game.map.flag_homes["blue"]
	for pair in [["red spawn to the blue spawn", a, b], ["blue spawn to the red spawn", b, a], ["red spawn to the blue flag", a, flag_blue],
			["blue spawn to the red flag", b, flag_red]]:
		var gap := _walk_gap(world, pair[1], pair[2])
		_check(gap < 2.0, "%s: routes arrive (ends %.1f m short)" % [pair[0], gap])
	var reached := 0
	var all_spawns: Array[Transform3D] = _game.map.spawns
	for spawn in all_spawns:
		var way := world.route(a, spawn.origin)
		if way.size() >= 2 and way[way.size() - 1].distance_to(spawn.origin) < 1.5:
			reached += 1
	print("  from the last red spawn, %d of %d spawns are reached in full" % [reached, all_spawns.size()])

	print("-- a player walks up each staircase to the top of the wall beside it")
	# The two portable stairs are the sniper way up: the converter's ramp hull under each is what the body
	# climbs. Hammer (x, y, z) is (x, z, -y) here. Forward held, no jump: grounded at wall-top height within
	# 1.5 m of the landing is on the stairs' top (the floor round them is 4.7 m lower).
	var climber: ArenaPlayer = _game.player_for(1)
	# The first tick of the match moves the body to its spawn; only after it does a teleport hold.
	_game.tick({})
	for stair in [[Vector3(760, -2053, -5316), Vector3(330, -1804, -5316)], [Vector3(-2275, -2053, -1808), Vector3(-1845, -1804, -1808)]]:
		var foot: Vector3 = stair[0] * 0.01905
		var top: Vector3 = stair[1] * 0.01905
		# teleport and not state.position: the controller's body keeps its old place otherwise.
		climber.controller.teleport(foot, rad_to_deg(atan2(foot.x - top.x, foot.z - top.z)), 0.0)
		var stood := Vector3.INF
		var highest := foot
		for i in 8 * 64:
			var feet: Vector3 = climber.controller.state.position
			var move := DotFpsCommand.new()
			move.move = Vector2(0.0, 1.0)
			move.yaw = rad_to_deg(atan2(feet.x - top.x, feet.z - top.z))
			_game.tick({1: [move, DotWeaponCommand.new()]})
			feet = climber.controller.state.position
			highest = feet if feet.y > highest.y else highest
			if climber.controller.state.is_grounded() and feet.y > top.y - 0.2 and Vector2(feet.x - top.x, feet.z - top.z).length() < 1.5:
				stood = feet
				break
			if i % 16 == 0:
				await get_tree().physics_frame
		_check(stood.is_finite(), "from %s a player walks up %.2f m and stands at the top" % [foot, highest.y - foot.y],
			"highest %s, ended %s" % [highest, climber.controller.state.position])
	_game.queue_free()
	await get_tree().process_frame

	await _run_part5(red, blue, a)


func _run_part5(red: int, blue: int, a: Vector3) -> void:
	print("-- capture the flag puts each flag at its side's home")
	_game = _new_game(ArenaMode.capture_the_flag(3))
	_check(_game != null and _game.objectives != null, "capture the flag sets up with objectives")
	if _game != null and _game.objectives != null:
		var flags := _game.objectives.manager.objectives.flags()
		var ok := flags.size() == 2
		for flag in flags:
			var want: Vector3 = _game.map.flag_homes["red" if String(flag.def.id).ends_with("1") else "blue"] + Vector3.UP
			ok = ok and flag.at.distance_to(want) < 0.5
		_check(ok, "two flags, each at its authored home")
		var fv := ArenaFlagView.new()
		fv.game = _game
		fv.ctf = _game.objectives.ctf
		add_child(fv)
		fv.refresh()
		var homes_ok := fv.drawn_count() == 2
		for flag in flags:
			var drawn := fv.view_position(flag.home_team())
			# On the floor under the stand (the stand's point floats a metre up), never above it.
			homes_ok = homes_ok and Vector2(drawn.x, drawn.z).distance_to(Vector2(flag.at.x, flag.at.z)) < 0.3 \
				and drawn.y <= flag.at.y + 0.05 and drawn.y > flag.at.y - 2.0
		_check(homes_ok, "and the flag view draws both, one per side, at those homes")
		fv.queue_free()
		# The real client path: game.headless is true there (collision backend) and a screen decides drawing.
		var objs: ArenaObjectives = _game.objectives
		_check(_game.headless and objs.flag_view == null, "a headless server builds no flag view")
		_check(ArenaObjectives.draws_flags(false) and not ArenaObjectives.draws_flags(true), "a process with a screen draws flags whatever game.headless says")
		objs.draw_flags = true
		objs._build_flag_view()
		await get_tree().process_frame
		var built: bool = objs.flag_view != null and objs.flag_view.drawn_count() == 2 and objs.flag_view.is_inside_tree()
		_check(built, "a client game (game.headless true) with a screen builds the flag view, two flags drawn")
		# What the view reports as the flag changes hands (the client's sounds hang off this), and the carrier's HUD line.
		var seen: Array[String] = []
		_game.ctf_seen.connect(func(what: StringName, team: int, by: int) -> void: seen.append("%d:%s:%d" % [team, what, by]))
		var one: DotObjectiveFlag = flags[0]
		var team_one := one.home_team()
		var thief := 1
		var _added := _game.add_player(thief, "thief")
		var _spawned := _game.respawn_player(thief)
		objs.flag_view.refresh()
		one.state = DotObjectiveFlag.State.CARRIED
		one.carrier = str(thief)
		objs.flag_view.refresh()
		one.drop(one.at + Vector3(4, 0, 0))
		objs.flag_view.refresh()
		one.send_home("")
		objs.flag_view.refresh()
		_check(seen == ["%d:taken:%d" % [team_one, thief], "%d:dropped:%d" % [team_one, thief], "%d:returned:0" % team_one], "the flag view reports taken, dropped, returned as the flag changes hands", str(seen))
		var hud := ArenaHud.new()
		add_child(hud)
		hud.build(_game)
		hud.follow(_game.player_for(thief))
		_check(hud.carrying_flag_text() == "", "the HUD has no carry line while nothing is carried")
		one.state = DotObjectiveFlag.State.CARRIED
		one.carrier = str(thief)
		_check(hud.carrying_flag_text().begins_with("YOU HAVE THE "), "the carrier's HUD says they have the flag", hud.carrying_flag_text())
		one.send_home("")
		hud.queue_free()

	_report_sections(6, 6, 6, -1)


## How far short of [param to] repeated route legs from [param from] end.
func _walk_gap(world: Object, from: Vector3, to: Vector3) -> float:
	var at := from
	for leg in 16:
		if at.distance_to(to) <= 1.5:
			break
		var way: PackedVector3Array = world.route_detail(at, to)["points"]
		if way.size() < 2 or way[way.size() - 1].distance_to(to) >= at.distance_to(to) - 0.5:
			break
		at = way[way.size() - 1]
	return at.distance_to(to)


func _new_game(mode: ArenaMode) -> ArenaGame:
	var game := ArenaGame.new()
	game.tick_rate = 64
	game.headless = true
	game.is_authority = true
	game.register_service = false
	game.mode = mode
	add_child(game)
	var res := game.setup(ArenaMap.by_id(MAP))
	if not res.ok:
		print("setup failed: %s" % res.error.message)
		game.queue_free()
		return null
	return game
