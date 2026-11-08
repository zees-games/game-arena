extends DotGameCheckSuite

const ArenaBots := preload("../game/arena_bots.gd")
const ArenaContent := preload("../game/arena_content.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

## "The bots shoot at me and I take no damage": every shot a bot fires is either a hit that costs the target
## health, or a miss whose reason is on record (ArenaShotStats: refused, prevented, aim, blocked, on line).
##
## [codeblock]
## ./game.sh test headless_bot_hitreg
## [/codeblock]
##
## [b]Direct.[/b] An attacker holds the trigger with the aim dead on a target's chest, every tick, from the target's
## present position: stationary and strafing, point blank, mid and long range. Every shot must damage it. The same
## again paced like a loaded server: several ticks run back to back (the catch-up after a slow frame) and a stall
## after them, so wall time and game time part ways.
##
## [b]Brain.[/b] The real brain (ArenaBots.think, stagger and coast on) against a stationary and a strafing target
## for a minute of game time: no shot may be refused or prevented, and none may miss while on line with a body in the open.

const TICK_RATE := ArenaContent.TICK_RATE
const ATTACKER := 1
const TARGET := 2

const RANGES := [1.5, 12.0, 40.0]
const SHOT_TICKS := 1280
const TAP_TICKS := 32
const BRAIN_SECONDS := 60.0

const CHECKS := 59
const SECTIONS := 4

var _entered := 0
var _completed := 0
var _game: ArenaGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena headless bot hit registration")
	ArenaBots.think_every = 2
	ArenaBots.think_near = 0.0
	await _direct("calm server, one tick per frame", 1, 0)
	await _direct("loaded server, 6 ticks back to back then a 40 ms stall", 6, 40)
	await _brain()
	_counter()
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _boot(seed_value: int = 1) -> void:
	if _game != null:
		remove_child(_game)
		_game.queue_free()
		await get_tree().process_frame
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
	map.id = &"hitreg_lane"
	map.display_name = "hitreg_lane"
	map.extent = 150.0
	map.wall_height = 8.0
	var _p := map.add_perimeter()
	var _s1 := map.add_spawn(Transform3D(Basis(), Vector3(0.0, 0.05, 0.0)))
	var _s2 := map.add_spawn(Transform3D(Basis(), Vector3(5.0, 0.05, 0.0)))
	var ready := _game.setup(map)
	_check(ready.ok, "the arena sets up", str(ready.error))
	_game.match_node.rules.warmup_sec = 0.0
	_game.match_node.rules.countdown_sec = 0.0
	var _a := _game.add_player(ATTACKER, "Shooter")
	var _b := _game.add_player(TARGET, "Target")
	_game.start(0)
	_game.tick({})
	await get_tree().physics_frame


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


static func angles_to(from: Vector3, to: Vector3) -> Vector2:
	var d := (to - from).normalized()
	return Vector2(rad_to_deg(atan2(-d.x, -d.z)), rad_to_deg(asin(d.y)))


## Attacker at the origin of the lane, target [param dist] metres away along -Z, both whole and unprotected.
func _place(dist: float) -> void:
	var tick: int = _game.current_tick()
	var shooter: ArenaPlayer = _game.player_for(ATTACKER)
	var target: ArenaPlayer = _game.player_for(TARGET)
	shooter.spawn(Transform3D(Basis(), Vector3(-10.0, 0.05, -20.0)), tick)
	target.spawn(Transform3D(Basis(), Vector3(-10.0, 0.05, -20.0 - dist)), tick)
	_game.combat.health_of(TARGET).health = 1.0e7
	shooter.give_default_loadout()
	shooter.arsenal.disabled = false


## The attacker's trigger-down command, aimed at the target's chest where it stands now.
func _aimed(tick_index: int) -> Array:
	var shooter: ArenaPlayer = _game.player_for(ATTACKER)
	var target: ArenaPlayer = _game.player_for(TARGET)
	var aim := angles_to(shooter.muzzle_position(), target.global_position + Vector3.UP * ArenaBots.chest_height())
	var m := DotFpsCommand.new()
	m.yaw = aim.x
	m.pitch = aim.y
	var w := DotWeaponCommand.new()
	# A tap every TAP_TICKS: holding the trigger climbs the recoil and widens the spread, which is the gun's doing.
	w.buttons = DotWeaponCommand.BUTTON_ATTACK if tick_index % TAP_TICKS == 0 else 0
	return [m, w]


func _strafe(tick_index: int, strafing: bool) -> Array:
	var m := DotFpsCommand.new()
	if strafing:
		m.move = Vector2(1.0 if (tick_index / 24) % 2 == 0 else -1.0, 0.0)
	var w := DotWeaponCommand.new()
	return [m, w]


func _direct(title: String, burst: int, stall_ms: int) -> void:
	_section("direct: " + title)
	await _boot()
	for strafing in [false, true]:
		for dist: float in RANGES:
			_place(dist)
			for _i in 4:
				_game.tick({})
			_game.shot_stats.reset()
			var i := 0
			while i < SHOT_TICKS:
				for _b in burst:
					_game.tick({ATTACKER: _aimed(i), TARGET: _strafe(i, strafing)})
					i += 1
				if stall_ms > 0:
					OS.delay_msec(stall_ms)
				await get_tree().physics_frame
			var t: Dictionary = _game.shot_stats.total([ATTACKER])
			var label := "%s %.1f m %s" % ["strafing" if strafing else "still", dist, "loaded" if burst > 1 else "calm"]
			print("    %-26s fired %d damaged %d refused %d prevented %d aim %d blocked %d on_line %d" % [
				label, t["fired"], t["damaged"], t["refused"], t["prevented"], t["miss_aim"], t["miss_blocked"], t["miss_on_line"]])
			_check(t["fired"] >= 10, "%s: the attacker fires (%d shots)" % [label, t["fired"]])
			_check(t["damaged"] == t["fired"], "%s: every shot on target costs the target health" % label,
				"%d of %d; %s" % [t["damaged"], t["fired"], _game.shot_stats.refusals])
	print(_game.shot_stats.report())
	_done()


## The brain at the trigger: stationary then strafing reference, the target made unkillable.
func _brain() -> void:
	_section("brain: ArenaBots.think against a still and a strafing target")
	await _boot()
	var mind := ArenaBots.Mind.new()
	mind.seed = 5
	for strafing in [false, true]:
		for dist: float in [4.0, 20.0]:
			_place(dist)
			var bot: ArenaPlayer = _game.player_for(ATTACKER)
			var ref: ArenaPlayer = _game.player_for(TARGET)
			for _i in 4:
				_game.tick({})
			_game.shot_stats.reset()
			var errs: Array[float] = []
			var ticks := int(BRAIN_SECONDS * TICK_RATE)
			for i in ticks:
				var tick: int = _game.current_tick()
				var cmds := {ATTACKER: ArenaBots.think(_game, bot, mind, tick, float(TICK_RATE)), TARGET: _strafe(i, strafing)}
				var wc: DotWeaponCommand = cmds[ATTACKER][1]
				if wc.is_pressed(DotWeaponCommand.BUTTON_ATTACK) and bot.is_alive():
					var mv: DotFpsCommand = cmds[ATTACKER][0]
					var ideal := angles_to(bot.muzzle_position(), ref.global_position + Vector3.UP * ArenaBots.chest_height())
					errs.append(Vector2(wrapf(mv.yaw - ideal.x, -180.0, 180.0), mv.pitch - ideal.y).length())
				_game.tick(cmds)
				_game.combat.health_of(TARGET).health = 1.0e7
				if i % 8 == 0:
					await get_tree().physics_frame
			var t: Dictionary = _game.shot_stats.total([ATTACKER])
			var label := "bot vs %s %.0f m" % ["strafing" if strafing else "still", dist]
			print("    %-26s fired %d damaged %d refused %d prevented %d aim %d blocked %d on_line %d" % [
				label, t["fired"], t["damaged"], t["refused"], t["prevented"], t["miss_aim"], t["miss_blocked"], t["miss_on_line"]])
			errs.sort()
			if not errs.is_empty():
				print("      command aim error at the trigger (deg): median %.2f p90 %.2f max %.2f over %d ticks; bot_aim_error %.1f aim_floor %.1f" % [
					errs[errs.size() / 2], errs[int(errs.size() * 0.9)], errs[-1], errs.size(), mind.brain.settings.profile.aim_error, mind.brain.settings.profile.aim_floor])
			_check(t["fired"] >= 5, "%s: the bot fires (%d shots)" % [label, t["fired"]])
			_check(t["refused"] == 0 and t["prevented"] == 0, "%s: no shot is refused or prevented" % label, str(_game.shot_stats.refusals))
			_check(t["miss_on_line"] == 0 and t["miss_blocked"] == 0, "%s: no shot lost while on line with the body" % label, str(_game.shot_stats.on_line_log.slice(-3)))
			_check(float(t["damaged"]) >= 0.5 * float(t["fired"]), "%s: at least half the shots land" % label, "%d of %d" % [t["damaged"], t["fired"]])
	print(_game.shot_stats.report())
	_done()


## The counter reads out as text and clears.
func _counter() -> void:
	_section("the counter")
	var text: String = _game.shot_stats.report()
	_check(text.begins_with("shots: fired"), "the report leads with the totals")
	_check(text.contains("#%d:" % ATTACKER), "and has a line for the shooter")
	_game.shot_stats.reset()
	_check(_game.shot_stats.total()["fired"] == 0, "reset clears it")
	_done()
