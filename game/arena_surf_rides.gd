extends RefCounted

## Records the rides real players take between the platforms of a combat surf map, replays them on
## the real motor to keep the ones that land, and gives bots the verified ones to ride.
##
## It is the host side of dot-bot's ride harvest: [method replay_start], [method replay_command],
## [method landing] and [method perturb]. Off unless the server turns `bot_record` on; bots are
## never recorded. Loaded by path, and only on a shell that has dot-bot's recorder.
## Reasoning: dot-bot docs/demonstration-recorder.md, "The first consumer: surf rides".

const CHANNEL := "arena.surf.rides"

const ArenaBots := preload("arena_bots.gd")
const ArenaSurf := preload("arena_surf.gd")

const KIND := "ride"

## A recorded ride shorter than this, metres, is a hop between neighbouring floors.
const MIN_RIDE_METRES := 40.0

## A step further than this in one tick is a teleport, and ends the recording.
const JUMPED := 6.0

## What a hand-planned ride is worth in the book until it is measured.
const SEED_SCORE := 0.5

const ACTION_YAW := 0
const ACTION_MOVE := 1
const ACTION_JUMP := 3

## Dispatches the replay simulator's oracle to the course of the episode being replayed.
class ReplayCourse:
	extends ArenaSurf.EdgeCourse

	var current: ArenaSurf.EdgeCourse = null

	func event_at(state: Variant) -> int:
		return current.event_at(state) if current != null else EVENT_NONE


## One player's place in the stretch of play being watched.
class Track:
	extends RefCounted
	var island: int = -1
	var riding: bool = false
	var from_island: int = -1
	var from_pos: Vector3 = Vector3.ZERO
	var last_pos: Vector3 = Vector3.INF
	var pre_pos: Vector3 = Vector3.ZERO
	var pre_vel: Vector3 = Vector3.ZERO
	var pre_state: DotFpsState = null
	var ticks: int = 0

var game: Object = null
var demo: DotBotDemoConfig = null
var ride_config: DotBotRideConfig = null
var schema: DotBotDemoSchema = null
var recorder: DotBotDemoRecorder = null
var store: DotBotDemoStore = null
var harvest: DotBotRideHarvest = null
var book: DotBotRideBook = null
var rng: DotRandomStream = null
var nav: DotBotNav = null
var map: Object = null
var tick_rate: float = 64.0

## Players' stretches that ended as a ride kept, and as one thrown away, for describe().
var begun: int = 0
var kept: int = 0
var discarded: int = 0
var harvested: int = 0
## Why stretches were thrown away: reason -> count.
var why_not: Dictionary = {}

var _tracks: Dictionary = {}
var _courses: Dictionary = {}
var _floors: Dictionary = {}
var _replay_course: ReplayCourse = null
var _sim: DotFpsSimulator = null
var _dirty: Dictionary = {}
var _job: DotBotRideHarvestJob = null
var _job_key: String = ""
var _job_loaded: Array = []
var _busy: bool = false
var _edge_keys: Dictionary = {}
var _attached: bool = false


## Cap and target are the recorder's own, so one setting says both how many rides a key keeps and when recordings outrank seeds.
static func ride_config_for(config: DotBotDemoConfig) -> DotBotRideConfig:
	var out := DotBotRideConfig.new()
	out.cap = config.cap
	out.target = config.target
	return out


## The `ride` schema: where the player is and how fast, and the command the server applied.
static func ride_schema() -> DotBotDemoSchema:
	var s := DotBotDemoSchema.make(KIND)
	s.add_observation("position", 3, 100.0).add_observation("velocity", 3, 20.0)
	s.add_action("yaw", 1, 180.0).add_action("move", 2, 1.0).add_action("jump", 1, 1.0, true)
	s.keep_outcomes = PackedStringArray(["landed"])
	return s


