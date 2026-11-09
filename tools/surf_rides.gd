extends "surf_rides_measure.gd"

const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaSurfRides := preload("../game/arena_surf_rides.gd")

## Finds a combat surf map's ride edges, plans each on the real motor, and measures the bot that
## rides them. Writes `maps/surf/<id>.surf.json`, which `arena_surf.gd` links into the bots' mesh.
##
##     godot --headless --path . tools/surf_rides.tscn -- surf_10x_reloaded_fixed --explore
##     godot --headless --path . tools/surf_rides.tscn -- surf_10x_reloaded_fixed --plan 0 --starts 6 --repairs 32 --rounds 3
##
## [b]--explore[/b] bakes the bots' mesh as the game does and, from every platform that holds a spawn
## or a teleport's landing, searches (dot-bot's [DotBotSurfPlanner]) for a ride that ends standing on
## another platform at least [constant MIN_RIDE_METRES] away (not a teleport's floor, lowest first).
## Each one found is an edge, and its landing is explored in turn (`--platforms N` caps how many).
## Edges are rewritten as each is found, so a run its timeout cuts short keeps what it found.
##
## [b]--plan i,j[/b] plans those edges (all, without a list): a ride searched from each of
## `--starts` starts perturbed round the edge's start (the first exactly there, standing), then
## `--rounds` rounds of repair from `--repairs` more. About twenty minutes an edge on one core:
## run one at a time.
##
## [b]--measure[/b] rides every planned edge `--runs` times on the simulator and `--live` times in the game, from perturbed starts with the view held on a fixed point (a bot that fights
## while it rides), and prints how many land and what steering a ride costs.
##
## [b]--demos[/b] lists what the recorder's store holds for the map, per edge. [b]--harvest[/b] replays
## every stored ride on the real motor (as the bot's pilot rides it: tracking and veto), keeps the ones that land, ranks them with the planned ones, and writes the planned
## cache with the verified recordings added to `maps/surf/<id>.merged.surf.json` (`--out FILE` for another path), which is never loaded by itself: review it, then copy it over the cache.
##
## For a map that finds nothing: `--probe`, `--section`, `--hold`, `--search`, `--wander`, `--islands` and `--picture` (read the code for arguments).
## `--measure --think` drives the live rides through `ArenaBots.think`. Everything is seeded, so two runs print the same numbers.


## Platforms smaller than this are not worth a ride (a ramp's walkable seam), m².
const MIN_ISLAND_AREA := 12.0
## A landing's least area (m²) and farthest distance (m); landings tried per platform; edges per map.
const LANDING_AREA := 40.0
const MAX_RIDE_METRES := 450.0
## Closer than this is a step off the platform, not a ride.
const MIN_RIDE_METRES := 40.0
const TARGETS_PER_PLATFORM := 12
const MAX_EDGES := 8
## Platforms explored from, at most (`--platforms`).
const MAX_PLATFORMS := 12


## A course for exploring: arriving is standing on any platform but the start's.
class ExploreCourse:
	extends DotBotSurfCourse
	var nav: DotBotNav = null
	var targets: PackedInt32Array = PackedInt32Array()
	var pit_boxes: Array[AABB] = []
	## Progress toward the goal (true), or distance from the start (false).
	var directed: bool = false

	func event_at(state: Variant) -> int:
		var p: Vector3 = state.position
		if p.y < floor_y:
			return EVENT_BELOW
		for box in pit_boxes:
			if box.has_point(p):
				return EVENT_PIT
		if state.is_grounded():
			for t in targets:
				if nav.on_island(t, p, 0.5):
					return EVENT_GOAL
		return EVENT_NONE

	## Distance from the start, flat: there is no goal to measure progress toward.
	func progress(p: Vector3) -> float:
		if directed:
			return super(p)
		return Vector2(p.x - start.x, p.z - start.z).length()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	map_id = StringName(args[0] if args.size() > 0 and not args[0].begins_with("--") else "surf_10x_reloaded_fixed")
	if not await _load():
		get_tree().quit(1)
		return
	var path := ProjectSettings.globalize_path(ArenaSurf.path_for(map_id))
	if args.has("--check") or args.has("--stamp"):
		var cached := _read(path)
		var stale := String(cached.get("bake", "")) != ArenaSurf.bake_id(nav)
		print("[surf] %s: cache %s" % [map_id, "STALE (planned on another bake)" if stale else "matches the bake"])
		print("[surf] %s: bake %s" % [map_id, ArenaSurf.bake_id(nav)])
		if args.has("--stamp"):
			_write(path, cached)
		get_tree().quit(3 if stale and args.has("--check") else 0)
		return
	if args.has("--islands"):
		list_islands()
	if args.has("--landings"):
		list_landings(_read(path))
	var picture_at := args.find("--picture")
	if picture_at >= 0:
		picture(args[picture_at + 1], 1.0)
	if args.has("--probe"):
		probe()
	if args.has("--section"):
		section(args)
	if args.has("--hold"):
		hold(args)
	if args.has("--search"):
		search_from(args, path)
	if args.has("--wander"):
		var found := wander(_opt(args, "--width", 48))
		if args.has("--write"):
			_write(path, {"edges": found})
	if args.has("--explore"):
		var edges := explore(_opt(args, "--platforms", MAX_PLATFORMS), func(found: Array) -> void: _write(path, {"edges": found}))
		_write(path, {"edges": edges})
	var plan_at := args.find("--plan")
	if plan_at >= 0:
		var data := _read(path)
		var wanted := PackedInt32Array()
		if plan_at + 1 < args.size() and not args[plan_at + 1].begins_with("--"):
			for part in args[plan_at + 1].split(","):
				wanted.append(int(part))
		var edges: Array = data.get("edges", [])
		for i in range(edges.size()):
			if not wanted.is_empty() and not wanted.has(i):
				continue
			plan(i, edges[i], _opt(args, "--starts", 6), _opt(args, "--repairs", 32), _opt(args, "--rounds", 3))
			# Saved after every edge: an edge is twenty minutes, and a run cut short keeps them.
			# `--out FILE` writes there instead, so edges planned in parallel processes can be merged (surf_rides_all.py).
			var out_at := args.find("--out")
			_write(ProjectSettings.globalize_path(args[out_at + 1]) if out_at >= 0 else path, data)
	if args.has("--demos") or args.has("--harvest"):
		var merged_at := args.find("--out")
		await demos(args.has("--harvest"), ProjectSettings.globalize_path(args[merged_at + 1]) if merged_at >= 0 else path.replace(".surf.json", ".merged.surf.json"))
	if args.has("--measure"):
		await measure(_read(path), _opt(args, "--runs", 40), _opt(args, "--live", 20))
	get_tree().quit(0)


