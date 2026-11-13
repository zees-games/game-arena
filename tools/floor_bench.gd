extends "perf_bench.gd"

## The floor experiment: what each layer of a 16v16 frame costs, bottom up, in one process on one frozen view.
## Boots the real client as tools/perf_bench.gd does (map, mode, bots, pilot, warm-up), then freezes the whole client
## (PROCESS_MODE_DISABLED: no _process, no _physics_process, no input) so the camera and every body stay where they are,
## and measures the frame time of each step by showing more of the scene:
##   S0  no 3D (viewport disable_3d): the canvas and the present alone
##   S1  the map: its mesh, lights, environment and baked GI; players, HUD and SubViewports hidden
##   S1 toggles (each alone on S1, then restored): noshadow, nogi, nofx, nossr, notransp, msaa off/2x/4x, fxaa, taa,
##       fsr2 at 0.67, 640x360, 1920x1080, everything cheap at once, vsync on
##   S2  + each remote player's figure mesh, static (no skeleton update)
##   S3  + the figures' AnimationPlayers at full rate (callback IDLE, every frame, a looping clip)
##   S4  + every node of every player (held gun, tags, the own view model), still frozen
##   S5a + the HUD and the remaining SubViewports
##   S5b + the client's _process set (unfrozen, the engine's physics at 1 Hz, so a median frame has no tick)
##   S5c + _physics_process at the game's rate: the in-process game
## One `FLOOR_ROW {json}` per step (frame-time p50/p95/avg, render cpu/gpu, draws, objects, nodes) and `FLOOR_DONE`.
## Run windowed on a GPU box: tools/floor_bench.sh -n 3 (gpu.sh run, GPU_XORG=1, as tools/perf_bench.sh).
## `--frames N` frames a row (default 360), `--settle S` seconds before each row (default 1.5).

var _frames_n := 360
var _settle := 1.5
var _hidden: Array[Node] = []
var _anims: Array[AnimationPlayer] = []
var _subviews := {}


func _run() -> void:
	_frames_n = int(args.get("frames", 360))
	_settle = float(args.get("settle", 1.5))
	client = (load(client_scene) as PackedScene).instantiate()
	_setup_client(client)
	add_child(client)
	await wait_gate(120.0)
	await _select(client.get("game"))
	var game: Object = client.get("game")
	_start_pilot(game)
	say("floor: map %s mode %s players %d, warming %.0f s" % [map, mode, _players(game), warmup])
	await wait(warmup)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var vp := get_viewport()
	RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), true)
	say("floor: setup %s" % JSON.stringify(_setup_info(vp)))
	var tick := Engine.physics_ticks_per_second

	client.process_mode = Node.PROCESS_MODE_DISABLED
	await _row("S5c_frozen_all", "everything shown, frozen (S4+S5a)")
	var players: Array = game.call("players")
	var hud: Node = client.get("hud")
	for sv in get_tree().root.find_children("*", "SubViewport", true, false):
		_subviews[sv] = (sv as SubViewport).render_target_update_mode
		(sv as SubViewport).render_target_update_mode = SubViewport.UPDATE_DISABLED
	for p: Node in players:
		_hide(p)
	if hud != null:
		for c in hud.get_children():
			_hide(c)

	vp.disable_3d = true
	await _row("S0", "no 3D: canvas and present")
	vp.disable_3d = false
	await _row("S1", "map only")
	await _toggles(vp)

	var figures: Array[Node3D] = []
	for p: Node in players:
		var fig: Variant = p.get("figure")
		if p.get("camera") == null and fig is Node3D:
			figures.append(fig)
	for p: Node in players:
		if p.get("camera") == null:
			p.visible = true
			for g in p.find_children("*", "GeometryInstance3D", true, false):
				if not _under(g, figures) and (g as GeometryInstance3D).visible:
					_hide(g)
	await _row("S2", "+ %d figure meshes, static" % figures.size())

	for fig in figures:
		var ap: Variant = fig.get("_anim")
		if ap is AnimationPlayer:
			_anims.append(ap)
			_loop(ap)
	await _row("S3", "+ %d AnimationPlayers at full rate" % _anims.size())

	for n in _hidden.duplicate():
		if is_instance_valid(n) and not (hud != null and hud.is_ancestor_of(n)):
			_show(n)
	for sv: SubViewport in _subviews:
		if _in_players(sv, players):
			sv.render_target_update_mode = _subviews[sv]
	await _row("S4", "+ every player node, frozen")

	for n in _hidden.duplicate():
		_show(n)
	for sv: SubViewport in _subviews:
		sv.render_target_update_mode = _subviews[sv]
	await _row("S5a", "+ HUD and SubViewports")

	for ap in _anims:
		ap.process_mode = Node.PROCESS_MODE_INHERIT
		ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	Engine.physics_ticks_per_second = 1
	client.process_mode = Node.PROCESS_MODE_INHERIT
	await wait(5.0)  # let the unfrozen game catch up before the live rows
	await _row("S5b", "+ _process (physics 1 Hz)")
	Engine.physics_ticks_per_second = tick
	await wait(5.0)
	await _row("S5c", "+ _physics_process at %d Hz: the game" % tick)
	await _row("S5c_again", "the game, 5 s later")
	say("FLOOR_DONE")
	get_tree().quit(0)


