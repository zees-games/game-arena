extends DotGameCheckSuite

const ArenaTickBudget := preload("../game/arena_tick_budget.gd")
const ArenaAudioManager := preload("../game/arena_audio_manager.gd")

## A solo frame must keep the simulation on wall-clock time. Models the engine's loop (time owed
## accumulates, at most `cap` ticks run) with ArenaTickBudget choosing the cap from the cost of
## a tick, and checks the simulated ticks per wall second at 17 fps with cheap ticks.

const SECTIONS := 5
const CHECKS := 26

var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	print("game-fatal-contact: solo ticks keep wall-clock time")
	await _run()
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


## Ticks per wall second the engine loop would run for frames of [param frame_sec] when one
## tick costs [param tick_cost_sec] and [param budget] picks the cap (null = a fixed 2).
func _scale(frame_sec: float, tick_cost_sec: float, rate: float, budget: ArenaTickBudget) -> float:
	var step := 1.0 / rate
	var owed := 0.0
	var cap := 2
	var ticks := 0
	var wall := 0.0
	for _frame in 600:
		owed += frame_sec
		var run := mini(int(owed / step), cap)
		owed = fposmod(owed, step) if run == int(owed / step) else 0.0
		ticks += run
		wall += frame_sec
		if budget != null and run > 0:
			cap = budget.steps_for(tick_cost_sec)
	return float(ticks) / wall / rate


func _run() -> void:
	_section("the cap follows what a tick costs")
	var b := ArenaTickBudget.new()
	var cheap := 0
	for _i in 30:
		cheap = b.steps_for(0.002)
	_check(cheap == ArenaTickBudget.MAX_STEPS, "a 2 ms tick may catch up the most", "%d" % cheap)
	var dear := 0
	for _i in 60:
		dear = b.steps_for(0.030)
	_check(dear == ArenaTickBudget.MIN_STEPS, "a tick dearer than the budget falls back to the floor", "%d" % dear)
	_check(ArenaTickBudget.new().steps_for(0.0) == ArenaTickBudget.MAX_STEPS, "no measurement yet allows the most")
	var spiky := ArenaTickBudget.new()
	for _i in 30:
		spiky.steps_for(0.0118)
	var before := spiky.steps_for(0.0118)
	var hitched := spiky.steps_for(0.357)
	_check(before >= 3 and hitched >= 3, "one 357 ms hitched tick does not drop the cap to the floor", "%d -> %d" % [before, hitched])
	var kept := 0
	for _i in 4:
		kept = spiky.steps_for(0.0118)
	_check(kept >= 3, "and the cap is back at once after it", "%d" % kept)
	_done()

	_section("17 fps with cheap ticks")
	var fixed := _scale(0.059, 0.003, 66.0, null)
	var follow := _scale(0.059, 0.003, 66.0, ArenaTickBudget.new())
	_check(fixed < 0.6, "the flat cap of 2 ran at about half speed", "%.2f" % fixed)
	_check(follow > 0.97, "the budgeted cap keeps real time", "%.2f" % follow)
	_check(_scale(0.030, 0.003, 66.0, ArenaTickBudget.new()) > 0.97, "30 fps keeps real time", "")
	_done()

	_section("when a tick is dearer than the tick")
	# 20 ms of work for a 15 ms tick: nothing keeps real time, but it must not collapse.
	var slow := _scale(0.060, 0.020, 66.0, ArenaTickBudget.new())
	_check(slow > 0.3 and slow < 1.0, "the simulation slows by the shortfall, no further", "%.2f" % slow)
	_check(slow >= _scale(0.060, 0.020, 66.0, null) - 0.001, "and never worse than the flat cap", "")
	_check(ArenaTickBudget.MAX_STEPS * ArenaTickBudget.PHYSICS_BUDGET_SEC > 0.0, "constants are sane")
	var lb := ArenaTickBudget.new()
	lb.steps_for(0.004)
	_check(is_equal_approx(lb.load_scale(1.0 / 66.0), 1.0), "a tick that fits its period leaves the bots' think periods alone")
	var hb := ArenaTickBudget.new()
	hb.steps_for(0.0227)
	_check(hb.load_scale(1.0 / 66.0) > 1.5 and hb.load_scale(1.0 / 66.0) <= ArenaTickBudget.MAX_LOAD_SCALE, "a tick over its period stretches them, capped")
	_done()

	# The loop above is a model; this one is the engine: a frame of 45 ms (22 fps) with a 2 ms
	# tick, once with the flat cap of 2 and once with ArenaTickBudget's cap, counting the
	# physics frames that really ran against wall time.
	_section("the real engine loop at 22 fps")
	var rate := float(Engine.physics_ticks_per_second)
	var flat := await _engine_scale(null, 45.0, 2.0, 3.0)
	var followed := await _engine_scale(ArenaTickBudget.new(), 45.0, 2.0, 3.0)
	_check(flat < 0.75, "a flat cap of 2 drops owed ticks in the real engine", "%.2f of %.0f Hz" % [flat, rate])
	_check(followed > 0.9, "the budgeted cap keeps the real engine on wall-clock time", "%.2f of %.0f Hz" % [followed, rate])
	_check(Engine.max_physics_steps_per_frame >= ArenaTickBudget.MIN_STEPS, "the cap never falls under the floor", "%d" % Engine.max_physics_steps_per_frame)
	_check(followed > flat + 0.2, "and the difference is large", "%.2f vs %.2f" % [followed, flat])
	_done()
	Engine.max_physics_steps_per_frame = 8

	await _run_part2(hitched)


