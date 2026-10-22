extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaModule := preload("../game/arena_module.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaFrameProbe := preload("../game/arena_frame_probe.gd")
const StallRecorder := preload("stall_recorder.gd")

## dot-net's lossy UDP relay, by path (it has no class_name): the latency simulator.
const Relay := preload("res://addons/dot_net/testing/dot_net_udp_relay.gd")

## What a CONNECTED client's frame costs, and whether the round trip changes it: the real
## client (`arena.tscn`) in this process, a dedicated arena server with hunting bots in a
## second one, and dot-net's relay between them adding a delay each way.
##
## [codeblock]
## godot --headless --path . res://tools/client_bench.tscn -- --bots 3 --delay 30 --seconds 15
## godot --headless --path . res://tools/client_bench.tscn -- --delay 30 --burn 20   # a slow device
## xvfb-run -a godot --path . res://tools/client_bench.tscn -- --delay 30            # with drawing
## ... -- --stall   the frames around the loading cover instead (load_stall's connected twin)
## [/codeblock]
##
## `--delay` is milliseconds EACH WAY (so 30 is a 60 ms round trip). `--burn MS` spends MS of
## wall time in every frame's `_process` before the client runs, which is what a device whose
## script runs several times slower than this one does to the loop: the question this tool
## exists for is whether a slow frame makes the next one slower (more physics steps, a longer
## input lead, longer replays), which a fast headless frame can never show.
##
## Why two processes: the server's tick in the same process would be in every number the
## client is judged by. The server is this scene again with `--role server`, killed at the end.
## It asserts nothing; it prints one summary.

const PORT := 27198

var _role := "client"
var _bots := 3
var _delay := 30.0
var _jitter := 0.0
var _seconds := 15.0
var _burn_ms := 0.0
var _port := PORT
var _map := "dm_box"
var _mode := "ffa"
var _play := false
## The server game's tick rate. 60 is dot-server's default `sv_tickrate`; 64 is ArenaGame's.
var _tick := 60

var _server_pid := -1
var _relay = null
var _client: Node = null


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--role": _role = args[i + 1]
			"--bots": _bots = int(args[i + 1])
			"--delay": _delay = float(args[i + 1])
			"--jitter": _jitter = float(args[i + 1])
			"--seconds": _seconds = float(args[i + 1])
			"--burn": _burn_ms = float(args[i + 1])
			"--port": _port = int(args[i + 1])
			"--map": _map = args[i + 1]
			"--mode": _mode = args[i + 1]
			"--tick": _tick = int(args[i + 1])
	_play = "--play" in args
	DotLog.set_level(DotLog.Level.ERROR)
	var _scratch := ArenaPresentation.use_scratch_settings("client_bench_" + _role)
	if _role == "server":
		_serve.call_deferred()
	else:
		_run.call_deferred()


# --- The server process ---------------------------------------------------------

func _serve() -> void:
	var data := "user://client_bench_server"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(data))
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

	var config := DotServerConfig.new()
	config.hostname = "client bench"
	config.port = _port
	config.bind_address = "127.0.0.1"
	config.transport_mode = "dual"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % data
	config.bans_path = "%s/bans.json" % data
	config.audit_log_path = "%s/audit.jsonl" % data
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""
	config.query_enabled = false
	config.enet_share_udp_port = false
	config.stdin_console_enabled = false
	config.log_level = "error"
	var server := DotServer.new()
	server.name = "Server"
	server.config = config
	server.config_file = ""
	server.auto_boot = false
	add_child(server)
	var booted: DotResult = await server.boot()
	if not booted.ok:
		printerr("client_bench server: ", booted.error)
		get_tree().quit(1)
		return
	var loaded: DotResult = await server.modules.load_module("res://game/arena_module.gd")
	if not loaded.ok:
		printerr("client_bench server: ", loaded.error)
		get_tree().quit(1)
		return
	var module := server.modules.get_module("arena") as ArenaModule
	var quota: DotBotQuota = module.get("_bot_quota")
	if quota != null and quota.mode_cvar != null:
		quota.mode_cvar.force_set("off")
	for i in _bots:
		var _id: int = module.bridge.add_bot("Bot %d" % (i + 1))
	print("client_bench server: ready on %d (enet %d) with %d bots" % [_port, config.effective_enet_port(), _bots])
	_report_server(module.net)


