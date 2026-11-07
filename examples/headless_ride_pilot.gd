extends "imported_base.gd"

const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaBots := preload("../game/arena_bots.gd")
const ArenaSurf := preload("../game/arena_surf.gd")
const ArenaSurfRides := preload("../game/arena_surf_rides.gd")

## The harvest replays a recorded ride with the bot's pilot (tracking and veto), judged on the edge's own course. A ride is made
## synthetically by driving the planned cache down one edge of a shipped map and keeping the commands, as a recording would;
## `-- --cost` prints the replay's price per tick against the harvest's slice budget. [codeblock] godot --headless --path .

const TICK_RATE := 64
const RIDE_MAP := &"surf_ski_2"
## An edge that lands from the lip at rest (same as headless_imported's RECORD_EDGE).
const EDGE := 6
const SECTIONS := 1
const CHECKS := 12

var _edge: ArenaSurf.Edge = null
var _surf: ArenaSurf = null
var _rides: RefCounted = null
var _store := DotBotDemoStoreMemory.new()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	if ArenaMap.imported_ids().is_empty() or ArenaMap.by_id(RIDE_MAP) == null:
		print("no imported maps - nothing to check")
		get_tree().quit(0)
		return
	ArenaMap.use_worlds = false
	_section("a recorded ride is replayed with the pilot, on the edge's course")
	_game = ArenaGame.new()
	_game.tick_rate = TICK_RATE
	_game.headless = true
	_game.is_authority = true
	_game.register_service = false
	_game.mode = ArenaMode.free_for_all(4)
	add_child(_game)
	var setup := _game.setup(ArenaMap.by_id(RIDE_MAP))
	var _added := _game.add_player(1, "a")
	var world := ArenaBots.world_for(_game)
	var _first := world.route(Vector3.ZERO, Vector3.ONE)
	var frames := 0
	while world.is_route_pending() and frames < 1200:
		await get_tree().process_frame
		frames += 1
	_surf = world.surf_for_map() if setup.ok else null
	var planned: Array = _surf.edges.filter(func(e: ArenaSurf.Edge) -> bool: return e.linked and e.id == EDGE) if _surf != null else []
	if planned.is_empty():
		_check(false, "%s has linked ride edge %d" % [RIDE_MAP, EDGE])
		_done()
		_finish()
		return
	_edge = planned[0]
	await _test_pilot()
	_done()
	_finish()