## The S1 toggles, each alone and then undone; finally all the cheap ones together and vsync on.
func _toggles(vp: Viewport) -> void:
	var lights: Array[Light3D] = []
	for l in get_tree().root.find_children("*", "Light3D", true, false):
		if (l as Light3D).shadow_enabled and (l as Light3D).is_visible_in_tree():
			lights.append(l)
	for l in lights:
		l.shadow_enabled = false
	await _row("S1_noshadow", "%d shadowed lights off" % lights.size())
	for l in lights:
		l.shadow_enabled = true

	var envs := _environments()
	var gi_nodes: Array[Node3D] = []
	for t in ["LightmapGI", "VoxelGI", "ReflectionProbe"]:
		for n in get_tree().root.find_children("*", t, true, false):
			if (n as Node3D).visible:
				gi_nodes.append(n)
	var sdfgi := []
	for e in envs:
		sdfgi.append(e.sdfgi_enabled)
		e.sdfgi_enabled = false
	for n in gi_nodes:
		n.visible = false
	await _row("S1_nogi", "%d GI/probe nodes hidden, sdfgi off (was %s)" % [gi_nodes.size(), str(sdfgi)])
	for i in envs.size():
		envs[i].sdfgi_enabled = sdfgi[i]
	for n in gi_nodes:
		n.visible = true

	var fx := ["ssao_enabled", "ssil_enabled", "ssr_enabled", "glow_enabled", "fog_enabled", "volumetric_fog_enabled"]
	var was := []
	for e in envs:
		var row := {}
		for k: String in fx:
			row[k] = e.get(k)
			e.set(k, false)
		was.append(row)
	await _row("S1_nofx", "ssao/ssil/ssr/glow/fog/volfog off (was %s)" % JSON.stringify(was))
	for i in envs.size():
		for k: String in was[i]:
			envs[i].set(k, was[i][k])

	var transp: Array[GeometryInstance3D] = []
	for g in get_tree().root.find_children("*", "MeshInstance3D", true, false):
		if (g as MeshInstance3D).is_visible_in_tree() and _transparent(g):
			transp.append(g)
	for g in transp:
		g.visible = false
	await _row("S1_notransp", "%d transparent meshes hidden" % transp.size())
	for g in transp:
		g.visible = true

	var msaa := vp.msaa_3d
	var ssaa := vp.screen_space_aa
	var taa := vp.use_taa
	var mode := vp.scaling_3d_mode
	var scale := vp.scaling_3d_scale
	for m in [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X]:
		vp.msaa_3d = m
		await _row("S1_msaa%d" % [0, 2, 4][m], "msaa_3d %dx (was enum %d)" % [[0, 2, 4][m], msaa])
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	await _row("S1_fxaa", "fxaa, msaa off")
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	vp.use_taa = true
	await _row("S1_taa", "taa, msaa off")
	vp.use_taa = false
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	vp.scaling_3d_scale = 0.67
	await _row("S1_fsr2", "fsr2 at 0.67, msaa off")
	vp.scaling_3d_mode = mode
	vp.scaling_3d_scale = scale
	vp.msaa_3d = msaa
	vp.screen_space_aa = ssaa
	vp.use_taa = taa

	var size := get_window().size
	for wh in [Vector2i(640, 360), Vector2i(1920, 1080)]:
		get_window().size = wh
		await _row("S1_%dx%d" % [wh.x, wh.y], "window %s (was %s)" % [wh, size])
	get_window().size = size

	# Everything cheap at once: the floor of this map at this resolution.
	for l in lights:
		l.shadow_enabled = false
	for e in envs:
		e.sdfgi_enabled = false
		for k: String in fx:
			e.set(k, false)
	for n in gi_nodes:
		n.visible = false
	for g in transp:
		g.visible = false
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	vp.use_taa = false
	await _row("S1_allcheap", "noshadow+nogi+nofx+notransp+no AA")
	for l in lights:
		l.shadow_enabled = true
	for i in envs.size():
		envs[i].sdfgi_enabled = sdfgi[i]
		for k: String in was[i]:
			envs[i].set(k, was[i][k])
	for n in gi_nodes:
		n.visible = true
	for g in transp:
		g.visible = true
	vp.msaa_3d = msaa
	vp.screen_space_aa = ssaa
	vp.use_taa = taa

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	await _row("S1_vsync", "vsync on (headless Xorg, no compositor)")
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	await _row("S1_again", "map only, all restored (drift check)")


