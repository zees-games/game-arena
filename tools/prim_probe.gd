extends Node

## Solo client with N bots: the renderer's draws and primitives per frame, and which nodes hold the primitives.
## `xvfb-run -a godot --path . --rendering-driver opengl3 res://tools/prim_probe.tscn -- --bots 5 --seconds 12`.

const ArenaFrameProbe := preload("../game/arena_frame_probe.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")
const ClientBench := preload("client_bench.gd")

var _bots := 5
var _seconds := 12.0
var _client: Node = null


func _ready() -> void:
	preload("../game/arena_weapon_roles.gd").ensure()
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--bots": _bots = int(args[i + 1])
			"--seconds": _seconds = float(args[i + 1])
	var _scratch := ArenaPresentation.use_scratch_settings("prim_probe")
	_run.call_deferred()


func _run() -> void:
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("mouse_capture_override", true)
	_client.set("offline_bots", _bots)
	add_child(_client)
	var pilot := ClientBench.Pilot.new()
	pilot.process_priority = -999
	add_child(pilot)
	var t0 := Time.get_ticks_usec()
	var draws := PackedInt64Array()
	var prims := PackedInt64Array()
	var objs := PackedInt64Array()
	var proc := 0.0
	var frames_ms := PackedFloat64Array()
	var cpu_ms := PackedFloat64Array()
	var gpu_ms := PackedFloat64Array()
	var rid := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	var proc_ms := PackedFloat64Array()
	var last := Time.get_ticks_usec()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var n := 0
	while (Time.get_ticks_usec() - t0) / 1.0e6 < _seconds:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var dt := (now - last) / 1000.0
		last = now
		if (Time.get_ticks_usec() - t0) / 1.0e6 < _seconds * 0.5:
			continue
		frames_ms.append(dt)
		cpu_ms.append(RenderingServer.viewport_get_measured_render_time_cpu(rid) + RenderingServer.get_frame_setup_time_cpu())
		gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
		proc_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		draws.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
		prims.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
		objs.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME))
		proc += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		n += 1
	draws.sort(); prims.sort(); objs.sort(); frames_ms.sort(); cpu_ms.sort(); gpu_ms.sort(); proc_ms.sort()
	print("PRIM_PROBE render cpu p50 %.2f ms, gpu p50 %.2f ms (p95 %.2f), script process p50 %.2f ms" % [cpu_ms[n / 2], gpu_ms[n / 2], gpu_ms[n * 95 / 100], proc_ms[n / 2]])
	print("PRIM_PROBE frame ms p50 %.2f p95 %.2f max %.2f | gpu %s" % [frames_ms[n / 2], frames_ms[n * 95 / 100], frames_ms[n - 1], RenderingServer.get_video_adapter_name()])
	print("PRIM_PROBE frames %d draws p50 %d max %d | prims p50 %d max %d | objects p50 %d | process %.2f ms" % [
		n, draws[n / 2], draws[n - 1], prims[n / 2], prims[n - 1], objs[n / 2], proc / maxi(n, 1)])
	var groups := {}
	var shadow_tris := 0
	var total := 0
	for node in get_tree().root.find_children("*", "GeometryInstance3D", true, false):
		var gi := node as GeometryInstance3D
		if not gi.is_visible_in_tree():
			continue
		var tris := _tris(gi)
		if tris == 0:
			continue
		total += tris
		if gi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			shadow_tris += tris
		var key := _group(gi)
		var row: Array = groups.get(key, [0, 0])
		row[0] += tris
		row[1] += 1
		groups[key] = row
	print("PRIM_PROBE visible triangles %d, of them shadow casting %d" % [total, shadow_tris])
	var keys := groups.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return groups[a][0] > groups[b][0])
	for k: String in keys.slice(0, 25):
		print("  %9d tris %4d nodes  %s" % [groups[k][0], groups[k][1], k])
	var census := {}
	for node in get_tree().root.find_children("*", "", true, false):
		var kind := ""
		if node is Light3D and (node as Light3D).is_visible_in_tree():
			kind = "%s shadow=%s" % [node.get_class(), (node as Light3D).shadow_enabled]
		elif node is GPUParticles3D and (node as GPUParticles3D).emitting:
			kind = "GPUParticles3D emitting"
		elif node is CPUParticles3D and (node as CPUParticles3D).emitting:
			kind = "CPUParticles3D emitting"
		elif node is SubViewport and (node as SubViewport).render_target_update_mode != SubViewport.UPDATE_DISABLED:
			kind = "SubViewport update %d" % (node as SubViewport).render_target_update_mode
		elif node is ReflectionProbe or node is VoxelGI or node is LightmapGI:
			kind = node.get_class()
		if kind != "":
			var key := kind + "  " + _group(node).split("  [")[0]
			census[key] = int(census.get(key, 0)) + 1
	for k: String in census:
		print("  census %4d  %s" % [census[k], k])
	var win := get_viewport()
	print("PRIM_PROBE viewport msaa3d %d scaling %d size %s shadow atlas %d" % [win.msaa_3d, win.scaling_3d_mode, str(win.size), win.positional_shadow_atlas_size])
	get_tree().quit(0)


func _tris(gi: GeometryInstance3D) -> int:
	var mesh: Mesh = null
	if gi is MeshInstance3D:
		mesh = (gi as MeshInstance3D).mesh
	elif gi is MultiMeshInstance3D and (gi as MultiMeshInstance3D).multimesh != null:
		var mm := (gi as MultiMeshInstance3D).multimesh
		if mm.mesh == null:
			return 0
		return _mesh_tris(mm.mesh) * (mm.visible_instance_count if mm.visible_instance_count >= 0 else mm.instance_count)
	if mesh == null:
		return 0
	return _mesh_tris(mesh)


func _mesh_tris(mesh: Mesh) -> int:
	var t := 0
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		var idx: Variant = arr[Mesh.ARRAY_INDEX]
		if idx is PackedInt32Array and (idx as PackedInt32Array).size() > 0:
			t += (idx as PackedInt32Array).size() / 3
		else:
			t += (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return t


## The node's path with numbers and per-instance names folded, cut to four segments under the client.
func _group(gi: Node) -> String:
	var parts := str(_client.get_path_to(gi)).split("/")
	var out := PackedStringArray()
	for p in parts.slice(0, 4):
		var q := p
		for d in "0123456789":
			q = q.replace(d, "#")
		out.append(q)
	var mesh_path := ""
	if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null:
		mesh_path = (gi as MeshInstance3D).mesh.resource_path.get_file().get_slice("::", 0)
	return "/".join(out) + ("  [" + mesh_path + "]" if mesh_path != "" else "")
