extends Node

const ArenaGame := preload("../game/arena_game.gd")


const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaSurf := preload("../game/arena_surf.gd")
const ArenaBots := preload("../game/arena_bots.gd")
const ArenaContent := preload("../game/arena_content.gd")


## The rate rides are planned and measured at: the game's default, which a listen server and the
## suites' recorded rides play at. The caches planned before ArenaGame.add_player applied the game's
## rate were stepped at this one too (the controller's default), whatever their stamp said.
const TICK_RATE := ArenaContent.TICK_RATE


## A perturbed start: up to this far sideways and along, metres, and moving at up to the
## arena's run speed in a direction up to this far off the ride's (degrees).
const SIDE := 1.0
const ALONG := 0.7
const TURN := 100.0


var game: ArenaGame = null
var bot: ArenaPlayer = null
var nav: DotBotNav = null
var map_id: StringName = &""


func measure(data: Dictionary, runs: int, live: int) -> void:
	var edges: Array = data.get("edges", [])
	for i in range(edges.size()):
		var row: Dictionary = edges[i]
		if (row.get("entries", []) as Array).is_empty():
			print("[surf] edge %d: not planned" % i)
			continue
		var from := _metres(row["from"])
		var to := _metres(row["to"])
		var course := ArenaSurf.course_for(game.map, nav, from, to, float(row.get("reference_yaw", NAN)))
		var sim := _simulator(course.event_at)
		var pilot := DotBotSurfPilot.new()
		pilot.load_stage(row, ArenaSurf.UNITS)
		pilot.sim = sim
		pilot.score = course.score
		var rng := RandomNumberGenerator.new()
		rng.seed = 5000 + i
		var ok := 0
		var ridden := 0
		var lookahead_before := pilot.lookahead_ticks
		var veto_before := pilot.veto_ticks
		var usec_before := sim.usec
		var steps_before := sim.steps
		var ride_sim := _simulator(course.event_at)
		for r in range(runs):
			var res := pilot.ride(perturbed(from, course.reference_yaw(), rng), ride_sim, int(ArenaSurf.RIDE_SECONDS * TICK_RATE))
			ridden += int(res["ticks"])
			if int(res["event"]) == DotBotSurfCourse.EVENT_GOAL:
				ok += 1
		print("[surf] edge %d (%d entries): simulated %d of %d land (%.0f%%); lookahead %.2f and vetoes %.2f motor ticks a ridden tick, %.0f us of motor a ridden tick" % [
			i, pilot.size(), ok, runs, 100.0 * ok / maxf(1.0, runs),
			float(pilot.lookahead_ticks - lookahead_before) / maxf(1.0, ridden), float(pilot.veto_ticks - veto_before) / maxf(1.0, ridden),
			float(sim.usec - usec_before) / maxf(1.0, ridden)])
		if live > 0:
			await _ride_live(i, row, course, live)


## Rides edge [param index] [param count] times in the game: the arena's own tick, its teleports,
## its pushes, with the view held on the map's middle while the legs surf. Times the steering
## (lookup, forecast and veto) and the bot's whole command.
func _ride_live(index: int, row: Dictionary, course: DotBotSurfCourse, count: int) -> void:
	var surf := ArenaSurf.new()
	surf.map = game.map
	surf.nav = nav
	var edge := ArenaSurf.Edge.new()
	edge.id = 0
	edge.from = course.start
	edge.to = course.goal_centre
	edge.course = course
	edge.cache = DotBotSurfPilot.new()
	edge.cache.load_stage(row, ArenaSurf.UNITS)
	edge.linked = true
	surf.edges.append(edge)
	var rng := RandomNumberGenerator.new()
	rng.seed = 9000 + index
	var aim_at := game.map.bounds.get_center()
	var landed := 0
	var failures: Array[String] = []
	var times: Array[float] = []
	var use_think := OS.get_cmdline_user_args().has("--think")
	var surf_world: ArenaSurf = null
	if use_think:
		var w := ArenaBots.world_for(game)
		var _r := w.route(Vector3.ZERO, Vector3.ONE)
		while w.is_route_pending():
			await get_tree().process_frame
		surf_world = w.surf_for_map()
	var mind := RideMind.new()
	var last_ride: Array = [null]
	var tick := 0
	for r in range(count):
		if not bot.is_alive():
			game.respawn_player(1)
		var s := perturbed(course.start, course.reference_yaw(), rng)
		bot.controller.teleport(s.position, course.reference_yaw(), 0.0)
		bot.controller.state.velocity = s.velocity
		mind.ride = null
		var first := true
		var ticks := 0
		var outcome := -1
		var think_mind: ArenaBots.Mind = null
		if use_think:
			think_mind = ArenaBots.Mind.new()
			think_mind.seed = 77 + r
			think_mind.ride = DotBotSurfRide.new().begin(surf_world.edges[index].cache, surf_world.edges[index].course, surf_world._sim_for(surf_world.edges[index], bot.controller), tick, float(TICK_RATE))
		while use_think and ticks < int(ArenaSurf.RIDE_SECONDS * TICK_RATE) + 2:
			var landed_before := surf_world.landed
			game.tick({1: ArenaBots.think(game, bot, think_mind, tick, float(TICK_RATE))})
			tick += 1
			ticks += 1
			if ticks % 32 == 0:
				await get_tree().physics_frame
			if think_mind.ride == null:
				outcome = 1 if surf_world.landed > landed_before else 0
				break
		while not use_think and ticks < int(ArenaSurf.RIDE_SECONDS * TICK_RATE) + 2:
			var intent := DotBotIntent.new()
			var eye := bot.controller.state.position + Vector3.UP * 1.6
			var look := DotBotAim.angles_to(eye, aim_at)
			intent.yaw = look.x
			intent.pitch = look.y
			intent.ride = 0 if first else -1
			first = false
			var landed_before := surf.landed
			var fell_before := surf.fell + surf.timed_out
			surf.steer(bot, mind, intent, tick, float(TICK_RATE))
			if mind.ride != null:
				last_ride[0] = mind.ride
			if surf.landed > landed_before:
				outcome = 1
				break
			if surf.fell + surf.timed_out > fell_before:
				outcome = 0
				break
			var move := DotFpsCommand.new()
			intent.write_move(move)
			var fire := DotWeaponCommand.new()
			intent.write_fire(fire)
			game.tick({1: [move, fire]})
			tick += 1
			ticks += 1
			if ticks % 32 == 0:
				await get_tree().physics_frame
		if r < 3:
			var ride_now: DotBotSurfRide = mind.ride if mind.ride != null else last_ride[0]
			if ride_now != null:
				print("[surf]   ride %d: %s" % [r, str(ride_now.pilot.describe())])
		if outcome == 1:
			landed += 1
			times.append(float(ticks) / TICK_RATE)
		else:
			failures.append("ride %d at %s" % [r, str(bot.controller.state.position.round())])
			if failures.size() == 1:
				var st := bot.controller.state
				print("[surf]   first miss: landing %s, under it island %d, grounded %s, course says %d, outcome %d after %d ticks" % [
					str((course as ArenaSurf.EdgeCourse).landing_islands), nav.island_at(st.position, 2.0), st.is_grounded(), course.event_at(st), outcome, ticks])
	var d := surf.describe()
	print("[surf] edge %d live: %d of %d land (%.0f%%), %s; steering %.0f us a riding tick (%.1f%% of a core per riding bot at %d Hz)%s" % [
		index, landed, count, 100.0 * landed / maxf(1.0, count), _spread(times), float(d["steer_us_per_tick"]),
		float(d["steer_us_per_tick"]) * TICK_RATE / 10000.0, TICK_RATE,
		"" if failures.is_empty() else "; missed: " + ", ".join(failures)])


