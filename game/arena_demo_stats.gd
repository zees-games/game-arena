extends RefCounted

## Records where real players stand (`place`) and how they aim (`engage`), for dot-bot's heatmap and aim statistics.
##
## Off unless `bot_record` is on. A bot is never a subject. An engagement starts when a player first has a living enemy in view and ends at their first hit or when the enemy has been out of view for a moment.

const ArenaPlayerTunables := preload("arena_player_tunables.gd")

const CHANNEL := "arena.demo_stats"
const PLACE := "place"
const ENGAGE := "engage"

## Sight: cosine of the cone an enemy must be inside, range in metres, and seconds out of view that ends an engagement.
const VIEW_COS := 0.7
const VIEW_RANGE := 60.0
const LOST_GRACE := 0.5
const ENGAGE_MAX := 10.0
## Chest height of the 1.8 m body the sight line was drawn for; scaled to the body in use.
const CHEST := 1.25
## Seconds after a hit given or taken that a player counts as in a fight.
const FIGHT_HOLD := 3.0

class Engagement:
	extends RefCounted
	var target: int = 0
	var started: int = 0
	var unseen: int = 0
	var fired: bool = false
	var last_target_pos: Vector3 = Vector3.ZERO
	var last_yaw: float = 0.0
	var last_pitch: float = 0.0

var game: Object = null
var demo: DotBotDemoConfig = null
var store: DotBotDemoStore = null
var recorder: DotBotDemoRecorder = null
var tick_rate: float = 64.0
var heatmap: DotBotDemoHeatmap = null
var stats: DotBotAimStats = null

## A place episode is cut at this many seconds so it reaches the store while the player lives.
var place_span: float = 30.0
var places: int = 0
var engagements: int = 0
## Seconds between reloads of the heatmap and aim statistics while recording, so what players do tonight shapes the bots within the hour.
var refresh_interval: float = 600.0
var refreshes: int = 0

var _engaged: Dictionary = {}
var _place_started: Dictionary = {}
var _fight_until: Dictionary = {}
var _map: Object = null
var _roam_cache: Array = [0, PackedVector3Array()]
var _hooked: bool = false
var _since_refresh: float = 0.0
var _refreshing: bool = false


static func place_schema() -> DotBotDemoSchema:
	var s := DotBotDemoSchema.make(PLACE)
	s.add_observation("position", 3, 100.0).add_observation("fight", 1, 1.0)
	s.add_action("speed", 1, 20.0)
	s.keep_outcomes = PackedStringArray(["span", "died", "left"])
	return s


static func engage_schema() -> DotBotDemoSchema:
	var s := DotBotDemoSchema.make(ENGAGE)
	s.add_observation("error", 1, 30.0).add_observation("fired", 1, 1.0).add_observation("tracking", 1, 30.0)
	s.add_action("turn", 2, 30.0)
	s.keep_outcomes = PackedStringArray(["hit", "kill"])
	return s


## Builds the recorder over [param p_store] for [param p_game]; [param p_config] is the layered `bot_record_*` config.
func setup(p_game: Object, p_config: DotBotDemoConfig, p_store: DotBotDemoStore, p_tick_rate: float) -> DotResult:
	game = p_game
	demo = p_config
	store = p_store
	tick_rate = p_tick_rate
	recorder = DotBotDemoRecorder.new(demo, store)
	recorder.is_server = true
	recorder.tick_rate = tick_rate
	recorder.include_fn = func(subject: Variant) -> bool:
		var p: Object = game.call(&"player_for", (subject as Vector2i).x) if game != null else null
		return p != null and not p.has_meta(&"bot")
	for schema in [place_schema(), engage_schema()]:
		var registered := recorder.register(schema)
		if not registered.ok:
			return registered
	_fresh_folds()
	if game.has_signal(&"hit_confirmed"):
		game.connect(&"hit_confirmed", _on_hit)
		_hooked = true
	return DotResult.success(self)


func release() -> void:
	if _hooked and game != null and game.is_connected(&"hit_confirmed", _on_hit):
		game.disconnect(&"hit_confirmed", _on_hit)
	_hooked = false
	if recorder != null:
		recorder.include_fn = Callable()
	recorder = null
	store = null
	game = null
	_map = null
	_engaged.clear()


func is_on() -> bool:
	return recorder != null and recorder.is_on()


## Call every frame: writes the recorder's queue.
func process(delta: float) -> void:
	if recorder != null:
		recorder.process(delta)
		if recorder.is_on():
			_since_refresh += delta
			if _since_refresh >= refresh_interval:
				_refresh_soon()


