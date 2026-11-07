extends RefCounted

## What a bot does with a tick, as the same two commands a client sends: dot-bot's brain,
## fed from this game. One brain for every bot arena has, solo and on a server.
##
## [b]Commands, not a second simulation.[/b] A bot is an [ArenaPlayer] like anybody else and
## moves through the same controller, shoots through the same arsenal and is hit by the same
## lag-compensated trace; all this decides is what it would have pressed. That keeps a bot
## from ever doing something a player could not -- no walking through walls, no shot the
## arsenal would refuse -- and keeps the tick order exactly what it is for people.
##
## [b]Solo used to be a test fixture.[/b] The offline client drove its bots with the
## `headless_match` aimbot: face the nearest player through any wall, hold the trigger under
## 40 m, no reaction and no aim error. A first play test on Windows died twelve times in ninety
## seconds to it, killed from 30 to 40 m within a second, while the brain a server ran (sight,
## reaction, aim error, range, strafing) was never met by anybody playing solo. Both now ask
## [DotBotBrain], so `bot_difficulty` means the same thing in both.
##
## [b]What the brain is told[/b] ([World], a [DotBotWorld]): every player as a
## [DotBotContact], the combat trace's line of sight, the map's spawns as places to roam, a
## route between them over the horde's navigation graph (built-in maps; an imported map has
## none, and is walked straight), how fast the held weapon's projectile flies (so a rocket
## is led), a sound for every shot fired (from [signal ArenaPlayer.used]) and who hit whom
## (from [signal ArenaGame.hit_confirmed]). Nothing else, so it cannot see through a wall.
##
## [b]A grenade is four commands, not a button.[/b] Arena has no throw key: a frag is slot 5,
## drawn, held to cook and released. When the brain says [member DotBotIntent.throw], [Mind]
## switches to the throwable, holds the trigger for [constant COOK_SEC], lets go along the
## view the brain chose, and switches back to what it held -- the same presses a person makes.
##
## [b]Deterministic per bot[/b]: the brain's randomness is seeded from the bot's id, and its
## clock is the game's tick, so two runs of the same inputs play the same bots. Not on an
## imported map, whose routes start when its background bake lands ([method World._nav_for_map]).
##
## [b]Ramps are ridden.[/b] On a combat surf map with a surf cache the routes cross ride edges
## between the platforms and walk through the map's teleports, and a bot whose route reaches a
## ride hands its legs to the surf pilot until it lands, aiming and shooting as before
## ([code]arena_surf.gd[/code], loaded only on a shell with dot-bot 4 and
## dot-player-controller 3).

const ArenaContent := preload("arena_content.gd")
const CHANNEL := "arena.bots"

const ArenaPlayer := preload("arena_player.gd")
const ArenaNpcs := preload("arena_npcs.gd")
const ArenaPaths := preload("arena_paths.gd")
const ArenaFrameProbe := preload("arena_frame_probe.gd")
const ArenaBotBrain := preload("arena_bot_brain.gd")
const ArenaHullGrid := preload("arena_hull_grid.gd")

## The behaviour of a weapon whose shot flies (a rocket, a bolt); every other one is led as
## hitscan. A path, because the pack names behaviours by path (see [DotWeaponDef]).
const PROJECTILE_BEHAVIOUR := "dot_weapon_projectile.gd"

## How long a bot cooks a grenade before letting go, seconds. Well inside the frag's 3 s fuse.
const COOK_SEC := 0.3

## How long a throw may take from the switch to the switch back before it is given up, seconds.
const THROW_GIVE_UP_SEC := 2.5

## Where the world is kept on the game.
const WORLD_META := &"arena_bot_world"

## A drop up to this many metres gets a reverse climb edge on a team map, and the ids those take.
const LEDGE_CLIMB_MAX := 2.2
const LEDGE_CLIMB_ID := 5000000

## Height of the eye and of a target's chest above its feet, metres.
const EYE := 1.6
const CHEST := 1.25


## The chest a bot aims at on the avatar body in play: CHEST scaled from the 1.8 m body it was written for.
static func chest_height() -> float:
	return CHEST * ArenaPlayer.stand_height() / 1.8


## The eye of the avatar body in play.
static func eye_height() -> float:
	return ArenaPlayer.eye_height()


