extends DotGameCheckSuite

const ArenaBots := preload("../game/arena_bots.gd")
const ArenaContent := preload("../game/arena_content.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaPlayerTunables := preload("../game/arena_player_tunables.gd")

## Hit zones, damage and bot fairness, measured: what one round of every firearm does to each
## zone of a fresh player, and what each bot difficulty lands on a target (hit share, head share,
## damage rate) with the recoil control it is given.

const TICK_RATE := ArenaContent.TICK_RATE
const ATTACKER := 1
const TARGET := 2
const ZONES := {"head": 1.62, "neck": 1.46, "chest": 1.15, "stomach": 0.85, "leg": 0.5}
const FIREARMS: PackedStringArray = [
	"pistol", "revolver", "derringer", "machine_pistol", "smg", "carbine", "rifle", "bullpup", "burst_rifle",
	"battle_rifle", "lmg", "minigun", "marksman", "sniper", "shotgun", "drum_shotgun",
]
## Automatics and the starting sidearm: none may kill a fresh player with one round anywhere.
const NO_ONE_SHOT: PackedStringArray = ["machine_pistol", "smg", "carbine", "rifle", "bullpup", "burst_rifle", "lmg", "minigun", "pistol"]
const BOT_SECONDS := 12.0
const BOT_RANGE := 12.0

const CHECKS := 4
const SECTIONS := 3

var _entered := 0
var _completed := 0
var _game: ArenaGame = null
var _hits: Array[DotDamage] = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact headless hit zones and bot fairness")
	ArenaBots.think_every = 1
	ArenaBots.think_near = 0.0
	await _boot()
	await _table()
	await _bots()
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


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
	map.id = &"hitzone_lane"
	map.display_name = "hitzone_lane"
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
	_game.combat.damage_applied.connect(func(d: DotDamage) -> void:
		if d.victim == TARGET:
			_hits.append(d))
	await get_tree().physics_frame


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


static func angles_to(from: Vector3, to: Vector3) -> Vector2:
	var d := (to - from).normalized()
	return Vector2(rad_to_deg(atan2(-d.x, -d.z)), rad_to_deg(asin(d.y)))


## Both whole (health and armour as a spawn gives them), [param dist] metres apart along -Z.
func _place(dist: float, weapon: StringName = &"") -> void:
	var tick: int = _game.current_tick()
	var shooter: ArenaPlayer = _game.player_for(ATTACKER)
	var target: ArenaPlayer = _game.player_for(TARGET)
	shooter.spawn(Transform3D(Basis(), Vector3(-10.0, 0.05, -20.0)), tick)
	target.spawn(Transform3D(Basis(), Vector3(-10.0, 0.05, -20.0 - dist)), tick)
	if weapon == &"":
		shooter.give_default_loadout()
	else:
		shooter.arsenal.clear()
		var _given := shooter.arsenal.give(weapon)
		shooter.hold(shooter.arsenal.catalogue.get_def(weapon).slot)
	shooter.arsenal.disabled = false
	for _i in 48:
		_game.tick({})


func _aim_at(height: float, press: bool) -> Array:
	var shooter: ArenaPlayer = _game.player_for(ATTACKER)
	var target: ArenaPlayer = _game.player_for(TARGET)
	var k := ArenaPlayerTunables.body_scale()
	var aim := angles_to(shooter.muzzle_position(), target.global_position + Vector3.UP * height * k)
	var m := DotFpsCommand.new()
	m.yaw = aim.x
	m.pitch = aim.y
	var w := DotWeaponCommand.new()
	w.buttons = DotWeaponCommand.BUTTON_ATTACK if press else 0
	return [m, w]


## One trigger pull at [param zone] of a target that cannot die (so a lethal round does not respawn it), wearing
## [param armour] (a spawn wears none; armour comes from a loadout item or a streak); the damage events it caused.
func _one_round(weapon: StringName, zone: String, dist: float, armour: float) -> Array[DotDamage]:
	_place(dist, weapon)
	var health: DotHealth = _game.combat.health_of(TARGET)
	health.health = 1.0e7
	health.armour = 0.0
	health.max_armour = maxf(health.max_armour, armour)
	var _worn := health.add_armour(armour)
	for _i in 4:
		_game.tick({ATTACKER: _aim_at(ZONES[zone], false)})
	_hits.clear()
	_game.tick({ATTACKER: _aim_at(ZONES[zone], true)})
	for _i in 3:
		_game.tick({ATTACKER: _aim_at(ZONES[zone], false)})
	await get_tree().physics_frame
	var out: Array[DotDamage] = []
	out.assign(_hits)
	return out


## The most health one round took (a shotgun's pellets on one tick are one round, a burst's rounds are not).
static func round_loss(got: Array[DotDamage]) -> float:
	var by_tick := {}
	for d in got:
		by_tick[d.tick] = by_tick.get(d.tick, 0.0) + d.health_lost
	var most := 0.0
	for t: int in by_tick:
		most = maxf(most, by_tick[t])
	return most


func _table() -> void:
	_place(10.0)
	var target: ArenaPlayer = _game.player_for(TARGET)
	var spawn_health: float = target.health.health
	print("")
	print("    a spawn: health %.0f armour %.0f (max %.0f), head x%.2f neck x%.2f" % [
		spawn_health, target.health.armour, target.health.max_armour, _head_mult(),
		_game.combat.resolver.hit_groups.multiplier(DotHitGroup.NECK)])
	for armour in [0.0, 100.0]:
		_section("one round of every firearm at 10 m, armour %.0f: raw / health lost / zone (! = one round kills)" % armour)
		var dead_in_one := PackedStringArray()
		var header := "    %-15s" % "weapon"
		for zone: String in ZONES:
			header += " %-17s" % zone
		print(header)
		for id in FIREARMS:
			var line := "    %-15s" % id
			for zone: String in ZONES:
				var got: Array[DotDamage] = await _one_round(StringName(id), zone, 10.0, armour)
				var amount := 0.0
				var group := "-"
				for d in got:
					amount += d.amount
					group = String(d.hit_group)
				var lost := round_loss(got)
				var lethal := lost >= spawn_health
				line += " %-17s" % ("%.0f/%.0f/%s%s" % [amount, lost, group, "!" if lethal else ""])
				if lethal and NO_ONE_SHOT.has(id):
					dead_in_one.append("%s@%s" % [id, zone])
			print(line)
		_check(dead_in_one.is_empty(), "no automatic or the pistol kills with one round (armour %.0f)" % armour, ",".join(dead_in_one))
		_completed += 1


func _head_mult() -> float:
	return _game.combat.resolver.hit_groups.multiplier(DotHitGroup.HEAD)


## The real brain at each difficulty, with the rifle, against a still and a strafing target: the share of rounds
## that land, of those in the head, and the damage rate while the trigger is down.
func _bots() -> void:
	_section("bots by difficulty: rifle at %.0f m, %.0f s each" % [BOT_RANGE, BOT_SECONDS])
	var settings := DotBotSettings.of(_game)
	var shares := PackedFloat32Array()
	for preset: String in DotBotProfile.PRESETS:
		shares.append(float(ArenaBots.RECOIL_CONTROL.get(preset, -1.0)))
	var rising := true
	for i in range(1, shares.size()):
		rising = rising and shares[i] > shares[i - 1] and shares[i] < 1.0
	_check(rising, "bots hold recoil better as difficulty rises, and none perfectly", str(shares))
	for preset: String in DotBotProfile.PRESETS:
		for strafing in [false, true]:
			var _set := settings.set_difficulty(preset)
			var mind := ArenaBots.Mind.new()
			mind.seed = 7
			_place(BOT_RANGE)
			var bot: ArenaPlayer = _game.player_for(ATTACKER)
			_game.shot_stats.reset()
			_hits.clear()
			var ticks := int(BOT_SECONDS * TICK_RATE)
			for i in ticks:
				var tick: int = _game.current_tick()
				var m := DotFpsCommand.new()
				if strafing:
					m.move = Vector2(1.0 if (i / 24) % 2 == 0 else -1.0, 0.0)
				_game.tick({ATTACKER: ArenaBots.think(_game, bot, mind, tick, float(TICK_RATE)), TARGET: [m, DotWeaponCommand.new()]})
				_game.combat.health_of(TARGET).health = 1.0e7
				if i % 16 == 0:
					await get_tree().physics_frame
			var t: Dictionary = _game.shot_stats.total([ATTACKER])
			var heads := 0
			var dealt := 0.0
			for d in _hits:
				dealt += d.amount
				if d.is_headshot():
					heads += 1
			var fired := maxi(int(t["fired"]), 1)
			print("    %-9s %-9s fired %4d landed %5.1f%% head %5.1f%% of hits, raw %.0f/s" % [
				preset, "strafing" if strafing else "still", fired, 100.0 * _hits.size() / fired,
				100.0 * heads / maxf(_hits.size(), 1.0), dealt / BOT_SECONDS])
	var _back := settings.set_difficulty(DotBotProfile.DEFAULT_PRESET)
	_completed += 1
