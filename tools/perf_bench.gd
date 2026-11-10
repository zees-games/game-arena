extends DotGamePerfBench

const ArenaPresentation := preload("../game/arena_presentation.gd")
const ClientBench := preload("client_bench.gd")
const ArenaFrameProbe := preload("../game/arena_frame_probe.gd")
const ArenaHullGrid := preload("../game/arena_hull_grid.gd")

## The 16v16 benchmark: dot-game's DotGamePerfBench (flags, recording, sidecar; see it) on arena's client, fixed map, mode, bot
## count and seed. Windowed on a GPU box (tools/perf_bench.sh), or headless through hv:
## `godot --path . res://tools/perf_bench.tscn -- --map cp-orange-x3 --mode ctf --bots 31 --seconds 30`.
## Arena's own flags: `--pilot 0`, `--motor-us 1` (the controller's and motor's phase timers, a little costly, totals in the
## sidecar), `--queries 0` (no motor query timers, which also leaves the native motor on), `--max-steps N` (ArenaTickBudget.max_steps),
## `--native-us 1` (dot-sim's own timers: each engine query and each whole native tick, in the sidecar as `native`),
## `--batch 0` (`arena_motor_batch` off: the players' motors one call each; the sidecar's `hulls` counts the batch's rows),
## `--hull-min N` (ArenaHullGrid.min_players: the roster from which the hull grid, the native hull world and the batch engage).
## Render knobs: `--res 1920x1080` (window size), `--killcam-hz N` (ArenaKillcamBodies.record_hz), `--lod 0` (ArenaPlayer.present_lod_enabled
## off), `--ablate a,b` (applied after the warm-up: noshadow, nofx = ssao/ssil/glow/fog/volumetric fog off, nohud, nobots).

var _pilot := true
var _motor_us := false
var _queries := true
var _native_us := false
## `--tick N`: the game and engine tick rate (default: the game's, 66); 128 for the 128 Hz cost.
var _tick := 0
var _max_steps := -1
## `--fine 1`: the per-player sub-spans of a tick (ArenaFrameProbe.fine): loop work, pre-motor, hitboxes, weapon context.
var _fine := false
var _ablate := PackedStringArray()


func _configure() -> void:
	client_scene = "res://game/arena.tscn"
	map = "cp-orange-x3"
	mode = "ctf"
	preload("../game/arena_weapon_roles.gd").ensure()
	var _scratch := ArenaPresentation.use_scratch_settings("perf_bench")


func _ready() -> void:
	super()
	_pilot = int(args.get("pilot", 1)) != 0
	_motor_us = int(args.get("motor-us", 0)) != 0
	_queries = int(args.get("queries", 1)) != 0
	_native_us = int(args.get("native-us", 0)) != 0 and ClassDB.class_exists(&"DotSimFpsBody")
	_max_steps = int(args.get("max-steps", -1))
	_fine = int(args.get("fine", 0)) != 0
	_tick = int(args.get("tick", 0))
	if _max_steps > 0:
		preload("../game/arena_tick_budget.gd").max_steps = _max_steps
	var wh := String(args.get("res", "")).split("x")
	if wh.size() == 2 and DisplayServer.get_name() != "headless":
		get_window().size = Vector2i(int(wh[0]), int(wh[1]))
	if args.has("killcam-hz"):
		preload("../game/arena_killcam_bodies.gd").record_hz = float(args["killcam-hz"])
	if int(args.get("batch", 1)) == 0:
		ArenaHullGrid.batch = false
	ArenaHullGrid.min_players = int(args.get("hull-min", ArenaHullGrid.MIN_PLAYERS))
	if int(args.get("lod", 1)) == 0:
		preload("../game/arena_player.gd").present_lod_enabled = false
	_ablate = String(args.get("ablate", "")).split(",", false)


func _setup_client(c: Node) -> void:
	super(c)
	c.set("mouse_capture_override", true)


func _select(game: Object) -> void:
	if _tick > 0:
		game.config.tick_rate = _tick
		game.tick_rate = _tick
		Engine.physics_ticks_per_second = _tick
	var _warmed := AwModelCache.warm(AwWeaponArtTable.model_paths())
	var picked: DotResult = null
	if String(game.get("map").id) != map:
		picked = await client.call("change_from_menu", StringName("map:" + map), StringName("mode:" + mode))
	elif String(game.get("mode").id) != mode:
		picked = await client.call("change_from_menu", StringName("mode:" + mode))
	if picked != null:
		say("map %s mode %s: %s" % [map, mode, "ok" if picked.ok else picked.error.message])
		await wait_gate(120.0)


func _start_pilot(_game: Object) -> void:
	if _pilot:
		var pilot := ClientBench.Pilot.new()
		pilot.process_priority = -999
		add_child(pilot)


func _add_counters(game: Object) -> void:
	# Unit counts for profiler_groups (e.g. bots:arena.bot,players:arena.p_); read only when that lists them.
	if profiler.has_method(&"add_counter"):
		profiler.call(&"add_counter", "players", func() -> int: return (game.call("players") as Array).size(), "arena.p_")
		profiler.call(&"add_counter", "bots", func() -> int: return maxi((game.call("players") as Array).size() - 1, 0), "arena.bot")


