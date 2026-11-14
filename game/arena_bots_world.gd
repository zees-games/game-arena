extends "arena_bots_world_nav.gd"

const ArenaContent := preload("arena_content.gd")


const ArenaPlayer := preload("arena_player.gd")
const ArenaBotBrain := preload("arena_bot_brain.gd")
const ArenaHullGrid := preload("arena_hull_grid.gd")


## The behaviour of a weapon whose shot flies (a rocket, a bolt); every other one is led as
## hitscan. A path, because the pack names behaviours by path (see [DotWeaponDef]).
const PROJECTILE_BEHAVIOUR := "dot_weapon_projectile.gd"


## How long a bot cooks a grenade before letting go, seconds. Well inside the frag's 3 s fuse.
const COOK_SEC := 0.3
## The KOTH layout's hill (ArenaObjectives.build), the point the bots' team jobs gather round.
const HILL := &"hill"


## A bot looks at which gun to hold one tick in this many (see `ArenaBots._choose_gun`).
const GUN_CHECK_EVERY := 8
## Metres inside which a scoped gun gives way to the sidearm.
const GUN_CLOSE := 10.0

## How long a throw may take from the switch to the switch back before it is given up, seconds.
const THROW_GIVE_UP_SEC := 2.5


## Where the world is kept on the game.
const WORLD_META := &"arena_bot_world"




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
	## The character dealt to this bot and its own settings derived from the game's, or null with `bot_personas off`.
	var persona: DotBotPersona = null
	var settings: DotBotSettings = null
	var persona_bias: Vector3 = Vector3.ZERO
	## [member World.persona_epoch] when the brain was made: a `bot_personas` change deals again.
	var persona_epoch: int = -1
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
	## The (yaw, pitch) degrees the last command was turned against recoil by; the brain steers from the view without it.
	var recoil_comp: Vector2 = Vector2.ZERO
	## Whether the last think left the bot free to coast.
	var coasting: bool = false
	## Ticks from the last think to the next (1 = every tick): `_every` far from enemies, or to its tier's next beat.
	var every: int = 1
	## The tick of the last think, so a think that follows a coast knows its brain turned for several ticks at once.
	var last_think_tick: int = -1
	## Between [method think_begin] and [method think_finish] (see ArenaBotThreads): the body's contact, the world and what the brain decided.
	var t_me: DotBotContact = null
	var t_world: Object = null
	var t_intent: DotBotIntent = null


## Ticks between rebuilds of a contact's loadout (see [method World._loadout_of]).
const LOADOUT_EVERY := 4


## Think-rate staggering (cvar `bot_think_every`, `bot_think_near`). A bot with no enemy within [member think_near] metres, no target, no ride, no throw, a plain walk and nothing pressed runs its brain one tick in
## [member think_every], offset by its id so the thinkers spread over the ticks, and repeats its last commands in between; 1 turns it off. Far from a fight a brain only picks a waypoint and walks it; the nearby enemy gets every tick.
static var think_every: int = 0
## Players above which `think_every` 0 (auto) staggers by two: up to a 16-player match every bot thinks every tick.
const AUTO_STAGGER_ABOVE := 16
## The stagger in force this tick (1 = none): `think_every`, or what auto picks for the player count.
static var _every: int = 1
static var think_near: float = 30.0
## Sight LOD (cvars `bot_sight_far`, `bot_sight_far_reuse`; dot-bot's DotBotWorld.sight_far): a body farther than this that a
## bot did not see stays unseen for `sight_far_reuse` s before the next ray; never its target, never a "seen". 0 is off; 20 m (A/B 2026-11-12, staging02 31 bots: bot_los -45%, bot_brain -26%).
static var sight_far: float = 20.0
static var sight_far_reuse: float = 0.15


## Think-rate tiers (cvars `bot_tier_*`): above [member DotBotThinkTier.above] players a bot that fights a person,
## was hurt by one, is near or in view of one, or is among the nearest to one thinks every tick; the rest every 2-4
## ticks and coast between, fighting included. Server-side commands only: the motor and prediction are untouched.
static var tiers := _make_tiers()
static func _make_tiers() -> DotBotThinkTier:
	var t := DotBotThinkTier.new()
	# A bot fighting a person beyond 25 m and out of every view cone thinks every other tick.
	t.engaged_far_every = 2
	return t


