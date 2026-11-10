extends Node

const ArenaFrameProbe := preload("../game/arena_frame_probe.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")

## Does the solo game keep wall-clock time? A solo match with N bots and a walking player; reports simulated ticks per wall second against the tick rate. `--burn MS` busy-waits that long in every frame; exit 1 when the scale is under `--min` (default 0.97).
## `xvfb-run -a godot --path . --rendering-driver opengl3 res://tools/timescale_probe.tscn -- --bots 31 --burn 40`

var _bots := 31
var _seconds := 8.0
var _burn_ms := 0.0
var _min := 0.97
var _warm := 3.0
var _legacy := false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--bots": _bots = int(args[i + 1])
			"--seconds": _seconds = float(args[i + 1])
			"--burn": _burn_ms = float(args[i + 1])
			"--min": _min = float(args[i + 1])
	_legacy = "--legacy" in args
	if "--cl_perf" in args:
		ArenaFrameProbe.set_interval(float(args[args.find("--cl_perf") + 1]))
	var _scratch := ArenaPresentation.use_scratch_settings("timescale_probe")
	_run.call_deferred()


func _process(_delta: float) -> void:
	if _burn_ms > 0.0:
		var until := Time.get_ticks_usec() + int(_burn_ms * 1000.0)
		while Time.get_ticks_usec() < until:
			pass


func _run() -> void:
	var client: Node = (load("res://game/arena.tscn") as PackedScene).instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	client.set("offline_bots", _bots)
	add_child(client)
	var t0 := Time.get_ticks_usec()
	while client.get("game") == null or client.get("player") == null:
		await get_tree().process_frame
		if (Time.get_ticks_usec() - t0) > 60000000:
			print("timescale_probe: the client never started")
			get_tree().quit(2)
			return
	if _legacy:
		client.set("_tick_budget", null)
		Engine.max_physics_steps_per_frame = 2
	Input.action_press(&"dot_fps_forward")
	var game = client.get("game")
	# Warm up: the loading cover and the first spawn are not the steady state.
	var w0 := Time.get_ticks_usec()
	while (Time.get_ticks_usec() - w0) / 1.0e6 < _warm:
		await get_tree().process_frame
	var tick0: int = game.current_tick()
	var phys0 := Engine.get_physics_frames()
	var start := Time.get_ticks_usec()
	var frames := 0
	var path := 0.0
	var ctrl = game.players()[0].controller if not game.players().is_empty() else null
	var last: Vector3 = ctrl.state.position if ctrl != null else Vector3.ZERO
	var phys_ms := 0.0
	while (Time.get_ticks_usec() - start) / 1.0e6 < _seconds:
		await get_tree().process_frame
		frames += 1
		phys_ms += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		if ctrl != null:
			var p: Vector3 = ctrl.state.position
			path += Vector2(p.x - last.x, p.z - last.z).length()
			last = p
	var wall := (Time.get_ticks_usec() - start) / 1.0e6
	var ticks: int = game.current_tick() - tick0
	var rate := float(game.tick_rate)
	var scale := float(ticks) / wall / rate
	print("timescale_probe: bots=%d burn=%.0fms players=%d fps=%.1f ticks/s=%.1f of %d physics_steps/frame=%.2f scale=%.3f path=%.2f m/s phys_ms/frame=%.1f" % [
		_bots, _burn_ms, game.players().size(), frames / wall, ticks / wall, int(rate),
		float(Engine.get_physics_frames() - phys0) / maxf(frames, 1), scale, path / wall, phys_ms / maxf(frames, 1)])
	get_tree().quit(0 if scale >= _min else 1)
