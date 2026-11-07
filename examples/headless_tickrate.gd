extends DotGameCheckSuite

const ArenaGame := preload("../game/arena_game.gd")
const ArenaEvents := preload("../game/arena_events.gd")

## The tick rate is a setting: what has to hold at 22, 33 and 66 Hz (128 is measured and reported, not asserted).
##
## - the snapshot rate is its own number (`sv_snapshot_rate`, carried in HELLO), a whole-tick divisor of any tick rate;
## - a client that predicts a scripted run (wall run, wall jump, jump, strafe) stays within 2 cm of the server (22 Hz: 10 cm; the wire quantises to a centimetre)
##   when it is rewound to the server's state every 1, 3 or 6 ticks, and ends a wall run on the server's tick;
## - a wall-run time cap that is a whole number of ticks ends on that tick for the server and a rewound client.
##
## The full-stack prediction check (real wire, real bridge, wall routes) is `headless_net` with `-- --tick-rate=N`
## (or ARENA_TICK_RATE=N), the same for `headless_lossy`.
## Run: [code]godot --headless --path . res://examples/headless_tickrate.tscn[/code]

const RATES := [22, 33, 66]
const SECTIONS := 4
const CHECKS := 50

var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena: the tick rate is a setting")
	_test_snapshot_rate()
	_test_prediction()
	_test_wall_cap()
	_test_tick_counts()
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _test_snapshot_rate() -> void:
	_section("the snapshot rate is derived from the target, never above the tick rate")
	var cases := [[66, 32, 33], [64, 32, 32], [60, 32, 30], [128, 32, 32], [33, 32, 33], [22, 32, 22], [66, 22, 22], [66, 16, 11], [66, 0, 33], [22, 128, 22]]
	for c: Array in cases:
		var got := ArenaGame.snapshot_rate_for(int(c[0]), int(c[1]))
		_check(got == int(c[2]), "%d Hz aiming at %d snapshots a second sends %d" % [c[0], c[1], c[2]], str(got))
	for rate: int in [15, 22, 30, 33, 44, 60, 66, 100, 128]:
		for target: int in [8, 16, 20, 32, 64]:
			if rate % ArenaGame.snapshot_rate_for(rate, target) != 0:
				_check(false, "%d Hz aiming at %d sends a divisor of the tick rate" % [rate, target])
	_check(ArenaGame.snapshot_rate_for(66) == 33 and ArenaGame.snapshot_rate_for(22) == 22, "the default target is unchanged")
	for rate: int in [15, 22, 30, 33, 44, 60, 66, 100, 128]:
		_check(ArenaGame.snapshot_rate_for(rate) <= rate and ArenaGame.snapshot_rate_for(rate) >= 1, "%d Hz sends at most one snapshot a tick" % rate)

	var hello := ArenaEvents.read_hello(DotNetReader.new(ArenaEvents.write_hello(22, 1, 2, 3, "dm_box", 25, 600.0, 11)))
	_check(bool(hello["ok"]) and int(hello["tick_rate"]) == 22 and int(hello["snapshot_rate"]) == 11, "HELLO carries the snapshot rate beside the tick rate")
	var plain := ArenaEvents.read_hello(DotNetReader.new(ArenaEvents.write_hello(22, 1, 2, 3, "dm_box", 25, 600.0)))
	_check(bool(plain["ok"]) and int(plain["snapshot_rate"]) == 0, "and 0 means derive it")
	_done()


func _wall_tunables() -> DotFpsTunables:
	var t := DotFpsTunables.with_profile("legacy")
	t.can_noclip = true
	t.wall_run_enabled = true
	t.wall_jump_enabled = true
	t.wall_run_min_speed = 6.0
	t.wall_run_max_time = 1.0
	t.wall_jump_max_per_wall = 1
	t.wall_jump_max_per_air = 3
	return t


func _world() -> DotFpsFlatBody:
	var world := DotFpsFlatBody.with_floor(0.0)
	world.add_box(AABB(Vector3(1.0, 0.0, -400.0), Vector3(0.5, 12.0, 400.0)))
	world.add_box(AABB(Vector3(-3.5, 0.0, -400.0), Vector3(0.5, 12.0, 400.0)))
	return world


func _beside_wall() -> DotFpsState:
	var s := DotFpsState.new()
	s.mode = DotFpsState.Mode.AIR
	s.position = Vector3(1.0 - 0.35 - 0.05, 3.0, -2.0)
	s.velocity = Vector3(0.0, 0.5, -8.0)
	s.time_since_grounded = 1.0
	return s


func _cmd(forward: float, strafe: float, jump: bool) -> DotFpsCommand:
	var c := DotFpsCommand.new()
	c.move = Vector2(strafe, forward)
	c.buttons = DotFpsCommand.BUTTON_JUMP if jump else 0
	return c


## The scripted input at [param second]: forward throughout; a wall jump at 0.6 s, a strafe from 0.7 to 1.2 s,
## a second jump at 1.3 s and a strafe the other way from 1.6 s. Held for a whole tick at any rate.
func _script(second: float, step: float) -> DotFpsCommand:
	var jump := (second >= 0.6 and second < 0.6 + step) or (second >= 1.3 and second < 1.3 + step)
	var strafe := 0.0
	if second >= 0.7 and second < 1.2:
		strafe = 1.0
	elif second >= 1.6:
		strafe = -1.0
	return _cmd(1.0, strafe, jump)