## Every 5 s: the server's real tick rate against its declared one, what a tick costs
## (dot-net's server counters), snapshots and bytes a second per client, entity count.
func _report_server(net: DotNetManager) -> void:
	var last: Dictionary = net.perf_counters()
	var t0 := Time.get_ticks_usec()
	while true:
		await get_tree().create_timer(5.0).timeout
		var now: Dictionary = net.perf_counters()
		var secs := (Time.get_ticks_usec() - t0) / 1.0e6
		var ticks := maxi(1, int(now[&"server_ticks"]) - int(last[&"server_ticks"]))
		var peers := PackedStringArray()
		for peer in net.budget.peer_ids():
			var d := net.budget.describe_peer(peer)
			peers.append("%d B/s %d pkt/s" % [int(d.get("bytes_per_sec", 0)), int(d.get("packets_per_sec", 0))])
		print("server: %.1f ticks/s (declared %d, engine %d Hz) | sim %.3f ms/tick send %.3f ms/tick | snapshot every %d ticks | entities %d | peers %s" % [
			ticks / secs, net.config.tick_rate, Engine.physics_ticks_per_second,
			(int(now[&"server_sim_usec"]) - int(last[&"server_sim_usec"])) / 1000.0 / ticks,
			(int(now[&"server_send_usec"]) - int(last[&"server_send_usec"])) / 1000.0 / ticks,
			net.config.ticks_per_snapshot(), net.registry.all().size(), ", ".join(peers)])
		last = now
		t0 = Time.get_ticks_usec()


# --- The client process ---------------------------------------------------------

## Burns wall time at the top of every frame, before anything of the client's runs.
class Burner extends Node:
	var ms := 0.0

	func _process(_delta: float) -> void:
		if ms <= 0.0:
			return
		var until := Time.get_ticks_usec() + int(ms * 1000.0)
		while Time.get_ticks_usec() < until:
			pass


## `--play`: a player rather than a statue. Runs and strafes in bursts, turns, jumps, holds
## the trigger most of the time and swaps weapons now and then, so the bench's bots have a
## moving target that shoots back, and the client's prediction covers firing, reloads,
## switches, damage, deaths and respawns: what a match is, and what an idle bench never was.
class Pilot extends Node:
	var _t := 0.0
	var _rng := RandomNumberGenerator.new()
	var _next := 0.0

	func _ready() -> void:
		_rng.seed = 20261017
		Input.action_press(&"dot_fps_forward")
		Input.action_press(&"arena_fire")

	func _process(delta: float) -> void:
		_t += delta
		var turn := InputEventMouseMotion.new()
		turn.relative = Vector2(sin(_t * 0.7) * 6.0, sin(_t * 1.3) * 1.5)
		Input.parse_input_event(turn)
		if _t < _next:
			return
		_next = _t + _rng.randf_range(0.3, 1.2)
		for a: StringName in [&"dot_fps_left", &"dot_fps_right", &"dot_fps_jump"]:
			Input.action_release(a)
		match _rng.randi_range(0, 5):
			0: Input.action_press(&"dot_fps_left")
			1: Input.action_press(&"dot_fps_right")
			2: Input.action_press(&"dot_fps_jump")
			3:
				if _rng.randf() < 0.5:
					Input.action_release(&"arena_fire")
				else:
					Input.action_press(&"arena_fire")
			4:
				var wheel := InputEventMouseButton.new()
				wheel.button_index = MOUSE_BUTTON_WHEEL_UP if _rng.randf() < 0.5 else MOUSE_BUTTON_WHEEL_DOWN
				wheel.pressed = true
				Input.parse_input_event(wheel)


