extends DotGamePerfBench

const ArenaPresentation := preload("../game/arena_presentation.gd")
const ClientBench := preload("client_bench.gd")
const ArenaFrameProbe := preload("../game/arena_frame_probe.gd")
const ArenaHullGrid := preload("../game/arena_hull_grid.gd")
const ArenaSimHost := preload("../game/arena_sim_host.gd")
const ArenaNetContext := preload("../game/arena_net_context.gd")
const ProcSplit := preload("proc_split.gd")
# Loaded with this script, so its _static_init (native brain off) runs before --brain-native.
const ArenaPlayerStack := preload("../game/arena_player_stack.gd")

## The 16v16 benchmark: dot-game's DotGamePerfBench (flags, recording, sidecar; see it) on arena's client. Windowed on a GPU box (tools/perf_bench.sh) or headless through hv: `godot --path . res://tools/perf_bench.tscn -- --map cp-orange-x3 --mode ctf --bots 31 --seconds 30`.
## Arena's flags: `--pilot 0`, `--motor-us 1`, `--queries 1` (script query timers; native body off), `--ctl-us 1`, `--max-steps N`, `--native-us 1`, `--batch 0` (`arena_motor_batch` off), `--hull-min N`, `--sim-host 1` (solo game as a loopback server; its cost is the `SIM_HOST` log lines).
## `--brain-native 0|1`: dot-bot's native mind (DotSimBotMind: aim, fight step, perception) off or on; without the dot-sim library it is script either way (the sidecar's `brain_native` says which ran).
## `--tier-idle-seen N`: ticks between thinks of an idle bot a person only sees (bot_tier_every_idle_seen; 1 is the old every tick).
## `--sight-far M`, `--sight-far-reuse S`: bot sight LOD (bot_sight_far, bot_sight_far_reuse; default 20 m and 0.15 s, 0 turns it off).
## `--tier-body-near N`, `--tier-body-far N`: ticks between motor ticks of a coasting bot nobody sees (bot_tier_body_every_near/far; 1, the default, every tick).
## `--web-defaults 1`: the browser build's defaults (cl_remote_lod_every 8).
## Render knobs: `--res 1920x1080`, `--killcam-hz N`, `--lod 0` (ArenaPlayer.present_lod_enabled off), `--anim-gate 0` (cl_remote_anim_gate off), `--carry 0` (AwWorldModel.person_carry off: the held gun's own kick and reload dip, no humanoid carry), `--ablate a,b` (after the warm-up: noshadow, nofx, nohud, nobots, no3d, norender).
## `--first-use 1` (dot-game's first-use rows): every weapon equipped, fired once cold and once warm, before the warm-up (offline only;
## `--first-use-only a,b` for some ids); `--prewarm 0` skips the client's weapon warm-up, so `--ab DIR DIR::--prewarm 0 -- --first-use 1` prices it.
## `--proc-split 1`: the process phase split by wall clock and a census of what processes (tools/proc_split.gd); `--present-ablate N` (ArenaPlayer.present_ablate bits: 1 no figure animation, 2 no held, 4 held not processing, 8 no pose).
## `--script-top N`: the N GDScript functions with the most self time in the report's script_functions (dot-profiler's profiler_script_top); needs the engine started with -d, which slows scripts, so read shares, not ms.

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
var _sched0 := {}
var _sched := {}
var _proc_split: ProcSplit = null


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
	if int(args.get("web-defaults", 0)) != 0:
		# The browser build's defaults (DotPlatform.is_web()), before the flags below may override one.
		var ap := preload("../game/arena_player.gd")
		ap.lod_off_every = ap.WEB_LOD_OFF_EVERY
		say("web defaults: lod_off_every %d" % ap.lod_off_every)
	if args.has("killcam-hz"):
		preload("../game/arena_killcam_bodies.gd").record_hz = float(args["killcam-hz"])
	if args.has("sight-far"):
		preload("../game/arena_bots.gd").sight_far = float(args["sight-far"])
	if args.has("sight-far-reuse"):
		preload("../game/arena_bots.gd").sight_far_reuse = float(args["sight-far-reuse"])
	if args.has("tier-idle-seen"):
		preload("../game/arena_bots.gd").tiers.idle_view_every = int(args["tier-idle-seen"])
	if args.has("tier-body-near"):
		preload("../game/arena_bots.gd").tiers.body_near_every = int(args["tier-body-near"])
	if args.has("tier-body-far"):
		preload("../game/arena_bots.gd").tiers.body_far_every = int(args["tier-body-far"])
	if int(args.get("batch", 1)) == 0:
		ArenaHullGrid.batch = false
	ArenaHullGrid.min_players = int(args.get("hull-min", ArenaHullGrid.MIN_PLAYERS))
	if int(args.get("lod", 1)) == 0:
		preload("../game/arena_player.gd").present_lod_enabled = false
	if int(args.get("anim-gate", 1)) == 0:
		preload("../game/arena_player.gd").anim_gate_enabled = false
	if int(args.get("carry", 1)) == 0:
		# By name: a no-op against an arena-weapons older than the switch.
		(AwWorldModel as Script).set(&"person_carry", false)
	if args.has("brain-native"):
		ArenaPlayerStack.set_brain_native(int(args["brain-native"]) != 0)
	say("brain: %s" % ("native" if ArenaPlayerStack.brain_native() else "script"))
	if int(args.get("target-first", 1)) == 0:
		# By name: the bench also runs against a dot-bot older than the switch.
		(DotBotBrain as Script).set(&"target_first", false)
	_ablate = String(args.get("ablate", "")).split(",", false)
	preload("../game/arena_player.gd").present_ablate = int(args.get("present-ablate", 0))
	preload("../game/arena_client_prewarm.gd").prewarm_weapons_enabled = int(args.get("prewarm", 1)) != 0


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