func _record_begin() -> void:
	ArenaFrameProbe.fine = _fine
	_apply_ablate()
	DotFpsPhysicsBody.profile = _queries
	DotFpsPhysicsBody.prof.fill(0)
	if _motor_us:
		DotFpsMotor.profile = true
		DotFpsController.phase_us.fill(0)
		DotFpsMotor.phase_us.fill(0)
	if _native_us:
		ClassDB.class_call_static(&"DotSimFpsBody", &"reset_profile")
		ClassDB.class_call_static(&"DotSimFpsBody", &"set_profile", true)


func _record_end() -> void:
	ArenaFrameProbe.fine = false
	DotFpsPhysicsBody.profile = false
	DotFpsMotor.profile = false
	if _native_us:
		ClassDB.class_call_static(&"DotSimFpsBody", &"set_profile", false)


func _sidecar_extra(_game: Object) -> Dictionary:
	var n := frames_recorded()
	var pr := DotFpsPhysicsBody.prof
	var queries := {}
	var names := ["cast", "rest", "overlap", "ray"]
	for i in names.size():
		queries[names[i]] = {"per_frame": snappedf(pr[i * 2] / n, 0.01), "ms_per_frame": snappedf(pr[i * 2 + 1] / 1000.0 / n, 0.001),
			"us_each": snappedf(float(pr[i * 2 + 1]) / maxf(pr[i * 2], 1.0), 0.01)}
	var phases := {}
	if _motor_us:
		# Totals over the recording in ms per frame; per player tick is these over arena.p_controller calls.
		var ctl := ["pre", "consume", "motor", "publish", "report", "signals_stats", "post"]
		for i in ctl.size():
			phases["ctl." + ctl[i]] = snappedf(DotFpsController.phase_us[i] / 1000.0 / n, 0.001)
		for i in DotFpsMotor.PHASES.size():
			if DotFpsMotor.PHASES[i] != "":
				phases["motor." + DotFpsMotor.PHASES[i]] = snappedf(DotFpsMotor.phase_us[i] / 1000.0 / n, 0.001)
	var native := {}
	if _native_us:
		# Count then microseconds per slot: the four engine queries, then whole native ticks; the tick less the queries is dot-sim's own work.
		var c: PackedInt64Array = ClassDB.class_call_static(&"DotSimFpsBody", &"profile_counters")
		var slots := ["cast", "rest", "overlap", "ray", "tick"]
		for i in mini(slots.size(), c.size() / 2):
			native[slots[i]] = {"per_frame": snappedf(float(c[i * 2]) / n, 0.01), "ms_per_frame": snappedf(c[i * 2 + 1] / 1000.0 / n, 0.001),
				"us_each": snappedf(float(c[i * 2 + 1]) / maxf(c[i * 2], 1.0), 0.01)}
	# Which movers gathered their hulls natively (dot-sim's hull world) and which by script: native 0 with a world
	# false means the loaded libdot_sim predates DotSimHullWorld (rebuild it, ci/install.sh).
	var hulls := {}
	if _game != null:
		hulls["world"] = _game.get(&"_hull_world") != null
		hulls["remote_feet"] = (_game.get(&"remote_feet_fn") as Callable).is_valid()
		hulls["remote_lags"] = (_game.get(&"remote_lags_fn") as Callable).is_valid()
		var native_n := 0
		var roster: Variant = _game.get(&"_roster")
		if roster is Array:
			for p: Variant in roster:
				if p is Object and bool((p as Object).get(&"_hull_body_ok")):
					native_n += 1
			hulls["roster"] = (roster as Array).size()
		hulls["native"] = native_n
		hulls["batch"] = ArenaHullGrid.batch
		hulls["batch_rows"] = ArenaHullGrid.batch_rows
		hulls["batch_faults"] = ArenaHullGrid.batch_faults
	return {"phases_ms_per_frame": phases, "native": native, "hulls": hulls, "pilot": _pilot, "queries": _queries, "max_steps": _max_steps, "fine": _fine, "motor_queries": queries}


func _apply_ablate() -> void:
	for a in _ablate:
		match a:
			"noshadow":
				for l in get_tree().root.find_children("*", "Light3D", true, false):
					(l as Light3D).shadow_enabled = false
			"nofx":
				var envs: Array[Environment] = []
				for we in get_tree().root.find_children("*", "WorldEnvironment", true, false):
					envs.append((we as WorldEnvironment).environment)
				for cam in get_tree().root.find_children("*", "Camera3D", true, false):
					if (cam as Camera3D).environment != null:
						envs.append((cam as Camera3D).environment)
				for e in envs:
					if e != null:
						e.ssao_enabled = false
						e.ssil_enabled = false
						e.glow_enabled = false
						e.fog_enabled = false
						e.volumetric_fog_enabled = false
				say("nofx: %d environments" % envs.size())
			"nohud":
				var hud: Variant = client.get("hud")
				if hud != null:
					hud.visible = false
			"nobots":
				for p: Object in client.get("game").call("players"):
					if p.get("camera") == null:
						p.visible = false
	if not _ablate.is_empty():
		say("ablate %s" % ",".join(_ablate))