func _run() -> void:
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
		"res://tools/client_bench.tscn", "--", "--role", "server", "--port", str(_port),
		"--bots", str(_bots), "--map", _map, "--mode", _mode, "--tick", str(_tick)])
	_server_pid = OS.create_process(OS.get_executable_path(), args)
	if _server_pid <= 0:
		printerr("client_bench: could not start the server")
		get_tree().quit(1)
		return
	await get_tree().create_timer(6.0).timeout

	_relay = Relay.new()
	_relay.seed = 20261016
	_relay.up.configure(0.0, _delay, _jitter)
	_relay.down.configure(0.0, _delay, _jitter)
	var relayed: DotResult = _relay.start(0, "127.0.0.1", _port)
	if not relayed.ok:
		return _fail("relay: %s" % relayed.error)

	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Bench"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % _relay.port()
	add_child(link)
	link.connect_to_server("127.0.0.1:%d" % _port)
	var t := 0.0
	while not link.is_playing() and t < 30.0:
		await get_tree().create_timer(0.25).timeout
		t += 0.25
	if not link.is_playing():
		return _fail("never connected")

	var burner := Burner.new()
	burner.ms = _burn_ms
	burner.process_priority = -1000
	add_child(burner)

	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("mouse_capture_override", true)
	var stall: RefCounted = null
	if "--stall" in OS.get_cmdline_user_args():
		stall = StallRecorder.new()
		stall.start(get_tree())
	add_child(_client)
	if stall != null:
		stall.watch(_client.get("gate"))
		t = 0.0
		while stall.open_seconds() < 3.0 and t < 60.0:
			await get_tree().process_frame
			t += get_process_delta_time()
		stall.stop()
		for line in stall.lines(2.0):
			print(line)
		link.disconnect_from_server("done")
		_finish(0)
		return
	t = 0.0
	while t < 40.0:
		await get_tree().create_timer(0.25).timeout
		t += 0.25
		var p = _client.get("player")
		var net = _client.get("net")
		if p != null and p.is_alive() and net != null and net.clock.is_synced():
			break
	# `--raw-input`: predict on the sampled command rather than the one the wire carries
	# (DotNetConfig.predict_wire_input), to measure what the rounding is worth.
	var client_net = _client.get("net")
	if "--raw-input" in OS.get_cmdline_user_args() and client_net != null and "predict_wire_input" in client_net.config:
		client_net.config.predict_wire_input = false
	# After the client, whose bindings register the actions the pilot presses.
	if _play:
		var pilot := Pilot.new()
		pilot.process_priority = -999
		add_child(pilot)
	# Settle: the first seconds are loading and the clock finding its lead.
	await get_tree().create_timer(3.0).timeout
	Engine.max_fps = 0
	_switch_off()
	_hide()
	await _measure()
	link.disconnect_from_server("done")
	_finish(0)


## `--off a,b`: stops `_process` and `_physics_process` on every node whose script path
## contains one of the names (`physics_server` stops the physics server itself), so a
## piece's cost is the drop in the numbers. A measurement aid; the client misbehaves.
func _switch_off() -> void:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--off")
	if at < 0 or at + 1 >= args.size():
		return
	var names := args[at + 1].split(",")
	if names.has("physics_server"):
		PhysicsServer3D.set_active(false)
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		stack.append_array(nd.get_children())
		var path := str(nd.get_script().resource_path) if nd.get_script() != null else ""
		for name_part in names:
			if path != "" and path.contains(name_part):
				nd.set_process(false)
				nd.set_physics_process(false)


