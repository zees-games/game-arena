extends Node

## Where the time to a playable frame goes, stamped in engine milliseconds (Time.get_ticks_msec) and printed once when the gate opens, as one console line and `window.dotWeb.published.arena_load` (JSON). Always on: about 20 stamps and one line.
## A hold appearing or going, the gate's state and the client's own phases (a `mark`) are stamped with the frame number, so a slow phase shows as a long gap and a frame count:
## long gap in few frames = one big frame, long gap in many = a sliced phase.

const CHANNEL := "arena.load"

static var _marks: Array = []
## True while [method trace_frames] runs: an [ArenaFrameProbe] section of [const SLOW_SECTION_USEC] or more is stamped.
static var tracing := false
const SLOW_SECTION_USEC := 20000

var gate: DotLoadGate = null
var _holds: Array = []
var _state := -1
var _worst_ms := 0
var _last_ms := 0
var _done := false
var _trace_left := 0
var _ticks := 0
var _tick_usec := 0
var _tick_started := 0
var _pass_start: PassStart = null
var _pass_end: PassStart = null


const STATE_NAMES: Array[String] = ["closed", "warming", "open"]
## A frame at least this long is stamped and counted: the startup goal is none over 100 ms.
const SLOW_FRAME_MS := 100
var _slow_frames := 0
var _title := "time to playable"
## The first load starts with the gate closed; a rearmed one waits for it to close.
var _seen_closed := true
## Play watched after the gate opens, and the frame length stamped there: the goal is a smooth 60 fps from the first frame.
const SETTLE_MSEC := 8000
const SETTLE_SLOW_MS := 50
var _settle_until := 0
var _settle_from := 0
var _settle_worst := 0
var _settle_slow := 0
## `?cl_load_trace=1` on the page (`--cl_load_trace 1` on a desktop): every frame under the cover and through the
## settle window traced as by [method trace_frames], so a slow frame splits into its setup step, the nodes' pass and
## the draw. `cl_load_trace=items` also makes every [DotRenderWarmup] draw one item a round (far slower, but each
## slow draw names its one material).
var _trace_load := false
var _trace_items := false
## Under that trace, what each [DotRenderWarmup] round put up, stamped with a slow draw.
var _warm_new: Array[String] = []
var _drawn_usec := 0
const WARM_ITEM_MARK_MS := 100


## A named moment in the client's own load, e.g. `mark("level_built")`. A frame's own stamps pass [param detail] (a hold, a gap, a state) instead of a built string; [method _report] words them once.
static func mark(label: String, detail: Variant = null) -> void:
	_marks.append([Time.get_ticks_msec(), Engine.get_process_frames(), label, detail])


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Last of every node's physics: a traced tick's node time runs from the tree's physics signal to here.
	process_physics_priority = 1 << 30
	set_physics_process(false)
	_last_ms = Time.get_ticks_msec()
	mark("timeline_start")
	# Beside this script, not "res://game/": a pack mounted under res://dot_cloud/<id>/<version>/ has no such path.
	var probe: GDScript = load((get_script() as Script).resource_path.get_base_dir().path_join("arena_frame_probe.gd"))
	var trace := str(probe.call(&"launch_value", "cl_load_trace"))
	_trace_items = trace == "items"
	_trace_load = trace == "1" or _trace_items
	if _trace_load:
		# The sub-spans too (`s_resolve`, `p_hitbox`, ...), so a slow section names its part.
		probe.set(&"fine", true)
		trace_frames.call_deferred(1 << 20)
		get_tree().node_added.connect(_on_node_added)


## Times a later load the same way, e.g. a map change: stamps from now, reported (under [param title]) once the
## gate has closed and opened again. The gate is still open when a change starts, so it must close before it counts.
func rearm(title: String) -> void:
	_marks.clear()
	_settle_until = 0
	_title = title
	_worst_ms = 0
	_slow_frames = 0
	_last_ms = Time.get_ticks_msec()
	_done = false
	_seen_closed = false
	set_process(true)
	mark("timeline_start")