## One bot's memory between ticks. Kept by the caller, one per bot.
class Mind:
	extends RefCounted
	var brain: DotBotBrain = null
	var seed: int = 0
	## The throw in hand: 0 none, then [constant THROW_DRAW], [constant THROW_COOK],
	## [constant THROW_RELEASE], [constant THROW_BACK].
	var throw_stage: int = 0
	var throw_view: Vector2 = Vector2.ZERO
	var throw_back: int = 0
	var throw_at: int = 0
	var throw_cook_from: int = 0
	## The ride under way (dot-bot's DotBotSurfRide, untyped so an older shell still compiles
	## this), or null.
	var ride: Variant = null
	## Where the bot was last tick, to see a teleport.
	var last_position: Vector3 = Vector3.INF
	## The commands of the last tick the brain thought, repeated on the ticks it coasts (see [constant THINK_EVERY]).
	var last_move: DotFpsCommand = null
	var last_fire: DotWeaponCommand = null
	## Whether nobody was within [member think_near] metres at the last think.
	var far: bool = false
	## The view the last think moved from and to, which the coast ticks walk along.
	var view_from: Vector2 = Vector2.ZERO
	var view_to: Vector2 = Vector2.ZERO
	## Whether the last think left the bot free to coast.
	var coasting: bool = false
	## The tick of the last think, so a think that follows a coast knows its brain turned for several ticks at once.
	var last_think_tick: int = -1
	## Between [method think_begin] and [method think_finish] (see ArenaBotThreads): the body's contact, the world and what the brain decided.
	var t_me: DotBotContact = null
	var t_world: Object = null
	var t_intent: DotBotIntent = null


## Ticks between rebuilds of a contact's loadout (see [method World._loadout_of]).
const LOADOUT_EVERY := 4

## Think-rate staggering (cvar `bot_think_every`, `bot_think_near`). A bot with no enemy within
## [member think_near] metres, no target, no ride, no throw, a plain walk and nothing pressed
## runs its brain one tick in [member think_every], offset by its id so the thinkers spread over
## the ticks, and repeats its last commands in between. 1 turns it off. Far from a fight a
## bot's brain only picks a waypoint and walks it; the sight, aim and fight code that costs
## most is for the nearby enemy, which gets every tick.
static var think_every: int = 0
## Players above which `think_every` 0 (auto) staggers by two: up to a 16-player match every bot thinks every tick.
const AUTO_STAGGER_ABOVE := 16
## The stagger in force this tick (1 = none): `think_every`, or what auto picks for the player count.
static var _every: int = 1
static var think_near: float = 30.0

## Further than this in one tick is a teleport, metres (a fall at the 3500 u/s limit is under 1).
const TELEPORT_JUMP := 4.0
const THROW_DRAW := 1
const THROW_COOK := 2
const THROW_RELEASE := 3
const THROW_BACK := 4


