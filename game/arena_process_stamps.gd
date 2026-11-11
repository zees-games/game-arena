extends Node

## Brackets every node's `_process` in a frame, so a profile can say where its "process
## scripts (no span)" goes: `arena.pr_nodes` runs from the first node processed to the last
## (the spans inside it are the sections the client times itself; its self time is every
## other node's `_process` and the engine's own per-node processing), and `arena.pr_post`
## from the last node to the frame's draw (deferred calls, tweens, timers, the delete queue).
## What the process row keeps after both is the process_frame handlers before the first node,
## the profiler's own frame among them.
##
## Two nodes at the extreme process priorities. Each frame costs them a clock read and a test
## while nothing is measuring.

const ArenaFrameProbe := preload("arena_frame_probe.gd")
const _SELF := preload("arena_process_stamps.gd")

const FIRST := -1000000000
const LAST := 1000000000

static var _first_usec: int = 0
static var _last_usec: int = 0

var _is_last: bool = false


## Adds the pair under [param parent] (any node: process priority is global).
static func bracket(parent: Node) -> void:
	var first: _SELF = _SELF.new()
	first.name = "ProcessStampFirst"
	first.process_priority = FIRST
	parent.add_child(first)
	var last: _SELF = _SELF.new()
	last.name = "ProcessStampLast"
	last._is_last = true
	last.process_priority = LAST
	parent.add_child(last)
	var _c := RenderingServer.frame_pre_draw.connect(last._on_pre_draw)


static func _measuring() -> bool:
	return DotFrameCost.enabled or ArenaFrameProbe.on()


func _process(_delta: float) -> void:
	if not _measuring():
		_first_usec = 0
		_last_usec = 0
		return
	if not _is_last:
		_first_usec = Time.get_ticks_usec()
		return
	if _first_usec != 0:
		ArenaFrameProbe.add(&"pr_nodes", _first_usec)
	_last_usec = Time.get_ticks_usec()


func _on_pre_draw() -> void:
	if _last_usec != 0 and _measuring():
		ArenaFrameProbe.add(&"pr_post", _last_usec)
	_last_usec = 0


func _exit_tree() -> void:
	if _is_last and RenderingServer.frame_pre_draw.is_connected(_on_pre_draw):
		RenderingServer.frame_pre_draw.disconnect(_on_pre_draw)