## `--hide a,b`: render ablation. `shadow` turns off every light's shadow, `light:<Name>`
## hides lights whose node name contains Name, `viewports` stops every SubViewport,
## `canvas` hides every CanvasLayer (the HUD), `node:<Name>` hides Node3Ds whose name contains Name. The drop in draws and objects is
## that piece's share.
func _hide() -> void:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--hide")
	if at < 0 or at + 1 >= args.size():
		return
	var names := args[at + 1].split(",")
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		stack.append_array(nd.get_children())
		for want in names:
			if want == "shadow" and nd is Light3D:
				(nd as Light3D).shadow_enabled = false
			elif want.begins_with("light:") and nd is Light3D and String(nd.name).contains(want.substr(6)):
				(nd as Light3D).visible = false
			elif want == "viewports" and nd is SubViewport:
				(nd as SubViewport).render_target_update_mode = SubViewport.UPDATE_DISABLED
			elif want == "canvas" and nd is CanvasLayer:
				(nd as CanvasLayer).visible = false
			elif want.begins_with("node:") and nd is Node3D and String(nd.name).contains(want.substr(5)):
				(nd as Node3D).visible = false
	print("hidden: ", names)


## `--mismatches`: every reconcile the prediction missed, by how far, so a run can tell
## rounding (under 2 cm) from a real disagreement and a teleport (a respawn).
var _mm_seen := -1
var _mm_rows: Array = []


func _note_mismatch(last: Dictionary) -> void:
	if last.is_empty() or int(last["tick"]) == _mm_seen:
		return
	_mm_seen = int(last["tick"])
	var a: Variant = last["predicted"]
	var b: Variant = last["received"]
	var d := -1.0
	if a is Vector3 and b is Vector3:
		d = (a as Vector3).distance_to(b as Vector3)
	var p = _client.get("player")
	_mm_rows.append([_mm_seen, String(last["property"]), d, p != null and p.is_alive(), a, b])


func _print_mismatches() -> void:
	var buckets := {"<2cm": 0, "2-10cm": 0, "10cm-1m": 0, ">1m": 0, "other": 0}
	var by_prop := {}
	for r in _mm_rows:
		by_prop[r[1]] = int(by_prop.get(r[1], 0)) + 1
		var d: float = r[2]
		var k := "other" if d < 0.0 else ("<2cm" if d < 0.02 else ("2-10cm" if d < 0.1 else ("10cm-1m" if d < 1.0 else ">1m")))
		buckets[k] += 1
	print("  mismatches seen %d %s %s" % [_mm_rows.size(), by_prop, buckets])
	for r in _mm_rows.slice(0, 25):
		print("    tick %d %-20s %.4f alive %s pred %s recv %s" % r)


