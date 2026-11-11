extends DotGameCheckSuite

const ArenaLaunchCommands := preload("../game/arena_launch_commands.gd")

## `-- +bot_quota 8 +profiler_overlay 1` at launch becomes console lines, each run when its
## name exists. Run `headless_launch_commands`.

const CHECKS := 11


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena: +name value launch commands")
	var none := ArenaLaunchCommands.parse(PackedStringArray(["--offline", "--bots", "4", "--map", "dm_atrium"]))
	_check(none.is_empty(), "plain -- options are not commands (%s)" % [none])

	var lines := ArenaLaunchCommands.parse(PackedStringArray([
		"--offline", "+bot_quota", "8", "+profiler_overlay", "1", "--map", "dm_atrium",
		"+profiler_record_seconds", "60", "+bot_quota", "12", "+say", "hello", "there", "+sens", "-5"]))
	_check(lines.size() == 5, "five names, the repeated one once (%s)" % [lines])
	_check(lines.size() == 5 and lines[0] == "bot_quota 12", "the later value of a repeated name wins, in its first place")
	_check(lines.size() == 5 and lines[1] == "profiler_overlay 1", "a value stops at the next -- option")
	_check(lines.size() == 5 and lines[3] == "say hello there", "a line takes every word up to the next + or --")
	var negative := ArenaLaunchCommands.parse(PackedStringArray(["+sens", "-5", "+2"]))
	_check(negative.size() == 1 and negative[0] == "sens -5 +2", "a signed number is a value, not a name (%s)" % [negative])

	var local := DotConsoleLocal.new()
	var quota: Array[int] = [1]
	local.add_var(&"bot_quota", "test", func() -> Variant: return quota[0],
		func(v: Variant) -> Variant:
			quota[0] = str(v).to_int()
			return DotResult.success(quota[0])
	)
	var runner := ArenaLaunchCommands.new()
	add_child(runner)
	var waiting := runner.start(local, ["bot_quota 12", "late_one 3", "never_bound 1"] as Array[String])
	_check(quota[0] == 12, "a known name runs at once (bot_quota %d)" % quota[0])
	_check(waiting == 2, "the names not bound yet wait (%d)" % waiting)

	var late: Array[int] = [0]
	local.add_var(&"late_one", "test", func() -> Variant: return late[0],
		func(v: Variant) -> Variant:
			late[0] = str(v).to_int()
			return DotResult.success(late[0])
	)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(late[0] == 3, "a name bound later runs on a following frame (late_one %d)" % late[0])
	_check(runner.pending().size() == 1, "the unknown name is still waiting (%s)" % [runner.pending()])
	runner._process(ArenaLaunchCommands.WAIT_SECONDS)
	await get_tree().process_frame
	_check(runner.pending().is_empty() and not runner.is_processing(), "and is given up on after the wait")

	_report(CHECKS)