## What the brain may know of this game.
class World:
	extends DotBotWorld

	var game: Object = null
	var tick_rate: float = float(ArenaContent.TICK_RATE)
	var brains: Dictionary = {}
	var _loadouts: Dictionary = {}
	var _tick: int = -1
	var _contacts: Array = []
	var _by_id: Dictionary = {}
	var _players: Dictionary = {}
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
	## The body tunables of this tick, looked up once for all contacts (the lookup walks every player).
	var _tunables: DotFpsTunables = null
	## The live contacts filed by cell of [member ArenaBots.think_near] metres (key -> contacts), for [method ArenaBots._nobody_near]; empty cell size: not built.
	var near_cells: Dictionary = {}
	var near_cell: float = 0.0
	## [member ArenaBots.think_near], set by the thinking bot before [method refresh].
	var near_reach: float = 0.0

	## Parallel think (cvar `bot_threads`, ArenaBotThreads): while true, brains on worker threads ask this world, whose
	## sight and wall rays then use queries of their own on [member _par_space] and whose other answers take [member _par_lock].
	var par: bool = false
	var _par_space: PhysicsDirectSpaceState3D = null
	var _par_trace: DotTrace = null
	var _par_physics: bool = false
	var _par_glass: bool = false
	var _par_lock := Mutex.new()
	## GodotPhysics3D answers every query out of buffers the space shares, so rays go one at a time.
	var _ray_lock := Mutex.new()
	## Any player's arsenal, taken on the main thread (walking the roster is not for a worker).
	var _par_arsenal: Object = null
	## The trace's ray observer (dropped weapons nudged by a shot) is called on the main thread: a worker's wall
	## rays are logged per job and replayed in job order by [method par_end].
	var _par_observe: bool = false
	var _par_job: Dictionary = {}
	var _par_rays: Dictionary = {}

	func _arsenal_for_drops() -> Object:
		return _par_arsenal if par else _any_arsenal(game)

	## Which job (brain) the calling thread works on, for the log of its wall rays.
	func par_job(job: int) -> void:
		if _par_observe:
			_par_lock.lock()
			_par_job[OS.get_thread_caller_id()] = job
			_par_lock.unlock()

	func _init(p_game: Object) -> void:
		game = p_game
		if game.has_signal(&"hit_confirmed"):
			game.connect(&"hit_confirmed", _on_hit)
		if game.has_signal(&"player_added"):
			game.connect(&"player_added", _hear_player)
		for p in game.call("players"):
			_hear_player(p)
		walkable_fn = _walkable_near
		DotBotArms.wire(self, func() -> Variant: return p_game.get("weapon_drops"), func() -> Object: return _arsenal_for_drops())

	## Rebuilds the contacts once a tick, however many bots ask.
	func refresh(tick: int, rate: float) -> void:
		tick_rate = maxf(rate, 1.0)
		if tick == _tick:
			return
		_tick = tick
		_contacts.clear()
		_by_id.clear()
		_players.clear()
		_tunables = null
		var teams := _team_mode()
		for p: ArenaPlayer in game.call("players"):
			var c := DotBotContact.new()
			c.id = p.player_id
			c.eye_height = ArenaPlayer.eye_height()
			c.aim_height = CHEST * ArenaPlayer.stand_height() / 1.8
			c.alive = p.is_alive()
			c.team = p.team if teams else 0
			if p.controller != null:
				c.position = p.controller.state.position
				c.velocity = p.controller.state.velocity
				c.view_yaw = p.controller.state.yaw
				c.view_pitch = p.controller.state.pitch
				_motion_of(c, p.controller.state)
			else:
				c.position = p.global_position
			if p.health != null and p.health.max_health > 0.0:
				c.health = p.health.health / p.health.max_health
			c.loadout = _loadout_of(p, tick)
			_contacts.append(c)
			_by_id[c.id] = c
			_players[c.id] = p
		near_cells.clear()
		near_cell = 0.0
		if ArenaHullGrid.enabled and near_reach > 0.0 and _contacts.size() > 16:
			near_cell = near_reach
			for c: DotBotContact in _contacts:
				if c.alive:
					var k := near_key(c.position.x, c.position.z, near_cell)
					var cell: Variant = near_cells.get(k)
					if cell == null:
						near_cells[k] = [c]
					else:
						(cell as Array).append(c)

	static func near_key(x: float, z: float, cell: float) -> int:
		return (int(floorf(x / cell)) + 4096) * 8192 + int(floorf(z / cell)) + 4096

	## What the player carries, rated, rebuilt one tick in [constant LOADOUT_EVERY] (offset by id)
	## and repeated between: it is 33 slot reads and ratings per player per tick for what only a
	## pickup, a shot or a reload changes, and a bot picks a weapon over tens of ticks.
	func _loadout_of(p: ArenaPlayer, tick: int) -> Dictionary:
		var held: Variant = _loadouts.get(p.player_id)
		if held is Array and (tick + p.player_id) % LOADOUT_EVERY != 0 and tick >= (held as Array)[0] and tick - (held as Array)[0] < LOADOUT_EVERY:
			return (held as Array)[1]
		var made := DotBotArms.loadout_of(p.arsenal)
		_loadouts[p.player_id] = [tick, made]
		return made

	## Arsenal of any player: its catalogue knows every weapon lying about.
	static func _any_arsenal(g: Object) -> Object:
		for p: ArenaPlayer in g.call("players"):
			return p.arsenal
		return null

	## What the bot's body is doing, and whether the game would honour an air-jump press now.
	func _motion_of(c: DotBotContact, state: DotFpsState) -> void:
		c.grounded = state.mode == DotFpsState.Mode.GROUND
		c.sliding = state.slide_time >= 0.0
		c.wall_running = state.wall_run_time >= 0.0
		if _tunables == null:
			_tunables = _body_tunables()
		var tunables := _tunables
		c.air_jump_ready = tunables.launch_enabled and state.launch_cooldown_left <= 0.0

	## The nearest map surface along a direction, for the walls a bot could run beside.
	## Gets the world ready for brains on other threads; false when the game's trace is one this cannot ask from them.
	## Starts what a worker would otherwise start (the imported map's mesh bake) on the calling thread first.
	func par_begin() -> bool:
		var combat: Variant = game.get("combat")
		var trace: Variant = (combat as Object).get("trace") if combat is Object else null
		if not trace is DotTrace:
			return false
		_par_trace = trace as DotTrace
		_par_observe = _par_trace.ray_observer.is_valid()
		_par_job.clear()
		_par_rays.clear()
		_par_arsenal = _any_arsenal(game)
		_par_physics = false
		_par_space = null
		if trace is DotTracePhysics:
			var bound: Variant = (trace as Object).get("_world")
			if not bound is World3D:
				return false
			_par_space = (bound as World3D).direct_space_state
			if _par_space == null:
				return false
			_par_physics = true
		elif not trace is DotTraceFlat:
			return false
		# The jail glass rule applies on a map with a collision root, as _line_of_sight has it.
		_par_glass = false
		var rules: Variant = game.get("glass_rules")
		if rules is DotMapGlassSight and (rules as DotMapGlassSight).block_sight:
			var map: Variant = game.get("map")
			var root: Variant = (map as Object).get("collision_root") if map is Object else null
			if root is Node3D and (root as Node3D).is_inside_tree():
				if _par_space == null:
					return false
				_par_glass = true
		var _nav_warm := _nav_for_map()
		var _surf_warm := surf_for_map()
		# The brain prunes both each think; once here, theirs find nothing to remove.
		prune_sight_blockers(now())
		var _heard := sounds_after(1 << 60, now())
		par = true
		return true

	func par_end() -> void:
		par = false
		if _par_observe:
			var jobs := _par_rays.keys()
			jobs.sort()
			for job: int in jobs:
				for r: Array in _par_rays[job]:
					_par_trace.ray_observer.call(r[0], r[1], r[2])
		_par_rays.clear()
		_par_arsenal = null
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

	func _los_par(from: Vector3, to: Vector3) -> bool:
		var rules: Variant = game.get("glass_rules")
		if _par_glass:
			_ray_lock.lock()
			var shut := (rules as DotMapGlassSight).blocks(_par_space, from, to)
			_ray_lock.unlock()
			if shut:
				return false
		if not _par_physics:
			return _par_trace.line_of_sight(from, to)
		var distance := from.distance_to(to)
		if distance <= 0.0001:
			return true
		var glass := _glass_of_trace()
		var base: int = _par_trace.collision_mask
		return _ray_par(from, from + (to - from) / distance * distance, (base & ~glass.glass_mask) if glass != null else base).is_empty()

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

	func now() -> float:
		return float(maxi(_tick, 0)) / tick_rate

	func contact(id: int) -> DotBotContact:
		return _by_id.get(id)

	func contacts() -> Array:
		return _contacts

	func line_of_sight(from: Vector3, to: Vector3) -> bool:
		if par:
			return _los_par(from, to)
		var t_los := Time.get_ticks_usec()
		var seen := _line_of_sight(from, to)
		ArenaFrameProbe.add(&"bot_los", t_los)
		return seen

	func _line_of_sight(from: Vector3, to: Vector3) -> bool:
		var combat: Variant = game.get("combat")
		var trace: Variant = (combat as Object).get("trace") if combat is Object else null
		var rules: Variant = game.get("glass_rules")
		# Bots inside the jail cell cannot see out through its glass; the trace itself ignores that layer for sight.
		if rules is DotMapGlassSight and (rules as DotMapGlassSight).block_sight:
			var map: Variant = game.get("map")
			var root: Variant = (map as Object).get("collision_root") if map is Object else null
			if root is Node3D and (root as Node3D).is_inside_tree() \
					and (rules as DotMapGlassSight).blocks((root as Node3D).get_world_3d().direct_space_state, from, to):
				return false
		if trace is DotTrace:
			return (trace as DotTrace).line_of_sight(from, to)
		return true

	const SPAWN_THINNING := 25.0
	const ROAM_PLACES := 24

	static func _near_any(points: PackedVector3Array, at: Vector3, within: float) -> bool:
		for point in points:
			if point.distance_to(at) < within:
				return true
		return false

	## Spawns and landings, repeated where people stand once the game has recorded enough of it.
	func waypoints() -> PackedVector3Array:
		if par:
			_par_lock.lock()
			var held := _waypoints()
			_par_lock.unlock()
			return held
		return _waypoints()

	func _waypoints() -> PackedVector3Array:
		var out := PackedVector3Array()
		var map: Variant = game.get("map")
		var spawns: Array = (map as Object).get("spawns") if map is Object else []
		var surf := surf_for_map()
		for spawn: Transform3D in spawns:
			# A combat surf map has dozens of spawns on one platform (surf_snipers_island: 48 on
			# one island); each as a waypoint outweighs the few landings and ramp starts that are
			# the only places a ride is taken from, and the bots never rode. With ride edges
			# linked, spawns closer than this to one kept are one place.
			if surf != null and out.size() > 0 and _near_any(out, spawn.origin, SPAWN_THINNING):
				continue
			out.append(spawn.origin)
		if surf != null:
			out.append_array(surf.call(&"landing_points"))
		var stats: Variant = game.get("demo_stats")
		return (stats as Object).call(&"weight_waypoints", out) if stats is Object else out

	## A route that may ride a ramp or walk through a teleport: the mesh's own answer once the
	## map's ride edges are linked into it, the walked corners otherwise.
	func route_detail(from: Vector3, to: Vector3) -> Dictionary:
		if par:
			_par_lock.lock()
			var held := _route_detail(from, to)
			_par_lock.unlock()
			return held
		return _route_detail(from, to)

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

	## The mesh for an imported map, the bake started on the first route asked on it; null on a
	## built-in map.
	##
	## [b]Not the graph.[/b] The graph is laid over a box list, and an imported map's solid is
	## hundreds of convex brushes with ramps and ledges at every height, so its bots walked
	## straight at each other through the walls. dot-bot's [DotBotNav] bakes what a body can
	## stand on from those brushes ([member ArenaMap.collision_root], on every machine that
	## simulates). [b]In the background[/b], because the two default surf maps took 2 to 3 s
	## to bake against a tenth of a second for the whole map change: bots walk straight for
	## those seconds and route after.
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

	## The nearest standable point of the mesh, for a bot that cannot free itself; INF off it.
	func _walkable_near(at: Vector3) -> Vector3:
		var nav := _nav_for_map()
		return nav.closest(at) if nav != null and nav.is_ready() else Vector3.INF

	func walkable_near(at: Vector3) -> Vector3:
		if par:
			_par_lock.lock()
			var held := super(at)
			_par_lock.unlock()
			return held
		return super(at)

	func drops() -> Array:
		if par:
			_par_lock.lock()
			var held := super()
			_par_lock.unlock()
			return held
		return super()

	func ladder(ride_id: int) -> Dictionary:
		if par:
			_par_lock.lock()
			var held := super(ride_id)
			_par_lock.unlock()
			return held
		return super(ride_id)

	## Whether an imported map's mesh is still baking; false on a built-in map or once landed.
	func is_route_pending() -> bool:
		return _nav != null and _nav_map == game.get("map") and _nav.is_baking()

	## A body as the map moves it: a live player's, or the arena's own.
	func _body_tunables() -> DotFpsTunables:
		for p: Object in game.call("players"):
			var controller: Variant = p.get("controller")
			var tunables: Variant = (controller as Object).get("tunables") if controller is Object else null
			if tunables is DotFpsTunables:
				return tunables
		return ArenaPlayer.arena_tunables()

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
		if not (data is DotNpcNavData) or not (data as DotNpcNavData).matches(ArenaNpcs.digest_of(map)):
			data = ArenaNpcs.nav_for(map)
		var graph := DotNpcNavGraph.new()
		if (data as DotNpcNavData).validate().ok and graph.rebuild(data).ok:
			_graph = graph
		return _graph

	## How fast the held weapon's shot flies, m/s; 0 for hitscan, a swing or a throw.
	func projectile_speed(shooter: DotBotContact) -> float:
		if par:
			_par_lock.lock()
			var held := _projectile_speed(shooter)
			_par_lock.unlock()
			return held
		return _projectile_speed(shooter)

	func _projectile_speed(shooter: DotBotContact) -> float:
		var p: ArenaPlayer = _players.get(shooter.id) if shooter != null else null
		var def: DotWeaponDef = p.arsenal.current_def() if p != null and p.arsenal != null else null
		if def == null or not def.behaviour_path.ends_with(PROJECTILE_BEHAVIOUR) or not (def.tuning is DotWeaponBallistics):
			return 0.0
		return (def.tuning as DotWeaponBallistics).speed

	func _team_mode() -> bool:
		var mode: Variant = game.get("mode")
		return mode is Object and (mode as Object).has_method("is_team_mode") and bool((mode as Object).call("is_team_mode"))

	## Every shot is a sound; a swing or a throw is a quieter one.
	func _hear_player(p: Object) -> void:
		if not (p is ArenaPlayer) or p.has_meta(&"arena_bot_heard"):
			return
		p.set_meta(&"arena_bot_heard", true)
		var body := p as ArenaPlayer
		body.used.connect(func(outcome: DotWeaponOutcome) -> void:
			if outcome == null or not outcome.used:
				return
			var loud := 1.0 if not outcome.shots.is_empty() or not outcome.spawns.is_empty() else 0.3
			emit_sound(body.muzzle_position(), loud, body.player_id, now())
		)

	func _on_hit(attacker: int, victim: int, _amount: float, _point: Vector3, _headshot: bool, _lethal: bool) -> void:
		var brain: DotBotBrain = brains.get(victim)
		if brain == null:
			return
		var from := contact(attacker)
		brain.hurt(from.eye() if from != null else Vector3.INF, now())


