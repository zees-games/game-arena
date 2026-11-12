extends "headless_imported_b0.gd"

const ArenaBots := preload("../game/arena_bots.gd")


const ArenaSurf := preload("../game/arena_surf.gd")
const ArenaSurfRides := preload("../game/arena_surf_rides.gd")


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

	# From that spawn to every other: every leg clear at knee height.
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


## Its starts, and how many must land.
const RIDE_STARTS := 3
const RIDE_LANDING := 2
## The edges the recorded-ride check records, each its own section: ones whose live rides
## land from the lip at rest, never "the first linked", which moves on every replan. Edges 0,
## 1, 3 and 7 miss or fall and want a replan.
const RECORD_EDGES := [6, 4]
## The rate the ride caches were planned at (ArenaContent.TICK_RATE, the game's default), which the
## recorded rides are ridden at: a cache stepped at another rate drifts off its line and the ride dies.
const RIDE_CACHE_RATE := 66
## The recorded-ride check's rate: [constant RIDE_CACHE_RATE] unless `-- --ride-rate=N` says otherwise (for working on the rides).
var _ride_rate := RIDE_CACHE_RATE
## How long a roaming bot is given to take a ride of its own accord, seconds.
const ROAM_SECONDS := 90.0


## The rotation's maps with planned rides, each ridden as [constant RIDE_MAP] is (one edge,
## [constant ROTATION_RIDE_STARTS] starts). Their rides are several flights long, which is why they were
## the last to get any; see docs/imported-maps.md, "Which maps have rides".
const ROTATION_RIDE_MAPS: Array[StringName] = [&"surf_10x_reloaded_fixed", &"surf_snipers_island", &"surf_the_flow"]
## Their starts, and how many must land. Wider than [constant RIDE_STARTS] on purpose: 10x's
## edges are 10 s rides that land one start in four to eight.
const ROTATION_RIDE_STARTS := 6
## While short of the bar, a ride check spends up to this many times its starts (48 for 6).
const RIDE_START_BUDGET := 8
## The seed of the perturbed starts; `-- --rotation --rotation-seed=N` draws others.
const ROTATION_RIDE_SEED := 41
var _rotation_seed := ROTATION_RIDE_SEED
## Per planned edge in file order (10x: file edges 0, 1 and 2, about 300 m each). Ridden here at 66 Hz
## from 5 seeds (`-- --rotation --rotation-seed=N`) they landed 8 of 35, 10 of 76 and 10 of 28 starts
## (23%, 13%, 36%; the cache's own records say 52%, 22%, 20% simulated); most misses fall into the
## teleport under the ramp. With 48 starts, 1, 1 and 2 landings fail by chance about once in 700
## runs (2 of 24 on edge 1 failed about one run in six), and a ride that has stopped working lands none.
const ROTATION_RIDE_LANDING: Array = [1, 1, 2]
## surf_snipers_island's three edges go from the pads its teleports put a player on down to the
## island with the spawns (0.6 to 1.7 s, 64 to 107 m); they land 100% of simulated and live rides
## (`--measure`), so five of six is the bar and one miss is tolerated.
const SNIPERS_RIDE_LANDING: Array = [5, 5, 5]
## surf_the_flow's two edges go from each spawn platform (16 spawns on each) down to the floor island
## the teleports land on (3.2 to 3.5 s); 100% simulated and 95% to 100% live (`--measure`), so five of six.
const FLOW_RIDE_LANDING: Array = [5, 5]