## Builds the recorder over [param p_store] for [param p_game] (a server's game); [param p_config] is the layered `bot_record_*` config.
func setup(p_game: Object, p_config: DotBotDemoConfig, p_store: DotBotDemoStore, p_tick_rate: float) -> DotResult:
	game = p_game
	demo = p_config
	store = p_store
	tick_rate = p_tick_rate
	ride_config = ride_config_for(demo)
	schema = ride_schema()
	recorder = DotBotDemoRecorder.new(demo, store)
	recorder.is_server = true
	recorder.tick_rate = tick_rate
	recorder.include_fn = func(subject: Variant) -> bool:
		var p: Object = game.call(&"player_for", int(subject))
		return p != null and not p.has_meta(&"bot")
	var registered := recorder.register(schema)
	if not registered.ok:
		return registered
	book = DotBotRideBook.new(ride_config)
	rng = DotRandomStream.new(ride_config.seed)
	_replay_course = ReplayCourse.new()
	return DotResult.success(self)


## Keys the recorder and the book to the game's current map, with its mesh once baked.
func set_map(p_map: Object, p_nav: DotBotNav) -> void:
	map = p_map
	nav = p_nav
	_tracks.clear()
	_courses.clear()
	_floors.clear()
	_edge_keys.clear()
	_dirty.clear()
	_attached = false
	_sim = null
	var id := str(p_map.get("id"))
	var version := str(p_map.call(&"effective_content_version")) if p_map.has_method(&"effective_content_version") else "0"
	recorder.set_map(id, version)
	book.set_map(id, version)


## Lets go of everything that points back at this object, so it frees when the game does.
func release() -> void:
	if recorder != null:
		recorder.include_fn = Callable()
	if _sim != null:
		_sim.oracle = Callable()
	_job = null
	harvest = null
	_sim = null
	_replay_course = null
	book = null
	recorder = null
	store = null
	game = null
	nav = null
	map = null
	_tracks.clear()
	_courses.clear()


## True while recording would happen now.
func is_on() -> bool:
	return recorder != null and recorder.is_on() and nav != null and nav.is_ready()


# --- Recording -----------------------------------------------------------------------

## Follows the game's map and the bots' mesh, and hands bots the recorded rides once the surf cache is linked.
func _sync() -> void:
	var current: Object = game.get("map")
	if current == null or not current.has_method(&"is_imported") or not bool(current.call(&"is_imported")) or not recorder.config.record:
		return
	var world := ArenaBots.world_for(game)
	var mesh := world.nav_for_rides()
	if mesh == null:
		return
	if mesh != nav or current != map:
		set_map(current, mesh)
	if mesh.is_ready() and not _attached:
		_attached = true
		var surf := world.surf_for_map()
		if surf != null:
			surf.set(&"rides", self)
			attach_surf(surf)

## Before [param player] simulates a tick: where it stands, which is what its command is judged from.
func before(id: int, player: Object) -> void:
	if recorder == null:
		return
	_sync()
	if not is_on():
		return
	var state: DotFpsState = player.controller.state
	var t := _track(id)
	t.pre_pos = state.position
	t.pre_vel = state.velocity
	if not t.riding:
		t.pre_state = state.duplicate_state()


## After [param player] simulated [param command] on [param tick]: begins, extends, ends or drops a ride.
func after(id: int, player: Object, command: DotFpsCommand, tick: int) -> void:
	if not is_on():
		return
	var t := _track(id)
	var state: DotFpsState = player.controller.state
	if player.has_meta(&"bot"):
		_tracks.erase(id)
		return
	if not bool(player.call(&"is_alive")) or (t.last_pos != Vector3.INF and state.position.distance_to(t.last_pos) > JUMPED):
		_drop(id, t, "moved or died")
		t.island = -1
	t.last_pos = state.position
	var grounded := state.is_grounded()
	var here := nav.island_at(state.position, 1.0)
	if t.riding:
		_extend(id, t, state, command, tick, grounded, here)
	elif grounded and here >= 0:
		t.island = canonical(here)
	elif not grounded and t.island >= 0 and here < 0:
		# From the standing state before this tick, so the run-off is in the recording and a bot replaying it starts on the ground too.
		var begun_res := recorder.begin(id, KIND, "", encode_state(t.pre_state if t.pre_state != null else state))
		if begun_res.ok:
			t.riding = true
			t.from_island = t.island
			t.from_pos = t.pre_pos
			t.ticks = 0
			begun += 1
			_extend(id, t, state, command, tick, grounded, here)