func _test_pilot() -> void:
	var cfg := DotBotDemoConfig.new()
	cfg.store = "memory"
	cfg.record = false
	_rides = ArenaSurfRides.new()
	var ready: DotResult = _rides.call(&"setup", _game, cfg, _store, float(TICK_RATE))
	_rides.set_map(_game.map, ArenaBots.world_for(_game).nav_for_rides())
	await _rides.attach_surf(_surf)
	var key: String = _rides.edge_key(_edge)
	var player := _game.player_for(1)
	_check(ready.ok and _rides.ride_config.piloted and _rides.has_method(&"pilot_setup"), "the host has pilot_setup and the harvest is piloted by default")

	var full := _synthetic_ride(player, key, 1, false)
	var slow := _synthetic_ride(player, key, 4, false)
	var coast := _synthetic_ride(player, key, 1, true)
	_check(full != null and slow != null and coast != null, "a synthetic ride lands from the lip on the real motor (%d samples, %d at 16 Hz)" % [
		full.sample_count() if full != null else 0, slow.sample_count() if slow != null else 0])
	if full == null or slow == null or coast == null:
		return

	var pilot := DotBotSurfPilot.new()
	_rides.pilot_setup(pilot, full)
	_check(is_equal_approx(pilot.reference_yaw, _edge.course.start_yaw) and pilot.score.is_valid(),
		"pilot_setup gives the edge course's reference yaw (%.1f) and score" % pilot.reference_yaw)
	_check(_rides.course_for_key(key) == _edge.course, "and a recording is judged on the course the bot rides the edge on")

	# The planned ride was flown without tracking (its pilot's own way), so that is how it is replayed here; see _variants for the others.
	_rides.ride_config.pilot_tracking = false
	var harvest: DotBotRideHarvest = _rides.harvest_on(player.controller)
	_check(harvest.is_piloted(), "the harvest rides a recording with the pilot")
	_variants(harvest, full, 1)
	_variants(harvest, slow, 4)
	var verdicts := harvest.verify([full])
	_check(verdicts[0]["ok"] and harvest.piloted_replays == harvest.replays,
		"a ride at every tick lands piloted on the starts too (score %s, %d piloted replays)" % [verdicts[0]["score"], harvest.piloted_replays])

	var open_cfg := DotBotRideConfig.new()
	open_cfg.piloted = false
	var open: DotBotRideHarvest = DotBotRideHarvest.new(open_cfg, _rides.schema, harvest.sim, _rides)
	var open_coast := open.verify([coast])
	var piloted_coast := harvest.verify([coast])
	_check(open.piloted_replays == 0 and not open_coast[0]["ok"], "with piloted off the commands replay open loop, and a ride of coasting is rejected")
	print("        piloted: the coasting ride is %s, the 16 Hz ride %s" % ["kept" if piloted_coast[0]["ok"] else "rejected", "kept" if harvest.verify([slow])[0]["ok"] else "rejected"])

	# Through the store, as the server does: verified, filed with the edge's pilot cache.
	var appended: DotResult = await _store.append([full, coast])
	var done: DotResult = await harvest.harvest(_store, _rides.recorder.map_id, _rides.recorder.map_version, ArenaSurfRides.KIND, key)
	_check(appended.ok and done.ok and int(done.value) == 1, "of two stored rides one is verified and the coasting one is not")
	var loaded: DotResult = await _rides.book.load_edge(_store, ArenaSurfRides.KIND, key, _rides.schema, float(TICK_RATE), _rides.reference_yaw_for(key))
	var recorded: Array = _rides.book.ranked(key).filter(func(r: Dictionary) -> bool: return r["source"] == DotBotRideBook.RECORDED)
	var data: Dictionary = recorded[0]["data"] if not recorded.is_empty() else {}
	_check(loaded.ok and recorded.size() == 1 and data.has("cache") and is_equal_approx(float(data.get("reference_yaw", NAN)), _edge.course.start_yaw),
		"the book holds it with the pilot cache and the edge's yaw (%d recorded)" % recorded.size())

	var rode := _bot_rides(player, recorded[0] if not recorded.is_empty() else {})
	print("  note  a bot riding the recording (begin_picked turns tracking on) ends with status %d (1 landed, 2 fell)" % rode)
	_check(rode != DotBotSurfRide.RIDING, "a bot rides the recorded cache to an end")

	await _cost(player, [full], false)
	await _cost(player, [full], true)


## The commands of the planned cache riding [param player]'s edge, kept every [param hold]th tick; [param coast] keeps no key at all. Null if it does not land.
func _synthetic_ride(player: ArenaPlayer, key: String, hold: int, coast: bool, tracking: bool = false) -> DotBotDemoEpisode:
	var sim := _surf._sim_for(_edge, player.controller)
	player.controller.teleport(_edge.from, _edge.course.start_yaw, 0.0)
	var s: DotFpsState = player.controller.state.duplicate_state()
	var ep := DotBotDemoEpisode.new()
	ep.id = 1 + hold + (100 if coast else 0) + (0 if tracking else 1000)
	ep.map_id = _rides.recorder.map_id
	ep.map_version = _rides.recorder.map_version
	ep.schema_id = _rides.schema.schema_id()
	ep.kind = ArenaSurfRides.KIND
	ep.key = key
	ep.start = ArenaSurfRides.encode_state(s)
	ep.rate = float(TICK_RATE) / hold
	ep.frame_size = _rides.schema.frame_size()
	ep.outcome = "landed"
	var rider := DotBotSurfPilot.new().share_cache(_edge.cache)
	rider.horizon = _edge.cache.horizon
	rider.sim = sim
	rider.tracking = tracking
	rider.score = _edge.course.score
	rider.reset()
	var rows := PackedFloat32Array()
	for t in int(ArenaSurf.RIDE_SECONDS * TICK_RATE):
		var cmd: DotFpsCommand = rider.command(s)
		if t % hold == 0:
			var yaw := cmd.yaw if not coast else _edge.course.start_yaw
			var move := cmd.move if not coast else Vector2.ZERO
			var jump := cmd.is_pressed(DotFpsCommand.BUTTON_JUMP) and not coast
			rows.append_array(PackedFloat32Array([s.position.x, s.position.y, s.position.z, s.velocity.x, s.velocity.y, s.velocity.z,
				yaw, move.x, move.y, 1.0 if jump else 0.0]))
		if sim.step(s, cmd) == DotBotSurfCourse.EVENT_GOAL:
			ep.ticks = rows
			return ep
	return null