func _run_part2(hitched) -> void:
	# Behind: frames run their whole cap and are still owed ticks (the owner's profile: every frame caught up,
	# 1876 ticks dropped). The budget then asks for cosmetic work to be shed, and gives it back afterwards.
	_section("a game that stays behind sheds cosmetic work")
	var period := 1.0 / 66.0
	var sb := ArenaTickBudget.new()
	for _f in 60:
		for _k in 4:
			sb.note_tick()
		sb.note_frame(0.059, period, 8)
	_check(is_zero_approx(sb.shed()), "frames that ran every owed tick shed nothing", "%.2f" % sb.shed())
	sb.steps_for(0.027)
	var cost_only := sb.load_scale(period)
	for _f in 40:
		for _k in 2:
			sb.note_tick()
		sb.note_frame(0.057, period, 2)
	_check(sb.shed() >= ArenaTickBudget.SHED_ON, "40 frames that each dropped ticks at the cap turn shedding on", "%.2f" % sb.shed())
	_check(sb.load_scale(period) > cost_only and sb.load_scale(period) <= ArenaTickBudget.BEHIND_SCALE, "and stretch the thinning bots' periods past the cost-based cap", "%.2f -> %.2f" % [cost_only, sb.load_scale(period)])
	var one := ArenaTickBudget.new()
	one.note_tick()
	one.note_tick()
	one.note_frame(0.4, period, 2)
	_check(one.shed() < ArenaTickBudget.SHED_ON, "one hitched frame does not", "%.2f" % one.shed())
	for _f in 200:
		sb.note_tick()
		sb.note_frame(0.015, period, 8)
	_check(is_zero_approx(sb.shed()), "shedding ends once frames stop dropping ticks", "%.2f" % sb.shed())

	var audio := ArenaAudioManager.new()
	add_child(audio)
	var refused: Array = []
	audio.played.connect(func(_id: StringName, handle: int, why: StringName) -> void:
		if handle == 0 and why == &"shed":
			refused.append(why))
	audio.listener_position = Vector3.ZERO
	ArenaTickBudget.shed_now = 0.0
	for _n in 6:
		audio.play_at(&"no_such_sound", Vector3(40, 0, 0))
	_check(audio.shed_count == 0, "on time, no sound is shed", "%d" % audio.shed_count)
	ArenaTickBudget.shed_now = 1.0
	for _n in 6:
		audio.play_at(&"no_such_sound", Vector3(40, 0, 0))
	_check(audio.shed_count == 6 - ArenaAudioManager.SHED_FAR_PER_FRAME and refused.size() == audio.shed_count, "behind, distant one-shots past the first two of a frame are refused", "%d" % audio.shed_count)
	var was := audio.shed_count
	for _n in 6:
		audio.play_at(&"no_such_sound", Vector3(3, 0, 0))
		audio.play(&"no_such_sound")
	_check(audio.shed_count == was, "sounds near the listener and sounds without a position always play")
	await get_tree().process_frame
	audio.play_at(&"no_such_sound", Vector3(40, 0, 0))
	_check(audio.shed_count == was, "and the next frame has its own allowance")
	ArenaTickBudget.shed_now = 0.0
	audio.queue_free()
	_done()


## Real ticks per wall second over [param seconds] (as a share of the tick rate) with frames
## [param frame_ms] long and ticks [param tick_ms] dear; [param budget] null keeps a flat 2.
func _engine_scale(budget: ArenaTickBudget, frame_ms: float, tick_ms: float, seconds: float) -> float:
	var worker := _Burner.new()
	worker.frame_ms = frame_ms
	worker.tick_ms = tick_ms
	worker.budget = budget
	Engine.max_physics_steps_per_frame = 2
	add_child(worker)
	var t0 := Time.get_ticks_usec()
	while float(Time.get_ticks_usec() - t0) < seconds * 1000000.0:
		await get_tree().process_frame
	var wall := float(Time.get_ticks_usec() - t0) / 1000000.0
	var ticks := worker.ticks
	worker.queue_free()
	await get_tree().process_frame
	return float(ticks) / wall / float(Engine.physics_ticks_per_second)


class _Burner extends Node:
	var frame_ms := 0.0
	var tick_ms := 0.0
	var budget: ArenaTickBudget = null
	var ticks := 0

	func _burn(ms: float) -> void:
		var until := Time.get_ticks_usec() + int(ms * 1000.0)
		while Time.get_ticks_usec() < until:
			pass

	func _process(_delta: float) -> void:
		_burn(frame_ms)

	func _physics_process(_delta: float) -> void:
		var t := Time.get_ticks_usec()
		_burn(tick_ms)
		ticks += 1
		if budget != null:
			Engine.max_physics_steps_per_frame = budget.steps_for(float(Time.get_ticks_usec() - t) / 1000000.0)