## Each weapon id: equip it (the draw), fire it cold, then again warm, the player invulnerable. Rows "equip ID", "shot ID", "shot2 ID".
func _first_use(_game: Object) -> void:
	if _sim_host:
		say("first use: offline only, not with --sim-host")
		return
	var ids: Array[StringName] = []
	for id: StringName in AwWeaponCatalogue.table():
		ids.append(id)
	if args.has("first-use-only"):
		ids.clear()
		for s in String(args["first-use-only"]).split(",", false):
			ids.append(StringName(s))
	for id in ids:
		var def: DotWeaponDef = AwWeaponCatalogue.table().get(id)
		var me: Variant = client.get("player")
		if def == null or me == null:
			say("first use: skip %s (%s)" % [id, "no def" if def == null else "no player"])
			continue
		me.health.invulnerable = true
		var _given: Variant = me.arsenal.give(id)
		var _eq := await time_first_use("equip %s" % id, func() -> void: me.arsenal.equip(def.slot), Callable(), 0, 45)
		var t := 0.0
		while t < 3.0 and not (me.arsenal.current() != null and me.arsenal.current().id() == id):
			await wait(0.1)
			t += 0.1
		if me.arsenal.current() == null or me.arsenal.current().id() != id:
			say("first use: %s did not equip" % id)
			continue
		await wait(0.8)
		for row in ["shot", "shot2"]:
			# Held ten frames, so a physics tick sees it at any frame rate; the window runs on to the impact and the shell.
			var _shot := await time_first_use("%s %s" % [row, id], func() -> void: Input.action_press(&"arena_fire"),
				func() -> void: Input.action_release(&"arena_fire"), 10, 45)
			await wait(1.0)


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


## Per thread of this process and of the sim host: run time, run-queue wait, slices and context switches (Linux /proc).
func _sched_snapshot() -> Dictionary:
	var out := {}
	if OS.get_name() != "Linux":
		return out
	var pids := {"client": OS.get_process_id()}
	var host: Variant = client.get("_sim_host") if client != null else null
	if host != null and int(host.get("_pid")) > 0:
		pids["server"] = int(host.get("_pid"))
	for who: String in pids:
		var base := "/proc/%d/task" % pids[who]
		var threads := {}
		for tid: String in DirAccess.get_directories_at(base):
			var st := _proc_read(base + "/" + tid + "/schedstat").split(" ", false)
			if st.size() < 3:
				continue
			var cs := {"voluntary_ctxt_switches": 0, "nonvoluntary_ctxt_switches": 0}
			for l in _proc_read(base + "/" + tid + "/status").split("\n", false):
				var kv := l.split(":", false, 1)
				if kv.size() == 2 and cs.has(kv[0]):
					cs[kv[0]] = int(kv[1].strip_edges())
			threads[tid] = {"run": int(st[0]), "wait": int(st[1]), "slices": int(st[2]), "vcs": cs.voluntary_ctxt_switches, "nvcs": cs.nonvoluntary_ctxt_switches,
				"comm": _proc_read(base + "/" + tid + "/comm").strip_edges(), "main": int(tid) == pids[who]}
		out[who] = threads
	return out


