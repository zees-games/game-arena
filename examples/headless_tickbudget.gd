extends DotGameCheckSuite

const ArenaTickBudget := preload("../game/arena_tick_budget.gd")

## A solo frame must keep the simulation on wall-clock time. Models the engine's loop
## (time owed accumulates, at most `cap` ticks run, the rest is dropped) with
## ArenaTickBudget choosing the cap from the cost of a tick, and checks the simulated
## ticks per wall second: at 17 fps with cheap ticks the old flat cap of 2 gave about half
## speed (the owner's 16v16 footage: "time feels slowed down").
## Run: [code]godot --headless --path . res://examples/headless_tickbudget.tscn[/code]

const SECTIONS := 3
const CHECKS := 9

var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	print("game-arena: solo ticks keep wall-clock time")
	_run()
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
	_done()
