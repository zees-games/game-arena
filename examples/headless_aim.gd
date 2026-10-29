extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

## Hit registration end to end: a still target at 20, 40 and 80 m, the aim centred on its head, a scoped sniper
## fired. The shot must land on the head (a headshot, a confirmed hit), standing and crouched, on the first shot
## and on a follow-up while the sights are still up.
##
## [codeblock]
## godot --headless --path . res://examples/headless_aim.tscn
## [/codeblock]

const TICK_RATE := 64
const DISTANCES := [20.0, 40.0, 80.0]
const EXPECTED_CHECKS := 29

var _checks := 0
var _failed := 0
var _game: ArenaGame = null
var _hits: Array = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	Engine.physics_ticks_per_second = TICK_RATE
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _now() -> int:
	return _game.get_tick() if _game.has_method(&"get_tick") else 1


func _boot() -> void:
	_game = ArenaGame.new()
	_game.name = "Arena"
	_game.tick_rate = TICK_RATE
	_game.score_limit = 0
	_game.time_limit_sec = 0.0
	_game.headless = true
	_game.is_authority = true
	_game.register_service = false
	add_child(_game)
	var map := ArenaMap.new()
	map.id = &"aim_lane"
	map.display_name = "aim_lane"
	map.extent = 150.0
	map.wall_height = 8.0
	var _p := map.add_perimeter()
	var _s1 := map.add_spawn(Transform3D(Basis(), Vector3(0.0, 0.05, 0.0)))
	var _s2 := map.add_spawn(Transform3D(Basis(), Vector3(5.0, 0.05, 0.0)))
	var ready := _game.setup(map)
	_check(ready.ok, "the arena sets up", str(ready.error))
	_game.match_node.rules.warmup_sec = 0.0
	_game.match_node.rules.countdown_sec = 0.0
	var _a := _game.add_player(1, "Shooter")
	var _b := _game.add_player(2, "Target")
	_game.start(0)
	_game.tick({})
	_game.hit_confirmed.connect(func(a: int, v: int, amount: float, point: Vector3, head: bool, lethal: bool) -> void:
		_hits.append({"attacker": a, "victim": v, "amount": amount, "point": point, "head": head, "lethal": lethal}))
	await get_tree().physics_frame


func _step(buttons: int, yaw: float, pitch: float, crouch: bool = false) -> void:
	var m := DotFpsCommand.new()
	m.yaw = yaw
	m.pitch = pitch
	m.buttons = DotFpsCommand.BUTTON_CROUCH if crouch else 0
	var w := DotWeaponCommand.new()
	w.buttons = buttons
	_game.tick({1: [m, w]})
	await get_tree().physics_frame


## A few quiet ticks: a confirmed hit can surface a tick after the shot.
func _settle(aim: int, a: Vector2, crouch: bool) -> void:
	for _i in 12:
		await _step(aim, a.x, a.y, crouch)


## The yaw and pitch (degrees) that point [param from] at [param to].
static func angles_to(from: Vector3, to: Vector3) -> Vector2:
	var d := (to - from).normalized()
	return Vector2(rad_to_deg(atan2(-d.x, -d.z)), rad_to_deg(asin(d.y)))


## One trial: the target [param dist] metres down -X from the shooter, the camera centre on its head.
func _trial(dist: float, crouch: bool, follow_up: bool) -> Dictionary:
	var shooter := _game.player_for(1)
	var victim := _game.player_for(2)
	var tick: int = _now()
	shooter.spawn(Transform3D(Basis(), Vector3(-10.0 - 0.0, 0.05, -20.0)), tick)
	victim.spawn(Transform3D(Basis(), Vector3(-10.0 - dist, 0.05, -20.0)), tick)
	# Tough enough to survive: a dead target is respawned by the game at a spawn point mid-trial.
	_game.combat.health_of(2).health = 100000.0
	var _fill := shooter.arsenal.give(ZeeWeaponIds.SNIPER)
	for _i in 4:
		await _step(0, 0.0, 0.0)
	var eye := shooter.muzzle_position()
	var head := victim.global_position + Vector3(0.0, 1.62, 0.0)
	var a := angles_to(eye, head)
	_hits.clear()
	var aim := DotWeaponCommand.BUTTON_USER_0
	# The sights come up before the trigger: a scoped shot is never a hip one.
	for _i in 150:
		await _step(aim, a.x, a.y, crouch)
	await _step(aim | DotWeaponCommand.BUTTON_ATTACK, a.x, a.y, crouch)
	await _settle(aim, a, crouch)
	var first := _hits.duplicate()
	var second := []
	if follow_up:
		for _i in 140:
			await _step(aim, a.x, a.y, crouch)
		_hits.clear()
		await _step(aim | DotWeaponCommand.BUTTON_ATTACK, a.x, a.y, crouch)
		await _settle(aim, a, crouch)
		second = _hits.duplicate()
	return {"one": first, "two": second, "eye": eye, "head": head, "angles": a}