## The map, in a game, with one bot and the bots' mesh baked the way the game bakes it.
func _load() -> bool:
	game = ArenaGame.new()
	game.tick_rate = TICK_RATE
	game.headless = true
	game.is_authority = true
	game.register_service = false
	game.mode = ArenaMode.free_for_all(1000)
	add_child(game)
	var map := ArenaMap.by_id(map_id)
	if map == null or not map.is_imported():
		print("[surf] %s is not a combat surf map here (is maps/imported linked?)" % map_id)
		return false
	var res := game.setup(map)
	if not res.ok:
		print("[surf] %s did not load: %s" % [map_id, res.error.message])
		return false
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	var added := game.add_player(1, "surfer")
	if not added.ok:
		print("[surf] no player: %s" % added.error.message)
		return false
	game.start(0)
	bot = game.player_for(1)
	await get_tree().physics_frame
	var tunables := bot.controller.tunables
	nav = DotBotNav.new()
	var source := game.map.nav_source()
	var baked := nav.bake(source if source != null else game.map.collision_root, {"radius": tunables.radius, "height": tunables.stand_height, "climb": tunables.step_height})
	if source != null:
		source.free()
	if not baked.ok:
		print("[surf] the mesh did not bake: %s" % baked.error.message)
		return false
	print("[surf] %s: %d polygons, %d islands, %d spawns, %d teleports, %.0f ms to bake" % [
		map_id, nav.mesh.get_polygon_count(), nav.islands().size(), game.map.spawns.size(), game.map.pits.size(), nav.bake_ms])
	return true


# --- Exploring -----------------------------------------------------------------------

## Holds one command from one state for ten seconds and prints the path:
## `--hold x,y,z vx,vy,vz yaw mx,my`. For checking a ramp can be ridden at all.
func hold(args: PackedStringArray) -> void:
	var at := args.find("--hold")
	var p := args[at + 1].split(",")
	var v := args[at + 2].split(",")
	var yaw := float(args[at + 3])
	var m := args[at + 4].split(",")
	var course := ArenaSurf.course_for(game.map, nav, Vector3.ZERO, Vector3.FORWARD)
	var sim := _simulator(course.event_at)
	var s := _standing_at(Vector3(float(p[0]), float(p[1]), float(p[2])), yaw)
	s.velocity = Vector3(float(v[0]), float(v[1]), float(v[2]))
	var event := 0
	var t := 0
	var path: Array[String] = []
	var action := _opt(args, "--action", -1)
	while t < 10 * TICK_RATE and event == 0:
		if action >= 0:
			var c: DotFpsCommand = DotBotSurfPilot.command_for(sim, action, s, yaw)
			if t < 3 or t % 64 == 0:
				print("[surf]   t %d yaw %.1f move %s v %s" % [t, c.yaw, str(c.move), str(s.velocity.snapped(Vector3.ONE * 0.1))])
			event = sim.step(s, c)
		else:
			event = sim.step(s, sim.command(yaw, Vector2(float(m[0]), float(m[1])), false))
		t += 1
		if t % 32 == 0:
			path.append("%s|%.0f" % [str(s.position.round()), s.velocity.length()])
	print("[surf] hold: event %d after %.2f s; %s" % [event, t / float(TICK_RATE), " ".join(path)])