## The world on [param game], made the first time a bot asks.
static func world_for(game: Object) -> World:
	if game.has_meta(WORLD_META):
		var held: Variant = game.get_meta(WORLD_META)
		if held is World:
			return held
	var made := World.new(game)
	game.set_meta(WORLD_META, made)
	return made


## [move, fire] for [param bot] this tick.
static func think(game: Object, bot: ArenaPlayer, mind: Mind, tick: int, tick_rate: float) -> Array:
	var early := think_begin(game, bot, mind, tick, tick_rate)
	if not early.is_empty():
		return early
	var t_brain := Time.get_ticks_usec()
	mind.t_intent = mind.brain.think(mind.t_me, mind.t_world, mind.t_world.now())
	ArenaFrameProbe.add(&"bot_brain", t_brain)
	return think_finish(game, bot, mind, tick, tick_rate)


## The part of [method think] before the brain runs, on the main thread: the commands of a tick the bot coasts (or
## of no game), else an empty array with [member Mind.t_me] and [member Mind.t_world] set for the brain.
static func think_begin(game: Object, bot: ArenaPlayer, mind: Mind, tick: int, tick_rate: float) -> Array:
	if game == null or bot == null:
		return [DotFpsCommand.new(), DotWeaponCommand.new()]

	_every = think_every if think_every > 0 else (2 if game.player_ids().size() > AUTO_STAGGER_ABOVE else 1)
	if _every > 1 and _coasts(mind, tick):
		return _coast(mind, tick)

	var world := world_for(game)
	var t_refresh := Time.get_ticks_usec()
	world.near_reach = think_near
	world.refresh(tick, tick_rate)
	ArenaFrameProbe.add(&"bot_refresh", t_refresh)

	if mind.brain == null:
		mind.brain = ArenaBotBrain.new(mind.seed if mind.seed != 0 else bot.player_id, DotBotSettings.of(game))
		# The bot's trick gates follow the motor: 1.18 times the minimum, as the old 6.5 was of 5.5.
		var body_tunables: Variant = bot.controller.get("tunables") if bot.controller != null else null
		if body_tunables is DotFpsTunables:
			mind.brain.tricks.slide_speed = body_tunables.slide_min_speed * 1.18
			mind.brain.tricks.wall_run_speed = body_tunables.wall_run_min_speed * 1.17
	world.brains[bot.player_id] = mind.brain

	var me := world.contact(bot.player_id)
	# A teleport carries the bot further in a tick than anything walks or flies, and its route was
	# laid from where it stood: walked on, the old corners lead it off the pad it landed on. The
	# brain is told as it is when a ride ends, and plans from here (a ride the pilot has is not cut).
	if mind.ride == null and mind.last_position != Vector3.INF and me.position.distance_to(mind.last_position) > TELEPORT_JUMP:
		mind.brain.ride_ended(true)
	mind.last_position = me.position
	mind.t_me = me
	mind.t_world = world
	return []