## Bots ride the ramps (`game/arena_surf.gd`): the edges are linked into the mesh, a route
## crosses one, a bot handed it lands alive from [constant RIDE_STARTS] starts, and a roaming
## bot is handed one by its own route.
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
	# The roamer alone on the map, the others back afterwards: bots parked on the start
	# platform and a roamer that sees one fights instead of roaming. This is about routes.
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
func _test_recorded_rides(record_edge: int) -> void:
	_section("players' rides on edge %d are recorded, harvested on the motor and ridden by a bot" % record_edge)
	_ride_rate = RIDE_CACHE_RATE
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ride-rate="):
			_ride_rate = clampi(int(arg.trim_prefix("--ride-rate=")), 15, 128)
	var changed := _game.change_map(ArenaMap.by_id(RIDE_MAP))
	var world := ArenaBots.world_for(_game)
	var _first := world.route(Vector3.ZERO, Vector3.ONE)
	var frames := 0
	while world.is_route_pending() and frames < 1200:
		await get_tree().process_frame
		frames += 1
	var surf: ArenaSurf = world.surf_for_map() if changed.ok else null
	var planned: Array = surf.edges.filter(func(e: ArenaSurf.Edge) -> bool: return e.linked and e.id == record_edge) if surf != null else []
	if planned.is_empty():
		_check(false, "%s has linked ride edge %d to record" % [RIDE_MAP, record_edge])
		_done()
		return
	var edge: ArenaSurf.Edge = planned[0]

	# Off until the config says so, and the two numbers are the recorder's own.
	# Existing players follow the game's rate (set_tick_rate reaches them, not only new ones).
	var suite_rate := _game.tick_rate
	_game.set_tick_rate(_ride_rate)
	_check(_game.players().all(func(p: ArenaPlayer) -> bool: return p.controller.tick_rate == _ride_rate),
		"players already in the game move on its new tick rate (%d)" % _ride_rate)
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
	var ready: DotResult = fresh.call(&"setup", _game, cfg, store, float(_ride_rate))
	_check(ready.ok, "a recorder and its ride book are built over a store")
	# release() breaks the callables that point back at the recorder, or it outlives the run.
	rides.call(&"release")
	_game.surf_rides = fresh
	rides = fresh

	var human_id := 4
	var human := _game.player_for(human_id)
	_check(human.controller.tick_rate == _game.tick_rate, "players move on the game's tick rate (%d, %d)" % [human.controller.tick_rate, _game.tick_rate])
	# A ride is a line along a ramp beside walls; a jump tap there is not a wall-run.
	for rider_id in [4, 5]:
		_game.player_for(rider_id).controller.tunables.wall_run_on_jump = false
	var aside: Vector3 = edge.to + Vector3(30.0, 0.0, 0.0)
	for other in _game.players():
		if other.player_id != human_id and other.player_id != 5:
			other.controller.teleport(aside + Vector3(float(other.player_id), 0.0, 0.0), 0.0, 0.0)
	var tick := 40000
	tick = await _ride_as_player(human, edge, surf, tick, 1)
	_check(rides.recorder.recorded == 0 and rides.kept == 0, "with recording off a ride is recorded by nobody (%d)" % rides.recorder.recorded)

	await _test_recorded_rides_part2(surf, edge, suite_rate, rides, cfg, store, fresh, human, aside, tick)