## From every place a teleport puts a player, a search for wherever the map's ramps lead: any
## platform but the one it starts on, scored by distance travelled and energy kept, never by a
## goal of this tool's choosing. A combat surf map's teleports put a player at the top of a
## ramp, so what a search from there lands on is the ride the mapper built.
func wander(width: int) -> Array:
	var islands := nav.islands()
	var bounds := game.map.bounds
	var targets := PackedInt32Array()
	for island: Dictionary in islands:
		var box: AABB = island["bounds"]
		if float(island["area"]) < MIN_ISLAND_AREA or box.position.y > bounds.end.y - 1.0 or box.position.y < bounds.position.y + 1.0:
			continue
		targets.append(int(island["index"]))
	var starts: Dictionary = {}
	for pit: Dictionary in game.map.pits:
		var to: Vector3 = pit["to"]
		var key := Vector3i((to / 4.0).round())
		if not starts.has(key):
			starts[key] = [to, float(pit["yaw"])]
	print("[surf] wandering from %d teleport landings" % starts.size())
	var planner := DotBotSurfPlanner.new()
	planner.seconds = ArenaSurf.RIDE_SECONDS
	planner.width = width
	var edges: Array = []
	for key: Vector3i in starts:
		var to: Vector3 = starts[key][0]
		var yaw: float = starts[key][1]
		var from_island := nav.island_at(to, 3.0)
		var course := ExploreCourse.new()
		course.nav = nav
		course.start = to
		course.gravity = 800.0 * ArenaSurf.UNITS
		course.floor_y = bounds.position.y - ArenaSurf.FALL_OUT_DEPTH
		course.progress_weight = 0.3
		course.unsupported_fn = ArenaSurf.unsupported_test(game.map)
		course.unsupported_penalty = ArenaSurf.UNSUPPORTED_PENALTY
		for pit: Dictionary in game.map.pits:
			course.pit_boxes.append(pit["box"])
		for t in targets:
			if t != from_island:
				course.targets.append(t)
		course.goal_centre = to + DotFpsMotor.forward_for(yaw) * 10.0
		var _settled := course.settle()
		var sim := _simulator(course.event_at)
		var start := _standing_at(to, yaw)
		var t0 := Time.get_ticks_msec()
		var found := planner.search(start, course, sim)
		if not bool(found["found"]):
			print("[surf]   from %s (island %d): nothing (%s), %.1f s" % [str(to.round()), from_island, found["why"], (Time.get_ticks_msec() - t0) / 1000.0])
			continue
		var landing := _replay_end(start, found["actions"], course, sim)
		var to_island := nav.island_at(landing, 1.0)
		var seconds := float(found["ticks"]) / float(TICK_RATE)
		print("[surf]   from %s (island %d): lands on island %d at %s after %.2f s, %.0f m away, %.1f s searching" % [
			str(to.round()), from_island, to_island, str(landing.round()), seconds, to.distance_to(landing), (Time.get_ticks_msec() - t0) / 1000.0])
		if to_island >= 0 and from_island >= 0 and seconds > 1.0:
			edges.append({"from": _units(nav.closest(to)), "to": _units(nav.closest(landing)), "from_island": from_island, "to_island": to_island,
				"explored_seconds": snappedf(seconds, 0.01), "veto": true})
	return edges