## The part of [method think] after the brain ran, on the main thread: the bot's commands from [member Mind.t_intent].
static func think_finish(_game: Object, bot: ArenaPlayer, mind: Mind, tick: int, tick_rate: float) -> Array:
	var move := DotFpsCommand.new()
	var fire := DotWeaponCommand.new()
	var world: World = mind.t_world
	var me: DotBotContact = mind.t_me
	var intent: DotBotIntent = mind.t_intent
	mind.t_me = null
	mind.t_world = null
	mind.t_intent = null
	var t_after := Time.get_ticks_usec()
	var surf := world.surf_for_map()
	if surf != null:
		surf.call(&"steer", bot, mind, intent, tick, tick_rate)
	elif mind.ride != null:
		mind.ride = null
	intent.write_move(move, "BUTTON_USER_0")
	intent.write_fire(fire)
	_throw(bot, mind, intent, move, fire, tick, tick_rate)
	move.sanitise()
	fire.sanitise()
	ArenaFrameProbe.add(&"bot_after", t_after)
	mind.far = _every > 1 and _nobody_near(me, world)
	# Only a think on the bot's own beat starts a coast, so the coast's steps count from it.
	mind.coasting = mind.far and (tick + mind.seed) % _every == 0 and _coastable(mind, intent, move, fire)
	if mind.coasting:
		# The brain turned for _every ticks at once; spread over them, so no tick turns faster than bot_turn_rate.
		mind.view_to = Vector2(move.yaw, move.pitch)
		# From the view the body has, which a respawn or a teleport may have turned since the last command.
		var from := Vector2(me.view_yaw, me.view_pitch)
		mind.view_from = from
		move.yaw = from.x + _turn(from.x, mind.view_to.x) / float(_every)
		move.pitch = from.y + (mind.view_to.y - from.y) / float(_every)
	elif _every > 1 and mind.throw_stage == 0 and mind.last_think_tick >= 0 and tick - mind.last_think_tick > 1:
		# A think after coasted ticks: the brain's turn limit is bot_turn_rate times the time since its last
		# think, so it turned for the whole gap at once (twice bot_turn_rate in one tick, the headless_bots
		# turn-rate failure). Held to one tick's turn from the body's view; the aim closes over the next ticks.
		var rate := mind.brain.settings.profile.turn_rate / tick_rate
		var body := Vector2(me.view_yaw, me.view_pitch)
		move.yaw = body.x + clampf(_turn(body.x, move.yaw), -rate, rate)
		move.pitch = body.y + clampf(move.pitch - body.y, -rate, rate)
	mind.last_think_tick = tick
	mind.last_move = move.duplicate_command()
	mind.last_fire = fire.duplicate_command()
	return [move, fire]


