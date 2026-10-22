extends RefCounted

## Bots ride the ramps of a combat surf map: ride edges between the platforms in the bots'
## routes, and the surf pilot on the legs while a bot rides one.
##
## [b]Why a combat surf map needs this.[/b] [DotBotNav] bakes what a body can stand on, and a
## ramp steeper than the slope limit is never ground, so an imported surf map bakes as islands:
## the spawn platforms, the landings at the foot of each ramp, the jail. A bot's route to another
## platform ended at the edge of its own and it walked straight off. A ride edge is a navigation
## link from one platform to another that the map's ramps carry a player across; a route may
## cross it, and when the brain reaches its start ([member DotBotIntent.ride]) the legs are
## dot-bot's [DotBotSurfPilot]'s until it lands, while the brain keeps aiming and shooting.
##
## [b]Learned offline, from the map alone.[/b] `tools/surf_rides.tscn` finds the edges (a search
## from each platform for a ride that lands on another), and plans each on the real motor with
## dot-bot's [DotBotSurfPlanner]: rides from perturbed starts, then repair rounds from wherever
## the pilot fails. The result is `maps/surf/<id>.surf.json`; nothing is planned at map load.
## The map's teleports are pits on every ride, and walkable links in the routes (a bot at the
## foot of a ramp walks into the teleport that takes it back up). Reasoning and numbers:
## docs/imported-maps.md, "Bots ride the ramps".
##
## [b]Loaded by path, and only on a shell that has it.[/b] This file names dot-bot's level 4 and
## dot-player-controller's level 3 ([DotBotSurfRide], [DotFpsSimulator]); `arena_bots.gd` loads
## it only when both are there, so an older shell's bots walk as they did.

const CHANNEL := "arena.surf"

const ArenaPaths := preload("arena_paths.gd")

## Where a map's rides are kept.
const CACHE := "res://maps/surf/%s.surf.json"

## Metres per unit in the cache file: the genre unit, as game-g2gfast's caches.
const UNITS := 0.01905

## Ride ids are edge indices; a teleport link's id is this plus the pit's index.
const TELEPORT_BASE := 1000

## The longest a ride may run before the bot is told it did not land, seconds.
const RIDE_SECONDS := 30.0

## How far below the map's bounds a ride has fallen out (what `ArenaPlayer` catches).
const FALL_OUT_DEPTH := 10.0


## A ride's course on a combat surf map: arriving is standing on the landing platform; a pit is
## any of the map's teleports, and falling out under the map.
class EdgeCourse:
	extends DotBotSurfCourse

	var nav: DotBotNav = null
	var landing_island: int = -1
	## The landing island and its neighbours at its height: a floor a kerb splits is two islands
	## to the mesh and one floor to a rider (surf_ski_2's bottom, 2026-10-13).
	var landing_islands: PackedInt32Array = PackedInt32Array()
	var pit_boxes: Array[AABB] = []

	func event_at(state: Variant) -> int:
		var p: Vector3 = state.position
		if p.y < floor_y:
			return EVENT_BELOW
		# Before the goal: a teleport on the landing platform still takes the player away.
		for box in pit_boxes:
			if box.has_point(p):
				return EVENT_PIT
		# Standing, or nearly: the mesh is baked at 46 degrees and these maps' movement stands at
		# 45.57, so a landing's edge can be a slope the motor slides on and the mesh walks on.
		var v: Vector3 = state.velocity
		if state.is_grounded() or v.y > -LANDED_FALL:
			for island in landing_islands:
				if nav.on_island(island, p, 0.6):
					return EVENT_GOAL
		return EVENT_NONE


## One ride edge: from where, to where, its course, its cache and its simulator.
class Edge:
	extends RefCounted
	var id: int = 0
	var from: Vector3 = Vector3.ZERO
	var to: Vector3 = Vector3.ZERO
	var course: EdgeCourse = null
	var cache: DotBotSurfPilot = null
	## Built from the first bot that rides it, with the course as its oracle.
	var sim: DotFpsSimulator = null
	var veto: bool = true
	## Whether it is in the mesh: planned, and landing on an island of this bake.
	var linked: bool = false