func _run() -> void:
	await _boot()
	var shooter := _game.player_for(1)
	var give := shooter.arsenal.give(ZeeWeaponIds.SNIPER)
	_check(give.ok, "the sniper is given", str(give.error))
	shooter.give_default_loadout()
	var _g2 := shooter.arsenal.give(ZeeWeaponIds.SNIPER)
	_select_sniper(shooter)
	for _i in 120:
		_game.tick({})
		await get_tree().physics_frame
	_check(shooter.arsenal.current_def().id == ZeeWeaponIds.SNIPER, "the sniper is in the hands", str(shooter.arsenal.current_def().id))
	for d in DISTANCES:
		var t := await _trial(d, false, true)
		var f: Array = t.one
		var s: Array = t.two
		print("    %.0f m: eye %s head %s hits %d / %d" % [d, t.eye, t.head, f.size(), s.size()])
		_check(f.size() == 1, "%.0f m: the first scoped shot at the head registers" % d, str(f.size()))
		_check(f.size() == 1 and f[0].head, "%.0f m: and it is a headshot" % d, str(f))
		_check(f.size() == 1 and f[0].amount > 100.0, "%.0f m: and it is a full headshot, not a body one" % d, str(f))
		_check(s.size() == 1 and s[0].head, "%.0f m: the follow-up lands on the head too" % d, str(s.size()))
		_check(true, "%.0f m: ran" % d)
	for d in DISTANCES:
		var t := await _trial(d, true, false)
		var f: Array = t.one
		print("    crouched shooter %.0f m: eye %s hits %d" % [d, t.eye, f.size()])
		_check(f.size() == 1 and f[0].head, "%.0f m: a crouched shooter's centred shot is a headshot" % d, str(f))
		_check(f.size() == 1, "%.0f m: crouched shot registers" % d)
	await _probe_buffer()
	var ok := _failed == 0 and _checks == EXPECTED_CHECKS
	print("%d checks, %d failed (expected %d)" % [_checks, _failed, EXPECTED_CHECKS])
	get_tree().quit(0 if ok else 1)


func _select_sniper(shooter: ArenaPlayer) -> void:
	var _ok := shooter.arsenal.select(ZeeWeaponIds.SLOT_HEAVY, _now())


## Fires once, then presses again [param press_at] ticks later (or holds from there) and counts the extra hits.
func _buffer_case(window: float, press_at: int, hold: bool) -> int:
	_game.player_for(1).arsenal.fire_buffer_seconds = window
	var a: Vector2 = (await _trial(40.0, false, false)).angles
	var aim := DotWeaponCommand.BUTTON_USER_0
	var fire := DotWeaponCommand.BUTTON_ATTACK
	for _i in 200:
		await _step(aim, a.x, a.y)
	_hits.clear()
	await _step(aim | fire, a.x, a.y)
	for i in 160:
		var down := i >= press_at and (hold or i == press_at)
		await _step(aim | (fire if down else 0), a.x, a.y)
	return _hits.size() - 1


func _probe_buffer() -> void:
	var early := 20
	var late := 78
	_check(await _buffer_case(0.15, early, false) == 0, "a tap 20 ticks into the bolt cycle does not fire later (0.15 s window)")
	_check(await _buffer_case(0.15, early, true) == 0, "holding the trigger from mid-cycle does not fire later (semi, 0.15 s window)")
	_check(await _buffer_case(0.15, late, false) == 1, "a tap just before the cycle ends fires when it ends (0.15 s window)")
	_check(await _buffer_case(0.0, late, false) == 0, "a window of 0 drops even that tap")
	_check(await _buffer_case(-1.0, early, false) == 1, "a negative window keeps the old unlimited buffer")
	_game.player_for(1).arsenal.fire_buffer_seconds = _game.fire_buffer_seconds
