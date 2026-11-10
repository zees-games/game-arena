extends RefCounted

## Where a connected client's frame goes, reported every few seconds: frame times, the
## engine's own process and physics times, the client's sections (prediction, snapshots
## and the replays inside them, interpolation, the HUD), and the clock's round trip and
## input lead beside them.
##
## [b]Why it exists.[/b] A browser build has one thread: a frame that stalls also delays
## reading the socket, so a long frame reads as a ping spike, and the ping spike raises
## the input lead, which lengthens every replay. No profiler reaches a release web export,
## and a headless run has neither the browser's speed nor its single thread, so the only
## way to see that loop is to have the client say it. Off unless asked for:
##
## [codeblock]
## embed.html?server=ws://127.0.0.1:6074&cl_perf=5     a browser, every 5 s
## godot --path . -- --cl_perf 5                       a desktop client
## cl_perf 5                                           the console, at any time
## [/codeblock]
##
## Static on purpose: the sections are timed in the client, the bridge and the HUD, and a
## probe that has to be handed to each of them is a probe nobody adds a section to. It is
## per process, which is right for a client and harmless for a suite that never turns it on.

const CHANNEL := "arena.perf"

## Seconds between reports; 0 is off.
static var interval: float = 0.0

static var _sections: Dictionary = {}
static var _frames: PackedFloat32Array = PackedFloat32Array()
static var _process_max: float = 0.0
static var _process_sum: float = 0.0
static var _physics_max: float = 0.0
static var _physics_sum: float = 0.0
static var _steps_max: int = 0
static var _last_physics_frame: int = -1
static var _elapsed: float = 0.0
static var _last_usec: int = 0
## `arena.<section>` per section, built once: a string join and a StringName intern on each of
## the ~600 spans a 31-bot frame records were a measurable part of the profiler's own cost.
static var _profiled_names: Dictionary = {}

## The sub-spans inside a section (`p_pre`, `p_hitbox`, `p_wctx`, `w_props`, `s_resolve`, `br_contacts`, ...): off
## outside a recording, since each costs a clock read; a profiler recording turns them on ([member fine_on_record]).
static var fine: bool = false
## Whether a profiler recording turns [member fine] on for its length (`profiler_fine 0` or the bench's `--fine 0` say no).
static var fine_on_record: bool = true


static func on() -> bool:
	return interval > 0.0


## Starts the probe from `--cl_perf N` or the page's `?cl_perf=N`, if either is given.
static func from_launch() -> void:
	var text := launch_value("cl_perf")
	if text.is_valid_float():
		set_interval(text.to_float())


## A launch option for a measurement, from `--name value` or the page's `?name=value`; ""
## when neither gives it. A browser has no command line, and a measurement has to be
## repeatable from a URL.
static func launch_value(option: String) -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--" + option)
	if index >= 0 and index + 1 < args.size():
		return args[index + 1]
	return DotWeb.query_param(option) if DotWeb.available() else ""


static func set_interval(seconds: float) -> void:
	interval = maxf(0.0, seconds)
	_last_usec = 0
	_reset()


## Adds the time since [param since_usec] to [param section]: `var t := Time.get_ticks_usec()` before the work, `ArenaFrameProbe.add(&"name", t)` after.
## While the dot profiler records ([member DotFrameCost.enabled]) the time is also charged to [DotFrameCost] as `arena.<section>`, so a recorded profile's hitches name the section (`r_held`, `bot_after`, ...) instead of a bare `engine.script`.
static func add(section: StringName, since_usec: int) -> void:
	if interval <= 0.0:
		if DotFrameCost.enabled:
			DotFrameCost.add_usec(_profiled(section), Time.get_ticks_usec() - since_usec)
		return
	var spent := Time.get_ticks_usec() - since_usec
	if DotFrameCost.enabled:
		DotFrameCost.add_usec(_profiled(section), spent)
	var row: PackedInt64Array = _sections.get(section, PackedInt64Array([0, 0, 0]))
	row[0] += spent
	row[1] += 1
	row[2] = maxi(row[2], spent)
	_sections[section] = row


## The clock a run of [method lap]s starts from; 0 while [member fine] is off.
static func lap_start() -> int:
	return Time.get_ticks_usec() if fine else 0


## Charges the time since [param since_usec] to the sub-span [param section] and returns the clock for the next
## lap. Only while [member fine] is on (a recording), so a tick outside one pays a call and a test.
static func lap(section: StringName, since_usec: int) -> int:
	if not fine:
		return 0
	var now := Time.get_ticks_usec()
	if DotFrameCost.enabled:
		DotFrameCost.add_usec(_profiled(section), now - since_usec)
	return now