var map: Object = null
var nav: DotBotNav = null
var edges: Array[Edge] = []
## Recorded rides ([code]arena_surf_rides.gd[/code]): an edge with a verified recording rides one of them.
var rides: RefCounted = null
## Teleport link id -> [from, to].
var teleports: Dictionary = {}

## Rides begun and how they ended, and the microseconds spent steering them, for describe().
var begun: int = 0
var landed: int = 0
var fell: int = 0
var timed_out: int = 0
var steer_usec: int = 0
var steer_ticks: int = 0


## The cache path for a map id.
static func path_for(id: StringName) -> String:
	return ArenaPaths.rebase(CACHE) % String(id)


## The rides of [param p_map] on [param p_nav] (baked and ready), linked into it, or null when
## the map has no cache.
static func load_for(p_map: Object, p_nav: DotBotNav) -> RefCounted:
	var path := path_for(p_map.get("id"))
	if not FileAccess.file_exists(path):
		return null
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		DotLog.warn(CHANNEL, "a surf cache that does not read", {"path": path})
		return null
	var made: RefCounted = (load(ArenaPaths.rebase("res://game/arena_surf.gd")) as GDScript).new()
	made.call(&"attach", p_map, p_nav, parsed)
	return made


## Builds the edges from [param data] and links them, and the map's teleports, into the mesh.
func attach(p_map: Object, p_nav: DotBotNav, data: Dictionary) -> void:
	map = p_map
	nav = p_nav
	var units := float(data.get("units", UNITS))
	for row: Dictionary in data.get("edges", []):
		var from := _vector(row.get("from", []), units)
		var to := _vector(row.get("to", []), units)
		var edge := Edge.new()
		edge.id = edges.size()
		edge.from = from
		edge.to = to
		edge.veto = bool(row.get("veto", true))
		edge.course = course_for(map, nav, from, to, float(row.get("reference_yaw", NAN)))
		edge.cache = DotBotSurfPilot.new()
		edge.cache.load_stage(row, units)
		edges.append(edge)
		if edge.cache.size() == 0:
			# Found and not planned yet: not ridden, and not routed over.
			continue
		if edge.course.landing_island < 0:
			DotLog.warn(CHANNEL, "a ride edge that lands nowhere on this mesh", {"map": str(map.get("id")), "edge": edge.id})
			continue
		nav.add_ride(from, to, edge.id)
		edge.linked = true
	_link_teleports()
	DotLog.info(CHANNEL, "ride edges linked", {"map": str(map.get("id")), "edges": edges.size(), "teleports": teleports.size()})


## The course of a ride from [param from] to the platform under [param to] on [param p_map]:
## the tool plans on it and the game rides on it, so both are this one function.
static func course_for(p_map: Object, p_nav: DotBotNav, from: Vector3, to: Vector3, yaw: float = NAN) -> EdgeCourse:
	var course := EdgeCourse.new()
	course.nav = p_nav
	course.start = from
	course.goal_centre = to
	course.landing_island = p_nav.island_at(to, 1.0)
	course.landing_islands = landing_floor(p_nav, course.landing_island)
	course.gravity = 800.0 * UNITS
	var bounds: AABB = p_map.get("bounds")
	course.floor_y = bounds.position.y - FALL_OUT_DEPTH
	for pit: Dictionary in p_map.get("pits"):
		course.pit_boxes.append(pit["box"])
	course.unsupported_fn = unsupported_test(p_map)
	course.toward_goal = true
	course.unsupported_penalty = UNSUPPORTED_PENALTY
	var _settled := course.settle()
	course.start_yaw = course.reference_yaw() if is_nan(yaw) else yaw
	return course