## The fewest ticks between thinks while the tiers are on (cvars `bot_tier_floor`, `bot_tier_floor_engaged`). 1, the default: the tiers alone decide. 3 and 2: a bot the tiers would have think every tick thinks at 22 Hz at 66
## (one fighting a person at 33 Hz) and coasts between with the view carried on; a bot a person hurt still thinks on the next tick. Off by default: the windowed bench gained 2 percent of the tick, inside its noise, and it changes how fast a bot reacts.
static var think_floor: int = 1
static var think_floor_engaged: int = 1


## Bot characters (cvar `bot_personas`): "" deals every persona in `cfg/game/game-arena/bot/` by weight, so each bot
## gets its own aim and lean to defend, attack or support; "id:weight,..." only those; "off" one shared bot_difficulty.
static var personas_mode: String = ""
const PERSONAS_OFF := "off"


## Whether tiers decide this tick (else the `bot_think_every` stagger does).
static var _tier_on: bool = false
const _COAST_FIRE := DotWeaponCommand.BUTTON_ATTACK | DotWeaponCommand.BUTTON_AIM
const _COAST_MOVE := DotFpsCommand.BUTTON_CROUCH | DotFpsCommand.BUTTON_WALK | DotFpsCommand.BUTTON_SPRINT


## Further than this in one tick is a teleport, metres (a fall at the 3500 u/s limit is under 1).
const TELEPORT_JUMP := 4.0
const THROW_DRAW := 1
const THROW_COOK := 2
const THROW_RELEASE := 3
const THROW_BACK := 4