func _measure() -> void:
	ArenaFrameProbe.set_interval(1.0e9)
	var frames := PackedFloat32Array()
	var steps := PackedInt32Array()
	var calls := 0.0
	var objs := 0.0
	var last := Time.get_ticks_usec()
	var last_phys := Engine.get_physics_frames()
	var start := last
	var net: DotNetManager = _client.get("net")
	var lead_sum := 0.0
	# Wall-clock parts of each frame. TIME_PROCESS / TIME_PHYSICS_PROCESS are each second's
	# slowest frame, not a per-frame figure, so they are no longer averaged here.
	var fclock := DotMenuFrameClock.new()
	fclock.start(get_tree())
	var perf0: Dictionary = net.perf_counters() if net != null and net.has_method(&"perf_counters") else {}
	var next_line := start + 2000000
	var line_perf: Dictionary = perf0
	var line_mm: Dictionary = {}
	while (Time.get_ticks_usec() - start) / 1.0e6 < _seconds:
		await get_tree().process_frame
		if "--timeline" in OS.get_cmdline_user_args() and Time.get_ticks_usec() >= next_line and net != null:
			next_line += 2000000
			var pc: Dictionary = net.perf_counters()
			var mm: Dictionary = net.predictor.describe().get("mismatches", {})
			var diff := {}
			for k in mm:
				var dv := int(mm[k]) - int(line_mm.get(k, 0))
				if dv > 0:
					diff[k] = dv
			var p = _client.get("player")
			print("  t=%4.1f alive %s replays %d skipped %d ticks %d steps %d %s" % [(Time.get_ticks_usec() - start) / 1e6,
				p != null and p.is_alive(), int(pc[&"reconciles"]) - int(line_perf[&"reconciles"]) - (int(pc[&"skipped"]) - int(line_perf[&"skipped"])),
				int(pc[&"skipped"]) - int(line_perf[&"skipped"]), int(pc[&"replayed_ticks"]) - int(line_perf[&"replayed_ticks"]),
				int(pc[&"client_ticks"]) - int(line_perf[&"client_ticks"]), diff])
			print("      last ", net.predictor.describe().get("last_mismatch", {}), " | draws %d objects %d" % [
				int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
				int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))])
			line_perf = pc
			line_mm = mm
		if net != null and "--mismatches" in OS.get_cmdline_user_args():
			_note_mismatch(net.predictor.describe().get("last_mismatch", {}))
		var now := Time.get_ticks_usec()
		frames.append((now - last) / 1000.0)
		last = now
		var pf := Engine.get_physics_frames()
		steps.append(pf - last_phys)
		last_phys = pf
		calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		objs += Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
		if net != null:
			lead_sum += float(net.clock.describe().get("lead", 0.0))
	var n := frames.size()
	var sorted := frames.duplicate()
	sorted.sort()
	var step_sum := 0
	var step_max := 0
	for s in steps:
		step_sum += s
		step_max = maxi(step_max, s)
	var elapsed := (Time.get_ticks_usec() - start) / 1.0e6
	if "--mismatches" in OS.get_cmdline_user_args():
		_print_mismatches()
	print("client_bench: delay %d ms each way, burn %.1f ms, %d bots, %.0f s" % [roundi(_delay), _burn_ms, _bots, elapsed])
	print("  fps %.1f | frame p50 %.1f p95 %.1f max %.1f ms" % [n / elapsed, sorted[n / 2], sorted[int(n * 0.95)], sorted[n - 1]])
	var fs := fclock.summary(elapsed + 1.0)
	fclock.stop()
	print("  physics %.2f ms/frame (%.2f ms/step) | script %.2f | render %.2f | wait %.2f | steps %.2f/frame (max %d) | draw calls %.0f objects %.0f" % [
		fs["physics_ms"], float(fs["physics_ms"]) / maxf(0.01, float(fs["steps"])), fs["script_ms"], fs["render_ms"], fs["wait_ms"],
		float(step_sum) / n, step_max, calls / n, objs / n])
	if not perf0.is_empty():
		var p1: Dictionary = net.perf_counters()
		var d := func(k: StringName) -> float: return float(int(p1[k]) - int(perf0[k]))
		print("  net: snapshots %.1f/frame %.3f ms | reconciles %.0f (skipped %.0f) %.3f ms/frame | replayed %.2f ticks/frame | predict %.3f ms/frame" % [
			d.call(&"snapshots") / n, d.call(&"snapshot_usec") / n / 1000.0, d.call(&"reconciles"), d.call(&"skipped"),
			d.call(&"reconcile_usec") / n / 1000.0, d.call(&"replayed_ticks") / n, d.call(&"predict_usec") / n / 1000.0])
	if net != null and net.predictor != null:
		print("  predictor %s | predicted identities %d" % [net.predictor.describe(), net.registry.predicted().size()])
	var clock: Dictionary = net.clock.describe() if net != null else {}
	print("  input lead %.1f ticks avg | clock rtt %s ms, jitter %s, snaps %s, catch-ups %s" % [lead_sum / n,
		clock.get("rtt_ms"), clock.get("jitter_ms"), clock.get("snaps"), clock.get("catch_ups")])
	for key: StringName in ArenaFrameProbe._sections:
		var row: PackedInt64Array = ArenaFrameProbe._sections[key]
		if String(key).ends_with("_n"):
			print("  %-12s %.1f/frame max %d" % [key, float(row[0]) / n, row[2]])
		else:
			print("  %-12s %.3f ms/frame  max %.2f  x%.2f" % [key, float(row[0]) / n / 1000.0, row[2] / 1000.0, float(row[1]) / n])
	ArenaFrameProbe.set_interval(0.0)
	print("  physics3d active %d pairs %d | nodes %d" % [
		int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
		int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))])
	if "--nodes" in OS.get_cmdline_user_args():
		var by := {}
		var stack: Array[Node] = [get_tree().root]
		while not stack.is_empty():
			var nd: Node = stack.pop_back()
			stack.append_array(nd.get_children())
			if not (nd.is_physics_processing() or nd.is_processing()):
				continue
			var key := str(nd.get_script().resource_path) if nd.get_script() != null else nd.get_class()
			var e: Array = by.get(key, [0, 0, 0])
			e[0] += 1
			e[1] += int(nd.is_physics_processing())
			e[2] += int(nd.is_processing())
			by[key] = e
		for k: String in by:
			print("    %-70s n=%d phys=%d proc=%d" % [k, by[k][0], by[k][1], by[k][2]])

	if OS.get_cmdline_user_args().has("--render"):
		_print_render()


