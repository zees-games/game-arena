extends Node

const ArenaPresentation := preload("../game/arena_presentation.gd")
const ClientBench := preload("client_bench.gd")

## The 16v16 benchmark: a solo client on a fixed map, mode, bot count and seed, recorded by the
## client's own dot profiler, so the report has the same per-system table as a player's
## `profiler_record`. Windowed on a GPU box (tools/perf_bench.sh), or headless through hv:
## `godot --path . res://tools/perf_bench.tscn -- --map cp-orange-x3 --mode ctf --bots 31 --seconds 30`.
## Prints `PERF_BENCH {json}` with the report path and a sidecar of engine numbers beside it.

var _map := "cp-orange-x3"
var _mode := "ctf"
var _bots := 31
var _seconds := 30.0
var _warmup := 20.0
var _seed := 1
var _out := "user://perf-bench"
var _tag := ""
var _pilot := true
## `--motor-us 1`: the controller's and motor's phase timers (they cost a little), totals in the sidecar.
var _motor_us := false
## `--queries 0`: no motor query timers, which also leaves the native motor on (they force the script one).
var _queries := true
## `--max-steps N`: ArenaTickBudget.max_steps, as cvar `arena_tick_max_steps`.
var _max_steps := -1
## `--res 1920x1080`: the window size (the default is the project's 1152x648).
var _res := Vector2i.ZERO
## `--killcam-hz N`: ArenaKillcamBodies.record_hz (default 60), `--lod 0`: ArenaPlayer.present_lod_enabled off.
var _killcam_hz := -1.0
var _lod := true
## `--ablate a,b`: render A/B switches applied after the warm-up: noshadow (every light's shadow off), nofx (ssao, ssil, glow,
## fog, volumetric fog off in every Environment), nohud, nobots (remote bodies hidden).
var _ablate := PackedStringArray()
var _client: Node = null
var _prof: Node = null
## Per-frame sums while recording, for the sidecar.
var _acc := {}
var _frames := 0
var _steps0 := 0
var _usec0 := 0


func _ready() -> void:
	preload("../game/arena_weapon_roles.gd").ensure()
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--map": _map = args[i + 1]
			"--mode": _mode = args[i + 1]
			"--bots": _bots = int(args[i + 1])
			"--seconds": _seconds = float(args[i + 1])
			"--warmup": _warmup = float(args[i + 1])
			"--seed": _seed = int(args[i + 1])
			"--out": _out = args[i + 1]
			"--tag": _tag = args[i + 1]
			"--pilot": _pilot = int(args[i + 1]) != 0
			"--motor-us": _motor_us = int(args[i + 1]) != 0
			"--queries": _queries = int(args[i + 1]) != 0
			"--max-steps": _max_steps = int(args[i + 1])
			"--res":
				var wh := args[i + 1].split("x")
				if wh.size() == 2:
					_res = Vector2i(int(wh[0]), int(wh[1]))
			"--killcam-hz": _killcam_hz = float(args[i + 1])
			"--ablate": _ablate = args[i + 1].split(",")
			"--lod": _lod = int(args[i + 1]) != 0
	seed(_seed)
	if _max_steps > 0:
		preload("../game/arena_tick_budget.gd").max_steps = _max_steps
	var _scratch := ArenaPresentation.use_scratch_settings("perf_bench")
	if _res != Vector2i.ZERO and DisplayServer.get_name() != "headless":
		get_window().size = _res
	if _killcam_hz >= 0.0:
		preload("../game/arena_killcam_bodies.gd").record_hz = _killcam_hz
	if not _lod:
		preload("../game/arena_player.gd").present_lod_enabled = false
	_run.call_deferred()


func _say(text: String) -> void:
	print("PERF_BENCH_LOG t=%.1f %s" % [Time.get_ticks_msec() / 1000.0, text])


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec, true, false, true).timeout


func _wait_gate(limit: float) -> void:
	var t := 0.0
	while t < limit:
		var gate: Variant = _client.get("gate")
		if gate == null or (gate as Object).call("is_open"):
			return
		await _wait(0.5)
		t += 0.5


