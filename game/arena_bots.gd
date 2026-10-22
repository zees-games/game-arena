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

const CHANNEL := "arena.bots"

const ArenaPlayer := preload("arena_player.gd")
const ArenaNpcs := preload("arena_npcs.gd")
const ArenaPaths := preload("arena_paths.gd")

## The behaviour of a weapon whose shot flies (a rocket, a bolt); every other one is led as
## hitscan. A path, because the pack names behaviours by path (see [DotWeaponDef]).
const PROJECTILE_BEHAVIOUR := "dot_weapon_projectile.gd"

## How long a bot cooks a grenade before letting go, seconds. Well inside the frag's 3 s fuse.
const COOK_SEC := 0.3

## How long a throw may take from the switch to the switch back before it is given up, seconds.
const THROW_GIVE_UP_SEC := 2.5

## Where the world is kept on the game.
const WORLD_META := &"arena_bot_world"

## Height of the eye and of a target's chest above its feet, metres.
const EYE := 1.6
const CHEST := 1.25


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
	var tick_rate: float = 64.0
	var brains: Dictionary = {}
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

	func _init(p_game: Object) -> void:
		game = p_game
		if game.has_signal(&"hit_confirmed"):
			game.connect(&"hit_confirmed", _on_hit)
		if game.has_signal(&"player_added"):
			game.connect(&"player_added", _hear_player)
		for p in game.call("players"):
			_hear_player(p)

	## Rebuilds the contacts once a tick, however many bots ask.
	func refresh(tick: int, rate: float) -> void:
		tick_rate = maxf(rate, 1.0)
		if tick == _tick:
			return
		_tick = tick
		_contacts.clear()
		_by_id.clear()
		_players.clear()
		var teams := _team_mode()
		for p: ArenaPlayer in game.call("players"):
			var c := DotBotContact.new()
			c.id = p.player_id
			c.eye_height = EYE
			c.aim_height = CHEST
			c.alive = p.is_alive()
			c.team = p.team if teams else 0
			if p.controller != null:
				c.position = p.controller.state.position
				c.velocity = p.controller.state.velocity
				c.view_yaw = p.controller.state.yaw
				c.view_pitch = p.controller.state.pitch
			else:
				c.position = p.global_position
			if p.health != null and p.health.max_health > 0.0:
				c.health = p.health.health / p.health.max_health
			_contacts.append(c)
			_by_id[c.id] = c
			_players[c.id] = p

	func now() -> float:
		return float(maxi(_tick, 0)) / tick_rate

	func contact(id: int) -> DotBotContact:
		return _by_id.get(id)

	func contacts() -> Array:
		return _contacts

	func line_of_sight(from: Vector3, to: Vector3) -> bool:
		var combat: Variant = game.get("combat")
		var trace: Variant = (combat as Object).get("trace") if combat is Object else null
		if trace is DotTrace:
			return (trace as DotTrace).line_of_sight(from, to)
		return true

	const SPAWN_THINNING := 25.0

	static func _near_any(points: PackedVector3Array, at: Vector3, within: float) -> bool:
		for point in points:
			if point.distance_to(at) < within:
				return true
		return false

	func waypoints() -> PackedVector3Array:
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
		return out

	## A route that may ride a ramp or walk through a teleport: the mesh's own answer once the
	## map's ride edges are linked into it, the walked corners otherwise.
	func route_detail(from: Vector3, to: Vector3) -> Dictionary:
		var surf := surf_for_map()
		if surf != null:
			return surf.call(&"route_detail", from, to)
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
		if DotAddonApi.build_level("dot_bot") < 4 or DotAddonApi.build_level("dot_player_controller") < 3:
			return null
		var surf_script := load(ArenaPaths.rebase("res://game/arena_surf.gd")) as GDScript
		_surf = surf_script.call(&"load_for", game.get("map"), nav) if surf_script != null else null
		return _surf

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
		var body := _body_tunables()
		var source: Node3D = (map as Object).call(&"nav_source") if (map as Object).has_method(&"nav_source") else null
		var started := _nav.bake_in_background(source if source != null else root as Node3D, {"radius": body.radius, "height": body.stand_height, "climb": body.step_height})
		if source != null:
			source.free()
		if not started.ok:
			DotLog.warn(CHANNEL, "bots cannot route on this map", {"map": str((map as Object).get("id")), "error": started.error.message})
		return _nav

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
	var move := DotFpsCommand.new()
	var fire := DotWeaponCommand.new()

	if game == null or bot == null:
		return [move, fire]

	var world := world_for(game)
	world.refresh(tick, tick_rate)

	if mind.brain == null:
		mind.brain = DotBotBrain.new(mind.seed if mind.seed != 0 else bot.player_id, DotBotSettings.of(game))
	world.brains[bot.player_id] = mind.brain

	var me := world.contact(bot.player_id)
	# A teleport carries the bot further in a tick than anything walks or flies, and its route was
	# laid from where it stood: walked on, the old corners lead it off the pad it landed on. The
	# brain is told as it is when a ride ends, and plans from here (a ride the pilot has is not cut).
	if mind.ride == null and mind.last_position != Vector3.INF and me.position.distance_to(mind.last_position) > TELEPORT_JUMP:
		mind.brain.ride_ended(true)
	mind.last_position = me.position
	var intent := mind.brain.think(me, world, world.now())
	var surf := world.surf_for_map()
	if surf != null:
		surf.call(&"steer", bot, mind, intent, tick, tick_rate)
	elif mind.ride != null:
		mind.ride = null
	intent.write_move(move)
	intent.write_fire(fire)
	_throw(bot, mind, intent, move, fire, tick, tick_rate)
	move.sanitise()
	fire.sanitise()
	return [move, fire]


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

	var thrown := ZeeWeaponIds.SLOT_THROWN
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
	var slot := arsenal.slot_at(ZeeWeaponIds.SLOT_THROWN)
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