## The rig's and the arsenal's phase clocks as read at the last [method charge_weapon_phases].
static var _pw_seen := PackedInt64Array()
static var _pa_seen := PackedInt64Array()
static var _pw_names: Array[StringName] = []
static var _pa_names: Array[StringName] = []


## Charges what the weapon rig's and arsenal's phase clocks gained since the last call to `arena.pw_<part>` and
## `arena.pa_<part>`, so a recorded profile splits p_weapons. After each p_weapons, while [member fine] is on.
static func charge_weapon_phases() -> void:
	if not DotFrameCost.enabled:
		return
	var rig := AwWeaponRig.phase_us
	var ars := DotWeaponArsenal.phase_us
	if _pw_names.is_empty():
		for part in AwWeaponRig.PHASES:
			_pw_names.append(StringName("arena.pw_" + part))
		for part in DotWeaponArsenal.PHASES:
			_pa_names.append(StringName("arena.pa_" + part))
	if _pw_seen.size() != rig.size():
		_pw_seen = rig.duplicate()
	if _pa_seen.size() != ars.size():
		_pa_seen = ars.duplicate()
	for i in rig.size():
		if rig[i] != _pw_seen[i]:
			DotFrameCost.add_usec(_pw_names[i], rig[i] - _pw_seen[i])
			_pw_seen[i] = rig[i]
	for i in ars.size():
		if ars[i] != _pa_seen[i]:
			DotFrameCost.add_usec(_pa_names[i], ars[i] - _pa_seen[i])
			_pa_seen[i] = ars[i]


static func _profiled(section: StringName) -> StringName:
	var name: Variant = _profiled_names.get(section)
	if name == null:
		name = StringName("arena." + section)
		_profiled_names[section] = name
	return name


## Counts [param amount] of something that is not a time (replayed ticks, snapshots).
static func count(key: StringName, amount: int = 1) -> void:
	if interval <= 0.0:
		return
	var row: PackedInt64Array = _sections.get(key, PackedInt64Array([0, 0, 0]))
	row[0] += amount
	row[1] += 1
	row[2] = maxi(row[2], amount)
	_sections[key] = row


## Once a frame, from the client's `_process`. Returns the report when one is due, else
## an empty dictionary; [param extra] is merged into it (round trip, lead).
static func frame(delta: float, extra: Callable) -> Dictionary:
	if interval <= 0.0:
		return {}

	# Wall time, not [param delta]: the engine clamps delta (max_physics_steps_per_frame
	# ticks' worth), so a 450 ms browser frame reads as 125 ms, and the stalls this exists
	# to show were the frames it shortened.
	var now := Time.get_ticks_usec()
	var spent := delta if _last_usec == 0 else (now - _last_usec) / 1000000.0
	_last_usec = now
	_frames.append(spent)
	var p := Performance.get_monitor(Performance.TIME_PROCESS)
	var f := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	_process_sum += p
	_process_max = maxf(_process_max, p)
	_physics_sum += f
	_physics_max = maxf(_physics_max, f)
	var physics_frame := Engine.get_physics_frames()
	if _last_physics_frame >= 0:
		_steps_max = maxi(_steps_max, physics_frame - _last_physics_frame)
	_last_physics_frame = physics_frame

	_elapsed += spent
	if _elapsed < interval:
		return {}

	var n := _frames.size()
	var sorted := _frames.duplicate()
	sorted.sort()
	var report := {
		"fps": snappedf(n / _elapsed, 0.1),
		"frame_ms": "p50 %.1f p95 %.1f max %.1f" % [
			sorted[n / 2] * 1000.0, sorted[mini(n - 1, int(n * 0.95))] * 1000.0, sorted[n - 1] * 1000.0],
		"process_ms": "avg %.2f max %.1f" % [_process_sum / n * 1000.0, _process_max * 1000.0],
		"physics_ms": "avg %.2f max %.1f" % [_physics_sum / n * 1000.0, _physics_max * 1000.0],
		"steps_max": _steps_max,
	}
	# Per frame: the average a frame spent in a section, the worst single call, and calls a
	# frame. A count's "ms" is its plain sum per frame instead.
	for key: StringName in _sections:
		var row: PackedInt64Array = _sections[key]
		if String(key).ends_with("_n"):
			report[key] = "%.1f/frame max %d" % [float(row[0]) / n, row[2]]
		else:
			report[key] = "%.2f ms/frame max %.1f x%.1f" % [
				float(row[0]) / n / 1000.0, row[2] / 1000.0, float(row[1]) / n]
	if extra.is_valid():
		report.merge(extra.call(), true)
	DotLog.info(CHANNEL, "frame", report)
	_reset()
	return report


static func _reset() -> void:
	_sections.clear()
	_frames.clear()
	_process_max = 0.0
	_process_sum = 0.0
	_physics_max = 0.0
	_physics_sum = 0.0
	_steps_max = 0
	_elapsed = 0.0