## Degrees from [param a] to [param b] the short way round.
static func _turn(a: float, b: float) -> float:
	return fposmod(b - a + 180.0, 360.0) - 180.0


## The commands of a tick the brain sits out: the last ones, with the view carried on towards where the last think turned it.
static func _coast(mind: Mind, tick: int) -> Array:
	var step := (tick + mind.seed) % _every
	var move := mind.last_move.duplicate_command()
	var fraction := float(step + 1) / float(_every)
	move.yaw = mind.view_from.x + _turn(mind.view_from.x, mind.view_to.x) * fraction
	move.pitch = mind.view_from.y + (mind.view_to.y - mind.view_from.y) * fraction
	mind.last_move.yaw = move.yaw
	mind.last_move.pitch = move.pitch
	return [move, mind.last_fire.duplicate_command()]


## Whether a bot that just thought may sit out the next ticks: nothing in hand but a walk.
static func _coastable(mind: Mind, intent: DotBotIntent, move: DotFpsCommand, fire: DotWeaponCommand) -> bool:
	return mind.ride == null and mind.throw_stage == 0 and intent.target_id < 0 and intent.state != &"dead" \
		and move.buttons == 0 and fire.buttons == 0


## Whether this tick repeats the last commands rather than think. See [member think_every].
static func _coasts(mind: Mind, tick: int) -> bool:
	if not mind.far or mind.last_move == null or mind.brain == null or mind.ride != null or mind.throw_stage != 0:
		return false
	if (tick + mind.seed) % _every == 0:
		return false
	return mind.coasting