## `--render`: what the frame asks the GPU for, which a machine without one cannot time but
## can count: the viewport's anti-aliasing and scale, every light and whether it casts
## shadows, the environment's post effects, and the meshes, particles and materials drawn.
func _print_render() -> void:
	var vp := get_viewport()
	print("  viewport msaa %d fxaa %d scale %.2f mode %d" % [vp.msaa_3d, vp.screen_space_aa, vp.scaling_3d_scale, vp.scaling_3d_mode])
	var meshes := 0
	var cast := 0
	var particles := 0
	var mats := {}
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		stack.append_array(nd.get_children())
		if nd is Light3D:
			var l := nd as Light3D
			print("    light %-18s %-40s shadow %s visible %s" % [l.get_class(), str(l.get_path()).right(40), l.shadow_enabled, l.is_visible_in_tree()])
		elif nd is WorldEnvironment and (nd as WorldEnvironment).environment != null:
			var e := (nd as WorldEnvironment).environment
			print("    environment bg %d glow %s ssao %s ssr %s sdfgi %s fog %s vol %s tonemap %d" % [e.background_mode, e.glow_enabled, e.ssao_enabled, e.ssr_enabled, e.sdfgi_enabled, e.fog_enabled, e.volumetric_fog_enabled, e.tonemap_mode])
		elif nd is GPUParticles3D or nd is CPUParticles3D:
			particles += int((nd as Node3D).is_visible_in_tree())
		elif nd is MeshInstance3D and (nd as Node3D).is_visible_in_tree():
			var mi := nd as MeshInstance3D
			meshes += 1
			cast += int(mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
			if mi.mesh != null:
				for i in mi.mesh.get_surface_count():
					var m := mi.get_active_material(i)
					if m != null:
						mats[m.get_rid()] = true
	print("    visible meshes %d (shadow casters %d) | particles %d | distinct materials %d" % [meshes, cast, particles, mats.size()])
	# Every visible geometry instance by class and by the nearest scripted ancestor: what the
	# renderer's object count is made of (it counts each again per shadow split).
	var by := {}
	stack = [get_tree().root]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		stack.append_array(nd.get_children())
		if not (nd is VisualInstance3D) or not (nd as Node3D).is_visible_in_tree():
			continue
		var owner_node: Node = nd.get_parent()
		while owner_node != null and owner_node.get_script() == null:
			owner_node = owner_node.get_parent()
		var key := "%s in %s" % [nd.get_class(), (owner_node.get_script() as Script).resource_path.get_file() if owner_node != null else "-"]
		by[key] = int(by.get(key, 0)) + 1
	for k: String in by:
		if int(by[k]) >= 3:
			print("      %4d  %s" % [by[k], k])


func _fail(why: String) -> void:
	printerr("client_bench: ", why)
	_finish(1)


func _finish(code: int) -> void:
	if _relay != null:
		_relay.stop()
	if _server_pid > 0:
		var _k := OS.kill(_server_pid)
	get_tree().quit(code)
