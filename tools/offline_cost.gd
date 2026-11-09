extends Node

const ArenaFrameProbe := preload("../game/arena_frame_probe.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ClientBench := preload("client_bench.gd")

## Solo (offline) client with N bots on `--map`, frame and physics cost per frame:
## `godot --path . res://tools/offline_cost.tscn -- --map blackhawkdown --bots 10 --seconds 25`.
## Prints fps, frame p50/p95/max, the engine's physics and process monitors and physics steps per frame. `--native 0` keeps the bots' sight scan in script when dot-sim is installed; `--motor-native 0` the movement collision queries.
## `--motor-lod N`, `--motor-lod-near 1`: bot_motor_lod and bot_motor_lod_near (far, and near, bots step their motor one tick in N).
## `--motor-tick 1|0`: [member DotFpsMotor.native_tick], a plain ground or air tick's start and end in dot-sim (needs a library with the motor tick).

var _bots := 10
## `--physoff 1`: switch the engine's 3D physics step off after warm-up. What the "physics" phase still costs is script (game tick plus every _physics_process); the drop is the engine's own share.
var _physoff := false
## `--motor-us 1`: time each player's motor step (DotFpsController's "motor" phase; the phase timers cost a little) and print microseconds per player tick.
var _motor_us := false
var _mt0 := 0
var _reuse := true
var _solid := true
var _seconds := 25.0
var _client: Node = null
var _frames := PackedFloat64Array()
var _phys := 0.0
var _proc := 0.0
var _steps0 := 0
var _n := 0
var _last := 0


func _ready() -> void:
	preload("../game/arena_weapon_roles.gd").ensure()
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--bots": _bots = int(args[i + 1])
			"--seconds": _seconds = float(args[i + 1])
			"--reuse": _reuse = int(args[i + 1]) != 0
			"--solid": _solid = int(args[i + 1]) != 0
			"--prof": DotFpsPhysicsBody.profile = int(args[i + 1]) != 0
			"--physoff": _physoff = int(args[i + 1]) != 0
			"--near": preload("../game/arena_bots.gd").think_near = float(args[i + 1])
			"--every": preload("../game/arena_bots.gd").think_every = int(args[i + 1])
			"--tier-above": preload("../game/arena_bots.gd").tiers.above = int(args[i + 1])
			"--tier-near": preload("../game/arena_bots.gd").tiers.near_every = int(args[i + 1])
			"--tier-far": preload("../game/arena_bots.gd").tiers.far_every = int(args[i + 1])
			"--tier-engaged": preload("../game/arena_bots.gd").tiers.engaged_far_every = int(args[i + 1])
			"--lod": ArenaPlayer.present_lod_enabled = int(args[i + 1]) != 0
			"--native": DotBotWorld.native_enabled = int(args[i + 1]) != 0
			"--motor-native": DotFpsPhysicsBody.native_enabled = int(args[i + 1]) != 0
			"--motor-us": _motor_us = int(args[i + 1]) != 0
			"--motor-tick": DotFpsMotor.native_tick = int(args[i + 1]) != 0
			"--motor-lod": preload("../game/arena_bots.gd").motor_lod_every = maxi(1, int(args[i + 1]))
			"--motor-lod-near": preload("../game/arena_bots.gd").motor_lod_near = int(args[i + 1]) != 0
	var _scratch := ArenaPresentation.use_scratch_settings("offline_cost")
	_run.call_deferred()


func _run() -> void:
	# Headless skips the loading-cover warm; do it after the client registers its own art table, or the default table's paths are warmed and the arena rifle loads mid-match.
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("mouse_capture_override", true)
	_client.set("offline_bots", _bots)
	add_child(_client)
	var _warmed := AwModelCache.warm(AwWeaponArtTable.model_paths())
	var pilot := ClientBench.Pilot.new()
	pilot.process_priority = -999
	add_child(pilot)
	_set_reuse(self)
	if not _solid:
		_client.game.body_rules.solid = false
	var warm := 8.0
	ArenaFrameProbe.set_interval(1.0e9)
	var t0 := Time.get_ticks_usec()
	var measuring := false
	while true:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var t := (now - t0) / 1.0e6
		if t >= warm and not measuring:
			measuring = true
			_steps0 = Engine.get_physics_frames()
			_q0 = _queries(self)
			_mt0 = _ticks
			if _motor_us:
				DotFpsMotor.profile = true
				DotFpsController.phase_us.fill(0)
				DotFpsMotor.phase_us.fill(0)
				DotFpsPhysicsBody.native_slides = 0
				DotFpsPhysicsBody.native_ticks = 0
			ArenaFrameProbe._reset()
			preload("../game/arena_bots.gd").tiers.counts.clear()
			_tally_on(_client.game)
			_last = now
			t0 = now
			continue
		if measuring:
			_frames.append((now - _last) / 1000.0)
			_last = now
			_phys += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
			_proc += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
			_n += 1
			if t > _seconds:
				break
	var sorted := _frames.duplicate()
	sorted.sort()
	var n := sorted.size()
	var mean := 0.0
	for f in _frames:
		mean += f
	mean /= n
	var hitches := 0
	for f in _frames:
		if f > 33.0:
			hitches += 1
	print("OFFLINE_COST native sight scan: %s, native motor queries: %s, native motor tick: %s" % [DotBotWorld.native_available(), DotFpsPhysicsBody.native_available(), DotFpsMotor.native_tick and DotFpsPhysicsBody.native_tick_available()])
	print("OFFLINE_COST fps %.1f | frame mean %.2f p50 %.2f p95 %.2f p99 %.2f max %.2f ms | >33ms %d | physics %.2f ms/frame process %.2f ms/frame | steps %.2f/frame (%d Hz, max %d) | %d bots" % [
		1000.0 / mean, mean, sorted[n / 2], sorted[int(n * 0.95)], sorted[int(n * 0.99)], sorted[n - 1], hitches,
		_phys / _n, _proc / _n, float(Engine.get_physics_frames() - _steps0) / _n,
		Engine.physics_ticks_per_second, Engine.max_physics_steps_per_frame, _bots])
	for key: StringName in ArenaFrameProbe._sections:
		var row: PackedInt64Array = ArenaFrameProbe._sections[key]
		print("  section %-14s %.3f ms/frame | %.3f ms/call x%d | max %.2f ms" % [key, float(row[0]) / _n / 1000.0, float(row[0]) / maxi(row[1], 1) / 1000.0, row[1], row[2] / 1000.0])
	print("  combat shots %d hits %d headshots %d kills %d hit_rate %.3f" % [_shots, _hits, _heads, _kills, float(_hits) / maxi(1, _shots)])
	print("  bot tiers: %s" % JSON.stringify(preload("../game/arena_bots.gd").tiers.describe()))
	print("  motor lod every %d (near %s): %d motor ticks skipped" % [preload("../game/arena_bots.gd").motor_lod_every, preload("../game/arena_bots.gd").motor_lod_near, ArenaPlayer.motor_skipped])
	print("  controller queries per physics step: %.1f" % (float(_queries(self) - _q0) / maxf(float(Engine.get_physics_frames() - _steps0), 1.0)))
	var pr := DotFpsPhysicsBody.prof
	print("  engine queries/frame: cast %.1f (%.2f ms) rest %.1f (%.2f ms) overlap %.1f (%.2f ms) ray %.1f (%.2f ms)" % [pr[0] / float(_n), pr[1] / 1000.0 / _n, pr[2] / float(_n), pr[3] / 1000.0 / _n, pr[4] / float(_n), pr[5] / 1000.0 / _n, pr[6] / float(_n), pr[7] / 1000.0 / _n])
	_ticks = 0; _reused = 0; _settled = 0
	var _qq := _queries(self)
	print("  motor ticks %d settled-skips %d reused start probes %d (queries per tick %.2f)" % [_ticks, _settled, _reused, float(_qq) / maxf(_ticks, 1.0)])
	if _motor_us:
		DotFpsMotor.profile = false
		var measured := _ticks - _mt0
		print("OFFLINE_COST motor %.1f us/tick per player (%d player ticks; controller simulate_tick %.1f us)" % [
			float(DotFpsController.phase_us[2]) / maxf(measured, 1.0), measured, float(_sum(DotFpsController.phase_us)) / maxf(measured, 1.0)])
		var parts := PackedStringArray()
		for i in DotFpsMotor.PHASES.size():
			if DotFpsMotor.PHASES[i] != "":
				parts.append("%s %.1f" % [DotFpsMotor.PHASES[i], float(DotFpsMotor.phase_us[i]) / maxf(measured, 1.0)])
		print("  motor phases us/tick: %s" % ", ".join(parts))
		print("  native slides %.2f, native tick halves %.2f per player tick" % [float(DotFpsPhysicsBody.native_slides) / maxf(measured, 1.0), float(DotFpsPhysicsBody.native_ticks) / maxf(measured, 1.0)])
	print("  physics3d active %d islands %d pairs %d" % [Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS), Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT), Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)])
	get_tree().quit(0)


