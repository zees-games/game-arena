class_name ArenaLoadTimeline
extends Node

## Where the time to a playable frame goes, stamped in engine milliseconds (Time.get_ticks_msec, from the
## engine's own start) and printed once when the gate opens, as one console line and
## `window.dotWeb.published.arena_load` (JSON). A hold appearing or going, the gate's state and the
## client's own phases (a `mark`) are stamped with the frame number, so a slow phase shows as a long gap
## and a frame count: long gap in few frames = one big frame, long gap in many = a sliced phase.
## Always on: about 20 stamps and one line.

const CHANNEL := "arena.load"

static var _marks: Array = []

var gate: DotLoadGate = null
var _holds: Array = []
var _state := -1
var _worst_ms := 0
var _last_ms := 0
var _done := false


## A named moment in the client's own load, e.g. `mark("level_built")`.
static func mark(label: String) -> void:
	_marks.append([Time.get_ticks_msec(), Engine.get_process_frames(), label])


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_last_ms = Time.get_ticks_msec()
	mark("timeline_start")


func _process(_delta: float) -> void:
	if _done or gate == null or not is_instance_valid(gate):
		return
	var now := Time.get_ticks_msec()
	_worst_ms = maxi(_worst_ms, now - _last_ms)
	if now - _last_ms >= 250:
		mark("slow_frame %d ms" % (now - _last_ms))
	_last_ms = now
	var reasons := gate.reasons()
	for r in reasons:
		if not _holds.has(r):
			mark("hold+ %s" % String(r))
	for r in _holds:
		if not reasons.has(r):
			mark("hold- %s" % String(r))
	_holds = reasons.duplicate()
	var s := int(gate.state())
	if s != _state:
		_state = s
		mark("gate %s" % ["closed", "warming", "open"][s])
	if gate.is_open():
		_done = true
		_report()


func _report() -> void:
	var rows: PackedStringArray = []
	var prev := int(_marks[0][0]) if not _marks.is_empty() else 0
	for m: Array in _marks:
		rows.append("%d(+%d,f%d) %s" % [int(m[0]), int(m[0]) - prev, int(m[1]), String(m[2])])
		prev = int(m[0])
	DotLog.info(CHANNEL, "time to playable, engine ms (+gap, frame): " + "; ".join(rows), {"worst_frame_ms": _worst_ms})
	if DotWeb.available():
		DotWeb.publish("arena_load", JSON.stringify({"marks": _marks, "worst_frame_ms": _worst_ms}))