## Traces the next [param frames] frames: at each frame's process signal (after the awaits it resumes) the
## physics ticks run since the last stamp and their node time, and at each draw's end "drawn". Splits a slow
## frame into catch-up ticks, setup continuations and the draw.
func trace_frames(frames: int) -> void:
	_trace_left = maxi(_trace_left, frames)
	tracing = true
	var tree := get_tree()
	if not tree.physics_frame.is_connected(_on_tick):
		tree.physics_frame.connect(_on_tick)
		tree.process_frame.connect(_on_frame)
		RenderingServer.frame_post_draw.connect(_on_drawn)
	set_physics_process(true)
	if _pass_start == null:
		_pass_start = PassStart.new()
		_pass_start.on_process = func() -> void: mark("process pass")
		_pass_start.process_priority = -(1 << 30)
		_pass_start.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(_pass_start)
	_pass_start.set_process(true)
	if _pass_end == null:
		_pass_end = PassStart.new()
		_pass_end.on_process = func() -> void: mark("process end")
		_pass_end.process_priority = 1 << 30
		_pass_end.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(_pass_end)
	_pass_end.set_process(true)


## First of every node's _process while a trace runs: splits the awaits resumed on the tree's process signal
## (a load step) from the nodes' own _process pass.
class PassStart extends Node:
	var on_process: Callable

	func _process(_delta: float) -> void:
		on_process.call()


func _on_tick() -> void:
	_tick_started = Time.get_ticks_usec()


func _physics_process(_delta: float) -> void:
	_ticks += 1
	_tick_usec += Time.get_ticks_usec() - _tick_started


func _on_frame() -> void:
	mark("frame: %d ticks, nodes %d ms" % [_ticks, _tick_usec / 1000])
	_ticks = 0
	_tick_usec = 0
	_trace_left -= 1
	if _trace_left <= 0:
		get_tree().physics_frame.disconnect(_on_tick)
		get_tree().process_frame.disconnect(_on_frame)
		RenderingServer.frame_post_draw.disconnect(_on_drawn)
		set_physics_process(false)
		_pass_start.set_process(false)
		_pass_end.set_process(false)
		tracing = false


func _on_drawn() -> void:
	mark("drawn")
	var now := Time.get_ticks_usec()
	if not _warm_new.is_empty() and (now - _drawn_usec) / 1000 >= WARM_ITEM_MARK_MS:
		mark("warm drew %s: %d ms" % [", ".join(_warm_new), (now - _drawn_usec) / 1000])
	_warm_new.clear()
	_drawn_usec = now


## The load trace's warm-up attribution: every warm-up draws one item a round, each named with its draw.
func _on_node_added(node: Node) -> void:
	if node is DotRenderWarmup:
		if _trace_items:
			(node as DotRenderWarmup).batch_size = 1
	elif node is GeometryInstance3D and node.get_parent() is DotRenderWarmup:
		_warm_new.append(_describe_item(node))


static func _describe_item(node: Node) -> String:
	var mi := node as MeshInstance3D
	if mi != null and mi.material_override != null:
		return _describe_material(mi.material_override)
	if mi != null and mi.mesh != null:
		var parts: Array[String] = []
		for i in mi.mesh.get_surface_count():
			parts.append(_describe_material(mi.mesh.surface_get_material(i)))
		return "mesh %s [%s]" % [mi.mesh.resource_path.get_file(), " ".join(parts)]
	var gp := node as GPUParticles3D
	if gp != null:
		return "particles " + _describe_material(gp.process_material)
	return node.get_class()