## What [method ArenaSurf.steer] keeps on a bot.
class RideMind:
	extends RefCounted
	var ride: Variant = null
	var brain: DotBotBrain = null


## A simulator of the bot's own movement over the map's brushes, [param oracle] its course.
func _simulator(oracle: Callable) -> DotFpsSimulator:
	var body := game.map.movement_body()
	bot.controller.body.copy_filters_to(body)
	var sim := bot.controller.simulator(body)
	sim.oracle = oracle
	if game.map.mechanics != null:
		var mechanics := game.map.mechanics
		sim.mechanics = func(state: DotFpsState, motor: DotFpsMotor, delta: float, start: Vector3) -> int:
			mechanics.simulate(motor, state, start, delta)
			return DotFpsSimulator.EVENT_NONE
	return sim


## A state standing at [param at], facing [param yaw], at rest.
func _standing_at(at: Vector3, yaw: float) -> DotFpsState:
	bot.controller.teleport(at, yaw, 0.0)
	var s := bot.controller.state.duplicate_state()
	s.velocity = Vector3.ZERO
	return s


## [param at] moved up to [constant SIDE] sideways and [constant ALONG] along, running at up to
## the arena's speed within [constant TURN] degrees of [param yaw]: how a bot whose route reached
## the edge arrives at it.
func perturbed(at: Vector3, yaw: float, rng: RandomNumberGenerator) -> DotFpsState:
	var forward := DotFpsMotor.forward_for(yaw)
	var side := Vector3(-forward.z, 0.0, forward.x)
	var p := at + side * rng.randf_range(-SIDE, SIDE) + forward * rng.randf_range(-ALONG, ALONG)
	var s := _standing_at(p, yaw)
	var heading := yaw + rng.randf_range(-TURN, TURN)
	s.velocity = DotFpsMotor.forward_for(heading) * rng.randf_range(0.0, bot.controller.tunables.max_speed)
	return s


static func _units(v: Vector3) -> Array:
	var u := v / ArenaSurf.UNITS
	return [snappedf(u.x, 0.1), snappedf(u.y, 0.1), snappedf(u.z, 0.1)]


static func _metres(row: Array) -> Vector3:
	return Vector3(float(row[0]), float(row[1]), float(row[2])) * ArenaSurf.UNITS


func _write(path: String, data: Dictionary) -> void:
	data["id"] = String(map_id)
	data["units"] = ArenaSurf.UNITS
	data["bake"] = ArenaSurf.bake_id(nav)
	data["note"] = "Written by tools/surf_rides.gd: a combat surf map's ride edges (platform to platform, in genre units, Godot axes) and, per edge, every tick of every ride the planner found on the real motor as [x, y, z, vx, vy, vz, action]. Replan after a movement or collision change."
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "", false))
	f.close()
	print("[surf] wrote %s" % path)


static func _read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


static func _spread(times: Array) -> String:
	if times.is_empty():
		return "no times"
	var sorted := times.duplicate()
	sorted.sort()
	return "%.2f s best, %.2f s median" % [sorted[0], sorted[sorted.size() / 2]]


static func _opt(args: PackedStringArray, flag: String, fallback: int) -> int:
	var i := args.find(flag)
	return int(args[i + 1]) if i >= 0 and i + 1 < args.size() else fallback
