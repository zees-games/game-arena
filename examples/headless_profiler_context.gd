extends DotGameCheckSuite

const ArenaProfilerContext := preload("../game/arena_profiler_context.gd")

## The profiler reports what perf work needs: the game and the dot-sim natives in every report's context, dot-sim's
## native timers in extras, and none of it failing where the library is missing.
## Run: [code]./game.sh test headless_profiler_context[/code]

const ArenaAudioManager := preload("../game/arena_audio_manager.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaFrameProbe := preload("../game/arena_frame_probe.gd")

const SECTIONS := 5
const CHECKS := 41

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
	_test_roster()
	await _test_audio()
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
	_check(ArenaFrameProbe.lap(&"x", ArenaFrameProbe.lap_start()) == 0, "outside a recording a sub-span reads no clock")
	_check(prof.start_recording(0.2).ok, "a recording starts")
	_check(ArenaFrameProbe.fine and ArenaFrameProbe.lap(&"x", ArenaFrameProbe.lap_start()) > 0, "a recording turns the sub-spans on")
	_check(prof.config.per_unit == "players" and is_equal_approx(prof.config.unit_target_us, ArenaProfilerContext.PLAYER_TARGET_US), "the report rates cost per player against the target")
	for i in 6:
		await get_tree().process_frame
	var report := prof.build_report()
	_check(report.get("context", {}).has("game") and report.context.game.get("game") == "arena", "context.game names the game", str(report.get("context", {}).keys()))
	_check(report.context.has("natives") and report.context.natives.has("status"), "context.natives has the status")
	_check(report.context.has("audio") and report.context.audio.has("driver") and report.context.audio.has("latency_ms"), "context.audio has the driver and its latency")
	_check(report.context.get("build", {}).has("commit") and report.context.build.get("source") in ["git", "stamp", "unknown"], "context.build has the commit and where it came from", str(report.context.get("build", {})))
	_check(report.context.get("build", {}).get("addons") is Dictionary, "context.build lists the addons' commits")
	_check(report.context.get("launch") is Array, "context.launch has the launch arguments")
	_check(report.context.get("machine", {}).has("os") and report.context.machine.has("cpu"), "context.machine has os and cpu")
	var native: Variant = report.get("extras", {}).get("native", {})
	if ClassDB.class_exists(&"DotSimFpsBody"):
		_check(native is Dictionary and native.has("tick") and native.tick.has("us_each"), "extras.native has the tick timer")
	else:
		_check(native is Dictionary and (native as Dictionary).is_empty(), "no library: extras.native is empty")
	var res := prof.stop_recording()
	_check(res.ok, "the recording writes")
	_check(not ArenaFrameProbe.fine, "the sub-spans are off again after the recording")
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


class _Roster extends RefCounted:
	var ids: Array[int] = []

	func player_ids() -> Array[int]:
		return ids


class _Bridge extends RefCounted:
	var bots: Array[int] = []

	func bot_ids() -> Array[int]:
		return bots


class _Holder extends RefCounted:
	var audio: Node = null


func _test_roster() -> void:
	_section("bots are counted from the roster, hosted here or not")
	var roster := _Roster.new()
	roster.ids = [1, 2, ArenaGame.BOT_SESSION_BASE + 1, ArenaGame.BOT_SESSION_BASE + 2, ArenaGame.BOT_SESSION_BASE + 3]
	var remote := ArenaProfilerContext.game_context(roster, _Bridge.new())
	_check(remote.bots == 3, "a client of a remote server counts the server's bots", str(remote))
	_check(remote.bots_hosted == 0, "and says it hosts none")
	_check(remote.players == 5, "players is the whole roster")
	var bridge := _Bridge.new()
	bridge.bots = [ArenaGame.BOT_SESSION_BASE + 1, ArenaGame.BOT_SESSION_BASE + 2, ArenaGame.BOT_SESSION_BASE + 3]
	var host := ArenaProfilerContext.game_context(roster, bridge)
	_check(host.bots == 3 and host.bots_hosted == 3, "a host counts the same bots once", str(host))
	roster.ids = [7]
	_check(ArenaProfilerContext.game_context(roster, null).bots == 0, "no bots, no bridge: zero")
	_done()


func _test_audio() -> void:
	_section("sound is a span and a line of context")
	var manager := ArenaAudioManager.new()
	manager.catalogue = DotAudioCatalogue.new()
	manager.mixer = DotAudioMixer.new()
	add_child(manager)
	_check(manager.setup().ok, "the arena's manager sets up")
	var holder := _Holder.new()
	holder.audio = manager
	var ctx := ArenaProfilerContext.audio_context(holder)
	for key: String in ["driver", "mix_rate", "latency_ms", "sink", "playing", "capacity"]:
		_check(ctx.has(key), "audio context has %s" % key, str(ctx.keys()))
	_check(ArenaProfilerContext.audio_context(null).has("driver"), "no manager still names the driver")
	# The profiler freed above turns the cost table off as it leaves: let it go first.
	await get_tree().process_frame
	await get_tree().process_frame
	var was := DotFrameCost.enabled
	DotFrameCost.reset()
	DotFrameCost.enabled = true
	var _h := manager.play(&"nothing_by_this_name")
	manager._process(0.0)
	var cost: Dictionary = DotFrameCost.take().get(&"arena.audio", {})
	var seen := int(cost.get("calls", 0)) == 2
	DotFrameCost.enabled = was
	DotFrameCost.reset()
	_check(seen, "a played sound and the reap are charged to arena.audio")
	manager.queue_free()
	_done()
