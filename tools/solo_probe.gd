extends Node

const ArenaPresentation := preload("../game/arena_presentation.gd")

## Where a solo frame goes: the real offline client among N bots, sampling Godot's own
## monitors once a frame. Under `--headless` the render numbers are zero and what remains is
## script and physics time; under xvfb they are the software renderer's, so read draw calls,
## primitives and objects (what the scene submits), not milliseconds of GPU.
##
## [codeblock]
## godot --headless --path . res://tools/solo_probe.tscn -- --bots 8 --seconds 10
## xvfb-run -a godot --path . res://tools/solo_probe.tscn -- --bots 8 --seconds 10
## [/codeblock]

var _bots := 8
var _seconds := 10.0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--bots": _bots = int(args[i + 1])
			"--seconds": _seconds = float(args[i + 1])
	DotLog.set_level(DotLog.Level.ERROR)
	var _scratch := ArenaPresentation.use_scratch_settings("solo_probe")
	_run.call_deferred()


func _run() -> void:
	var client: Node = (load("res://game/arena.tscn") as PackedScene).instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	add_child(client)
	var spin := 0.0
	while spin < 40.0:
		await get_tree().create_timer(0.25).timeout
		spin += 0.25
		var g = client.get("game")
		var p = client.get("player")
		if g != null and p != null and p.is_alive() and g.match_node != null and g.match_node.state == DotMatch.State.LIVE:
			break
	var g = client.get("game")
	print("live after %.1fs with %d players" % [spin, g.players().size() if g != null else -1])
	Engine.max_fps = 0
	# --off a,b: stop _process/_physics_process on nodes whose script path contains a name,
	# to read each one's cost as the drop in the averages below.
	for i in range(OS.get_cmdline_user_args().size() - 1):
		if OS.get_cmdline_user_args()[i] == "--off":
			var names := OS.get_cmdline_user_args()[i + 1].split(",")
			var st := [get_tree().root]
			while not st.is_empty():
				var nd: Node = st.pop_back()
				st.append_array(nd.get_children())
				var sp := str(nd.get_script().resource_path) if nd.get_script() != null else ""
				for nm in names:
					if sp.contains(nm):
						nd.set_process(false)
						nd.set_physics_process(false)
	var n := 0
	var proc := 0.0
	var phys := 0.0
	var proc_max := 0.0
	var phys_max := 0.0
	var calls := 0.0
	var prims := 0.0
	var objs := 0.0
	var t := 0.0
	var worst := 0.0
	while t < _seconds:
		await get_tree().process_frame
		var dt := get_process_delta_time()
		t += dt
		worst = maxf(worst, dt * 1000.0)
		n += 1
		var pr := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		var ph := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		proc += pr
		phys += ph
		proc_max = maxf(proc_max, pr)
		phys_max = maxf(phys_max, ph)
		calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		prims += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		objs += Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	print("frames=%d fps=%.0f worst_frame=%.1f ms" % [n, n / t, worst])
	print("process avg=%.2f max=%.2f ms | physics avg=%.2f max=%.2f ms (per physics step)" % [proc / n, proc_max, phys / n, phys_max])
	print("draw calls=%.0f primitives=%.0f objects=%.0f | nodes=%d" % [calls / n, prims / n, objs / n, int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))])
	var by := {}
	var stack := [get_tree().root]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		stack.append_array(nd.get_children())
		var key := str(nd.get_script().resource_path) if nd.get_script() != null else nd.get_class()
		if nd.is_physics_processing() or nd.is_processing():
			var e: Array = by.get(key, [0, 0, 0])
			e[0] += 1
			e[1] += int(nd.is_physics_processing())
			e[2] += int(nd.is_processing())
			by[key] = e
	for k in by:
		print("  node-type %-60s n=%d phys=%d proc=%d" % [k, by[k][0], by[k][1], by[k][2]])
	print("  physics3d active=%d pairs=%d islands=%d" % [int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)), int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)), int(Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT))])
	get_tree().quit()
