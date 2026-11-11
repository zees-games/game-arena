extends Node

## Where the time to a playable frame goes, stamped in engine milliseconds (Time.get_ticks_msec) and printed once when the gate opens, as one console line and `window.dotWeb.published.arena_load` (JSON). Always on: about 20 stamps and one line.
## A hold appearing or going, the gate's state and the client's own phases (a `mark`) are stamped with the frame number, so a slow phase shows as a long gap and a frame count:
## long gap in few frames = one big frame, long gap in many = a sliced phase.

const CHANNEL := "arena.load"

static var _marks: Array = []

var gate: DotLoadGate = null
var _holds: Array = []
var _state := -1
var _worst_ms := 0
var _last_ms := 0
var _done := false


const STATE_NAMES: Array[String] = ["closed", "warming", "open"]


## A named moment in the client's own load, e.g. `mark("level_built")`. A frame's own stamps pass [param detail] (a hold, a gap, a state) instead of a built string; [method _report] words them once.
static func mark(label: String, detail: Variant = null) -> void:
	_marks.append([Time.get_ticks_msec(), Engine.get_process_frames(), label, detail])


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
	if gate.is_open():
		_done = true
		set_process(false)
		_report.call_deferred()


func _report() -> void:
	var rows: PackedStringArray = []
	var marks: Array = []
	var prev := int(_marks[0][0]) if not _marks.is_empty() else 0
	for m: Array in _marks:
		var label := String(m[2])
		if label == "gate":
			label += " " + STATE_NAMES[int(m[3])]
		elif label == "slow_frame ms":
			label = "slow_frame %d ms" % int(m[3])
		elif m[3] != null:
			label += " " + String(m[3])
		rows.append("%d(+%d,f%d) %s" % [int(m[0]), int(m[0]) - prev, int(m[1]), label])
		marks.append([m[0], m[1], label])
		prev = int(m[0])
	DotLog.info(CHANNEL, "time to playable, engine ms (+gap, frame): " + "; ".join(rows), {"worst_frame_ms": _worst_ms})
	if DotWeb.available():
		DotWeb.publish("arena_load", JSON.stringify({"marks": marks, "worst_frame_ms": _worst_ms}))
