extends DotGameCheckSuite

## Arena's slide is unchanged: it never asks for the sprint button (that gate is Zombie Zone's
## opt-in in the shared addon), so crouch at a run slides and a crouch-walk does not.

const ArenaPlayer := preload("../game/arena_player.gd")
const STEP := 1.0 / 30.0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _command(forward: float, buttons: int) -> DotFpsCommand:
	var c := DotFpsCommand.new()
	c.move = Vector2(0.0, forward)
	c.buttons = buttons
	return c


func _run_for(motor: DotFpsMotor, buttons: int, seconds: float) -> DotFpsState:
	var s := DotFpsState.new()
	s.mode = DotFpsState.Mode.GROUND

	for _i in range(int(seconds / STEP)):
		motor.simulate(s, _command(1.0, buttons), STEP)

	return s


func _run() -> void:
	print("arena: slide rules unchanged")
	var t := ArenaPlayer.arena_tunables()
	_check(t.slide_enabled, "sliding is on")
	_check(not t.slide_requires_sprint, "a slide does not need the sprint button")
	_check(is_equal_approx(t.slide_min_speed, 4.1), "the minimum speed is still 4.1 m/s")
	var motor := DotFpsMotor.new(t, DotFpsFlatBody.with_floor(0.0))

	var run := _run_for(motor, DotFpsCommand.BUTTON_SPRINT, 3.0)
	motor.simulate(run, _command(1.0, DotFpsCommand.BUTTON_SPRINT | DotFpsCommand.BUTTON_CROUCH), STEP)
	_check(run.is_sliding(), "crouch at a sprint slides")

	var jog := _run_for(motor, 0, 3.0)
	motor.simulate(jog, _command(1.0, DotFpsCommand.BUTTON_CROUCH), STEP)
	_check(jog.is_sliding(), "crouch at a plain run slides, no sprint button needed")

	var walk := _run_for(motor, DotFpsCommand.BUTTON_WALK, 3.0)
	motor.simulate(walk, _command(1.0, DotFpsCommand.BUTTON_WALK | DotFpsCommand.BUTTON_CROUCH), STEP)
	_check(not walk.is_sliding(), "crouch at a walk does not slide")
	_report()
	get_tree().quit(0 if _failed == 0 else 1)
