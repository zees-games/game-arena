extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

## Server-side hit accuracy against a moving, animated target, by body region.
##
## A target strafes (or stands, or crouches) 25 m from a still shooter. Every tick the target's drawn
## pose is recorded: the global position of its skeleton's bones (Head, Torso, Hips, Foot) when the
## figure built, else the standing zone heights scaled by the crouch. Then a synthetic shot is
## resolved exactly as ArenaGame.tick does for a fired weapon -- `_resolve_shot(shot, tick - lag)` --
## aimed at where the bone WAS `lag` ticks ago (what the shooter's screen showed). With a correct rewind
## and hit zones that match the drawn body every one of them hits; the table lists misses by region.
##
## [codeblock]
## godot --headless --path . res://examples/headless_hitbox.tscn
## [/codeblock]

const TICK_RATE := 64
const DIST := 25.0
const LAGS := [0.0, 6.0, 12.5, 25.0]
const REGIONS := ["head", "chest", "pelvis", "foot"]
const SHOTS_PER_CELL := 12
## Fraction of shots allowed to miss; the printed table is the real report.
const MAX_MISS := 0.0

var _game: ArenaGame = null
var _checks := 0
var _failed := 0
var _pose_source := "zones"
var _hist: Array = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	Engine.physics_ticks_per_second = TICK_RATE
	_run.call_deferred()


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
	map.id = &"hitbox_lane"
	map.display_name = "hitbox_lane"
	map.extent = 150.0
	map.wall_height = 8.0
	var _p := map.add_perimeter()
	var _s1 := map.add_spawn(Transform3D(Basis(), Vector3(0.0, 0.05, 0.0)))
	var _s2 := map.add_spawn(Transform3D(Basis(), Vector3(5.0, 0.05, 0.0)))
	var ready := _game.setup(map)
	_ok(ready.ok, "the arena sets up")
	_game.match_node.rules.warmup_sec = 0.0
	_game.match_node.rules.countdown_sec = 0.0
	var _a := _game.add_player(1, "Shooter")
	var _b := _game.add_player(2, "Target")
	_game.start(0)
	_game.tick({})
	_game.combat.config.shots_per_second = 1000.0
	await get_tree().physics_frame


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_failed += 1
	print("  [%s] %s" % ["ok" if cond else "FAIL", what])


## Where the drawn body's regions are right now (world space).
func _pose(target: ArenaPlayer) -> Dictionary:
	var base: Vector3 = target.global_position
	var fig: Node = target.figure
	if fig != null and fig.has_method(&"skeleton") and fig.skeleton() != null:
		var sk: Skeleton3D = fig.skeleton()
		var names := {"head": "Head", "chest": "Torso", "pelvis": "Hips", "foot": "Foot.L"}
		var out := {}
		for r in names:
			var i := sk.find_bone(names[r])
			if i < 0:
				out.clear()
				break
			out[r] = sk.global_transform * sk.get_bone_global_pose(i).origin
		if not out.is_empty():
			_pose_source = "skeleton"
			return out
	var k: float = 1.0 - 0.25 * target.controller.state.crouch_fraction
	return {
		"head": base + Vector3(0, 1.62 * k, 0), "chest": base + Vector3(0, 1.2 * k, 0),
		"pelvis": base + Vector3(0, 0.9 * k, 0), "foot": base + Vector3(0, 0.1, 0),
	}


func _step(target_move: Vector2, crouch: bool) -> void:
	var m1 := DotFpsCommand.new()
	var w1 := DotWeaponCommand.new()
	var m2 := DotFpsCommand.new()
	m2.move = target_move
	m2.buttons = DotFpsCommand.BUTTON_CROUCH if crouch else 0
	m2.yaw = 90.0
	var w2 := DotWeaponCommand.new()
	_game.tick({1: [m1, w1], 2: [m2, w2]})
	await get_tree().physics_frame
	_hist.append(_pose(_game.player_for(2)))


