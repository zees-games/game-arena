extends DotGamePerfBench

const ArenaPresentation := preload("../game/arena_presentation.gd")
const ClientBench := preload("client_bench.gd")
const ArenaFrameProbe := preload("../game/arena_frame_probe.gd")

## The 16v16 benchmark: dot-game's DotGamePerfBench (flags, recording, sidecar; see it) on arena's client, fixed map, mode, bot
## count and seed. Windowed on a GPU box (tools/perf_bench.sh), or headless through hv:
## `godot --path . res://tools/perf_bench.tscn -- --map cp-orange-x3 --mode ctf --bots 31 --seconds 30`.
## Arena's own flags: `--pilot 0`, `--motor-us 1` (the controller's and motor's phase timers, a little costly, totals in the
## sidecar), `--queries 0` (no motor query timers, which also leaves the native motor on), `--max-steps N` (ArenaTickBudget.max_steps).
## Render knobs: `--res 1920x1080` (window size), `--killcam-hz N` (ArenaKillcamBodies.record_hz), `--lod 0` (ArenaPlayer.present_lod_enabled
## off), `--ablate a,b` (applied after the warm-up: noshadow, nofx = ssao/ssil/glow/fog/volumetric fog off, nohud, nobots).

var _pilot := true
var _motor_us := false
var _queries := true
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
	_max_steps = int(args.get("max-steps", -1))
	_fine = int(args.get("fine", 0)) != 0
	if _max_steps > 0:
		preload("../game/arena_tick_budget.gd").max_steps = _max_steps
	var wh := String(args.get("res", "")).split("x")
	if wh.size() == 2 and DisplayServer.get_name() != "headless":
		get_window().size = Vector2i(int(wh[0]), int(wh[1]))
	if args.has("killcam-hz"):
		preload("../game/arena_killcam_bodies.gd").record_hz = float(args["killcam-hz"])
	if int(args.get("lod", 1)) == 0:
		preload("../game/arena_player.gd").present_lod_enabled = false
	_ablate = String(args.get("ablate", "")).split(",", false)


func _setup_client(c: Node) -> void:
	super(c)
	c.set("mouse_capture_override", true)


func _select(game: Object) -> void:
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


func _record_end() -> void:
	ArenaFrameProbe.fine = false
	DotFpsPhysicsBody.profile = false
	DotFpsMotor.profile = false


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
	return {"phases_ms_per_frame": phases, "pilot": _pilot, "queries": _queries, "max_steps": _max_steps, "fine": _fine, "motor_queries": queries}


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
