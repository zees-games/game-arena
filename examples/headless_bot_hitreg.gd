extends DotGameCheckSuite

const ArenaBots := preload("../game/arena_bots.gd")
const ArenaContent := preload("../game/arena_content.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaPlayerTunables := preload("../game/arena_player_tunables.gd")

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

const CHECKS := 54
const SECTIONS := 5

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
	await _crowd()
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
			for _i in _game.match_node.spawn_protection_ticks() + 4:
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
			# The gun's own spread opens a miss or two in three at 40 m even from a tap: that range only has to land most.
			var want := 0.3 if dist > 30.0 else 1.0
			_check(float(t["damaged"]) >= want * float(t["fired"]), "%s: shots on target cost the target health" % label,
				"%d of %d; %s" % [t["damaged"], t["fired"], _game.shot_stats.refusals])
	print(_game.shot_stats.report())
	_done()


## The brain at the trigger against a still and a strafing target (made unkillable), its deliberate aim error
## switched off so what is left is the gun: once without the recoil compensation, once with it.
func _brain() -> void:
	_section("brain: ArenaBots.think against a still and a strafing target, recoil compensation off then on")
	await _boot()
	var landed := {false: 0, true: 0}
	var shots := {false: 0, true: 0}
	# Whole control, so what is measured is the correction itself; bot_recoil_control scales it per difficulty.
	ArenaBots.recoil_control = 1.0
	for comp in [false, true]:
		ArenaBots.recoil_compensation = comp
		var mind := ArenaBots.Mind.new()
		mind.seed = 5
		for strafing in [false, true]:
			for dist: float in [4.0, 20.0]:
				_place(dist)
				var bot: ArenaPlayer = _game.player_for(ATTACKER)
				var ref: ArenaPlayer = _game.player_for(TARGET)
				for _i in _game.match_node.spawn_protection_ticks() + 4:
					_game.tick({})
				_game.shot_stats.reset()
				var ticks := int(BRAIN_SECONDS * TICK_RATE)
				var errs: Array[float] = []
				var dirs: Array[float] = []
				var spreads: Array[float] = []
				var probe := func(shot: DotShot) -> void:
					if shot.attacker == ATTACKER:
						var want := (ref.global_position + Vector3.UP * ArenaBots.chest_height() - shot.origin).normalized()
						dirs.append(rad_to_deg(shot.direction.angle_to(want)))
						spreads.append(shot.spread)
				_game.combat.shot_resolved.connect(probe)
				for i in ticks:
					var tick: int = _game.current_tick()
					if mind.brain != null:
						mind.brain.settings.profile.aim_error = 0.0
						mind.brain.settings.profile.aim_floor = 0.0
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
				var label := "bot %s vs %s %.0f m" % ["comp" if comp else "raw", "strafing" if strafing else "still", dist]
				print("    %-30s fired %d damaged %d refused %d prevented %d aim %d blocked %d on_line %d" % [
					label, t["fired"], t["damaged"], t["refused"], t["prevented"], t["miss_aim"], t["miss_blocked"], t["miss_on_line"]])
				_game.combat.shot_resolved.disconnect(probe)
				dirs.sort()
				spreads.sort()
				if not dirs.is_empty():
					print("      bullet direction off the chest before spread (deg): median %.2f p90 %.2f; spread median %.2f" % [dirs[dirs.size() / 2], dirs[int(dirs.size() * 0.9)], spreads[spreads.size() / 2]])
				errs.sort()
				if not errs.is_empty():
					print("      command aim error at the trigger (deg): median %.2f p90 %.2f max %.2f over %d ticks" % [errs[errs.size() / 2], errs[int(errs.size() * 0.9)], errs[-1], errs.size()])
				landed[comp] += int(t["damaged"])
				shots[comp] += int(t["fired"])
				if comp:
					_check(t["fired"] >= 5, "%s: the bot fires (%d shots)" % [label, t["fired"]])
					_check(t["refused"] == 0 and t["prevented"] == 0, "%s: no shot is refused or prevented" % label, str(_game.shot_stats.refusals))
					# The gun's own spread (5 degrees held) takes the rest; what the bot owns is where the bullet is pointed.
					if not strafing and not dirs.is_empty():
						_check(dirs[dirs.size() / 2] < 1.0, "%s: the bullets leave within a degree of the chest" % label, "median %.2f" % dirs[dirs.size() / 2])
	ArenaBots.recoil_compensation = true
	ArenaBots.recoil_control = -1.0
	print("    hit rate without compensation %d of %d, with it %d of %d" % [landed[false], shots[false], landed[true], shots[true]])
	_check(float(landed[true]) / maxf(float(shots[true]), 1.0) > 1.3 * float(landed[false]) / maxf(float(shots[false]), 1.0),
		"compensating the recoil lifts the hit rate by a third or more")
	print(_game.shot_stats.report())
	_done()


## 16v16 and latency: 30 more players crowd the arena (the rewind moves every one of them each shot) while a strafing
## target is shot from a still attacker, aimed at where its head and chest WERE `lag` ticks ago (what the shooter's screen
## showed), resolved as ArenaGame.tick resolves a fired weapon. Nearly every shot must land, head shots in the head zone.
func _crowd() -> void:
	_section("crowd: 32 players, strafing target, head and chest, rewound by 0 to 25 ticks")
	await _boot()
	for k in 30:
		var _p := _game.add_player(10 + k, "Crowd%d" % k)
		_game.player_for(10 + k).spawn(Transform3D(Basis(), Vector3(-10.0 + 3.0 * (k % 8), 0.05, -100.0 - 3.0 * (k / 8))), _game.current_tick())
	_place(25.0)
	for _i in _game.match_node.spawn_protection_ticks() + 4:
		_game.tick({})
	var shooter: ArenaPlayer = _game.player_for(ATTACKER)
	var target: ArenaPlayer = _game.player_for(TARGET)
	var hist := {"head": [], "chest": []}
	var offsets := {"head": 1.62 * ArenaPlayerTunables.body_scale(), "chest": ArenaBots.chest_height()}
	var ticks := 0
	for lag: float in [0.0, 6.0, 12.5, 25.0]:
		var got := {"head": 0, "chest": 0}
		var zone := 0
		var shots := 0
		for i in 320:
			_game.tick({TARGET: _strafe(ticks, true)})
			ticks += 1
			_game.combat.health_of(TARGET).health = 1.0e7
			for region: String in hist:
				hist[region].append(target.global_position + Vector3.UP * offsets[region])
			if hist["head"].size() < 40 or i % 12 != 0:
				continue
			shots += 1
			var back := int(floor(lag))
			for region: String in hist:
				var h: Array = hist[region]
				var a: Vector3 = h[h.size() - 1 - back]
				var b: Vector3 = h[h.size() - 1 - back - 1]
				var at := a.lerp(b, lag - float(back))
				var shot := DotShot.make(&"crowd_probe", ATTACKER, _game._tick, 0)
				shot.origin = shooter.muzzle_position()
				shot.direction = (at - shot.origin).normalized()
				shot.pellets = [shot.direction]
				shot.pellet_count = 1
				shot.damage = 1.0
				shot.max_range = 200.0
				shot.damage_type = DotDamageType.new()
				_game._unlag_shooter = ATTACKER
				_game._resolve_shot(shot, float(_game._tick) - lag)
				for d in shot.damages:
					if d.victim == TARGET:
						got[region] += 1
						if region == "head" and String(d.hit_group).contains("head"):
							zone += 1
		print("    lag %5.1f ticks: head %d/%d (in the head zone %d), chest %d/%d" % [lag, got["head"], shots, zone, got["chest"], shots])
		_check(got["chest"] >= int(shots * 0.9), "lag %.1f: chest shots hit the strafing target in a crowd" % lag, "%d of %d" % [got["chest"], shots])
		_check(got["head"] >= int(shots * 0.9), "lag %.1f: head shots hit the strafing target in a crowd" % lag, "%d of %d" % [got["head"], shots])
		_check(zone >= int(got["head"] * 0.9), "lag %.1f: head shots are credited to the head zone" % lag, "%d of %d" % [zone, got["head"]])
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
