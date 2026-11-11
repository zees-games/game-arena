extends DotGamePerfBench

const ArenaPresentation := preload("../game/arena_presentation.gd")
const ClientBench := preload("client_bench.gd")
const ArenaFrameProbe := preload("../game/arena_frame_probe.gd")
const ArenaHullGrid := preload("../game/arena_hull_grid.gd")
const ArenaSimHost := preload("../game/arena_sim_host.gd")
const ArenaNetContext := preload("../game/arena_net_context.gd")

## The 16v16 benchmark: dot-game's DotGamePerfBench (flags, recording, sidecar; see it) on arena's client. Windowed on a GPU box (tools/perf_bench.sh) or headless through hv: `godot --path . res://tools/perf_bench.tscn -- --map cp-orange-x3 --mode ctf --bots 31 --seconds 30`.
## Arena's flags: `--pilot 0`, `--motor-us 1`, `--queries 1` (script query timers; native body off), `--ctl-us 1`, `--max-steps N`, `--native-us 1`, `--batch 0` (`arena_motor_batch` off), `--hull-min N`, `--sim-host 1` (solo game as a loopback server; its cost is the `SIM_HOST` log lines).
## Render knobs: `--res 1920x1080`, `--killcam-hz N`, `--lod 0` (ArenaPlayer.present_lod_enabled off), `--ablate a,b` (after the warm-up: noshadow, nofx, nohud, nobots).

var _pilot := true
var _motor_us := false
## Off by default: the script query timers switch the native body off, so every player would run the
## script collision path (about twice the motor cost) instead of the one a match really runs.
var _queries := false
var _native_us := false
var _ctl_us := false
## `--weapon-us 1`: the rig's and the arsenal's parts of p_weapons, in microseconds per call (off by default: the clocks are inside p_weapons).
var _weapon_us := false
## `--tick N`: the game and engine tick rate (default: the game's, 66); 128 for the 128 Hz cost.
var _tick := 0
var _max_steps := -1
## `--fine 0`: no sub-spans inside a system (ArenaFrameProbe.fine), so a report matches one from before they were on by default.
var _fine := true
var _ablate := PackedStringArray()
var _sim_host := false


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
	_queries = int(args.get("queries", 0)) != 0
	_ctl_us = int(args.get("ctl-us", 0)) != 0
	_weapon_us = int(args.get("weapon-us", 0)) != 0
	_native_us = int(args.get("native-us", 0)) != 0 and ClassDB.class_exists(&"DotSimFpsBody")
	_max_steps = int(args.get("max-steps", -1))
	_fine = int(args.get("fine", 1)) != 0
	ArenaFrameProbe.fine_on_record = _fine
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
	if int(args.get("target-first", 1)) == 0:
		# By name: the bench also runs against a dot-bot older than the switch.
		(DotBotBrain as Script).set(&"target_first", false)
	_ablate = String(args.get("ablate", "")).split(",", false)


func _setup_client(c: Node) -> void:
	super(c)
	c.set("mouse_capture_override", true)
	_sim_host = int(args.get("sim-host", 0)) != 0
	if _sim_host:
		ArenaSimHost.forced = 1
		ArenaSimHost.ask_map = map
		ArenaSimHost.ask_mode = mode


func _select(game: Object) -> void:
	if _sim_host:
		await _select_hosted()
		return
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


## The server booted on the map and mode already: wait for the client to exist, load and see the roster.
func _select_hosted() -> void:
	var t := 0.0
	while client.get("gate") == null and t < 120.0:
		await wait(0.25)
		t += 0.25
	await wait_gate(120.0)
	var _warmed := AwModelCache.warm(AwWeaponArtTable.model_paths())
	t = 0.0
	while _players(client.get("game")) < bots + 1 and t < 30.0:
		await wait(0.25)
		t += 0.25
	say("sim host: hosted %s, map %s, players %d" % [client.get("_sim_host") != null, String(client.get("game").get("map").id), _players(client.get("game"))])


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
	# --ctl-us 1: the controller's phases alone, on whichever motor path runs (--motor-us forces the script one).
	DotFpsController.phase_timers = _ctl_us
	AwWeaponRig.phase_timers = _weapon_us
	DotWeaponArsenal.phase_timers = _weapon_us
	AwWeaponRig.phase_us.fill(0)
	AwWeaponRig.phase_calls.fill(0)
	DotWeaponArsenal.phase_us.fill(0)
	DotWeaponArsenal.phase_calls.fill(0)
	if _ctl_us:
		DotFpsController.phase_us.fill(0)
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
	DotFpsController.phase_timers = false
	AwWeaponRig.phase_timers = false
	DotWeaponArsenal.phase_timers = false
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
	if _motor_us or _ctl_us:
		# Totals over the recording in ms per frame; per player tick is these over arena.p_controller calls.
		var ctl := ["pre", "consume", "motor", "publish", "report", "signals_stats", "post", "set_position"]
		for i in ctl.size():
			phases["ctl." + ctl[i]] = snappedf(DotFpsController.phase_us[i] / 1000.0 / n, 0.001)
	if _motor_us:
		for i in DotFpsMotor.PHASES.size():
			if DotFpsMotor.PHASES[i] != "":
				phases["motor." + DotFpsMotor.PHASES[i]] = snappedf(DotFpsMotor.phase_us[i] / 1000.0 / n, 0.001)
	var weapon := {}
	if _weapon_us:
		# Per rig call (idle and full together); the arsenal's per call of its own, its counts beside.
		var rc := AwWeaponRig.phase_calls
		weapon["rig_calls"] = {"idle": rc[0], "full": rc[1]}
		for i in AwWeaponRig.PHASES.size():
			weapon["pw." + AwWeaponRig.PHASES[i]] = snappedf(float(AwWeaponRig.phase_us[i]) / maxf(rc[0] + rc[1], 1.0), 0.01)
		var ac := DotWeaponArsenal.phase_calls
		weapon["arsenal_calls"] = {"full": ac[0], "idle": ac[1], "idle_rested": ac[2]}
		for i in DotWeaponArsenal.PHASES.size():
			weapon["pa." + DotWeaponArsenal.PHASES[i]] = snappedf(float(DotWeaponArsenal.phase_us[i]) / maxf(ac[0] + ac[1], 1.0), 0.01)
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
	return {"phases_ms_per_frame": phases, "weapon_us_per_call": weapon, "native": native, "hulls": hulls, "sim_host": _sim_host and client.get("_sim_host") != null, "net": ArenaNetContext.describe(client.get("bridge")), "pilot": _pilot, "queries": _queries, "max_steps": _max_steps, "fine": _fine, "motor_queries": queries}


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
				# Not `hud.visible = false`: the client's _restore_hud_if_orphaned shows a hidden HUD again at once, so the
				# ablation never held. The HUD stays visible; what it draws (its children) is hidden.
				if hud != null:
					var hidden := 0
					for c in (hud as Node).get_children():
						if c.get("visible") != null:
							c.set("visible", false)
							hidden += 1
					say("nohud: %d HUD children hidden" % hidden)
			"nobots":
				for p: Object in client.get("game").call("players"):
					if p.get("camera") == null:
						p.visible = false
	if not _ablate.is_empty():
		say("ablate %s" % ",".join(_ablate))