## /proc files report size 0, so read them line by line rather than by length.
func _proc_read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var s := ""
	while not f.eof_reached():
		s += f.get_line() + "\n"
	return s


## Wall time split per thread over the recording, ms per frame: running and waiting for a CPU (the rest is sleeping or blocked); context switches per frame.
func _sched_report(a: Dictionary, b: Dictionary) -> Dictionary:
	var n := maxf(frames_recorded(), 1.0)
	var res := {}
	for who: String in b:
		var rows := []
		for tid: String in b[who]:
			var t1: Dictionary = b[who][tid]
			var t0: Dictionary = (a.get(who, {}) as Dictionary).get(tid, {"run": 0, "wait": 0, "slices": 0, "vcs": 0, "nvcs": 0})
			var run: float = (int(t1.run) - int(t0.run)) / 1e6 / n
			if run < 0.05 and not t1.main:
				continue
			rows.append({"tid": tid, "comm": t1.comm, "main": t1.main, "run_ms": snappedf(run, 0.01),
				"rq_wait_ms": snappedf((t1.wait - t0.wait) / 1e6 / n, 0.01), "vcs": snappedf((t1.vcs - t0.vcs) / n, 0.01), "nvcs": snappedf((t1.nvcs - t0.nvcs) / n, 0.01)})
		rows.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return float(x.run_ms) > float(y.run_ms))
		res[who] = rows
	return res


func _record_begin() -> void:
	_sched0 = _sched_snapshot()
	ArenaFrameProbe.fine = _fine
	_apply_ablate()
	if args.has("script-top") and profiler != null:
		profiler.config.script_top = int(args["script-top"])
	if int(args.get("proc-split", 0)) != 0:
		say("proc census %s" % JSON.stringify(ProcSplit.census(get_tree().root)))
		_proc_split = ProcSplit.new()
		add_child(_proc_split)
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
	_sched = _sched_report(_sched0, _sched_snapshot())
	if _proc_split != null:
		say("proc split ms/frame %s" % JSON.stringify(_proc_split.report()))
		_proc_split.queue_free()
		_proc_split = null
	for who: String in _sched:
		for r: Dictionary in _sched[who]:
			say("sched %s %s%s run %.2f rq %.2f vcs %.2f nvcs %.2f ms|n/frame" % [who, r.comm, " (main)" if r.main else "", r.run_ms, r.rq_wait_ms, r.vcs, r.nvcs])
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
	return {"phases_ms_per_frame": phases, "weapon_us_per_call": weapon, "native": native, "hulls": hulls, "sim_host": _sim_host and client.get("_sim_host") != null, "sched": _sched, "net": ArenaNetContext.describe(client.get("bridge")), "pilot": _pilot, "brain_native": ArenaPlayerStack.brain_native(), "queries": _queries, "max_steps": _max_steps, "fine": _fine, "motor_queries": queries, "body_skipped": preload("../game/arena_player.gd").body_skipped, "tiers": preload("../game/arena_bots.gd").tiers.describe()}


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
			# Splits the engine's render phase: no3d keeps the canvas and the present (swapchain, the Xvfb copy) but draws no
			# 3D scene; norender skips RenderingServer.draw altogether, leaving physics and scripts.
			"no3d":
				get_viewport().disable_3d = true
			"norender":
				RenderingServer.render_loop_enabled = false
	if not _ablate.is_empty():
		say("ablate %s" % ",".join(_ablate))
