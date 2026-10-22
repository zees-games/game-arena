extends RefCounted

## Wall-clock frames from [method start] on, split where the load gate opens, so a stall after
## the cover drops shows as a long frame in the first second of play. Shared by `load_stall`
## (offline) and `client_bench --stall` (connected).
##
## Software GL makes every frame slow: judge the ratio of the worst frame to the median.

var frames: Array = []
var script_ms: Array = []
var calls: Array = []
var open_at := -1
var _last := 0
var _tree: SceneTree = null
## Things that entered the tree after the open, with a mesh or material the cover's warm-up
## had not drawn: "frame +N name (what)". These are the first draws a player sees.
var late: Array = []
var _warm := {}


func start(tree: SceneTree) -> void:
	_tree = tree
	_last = Time.get_ticks_usec()
	var _c := tree.process_frame.connect(_on_frame)


## The gate exists only once the client is in the tree, so it is handed over afterwards.
func watch(gate: Object) -> void:
	if gate != null:
		var _o := gate.connect(&"opened", func() -> void:
			if open_at < 0:
				open_at = frames.size()
				if OS.is_stdout_verbose():
					print("STALL-MARK gate opened")
				for item: Variant in gate.call(&"collect_warm_items"):
					_warm[item] = true
				var _n := _tree.node_added.connect(_on_node))


func _on_node(node: Node) -> void:
	var found: Array = []
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			found.append(mi.mesh)
			for i in mi.mesh.get_surface_count():
				found.append(mi.get_active_material(i))
		found.append(mi.material_override)
	elif node is GPUParticles3D:
		found.append((node as GPUParticles3D).process_material)
	elif node is CPUParticles3D:
		found.append((node as CPUParticles3D).mesh)
	for item: Variant in found:
		if item != null and not _warm.has(item):
			late.append("frame +%d %s (%s)" % [frames.size() - open_at, node.get_path(), (item as Resource).resource_path.get_file() if (item as Resource).resource_path != "" else (item as Resource).get_class()])
			return


func stop() -> void:
	if _tree != null and _tree.process_frame.is_connected(_on_frame):
		_tree.process_frame.disconnect(_on_frame)


func _on_frame() -> void:
	var now := Time.get_ticks_usec()
	frames.append((now - _last) / 1000.0)
	_last = now
	script_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	calls.append(int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))


## Seconds of play since the gate opened; 0 while it is closed.
func open_seconds() -> float:
	if open_at < 0:
		return 0.0
	var sum := 0.0
	for i in range(open_at, frames.size()):
		sum += frames[i] / 1000.0
	return sum


## Summary numbers, or an empty dictionary if the gate never opened. `ratio` is the worst
## frame after the open, in the first `window_sec`, over the median of all frames after it.
func summary(window_sec: float = 2.0) -> Dictionary:
	if open_at < 0 or open_at >= frames.size():
		return {}
	var after: Array = frames.slice(open_at)
	var sorted: Array = after.duplicate()
	sorted.sort()
	var median: float = sorted[sorted.size() / 2]
	var first := 0.0
	var n := 0
	var worst := 0.0
	for f in after:
		if first >= window_sec * 1000.0:
			break
		first += f
		n += 1
		worst = maxf(worst, f)
	var before_max := 0.0
	var before_sum := 0.0
	for f in frames.slice(0, open_at):
		before_max = maxf(before_max, f)
		before_sum += f
	return {"cover_frames": open_at, "cover_ms": before_sum, "cover_worst_ms": before_max,
		"median_ms": median, "window_fps": n * 1000.0 / maxf(first, 1.0), "window_worst_ms": worst,
		"ratio": worst / maxf(median, 0.001)}


func lines(window_sec: float = 2.0) -> PackedStringArray:
	var s := summary(window_sec)
	if s.is_empty():
		return PackedStringArray(["stall: the gate never opened (%d frames)" % frames.size()])
	var out := PackedStringArray()
	out.append("stall: cover up %d frames (%.0f ms, worst %.0f) | after open, first %.0f s: %.1f fps, worst %.0f ms = x%.1f the %.1f ms median" % [
		s["cover_frames"], s["cover_ms"], s["cover_worst_ms"], window_sec, s["window_fps"], s["window_worst_ms"], s["ratio"], s["median_ms"]])
	for i in range(maxi(0, open_at - 3), mini(frames.size(), open_at + 15)):
		out.append("  frame %+d: %.0f ms (%d draw calls)" % [i - open_at, frames[i], calls[i]])
	for entry in late.slice(0, 25):
		out.append("  late: " + entry)
	out.append("  late total: %d" % late.size())
	return out
