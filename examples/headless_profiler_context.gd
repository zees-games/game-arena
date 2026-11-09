extends DotGameCheckSuite

const ArenaProfilerContext := preload("../game/arena_profiler_context.gd")

## The profiler reports what perf work needs: the game and the dot-sim natives in every report's context, dot-sim's
## native timers in extras, and none of it failing where the library is missing.
## Run: [code]./game.sh test headless_profiler_context[/code]

const SECTIONS := 3
const CHECKS := 19

var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena: the profiler's context")
	_test_natives()
	await _test_report()
	_test_degrades()
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _test_natives() -> void:
	_section("the natives line says what runs")
	var n := ArenaProfilerContext.natives()
	for key: String in ["loaded", "stamp", "status", "hull_native", "arena_hull_native"]:
		_check(n.has(key), "natives has %s" % key)
	_check(str(n.status).begins_with("dot-sim:"), "the status is dot_sim_status()", str(n.status))
	_check(n.arena_hull_native == ("1" if n.hull_native else "0"), "the hull cvar matches the flag")
	_check(n.loaded == ClassDB.class_exists(&"DotSimFpsBody"), "loaded follows the class")
	_done()


func _test_report() -> void:
	_section("a recording's report carries the game and the natives")
	var prof := DotProfiler.new()
	prof.config = DotProfilerConfig.new()
	prof.config.record_dir = "user://profiles_ctx_test"
	add_child(prof)
	ArenaProfilerContext.install(prof, null, null)
	_check(prof.start_recording(0.2).ok, "a recording starts")
	for i in 6:
		await get_tree().process_frame
	var report := prof.build_report()
	_check(report.get("context", {}).has("game") and report.context.game.get("game") == "arena", "context.game names the game", str(report.get("context", {}).keys()))
	_check(report.context.has("natives") and report.context.natives.has("status"), "context.natives has the status")
	_check(report.context.get("machine", {}).has("os") and report.context.machine.has("cpu"), "context.machine has os and cpu")
	var native: Variant = report.get("extras", {}).get("native", {})
	if ClassDB.class_exists(&"DotSimFpsBody"):
		_check(native is Dictionary and native.has("tick") and native.tick.has("us_each"), "extras.native has the tick timer")
	else:
		_check(native is Dictionary and (native as Dictionary).is_empty(), "no library: extras.native is empty")
	var res := prof.stop_recording()
	_check(res.ok, "the recording writes")
	_check(FileAccess.file_exists(String(res.value).get_basename() + ".txt"), "a text report is beside the JSON")
	var text := FileAccess.get_file_as_string(String(res.value).get_basename() + ".txt")
	_check(text.contains("dot-sim:"), "the text report shows the natives line")
	prof.queue_free()
	_done()


func _test_degrades() -> void:
	_section("no profiler, no library: no errors")
	ArenaProfilerContext.install(null, null, null)
	var plain := Node.new()
	ArenaProfilerContext.install(plain, null, null)
	plain.free()
	_check(true, "install on nothing returns")
	_check(ArenaProfilerContext.game_context(null).get("game") == "arena", "no game still names the game")
	if not ClassDB.class_exists(&"DotSimFpsBody"):
		ArenaProfilerContext.begin_native()
		_check(ArenaProfilerContext.end_native(null).is_empty(), "the timer hook reports nothing without the library")
	else:
		_check(true, "library present: the timers are covered above")
	_done()