## One search from a given state toward one island: `--search x,y,z vx,vy,vz island`.
func search_from(args: PackedStringArray, path: String) -> void:
	var at := args.find("--search")
	var p := args[at + 1].split(",")
	var v := args[at + 2].split(",")
	var all_targets := args[at + 3].split(",")
	var target := int(all_targets[0])
	var course := ExploreCourse.new()
	course.nav = nav
	course.start = Vector3(float(p[0]), float(p[1]), float(p[2]))
	course.directed = true
	course.gravity = 800.0 * ArenaSurf.UNITS
	course.floor_y = game.map.bounds.position.y - ArenaSurf.FALL_OUT_DEPTH
	for pit: Dictionary in game.map.pits:
		course.pit_boxes.append(pit["box"])
	for t in all_targets:
		course.targets.append(int(t))
	course.unsupported_fn = ArenaSurf.unsupported_test(game.map)
	course.toward_goal = true
	course.unsupported_penalty = ArenaSurf.UNSUPPORTED_PENALTY
	course.goal_centre = nav.closest((nav.islands()[target] as Dictionary)["centre"])
	var pw := args.find("--progress")
	if pw >= 0:
		course.progress_weight = float(args[pw + 1])
	var g := args.find("--guide")
	if g >= 0:
		course.guide.append(course.start)
		for part in args[g + 1].split(";"):
			var xyz := part.split(",")
			course.guide.append(Vector3(float(xyz[0]), float(xyz[1]), float(xyz[2])))
	var _settled := course.settle()
	var sim := _simulator(course.event_at)
	var s := _standing_at(course.start, course.reference_yaw())
	s.velocity = Vector3(float(v[0]), float(v[1]), float(v[2]))
	var planner := DotBotSurfPlanner.new()
	planner.seconds = ArenaSurf.RIDE_SECONDS
	planner.width = _opt(args, "--width", planner.width)
	planner.seconds = float(_opt(args, "--seconds", int(planner.seconds)))
	var began := Time.get_ticks_msec()
	if args.has("--trace"):
		planner.trace = func(depth: int, best: Dictionary) -> void:
			if depth % 4 == 0:
				var st: DotFpsState = best["state"]
				print("[surf]   %.1f s best %s v %s score %.1f%s" % [(depth + 1) * planner.hold / float(TICK_RATE), str(st.position.round()), str(st.velocity.round()), float(best["score"]), " unsupported" if course.unsupported_fn.call(st) else ""])
	var found := planner.search(s, course, sim)
	print("[surf] search to %d: %s %s, %d ticks, %.1f s, %d motor ticks (%.0f us each)" % [target, found["found"], found["why"], found["ticks"],
		(Time.get_ticks_msec() - began) / 1000.0, sim.steps, sim.tick_usec()])
	if bool(found["found"]):
		var ride := DotBotSurfPlanner.trajectory(s, found["actions"], planner.hold, course, sim)
		var e: PackedFloat32Array = ride["entries"]
		var points: Array[String] = []
		for i in range(0, e.size() / 7, 32):
			points.append(str(Vector3(e[i * 7], e[i * 7 + 1], e[i * 7 + 2]).round()))
		print("[surf]   %s" % " ".join(points))
		# `--add`: keep the ride as a new edge of the file (to plan with `--plan i`), for a platform
		# `--explore` never reached.
		if args.has("--add"):
			var landing := _replay_end(s, found["actions"], course, sim)
			var landed := nav.island_at(landing, 1.5)
			var data := _read(path)
			var edges: Array = data.get("edges", [])
			edges.append({"from": _units(course.start), "to": _units(nav.closest(landing)), "from_island": nav.island_at(course.start, 2.5),
				"to_island": landed if landed >= 0 else target, "explored_seconds": snappedf(float(found["ticks"]) / float(TICK_RATE), 0.01), "veto": true})
			data["edges"] = edges
			_write(path, data)
			print("[surf]   added as edge %d" % (edges.size() - 1))


## Prints the solid under a line of points: `--section x0,z0 x1,z1 [step]`, each sample as
## height and slope of what a ray straight down meets. For reading a ramp's shape.
func section(args: PackedStringArray) -> void:
	var at := args.find("--section")
	var a := args[at + 1].split(",")
	var b := args[at + 2].split(",")
	var p0 := Vector2(float(a[0]), float(a[1]))
	var p1 := Vector2(float(b[0]), float(b[1]))
	var space := game.map.collision_root.get_world_3d().direct_space_state
	var n := 40
	for i in range(n + 1):
		var p := p0.lerp(p1, float(i) / n)
		var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, 75.0, p.y), Vector3(p.x, -100.0, p.y))
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			print("[surf] %s: nothing" % str(p.round()))
		else:
			var nrm: Vector3 = hit["normal"]
			print("[surf] %s: y %.1f slope %.0f normal %s" % [str(p.round()), hit["position"].y, rad_to_deg(acos(clampf(nrm.y, -1, 1))), str(nrm.snapped(Vector3.ONE * 0.01))])


## Prints every platform of the mesh worth standing on, the spawns on each, and every teleport
## (its box and where it puts a player): the map as the search sees it.
func list_islands() -> void:
	var spawns_on: Dictionary = {}
	for spawn: Transform3D in game.map.spawns:
		var i := nav.island_at(spawn.origin, 2.0)
		spawns_on[i] = int(spawns_on.get(i, 0)) + 1
	for island: Dictionary in nav.islands():
		if float(island["area"]) < MIN_ISLAND_AREA:
			continue
		var box: AABB = island["bounds"]
		print("[surf] island %d: %.0f m2, centre %s, from %s to %s, %d spawns%s" % [island["index"], island["area"],
			str((island["centre"] as Vector3).round()), str(box.position.round()), str(box.end.round()), int(spawns_on.get(island["index"], 0)),
			", a teleport's floor" if _in_pit(island) else ""])
	var pits: Array = game.map.pits
	for i in range(pits.size()):
		var box: AABB = pits[i]["box"]
		var to: Vector3 = pits[i]["to"]
		print("[surf] teleport %d: %s to %s, lands at %s (island %d) yaw %.0f" % [i, str(box.position.round()), str(box.end.round()),
			str(to.round()), nav.island_at(to, 2.5), float(pits[i]["yaw"])])


