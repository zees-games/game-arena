extends RefCounted

## How many physics ticks a solo frame may run to keep the game on wall-clock time.
##
## [b]Why it exists.[/b] Solo used to cap `Engine.max_physics_steps_per_frame` at 2 "so a
## slow frame does not owe more", and the engine drops whatever the cap leaves. At 66 Hz a
## 59 ms frame is owed 4 ticks, got 2, and the owner's footage (16v16 bots, 17 fps) showed
## gravity and walking at half speed: the simulation ran at about 34 ticks a wall second.
## The engine's own default (8) catches up, but a catch-up that costs more than the frame
## has makes the next frame slower still, which the cap was guarding against.
##
## So the cap follows the measured cost of a tick: as many steps as fit in
## [constant PHYSICS_BUDGET_SEC] of wall time, never under [constant MIN_STEPS] (the old
## behaviour, when ticks are too dear to catch up) and never over [constant MAX_STEPS].
## When a tick costs more than the tick is long, nothing can keep real time and the
## simulation slows by exactly the shortfall; only a cheaper tick fixes that.

const MIN_STEPS := 2
const MAX_STEPS := 8
## Cvar `arena_tick_floor`: 1 lets a dear tick run once a frame, a higher frame rate for a slower simulation.
static var floor_steps := MIN_STEPS
## Wall time a frame may spend ticking while it catches up.
const PHYSICS_BUDGET_SEC := 0.045
## Weight of the newest tick in the cost average.
const SMOOTHING := 0.1
## Share of a tick's length its cost may take before the bots think less often.
const LOAD_HEADROOM := 0.8
const MAX_LOAD_SCALE := 2.0

var _cost_sec := 0.0


## The cap for the next frame given what a tick just cost; [param tick_cost_sec] is one
## tick's wall time.
func steps_for(tick_cost_sec: float) -> int:
	_cost_sec = tick_cost_sec if _cost_sec <= 0.0 else lerpf(_cost_sec, tick_cost_sec, SMOOTHING)
	if _cost_sec <= 0.0:
		return MAX_STEPS
	return clampi(int(floorf(PHYSICS_BUDGET_SEC / _cost_sec)), floor_steps, MAX_STEPS)


func cost() -> float:
	return _cost_sec


## How much to stretch the bots' think periods (DotBotThinkTier.load_scale) for the cost measured so far:
## 1 while a tick fits in [constant LOAD_HEADROOM] of its [param period_sec], else the overshoot, so a tick that
## costs 1.5 periods asks the thinning bots for 1.5 times the periods. Capped at [constant MAX_LOAD_SCALE].
func load_scale(period_sec: float) -> float:
	if _cost_sec <= 0.0 or period_sec <= 0.0:
		return 1.0
	return clampf(_cost_sec / (period_sec * LOAD_HEADROOM), 1.0, MAX_LOAD_SCALE)
