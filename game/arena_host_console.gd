extends Node
## The solo client talking to its own server process (ArenaSimHost): console lines out as
## `Ask.HOST`, the answers back ([ArenaSimOwner] on the far end). What solo did in this process
## -- bots, difficulty, cheats, the map and the mode -- is asked for here instead.

const ArenaEvents := preload("arena_events.gd")
const ArenaHostWire := preload("arena_host_wire.gd")
const ArenaLaunchCommands := preload("arena_launch_commands.gd")
const CHANNEL := "arena.host_console"
const ANSWER_SEC := 30.0

signal answered(seq: int, good: bool, text: String)

var bridge: Node = null
var console: DotConsoleController = null
var local: Object = null
## Claims whatever no local command did, so `bot_quota 8` typed solo reaches the server process.
var source := DotConsoleRemote.new("solo server")

var _seq := 0
var _open: Dictionary = {}


func attach(with_bridge: Node, with_console: DotConsoleController, local_console: Object) -> void:
	bridge = with_bridge
	console = with_console
	local = local_console
	bridge.host_replied.connect(_on_replied)
	source.send_fn = func(line: String) -> void:
		var _answer: DotResult = await ask(line, true)
	if console != null:
		console.add_source(source)
	var names: DotResult = await ask("host_names")
	if names.ok:
		source.learn_names(str(names.value).replace("\n", " ").split(" ", false))


## Sends one line and waits for its answer: the text on success, the server's refusal otherwise.
## [param echo] prints each answered line in the console as it comes.
func ask(line: String, echo: bool = false) -> DotResult:
	_seq = (_seq + 1) % (1 << ArenaHostWire.SEQ_BITS)
	var seq := _seq
	# An Array: a packed array read out of a Dictionary is a copy, and the lines would be lost.
	_open[seq] = {"echo": echo, "lines": []}
	bridge.send_request(ArenaEvents.Ask.HOST, ArenaHostWire.write_line(seq, line))
	get_tree().create_timer(ANSWER_SEC).timeout.connect(func() -> void:
		_on_replied(seq, true, false, "The solo server did not answer '%s'." % line))
	while true:
		var got: Array = await answered
		if int(got[0]) == seq:
			return DotResult.success(got[2]) if bool(got[1]) else DotResult.fail(DotError.CODE_STATE, str(got[2]))
	return DotResult.fail(DotError.CODE_STATE, "unreachable")


## True for a name this console or the server process answers: what a `+name value` launch line waits for.
func claims(command: String) -> bool:
	return (local != null and bool(local.call(&"claims", command))) or source.names().has(command.to_lower())


func execute(line: String) -> DotResult:
	if local != null and bool(local.call(&"claims", line.get_slice(" ", 0))):
		return local.call(&"execute", line)
	return source.execute(line)


## The `+name value` lines of a solo launch, each run once somebody knows its name.
func run_launch_commands(args: PackedStringArray) -> void:
	var lines := ArenaLaunchCommands.parse(args)
	if lines.is_empty():
		return
	var runner := ArenaLaunchCommands.new()
	runner.name = "LaunchCommands"
	add_child(runner)
	var _waiting := runner.start(self, lines)


func _on_replied(seq: int, done: bool, good: bool, text: String) -> void:
	if not _open.has(seq):
		return
	var entry: Dictionary = _open[seq]
	if text != "" and bool(entry["echo"]) and console != null:
		console.print_line(text, DotConsoleBuffer.Level.INFO if good else DotConsoleBuffer.Level.ERROR)
	if not done:
		(entry["lines"] as Array).append(text)
		return
	var _gone := _open.erase(seq)
	answered.emit(seq, good, text if text != "" else "\n".join(PackedStringArray(entry["lines"] as Array)))