## [param island] and every island whose outline comes within [constant FLOOR_JOIN] metres of
## its and whose height is within [constant FLOOR_STEP]: one floor, however the bake split it.
static func landing_floor(p_nav: DotBotNav, island: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if island < 0:
		return out
	out.append(island)
	var all := p_nav.islands()
	var box: AABB = all[island]["bounds"]
	var near := box.grow(FLOOR_JOIN)
	for other: Dictionary in all:
		var i: int = other["index"]
		var obox: AABB = other["bounds"]
		if i != island and near.intersects(obox.grow(0.01)) and absf(obox.get_center().y - box.get_center().y) <= FLOOR_STEP:
			out.append(i)
	return out


## Falling slower than this, m/s, on the landing island is landed.
const LANDED_FALL := 3.0

const FLOOR_JOIN := 1.5
const FLOOR_STEP := 3.0


## `func(state) -> bool`: nothing but the map's floor under the state within a long fall. What
## keeps the planner's beam on the ramps (see [member DotBotSurfCourse.unsupported_fn]).
static func unsupported_test(p_map: Object) -> Callable:
	var root: Node3D = p_map.get("collision_root")
	var bounds: AABB = p_map.get("bounds")
	var floor := bounds.position.y + SUPPORT_ABOVE_FLOOR
	return func(state: Variant) -> bool:
		if root == null or not root.is_inside_tree():
			return false
		var p: Vector3 = state.position + Vector3.UP * 0.2
		var v: Vector3 = state.velocity
		var space := root.get_world_3d().direct_space_state
		# Straight down, and down along where it is going: a jump across the gap to a ramp's top
		# has only the floor straight under it, and the ramp ahead.
		var flat := Vector3(v.x, 0.0, v.z)
		var rays: Array[Vector3] = [Vector3.DOWN]
		if flat.length() > 1.0:
			flat = flat.normalized()
			for ahead in [1.0, 2.0, 4.0]:
				rays.append((flat * ahead + Vector3.DOWN).normalized())
		for direction in rays:
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p, p + direction * SUPPORT_REACH))
			if not hit.is_empty() and (hit["position"] as Vector3).y >= floor:
				return false
		return true


## What an unheld state scores less, metres: more than a fall's worth of speed buys, so a line
## that has left the ramps never outranks one still on them.
const UNSUPPORTED_PENALTY := 150.0

## A state is held when something stands under it within this far, metres, and higher than this
## over the map's floor (the floor of a combat surf map is a teleport back to the top).
const SUPPORT_REACH := 60.0
const SUPPORT_ABOVE_FLOOR := 8.0


## Each teleport whose box stands on a platform and whose destination is on one is a walked link:
## a bot at the foot of a ramp walks into it and comes out at the top.
func _link_teleports() -> void:
	var pits: Array = map.get("pits")
	for i in range(pits.size()):
		var box: AABB = pits[i]["box"]
		var dest: Vector3 = pits[i]["to"]
		if box.size.x > 12.0 or box.size.z > 12.0:
			# A floor under half the map is where a fall ends, not a door anybody walks to.
			continue
		var floor_point := Vector3(box.get_center().x, box.position.y, box.get_center().z)
		var near := nav.closest(floor_point)
		if Vector2(near.x - floor_point.x, near.z - floor_point.z).length() > 1.0 or absf(near.y - floor_point.y) > 1.5:
			continue
		var landing := nav.closest(dest)
		if landing.distance_to(dest) > 2.5:
			continue
		var id := TELEPORT_BASE + i
		teleports[id] = [near, landing]
		# Nearly free: the distance a teleport covers is not walked.
		nav.add_ride(near, landing, id, 0.01)


## A route that may ride or teleport (see [method DotBotNav.route]).
func route_detail(from: Vector3, to: Vector3) -> Dictionary:
	return nav.route(from, to)


## The landing platforms, as places worth roaming to: without them every waypoint is a spawn,
## and on these maps the spawns are one platform pair at the top.
func landing_points() -> PackedVector3Array:
	var out := PackedVector3Array()
	for edge in edges:
		if edge.linked:
			out.append(edge.to)
	# The way up to a ride that starts away from the spawns (a pad a teleport puts a player on, the
	# landing back on the spawn island) is a place to roam to as well: the teleport's door. Nothing
	# else sends a bot there, so that ride was never taken. The pad itself is no goal: a route to
	# a point on it ends on the floor beneath, never through the teleport's link.
	var spawn_islands := PackedInt32Array()
	for spawn: Transform3D in map.get("spawns"):
		spawn_islands.append(nav.island_at(spawn.origin, 2.0))
	for id in teleports:
		var link: Array = teleports[id]
		for edge in edges:
			if edge.linked and edge.from.distance_to(link[1]) < 3.0 and not spawn_islands.has(nav.island_at(edge.from, 2.5)):
				out.append(link[0])
				break
	return out