func _run() -> void:
	# The map and mode are picked like the M menu does (the client also reads `--map` itself).
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("mouse_capture_override", true)
	_client.set("offline_bots", _bots)
	add_child(_client)
	var _warmed := AwModelCache.warm(AwWeaponArtTable.model_paths())
	await _wait_gate(120.0)
	var game: Object = _client.get("game")
	var picked: DotResult = null
	if String(game.get("map").id) != _map:
		picked = await _client.call("change_from_menu", StringName("map:" + _map), StringName("mode:" + _mode))
	elif String(game.get("mode").id) != _mode:
		picked = await _client.call("change_from_menu", StringName("mode:" + _mode))
	if picked != null:
		_say("map %s mode %s: %s" % [_map, _mode, "ok" if picked.ok else picked.error.message])
		await _wait_gate(120.0)
	game = _client.get("game")
	if _pilot:
		var pilot := ClientBench.Pilot.new()
		pilot.process_priority = -999
		add_child(pilot)
	_say("map %s mode %s players %d, warming %.0f s" % [String(game.get("map").id), String(game.get("mode").id), game.call("players").size(), _warmup])
	await _wait(_warmup)
	_apply_ablate(game)
	_prof = DotRegistry.get_service(&"dot_profiler")
	if _prof == null:
		_prof = DotProfiler.new()
		add_child(_prof)
		_say("client has no profiler; placed one")
	_prof.config.record_dir = _out
	_prof.config.keep_recordings = 500
	_prof.config.budget_ms = 33.0
	# Unit counts for profiler_groups (e.g. bots:arena.bot,players:arena.p_); read only when that lists them.
	if _prof.has_method(&"add_counter"):
		_prof.call(&"add_counter", "players", func() -> int: return (game.call("players") as Array).size(), "arena.p_")
		_prof.call(&"add_counter", "bots", func() -> int: return maxi((game.call("players") as Array).size() - 1, 0), "arena.bot")
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	DotFpsPhysicsBody.profile = _queries
	DotFpsPhysicsBody.prof.fill(0)
	if _motor_us:
		DotFpsMotor.profile = true
		DotFpsController.phase_us.fill(0)
		DotFpsMotor.phase_us.fill(0)
	_steps0 = Engine.get_physics_frames()
	_usec0 = Time.get_ticks_usec()
	var started: DotResult = _prof.start_recording(_seconds)
	if not started.ok:
		_say("recording did not start: %s" % started.error.message)
		get_tree().quit(1)
		return
	var players0: int = game.call("players").size()
	while _prof.is_recording():
		await get_tree().process_frame
		_sample()
	await get_tree().process_frame
	DotFpsPhysicsBody.profile = false
	DotFpsMotor.profile = false
	var path: String = _prof.last_saved_path()
	var side := _sidecar(game, players0)
	var side_path := ProjectSettings.globalize_path(path).get_basename() + ".bench.json"
	var f := FileAccess.open(side_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(side, " "))
		f.close()
	# The run may be on another box: the report itself goes to stdout too, without spikes and samples.
	var report: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if report is Dictionary:
		_print_spikes(report as Dictionary)
		(report as Dictionary).erase("spikes")
		(report as Dictionary).erase("samples")
	print("PERF_BENCH_REPORT %s" % JSON.stringify(report))
	print("PERF_BENCH_SIDECAR %s" % JSON.stringify(side))
	print("PERF_BENCH %s" % JSON.stringify({"report": ProjectSettings.globalize_path(path), "sidecar": side_path, "tag": _tag}))
	get_tree().quit(0)


## The worst frames of the recording, one `PERF_BENCH_SPIKE` line each (time, ms, phase split, what changed in it);
## the report on stdout has no spikes, and hitch work wants to know which frame was which.
func _print_spikes(report: Dictionary) -> void:
	var spikes: Array = (report.get("spikes", []) as Array).duplicate()
	spikes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("ms", 0.0)) > float(b.get("ms", 0.0)))
	for i in mini(spikes.size(), 25):
		var s: Dictionary = spikes[i]
		print("PERF_BENCH_SPIKE t=%.2f ms=%.0f phys=%.0f script=%.0f render=%.0f cause=%s %s" % [float(s.get("t", 0.0)), float(s.get("ms", 0.0)),
			float(s.get("physics", 0.0)), float(s.get("script", 0.0)), float(s.get("render", 0.0)), s.get("cause", ""), str(s.get("hints", []))])


func _apply_ablate(game: Object) -> void:
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
				_say("nofx: %d environments" % envs.size())
			"nohud":
				var hud: Variant = _client.get("hud")
				if hud != null:
					hud.visible = false
			"nobots":
				for p: Object in game.call("players"):
					if p.get("camera") == null:
						p.visible = false
	_say("ablate %s" % ",".join(_ablate))


func _add(key: String, v: float) -> void:
	_acc[key] = float(_acc.get(key, 0.0)) + v


func _sample() -> void:
	_frames += 1
	var vp := get_viewport().get_viewport_rid()
	_add("render_cpu_ms", RenderingServer.viewport_get_measured_render_time_cpu(vp) + RenderingServer.get_frame_setup_time_cpu())
	_add("render_gpu_ms", RenderingServer.viewport_get_measured_render_time_gpu(vp))
	_add("draw_calls", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_add("objects", Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	_add("primitives", Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	_add("phys_active", Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))
	_add("phys_pairs", Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS))
	_add("phys_islands", Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT))
	_add("nodes", Performance.get_monitor(Performance.OBJECT_NODE_COUNT))


## Engine numbers the per-system table does not hold: renderer, physics server, the motor's queries.
func _sidecar(game: Object, players0: int) -> Dictionary:
	var n := maxf(_frames, 1.0)
	var per_frame := {}
	for k: String in _acc:
		per_frame[k] = snappedf(float(_acc[k]) / n, 0.001)
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
	return {
		"phases_ms_per_frame": phases,
		"map": _map, "mode": String(game.get("mode").id), "bots": _bots, "seed": _seed, "seconds": _seconds, "warmup": _warmup,
		"tag": _tag, "players": players0, "pilot": _pilot, "queries": _queries, "max_steps": _max_steps,
		"host": OS.get_environment("HOSTNAME") if OS.get_environment("HOSTNAME") != "" else OS.get_environment("HOST"),
		"display": DisplayServer.get_name(), "adapter": RenderingServer.get_video_adapter_name(),
		"renderer": RenderingServer.get_current_rendering_method(), "window": [get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y],
		"vsync": DisplayServer.window_get_vsync_mode(), "cpu": OS.get_processor_name(), "threads": OS.get_processor_count(),
		"physics_engine": str(ProjectSettings.get_setting("physics/3d/physics_engine", "")),
		"tick_hz": Engine.physics_ticks_per_second, "frames": _frames,
		"ticks_per_frame": snappedf(float(Engine.get_physics_frames() - _steps0) / n, 0.001),
		"ticks_per_sec": snappedf(float(Engine.get_physics_frames() - _steps0) * 1000000.0 / maxf(Time.get_ticks_usec() - _usec0, 1.0), 0.01),
		"per_frame": per_frame, "motor_queries": queries,
	}
