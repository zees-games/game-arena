extends Node

const ArenaMap := preload("../maps/arena_map.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaModuleCvars := preload("../game/arena_module_cvars.gd")

## What dot-game's DotGameCombatFeel does to a real ArenaPlayer: spread widens while moving, airborne and
## sliding and narrows crouched; the recoil pattern is the same every run; the cl_crosshair_* cvars restyle
## the crosshair through the console; the sprint rules are opt-in.
##
## [codeblock]
## godot --headless --path . res://examples/headless_combatfeel.tscn
## [/codeblock]

const TICK_RATE := 64
const EXPECTED_SECTIONS := 4
const EXPECTED_CHECKS := 36

var _checks := 0
var _failed := 0
var _sections := 0
var _tick := 1
var _feel: DotGameCombatFeel = null
var last_slid := false


func _ready() -> void:
	Engine.physics_ticks_per_second = TICK_RATE
	_run.call_deferred()


func _run() -> void:
	_feel = DotGameCombatFeel.new(true, false)
	await _test_spread()
	await _test_recoil()
	_test_console()
	_test_wiring()
	var ok := _failed == 0 and _sections == EXPECTED_SECTIONS and _checks == EXPECTED_CHECKS
	print("%d checks, %d failed, %d sections of %d (expected %d checks)" % [
		_checks, _failed, _sections, EXPECTED_SECTIONS, EXPECTED_CHECKS])
	get_tree().quit(0 if ok else 1)


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _player(id: int) -> ArenaPlayer:
	var p := ArenaPlayer.new()
	p.name = "P%d" % id
	p.setup(ArenaPlayer.Mode.HEADLESS, ArenaMap.dm_box(), id, "P%d" % id)
	add_child(p)
	p.spawn(Transform3D(Basis(), Vector3(-16.0, 0.05, 6.0)), 0)
	p.give_default_loadout()
	_feel.attach(p.arsenal)
	return p


static func _move(forward: float, buttons: int) -> DotFpsCommand:
	var c := DotFpsCommand.new()
	c.move = Vector2(0.0, forward)
	c.yaw = -90.0
	c.buttons = buttons
	return c


func _step(p: ArenaPlayer, move: DotFpsCommand, fire: bool = false) -> DotWeaponOutcome:
	var w := DotWeaponCommand.new()
	if fire:
		w.buttons = DotWeaponCommand.BUTTON_ATTACK
	var out := p.simulate_tick(_tick, 1.0 / float(TICK_RATE), move, w)
	_tick += 1
	await get_tree().physics_frame
	return out


## The widest cone over [param ticks] ticks of [param move], after settling still first.
func _widest(p: ArenaPlayer, ticks: int, move: Callable, settle: Callable = Callable()) -> float:
	for _i in 80:
		await _step(p, _move(0.0, 0))
	if settle.is_valid():
		for _i in 40:
			await _step(p, settle.call(0))
	var widest := 0.0
	var slid := false
	for i in ticks:
		await _step(p, move.call(i))
		widest = maxf(widest, p.arsenal.spread_now())
		slid = slid or p.controller.state.is_sliding()
	last_slid = slid
	return widest


func _test_spread() -> void:
	_sections += 1
	print("== spread follows the movement")
	var p := _player(1)
	await get_tree().physics_frame
	var still := 0.0
	for _i in 80:
		await _step(p, _move(0.0, 0))
	still = p.arsenal.spread_now()
	var run := await _widest(p, 60, func(_i: int) -> DotFpsCommand: return _move(1.0, 0))
	var jump := await _widest(p, 40, func(i: int) -> DotFpsCommand: return _move(0.0, DotFpsCommand.BUTTON_JUMP if i < 3 else 0))
	p.controller.teleport(Vector3(-16.0, 0.05, 6.0), -90.0, 0.0)
	var slide := await _widest(p, 40, func(_i: int) -> DotFpsCommand: return _move(1.0, DotFpsCommand.BUTTON_CROUCH), func(_i: int) -> DotFpsCommand: return _move(1.0, 0))
	var slid := last_slid
	p.controller.teleport(Vector3(-16.0, 0.05, 6.0), -90.0, 0.0)
	var crouch_still := await _widest(p, 40, func(_i: int) -> DotFpsCommand: return _move(0.0, DotFpsCommand.BUTTON_CROUCH))
	print("    still %.3f  run %.3f  jump %.3f  slide %.3f  crouched %.3f degrees" % [still, run, jump, slide, crouch_still])
	_check(still > 0.0, "a standing player has a cone", "%.3f" % still)
	_check(run > still * 1.2, "running widens it", "%.3f vs %.3f" % [run, still])
	_check(jump > run, "the air widens it past a run", "%.3f vs %.3f" % [jump, run])
	_check(slid, "the player really slid")
	_check(slide > still * 1.2, "a slide widens it (the context carries the slide)", "%.3f vs %.3f" % [slide, still])
	_check(crouch_still < still, "crouching narrows it", "%.3f vs %.3f" % [crouch_still, still])
	await get_tree().physics_frame
	var settled := 0.0
	for _i in 200:
		await _step(p, _move(0.0, 0))
	settled = p.arsenal.spread_now()
	_check(absf(settled - still) < 0.01, "and it settles back once still", "%.3f vs %.3f" % [settled, still])
	p.queue_free()


func _burst(id: int, forward: float, crouch: bool) -> Array:
	var p := _player(id)
	await get_tree().physics_frame
	for _i in 40:
		await _step(p, _move(0.0, 0))
	var kicks: Array = []
	var buttons := DotFpsCommand.BUTTON_CROUCH if crouch else 0
	for _i in 120:
		var out := await _step(p, _move(forward, buttons), true)
		if out != null and out.recoil != Vector2.ZERO:
			kicks.append(out.recoil)
	p.queue_free()
	return kicks


func _test_recoil() -> void:
	_sections += 1
	print("== recoil is a pattern")
	var a: Array = await _burst(10, 0.0, false)
	var b: Array = await _burst(11, 0.0, false)
	var moving: Array = await _burst(12, 1.0, false)
	var crouched: Array = await _burst(13, 0.0, true)
	print("    shots %d %d %d %d; first kick %s" % [a.size(), b.size(), moving.size(), crouched.size(), str(a[0]) if not a.is_empty() else "-"])
	_check(a.size() >= 5, "a held trigger kicks every shot", "%d kicks" % a.size())
	_check(a == b, "the same burst kicks identically in two runs (a pattern, not noise)")
	var grows := a.size() >= 5 and (a[4] as Vector2).length() > (a[0] as Vector2).length()
	_check(grows, "the kick builds along the burst")
	var yaws := a.map(func(k: Vector2) -> bool: return k.x != 0.0)
	_check(a.any(func(k: Vector2) -> bool: return k.y > 0.0) and a.any(func(k: Vector2) -> bool: return k.y < 0.0) or a.any(func(k: Vector2) -> bool: return k.y != 0.0), "the pattern has a sideways component", str(yaws.size()))
	_check(not moving.is_empty() and not a.is_empty() and (moving[0] as Vector2).length() > (a[0] as Vector2).length(), "moving kicks harder than standing")
	_check(not crouched.is_empty() and not a.is_empty() and (crouched[0] as Vector2).length() < (a[0] as Vector2).length(), "crouching kicks less than standing")


func _test_console() -> void:
	_sections += 1
	print("== cl_crosshair_* at the console")
	if _feel.crosshair_cvars == null:
		_check(false, "dot-ui's crosshair cvars are present")
		return
	var cross := DotCrosshair.new()
	add_child(cross)
	var console := DotConsoleLocal.new()
	_check(_feel.bind_console(console, cross), "bind_console registers on a local source")
	var listed := console.names()
	_check(listed.has("cl_crosshair_size") and listed.has("cl_crosshair_gap") and listed.has("cl_crosshair_colour"), "the cvars are listed")
	_check(console.execute("cl_crosshair_size 21").ok and cross.length == 21.0, "cl_crosshair_size restyles the crosshair", str(cross.length))
	_check(console.execute("cl_crosshair_gap 9").ok and cross.base_gap == 9.0, "cl_crosshair_gap does")
	_check(console.execute("cl_crosshair_style 2").ok and cross.length == 0.0 and cross.centre_dot, "style 2 is dot only")
	_check(console.execute("cl_crosshair_colour ff0000").ok and cross.colour.r > 0.99 and cross.colour.g < 0.01, "cl_crosshair_colour takes a colour")
	_check(not console.execute("cl_crosshair_size banana").ok, "garbage is refused")
	_check(console.execute("cl_crosshair_show 0").ok and not cross.visible, "show 0 hides it")
	cross.queue_free()


func _test_wiring() -> void:
	_sections += 1
	print("== the opt-in wiring")
	_check(_feel.spread != null and _feel.recoil != null, "dot-weapon's rules are loaded by path")
	_check(_feel.sprint == null, "a game may opt out of the sprint rules")
	var names: Array[String] = []
	_feel.bind_cvars(func(n: String, d: String, _h: String, _f: int) -> Object:
		names.append(n)
		return null)
	_check(names.any(func(n: String) -> bool: return n.begins_with("sv_spread")) and names.any(func(n: String) -> bool: return n.begins_with("sv_recoil")), "sv_spread* and sv_recoil* register", str(names.size()))
	_check(not names.any(func(n: String) -> bool: return n.begins_with("sv_sprint") or n.begins_with("sv_stamina")), "no sv_sprint* or sv_stamina* register")
	var with_sprint := DotGameCombatFeel.new(true)
	_check(with_sprint.sprint != null, "the default opt-in loads the sprint rules")
	var tun := DotFpsTunables.new()
	with_sprint.track_tunables(tun)
	with_sprint.sprint.call(&"set_cvar", "sv_sprintspeed", "2.25")
	_check(is_equal_approx(tun.sprint_speed_scale, 2.25), "a sprint cvar change reaches a tracked player", str(tun.sprint_speed_scale))

	var arena := DotGameCombatFeel.new(true, true)
	arena.sprint_defaults(ArenaPlayer.arena_tunables())
	var arena_tun := ArenaPlayer.arena_tunables()
	arena.track_tunables(arena_tun)
	_check(arena.sprint != null and is_equal_approx(arena_tun.sprint_speed_scale, 1.0) and arena_tun.sprint_can_shoot, "the arena loads the sprint rules without changing its speeds")
	var arena_names: Array[String] = []
	arena.bind_cvars(func(n: String, _d: String, _h: String, _f: int) -> Object:
		arena_names.append(n)
		return null)
	_check(arena_names.has("sv_sprint_shoot") and arena_names.has("sv_sprint_barrel"), "sv_sprint_shoot and sv_sprint_barrel register")
	arena.sprint.call(&"set_cvar", "sv_sprint_shoot", "0")
	arena.sprint.call(&"set_cvar", "sv_sprint_barrel", "0")
	_check(not arena_tun.sprint_can_shoot and not arena_tun.sprint_shot_follows_barrel, "and reach a tracked player's tunables")
	var fresh := DotFpsTunables.new()
	_check(fresh.sprint_can_shoot and fresh.sprint_shot_follows_barrel, "both default on: sprint-and-shoot allowed, along the barrel")
	var launch_default := ArenaPlayer.arena_tunables().launch_velocity
	_check(launch_default >= 12.0 * 1.25 and launch_default <= 12.0 * 1.35, "the launch defaults 25 to 35 percent above the old 12 m/s", str(launch_default))
	_check(ArenaModuleCvars.MOVEMENT_CVARS.get("arena_launch_velocity", [""])[0] == "launch_velocity" and ArenaPlayer.MOVEMENT_RULES.has("launch_velocity"), "arena_launch_velocity sets the launch and is a replicated movement rule")
	var speeds := ArenaPlayer.arena_tunables()
	_check(speeds.max_speed < 8.0 and speeds.max_speed > 7.0, "the arena runs about 15 percent slower than the old 9 m/s", str(speeds.max_speed))
	var run_before := speeds.speed_for(0)
	speeds.speed_scale = 0.5
	_check(is_equal_approx(speeds.speed_for(0), run_before * 0.5) and is_equal_approx(speeds.speed_for(DotFpsCommand.BUTTON_CROUCH), speeds.max_speed * speeds.crouch_speed_scale * 0.5), "speed_scale scales run and crouch alike")
	var speed_ok := true
	for cvar in ["arena_speed_scale", "arena_run_speed", "arena_walk_scale", "arena_sprint_scale", "arena_crouch_scale"]:
		speed_ok = speed_ok and ArenaModuleCvars.MOVEMENT_CVARS.has(cvar) and ArenaPlayer.MOVEMENT_RULES.has(ArenaModuleCvars.MOVEMENT_CVARS[cvar][0])
	_check(speed_ok, "every speed cvar is a replicated movement rule, so prediction agrees")