## The legs of [param bot] this tick, when its route reached a ride edge or it is riding one:
## [param intent] (the brain's) gets the pilot's move and jump for its own view.
func steer(bot: Object, mind: Object, intent: DotBotIntent, tick: int, tick_rate: float) -> void:
	var ride: DotBotSurfRide = mind.get(&"ride")
	var state: DotFpsState = null
	var controller: Variant = bot.get(&"controller")
	if controller is DotFpsController:
		state = (controller as DotFpsController).state
	if ride == null:
		var id := intent.ride
		if id < 0 or id >= edges.size() or not edges[id].linked or state == null or not bool(bot.call(&"is_alive")):
			return
		var edge := edges[id]
		var sim := _sim_for(edge, controller as DotFpsController) if edge.veto else null
		ride = DotBotSurfRide.new().begin(edge.cache, edge.course, sim, tick, tick_rate, RIDE_SECONDS)
		# A recording starts at the takeoff arena_surf_rides.gd saw (airborne above no island), so the pilot runs up and the recording takes over there.
		var recorded: Dictionary = rides.call(&"pick", edge.id) if rides != null else {}
		if not recorded.is_empty():
			ride.set_meta(&"recording", recorded)
		mind.set(&"ride", ride)
		begun += 1
	if ride != null and ride.has_meta(&"recording") and state != null and not state.is_grounded() and nav.island_at(state.position, 1.0) < 0:
		var entry: Dictionary = ride.get_meta(&"recording")
		ride.remove_meta(&"recording")
		ride.picked = entry
		ride.recorded = entry["data"]
		ride.decode = Callable(rides, &"decode")
		ride.ticks = 1
	var status := DotBotSurfRide.FELL
	if state != null and bool(bot.call(&"is_alive")):
		var began := Time.get_ticks_usec()
		status = ride.steer(state, intent, tick)
		steer_usec += Time.get_ticks_usec() - began
		steer_ticks += 1
	if status == DotBotSurfRide.RIDING:
		return
	match status:
		DotBotSurfRide.LANDED:
			landed += 1
		DotBotSurfRide.TIMED_OUT:
			timed_out += 1
		_:
			fell += 1
	mind.set(&"ride", null)
	var brain: Variant = mind.get(&"brain")
	if brain is DotBotBrain:
		(brain as DotBotBrain).ride_ended(status == DotBotSurfRide.LANDED)


## The simulator a ride's veto runs on: the riding player's own motor over the map's brushes
## (never its solid-players wrapper: the others' hulls would stand still in a forecast), the
## map's pushes as its mechanics, the edge's course as its oracle.
func _sim_for(edge: Edge, controller: DotFpsController) -> DotFpsSimulator:
	if edge.sim != null:
		return edge.sim
	var body: DotFpsBody = map.call(&"movement_body")
	if body == null:
		return null
	controller.body.copy_filters_to(body)
	var sim := controller.simulator(body)
	if sim == null:
		return null
	sim.oracle = edge.course.event_at
	var mechanics: Variant = map.get(&"mechanics")
	if mechanics != null:
		sim.mechanics = func(state: DotFpsState, motor: DotFpsMotor, delta: float, start: Vector3) -> int:
			mechanics.call(&"simulate", motor, state, start, delta)
			return DotFpsSimulator.EVENT_NONE
	edge.sim = sim
	return sim


static func _vector(row: Array, units: float) -> Vector3:
	return Vector3(float(row[0]), float(row[1]), float(row[2])) * units if row.size() >= 3 else Vector3.ZERO


func describe() -> Dictionary:
	return {"edges": edges.size(), "linked": edges.filter(func(e: Edge) -> bool: return e.linked).size(),
		"teleports": teleports.size(), "begun": begun, "landed": landed,
		"fell": fell, "timed_out": timed_out,
		"steer_us_per_tick": snappedf(float(steer_usec) / maxf(1.0, float(steer_ticks)), 0.1)}
