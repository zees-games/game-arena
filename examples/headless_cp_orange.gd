extends DotGameCheckSuite

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMaps := preload("../game/arena_maps.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaModes := preload("../game/arena_modes.gd")
const ArenaBots := preload("../game/arena_bots.gd")
const ArenaImportedMaps := preload("../maps/arena_imported_maps.gd")

## cp-orange-x3 (arena-dm-maps), a large control point map: its team spawns are red and blue, the
## manifest lists the modes it hosts, and CTF puts the flags where `flag_spawns` says. Skips (exit 0,
## says so) when the map is not linked at maps/imported_dm. [codeblock]
## godot --headless --path . res://examples/headless_cp_orange.tscn
## [/codeblock]

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
	_game.queue_free()
	await get_tree().process_frame

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