## After [param player] simulated a tick with [param move] and [param fire].
func after(id: int, player: Object, move: DotFpsCommand, fire: DotWeaponCommand, tick: int) -> void:
	if not is_on():
		return
	_sync_map()
	if player.has_meta(&"bot"):
		return
	if not bool(player.call(&"is_alive")):
		_lose(id, "died")
		return
	var state: DotFpsState = player.controller.state
	var fighting := _engaged.has(id) or tick < int(_fight_until.get(id, -1))
	_place(id, player, state, fighting, tick)
	_engage(id, player, state, move, fire, tick)


## [param points] with those in busier cells repeated, so a uniform pick among them roams where people stand. Unchanged until the heatmap holds enough.
func weight_waypoints(points: PackedVector3Array) -> PackedVector3Array:
	if heatmap == null or heatmap.episode_count() == 0:
		return points
	var stamp := hash(points) ^ (heatmap.episode_count() * 7919)
	if _roam_cache[0] != stamp:
		_roam_cache = [stamp, heatmap.weighted(points, "")]
	return _roam_cache[1]


## Reloads the heatmap and aim statistics for the current map from the store.
func refresh() -> DotResult:
	if store == null or recorder == null:
		return DotResult.fail(DotError.CODE_STATE, "Not set up.")
	var fresh_heat := _new_heatmap()
	var fresh_stats := _new_stats()
	var folded: DotResult = await fresh_heat.fold_store(store, recorder.map_id, recorder.map_version, ["all", "t1", "t2"])
	if not folded.ok:
		return folded
	folded = await fresh_stats.fold_store(store, recorder.map_id, recorder.map_version, ["all"])
	if not folded.ok:
		return folded
	# Swapped in whole, so waypoints never read a half-folded heatmap.
	heatmap = fresh_heat
	stats = fresh_stats
	_roam_cache = [0, PackedVector3Array()]
	refreshes += 1
	return folded


## The suggested presets for one map version in [param p_store], as lines for a person to review; changes nothing.
static func preset_lines(p_store: DotBotDemoStore, p_map_id: String, p_version: String, min_count: int = 0) -> PackedStringArray:
	var counts: DotResult = p_store.counts(p_map_id, p_version, DotBotAimStats.KIND)
	if not counts.ok:
		return PackedStringArray([str(counts.message)])
	var aim := _new_stats()
	aim.map_id = p_map_id
	aim.map_version = p_version
	if min_count > 0:
		aim.min_count = min_count
	var folded: DotResult = await aim.fold_store(p_store, p_map_id, p_version, (counts.value as Dictionary).keys())
	if not folded.ok:
		return PackedStringArray([str(folded.message)])
	return aim.describe_lines() + aim.suggest_lines()


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray(["demo stats: %d place, %d engage episodes begun" % [places, engagements]])
	if recorder != null:
		out.append_array(recorder.describe_lines())
	if heatmap != null:
		out.append_array(heatmap.describe_lines())
	return out


func _fresh_folds() -> void:
	heatmap = _new_heatmap()
	stats = _new_stats()
	_roam_cache = [0, PackedVector3Array()]


static func _new_heatmap() -> DotBotDemoHeatmap:
	var h := DotBotDemoHeatmap.new()
	h.fight_index = 3
	return h


static func _new_stats() -> DotBotAimStats:
	var a := DotBotAimStats.new()
	a.track_index = 2
	return a


## Reloads in the background; one at a time, and a request made meanwhile is dropped.
func _refresh_soon() -> void:
	_since_refresh = 0.0
	if _refreshing:
		return
	_refreshing = true
	var _r: Variant = await refresh()
	_refreshing = false


func _team_mode() -> bool:
	var mode: Variant = game.get("mode")
	return mode is Object and (mode as Object).has_method("is_team_mode") and bool((mode as Object).call("is_team_mode"))


func _label_for(player: Object) -> String:
	return "t%d" % int(player.get("team")) if _team_mode() else "all"


func _sync_map() -> void:
	var current: Object = game.get("map")
	if current == null or current == _map:
		return
	_map = current
	_engaged.clear()
	_place_started.clear()
	var version := str(current.call(&"effective_content_version")) if current.has_method(&"effective_content_version") else "0"
	recorder.set_map(str(current.get("id")), version)
	_refresh_soon()


func _place(id: int, player: Object, state: DotFpsState, fighting: bool, tick: int) -> void:
	var subject := Vector2i(id, 0)
	var started: int = int(_place_started.get(id, -1))
	if started >= 0 and float(tick - started) / tick_rate >= place_span:
		var _e := recorder.end(subject, "span")
		started = -1
	if started < 0:
		if not recorder.begin(subject, PLACE, _label_for(player)).ok:
			return
		places += 1
		_place_started[id] = tick
	var speed := Vector2(state.velocity.x, state.velocity.z).length()
	var frame := PackedFloat32Array([state.position.x, state.position.y, state.position.z, 1.0 if fighting else 0.0])
	var _kept := recorder.sample(subject, frame, PackedFloat32Array([speed]), tick)