## Prints, per edge of the cache, the island its start and landing are on in this bake (-1: the edge lands nowhere).
func list_landings(data: Dictionary) -> void:
	var units := float(data.get("units", 0.01905))
	var edges: Array = data.get("edges", [])
	for i in range(edges.size()):
		var row: Dictionary = edges[i]
		var from := _metres(row["from"])
		var to := _metres(row["to"])
		var off := nav.closest(to).distance_to(to)
		print("[surf] edge %d: from island %d (cached %d), lands on %d (cached %d; %d bare, %.2f m off the mesh), planned %s" % [i,
			ArenaSurf.landing_island_at(nav, from), int(row.get("from_island", -2)), ArenaSurf.landing_island_at(nav, to),
			int(row.get("to_island", -2)), nav.island_at(to, 1.0), off, row.has("lengths")])


## Writes a top-down picture of the map to [param out] (a PNG, [param scale] metres a pixel): the
## highest ramp face of each column in blue to cyan by height, else the highest floor under the
## sky in grey by height; platforms of the mesh worth landing on tinted green, teleports red,
## where they put a player yellow, spawns white. For reading a map no search finds a ride on.
func picture(out: String, scale: float) -> void:
	var b := game.map.bounds
	var w := int(ceil(b.size.x / scale))
	var h := int(ceil(b.size.z / scale))
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	var space := game.map.collision_root.get_world_3d().direct_space_state
	var lo := b.position.y
	var hi := b.end.y
	for px in range(w):
		for pz in range(h):
			var x := b.position.x + (px + 0.5) * scale
			var z := b.position.z + (pz + 0.5) * scale
			var top := hi - 1.5
			var colour := Color(0, 0, 0)
			var found_floor := false
			for _k in range(8):
				var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(x, top, z), Vector3(x, lo - 2.0, z)))
				if hit.is_empty():
					break
				var y: float = hit["position"].y
				var ny: float = (hit["normal"] as Vector3).y
				var t := clampf((y - lo) / maxf(1.0, hi - lo), 0.0, 1.0)
				var slope := rad_to_deg(acos(clampf(ny, -1.0, 1.0)))
				if slope > 46.0 and slope < 85.0:
					colour = Color(0.1, 0.2 + 0.8 * t, 0.5 + 0.5 * t)
					break
				if not found_floor and slope <= 46.0:
					found_floor = true
					colour = Color(0.15 + 0.6 * t, 0.15 + 0.6 * t, 0.15 + 0.6 * t)
				top = y - 0.1
			img.set_pixel(px, pz, colour)
	var to_pixel := func(p: Vector3) -> Vector2i:
		return Vector2i(int((p.x - b.position.x) / scale), int((p.z - b.position.z) / scale))
	for island: Dictionary in nav.islands():
		if float(island["area"]) < LANDING_AREA or (island["bounds"] as AABB).position.y > hi - 2.0 or (island["bounds"] as AABB).position.y < lo + 1.0 or _in_pit(island):
			continue
		var ib: AABB = island["bounds"]
		for px in range(maxi(0, int((ib.position.x - b.position.x) / scale)), mini(w, int((ib.end.x - b.position.x) / scale) + 1)):
			for pz in range(maxi(0, int((ib.position.z - b.position.z) / scale)), mini(h, int((ib.end.z - b.position.z) / scale) + 1)):
				var p := Vector3(b.position.x + (px + 0.5) * scale, ib.get_center().y, b.position.z + (pz + 0.5) * scale)
				if nav.on_island(int(island["index"]), p, scale):
					img.set_pixel(px, pz, img.get_pixel(px, pz).lerp(Color(0.2, 0.9, 0.2), 0.6))
	for pit: Dictionary in game.map.pits:
		var pb: AABB = pit["box"]
		if pb.size.x > 100.0:
			continue
		var a: Vector2i = to_pixel.call(pb.position)
		var e: Vector2i = to_pixel.call(pb.end)
		# A small teleport filled, a big one (the pit under a ramp) outlined.
		var small := pb.size.x <= 12.0 and pb.size.z <= 12.0
		for px in range(clampi(a.x, 0, w - 1), clampi(e.x, 0, w - 1) + 1):
			for pz in range(clampi(a.y, 0, h - 1), clampi(e.y, 0, h - 1) + 1):
				if small or px == a.x or px == e.x or pz == a.y or pz == e.y:
					img.set_pixel(px, pz, Color(0.9, 0.1, 0.1))
		var d: Vector2i = to_pixel.call(pit["to"])
		img.set_pixel(clampi(d.x, 0, w - 1), clampi(d.y, 0, h - 1), Color(1, 1, 0))
	for spawn: Transform3D in game.map.spawns:
		var s: Vector2i = to_pixel.call(spawn.origin)
		img.set_pixel(clampi(s.x, 0, w - 1), clampi(s.y, 0, h - 1), Color(1, 1, 1))
	img.resize(w * 3, h * 3, Image.INTERPOLATE_NEAREST)
	var _saved := img.save_png(out)
	print("[surf] picture %s: %d x %d, x from %.0f, z from %.0f, %.1f m a pixel (x right, z down)" % [out, w, h, b.position.x, b.position.z, scale / 3.0])


