extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaModule := preload("../game/arena_module.gd")
const LoopbackServer := preload("loopback_server.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaFrameProbe := preload("../game/arena_frame_probe.gd")
const ArenaHullGrid := preload("../game/arena_hull_grid.gd")
const ArenaBotBrain := preload("../game/arena_bot_brain.gd")
const ArenaBotThreads := preload("../game/arena_bot_threads.gd")
const ArenaBots := preload("../game/arena_bots.gd")

## The 128-player scale harness (nightly arena-128-scale-1). Measures; asserts nothing; prints one `SCALE128 {json}` line. Driven by tools/scale128.sh, which runs it through `heavy`.
## `godot --headless --path . res://tools/scale128.tscn -- --role server --bots 64 --tick 33 --seconds 30` (or `--role offline --bots 32 --tick 66 --seconds 20`). [b]server[/b]: DotServer + ArenaModule with N bots, no client, one physics tick timed three ways (script half between sentinels, TIME_PHYSICS_PROCESS, wall-clock ticks/s).
## [b]offline[/b]: the real offline client (game, bots and drawing in one process), the same numbers plus how fast game time ran against the wall clock (`sim_speed`) and a node census of one other player.

var _role := "server"
var _bots := 16
var _tick := 66
var _seconds := 30.0
var _settle := 4.0
var _port := 27230
var _map := "dm_box"
var _mode := "ffa"

var _t_start := 0
var _script_us := PackedFloat64Array()
var _phys_ms := PackedFloat64Array()
var _count := 0
var _first: Node = null
var _last: Node = null
var _recording := false


class Sentinel extends Node:
	var bench: Node
	var is_start := true
	func _physics_process(_d: float) -> void:
		bench._sentinel(is_start)


var _t0 := 0


func _sentinel(is_start: bool) -> void:
	if not _recording:
		return
	var now := Time.get_ticks_usec()
	if is_start:
		_t0 = now
		_count += 1
	else:
		_script_us.append(float(now - _t0))
		_phys_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--role": _role = args[i + 1]
			"--bots": _bots = int(args[i + 1])
			"--tick": _tick = int(args[i + 1])
			"--seconds": _seconds = float(args[i + 1])
			"--port": _port = int(args[i + 1])
			"--map": _map = args[i + 1]
			"--mode": _mode = args[i + 1]
			"--fastsense": ArenaBotBrain.fast_sense = args[i + 1] != "0"
			"--hullgrid": ArenaHullGrid.enabled = args[i + 1] != "0"
			"--hullfast": ArenaHullGrid.fast = args[i + 1] != "0"
			"--worldcoarse": DotFpsFlatBody.world_coarse = args[i + 1] != "0"
			"--hullverify": ArenaHullGrid.verify = args[i + 1] != "0"
			"--hullnative": ArenaHullGrid.native = args[i + 1] != "0"
			"--threads": ArenaBotThreads.threads = int(args[i + 1])
			"--thinkevery": ArenaBots.think_every = int(args[i + 1])
			"--thinknear": ArenaBots.think_near = float(args[i + 1])
			"--tierabove": ArenaBots.tiers.above = int(args[i + 1])
			"--motorprof": _motorprof = args[i + 1] != "0"
			"--spawn": _spawn = args[i + 1] != "0"
			"--wphases":
				AwWeaponRig.phase_timers = args[i + 1] != "0"
				DotWeaponArsenal.phase_timers = AwWeaponRig.phase_timers
			"--native": DotBotWorld.native_enabled = args[i + 1] != "0"
			"--motornative": DotFpsPhysicsBody.native_enabled = args[i + 1] != "0"
	DotLog.set_level(DotLog.Level.ERROR)
	var _scratch := ArenaPresentation.use_scratch_settings("scale128_" + _role)
	for is_start in [true, false]:
		var s := Sentinel.new()
		s.bench = self
		s.is_start = is_start
		s.process_physics_priority = -1000000 if is_start else 1000000
		add_child(s)
	if _role == "offline":
		_offline.call_deferred()
	else:
		_serve.call_deferred()


static func _stats(a: PackedFloat64Array, scale := 1.0) -> Dictionary:
	if a.is_empty():
		return {}
	var s := a.duplicate()
	s.sort()
	var sum := 0.0
	for v in s:
		sum += v
	var n := s.size()
	return {
		"mean": snappedf(sum / n * scale, 0.001), "p50": snappedf(s[n / 2] * scale, 0.001),
		"p95": snappedf(s[mini(n - 1, int(n * 0.95))] * scale, 0.001),
		"p99": snappedf(s[mini(n - 1, int(n * 0.99))] * scale, 0.001), "max": snappedf(s[n - 1] * scale, 0.001),
	}


func _rss_mb() -> float:
	var f := FileAccess.open("/proc/self/status", FileAccess.READ)
	if f == null:
		return -1.0
	for line in f.get_as_text().split("\n"):
		if line.begins_with("VmRSS:"):
			return snappedf(float(line.split(" ", false)[1]) / 1024.0, 0.1)
	return -1.0


func _sections_ms(ticks: int) -> Dictionary:
	var out := {}
	for k in ArenaFrameProbe._sections:
		var row: PackedInt64Array = ArenaFrameProbe._sections[k]
		out[String(k)] = {"per_tick_ms": snappedf(row[0] / 1000.0 / maxi(1, ticks), 0.001), "calls": row[1], "max_ms": snappedf(row[2] / 1000.0, 0.001)}
	return out


func _report(extra: Dictionary) -> void:
	var wall := (Time.get_ticks_usec() - _t_start) / 1.0e6
	var budget_ms := 1000.0 / _tick
	var script := _stats(_script_us, 0.001)
	var out := {
		"role": _role, "bots": _bots, "tick_hz": _tick, "budget_ms": snappedf(budget_ms, 0.01),
		"wall_s": snappedf(wall, 0.1), "ticks": _count, "ticks_per_s": snappedf(_count / wall, 0.1),
		"tick_ratio": snappedf(_count / wall / _tick, 0.001),
		"script_ms": script, "physics_frame_ms": _stats(_phys_ms),
		"engine_ms_mean": snappedf(float(_stats(_phys_ms).get("mean", 0.0)) - float(script.get("mean", 0.0)), 0.001),
		"per_actor_us": snappedf(float(script.get("mean", 0.0)) * 1000.0 / maxi(1, _bots), 0.1),
		"mem_static_mb": snappedf(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, 0.1),
		"rss_mb": _rss_mb(), "nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"sections": _sections_ms(_count),
		"verdict_holds": float(script.get("mean", 99999.0)) < 0.7 * budget_ms and float(script.get("p95", 99999.0)) < budget_ms and _count / wall / _tick > 0.97,
	}
	out["bot_threads"] = ArenaBotThreads.threads
	out["think_every"] = ArenaBots.think_every
	out["think_near"] = ArenaBots.think_near
	out["par_ticks"] = ArenaBotThreads.par_ticks
	out["tiers"] = ArenaBots.tiers.describe()
	# What the bots did while recorded, so a think-rate change shows its cost in play (shots per hit, kills).
	out["combat"] = {"shots": _shots, "hits": _hits, "headshots": _heads, "kills": _kills,
		"hit_rate": snappedf(float(_hits) / maxi(1, _shots), 0.001)}
	out["native_scan"] = DotBotWorld.native_available()
	out["motor_native"] = DotFpsPhysicsBody.native_enabled and ClassDB.class_exists(&"DotSimFpsBody")
	out.merge(extra)
	if ArenaHullGrid.verify:
		out["hull_verified"] = ArenaHullGrid.verified
		out["hull_mismatches"] = ArenaHullGrid.mismatches
		out["hull_native_verified"] = ArenaHullGrid.native_verified
		out["hull_native_mismatches"] = ArenaHullGrid.native_mismatches
	# Hull gathers dot-sim's hull world answered in the motor tick (no script call), and the pair calls it made.
	var arena := get_tree().root.find_child("Arena", true, false)
	var world: Object = arena.get(&"_hull_world") if arena != null else null
	if world != null:
		var c: PackedInt64Array = world.counters()
		out["hull_native_gathers"] = c[0]
		out["hull_native_pair_calls"] = c[1]
	out["motor_us_per_bot_tick"] = _motor_phases(_count)
	if AwWeaponRig.phase_timers:
		# Weapon tick sub-phases (ms per tick), the split of p_weapons, and how many idle/full ticks they cover.
		var wp := {}
		for i in AwWeaponRig.PHASES.size():
			wp["rig_" + AwWeaponRig.PHASES[i]] = snappedf(AwWeaponRig.phase_us[i] / 1000.0 / maxi(1, _count), 0.001)
		for i in DotWeaponArsenal.PHASES.size():
			wp["ars_" + DotWeaponArsenal.PHASES[i]] = snappedf(DotWeaponArsenal.phase_us[i] / 1000.0 / maxi(1, _count), 0.001)
		wp["rig_calls"] = AwWeaponRig.phase_calls
		wp["ars_calls"] = DotWeaponArsenal.phase_calls
		out["weapon_phases_ms"] = wp
	print("SCALE128 ", JSON.stringify(out))


var _motorprof := false
var _spawn := false


## `--spawn 1`: respawns the dead (or, with [param all], everyone) through ArenaGame.respawn_player, about once a
## second; the match's own queue never runs without a person in it.
func _respawn_dead(game: Node, all: bool) -> void:
	for p in game.players():
		if all or not p.is_alive():
			var _r: DotResult = game.respawn_player(p.player_id)


var _shots := 0
var _hits := 0
var _heads := 0
var _kills := 0


func _tally_on(g: Object) -> void:
	g.connect(&"hit_confirmed", func(_a: int, _v: int, _amount: float, _p: Vector3, head: bool, lethal: bool) -> void:
		if _recording:
			_hits += 1
			_heads += int(head)
			_kills += int(lethal))
	for p in g.call("players"):
		p.connect(&"used", func(outcome: DotWeaponOutcome) -> void:
			if _recording and outcome != null and outcome.used:
				_shots += outcome.shots.size())


func _motor_phases(ticks: int) -> Dictionary:
	var out := {}
	if not _motorprof:
		return out
	var n := maxi(1, _bots * ticks)
	for i in DotFpsMotor.PHASES.size():
		if DotFpsMotor.PHASES[i] != "":
			out["m_" + DotFpsMotor.PHASES[i]] = snappedf(DotFpsMotor.phase_us[i] / float(n), 0.01)
	var cn := ["pre", "consume", "motor", "publish", "report", "signals+stats", "post", "other"]
	for i in cn.size():
		out["c_" + cn[i]] = snappedf(DotFpsController.phase_us[i] / float(n), 0.01)
	return out


func _begin_record() -> void:
	if _motorprof:
		DotFpsMotor.profile = true
		DotFpsMotor.phase_us.fill(0)
		DotFpsController.phase_us.fill(0)
	ArenaFrameProbe.set_interval(1.0e9)
	ArenaFrameProbe._sections.clear()
	AwWeaponRig.phase_us.fill(0)
	AwWeaponRig.phase_calls.fill(0)
	DotWeaponArsenal.phase_us.fill(0)
	DotWeaponArsenal.phase_calls.fill(0)
	_script_us.clear()
	_phys_ms.clear()
	_count = 0
	_t_start = Time.get_ticks_usec()
	_recording = true


# server

func _serve() -> void:
	var data := "user://scale128_server"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(data))
	Engine.physics_ticks_per_second = _tick
	var game := ArenaGame.new()
	game.name = "Arena"
	game.tick_rate = _tick
	game.score_limit = 0
	game.time_limit_sec = 0.0
	game.warmup_sec = 0.0
	game.headless = true
	game.mode_id = StringName(_mode)
	game.register_service = true
	add_child(game)
	var map := ArenaMap.by_id(StringName(_map))
	var _set := game.setup(map if map != null else ArenaMap.dm_box())
	var config := LoopbackServer.config("scale128", _port, data, "error", 256)
	config.tickrate = _tick
	var server := await LoopbackServer.boot(self, config, "scale128")
	if server == null:
		get_tree().quit(1)
		return
	var module := server.modules.get_module("arena") as ArenaModule
	var quota: DotBotQuota = module.get("_bot_quota")
	# The server's own quota manages the bots (fixed N): an "off" quota removes every bot a second later.
	if quota != null and quota.mode_cvar != null:
		quota.mode_cvar.force_set("fixed")
		quota.quota_cvar.force_set(str(_bots))
		quota.empty_cvar.force_set("1")
	var made := 0
	var t_add := Time.get_ticks_usec()
	while module.bridge.bot_ids().size() < _bots and (Time.get_ticks_usec() - t_add) < 60000000:
		await get_tree().create_timer(0.5).timeout
	made = module.bridge.bot_ids().size()
	var add_ms := (Time.get_ticks_usec() - t_add) / 1000.0
	game = module.game
	if _spawn:
		# With no person in it the match never runs its respawn queue: the bots would stand where they joined with
		# empty hands, and p_weapons would time unarmed players. Spawn each one the way a respawn does (loadout too).
		_respawn_dead(game, true)
	await get_tree().create_timer(_settle).timeout
	var net: DotNetManager = module.net
	var before: Dictionary = net.perf_counters()
	_begin_record()
	_tally_on(game)
	var t_end := Time.get_ticks_usec() + int(_seconds * 1.0e6)
	while Time.get_ticks_usec() < t_end:
		await get_tree().create_timer(minf(1.0, (t_end - Time.get_ticks_usec()) / 1.0e6)).timeout
		if _spawn:
			_respawn_dead(game, false)
	_recording = false
	var after: Dictionary = net.perf_counters()
	var nt := maxi(1, int(after[&"server_ticks"]) - int(before[&"server_ticks"]))
	var alive := 0
	for p in game.players():
		alive += int(p.is_alive())
	_report({
		"alive": alive, "bots_made": made, "engine_hz": Engine.physics_ticks_per_second, "players": game.players().size(), "add_bots_ms": snappedf(add_ms, 0.1),
		"net_sim_ms_per_tick": snappedf((int(after[&"server_sim_usec"]) - int(before[&"server_sim_usec"])) / 1000.0 / nt, 0.001),
		"net_send_ms_per_tick": snappedf((int(after[&"server_send_usec"]) - int(before[&"server_send_usec"])) / 1000.0 / nt, 0.001),
		"net_ticks": nt, "snapshot_every_ticks": net.config.ticks_per_snapshot(),
		"snapshot_hz": net.config.snapshot_rate, "entities": net.registry.all().size(),
	})
	get_tree().quit()