func _test_recorded_rides_part2(surf: ArenaSurf, edge: ArenaSurf.Edge, suite_rate, rides: RefCounted, cfg: DotBotDemoConfig, store: DotBotDemoStoreMemory, fresh: RefCounted, human, aside: Vector3, tick) -> void:
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

	# The open-loop replay and the bot playing the raw commands; headless_ride_pilot covers the piloted harvest.
	rides.ride_config.piloted = false
	var harvest: DotBotRideHarvest = rides.harvest_on(human.controller)
	var done: DotResult = await harvest.harvest(store, rides.recorder.map_id, rides.recorder.map_version, ArenaSurfRides.KIND, key)
	var verified_total: int = harvest.verified + rides.harvested
	# Most land: with the players' motor on 1/66 s while the game ticked 1/64, edge 4 landed 2 of 5; on one rate, all 5.
	_check(harvest.ready().ok and done.ok and verified_total >= 1 and verified_total * 2 >= rides.kept,
		"replayed on the real motor, %d of %d recorded rides land (%d rejected)" % [verified_total, rides.kept, harvest.rejected])

	# A bot rides the verified recording, and is never recorded itself.
	var recorded_before: int = rides.recorder.recorded
	var rebuilt := DotBotRideBook.new(rides.ride_config)
	rebuilt.set_map(rides.recorder.map_id, rides.recorder.map_version)
	rides.book = rebuilt
	var loaded: DotResult = await rebuilt.load_edge(store, ArenaSurfRides.KIND, key, rides.schema, float(_ride_rate))
	rides._edge_keys[edge.id] = key
	_check(loaded.ok and rebuilt.recorded_count(key) >= 1, "the book holds %d verified recordings of the edge" % rebuilt.recorded_count(key))
	var bot := _game.player_for(5)
	bot.set_meta(&"bot", true)
	if not bot.is_alive():
		_game.respawn_player(5)
	surf.rides = rides
	human.controller.teleport(aside + Vector3(-6.0, 0.0, 0.0), 0.0, 0.0)
	var landed_before := surf.landed
	var run := await _bot_rides(bot, surf, edge, landed_before, tick)
	tick = run["tick"]
	var source: String = run["source"]
	var ridden: int = run["ridden"]
	_check(source == DotBotRideBook.RECORDED and surf.landed > landed_before,
		"a bot rides a recorded line to the platform below (%s, %s, %d ticks)" % [source, "landed" if surf.landed > landed_before else "did not land", ridden])
	_check(rides.recorder.recorded == recorded_before and rides.begun == rides.kept + rides.discarded,
		"and the bot is not recorded (%d recorded before and after)" % recorded_before)
	bot.remove_meta(&"bot")
	surf.rides = null
	fresh.call(&"release")
	_game.surf_rides = null
	_game.set_tick_rate(suite_rate)
	_done()


## Steers [param bot] down [param edge] up to eight times from the lip until [member ArenaSurf.landed] passes [param landed_before]; returns the final tick, the recording's source and the ticks ridden.
func _bot_rides(bot: ArenaPlayer, surf: ArenaSurf, edge: ArenaSurf.Edge, landed_before: int, tick: int) -> Dictionary:
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
		while ridden < int(ArenaSurf.RIDE_SECONDS * _ride_rate) + 4:
			surf.steer(bot, mind, intent, tick, float(_ride_rate))
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
	return {"tick": tick, "source": source, "ridden": ridden}


## Everyone but the rider steps aside: players are solid to each other and a respawned one stands on the lip.
func _park_others(rider: ArenaPlayer, edge: ArenaSurf.Edge) -> void:
	var aside: Vector3 = edge.to + Vector3(30.0, 0.0, 0.0)
	for other in _game.players():
		if other != rider:
			other.controller.teleport(aside + Vector3(float(other.player_id), 0.0, 0.0), 0.0, 0.0)


## A teleport keeps the motor's wall-jump and wall-run counters, so a ride started after another ride, or after bots played on the
## same player, began with a spent wall budget and missed the lip's jump. A person's ride starts on the ground with a fresh one.
func _clear_wall_state(state: DotFpsState) -> void:
	state.wall_jump_count = 0
	state.wall_jumps_in_air = 0
	state.wall_jump_heading = 0
	state.wall_run_spent = false
	state.wall_run_time = -1.0
	state.wall_run_cooldown_left = 0.0
	state.time_since_jump = 1000.0
	state.time_since_jump_pressed = 1000.0


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
		_clear_wall_state(player.controller.state)
		_park_others(player, edge)
		var mind := ArenaBots.Mind.new()
		mind.seed = 300 + k
		var outcome := [surf.landed, surf.fell, surf.timed_out]
		mind.ride = DotBotSurfRide.new().begin(edge.cache, edge.course, surf._sim_for(edge, player.controller), tick, float(_ride_rate))
		var ticks := 0
		while mind.ride != null and ticks < int(ArenaSurf.RIDE_SECONDS * _ride_rate) + 4:
			_game.tick({player.player_id: ArenaBots.think(_game, player, mind, tick, float(_ride_rate))})
			tick += 1
			ticks += 1
			if ticks % 32 == 0:
				await get_tree().physics_frame
		var st := player.controller.state
		# A few ticks standing on the far platform, which is where a recorded ride ends.
		for _s in range(8):
			_game.tick({player.player_id: ArenaBots.think(_game, player, ArenaBots.Mind.new(), tick, float(_ride_rate))})
			tick += 1
		# `-- --ride-notes` says where each ride ended, for working on an edge that does not land.
		var nav: Variant = _game.surf_rides.get("nav") if _game.surf_rides != null else null
		if nav != null and OS.get_cmdline_user_args().has("--ride-notes"):
			var island: int = nav.island_at(st.position, 0.6)
			print("  ride %d: landed/fell/timed out %d/%d/%d after %d ticks, at %s on island %d (edge %d lands on %d)" % [k,
				surf.landed - outcome[0], surf.fell - outcome[1], surf.timed_out - outcome[2], ticks, str(st.position.round()),
				int(_game.surf_rides.call(&"canonical", island)), edge.id, int(_game.surf_rides.call(&"canonical", edge.course.landing_island))])
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
## What six bots must do in that time, as bands: the floors sit well under what one run
## measured (30 to 47 kills, 1,700 to 6,800 m walked, 1 to 6 platforms, 4 to 16 rides), to
## catch bots that stand still, never meet, or never ride.
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