var _q0 := 0


static func _sum(a: PackedInt64Array) -> int:
	var t := 0
	for v in a:
		t += v
	return t


func _set_reuse(node: Node) -> void:
	if node is DotFpsController and node.get("motor") != null:
		node.motor.reuse_settled_ground = _reuse
	for c in node.get_children():
		_set_reuse(c)
var _ticks := 0
var _reused := 0
var _settled := 0


func _queries(node: Node) -> int:
	var total := 0
	if node is DotFpsController and node.body != null:
		var d: Dictionary = node.body.describe()
		total += int(d.get("queries", d.get("inner", {}).get("queries", 0)))
		var m: Dictionary = node.motor.describe() if node.get("motor") != null else {}
		_ticks += int(m.get("ticks", 0))
		_reused += int(m.get("reused_ground_ticks", 0))
		_settled += int(m.get("settled_ground_ticks", 0))
	for c in node.get_children():
		total += _queries(c)
	return total


var _shots := 0
var _hits := 0
var _heads := 0
var _kills := 0


## Shots, hits and kills while measuring: the accuracy a tier change must leave alone.
func _tally_on(g: Object) -> void:
	g.connect(&"hit_confirmed", func(_a: int, _v: int, _amount: float, _p: Vector3, head: bool, lethal: bool) -> void:
		_hits += 1
		_heads += int(head)
		_kills += int(lethal))
	for p in g.call("players"):
		p.connect(&"used", func(outcome: DotWeaponOutcome) -> void:
			if outcome != null and outcome.used:
				_shots += outcome.shots.size())
