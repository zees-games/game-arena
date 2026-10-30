extends RefCounted

## `client_bench --profile`: every measured frame split into physics, script, render CPU, GPU and
## wait, with the client's ArenaFrameProbe sections of that same frame, so a slow frame names its
## system. The engine's TIME_PROCESS monitor is a once-a-second figure and cannot do this.

const ArenaFrameProbe := preload("../game/arena_frame_probe.gd")

var rows: Array = []
var _vp := RID()
var _clock: DotMenuFrameClock = null
## Probe nodes between every processing node, priorities renumbered in the engine's own order.
var _marks := PackedInt64Array()
var _owners: Array[String] = []
var _probes: Array[Node] = []
var _signal_at := 0
var _pre_at := 0


## A probe between two processing nodes: stamps when the engine reaches it.
class Probe extends Node:
	var prof: RefCounted
	var index := 0

	func _process(_d: float) -> void:
		prof._marks[index] = Time.get_ticks_usec()


func start(tree: SceneTree, clock: DotMenuFrameClock) -> void:
	_clock = clock
	_vp = tree.root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp, true)
	ArenaFrameProbe._sections.clear()
	clock.on_frame = _on_frame
	_place_probes(tree)
	var _c := tree.process_frame.connect(func() -> void: _signal_at = Time.get_ticks_usec())
	var _d := RenderingServer.frame_pre_draw.connect(func() -> void: _pre_at = Time.get_ticks_usec())


## Gives every processing node a distinct priority in the order it already ran in and puts a
## probe after each, so a frame's script time splits per node. New nodes at priority 0 run first.
func _place_probes(tree: SceneTree) -> void:
	var nodes: Array[Node] = []
	var stack: Array[Node] = [tree.root]
	while not stack.is_empty():
		var nd: Node = stack.pop_front()
		var kids := nd.get_children()
		kids.reverse()
		for k in kids:
			stack.push_front(k)
		if nd.is_processing() and nd.get_script() != null:
			nodes.append(nd)
	var order: Array = range(nodes.size())
	order.sort_custom(func(a: int, b: int) -> bool:
		var pa := nodes[a].process_priority
		var pb := nodes[b].process_priority
		return pa < pb if pa != pb else a < b)
	_marks.resize(order.size() + 1)
	_owners.append("(signals, deferred calls, new nodes)")
	var first := Probe.new()
	first.prof = self
	first.index = 0
	first.process_priority = 99999
	tree.root.add_child(first)
	_probes.append(first)
	for k in order.size():
		var nd: Node = nodes[order[k]]
		nd.process_priority = 100000 + 2 * k
		var pr := Probe.new()
		pr.prof = self
		pr.index = k + 1
		pr.process_priority = 100001 + 2 * k
		tree.root.add_child(pr)
		_probes.append(pr)
		_owners.append("%s %s" % [(nd.get_script() as Script).resource_path.get_file(), nd.name])


func stop() -> void:
	if _clock != null:
		_clock.on_frame = Callable()
	for pr in _probes:
		pr.queue_free()
	RenderingServer.viewport_set_measure_render_time(_vp, false)


func _on_frame(wall_us: int, phys_us: int, script_us: int, render_us: int, steps: int) -> void:
	var sec := {}
	for key: StringName in ArenaFrameProbe._sections:
		var row: PackedInt64Array = ArenaFrameProbe._sections[key]
		sec[key] = row[0]
	ArenaFrameProbe._sections.clear()
	if _marks.size() > 0 and _marks[0] > 0:
		sec[&"<signals+deferred>"] = _marks[0] - _signal_at
		for k in range(1, _marks.size()):
			if _marks[k] > 0 and _marks[k - 1] > 0 and _marks[k] - _marks[k - 1] >= 200:
				sec[StringName(_owners[k])] = _marks[k] - _marks[k - 1]
		sec[&"<after nodes>"] = _pre_at - _marks[_marks.size() - 1]
		_marks.fill(0)
	rows.append([wall_us / 1000.0, phys_us / 1000.0, script_us / 1000.0, render_us / 1000.0,
		RenderingServer.viewport_get_measured_render_time_gpu(_vp), steps,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)), sec])


## The slowest frames with their parts, then the mean parts of frames at or over [param slow_ms]
## against the frames under it: what a slow frame has that a normal one does not.
func lines(worst_n: int = 12, slow_ms: float = 100.0) -> PackedStringArray:
	var out := PackedStringArray()
	var order: Array = range(rows.size())
	order.sort_custom(func(a: int, b: int) -> bool: return rows[a][0] > rows[b][0])
	for i: int in order.slice(0, worst_n):
		out.append("  frame %d: %s" % [i, _fmt(rows[i])])
	for slow in [true, false]:
		var n := 0
		var sum := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
		var sec := {}
		for r: Array in rows:
			if (r[0] >= slow_ms) != slow:
				continue
			n += 1
			for k in 7:
				sum[k] += float(r[k])
			for key: StringName in r[7]:
				sec[key] = sec.get(key, 0) + int(r[7][key])
		if n == 0:
			continue
		var avg: Array = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, {}]
		for k in 7:
			avg[k] = sum[k] / n
		for key: StringName in sec:
			avg[7][key] = int(sec[key] / n)
		out.append("  mean of %d frames %s %.0f ms: %s" % [n, ">=" if slow else "<", slow_ms, _fmt(avg)])
	return out


func _fmt(r: Array) -> String:
	var parts := PackedStringArray()
	var sec: Dictionary = r[7]
	var keys: Array = sec.keys()
	keys.sort_custom(func(a: StringName, b: StringName) -> bool: return int(sec[a]) > int(sec[b]))
	for key: StringName in keys.slice(0, 8):
		if String(key).ends_with("_n"):
			parts.append("%s %d" % [key, sec[key]])
		elif int(sec[key]) >= 200:
			parts.append("%s %.1f" % [key, sec[key] / 1000.0])
	return "%.0f ms = phys %.1f (%.1f steps) script %.1f render %.1f wait %.1f | gpu %.1f | %d draws | %s" % [
		r[0], r[1], r[5], r[2], r[3], r[0] - r[1] - r[2] - r[3], r[4], r[6], ", ".join(parts)]
