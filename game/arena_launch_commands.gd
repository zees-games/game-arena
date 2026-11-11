extends Node

## Console lines given at launch: `-- +bot_quota 8 +profiler_overlay 1`. Every `+name value...` among the user arguments is one line for the local console, run once the console knows the name: the only way to set a client console var in a build with no keyboard at hand
## (an exported release started by a script to be profiled). A name given twice runs once, with the last value, so a launcher can put its defaults first and whatever the person typed after.
## The names do not all exist at the same moment (the profiler binds its own a little after the bots), so a line waits for its name and is given up on, loudly, after [constant WAIT_SECONDS].

const CHANNEL := "arena"

## How long a line waits for a name nobody has bound before it is reported and dropped.
const WAIT_SECONDS := 10.0

## The console the lines run on: anything with `claims(name)` and `execute(line)`.
var console: Object

var _pending: Array[String] = []
var _waited: float = 0.0


## The lines in `args`, in the order their names first appear, the last value of each kept. A value runs to the next argument that opens with `+` or `--`;
## `+-5` style negatives are values, since only a letter after the `+` starts a name.
static func parse(args: PackedStringArray) -> Array[String]:
	var order: Array[String] = []
	var lines: Dictionary = {}
	var key := ""
	for arg: String in args:
		if arg.length() > 1 and arg.begins_with("+") and not arg.substr(1, 1).is_valid_float():
			key = arg.substr(1).to_lower()
			if not lines.has(key):
				order.append(key)
			lines[key] = key
		elif arg.begins_with("--"):
			key = ""
		elif not key.is_empty():
			lines[key] = "%s %s" % [lines[key], arg]
	var out: Array[String] = []
	for known: String in order:
		out.append(str(lines[known]))
	return out


## Starts running `lines` on `on`; returns how many are waiting.
func start(on: Object, lines: Array[String]) -> int:
	console = on
	_pending = lines.duplicate()
	_waited = 0.0
	set_process(not _pending.is_empty())
	_run_ready()
	return _pending.size()


func _ready() -> void:
	set_process(not _pending.is_empty())


func _process(delta: float) -> void:
	_waited += delta
	if _any_claimed():
		set_process(false)
		_run_ready.call_deferred()
	elif _waited >= WAIT_SECONDS:
		set_process(false)
		_give_up.call_deferred()


## Whether the console claims any waiting line yet; the frame's whole cost until one does.
func _any_claimed() -> bool:
	if console == null or not is_instance_valid(console):
		return false
	for line: String in _pending:
		if bool(console.call(&"claims", line.get_slice(" ", 0))):
			return true
	return false


func _give_up() -> void:
	for line: String in _pending:
		DotLog.warn(CHANNEL, "launch command '+%s' names nothing the console knows; dropped" % line)
	_pending.clear()


## Lines still waiting for their name.
func pending() -> Array[String]:
	return _pending.duplicate()


func _run_ready() -> void:
	if console == null or not is_instance_valid(console):
		return
	var left: Array[String] = []
	for line: String in _pending:
		var key := line.get_slice(" ", 0)
		if not bool(console.call(&"claims", key)):
			left.append(line)
			continue
		var result: DotResult = console.call(&"execute", line)
		if result != null and result.ok:
			DotLog.info(CHANNEL, "launch command: %s" % line)
		else:
			DotLog.warn(CHANNEL, "launch command '%s' failed: %s" % [line, result.error if result != null else "no result"])
	_pending = left
	set_process(not _pending.is_empty() and _waited < WAIT_SECONDS)