## Steers a bot down [param entry] on the edge's simulator from the lip; returns the ride's status.
func _bot_rides(player: ArenaPlayer, entry: Dictionary) -> int:
	var sim := _surf._sim_for(_edge, player.controller)
	player.controller.teleport(_edge.from, _edge.course.start_yaw, 0.0)
	var s: DotFpsState = player.controller.state.duplicate_state()
	var ride := DotBotSurfRide.new().begin_picked(entry, _edge.cache, _edge.course, sim, 0, _rides.decode, float(TICK_RATE))
	var intent := DotBotIntent.new()
	intent.yaw = _edge.course.start_yaw
	for t in int(ArenaSurf.RIDE_SECONDS * TICK_RATE):
		var status := ride.steer(s, intent, t)
		if status != DotBotSurfRide.RIDING:
			return status
		var cmd: DotFpsCommand = sim.command(intent.yaw, intent.move, intent.jump)
		var _event := sim.step(s, cmd)
	return DotBotSurfRide.TIMED_OUT


## What a replay costs per tick and per harvest slice against the slice budget (printed; the checks are only that it runs).
func _cost(player: ArenaPlayer, episodes: Array, tracking: bool) -> void:
	_rides.ride_config.pilot_tracking = tracking
	var harvest: DotBotRideHarvest = _rides.harvest_on(player.controller)
	var budget_us: float = harvest.config.budget_msec * 1000.0
	var worst := 0.0
	var ticks := 0
	var usec := 0
	var steps_before: int = harvest.sim.steps
	var reps := 5
	for _r in reps:
		for ep: DotBotDemoEpisode in episodes:
			var state: Variant = _rides.replay_start(ep)
			var hold := maxi(1, roundi(float(TICK_RATE) / ep.rate))
			var began := Time.get_ticks_usec()
			var result := harvest.replay_piloted(ep, state)
			var took := float(Time.get_ticks_usec() - began)
			worst = maxf(worst, took)
			usec += int(took)
			# The replay stops when it lands.
			ticks += ep.sample_count() * hold
			_check_cost_result(result)
	var steps: int = harvest.sim.steps - steps_before
	print("  cost  piloted replay, tracking %s: %.1f us a recorded tick (%d replays, %d ticks), %.1f simulator steps a tick; one replay at most %.2f ms, slice budget %.1f ms" % [
		str(tracking), float(usec) / maxf(1.0, ticks), reps * episodes.size(), ticks, float(steps) / maxf(1.0, ticks), worst / 1000.0, budget_us / 1000.0])
	if tracking:
		_check(worst > 0.0, "the tracking replay cost was measured")
		return
	var open_cfg := DotBotRideConfig.new()
	open_cfg.piloted = false
	var open := DotBotRideHarvest.new(open_cfg, _rides.schema, harvest.sim, _rides)
	var open_usec := 0
	var open_ticks := 0
	for _r in reps:
		var ep: DotBotDemoEpisode = episodes[0]
		var state: Variant = _rides.replay_start(ep)
		var began := Time.get_ticks_usec()
		var _result := open.replay_open(ep, state)
		open_usec += Time.get_ticks_usec() - began
		open_ticks += ep.sample_count()
	print("  cost  open loop replay: %.1f us a tick" % (float(open_usec) / maxf(1.0, open_ticks)))
	_check(worst > 0.0, "the replay cost was measured")


func _check_cost_result(result: int) -> void:
	if result != DotBotRideHarvest.LANDED:
		print("  note  a cost replay did not land (%d)" % result)


func _finish() -> void:
	if _game != null:
		remove_child(_game)
		_game.free()
		_game = null
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _variants(harvest: DotBotRideHarvest, ep: DotBotDemoEpisode, hold: int) -> void:
	for tracking in [true, false]:
		for horizon in [192, 0]:
			var pilot := DotBotRideQuantiser.pilot_for(ep, _rides.schema, harvest.sim, Callable(_rides, &"pilot_setup"), tracking, horizon, hold)
			pilot.reset()
			var s: DotFpsState = _rides.replay_start(ep)
			var out := "running"
			for t in ep.sample_count() * hold + 96:
				var event: int = harvest.sim.step(s, pilot.command(s))
				var v: int = _rides.landing(s, event, ep)
				if v != 0 or event != 0:
					out = "t=%d verdict %d event %d" % [t, v, event]
					break
			print("  note  hold %d tracking %s horizon %d: %s" % [hold, tracking, horizon, out])