static func _describe_material(m: Material) -> String:
	if m == null:
		return "none"
	var named := m.resource_path.get_file() if not m.resource_path.is_empty() else m.resource_name
	var sm := m as ShaderMaterial
	var bm := m as BaseMaterial3D
	if sm != null and sm.shader != null:
		named += " shader " + sm.shader.resource_path.get_file()
	elif bm != null:
		named += " t%d s%d" % [bm.transparency, bm.shading_mode]
	return named if not named.strip_edges().is_empty() else m.get_class()


func _process(_delta: float) -> void:
	if _settle_until > 0:
		_settle()
		return
	if _done or gate == null or not is_instance_valid(gate):
		return
	var now := Time.get_ticks_msec()
	_worst_ms = maxi(_worst_ms, now - _last_ms)
	if now - _last_ms >= SLOW_FRAME_MS:
		_slow_frames += 1
		mark("slow_frame ms", now - _last_ms)
	_last_ms = now
	var reasons := gate.reasons()
	if reasons != _holds:
		for r in reasons:
			if not _holds.has(r):
				mark("hold+", r)
		for r in _holds:
			if not reasons.has(r):
				mark("hold-", r)
		_holds = reasons
	var s := int(gate.state())
	if s != _state:
		_state = s
		mark("gate", s)
	if not gate.is_open():
		_seen_closed = true
	elif _seen_closed:
		_done = true
		if _trace_load and get_tree().node_added.is_connected(_on_node_added):
			get_tree().node_added.disconnect(_on_node_added)
		_report.call_deferred()
		_settle_from = _marks.size()
		_settle_until = now + SETTLE_MSEC
		_settle_worst = 0
		_settle_slow = 0


## The first [const SETTLE_MSEC] of play after the gate opens: each frame of [const SETTLE_SLOW_MS] or more is
## stamped between the client's own marks, so a spike right after the cover names its work. Reported once, as
## `arena.load` "after open" and `window.dotWeb.published.arena_after_open`.
func _settle() -> void:
	var now := Time.get_ticks_msec()
	var ms := now - _last_ms
	_last_ms = now
	_settle_worst = maxi(_settle_worst, ms)
	if ms >= SETTLE_SLOW_MS:
		_settle_slow += 1
		mark("slow_frame ms", ms)
	if now < _settle_until:
		return
	_settle_until = 0
	set_process(false)
	if _trace_load:
		_trace_left = mini(_trace_left, 1)
	var rows := _rows(_marks.slice(_settle_from))
	DotLog.info(CHANNEL, "after open, engine ms (+gap, frame): " + "; ".join(rows[0]), {"worst_frame_ms": _settle_worst, "slow_frames": _settle_slow})
	if DotWeb.available():
		DotWeb.publish("arena_after_open", JSON.stringify({"marks": rows[1], "worst_frame_ms": _settle_worst, "slow_frames": _settle_slow, "now_ms": now}))


func _report() -> void:
	var rows := _rows(_marks)
	DotLog.info(CHANNEL, _title + ", engine ms (+gap, frame): " + "; ".join(rows[0]), {"worst_frame_ms": _worst_ms, "slow_frames": _slow_frames})
	if DotWeb.available():
		DotWeb.publish("arena_load", JSON.stringify({"marks": rows[1], "worst_frame_ms": _worst_ms, "slow_frames": _slow_frames, "now_ms": Time.get_ticks_msec()}))


## [param list]'s stamps worded: the log rows and the published [ms, frame, label] triples.
func _rows(list: Array) -> Array:
	var rows: PackedStringArray = []
	var marks: Array = []
	var prev := int(list[0][0]) if not list.is_empty() else 0
	for m: Array in list:
		var label := String(m[2])
		if label == "gate":
			label += " " + STATE_NAMES[int(m[3])]
		elif label == "slow_frame ms":
			label = "slow_frame %d ms" % int(m[3])
		elif m[3] != null:
			label += " " + str(m[3])
		rows.append("%d(+%d,f%d) %s" % [int(m[0]), int(m[0]) - prev, int(m[1]), label])
		marks.append([m[0], m[1], label])
		prev = int(m[0])
	return [rows, marks]