## What the brain may know of this game.
class World:
	extends NavWorld

	var tick_rate: float = float(ArenaContent.TICK_RATE)
	var _loadouts: Dictionary = {}
	var _waypoints_tick: int = -1
	var _waypoints_held := PackedVector3Array()
	var _contacts: Array = []
	## The contacts by id, kept from tick to tick and rewritten whole by [method refresh] (a brain keeps ids, never a contact).
	var _by_id: Dictionary = {}
	var _players: Dictionary = {}
	## Weapon ratings (def -> [method DotBotArms.rate]) of this tick: every loadout and drop list rates the same few definitions.
	var _rated: Dictionary = {}
	## The tick [method player_count] counted on, and its count.
	var _count_tick: int = -1
	var _count: int = 0
	## [method DotBotArms.rate] once a tick per definition (over [member _rated]), for every loadout and drop list here.
	var _rater: Callable = Callable()
	## The body tunables of this tick, looked up once for all contacts (the lookup walks every player).
	var _tunables: DotFpsTunables = null
	## The live contacts filed by cell of [member ArenaBots.think_near] metres (key -> contacts), for [method ArenaBots._nobody_near]; empty cell size: not built.
	var near_cells: Dictionary = {}
	var near_cell: float = 0.0
	## [member ArenaBots.think_near], set by the thinking bot before [method refresh].
	var near_reach: float = 0.0
	## Bots a person hurt since their last think: they think next tick whatever their tier.
	var woken: Dictionary = {}
	## [member ArenaBots.tiers], set by the thinking bot before [method refresh].
	var tiers: DotBotThinkTier = null
	## The personas bots are dealt from ([method personas_for]), the `bot_personas` text it was set for, and a count
	## bumped when that changes so every bot is dealt again.
	var _personas: DotBotPersonaPool = null
	var _personas_text: String = ""
	var persona_epoch: int = 0
	var _persona_rng := RandomNumberGenerator.new()

	var _par_glass: bool = false
	## Which job (brain) the calling thread works on, for the log of its wall rays.
	func par_job(job: int) -> void:
		if _par_observe:
			_par_lock.lock()
			_par_job[OS.get_thread_caller_id()] = job
			_par_lock.unlock()

	## The pool for `bot_personas` [param mode], or null for "off". Loaded once from the `bot` profiles; a changed
	## mode sets the override, forgets who had what and bumps [member persona_epoch].
	func personas_for(mode: String) -> DotBotPersonaPool:
		if mode != _personas_text:
			_personas_text = mode
			persona_epoch += 1
			if _personas != null:
				_personas.set_override(mode if mode != PERSONAS_OFF else "")
				_personas.reset_assignments()
		if mode == PERSONAS_OFF:
			return null
		if _personas == null:
			_personas = DotBotPersonaPool.new()
			_persona_rng.seed = 0x5eed
			var n := _personas.load_from(DotProfileSet.create("dot-bot", "game-arena", DotBotPersona.KIND, DotBotPersona.schema()))
			_personas.set_override(mode)
			DotLog.info(CHANNEL, "bot personas loaded", {"personas": n, "override": mode})
		return _personas

	## The persona [param id] is dealt from [param pool].
	func deal_persona(pool: DotBotPersonaPool, id: int) -> DotBotPersona:
		return pool.deal(StringName(str(id)), _persona_rng)

	func _init(p_game: Object) -> void:
		game = p_game
		if game.has_signal(&"hit_confirmed"):
			game.connect(&"hit_confirmed", _on_hit)
		if game.has_signal(&"player_added"):
			game.connect(&"player_added", _hear_player)
		for p in game.call("players"):
			_hear_player(p)
		walkable_fn = _walkable_near
		# The lambdas hold the box, not self: a lambda on self in a field of self is a reference cycle.
		var box := _par_arsenal
		var rated := _rated
		_rater = func(def: Object) -> float:
			var held: Variant = rated.get(def)
			if held == null:
				held = DotBotArms.rate(def)
				rated[def] = held
			return held
		DotBotArms.wire(self, func() -> Variant: return p_game.get("weapon_drops"), func() -> Object: return box[0] if box[0] != null else _any_arsenal(p_game), _rater)

	## Players in the game on [param tick], counted once a tick however many bots ask.
	func player_count(tick: int) -> int:
		if tick != _count_tick or tick < 0:
			_count_tick = tick
			_count = (game.call(&"player_ids") as Array).size()
		return _count

	## Rebuilds the contacts once a tick, however many bots ask.
	func refresh(tick: int, rate: float) -> void:
		tick_rate = maxf(rate, 1.0)
		if tick == _tick:
			return
		_tick = tick
		contacts_version = tick
		_contacts.clear()
		_players.clear()
		_rated.clear()
		_tunables = null
		var t_lap := ArenaFrameProbe.lap_start()
		var teams := _team_mode()
		var eye := ArenaPlayer.eye_height()
		var aim := CHEST * ArenaPlayer.stand_height() / 1.8
		for p: ArenaPlayer in game.call("players"):
			# Last tick's contact, every field written again: as a fresh one, without a new object per player per tick.
			var c: DotBotContact = _by_id.get(p.player_id)
			if c == null:
				c = DotBotContact.new()
				c.id = p.player_id
				_by_id[c.id] = c
			c.eye_height = eye
			c.aim_height = aim
			c.alive = p.is_alive()
			c.team = p.team if teams else 0
			if p.controller != null:
				var state := p.controller.state
				c.position = state.position
				c.velocity = state.velocity
				c.view_yaw = state.yaw
				c.view_pitch = state.pitch
				_motion_of(c, state)
			else:
				c.position = p.global_position
				c.velocity = Vector3.ZERO
				c.view_yaw = NAN
				c.view_pitch = NAN
				c.grounded = true
				c.sliding = false
				c.wall_running = false
				c.air_jump_ready = false
			c.health = p.health.health / p.health.max_health if p.health != null and p.health.max_health > 0.0 else 1.0
			c.loadout = _loadout_of(p, tick)
			_contacts.append(c)
			_players[c.id] = p
		if _by_id.size() != _contacts.size():
			# Someone left: only this tick's players have a contact.
			_by_id.clear()
			for c: DotBotContact in _contacts:
				_by_id[c.id] = c
		_objective_refresh(teams)
		t_lap = ArenaFrameProbe.lap(&"br_contacts", t_lap)
		if tiers != null and tiers.applies(_contacts.size()):
			_tier_begin()
		elif tiers != null:
			tiers.begin(_contacts.size(), PackedVector3Array(), PackedVector3Array(), PackedInt32Array(), PackedVector3Array())
		t_lap = ArenaFrameProbe.lap(&"br_tiers", t_lap)
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
		ArenaFrameProbe.lap(&"br_near", t_lap)

	## The flags as the HUD shows them, or the hill, into [member DotBotWorld.objective], for the bots' team jobs (defend,
	## attack, support). Outside those modes the objective is empty and every bot roams as in a free-for-all.
	func _objective_refresh(teams: bool) -> void:
		var objectives: Variant = game.get("objectives") if teams else null
		var ctf: Variant = objectives.get("ctf") if objectives is Object else null
		if not (ctf is DotObjectiveCtf):
			var hill := _hill_of(objectives)
			if hill != null:
				if objective == null:
					objective = DotBotObjective.new()
				objective.set_point(hill.def.area.centre, hill.def.area.radius, hill.owner_team)
			elif objective != null:
				objective.clear_flags()
			return
		if objective == null:
			objective = DotBotObjective.new()
		var flags: Array[DotObjectiveFlag] = (ctf as DotObjectiveCtf).flags()
		for flag in flags:
			if flag == null or flag.def == null or flag.def.area == null:
				continue
			var team := flag.home_team()
			var capture := Vector3.INF
			for other in flags:
				if other != null and other != flag and other.home_team() != team:
					var area := other.capture_area_for(team, flags)
					if area != null:
						capture = area.centre
					break
			var carrier := -1
			if flag.state == DotObjectiveFlag.State.CARRIED and flag.carrier.is_valid_int():
				carrier = flag.carrier.to_int()
			objective.set_flag(team, flag.def.area.centre, flag.position(), carrier, int(flag.state), capture)

	## The hill of a hill mode, or null.
	func _hill_of(objectives: Variant) -> DotObjective:
		var manager: Variant = objectives.get("manager") if objectives is Object else null
		if not (manager is DotObjectiveManager):
			return null
		var hill := (manager as DotObjectiveManager).objective(HILL)
		return hill if hill != null and hill.def != null and hill.def.area != null else null

	## Hands the tiers the live people's eyes and views and the bots' positions (a person is a contact with no brain).
	func _tier_begin() -> void:
		var eyes := PackedVector3Array()
		var looks := PackedVector3Array()
		var ids := PackedInt32Array()
		var at := PackedVector3Array()
		for c: DotBotContact in _contacts:
			if brains.has(c.id):
				if c.alive:
					ids.append(c.id)
					at.append(c.position)
			elif c.alive:
				eyes.append(c.eye())
				looks.append(DotBotIntent.direction(c.view_yaw, c.view_pitch))
		tiers.begin(_contacts.size(), eyes, looks, ids, at)

	static func near_key(x: float, z: float, cell: float) -> int:
		return (int(floorf(x / cell)) + 4096) * 8192 + int(floorf(z / cell)) + 4096

	## What the player carries, rated, rebuilt one tick in [constant LOADOUT_EVERY] (offset by id)
	## and repeated between: it is 33 slot reads and ratings per player per tick for what only a
	## pickup, a shot or a reload changes, and a bot picks a weapon over tens of ticks.
	func _loadout_of(p: ArenaPlayer, tick: int) -> Dictionary:
		var held: Variant = _loadouts.get(p.player_id)
		if held is Array and (tick + p.player_id) % LOADOUT_EVERY != 0 and tick >= (held as Array)[0] and tick - (held as Array)[0] < LOADOUT_EVERY:
			return (held as Array)[1]
		var made := DotBotArms.loadout_of(p.arsenal, _rater)
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
		_par_arsenal[0] = _any_arsenal(game)
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

	func now() -> float:
		return float(maxi(_tick, 0)) / tick_rate

	func contact(id: int) -> DotBotContact:
		return _by_id.get(id)

	func contacts() -> Array:
		return _contacts

	func contact_of(all: Array, id: int) -> DotBotContact:
		return _by_id.get(id) if is_same(all, _contacts) else DotBotWorld.find(all, id)

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
		if trace is DotTracePhysics and _plain_sight_trace(trace as Object):
			return _sight_ray(trace as DotTracePhysics, from, to)
		if trace is DotTrace:
			return (trace as DotTrace).line_of_sight(from, to)
		return true

	## The trace's own line_of_sight is a [DotHitbox.Hit] world ray: two Hit objects and, on a hit, the surface's
	## material looked up, all of which a yes/no sight drops. Only the plain physics trace and the glass one (whose
	## sight ray leaves the glass layer out) take this path; any other trace keeps its own rules.
	const _GLASS_TRACE := preload("arena_glass_trace.gd")
	var _sight_query: PhysicsRayQueryParameters3D = null

	static func _plain_sight_trace(trace: Object) -> bool:
		var script: Variant = trace.get_script()
		return script == _GLASS_TRACE or script == DotTracePhysics

	## [method DotTrace.line_of_sight] on a [DotTracePhysics] (and [code]arena_glass_trace.gd[/code]'s sight mask), the
	## same answer from one ray query; headless_bots checks both agree.
	func _sight_ray(trace: DotTracePhysics, from: Vector3, to: Vector3) -> bool:
		var offset := to - from
		var distance := offset.length()
		if distance <= 0.0001:
			return true
		var bound: Variant = trace.get("_world")
		if not bound is World3D:
			return true
		var space := (bound as World3D).direct_space_state
		if space == null:
			return true
		var mask: int = trace.collision_mask
		var glass: Variant = trace.get("glass")
		if glass is DotMapGlassSight and (glass as DotMapGlassSight).glass_mask != 0:
			mask &= ~(glass as DotMapGlassSight).glass_mask
		if _sight_query == null:
			_sight_query = PhysicsRayQueryParameters3D.new()
			_sight_query.collide_with_areas = false
			_sight_query.collide_with_bodies = true
			_sight_query.hit_from_inside = false
		_sight_query.from = from
		_sight_query.to = from + offset / distance * distance
		_sight_query.collision_mask = mask
		_sight_query.exclude = trace.exclude_rids
		return space.intersect_ray(_sight_query).is_empty()

	const SPAWN_THINNING := 25.0
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
		var t_lap := ArenaFrameProbe.lap_start()
		var points := _waypoints()
		ArenaFrameProbe.lap(&"bot_waypoints", t_lap)
		return points

	func _waypoints() -> PackedVector3Array:
		# Every replan asks (DotBotGoal's spots too); spawns and landings are gathered once per tick, the weighting keeps its own cache.
		if _waypoints_tick != _tick or _tick < 0:
			_waypoints_held = _places()
			_waypoints_tick = _tick
		var stats: Variant = game.get("demo_stats")
		return (stats as Object).call(&"weight_waypoints", _waypoints_held) if stats is Object else _waypoints_held

	func _places() -> PackedVector3Array:
		var out := PackedVector3Array()
		var map: Variant = game.get("map")
		var spawns: Array = (map as Object).get("spawns") if map is Object else []
		var surf := surf_for_map()
		for spawn: Transform3D in spawns:
			# A combat surf map has dozens of spawns on one platform (surf_snipers_island: 48); each as a waypoint outweighed the few landings and ramp starts a ride is taken from, and the bots never rode.
			# With ride edges linked, spawns closer than this to one kept are one place.
			if surf != null and out.size() > 0 and _near_any(out, spawn.origin, SPAWN_THINNING):
				continue
			out.append(spawn.origin)
		if surf != null:
			out.append_array(surf.call(&"landing_points"))
		return out

	## The nearest standable point of the mesh, for a bot that cannot free itself; INF off it.
	func _walkable_near(at: Vector3) -> Vector3:
		var nav := _nav_for_map()
		return nav.closest(at) if nav != null and nav.is_ready() else Vector3.INF

	## Whether an imported map's mesh is still baking or its edges still joining (each call steps that); false on a built-in map or once done.
	func is_route_pending() -> bool:
		if _nav == null or _nav_map != game.get("map"):
			return false
		return _nav.is_baking() or ((_joining or _nav.is_ready()) and not warm())

	## How fast the held weapon's shot flies, m/s; 0 for hitscan, a swing or a throw.
	func projectile_speed(shooter: DotBotContact) -> float:
		if par:
			_par_lock.lock()
			var held := _projectile_speed(shooter)
			_par_lock.unlock()
			return held
		var t_lap := ArenaFrameProbe.lap_start()
		var speed := _projectile_speed(shooter)
		ArenaFrameProbe.lap(&"bot_proj_speed", t_lap)
		return speed

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
		if not brains.has(attacker):
			woken[victim] = true
		var from := contact(attacker)
		brain.hurt(from.eye() if from != null else Vector3.INF, now())
