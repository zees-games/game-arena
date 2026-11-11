extends RefCounted

const CHANNEL := "arena.bots"
## A drop up to this many metres gets a reverse climb edge on a team map, and the ids those take.
const LEDGE_CLIMB_MAX := 2.2
const LEDGE_CLIMB_ID := 5000000

const ArenaPaths := preload("arena_paths.gd")
const ArenaFrameProbe := preload("arena_frame_probe.gd")


class NavWorld:
	extends DotBotWorld

	var game: Object = null
	var brains: Dictionary = {}
	var _tick: int = -1
	## The drop list of [member _drops_tick]: drops lie still while the brains of a tick think, and every brain asks.
	var _drops_held: Array = []
	var _drops_tick: int = -1
	## The graph bots walk on and the map it was built for: the horde's when it has one,
	## built here on a built-in map when it does not, none on an imported map.
	var _graph: DotNpcNavGraph = null
	var _graph_map: Object = null
	## An imported map's walkable mesh, baked from its brushes in the background, and the map
	## it is for. See [method _nav_for_map].
	var _nav: DotBotNav = null
	var _nav_map: Object = null
	## The map's ride edges ([code]arena_surf.gd[/code]), once its mesh has landed and if it has
	## a surf cache; and whether that was looked for on this mesh.
	var _surf: RefCounted = null
	var _surf_looked: bool = false
	## The map's ladders joined into [member _nav] as climb edges, and how many got one.
	var _ladders: DotBotLinks = null
	## The drop and hop edges found on the mesh (kept so they are not collected).
	var _edges: DotBotLinks = null
	## False in a test that wants ladders to be the only way up.
	var join_edges := true
	## Parallel think (cvar `bot_threads`, ArenaBotThreads): while true, brains on worker threads ask this world, whose
	## sight and wall rays then use queries of their own on [member _par_space] and whose other answers take [member _par_lock].
	var par: bool = false
	var _par_space: PhysicsDirectSpaceState3D = null
	var _par_trace: DotTrace = null
	var _par_physics: bool = false
	var _par_lock := Mutex.new()
	## GodotPhysics3D answers every query out of buffers the space shares, so rays go one at a time.
	var _ray_lock := Mutex.new()
	## Any player's arsenal, taken on the main thread (walking the roster is not for a worker).
	var _par_arsenal: Array = [null]
	## The trace's ray observer (dropped weapons nudged by a shot) is called on the main thread: a worker's wall
	## rays are logged per job and replayed in job order by [method par_end].
	var _par_observe: bool = false
	var _par_job: Dictionary = {}
	var _par_rays: Dictionary = {}

	func par_end() -> void:
		par = false
		if _par_observe:
			var jobs := _par_rays.keys()
			jobs.sort()
			for job: int in jobs:
				for r: Array in _par_rays[job]:
					_par_trace.ray_observer.call(r[0], r[1], r[2])
		_par_rays.clear()
		_par_arsenal[0] = null
		_par_space = null
		_par_trace = null

	func _glass_of_trace() -> DotMapGlassSight:
		var g: Variant = _par_trace.get("glass")
		return g as DotMapGlassSight if g is DotMapGlassSight and (g as DotMapGlassSight).glass_mask != 0 else null

	func _ray_par(from: Vector3, to: Vector3, mask: int) -> Dictionary:
		var q := PhysicsRayQueryParameters3D.new()
		q.from = from
		q.to = to
		q.collision_mask = mask
		q.exclude = _par_trace.exclude_rids
		q.collide_with_areas = false
		q.collide_with_bodies = true
		q.hit_from_inside = false
		_ray_lock.lock()
		var result := _par_space.intersect_ray(q)
		_ray_lock.unlock()
		return result

	func _wall_par(from: Vector3, dir: Vector3, reach: float) -> Dictionary:
		var found := {}
		if not _par_physics:
			# DotTrace.ray with no hitboxes is this world ray (the observer is called below, on the main thread).
			var flat: DotHitbox.Hit = _par_trace.call(&"_world_ray", from, dir, reach)
			if flat.ok():
				found = {"normal": flat.normal, "distance": flat.distance}
		else:
			var glass := _glass_of_trace()
			var base: int = _par_trace.collision_mask
			var result := _ray_par(from, from + dir * reach, glass.shot_mask(from, base) if glass != null else base)
			if not result.is_empty():
				found = {"normal": result["normal"], "distance": from.distance_to(result["position"])}
		if _par_observe:
			_par_lock.lock()
			var job: int = _par_job.get(OS.get_thread_caller_id(), -1)
			if not _par_rays.has(job):
				_par_rays[job] = []
			(_par_rays[job] as Array).append([from, dir, float(found["distance"]) if not found.is_empty() else reach])
			_par_lock.unlock()
		return found

	func wall_ahead(from: Vector3, dir: Vector3, reach: float) -> Dictionary:
		if par:
			return _wall_par(from, dir, reach)
		var t_wall := Time.get_ticks_usec()
		var found := _wall_ahead(from, dir, reach)
		ArenaFrameProbe.add(&"bot_wall_ray", t_wall)
		return found

	func _wall_ahead(from: Vector3, dir: Vector3, reach: float) -> Dictionary:
		var combat: Variant = game.get("combat")
		var trace: Variant = (combat as Object).get("trace") if combat is Object else null
		if not trace is DotTrace:
			return {}
		var hit := (trace as DotTrace).ray(from, dir, reach)
		if not hit.ok():
			return {}
		return {"normal": hit.normal, "distance": hit.distance}

	const ROAM_PLACES := 24

	## A route that may ride a ramp or walk through a teleport: the mesh's own answer once the
	## map's ride edges are linked into it, the walked corners otherwise.
	func route_detail(from: Vector3, to: Vector3) -> Dictionary:
		if par:
			_par_lock.lock()
			var held := _route_detail(from, to)
			_par_lock.unlock()
			return held
		var t_lap := ArenaFrameProbe.lap_start()
		var detail := _route_detail(from, to)
		ArenaFrameProbe.lap(&"bot_route_detail", t_lap)
		return detail

	func _route_detail(from: Vector3, to: Vector3) -> Dictionary:
		var surf := surf_for_map()
		if surf != null:
			return surf.call(&"route_detail", from, to)
		if _ladders != null and _nav != null and _nav.is_ready():
			return _nav.route(from, to)
		var points := route(from, to)
		var rides := PackedInt32Array()
		rides.resize(points.size())
		rides.fill(-1)
		return {"points": points, "rides": rides}

	## The map's ride edges, linked into its mesh: null on a built-in map, before the mesh lands,
	## on a map with no surf cache, and on a shell without dot-bot 4 or dot-player-controller 3.
	func surf_for_map() -> RefCounted:
		var nav := _nav_for_map()
		if nav == null or not nav.is_ready():
			return null
		if _surf_looked:
			return _surf
		_surf_looked = true
		_link_ladders(nav)
		if DotAddonApi.build_level("dot_bot") < 4 or DotAddonApi.build_level("dot_player_controller") < 3:
			return null
		var surf_script := load(ArenaPaths.rebase("res://game/arena_surf.gd")) as GDScript
		_surf = surf_script.call(&"load_for", game.get("map"), nav) if surf_script != null else null
		return _surf

	## How many ladders the bots can climb on this map: climb edges in the mesh.
	func ladder_count() -> int:
		if _ladders == null:
			return 0
		var n := 0
		for l: Dictionary in _ladders.ladders:
			n += 1 if l.has("from") else 0
		return n

	## Joins the imported map's ladders into [param nav] as one-way climbs and hands the brain their geometry (dot-bot 10).
	func _link_ladders(nav: DotBotNav) -> void:
		_ladders = null
		ladder_fn = Callable()
		# Drops off the rims and hops over gaps join a spawn island the plain bake leaves cut off.
		if join_edges and DotAddonApi.build_level("dot_bot") >= 12:
			_edges = DotBotLinks.new()
			_edges.join(nav)
			_climb_back_ledges(nav)
		if DotAddonApi.build_level("dot_bot") >= 13:
			extra_waypoints = nav.spread_points(ROAM_PLACES, DotRandomStream.new(7919, &"roam"))
		var mechanics: Variant = (game.get("map") as Object).get("mechanics")
		if DotAddonApi.build_level("dot_bot") < 10 or not (mechanics is Object) or (mechanics as Object).get("ladders").is_empty():
			return
		var links := DotBotLinks.link_ladders(nav, (mechanics as Object).get("ladders"))
		if links != null:
			_ladders = links
			ladder_fn = links.ladder_of

	## A team map's spawn rooms are walled in, with a ramp that tops out on a ledge over the open floor: bots leave by the drop but, with no way back up, never reach the enemy spawn. Each short drop gets a reverse climb edge, only on a map whose spawns carry a side.
	func _climb_back_ledges(nav: DotBotNav) -> void:
		var map: Variant = game.get("map")
		if not (map is Object) or not (map as Object).has_method(&"spawn_tag"):
			return
		var tagged := false
		for index in (map as Object).get("spawns").size():
			if (map as Object).call(&"spawn_tag", index) != &"":
				tagged = true
				break
		if not tagged:
			return
		nav.begin_batch()
		for ride: Dictionary in nav.rides():
			var drop: float = (ride["from"] as Vector3).y - (ride["to"] as Vector3).y
			if int(ride["id"]) >= LEDGE_CLIMB_ID or drop < 1.0 or drop > LEDGE_CLIMB_MAX:
				continue
			nav.add_ride(ride["to"], ride["from"], LEDGE_CLIMB_ID + int(ride["id"]), 3.0)
		nav.end_batch()

	## Starts the mesh bake and, once it has landed, loads the ride edges; true when both are done. Called every frame while loading, it keeps that work out of the first bot tick.
	func warm() -> bool:
		var nav := _nav_for_map()
		if nav == null:
			return true
		if not nav.is_ready():
			return false
		surf_for_map()
		return true

	## The imported map's mesh for the ride recorder (baking it if nothing has asked yet); null on a built-in map.
	func nav_for_rides() -> DotBotNav:
		return _nav_for_map()

	## The corners of a way from [param from] to [param to]: over the navigation graph on a
	## built-in map, over the mesh baked from the brushes on an imported one; empty (walk
	## straight) off either, with no way, or while an imported map's mesh is still baking.
	func route(from: Vector3, to: Vector3) -> PackedVector3Array:
		if par:
			_par_lock.lock()
			var held := _route(from, to)
			_par_lock.unlock()
			return held
		var t_route := Time.get_ticks_usec()
		var corners := _route(from, to)
		ArenaFrameProbe.add(&"bot_route", t_route)
		return corners

	func _route(from: Vector3, to: Vector3) -> PackedVector3Array:
		var nav := _nav_for_map()
		if nav != null:
			return nav.path(from, to)
		var graph := _graph_for_map()
		if graph == null:
			return PackedVector3Array()
		return graph.find_smooth_path(from, to, -1.0, true)

	## The mesh for an imported map, the bake started on the first route asked on it; null on a built-in map.
	## [b]Not the graph.[/b] The graph is laid over a box list; an imported map's solid is hundreds of convex brushes with ramps and ledges at every height, so graph bots walked through the walls. dot-bot's [DotBotNav] bakes what a body can stand on
	## from those brushes ([member ArenaMap.collision_root]). [b]In the background[/b]: the two default surf maps took 2 to 3 s to bake against a tenth of a second for the map change, so bots walk straight for those seconds and route after.
	func _nav_for_map() -> DotBotNav:
		var map: Variant = game.get("map")
		if not (map is Object) or not (map as Object).has_method(&"is_imported") or not bool((map as Object).call(&"is_imported")):
			return null
		if _nav != null and _nav_map == map:
			return _nav
		# An older shell's dot-bot has no background bake, and baking in the tick is seconds:
		# its bots walk straight, as they did before.
		if DotAddonApi.build_level("dot_bot") < 3:
			return null
		var root: Variant = (map as Object).get("collision_root")
		if not (root is Node3D) or not (root as Node3D).is_inside_tree():
			return null
		if _nav != null:
			_nav.clear()
		_nav = DotBotNav.new()
		_nav_map = map
		_surf = null
		_surf_looked = false
		_ladders = null
		var body := _body_tunables()
		var source: Node3D = (map as Object).call(&"nav_source") if (map as Object).has_method(&"nav_source") else null
		var started := _nav.bake_in_background(source if source != null else root as Node3D, {"radius": body.radius, "height": body.stand_height, "climb": body.step_height})
		if source != null:
			source.free()
		if not started.ok:
			DotLog.warn(CHANNEL, "bots cannot route on this map", {"map": str((map as Object).get("id")), "error": started.error.message})
		return _nav

	func walkable_near(at: Vector3) -> Vector3:
		if par:
			_par_lock.lock()
			var held := super(at)
			_par_lock.unlock()
			return held
		var t_lap := ArenaFrameProbe.lap_start()
		var spot := super(at)
		ArenaFrameProbe.lap(&"bot_walkable", t_lap)
		return spot

	func drops() -> Array:
		if par:
			_par_lock.lock()
			var held := _drops_now()
			_par_lock.unlock()
			return held
		var t_lap := ArenaFrameProbe.lap_start()
		var lying := _drops_now()
		ArenaFrameProbe.lap(&"bot_drops", t_lap)
		return lying

	## The drop list, built once a tick: nothing moves a drop while the brains of a tick think (the callers only read it).
	func _drops_now() -> Array:
		if _tick < 0 or _drops_tick != _tick:
			_drops_held = super.drops()
			_drops_tick = _tick
		return _drops_held

	func ladder(ride_id: int) -> Dictionary:
		if par:
			_par_lock.lock()
			var held := super(ride_id)
			_par_lock.unlock()
			return held
		return super(ride_id)

	## A body as the map moves it: a live player's, or the arena's own.
	## arena_npcs reaches the map, and so this file again; it is loaded when first asked for.
	func _npcs() -> GDScript:
		return load(ArenaPaths.rebase("res://game/arena_npcs.gd")) as GDScript

	func _body_tunables() -> DotFpsTunables:
		for p: Object in game.call("players"):
			var controller: Variant = p.get("controller")
			var tunables: Variant = (controller as Object).get("tunables") if controller is Object else null
			if tunables is DotFpsTunables:
				return tunables
		return (load(ArenaPaths.rebase("res://game/arena_player.gd")) as GDScript).call("arena_tunables")

	func _graph_for_map() -> DotNpcNavGraph:
		var map: Variant = game.get("map")
		if not (map is Object) or not (map as Object).has_method(&"is_imported") or bool((map as Object).call(&"is_imported")):
			return null
		if _graph != null and _graph_map == map:
			return _graph
		_graph_map = map
		_graph = null
		var horde: Variant = game.get("horde")
		var data: Variant = (horde as Object).get("nav") if horde is Object else null
		if not (data is DotNpcNavData) or not (data as DotNpcNavData).matches(_npcs().digest_of(map)):
			data = _npcs().nav_for(map)
		var graph := DotNpcNavGraph.new()
		if (data as DotNpcNavData).validate().ok and graph.rebuild(data).ok:
			_graph = graph
		return _graph