## Loads [param map_id], waits for its mesh, checks its planned edges are linked and that a route crosses
## the first, then rides that edge from [param starts] starts, [param need] of which must land. Returns
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
	rng.seed = _rotation_seed
	# Ridden at the rate the cache was planned at ([constant RIDE_CACHE_RATE]), as the recorded ride and
	# `--measure` are, not at the suite's 64 Hz (on 10x's edge 1 that cost little: 6 of 51 starts landed
	# at 64 Hz, 10 of 76 at 66; the plan's own rate is what limits it).
	var suite_rate := _game.tick_rate
	_game.set_tick_rate(RIDE_CACHE_RATE)
	var rate := float(RIDE_CACHE_RATE)
	# A long, chaotic ride lands one start in four to eight, so a bare 'need of starts' fails on chance
	# alone: while short of the bar, spend up to [constant RIDE_START_BUDGET] times the starts before judging.
	var k := -1
	while k + 1 < starts or (landed < need and k + 1 < starts * RIDE_START_BUDGET):
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
		mind.ride = DotBotSurfRide.new().begin(edge.cache, edge.course, surf._sim_for(edge, bot.controller), tick, rate)
		var before := surf.landed
		var ticks := 0
		while mind.ride != null and ticks < int(ArenaSurf.RIDE_SECONDS * rate) + 4:
			_game.tick({id: ArenaBots.think(_game, bot, mind, tick, rate)})
			tick += 1
			ticks += 1
			if ticks % 32 == 0:
				await get_tree().physics_frame
		var feet := bot.controller.state.position
		var made_it := surf.landed > before and surf.nav.on_island(edge.course.landing_island, feet, 0.6)
		landed += 1 if made_it else 0
		alive += 1 if made_it and bot.is_alive() else 0
		notes.append("%s %.2f s at %s" % ["landed" if made_it else "missed", float(ticks) / rate, str(feet.round())])
	_game.set_tick_rate(suite_rate)
	_line("     edge %d, %.0f m: %s" % [edge.id, edge.from.distance_to(edge.to), "; ".join(notes)])
	_check(landed >= need and alive == landed,
		"a bot rides it to the platform below and lands alive (%d of %d, %d needed)" % [landed, k + 1, need])
	return {"surf": surf, "edge": edge, "tick": tick}


## How far from a fall-out destination a faller must get to count as out, in metres: the
## ski_2 cell is about 12 m across, and the ground past its door is open for far more.
const FALLOUT_OUT_AT := 12.0
## Seconds spent walking each of eight headings from a destination.
const FALLOUT_WALK := 4.0
## Destinations tried per map, biggest volume first: the catch-all under the map is the one
## everybody reaches, and a second is the jail or pit someone is sent to on purpose.
const FALLOUT_PER_MAP := 2