# offline

func _census(g: Node, local: Node) -> Dictionary:
	var classes := {}
	var procs := 0
	var physprocs := 0
	var scripts := 0
	var lights := 0
	var bodies := 0
	var shapes := 0
	var anim := 0
	var tags := 0
	var meshes := 0
	var nodes := 0
	var players := 0
	for p in g.players():
		if p == local:
			continue
		players += 1
		var st := [p]
		while not st.is_empty():
			var nd: Node = st.pop_back()
			st.append_array(nd.get_children())
			nodes += 1
			classes[nd.get_class()] = int(classes.get(nd.get_class(), 0)) + 1
			procs += int(nd.is_processing())
			physprocs += int(nd.is_physics_processing())
			scripts += int(nd.get_script() != null)
			lights += int(nd is Light3D)
			bodies += int(nd is PhysicsBody3D or nd is Area3D)
			shapes += int(nd is CollisionShape3D)
			anim += int(nd is AnimationPlayer or nd is AnimationTree or nd is Skeleton3D)
			tags += int(nd is Label3D or nd is Sprite3D or nd.name.to_lower().contains("tag"))
			meshes += int(nd is MeshInstance3D)
	var n := float(maxi(1, players))
	var top := []
	var keys := classes.keys()
	keys.sort_custom(func(a, b): return classes[a] > classes[b])
	for k in keys.slice(0, 8):
		top.append("%s:%.1f" % [k, classes[k] / n])
	return {
		"remote_players": players, "nodes_per_player": snappedf(nodes / n, 0.1),
		"scripts_per_player": snappedf(scripts / n, 0.1), "processing_nodes_per_player": snappedf(procs / n, 0.1),
		"physics_processing_nodes_per_player": snappedf(physprocs / n, 0.1),
		"lights_per_player": snappedf(lights / n, 0.1), "phys_bodies_areas_per_player": snappedf(bodies / n, 0.1),
		"collision_shapes_per_player": snappedf(shapes / n, 0.1), "anim_nodes_per_player": snappedf(anim / n, 0.1),
		"tag_nodes_per_player": snappedf(tags / n, 0.1), "meshes_per_player": snappedf(meshes / n, 0.1),
		"top_classes": top,
	}