## Holds each of eight headings from every spawn platform for six seconds and prints where the
## player ends and what stopped it: what a search is up against, before it searches.
func probe() -> void:
	var seen: Dictionary = {}
	for spawn: Transform3D in game.map.spawns:
		var island := nav.island_at(spawn.origin, 2.0)
		if seen.has(island):
			continue
		seen[island] = true
		var from := nav.closest(spawn.origin)
		var course := ArenaSurf.course_for(game.map, nav, from, from + Vector3.FORWARD * 10.0)
		var sim := _simulator(course.event_at)
		for k in range(8):
			var yaw := k * 45.0
			var s := _standing_at(from, yaw)
			var event := 0
			var t := 0
			var path: Array[String] = []
			while t < 6 * TICK_RATE and event == 0:
				event = sim.step(s, sim.command(yaw, Vector2(0.0, 1.0), false))
				t += 1
				if t % 32 == 0:
					path.append("%s%s" % [str(s.position.round()), "g" if s.is_grounded() else ""])
			print("[surf] probe island %d from %s yaw %.0f: event %d after %.2f s at %s; %s" % [island, str(from.round()), yaw, event, t / float(TICK_RATE), str(s.position.round()), " ".join(path.slice(0, 8))])
		# Then off the +z and -z ends holding into the nearer face: the genre's drop-in.
		for yaw in [0.0, 180.0]:
			for strafe in [-1.0, 1.0]:
				var s := _standing_at(from, yaw)
				var event := 0
				var t := 0
				var path: Array[String] = []
				while t < 10 * TICK_RATE and event == 0:
					var mv := Vector2(0.0, 1.0) if t < 40 else Vector2(strafe, 0.2)
					event = sim.step(s, sim.command(yaw, mv, false))
					t += 1
					if t % 64 == 0:
						path.append("%s%s" % [str(s.position.round()), "g" if s.is_grounded() else ""])
				print("[surf] drop-in island %d yaw %.0f strafe %.0f: event %d after %.2f s at %s; %s" % [island, yaw, strafe, event, t / float(TICK_RATE), str(s.position.round()), " ".join(path)])


## The edges a search finds from the spawn platforms and every platform a ride lands on.
## [param platforms] caps the platforms ridden from, spawns first; [param progress] is handed
## the edges so far after each one is found, so a run cut short by its timeout keeps them.
func explore(platforms: int, progress: Callable) -> Array:
	var islands := nav.islands()
	var bounds := game.map.bounds
	var targets := PackedInt32Array()
	for island: Dictionary in islands:
		var box: AABB = island["bounds"]
		# The map's sky and floor planes are islands too, and nobody stands on either.
		if float(island["area"]) < MIN_ISLAND_AREA or box.position.y > bounds.end.y - 1.0 or box.position.y < bounds.position.y + 1.0:
			continue
		targets.append(int(island["index"]))
	# Where to start from on each platform: a spawn, or where a teleport puts a player.
	var start_of: Dictionary = {}
	var queue: Array[int] = []
	for spawn: Transform3D in game.map.spawns:
		var i := nav.island_at(spawn.origin, 2.0)
		if i >= 0 and not start_of.has(i):
			start_of[i] = nav.closest(spawn.origin)
			queue.append(i)
	for pit: Dictionary in game.map.pits:
		var i := nav.island_at(pit["to"], 2.5)
		if i >= 0 and targets.has(i) and not start_of.has(i):
			start_of[i] = nav.closest(pit["to"])
			queue.append(i)
	# Where a ride may end: the bigger platforms that are not a teleport's floor.
	var landings := PackedInt32Array()
	for t in targets:
		if float((islands[t] as Dictionary)["area"]) >= LANDING_AREA and not _in_pit(islands[t]):
			landings.append(t)
	print("[surf] exploring from %d platforms toward %d landings" % [queue.size(), landings.size()])
	var edges: Array = []
	var planner := DotBotSurfPlanner.new()
	planner.seconds = ArenaSurf.RIDE_SECONDS
	var explored := 0
	while not queue.is_empty() and edges.size() < MAX_EDGES and explored < platforms:
		var from_island: int = queue.pop_front()
		explored += 1
		var from: Vector3 = start_of[from_island]
		# Toward each platform worth riding to, biggest first: a search with no goal to steer
		# by (distance from the start) only ever found the way off the edge.
		var tried := 0
		# Lowest first, only below and not beside the start: a ride goes down, and the platform at
		# the bottom of a ramp is where the whole ramp was ridden. Nearest first spent every try on
		# the strips of walkable ramp next to the spawn, a hundred seconds each, and never reached
		# the platforms across the map; biggest first spent them on the roofs of the rooms.
		var order: Array = Array(landings)
		order = order.filter(func(t: int) -> bool:
			var c: Vector3 = (islands[t] as Dictionary)["centre"]
			return c.y < from.y - 1.0 and Vector2(c.x - from.x, c.z - from.z).length() >= MIN_RIDE_METRES)
		order.sort_custom(func(a: int, b: int) -> bool:
			return float((islands[a] as Dictionary)["centre"].y) < float((islands[b] as Dictionary)["centre"].y))
		for target: int in order:
			if target == from_island or tried >= TARGETS_PER_PLATFORM or edges.size() >= MAX_EDGES:
				continue
			var aim := nav.closest((islands[target] as Dictionary)["centre"])
			if aim.y > from.y + 2.0 or Vector2(aim.x - from.x, aim.z - from.z).length() > MAX_RIDE_METRES:
				continue
			tried += 1
			var course := ExploreCourse.new()
			course.nav = nav
			course.start = from
			course.directed = true
			course.gravity = 800.0 * ArenaSurf.UNITS
			course.floor_y = bounds.position.y - ArenaSurf.FALL_OUT_DEPTH
			for pit: Dictionary in game.map.pits:
				course.pit_boxes.append(pit["box"])
			# Steered toward this one, but landing on any of them is a ride: the best line toward a
			# far platform often ends on its neighbour.
			course.targets.append(target)
			for other: int in order:
				if other != target:
					course.targets.append(other)
			course.unsupported_fn = ArenaSurf.unsupported_test(game.map)
			course.toward_goal = true
			course.unsupported_penalty = ArenaSurf.UNSUPPORTED_PENALTY
			course.goal_centre = aim
			var _settled := course.settle()
			var sim := _simulator(course.event_at)
			var start := _standing_at(from, course.reference_yaw())
			var t0 := Time.get_ticks_msec()
			var found := planner.search(start, course, sim)
			if not bool(found["found"]):
				print("[surf]   island %d to %d (%.0f m2, %.0f m away): no ride (%s), %.1f s" % [from_island, target,
					float((islands[target] as Dictionary)["area"]), from.distance_to(aim), found["why"], (Time.get_ticks_msec() - t0) / 1000.0])
				continue
			var landing := _replay_end(start, found["actions"], course, sim)
			var to_point := nav.closest(landing)
			var landed := nav.island_at(landing, 1.5)
			var reached := landed if landed >= 0 else target
			var seconds := float(found["ticks"]) / float(TICK_RATE)
			print("[surf]   island %d to %d: a ride of %.2f s landing at %s, %.1f s searching" % [
				from_island, reached, seconds, str(to_point.round()), (Time.get_ticks_msec() - t0) / 1000.0])
			edges.append({"from": _units(from), "to": _units(to_point), "from_island": from_island, "to_island": reached,
				"explored_seconds": snappedf(seconds, 0.01), "veto": true})
			progress.call(edges)
			if not start_of.has(reached):
				start_of[reached] = to_point
				queue.append(reached)
	return edges


