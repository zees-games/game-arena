extends RefCounted

## What the in-game profiler (dot-profiler) reports about this game beside its own numbers: the game, map and
## bot count, the dot-sim natives (tag, which run, the `arena_hull_native` cvar) in every report's `context`,
## and dot-sim's native timers in `extras.native` of any recording (F10, `profiler_capture`, `record`).
##
## Without the library every part degrades: the natives line says so and the timer hook reports nothing,
## with no error. Costs nothing while no recording runs: the providers are read at a recording's start and
## end, and the native timers are on only inside one.

const ArenaPlayerStack := preload("arena_player_stack.gd")
const ArenaHullGrid := preload("arena_hull_grid.gd")

const STAMP := "res://addons/dot_sim/bin/.natives"
const SLOTS := ["cast", "rest", "overlap", "ray", "tick"]

static var _begin_frame := 0


## Registers the providers on [param profiler] (a DotProfiler); [param game] is the ArenaGame and [param bridge]
## the client's net bridge (its bots, when this process hosts them), both read when asked.
static func install(profiler: Object, game: Object, bridge: Object = null) -> void:
	if profiler == null or not profiler.has_method(&"add_context") or not profiler.has_method(&"add_recording_hook"):
		return
	var game_ref: WeakRef = weakref(game) if game != null else null
	var bridge_ref: WeakRef = weakref(bridge) if bridge != null else null
	profiler.call(&"add_context", "game", func() -> Dictionary: return game_context(game_ref.get_ref() if game_ref != null else null, bridge_ref.get_ref() if bridge_ref != null else null))
	profiler.call(&"add_context", "natives", natives)
	profiler.call(&"add_recording_hook", "native",
		begin_native, func() -> Dictionary: return end_native(profiler))


## Game, map, mode, bots (those this process hosts) and tick rate.
static func game_context(game: Object, bridge: Object = null) -> Dictionary:
	var out := {"game": "arena"}
	if game == null:
		return out
	var tick: Variant = game.get(&"tick_rate")
	if tick != null:
		out["tick_rate"] = tick
	var map: Variant = game.get(&"map")
	if map is Object and (map as Object).get(&"id") != null:
		out["map"] = str((map as Object).get(&"id"))
	var mode: Variant = game.get(&"mode_id")
	if mode != null:
		out["mode"] = str(mode)
	var bots := 0
	if bridge != null and bridge.has_method(&"bot_ids"):
		bots = (bridge.call(&"bot_ids") as Array).size()
	out["bots"] = bots
	return out


## dot-sim: tag and platform from the bootstrap's stamp, the modules loaded, what runs, and the hull cvar.
static func natives() -> Dictionary:
	var out := {"loaded": ClassDB.class_exists(&"DotSimFpsBody")}
	out["stamp"] = FileAccess.get_file_as_string(STAMP).strip_edges() if FileAccess.file_exists(STAMP) else "unknown"
	out["status"] = ArenaPlayerStack.dot_sim_status()
	out["hull_native"] = ArenaHullGrid.native
	out["arena_hull_native"] = "1" if ArenaHullGrid.native else "0"
	return out


## Starts dot-sim's per-call timers for the recording; a no-op where the library is missing.
static func begin_native() -> void:
	_begin_frame = Engine.get_process_frames()
	if ClassDB.class_exists(&"DotSimFpsBody"):
		ClassDB.class_call_static(&"DotSimFpsBody", &"reset_profile")
		ClassDB.class_call_static(&"DotSimFpsBody", &"set_profile", true)


## The timers per frame, in the shape of the bench sidecar's `native`: {slot: {per_frame, ms_per_frame, us_each}}.
## Read while recording (the overlay) leaves them running; read after it ends turns them off.
static func end_native(profiler: Object) -> Dictionary:
	if not ClassDB.class_exists(&"DotSimFpsBody"):
		return {}
	var c: PackedInt64Array = ClassDB.class_call_static(&"DotSimFpsBody", &"profile_counters")
	var n := maxf(Engine.get_process_frames() - _begin_frame, 1)
	var out := {}
	for i in mini(SLOTS.size(), c.size() / 2):
		out[SLOTS[i]] = {"per_frame": snappedf(float(c[i * 2]) / n, 0.01), "ms_per_frame": snappedf(c[i * 2 + 1] / 1000.0 / n, 0.001),
			"us_each": snappedf(float(c[i * 2 + 1]) / maxf(c[i * 2], 1.0), 0.01)}
	if profiler != null and profiler.has_method(&"is_recording") and not bool(profiler.call(&"is_recording")):
		ClassDB.class_call_static(&"DotSimFpsBody", &"set_profile", false)
	return out
