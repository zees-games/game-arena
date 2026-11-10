extends RefCounted

## What the in-game profiler (dot-profiler) reports about this game beside its own numbers: the game, map and bot count, the sound driver, the dot-sim natives (tag, which run, the `arena_hull_native` cvar) in every report's `context`,
## and dot-sim's native timers in `extras.native` of any recording (F10, `profiler_capture`, `record`). Without the library every part degrades (the natives line says so, the timer hook reports nothing, no error);
## costs nothing while no recording runs: providers are read at a recording's start and end, and the native timers are on only inside one.

const ArenaGame := preload("arena_game.gd")
const ArenaPlayerStack := preload("arena_player_stack.gd")
const ArenaHullGrid := preload("arena_hull_grid.gd")
const ArenaFrameProbe := preload("arena_frame_probe.gd")
const ArenaNetContext := preload("arena_net_context.gd")

const STAMP := "res://addons/dot_sim/bin/.natives"
const SLOTS := ["cast", "rest", "overlap", "ray", "tick"]
## What a player may cost a tick, in microseconds: the report's suspects are rated against it.
const PLAYER_TARGET_US := 70.0

static var _begin_frame := 0


## Registers the providers on [param profiler] (a DotProfiler); [param game] is the ArenaGame and [param bridge]
## the client's net bridge (its bots, when this process hosts them), both read when asked; [param presentation]
## is whatever holds the client's `audio` manager.
static func install(profiler: Object, game: Object, bridge: Object = null, presentation: Object = null) -> void:
	if profiler == null or not profiler.has_method(&"add_context") or not profiler.has_method(&"add_recording_hook"):
		return
	var game_ref: WeakRef = weakref(game) if game != null else null
	var bridge_ref: WeakRef = weakref(bridge) if bridge != null else null
	profiler.call(&"add_context", "game", func() -> Dictionary: return game_context(game_ref.get_ref() if game_ref != null else null, bridge_ref.get_ref() if bridge_ref != null else null))
	var sound_ref: WeakRef = weakref(presentation) if presentation != null else null
	profiler.call(&"add_context", "audio", func() -> Dictionary: return audio_context(sound_ref.get_ref() if sound_ref != null else null))
	profiler.call(&"add_context", "natives", natives)
	# Whether the sim ran in its own process and what it cost there, and this client's lead and replays.
	profiler.call(&"add_context", "net", func() -> Dictionary: return ArenaNetContext.describe(bridge_ref.get_ref() if bridge_ref != null else null))
	profiler.call(&"add_recording_hook", "native",
		begin_native, func() -> Dictionary: return end_native(profiler))
	profiler.call(&"add_recording_hook", "fine", begin_fine, func() -> Dictionary: return end_fine(profiler))
	if game_ref != null and profiler.has_method(&"add_counter"):
		profiler.call(&"add_counter", "players", func() -> int: return player_count(game_ref.get_ref()), "arena.p_")
	# The report's cost per player and its target; only a profiler new enough to have them, and only where nobody chose.
	var config: Variant = profiler.get(&"config")
	if config is Object and (config as Object).get(&"per_unit") is String and String((config as Object).get(&"per_unit")) == "":
		(config as Object).set(&"per_unit", "players")
		(config as Object).set(&"unit_target_us", PLAYER_TARGET_US)


static func player_count(game: Object) -> int:
	return (game.call(&"player_ids") as Array).size() if game != null and game.has_method(&"player_ids") else 0


## Turns the sub-spans inside the tick's sections on for the recording, so one profile names the part of a section.
static func begin_fine() -> void:
	if ArenaFrameProbe.fine_on_record:
		ArenaFrameProbe.fine = true
		AwWeaponRig.phase_timers = true
		DotWeaponArsenal.phase_timers = true


## Off again once the recording ended (a read while it runs, for the overlay, leaves them on).
static func end_fine(profiler: Object) -> Dictionary:
	var out := {"sub_spans": ArenaFrameProbe.fine}
	if ArenaFrameProbe.fine_on_record and profiler != null and profiler.has_method(&"is_recording") and not bool(profiler.call(&"is_recording")):
		ArenaFrameProbe.fine = false
		AwWeaponRig.phase_timers = false
		DotWeaponArsenal.phase_timers = false
	return out


## Game, map, mode, tick rate, and the players and bots in the match. Bots are counted from the roster (their ids
## start at BOT_SESSION_BASE), so a client of a remote server reports the server's bots; `bots_hosted` is this process's own.
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
	var hosted := 0
	if bridge != null and bridge.has_method(&"bot_ids"):
		hosted = (bridge.call(&"bot_ids") as Array).size()
	var bots := 0
	var players := 0
	if game.has_method(&"player_ids"):
		for id: int in game.call(&"player_ids"):
			players += 1
			if id >= ArenaGame.BOT_SESSION_BASE:
				bots += 1
	out["players"] = players
	out["bots"] = maxi(bots, hosted)
	out["bots_hosted"] = hosted
	return out


## The sound driver and its latency, and how busy the game's sound manager is (dot-audio's `describe`).
static func audio_context(presentation: Object) -> Dictionary:
	var out := {"driver": AudioServer.get_driver_name(), "output": AudioServer.output_device, "mix_rate": int(AudioServer.get_mix_rate()),
		"latency_ms": snappedf(AudioServer.get_output_latency() * 1000.0, 0.1), "buses": AudioServer.bus_count}
	var manager: Variant = presentation.get(&"audio") if presentation != null else null
	if manager is Object and (manager as Object).has_method(&"describe"):
		var d: Dictionary = (manager as Object).call(&"describe")
		for key: String in ["sink", "device", "sounds", "playing", "capacity", "music"]:
			if d.has(key):
				out[key] = d[key]
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
