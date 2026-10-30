extends DotGameCheckSuite

const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaPlayerTunables := preload("../game/arena_player_tunables.gd")
const ArenaModule := preload("../game/arena_module.gd")

const EXPECTED_CHECKS := 11
const STEP := 1.0 / 60.0

## A server cvar for the wall-run size rules changes whether a run starts beside a 1 m crate:
## the arena's own tunables, the same `_set_rule` path RULES takes, and a class attribute.


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


## Runs an airborne player down a face of height [param top]; true when a wall run started.
func _runs_beside(t: DotFpsTunables, top: float) -> bool:
	var world := DotFpsFlatBody.with_floor(0.0)
	world.add_box(AABB(Vector3(1.0, 0.0, -200.0), Vector3(0.5, top, 200.0)))
	var motor := DotFpsMotor.new(t, world)
	var s := DotFpsState.new()
	s.mode = DotFpsState.Mode.AIR
	s.position = Vector3(1.0 - 0.35 - 0.05, maxf(top - 0.2, 0.3), -2.0)
	s.velocity = Vector3(0.0, 0.0, -12.0)
	s.time_since_grounded = 1.0
	for _i in range(30):
		var c := DotFpsCommand.new()
		c.move = Vector2(0.0, 1.0)
		motor.simulate(s, c, STEP)
	return motor.wall_runs > 0


func _run() -> void:
	var t := ArenaPlayer.arena_tunables()
	_check(t.wall_run_min_height > 0.0 and t.wall_run_min_length > 0.0, "the arena inherits the size rules on")
	_check(_runs_beside(t, 4.0), "a 4 m wall starts a run")
	_check(not _runs_beside(t, 1.0), "a 1 m crate starts none by default")

	for key in ["wall_run_min_height", "wall_run_min_length"]:
		_check(ArenaPlayer.MOVEMENT_RULES.has(key), "%s is a RULES key a client predicts with" % key)
	var cvars := {}
	for cvar: String in ArenaModule.MOVEMENT_CVARS:
		cvars[ArenaModule.MOVEMENT_CVARS[cvar][0]] = cvar
	_check(cvars.get("wall_run_min_height") == "arena_wall_run_min_height"
		and cvars.get("wall_run_min_length") == "arena_wall_run_min_length", "each has its arena_wall_run_* cvar")

	var served := ArenaPlayer.arena_tunables()
	ArenaPlayer._set_rule(served, "wall_run_min_height", 0.0)
	_check(_runs_beside(served, 1.0), "a server cvar of 0 lets the same 1 m crate start a run")
	var tall := ArenaPlayer.arena_tunables()
	ArenaPlayer._set_rule(tall, "wall_run_min_height", 6.0)
	_check(not _runs_beside(tall, 4.0), "a cvar of 6 refuses the 4 m wall that ran by default")
	var short := ArenaPlayer.arena_tunables()
	ArenaPlayer._set_rule(short, "wall_run_min_length", 500.0)
	_check(not _runs_beside(short, 4.0), "a minimum length longer than the wall refuses the run")

	var def := DotPlayerClassDef.new()
	def.attributes = {"wall_run_min_height": 0.0}
	var classed := ArenaPlayer.arena_tunables()
	_check(ArenaPlayerTunables.apply_class_attributes(def, classed) == 1 and _runs_beside(classed, 1.0),
		"a class attribute overrides the height for its players")
	var plain := ArenaPlayer.arena_tunables()
	ArenaPlayerTunables.apply_class_attributes(DotPlayerClassDef.new(), plain)
	_check(plain.wall_run_min_height == t.wall_run_min_height, "a class that sets none keeps the server's value")

	_report(EXPECTED_CHECKS)