## Whether [param island] is a teleport's floor: its middle, a step above it, inside a pit. A
## combat surf map's big teleports are the rooms under its ramps, and their floors bake as the
## largest islands of the map; landing there is the fall, not a platform.
func _in_pit(island: Dictionary) -> bool:
	var at := nav.closest(island["centre"]) + Vector3.UP * 0.5
	for pit: Dictionary in game.map.pits:
		if (pit["box"] as AABB).has_point(at):
			return true
	return false


func _replay_end(start: DotFpsState, actions: PackedByteArray, course: DotBotSurfCourse, sim: DotFpsSimulator) -> Vector3:
	var s := start.duplicate_state()
	var reference := course.reference_yaw()
	for action: int in actions:
		for _t in range(8):
			if sim.step(s, DotBotSurfPilot.command_for(sim, action, s, reference)) != DotFpsSimulator.EVENT_NONE:
				return s.position
	return s.position


# --- Planning ------------------------------------------------------------------------

func plan(index: int, edge: Dictionary, starts: int, repairs: int, rounds: int) -> void:
	var from := _metres(edge["from"])
	var to := _metres(edge["to"])
	var course := ArenaSurf.course_for(game.map, nav, from, to)
	if course.landing_island < 0:
		print("[surf] edge %d lands on no island of this mesh; explore again" % index)
		return
	var sim := _simulator(course.event_at)
	var repair_sim := _simulator(course.event_at)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1000 + index
	var from_starts: Array = [_standing_at(from, course.reference_yaw())]
	for i in range(starts - 1):
		from_starts.append(perturbed(from, course.reference_yaw(), rng))
	var repair_rng := RandomNumberGenerator.new()
	repair_rng.seed = 3000 + index
	var repair_starts: Array = []
	for i in range(repairs):
		repair_starts.append(perturbed(from, course.reference_yaw(), repair_rng))
	var planner := DotBotSurfPlanner.new()
	planner.seconds = ArenaSurf.RIDE_SECONDS
	planner.repair_back = TICK_RATE
	var started := Time.get_ticks_msec()
	print("[surf] planning edge %d: island %d to %d, %.0f m" % [index, int(edge.get("from_island", -1)), int(edge.get("to_island", -1)), from.distance_to(to)])
	var built := planner.build(from_starts, repair_starts, rounds, course, sim, repair_sim,
		func(line: String) -> void: print("[surf]   " + line))
	var spent := (Time.get_ticks_msec() - started) / 1000.0
	print("[surf]   edge %d: %d searches found %d rides, failures per round %s; %.1f s wall, %d motor ticks (%.1f us each)" % [
		index, built["searches"], built["found"], str(built["rounds"]), spent, sim.steps + repair_sim.steps,
		float(sim.usec + repair_sim.usec) / maxf(1.0, float(sim.steps + repair_sim.steps))])
	edge["reference_yaw"] = snappedf(course.reference_yaw(), 0.01)
	edge["lengths"] = Array(built["lengths"])
	edge["rides"] = built["seconds"]
	edge["planned"] = {"starts": starts, "repairs": repairs, "rounds": built["rounds"], "searches": built["searches"],
		"seconds": snappedf(spent, 0.1), "motor_ticks": sim.steps + repair_sim.steps, "tick_rate": TICK_RATE}
	edge["entries"] = DotBotSurfPilot.entries_to_rows(built["rides"], ArenaSurf.UNITS)