## Whether no live enemy of [param me] is within [member think_near] metres.
static func _nobody_near(me: DotBotContact, world: World) -> bool:
	var near_sq := think_near * think_near
	if world.near_cell > 0.0 and world.near_cell == think_near:
		var cx := int(floorf(me.position.x / think_near)) + 4096
		var cz := int(floorf(me.position.z / think_near)) + 4096
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var cell: Variant = world.near_cells.get((cx + dx) * 8192 + cz + dz)
				if cell == null:
					continue
				for item: DotBotContact in cell:
					if item.id != me.id and me.is_enemy(item) and item.position.distance_squared_to(me.position) < near_sq:
						return false
		return true
	for item: DotBotContact in world.contacts():
		if item.alive and item.id != me.id and me.is_enemy(item) and item.position.distance_squared_to(me.position) < near_sq:
			return false
	return true


## Turns the brain's [member DotBotIntent.throw] into the presses a person makes: draw the
## throwable, cook it, let go along the view the brain chose, and draw what was held before.
## While a throw is under way it owns the trigger, the slot and the view; the legs stay the
## brain's.
static func _throw(bot: ArenaPlayer, mind: Mind, intent: DotBotIntent, move: DotFpsCommand, fire: DotWeaponCommand, tick: int, tick_rate: float) -> void:
	var arsenal := bot.arsenal
	if arsenal == null or not bot.is_alive():
		mind.throw_stage = 0
		return
	if mind.throw_stage == 0:
		if not intent.throw or not _has_throwable(arsenal):
			return
		mind.throw_stage = THROW_DRAW
		mind.throw_view = Vector2(intent.yaw, intent.pitch)
		mind.throw_back = arsenal.current_slot()
		mind.throw_at = tick

	var thrown := AwWeaponIds.thrown_slot()
	if tick - mind.throw_at > int(THROW_GIVE_UP_SEC * tick_rate) and mind.throw_stage < THROW_RELEASE:
		mind.throw_stage = THROW_RELEASE if mind.throw_stage == THROW_COOK else THROW_BACK

	fire.set_button(DotWeaponCommand.BUTTON_ATTACK, false)
	match mind.throw_stage:
		THROW_DRAW:
			fire.slot = thrown
			if arsenal.current_slot() == thrown and not arsenal.is_switching():
				mind.throw_stage = THROW_COOK
				mind.throw_cook_from = tick
				fire.set_button(DotWeaponCommand.BUTTON_ATTACK, true)
		THROW_COOK:
			fire.set_button(DotWeaponCommand.BUTTON_ATTACK, true)
			if tick - mind.throw_cook_from >= maxi(1, int(COOK_SEC * tick_rate)):
				mind.throw_stage = THROW_RELEASE
		THROW_RELEASE:
			# The trigger up on this tick is the throw.
			mind.throw_stage = THROW_BACK
		THROW_BACK:
			var back := mind.throw_back if mind.throw_back > 0 and mind.throw_back != thrown and arsenal.has_slot(mind.throw_back) else 0
			if back > 0 and arsenal.current_slot() != back:
				fire.slot = back
			if back == 0 or arsenal.current_slot() == back or tick - mind.throw_at > int(THROW_GIVE_UP_SEC * tick_rate) * 2:
				mind.throw_stage = 0

	if mind.throw_stage in [THROW_DRAW, THROW_COOK, THROW_RELEASE]:
		# Looking where the brain lobbed it until it is gone.
		for command: Object in [move, fire]:
			command.set(&"yaw", mind.throw_view.x)
			command.set(&"pitch", mind.throw_view.y)


## Whether [param arsenal] holds a throwable it can pay for.
static func _has_throwable(arsenal: DotWeaponArsenal) -> bool:
	var slot := arsenal.slot_at(AwWeaponIds.thrown_slot())
	if slot == null or slot.def == null:
		return false
	var def := slot.def
	if not def.uses_ammo():
		return true
	if def.uses_magazine():
		return slot.magazine >= def.cost_per_use
	return def.infinite_reserve or arsenal.ammo().has(def.ammo_type, def.cost_per_use)


## Forgets a bot that left, so its brain is not told about hits any more.
static func forget(game: Object, id: int) -> void:
	if game != null and game.has_meta(WORLD_META):
		var held: Variant = game.get_meta(WORLD_META)
		if held is World:
			(held as World).brains.erase(id)
			(held as World)._loadouts.erase(id)