func _extend(id: int, t: Track, state: DotFpsState, command: DotFpsCommand, tick: int, grounded: bool, here: int) -> void:
	t.ticks += 1
	var obs := PackedFloat32Array([t.pre_pos.x, t.pre_pos.y, t.pre_pos.z, t.pre_vel.x, t.pre_vel.y, t.pre_vel.z])
	var act := PackedFloat32Array([command.yaw, command.move.x, command.move.y, 1.0 if command.is_pressed(DotFpsCommand.BUTTON_JUMP) else 0.0])
	var _kept := recorder.sample(id, obs, act, tick)
	var bounds: AABB = map.get("bounds")
	var lost := state.position.y < bounds.position.y - ArenaSurf.FALL_OUT_DEPTH or float(t.ticks) / tick_rate > ArenaSurf.RIDE_SECONDS
	for pit: Dictionary in map.get("pits"):
		if (pit["box"] as AABB).has_point(state.position):
			lost = true
	if lost:
		_drop(id, t, "fell, pit or timed out")
		return
	# Standing, or nearly (the course's own rule): a slope the motor slides down is a landing too.
	var down := nav.island_at(state.position, 0.6)
	if down < 0 or not (grounded or state.velocity.y > -ArenaSurf.LANDED_FALL):
		return
	var to := canonical(down)
	t.riding = false
	if to == t.from_island or t.from_pos.distance_to(state.position) < MIN_RIDE_METRES:
		recorder.cancel(id)
		discarded += 1
		var reason := "same floor" if to == t.from_island else "short"
		why_not[reason] = int(why_not.get(reason, 0)) + 1
	else:
		var key := "%d>%d" % [t.from_island, to]
		if recorder.end(id, "landed", key).ok:
			kept += 1
			_dirty[key] = true
		else:
			discarded += 1
			why_not["not kept"] = int(why_not.get("not kept", 0)) + 1
	t.island = to


func _drop(id: int, t: Track, reason: String) -> void:
	if t.riding:
		discarded += 1
		why_not[reason] = int(why_not.get(reason, 0)) + 1
	t.riding = false
	recorder.cancel(id)


func _track(id: int) -> Track:
	var t: Track = _tracks.get(id)
	if t == null:
		t = Track.new()
		_tracks[id] = t
	return t


## The island that names [param island]'s floor: a floor a kerb splits is one place to a rider.
func canonical(island: int) -> int:
	if island < 0:
		return island
	if not _floors.has(island):
		var best := island
		for other in ArenaSurf.landing_floor(nav, island):
			best = mini(best, other)
		_floors[island] = best
	return _floors[island]


# --- The host the harvest replays on --------------------------------------------------

## The episode's start as a state, and its course made current; null when the key names no island.
func replay_start(ep: DotBotDemoEpisode) -> Variant:
	var course := course_for_key(ep.key)
	if course == null:
		return null
	_replay_course.current = course
	return decode_state(ep.start)


## The command for one recorded [param action].
func replay_command(sim: Variant, action: PackedFloat32Array, _state: Variant) -> DotFpsCommand:
	return sim.command(action[ACTION_YAW], Vector2(action[ACTION_MOVE], action[ACTION_MOVE + 1]), action[ACTION_JUMP] > 0.5)