# --- Recorded rides ------------------------------------------------------------------

## Lists the recorded rides of the map per edge and, with [param verify], replays the unchecked ones.
func demos(verify: bool, merged_path: String = "") -> void:
	var cfg := DotBotDemoConfig.new()
	var layered := cfg.load_layered("")
	var made := DotBotDemoStore.from_config(cfg, null) if layered.ok else layered
	if not made.ok or made.value == null:
		print("[surf] no ride store: %s" % ("off" if made.ok else made.error.message))
		return
	var store: DotBotDemoStore = made.value
	var _opened := store.open()
	var rides := ArenaSurfRides.new()
	var ready := rides.setup(game, cfg, store, float(TICK_RATE))
	if not ready.ok:
		print("[surf] %s" % ready.error.message)
		return
	rides.set_map(game.map, nav)
	var counts: DotResult = await store.counts(rides.recorder.map_id, rides.recorder.map_version, ArenaSurfRides.KIND)
	if not counts.ok:
		print("[surf] the store did not answer: %s" % counts.error.message)
		return
	for key: String in counts.value:
		print("[surf] edge %s: %d verified recorded rides" % [key, counts.value[key]])
	if counts.value.is_empty():
		print("[surf] nothing recorded for %s@%s" % [rides.recorder.map_id, rides.recorder.map_version])
	# Before the harvest, so a recording is judged and piloted on the course a bot rides its edge on.
	var surf := ArenaSurf.load_for(game.map, nav)
	if surf != null:
		await rides.attach_surf(surf)
	if verify:
		var harvest := rides.harvest_on(bot.controller)
		if harvest == null:
			print("[surf] no simulator to replay on")
			return
		for key: String in counts.value:
			var done: DotResult = await harvest.harvest(store, rides.recorder.map_id, rides.recorder.map_version, ArenaSurfRides.KIND, key)
			print("[surf] edge %s: %s" % [key, "%d verified now" % done.value if done.ok else done.error.message])
		for line in harvest.describe_lines():
			print("[surf] %s" % line)
		print("[surf] %d of the replays ridden by the pilot (piloted %s)" % [harvest.describe()["piloted_replays"], str(harvest.is_piloted())])
	for key: String in counts.value:
		var _loaded: DotResult = await rides.book.load_edge(store, ArenaSurfRides.KIND, key, rides.schema, float(TICK_RATE), rides.reference_yaw_for(key))
	for line in rides.book.describe_lines():
		print("[surf] %s" % line)
	if verify and surf != null and merged_path != "":
		_write_merged(rides, surf, merged_path)


## The planned cache of the map with each edge's verified recordings added as rides of their own, in the cache's units.
func _write_merged(rides: ArenaSurfRides, surf: ArenaSurf, path: String) -> void:
	var data := _read(ProjectSettings.globalize_path(ArenaSurf.path_for(map_id)))
	var edges: Array = data.get("edges", [])
	var added := 0
	for edge: ArenaSurf.Edge in surf.edges:
		if edge.id >= edges.size():
			continue
		var row: Dictionary = edges[edge.id]
		var entries: Array = row.get("entries", [])
		var lengths: Array = row.get("lengths", [])
		for ride: Dictionary in rides.book.ranked(rides.edge_key(edge)):
			var cache: Variant = (ride["data"] as Dictionary).get("cache") if ride["data"] is Dictionary else null
			if ride["source"] != DotBotRideBook.RECORDED or not (cache is PackedFloat32Array):
				continue
			var rows := DotBotSurfPilot.entries_to_rows(cache, ArenaSurf.UNITS)
			entries.append_array(rows)
			lengths.append(rows.size())
			added += 1
		row["entries"] = entries
		row["lengths"] = lengths
	print("[surf] %d recorded rides added to the planned cache" % added)
	if added > 0:
		_write(path, data)


# --- Measuring -----------------------------------------------------------------------


# --- Pieces --------------------------------------------------------------------------