func _row(id: String, what: String) -> void:
	await wait(_settle)
	var vp_rid := get_viewport().get_viewport_rid()
	var gpu := 0.0
	var cpu := 0.0
	var draws := 0.0
	var objs := 0.0
	var ms := PackedFloat32Array()
	var last := Time.get_ticks_usec()
	for i in _frames_n:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		ms.append((now - last) / 1000.0)
		last = now
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp_rid)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp_rid) + RenderingServer.get_frame_setup_time_cpu()
		draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		objs += Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	var st := frame_stats(ms)
	var n := float(_frames_n)
	var row := {"id": id, "what": what, "p50": st.p50, "p95": st.p95, "avg": st.avg, "gpu": snappedf(gpu / n, 0.01), "rcpu": snappedf(cpu / n, 0.01),
		"draws": roundi(draws / n), "objects": roundi(objs / n), "nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"physics_ms": snappedf(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, 0.01),
		"process_ms": snappedf(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, 0.01)}
	print("FLOOR_ROW %s" % JSON.stringify(row))


func _setup_info(vp: Viewport) -> Dictionary:
	var envs := _environments()
	var e: Environment = envs[0] if not envs.is_empty() else null
	return {"window": get_window().size, "vsync_was": DisplayServer.window_get_vsync_mode(), "msaa": vp.msaa_3d, "ssaa": vp.screen_space_aa, "taa": vp.use_taa,
		"scaling": [vp.scaling_3d_mode, vp.scaling_3d_scale], "physics": ProjectSettings.get_setting("physics/3d/physics_engine"),
		"renderer": RenderingServer.get_current_rendering_method(), "gpu": RenderingServer.get_video_adapter_name(),
		"lights": get_tree().root.find_children("*", "Light3D", true, false).size(), "subviewports": get_tree().root.find_children("*", "SubViewport", true, false).size(),
		"env": {} if e == null else {"sdfgi": e.sdfgi_enabled, "ssao": e.ssao_enabled, "ssil": e.ssil_enabled, "ssr": e.ssr_enabled, "glow": e.glow_enabled, "fog": e.fog_enabled, "volfog": e.volumetric_fog_enabled},
		"godot": Engine.get_version_info().string}


func _environments() -> Array[Environment]:
	var envs: Array[Environment] = []
	for we in get_tree().root.find_children("*", "WorldEnvironment", true, false):
		if (we as WorldEnvironment).environment != null and not envs.has((we as WorldEnvironment).environment):
			envs.append((we as WorldEnvironment).environment)
	for cam in get_tree().root.find_children("*", "Camera3D", true, false):
		var e := (cam as Camera3D).environment
		if e != null and not envs.has(e):
			envs.append(e)
	return envs


func _transparent(g: MeshInstance3D) -> bool:
	if g.mesh == null:
		return false
	for s in g.mesh.get_surface_count():
		var m := g.get_active_material(s)
		if m is BaseMaterial3D and (m as BaseMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			return true
	return false


func _loop(ap: AnimationPlayer) -> void:
	var names := ap.get_animation_list()
	if names.is_empty():
		return
	var pick := String(ap.current_animation)
	for want in ["run", "walk", "idle"]:
		if pick != "":
			break
		for a in names:
			if want in String(a).to_lower():
				pick = a
				break
	if pick == "":
		pick = names[0]
	ap.get_animation(pick).loop_mode = Animation.LOOP_LINEAR
	ap.process_mode = Node.PROCESS_MODE_ALWAYS
	ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	ap.play(pick)


func _hide(n: Node) -> void:
	if n.get("visible") == true:
		n.set("visible", false)
		_hidden.append(n)


func _show(n: Node) -> void:
	if is_instance_valid(n):
		n.set("visible", true)
	_hidden.erase(n)


static func _under(n: Node, roots: Array[Node3D]) -> bool:
	for r in roots:
		if r == n or r.is_ancestor_of(n):
			return true
	return false


static func _in_players(n: Node, players: Array) -> bool:
	for p: Node in players:
		if p.is_ancestor_of(n):
			return true
	return false
