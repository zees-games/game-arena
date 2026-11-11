extends DotGameCheckSuite
## Shared state, the harness and the boot of headless_lossy, split out for the file size gate.

const ArenaGame := preload("../game/arena_game.gd")
## `-- --tick-rate=30` (or ARENA_TICK_RATE) runs the same suite at another rate; tick-count thresholds scale with it.
@export var tick_rate_override := 0
var TICK_RATE: int:
	get: return clampi(tick_rate_override, 15, 128) if tick_rate_override > 0 else _tick_rate_arg()
## Checks per window, and outside them.
const MEASURE_ATTEMPTS := 6
var _entered := 0
var _completed := 0
var _game: ArenaGame = null
static func _tick_rate_arg() -> int:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tick-rate="):
			return clampi(int(arg.trim_prefix("--tick-rate=")), 10, 240)
	return clampi(int(OS.get_environment("ARENA_TICK_RATE")), 10, 240) if OS.has_environment("ARENA_TICK_RATE") else 64


## Runs one measured section, and runs it again (five times at most) when it failed AND this process
## was stalled for longer than the clock's own tolerance during it. A runner descheduled for
## 3 ticks makes a +-4 tick clock error by itself, which says nothing about the code. No limit
## moves: the rerun is judged by the same checks, and a failure with no stall is final.
func _measured(section: Callable) -> void:
	for attempt in range(MEASURE_ATTEMPTS):
		var passed := _passed
		var failed := _failed
		var failures := _failures.size()
		var entered := _entered
		var completed := _completed
		_stall_ms = 0
		_last_physics_usec = 0
		_gaps.clear()
		_start_watchdog()
		var began_usec := Time.get_ticks_usec()
		var began_frame := Engine.get_physics_frames()
		await section.call()
		# Wall time the ticks did not keep up with: a box that runs every tick a little late never shows one
		# long gap, yet ends the section as far behind the network as a single stall of that length.
		var behind := (Time.get_ticks_usec() - began_usec) / 1000 \
			- (Engine.get_physics_frames() - began_frame) * 1000 / Engine.physics_ticks_per_second
		var stalled := maxi(maxi(_stall_ms, _watchdog_stall_ms()), behind)
		if _failed == failed or stalled < _stall_limit_ms() or attempt == MEASURE_ATTEMPTS - 1:
			if stalled >= _stall_limit_ms():
				print("    (the runner stalled this process for up to %d ms during it)" % stalled)
			elif _failed != failed:
				# A failure the box did not cause, said in so many words: it is the netcode's to explain.
				print("    (failed with no stall over the limit: longest physics gap %d ms, sleeper %d ms, %d ms behind; limit %d; gaps as (tick, ms) %s)" % [
					_stall_ms, _watchdog_stall_ms(), behind, _stall_limit_ms(), _gaps])
			return
		print("    NOT A MEASUREMENT: the runner stalled this process for %d ms (limit %d) and %d checks failed; again" % [
			stalled, _stall_limit_ms(), _failed - failed])
		_passed = passed
		_failed = failed
		_failures.resize(failures)
		_entered = entered
		_completed = completed
		# A burst of load rarely lasts one section; waiting lets it pass.
		await get_tree().create_timer(2.0).timeout


## Three ticks of wall time: the clock check's own tolerance.
func _stall_limit_ms() -> int:
	return 3000 / TICK_RATE


## The longest gap between two physics callbacks since [method _measured] began, and the last one.
var _stall_ms := 0
var _last_physics_usec := 0

## Every physics gap over a tick and a half since it was last cleared, as `(server tick, ms)`: where a
## stall fell, for the line that says a failure had one or had none.
var _gaps: Array[Vector2i] = []


## A thread that only sleeps 1 ms and records how late it wakes. The physics gap cannot see a runner
## that starves the relay or ENet threads while the main thread still gets its callbacks on time.
var _watch_thread: Thread = null
var _watch_stop := false
var _watch_max_usec := 0
var _watch_mutex := Mutex.new()


func _start_watchdog() -> void:
	_watch_mutex.lock()
	_watch_max_usec = 0
	_watch_mutex.unlock()
	if _watch_thread != null:
		return
	_watch_stop = false
	_watch_thread = Thread.new()
	_watch_thread.start(_watch_loop)


func _watch_loop() -> void:
	var last := Time.get_ticks_usec()
	while true:
		OS.delay_usec(1000)
		var now := Time.get_ticks_usec()
		_watch_mutex.lock()
		_watch_max_usec = maxi(_watch_max_usec, now - last - 1000)
		var stop := _watch_stop
		_watch_mutex.unlock()
		last = now
		if stop:
			return


func _watchdog_stall_ms() -> int:
	_watch_mutex.lock()
	var usec := _watch_max_usec
	_watch_mutex.unlock()
	return usec / 1000


func _stop_watchdog() -> void:
	if _watch_thread == null:
		return
	_watch_mutex.lock()
	_watch_stop = true
	_watch_mutex.unlock()
	_watch_thread.wait_to_finish()
	_watch_thread = null


func _track_stall() -> void:
	var now := Time.get_ticks_usec()
	if _last_physics_usec != 0:
		_stall_ms = maxi(_stall_ms, (now - _last_physics_usec) / 1000)
		if (now - _last_physics_usec) * TICK_RATE > 1500000:
			_gaps.append(Vector2i(_game.current_tick(), (now - _last_physics_usec) / 1000))
	_last_physics_usec = now


## The share of real time [param ticks] server ticks since [param from_usec] are.
func _pace(ticks: int, from_usec: int) -> float:
	return float(ticks) * 1000000.0 / (float(TICK_RATE) * float(maxi(1, Time.get_ticks_usec() - from_usec)))


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().physics_frame
	return bool(condition.call())


## Waits [param seconds] of GAME time: physics frames, not the wall clock. A starved runner (CI has two
## cores) runs fewer ticks a second, and a window counted in wall seconds then holds too few ticks to check.
## The wall cap keeps a hung scene from waiting for ever.
func _wait_game(seconds: float) -> void:
	var frames_to := Engine.get_physics_frames() + int(seconds * Engine.physics_ticks_per_second)
	var deadline := Time.get_ticks_msec() + int(seconds * 8000.0)
	while Engine.get_physics_frames() < frames_to and Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