func _engage(id: int, player: Object, state: DotFpsState, move: DotFpsCommand, fire: DotWeaponCommand, tick: int) -> void:
	var subject := Vector2i(id, 1)
	var eye := state.position + Vector3(0.0, ArenaPlayerTunables.eye_height_m(), 0.0)
	var aim := Vector3.FORWARD
	if fire != null:
		aim = fire.aim_direction()
	elif move != null:
		aim = move.aim_direction()
	var e: Engagement = _engaged.get(id)
	if e == null:
		var target := _enemy_in_view(player, eye, aim)
		if target == null or not recorder.begin(subject, ENGAGE, "all").ok:
			return
		e = Engagement.new()
		e.target = int(target.get("player_id"))
		e.started = tick
		e.last_yaw = state.yaw
		e.last_pitch = state.pitch
		_engaged[id] = e
		engagements += 1
	var foe: Object = game.call(&"player_for", e.target)
	if foe == null or not bool(foe.call(&"is_alive")):
		_engaged.erase(id)
		recorder.cancel(subject)
		return
	var foe_pos: Vector3 = foe.controller.state.position + Vector3(0.0, CHEST * ArenaPlayerTunables.body_scale(), 0.0)
	var to := foe_pos - eye
	var seen := to.length() <= VIEW_RANGE and to.normalized().dot(aim) >= VIEW_COS and _sees(eye, foe_pos)
	e.unseen = 0 if seen else e.unseen + 1
	if fire != null and (fire.buttons & DotWeaponCommand.BUTTON_ATTACK) != 0:
		e.fired = true
	var err := rad_to_deg(aim.angle_to(to.normalized()))
	var moved := (foe_pos - e.last_target_pos).length() * tick_rate if e.last_target_pos != Vector3.ZERO else 0.0
	e.last_target_pos = foe_pos
	var tracking := err if moved > 0.5 else -1.0
	var turn := PackedFloat32Array([wrapf(state.yaw - e.last_yaw, -180.0, 180.0), state.pitch - e.last_pitch])
	e.last_yaw = state.yaw
	e.last_pitch = state.pitch
	# A shot between two kept samples is held until one is kept.
	if recorder.sample(subject, PackedFloat32Array([err, 1.0 if e.fired else 0.0, tracking]), turn, tick):
		e.fired = false
	if float(e.unseen) / tick_rate >= LOST_GRACE or float(tick - e.started) / tick_rate >= ENGAGE_MAX:
		_engaged.erase(id)
		recorder.cancel(subject)


func _enemy_in_view(player: Object, eye: Vector3, aim: Vector3) -> Object:
	var teams := _team_mode()
	var best: Object = null
	var best_dot := VIEW_COS
	for other: Object in game.call(&"players"):
		if other == player or not bool(other.call(&"is_alive")) or other.controller == null:
			continue
		if teams and int(other.get("team")) == int(player.get("team")):
			continue
		var to: Vector3 = other.controller.state.position + Vector3(0.0, CHEST * ArenaPlayerTunables.body_scale(), 0.0) - eye
		if to.length() > VIEW_RANGE:
			continue
		var d := to.normalized().dot(aim)
		if d > best_dot and _sees(eye, eye + to):
			best_dot = d
			best = other
	return best


func _sees(from: Vector3, to: Vector3) -> bool:
	var combat: Variant = game.get("combat")
	var trace: Variant = (combat as Object).get("trace") if combat is Object else null
	return (trace as DotTrace).line_of_sight(from, to) if trace is DotTrace else true


func _on_hit(attacker: int, victim: int, _amount: float, _point: Vector3, _head: bool, lethal: bool) -> void:
	if recorder == null:
		return
	var tick := int(game.call(&"current_tick"))
	_fight_until[attacker] = tick + int(FIGHT_HOLD * tick_rate)
	_fight_until[victim] = tick + int(FIGHT_HOLD * tick_rate)
	var e: Engagement = _engaged.get(attacker)
	if e == null or e.target != victim:
		return
	_engaged.erase(attacker)
	var _r := recorder.end(Vector2i(attacker, 1), "kill" if lethal else "hit")


func _lose(id: int, outcome: String) -> void:
	if _engaged.has(id):
		_engaged.erase(id)
		recorder.cancel(Vector2i(id, 1))
	if _place_started.has(id):
		_place_started.erase(id)
		var _r := recorder.end(Vector2i(id, 0), outcome)