func _offline() -> void:
	var client: Node = (load("res://game/arena.tscn") as PackedScene).instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	add_child(client)
	var spin := 0.0
	while spin < 90.0:
		await get_tree().create_timer(0.25).timeout
		spin += 0.25
		var g0 = client.get("game")
		var p0 = client.get("player")
		if g0 != null and p0 != null and p0.is_alive() and g0.match_node != null and g0.match_node.state == DotMatch.State.LIVE:
			break
	var g = client.get("game")
	g.tick_rate = _tick
	Engine.physics_ticks_per_second = _tick
	Engine.max_fps = 0
	await get_tree().create_timer(_settle).timeout
	var census := _census(g, client.get("player"))
	var tick0: int = g.current_tick()
	var frames := PackedFloat64Array()
	_begin_record()
	_tally_on(g)
	var t_last := Time.get_ticks_usec()
	var proc := 0.0
	var render := 0.0
	var draw := 0.0
	var n := 0
	var spikes := []
	var nodes_last := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	while (Time.get_ticks_usec() - _t_start) / 1.0e6 < _seconds:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var nodes_now := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		spikes.append([snappedf((now - t_last) / 1000.0, 0.1), nodes_now - nodes_last, snappedf((now - _t_start) / 1.0e6, 0.01)])
		nodes_last = nodes_now
		frames.append(float(now - t_last))
		t_last = now
		proc += Performance.get_monitor(Performance.TIME_PROCESS)
		draw += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		n += 1
	_recording = false
	spikes.sort_custom(func(x, y): return x[0] > y[0])
	var cold := {}
	if _role == "offline" and "--cold" in OS.get_cmdline_user_args():
		cold = await _cold(client, g)
	var wall := (Time.get_ticks_usec() - _t_start) / 1.0e6
	var game_ticks: int = g.current_tick() - tick0
	_report({
		"frame_ms": _stats(frames, 0.001), "fps": snappedf(n / wall, 0.1),
		"process_ms_mean": snappedf(proc / maxi(1, n) * 1000.0, 0.001), "draw_calls": snappedf(draw / maxi(1, n), 1.0),
		"game_ticks": game_ticks, "sim_speed": snappedf(game_ticks / wall / _tick, 3),
		"max_physics_steps_per_frame": Engine.max_physics_steps_per_frame, "census": census,
		"players": g.players().size(), "worst_frames_ms_nodes_t": spikes.slice(0, 6), "cold": cold,
	})
	get_tree().quit()


## First use against the Nth: what adding bots costs (ms and nodes each, 1st..8th), then the
## frames in which the first hurt, the first kill and the first shots land.
func _cold(client: Node, g: Node) -> Dictionary:
	var adds := []
	for i in 8:
		var nodes0 := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		var t0 := Time.get_ticks_usec()
		client.call("_add_offline_bot", "ColdBot%d" % i)
		adds.append([snappedf((Time.get_ticks_usec() - t0) / 1000.0, 0.01), int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)) - nodes0])
		await get_tree().process_frame
	var frames := []
	var nodes_last := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var t_last := Time.get_ticks_usec()
	var t_end := t_last + 15000000
	while Time.get_ticks_usec() < t_end:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var nodes_now := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		frames.append([snappedf((now - t_last) / 1000.0, 0.1), nodes_now - nodes_last])
		nodes_last = nodes_now
		t_last = now
	var spiky := frames.filter(func(f): return f[1] != 0 or f[0] > 40.0)
	spiky.sort_custom(func(x, y): return x[0] > y[0])
	return {"bot_adds_ms_nodes": adds, "spiky_frames_ms_nodes": spiky.slice(0, 12), "frames": frames.size()}