func _fire(at: Vector3, lag: float) -> Dictionary:
	var shooter = _game.player_for(1)
	var shot := DotShot.make(&"hitbox_probe", 1, _game._tick, 0)
	shot.origin = shooter.muzzle_position()
	shot.direction = (at - shot.origin).normalized()
	shot.pellets = [shot.direction]
	shot.pellet_count = 1
	shot.damage = 1.0
	shot.max_range = 200.0
	shot.damage_type = DotDamageType.new()
	_game._unlag_shooter = 1
	_game._resolve_shot(shot, float(_game._tick) - lag if lag >= 0.0 else -1.0)
	for d in shot.damages:
		if d.victim == 2:
			return {"hit": true, "group": String(d.hit_group)}
	return {"hit": false, "group": ""}


func _cell(label: String, stance_crouch: bool, moving: bool, table: Dictionary) -> void:
	var shooter = _game.player_for(1)
	var victim = _game.player_for(2)
	var t: int = _game._tick
	shooter.spawn(Transform3D(Basis(), Vector3(0.0, 0.05, 0.0)), t)
	victim.spawn(Transform3D(Basis(), Vector3(0.0, 0.05, -DIST)), t)
	_game.combat.health_of(2).health = 1.0e7
	_hist.clear()
	var dir := 1.0
	for i in 40:
		await _step(Vector2(dir, 0) if moving else Vector2.ZERO, stance_crouch)
	var cf: float = victim.controller.state.crouch_fraction
	print("%s: crouch_fraction %.2f, head at %.2f m" % [label, cf, (_hist[-1]["head"] as Vector3).y - victim.global_position.y])
	_ok(cf > 0.9 if stance_crouch else cf < 0.1, "%s: the target is in the stance asked for" % label)
	for lag in LAGS:
		for n in SHOTS_PER_CELL:
			if moving and n % 4 == 0:
				dir = -dir
			for _j in 3:
				await _step(Vector2(dir, 0) if moving else Vector2.ZERO, stance_crouch)
			var now_idx := _hist.size() - 1
			var then_pos: float = float(now_idx) - lag
			var lo := floori(then_pos)
			var frac := then_pos - float(lo)
			var a: Dictionary = _hist[lo]
			var b: Dictionary = _hist[mini(lo + 1, now_idx)]
			for region in REGIONS:
				var aim: Vector3 = (a[region] as Vector3).lerp(b[region], frac)
				var res := _fire(aim, lag)
				var key := "%s|%s|lag%.1f" % [label, region, lag]
				var row: Dictionary = table.get(key, {"n": 0, "hit": 0, "groups": {}})
				row.n += 1
				if res.hit:
					row.hit += 1
					row.groups[res.group] = int(row.groups.get(res.group, 0)) + 1
				table[key] = row


func _run() -> void:
	await _boot()
	var table := {}
	await _cell("stand-still", false, false, table)
	await _cell("stand-strafe", false, true, table)
	await _cell("crouch-still", true, false, table)
	await _cell("crouch-strafe", true, true, table)
	print("pose source: %s" % _pose_source)
	var by_region := {}
	var total := 0
	var misses := 0
	for key in table:
		var row: Dictionary = table[key]
		var parts: PackedStringArray = key.split("|")
		# A hit on the wrong zone (a drawn head that lands on the chest) is a miss too.
		var miss: int = row.n - int(row.groups.get(_expect(parts[1]), 0))
		total += row.n
		misses += miss
		by_region[parts[1]] = int(by_region.get(parts[1], 0)) + miss
		if miss > 0:
			print("  %-34s %2d/%2d hit  groups %s" % [key, row.hit, row.n, row.groups])
	print("misses by region: %s  (%d of %d shots)" % [by_region, misses, total])
	_ok(total > 0, "shots were fired")
	_ok(float(misses) / float(maxi(total, 1)) <= MAX_MISS, "every shot at a drawn bone hits (misses %d of %d)" % [misses, total])
	print("%d checks, %d failed" % [_checks, _failed])
	get_tree().quit(0 if _failed == 0 else 1)


func _expect(region: String) -> String:
	return {"head": "head", "chest": "chest", "pelvis": "chest", "foot": "leg"}[region]