## Landed on the recorded island, fell out or hit a pit, or still going.
func landing(state: Variant, _event: int, _ep: DotBotDemoEpisode) -> int:
	match _replay_course.current.event_at(state):
		DotBotSurfCourse.EVENT_GOAL:
			return DotBotRideHarvest.LANDED
		DotBotSurfCourse.EVENT_PIT, DotBotSurfCourse.EVENT_BELOW:
			return DotBotRideHarvest.FAILED
	return DotBotRideHarvest.GOING


## [param state] moved up to [param metres] sideways and its speed changed by up to [param speed].
func perturb(state: Variant, stream: DotRandomStream, metres: float, speed: float) -> Variant:
	var s: DotFpsState = (state as DotFpsState).duplicate_state()
	s.position += Vector3(stream.next_range_f(-metres, metres), 0.0, stream.next_range_f(-metres, metres))
	var flat := Vector3(s.velocity.x, 0.0, s.velocity.z)
	if flat.length() > 0.01:
		var scale := maxf(0.0, flat.length() + stream.next_range_f(-speed, speed)) / flat.length()
		s.velocity = Vector3(flat.x * scale, s.velocity.y, flat.z * scale)
	return s


## The course of ride key "from>to" (island indices), or null when the mesh has no such islands.
func course_for_key(key: String) -> ArenaSurf.EdgeCourse:
	if _courses.has(key):
		return _courses[key]
	var parts := key.split(">")
	var course: ArenaSurf.EdgeCourse = null
	if parts.size() == 2 and nav != null:
		var islands := nav.islands()
		var a := int(parts[0])
		var b := int(parts[1])
		if a >= 0 and b >= 0 and a < islands.size() and b < islands.size():
			var from := nav.closest((islands[a] as Dictionary)["centre"])
			var to := nav.closest((islands[b] as Dictionary)["centre"])
			course = ArenaSurf.course_for(map, nav, from, to)
			if course.landing_island < 0:
				course = null
	_courses[key] = course
	return course


## A harvest over [param p_sim], whose oracle follows the episode being replayed.
func make_harvest(p_sim: DotFpsSimulator) -> DotBotRideHarvest:
	p_sim.oracle = _replay_course.event_at
	_sim = p_sim
	harvest = DotBotRideHarvest.new(ride_config, schema, p_sim, self)
	return harvest


## The harvest on [param controller]'s motor over the map's brushes, as an edge's veto runs.
func harvest_on(controller: DotFpsController) -> DotBotRideHarvest:
	var surf := ArenaSurf.new()
	surf.map = map
	surf.nav = nav
	var edge := ArenaSurf.Edge.new()
	edge.course = _replay_course
	var p_sim := surf._sim_for(edge, controller)
	if p_sim == null:
		return null
	return make_harvest(p_sim)


# --- State as plain values ------------------------------------------------------------

