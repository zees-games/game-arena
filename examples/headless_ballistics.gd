extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

## sv_ballistics through the whole game: off, a velocity weapon stays hitscan and damages instantly; on, its
## bullet takes time, drops, and hits once.
##
## [codeblock]
## godot --headless --path . res://examples/headless_ballistics.tscn
## [/codeblock]

const TICK_RATE := 64
const EXPECTED_CHECKS := 13

var _checks := 0
var _failed := 0
var _game: ArenaGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	Engine.physics_ticks_per_second = TICK_RATE
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _fire(ticks: int) -> void:
	for i in ticks:
		var w := DotWeaponCommand.new()
		w.buttons = DotWeaponCommand.BUTTON_ATTACK if i == 0 else 0
		_game.tick({1: [DotFpsCommand.new(), w]})
		await get_tree().physics_frame


## Builds the game with a shooter and a target and lets it settle.
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
	var ready := _game.setup(ArenaMap.dm_box())
	_check(ready.ok, "the arena sets up", str(ready.error))
	_game.match_node.rules.warmup_sec = 0.0
	_game.match_node.rules.countdown_sec = 0.0
	var _a := _game.add_player(1, "Shooter")
	var _b := _game.add_player(2, "Target")
	_game.start(0)
	_game.tick({})
	await get_tree().physics_frame


func _run() -> void:
	await _boot()
	var shooter := _game.player_for(1)
	var victim := _game.player_for(2)
	shooter.give_default_loadout()
	await _fire(0)
	for _i in 150:
		_game.tick({})
		await get_tree().physics_frame
	var def := shooter.arsenal.current_def()
	var tuning := ArenaPlayer.weapon_catalogue().get_def(def.id).tuning as DotWeaponBallistics
	var was := [tuning.muzzle_velocity, tuning.bullet_gravity, tuning.drag, tuning.max_range, tuning.spread, tuning.spread_moving, tuning.recoil_pitch]
	tuning.muzzle_velocity = 40.0
	tuning.bullet_gravity = 1.0
	tuning.drag = 0.0005
	tuning.max_range = 120.0
	tuning.spread = 0.0
	tuning.spread_moving = 0.0
	tuning.pellets = 1

	var dir := shooter.aim_direction()
	var origin := shooter.muzzle_position()
	var feet := origin + dir * 15.0 - Vector3(0.0, 1.3, 0.0)
	feet.y = maxf(feet.y, 0.05)
	victim.spawn(Transform3D(Basis(), feet), 1)
	_game.tick({})
	var health_before := _game.combat.health_of(2).health
	var info := {"hits": [], "point": Vector3.ZERO, "ticks": 0}
	_check(_game.bullet_bridge != null, "the game builds a bullet bridge")
	_check(not _game.combat_feel.ballistics.enabled, "sv_ballistics is off by default")
	var round_of := shooter.arsenal.round_for(&"rifle")
	_check(round_of != null and round_of.penetration > 0.0, "the rifle's round, from cfg ammo data, can penetrate")
	var sniper := shooter.arsenal.round_for(&"sniper")
	_check(sniper != null and sniper.penetration > round_of.penetration, "the sniper's round penetrates further")
	_check(shooter.arsenal.round_for(&"charge_rifle").penetration == 0.0, "a cell round penetrates nothing")

	await _fire(3)
	var off_health := _game.combat.health_of(2).health
	_check(_game.bullet_bridge.bullets.count() == 0, "off: no bullets are flown")
	var off_damaged := off_health < health_before
	print("  off: health %s -> %s" % [health_before, off_health])

	_game.combat.health_of(2).health = health_before
	_game.combat_feel.ballistics.set(&"enabled", true)
	_game.bullet_bridge.bullet_hit.connect(func(_id: int, d: DotDamage) -> void:
		info.hits.append(d)
		info.point = d.point
		info.ticks = _game.get_tick() if _game.has_method(&"get_tick") else 0)
	for _i in 80:
		_game.tick({})
		await get_tree().physics_frame
	await _fire(1)
	_check(_game.bullet_bridge.bullets.count() >= 1 or not info.hits.is_empty(), "on: the shot became a bullet")
	_check(info.hits.is_empty(), "it has not arrived on the tick it was fired", str(info.hits.size()))
	await _fire(60)
	_check(info.hits.size() == 1, "the bullet hit the target once", str(info.hits.size()))
	if info.hits.size() == 1:
		_check(info.point.y < origin.y - 0.4, "and had dropped by the time it arrived", "%.2f m below" % (origin.y - info.point.y))
		_check(_game.combat.health_of(2).health < health_before, "and the damage was applied")
	else:
		_check(false, "dropped", "no hit")
		_check(false, "damage applied")
	_check(_game.bullet_bridge.bullets.count() == 0, "nothing left in flight")
	tuning.muzzle_velocity = was[0]
	tuning.bullet_gravity = was[1]
	tuning.drag = was[2]
	tuning.max_range = was[3]
	tuning.spread = was[4]
	tuning.spread_moving = was[5]
	tuning.recoil_pitch = was[6]
	print("  off-damage-before-switch: %s" % off_damaged)
	var ok := _failed == 0 and _checks == EXPECTED_CHECKS
	print("%d checks, %d failed (expected %d)" % [_checks, _failed, EXPECTED_CHECKS])
	get_tree().quit(0 if ok else 1)