## Server and a predicting client run the same commands; the client is rewound to the server's state every [param every] ticks.
## Returns the worst position gap, the ticks the two disagreed about wall running, and the wall-run ticks.
func _predict(rate: int, every: int) -> Dictionary:
	var step := 1.0 / float(rate)
	var tunables := _wall_tunables()
	var world := _world()
	DotFpsNetSync.set_tick_rate(rate)
	var server := DotFpsMotor.new(tunables, world)
	var client := DotFpsMotor.new(tunables, world)
	var s := _beside_wall()
	var c := _beside_wall()
	var worst := 0.0
	var split := 0
	var running := 0
	for i in range(int(2.5 * float(rate))):
		var second := float(i) * step
		server.simulate(s, _script(second, step), step)
		client.simulate(c, _script(second, step), step)
		worst = maxf(worst, s.position.distance_to(c.position))
		split += 1 if s.is_wall_running() != c.is_wall_running() else 0
		running += 1 if s.is_wall_running() else 0
		if i % every == 0:
			# The wire's precision: a centimetre on the position, a centimetre a second on the velocity.
			c.position = (s.position * 100.0).round() / 100.0
			c.velocity = (s.velocity * 100.0).round() / 100.0
			DotFpsNetSync.unpack_flags(c, DotFpsNetSync.pack_flags(s))
	return {"worst": worst, "split": split, "running": running}


func _test_prediction() -> void:
	_section("a rewound client predicts a wall run, wall jump, jump and strafe within 2 cm of the server (22 Hz: 10 cm; the wire quantises to a centimetre)")
	var was := DotFpsNetSync.timer_scale
	for rate: int in RATES + [128]:
		for every: int in [1, 3, 6]:
			var r := _predict(rate, every)
			print("  measured: %d Hz, rewound every %d: worst gap %.4f m, %d ticks disagreeing, %d wall-run ticks" % [rate, every, r.worst, r.split, r.running])
			if rate in RATES:
				# 22 Hz measured 0.07 m and one disagreeing tick when rewound every tick to a 1 cm-quantised state: at a
				# 45 ms tick a centimetre decides whether the wall is touched. Bounded, reported; 33 Hz and up stay under 1 cm.
				var limit := 0.1 if rate == 22 else 0.02
				_check(r.worst < limit and r.split <= (1 if rate == 22 else 0) and r.running > 0, "%d Hz rewound every %d tick(s): the client stays on the server" % [rate, every], "gap %.4f, split %d, running %d" % [r.worst, r.split, r.running])
	DotFpsNetSync.timer_scale = was
	_done()


## The tick a [param cap]-second wall run ends on the server and on a client rewound every [param every] ticks.
func _cap_ends(rate: int, cap: float, every: int) -> Vector2i:
	var step := 1.0 / float(rate)
	var t := _wall_tunables()
	t.wall_run_auto = true
	t.wall_run_max_time = cap
	DotFpsNetSync.set_tick_rate(rate)
	var world := DotFpsFlatBody.with_floor(0.0)
	world.add_box(AABB(Vector3(1.0, 0.0, -400.0), Vector3(0.5, 12.0, 400.0)))
	var server := DotFpsMotor.new(t, world)
	var client := DotFpsMotor.new(t, world)
	var s := _beside_wall()
	var c := _beside_wall()
	s.velocity = Vector3(0.0, 0.5, -9.0)
	c.velocity = s.velocity
	var ends := Vector2i(-1, -1)
	var started := false
	for i in range(rate * 3):
		server.simulate(s, _cmd(1.0, 0.0, false), step)
		client.simulate(c, _cmd(1.0, 0.0, false), step)
		if i % every == 0:
			DotFpsNetSync.unpack_flags(c, DotFpsNetSync.pack_flags(s))
		started = started or s.is_wall_running()
		if started and ends.x < 0 and not s.is_wall_running():
			ends.x = i
		if started and ends.y < 0 and not c.is_wall_running():
			ends.y = i
	return ends


func _test_wall_cap() -> void:
	_section("a wall-run time cap ends on the same tick for the server and a rewound client")
	var was := DotFpsNetSync.timer_scale
	for rate: int in RATES + [128]:
		for cap: float in [0.5, 1.0, 1.5]:
			for every: int in [1, 3]:
				var e := _cap_ends(rate, cap, every)
				print("  measured: %d Hz cap %.1f s rewind %d: server tick %d, client tick %d (cap tick %d)" % [rate, cap, every, e.x, e.y, roundi(cap * float(rate))])
				if rate in RATES:
					_check(e.x == e.y and absi(e.x - roundi(cap * float(rate))) <= 1, "%d Hz, %.1f s cap, rewound every %d: both end on tick %d" % [rate, cap, every, e.x], "client %d" % e.y)
	DotFpsNetSync.timer_scale = was
	_done()


func _test_tick_counts() -> void:
	_section("tick-count constants, in seconds, at each rate (informational: these are written for 66 Hz)")
	for rate: int in RATES + [128]:
		print("  measured: %d Hz: one tick %.1f ms; thrower grace (8 ticks) %.0f ms; flashlight hold (3) %.0f ms; unlag cap (32) %.2f s" % [rate, 1000.0 / rate, 8000.0 / rate, 3000.0 / rate, 32.0 / rate])
	_check(true, "tick-count constants listed")
	_done()