## Every field of the motor state as JSON-safe values.
static func encode_state(state: DotFpsState) -> Dictionary:
	var out := {}
	for prop: Dictionary in state.get_property_list():
		if int(prop["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		var v: Variant = state.get(prop["name"])
		match typeof(v):
			TYPE_VECTOR3:
				out[prop["name"]] = [v.x, v.y, v.z]
			TYPE_STRING_NAME:
				out[prop["name"]] = String(v)
			TYPE_ARRAY:
				out[prop["name"]] = (v as Array).map(func(m: Vector2i) -> Array: return [m.x, m.y])
			_:
				out[prop["name"]] = v
	return out


## The state [method encode_state] wrote.
static func decode_state(data: Dictionary) -> DotFpsState:
	var state := DotFpsState.new()
	for name: String in data:
		var v: Variant = data[name]
		var have: Variant = state.get(name)
		match typeof(have):
			TYPE_VECTOR3:
				state.set(name, Vector3(float(v[0]), float(v[1]), float(v[2])))
			TYPE_STRING_NAME:
				state.set(name, StringName(v))
			TYPE_ARRAY:
				var mods: Array[Vector2i] = []
				for m: Array in v:
					mods.append(Vector2i(int(m[0]), int(m[1])))
				state.set(name, mods)
			TYPE_INT:
				state.set(name, int(v))
			TYPE_FLOAT:
				state.set(name, float(v))
			_:
				state.set(name, v)
	return state


# --- Harvesting on a running server ----------------------------------------------------

## Call every frame: writes the recorder's queue, and when a key has new recordings replays them a slice at a time.
func process(delta: float) -> void:
	if recorder == null:
		return
	recorder.process(delta)
	if _job != null:
		if not _job.is_settled():
			var _more := _job.step()
		elif not _busy:
			_commit_job()
	elif not _dirty.is_empty() and not _busy and recorder.queued() == 0 and is_on():
		_start_job()


func _start_job() -> void:
	_busy = true
	var key: String = _dirty.keys()[0]
	_dirty.erase(key)
	var loaded: DotResult = await store.load(recorder.map_id, recorder.map_version, KIND, key, 0)
	if loaded.ok:
		var todo := DotBotRideHarvest.unchecked(loaded.value)
		var players: Array = game.call(&"players")
		var made: DotBotRideHarvest = harvest_on(players[0].controller) if not players.is_empty() and not todo.is_empty() else null
		if made != null:
			_job = made.make_job(todo)
			_job_key = key
			_job_loaded = loaded.value
	_busy = false


func _commit_job() -> void:
	_busy = true
	var job := _job
	var key := _job_key
	_job = null
	var committed: DotResult = await harvest.commit(store, _job_loaded, job.verdicts)
	if committed.ok:
		var good := job.verdicts.filter(func(v: Dictionary) -> bool: return v["ok"]).size()
		recorder.note_verified(KIND, key, good)
		harvested += good
		var _loaded: DotResult = await book.load_edge(store, KIND, key, schema, tick_rate)
	_busy = false


# --- Riding recorded rides ---------------------------------------------------------------

## Registers [param surf]'s edges in the book as seeds and loads the verified recordings of each.
func attach_surf(surf: Object) -> void:
	for edge: ArenaSurf.Edge in surf.edges:
		if not edge.linked:
			continue
		var key := edge_key(edge)
		_edge_keys[edge.id] = key
		book.add_seeded(key, SEED_SCORE, edge.cache)
		var _loaded: DotResult = await book.load_edge(store, KIND, key, schema, tick_rate)


## The key recordings of [param edge] are filed under.
func edge_key(edge: ArenaSurf.Edge) -> String:
	return "%d>%d" % [canonical(nav.island_at(edge.from, 2.0)), canonical(edge.course.landing_island)]


## One of edge [param edge_id]'s rides if a recording is among them; otherwise empty, and the planned cache rides.
func pick(edge_id: int) -> Dictionary:
	var key: String = _edge_keys.get(edge_id, "")
	if key == "" or book.recorded_count(key) == 0:
		return {}
	var entry := DotBotSurfRide.pick(book, key, rng)
	return entry if entry.get("source", "") == DotBotRideBook.RECORDED else {}


## Writes one recorded action into a bot's intent.
func decode(action: PackedFloat32Array, _state: Variant, intent: DotBotIntent) -> void:
	intent.yaw = action[ACTION_YAW]
	intent.move = Vector2(action[ACTION_MOVE], action[ACTION_MOVE + 1])
	intent.jump = action[ACTION_JUMP] > 0.5
	intent.crouch = false
	intent.walk = false


func describe() -> Dictionary:
	return {"on": is_on(), "begun": begun, "kept": kept, "discarded": discarded, "harvested": harvested,
		"open": _tracks.size(), "why_not": why_not, "map": "%s@%s" % [recorder.map_id, recorder.map_version]}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray(["ride recording: %d begun, %d kept, %d discarded, %d verified" % [begun, kept, discarded, harvested]])
	out.append_array(recorder.describe_lines())
	if harvest != null:
		out.append_array(harvest.describe_lines())
	out.append_array(book.describe_lines())
	return out
