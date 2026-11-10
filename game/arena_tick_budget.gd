extends RefCounted

## How many physics ticks a solo frame may run to keep the game on wall-clock time. [b]Why it exists.[/b] Solo capped `Engine.max_physics_steps_per_frame` at 2 and the engine drops whatever the cap leaves: a 59 ms frame at 66 Hz is owed 4 ticks, got 2, and the simulation ran at half speed (16v16 bots, 17 fps).
## The engine's default (8) catches up, but a catch-up that costs more than the frame makes the next frame slower still. So the cap follows the measured cost of a tick: as many steps as fit in [constant PHYSICS_BUDGET_SEC], never under [constant MIN_STEPS] and never over [constant MAX_STEPS].
## When a tick costs more than the tick is long nothing can keep real time and the simulation slows by exactly the shortfall; only a cheaper tick fixes that.

const MIN_STEPS := 2
const MAX_STEPS := 8
## Cvar `arena_tick_max_steps`: below [constant MIN_STEPS] trades simulation speed for frame rate
## when a tick is too dear to run twice a frame (1 = one tick per frame).
static var max_steps := MAX_STEPS
## Wall time a frame may spend ticking while it catches up.
const PHYSICS_BUDGET_SEC := 0.045
## Weight of the newest tick in the cost average.
const SMOOTHING := 0.1
## A single tick counts for at most this many times the running cost: one hitched tick (a first-use build, a stall of 300 ms) is not a price the next ticks pay, and with the newest-tick weight above it would have held the cap at the floor for twenty frames.
## A real rise in cost still moves the average, doubling in about seven ticks.
const OUTLIER := 2.0
## Share of a tick's length its cost may take before the bots think less often.
const LOAD_HEADROOM := 0.8
const MAX_LOAD_SCALE := 2.0
## While frames keep dropping owed ticks (see [method note_frame]) the thinning bots' periods stretch up to this,
## past [constant MAX_LOAD_SCALE]: the cost-based stretch alone stops at 2 and a 27 ms tick stays behind.
const BEHIND_SCALE := 3.0
## How fast [method shed] rises per frame that dropped ticks and falls per frame that did not. It falls five
## times slower than it rises, so shedding does not flap on and off around the point where ticks just fit.
const SHED_RISE := 0.05
const SHED_FALL := 0.01
## From this [method shed] on, cosmetic per-tick work is dropped (ArenaAudioManager's distant one-shots).
const SHED_ON := 0.5

## [method shed] of the running solo game, 0 anywhere else. Read by cosmetic code only: nothing that decides
## the simulation or what goes on the wire may look at it.
static var shed_now := 0.0

var _cost_sec := 0.0
var _ticks := 0
var _shed := 0.0


## The cap for the next frame given what a tick just cost; [param tick_cost_sec] is one
## tick's wall time.
func steps_for(tick_cost_sec: float) -> int:
	_cost_sec = tick_cost_sec if _cost_sec <= 0.0 else lerpf(_cost_sec, minf(tick_cost_sec, _cost_sec * OUTLIER), SMOOTHING)
	if _cost_sec <= 0.0:
		return max_steps
	return clampi(int(floorf(PHYSICS_BUDGET_SEC / _cost_sec)), mini(MIN_STEPS, max_steps), max_steps)


func cost() -> float:
	return _cost_sec


## How much to stretch the bots' think periods (DotBotThinkTier.load_scale) for the cost measured so far:
## 1 while a tick fits in [constant LOAD_HEADROOM] of its [param period_sec], else the overshoot, so a tick that
## costs 1.5 periods asks the thinning bots for 1.5 times the periods. Capped at [constant MAX_LOAD_SCALE].
func load_scale(period_sec: float) -> float:
	if _cost_sec <= 0.0 or period_sec <= 0.0:
		return 1.0
	return maxf(clampf(_cost_sec / (period_sec * LOAD_HEADROOM), 1.0, MAX_LOAD_SCALE), lerpf(1.0, BEHIND_SCALE, _shed))


## One physics tick ran in the frame being drawn.
func note_tick() -> void:
	_ticks += 1


## One frame of [param frame_sec] wall time was drawn after the ticks counted by [method note_tick], under a cap
## of [param cap] steps. A frame that ran its whole cap and was still owed more dropped ticks: the game is
## behind, and [method shed] rises; it falls again once frames stop dropping. Returns [method shed].
func note_frame(frame_sec: float, period_sec: float, cap: int) -> float:
	var behind := period_sec > 0.0 and _ticks >= cap and frame_sec / period_sec > float(_ticks) + 0.5
	_ticks = 0
	_shed = minf(_shed + SHED_RISE, 1.0) if behind else maxf(_shed - SHED_FALL, 0.0)
	return _shed


## 0 while the game keeps wall-clock time, towards 1 the longer frames have been dropping owed ticks. What may
## be shed with it is only work that changes nothing in the simulation: the thinning bots' think periods (which
## [method load_scale] already stretches with cost) and cosmetic sound.
func shed() -> float:
	return _shed
