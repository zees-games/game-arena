extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaBots := preload("../game/arena_bots.gd")
const ArenaDemoStatsScript := preload("../game/arena_demo_stats.gd")
const ArenaPlayerTunables := preload("../game/arena_player_tunables.gd")

## Place and engage recordings and heatmap-weighted roaming: off by default, a bot is never recorded, a player standing and aiming at another becomes a `place` and an `engage` episode, and the bots' waypoints repeat where people stand.
##
## [codeblock]
## godot --headless --path . res://examples/headless_demo_stats.tscn
## [/codeblock]

const TICK_RATE := 64
const EXPECTED_CHECKS := 29

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
	map.id = &"demo_lane"
	map.display_name = "demo_lane"
	map.extent = 150.0
	map.wall_height = 8.0
	var _p := map.add_perimeter()
	# Headless authority only builds ground collision when the map has toys (see _build_toys);
	# one far-off ball gives the lane its floor without touching the shot.
	map.toys = [{"toy": "beach_ball", "at": [100.0, 0.0, 100.0]}]
	var _s1 := map.add_spawn(Transform3D(Basis(), Vector3(0.0, 0.05, 0.0)))
	var _s2 := map.add_spawn(Transform3D(Basis(), Vector3(5.0, 0.05, 0.0)))
	_check(_game.setup(map).ok, "the arena sets up")
	_game.match_node.rules.warmup_sec = 0.0
	_game.match_node.rules.countdown_sec = 0.0
	# The shot comes within the default protection of the first spawn, which would absorb it.
	_game.config.spawn_protection_sec = 0.0
	_game.match_node.rules.spawn_protection_sec = 0.0
	_game.player_stack.refresh_spawn_rules()
	for id in [1, 2, 3]:
		var _a := _game.add_player(id, "P%d" % id)
	_game.player_for(3).set_meta(&"bot", true)
	_game.start(0)
	_game.tick({})
	await get_tree().physics_frame


func _step(buttons: int, yaw: float, pitch: float, who: int = 1) -> void:
	var m := DotFpsCommand.new()
	m.yaw = yaw
	m.pitch = pitch
	var w := DotWeaponCommand.new()
	w.buttons = buttons
	w.yaw = yaw
	w.pitch = pitch
	_game.tick({who: [m, w]})
	await get_tree().physics_frame


static func angles_to(from: Vector3, to: Vector3) -> Vector2:
	var d := (to - from).normalized()
	return Vector2(rad_to_deg(atan2(-d.x, -d.z)), rad_to_deg(asin(d.y)))


func _episodes(store: DotBotDemoStoreMemory, kind: String) -> Array:
	return store.episodes.filter(func(e: DotBotDemoEpisode) -> bool: return e.kind == kind)


func _run() -> void:
	await _boot()
	var config := DotBotDemoConfig.new()
	config.store = "memory"
	config.record = false
	var store := DotBotDemoStoreMemory.new()
	var started := _game.start_demo_stats(config, store)
	_check(started.ok, "demo stats start over a store", str(started.error))
	var stats: RefCounted = _game.demo_stats
	_check(_game.start_demo_stats(config, store).value == stats, "starting twice keeps the first")

	var shooter := _game.player_for(1)
	var victim := _game.player_for(2)
	var tick: int = _game.current_tick()
	shooter.spawn(Transform3D(Basis(), Vector3(-10.0, 0.05, -20.0)), tick)
	victim.spawn(Transform3D(Basis(), Vector3(-30.0, 0.05, -20.0)), tick)
	_game.combat.health_of(2).health = 100000.0
	var _g := shooter.arsenal.give(AwWeaponIds.SNIPER)
	var _sel := shooter.arsenal.select(AwWeaponIds.big_gun_slot(), tick)
	for _i in 20:
		await _step(0, 0.0, 0.0)

	for _i in 10:
		await _step(0, 90.0, 0.0)
	_check(not stats.is_on() and stats.places == 0 and stats.engagements == 0, "nothing is recorded while bot_record is off")

	config.record = true
	stats.place_span = 1.0
	var eye: Vector3 = shooter.muzzle_position()
	# The head, above the chest the recorder measures against, so the first view error is small but not zero.
	var a := angles_to(eye, victim.global_position + Vector3(0.0, 1.62 * ArenaPlayerTunables.body_scale(), 0.0))
	var aim := DotWeaponCommand.BUTTON_USER_0
	for _i in 150:
		await _step(aim, a.x, a.y)
	var hits: Array = []
	_game.hit_confirmed.connect(func(by: int, at: int, _amount: float, _point: Vector3, _head: bool, _lethal: bool) -> void: hits.append("%d>%d" % [by, at]))
	await _step(aim | DotWeaponCommand.BUTTON_ATTACK, a.x, a.y)
	for _i in 12:
		await _step(aim, a.x, a.y)
	# A bot that stands and looks at a player is no subject.
	for _i in 20:
		await _step(0, 0.0, 0.0, 3)
	_check(stats.is_on(), "recording is on once the config says so")
	_check(not stats.recorder.is_recording(Vector2i(3, 0)) and not stats.recorder.is_recording(Vector2i(3, 1)), "a bot is never a subject")
	await stats.recorder.flush_all()

	var places := _episodes(store, "place")
	var engages := _episodes(store, "engage")
	_check(places.size() >= 2, "standing about makes place episodes cut at the span", str(places.size()))
	_check(not places.is_empty() and places[0].key == "all" and places[0].frame_size == 5 and places[0].sample_count() > 0, "a place episode carries position, the fight flag and the speed under its label")
	_check(places.all(func(e: DotBotDemoEpisode) -> bool: return e.map_id == "demo_lane"), "episodes carry the map")
	_check(engages.size() == 1, "one engagement, ended by the hit", "%d stored, hits %s" % [engages.size(), hits])
	var e: DotBotDemoEpisode = engages[0] if not engages.is_empty() else null
	_check(e != null and e.outcome in ["hit", "kill"], "the engagement ends at the first hit", e.outcome if e != null else "")
	var fired_at := -1
	var first_error := -1.0
	if e != null:
		first_error = e.ticks[0]
		for i in e.sample_count():
			if e.ticks[i * e.frame_size + 1] > 0.5:
				fired_at = i
				break
	_check(fired_at > 0, "the shot is in the episode, after the player had the enemy in view", str(fired_at))
	_check(first_error > 0.05 and first_error < 5.0, "the view error off the target is measured in degrees", str(first_error))

	_check(stats.refreshes >= 1, "loading the map reloaded the folds on its own", str(stats.refreshes))
	var before_periodic: int = stats.refreshes
	stats.refresh_interval = 0.05
	stats.process(0.1)
	for _i in 3:
		await get_tree().physics_frame
	_check(stats.refreshes > before_periodic, "the slow timer reloads them again", "%d -> %d" % [before_periodic, stats.refreshes])
	stats.refresh_interval = 600.0

	var folded: DotResult = await stats.refresh()
	_check(folded.ok and stats.stats.episode_count("all") + stats.stats.dropped >= 1, "the aim statistics fold the engagement", str(folded.error))
	_check(stats.heatmap.episode_count() >= 2, "the heatmap folds the place episodes", str(stats.heatmap.episode_count()))

	# Roaming: a point people stand at is repeated.
	var busy := Vector3(0.0, 0.05, 0.0)
	var empty := Vector3(5.0, 0.05, 0.0)
	var world: ArenaBots.World = ArenaBots.world_for(_game)
	var plain := world.waypoints()
	_check(plain.size() == 2 and plain.has(busy) and plain.has(empty), "waypoints are unweighted before the heatmap has enough", str(plain.size()))
	var heat: DotBotDemoHeatmap = stats.heatmap
	for i in 4:
		var ep := DotBotDemoEpisode.new()
		ep.map_id = "demo_lane"
		ep.map_version = heat.map_version
		ep.kind = "place"
		ep.key = "all"
		ep.rate = 1.0
		ep.frame_size = 5
		ep.day = Time.get_date_string_from_system(true)
		for _s in 30:
			ep.ticks.append_array(PackedFloat32Array([busy.x, 0.0, busy.z, 0.0, 0.0]))
		var took := heat.fold(ep)
		if i == 0:
			_check(took, "a synthetic place episode folds")
	var weighted := world.waypoints()
	var at_busy := 0
	for p in weighted:
		if p == busy:
			at_busy += 1
	_check(weighted.size() > plain.size() and at_busy > 1 and weighted.count(empty) == 1, "roaming repeats the busy point and leaves the empty one once", "%d busy of %d" % [at_busy, weighted.size()])

	# Engage detection against synthetic placements of the enemy: the cone (45 degrees), the range (60 m) and the grace out of view (0.5 s).
	var spot := Transform3D(Basis(), Vector3(-30.0, 0.05, -20.0))
	victim.spawn(spot, _game.current_tick())
	for _i in 40:
		await _step(0, 0.0, 0.0)
	_check(not stats._engaged.has(1), "an enemy 90 degrees off the view is not an engagement")
	victim.spawn(Transform3D(Basis(), Vector3(-10.0, 0.05, -90.0)), _game.current_tick())
	for _i in 40:
		await _step(0, 0.0, 0.0)
	_check(not stats._engaged.has(1), "an enemy 70 m away is out of range")
	victim.spawn(Transform3D(Basis(), Vector3(-20.0, 0.05, -37.0)), _game.current_tick())
	for _i in 10:
		await _step(0, 0.0, 0.0)
	_check(stats._engaged.has(1), "an enemy 30 degrees off the view and in range starts one")
	for _i in 20:
		await _step(0, 90.0, 0.0)
	for _i in 5:
		await _step(0, 0.0, 0.0)
	_check(stats._engaged.has(1), "a glance away shorter than the grace keeps it")
	for _i in 45:
		await _step(0, 90.0, 0.0)
	_check(not stats._engaged.has(1), "looking away for longer than the grace ends it")
	await stats.recorder.flush_all()
	_check(_episodes(store, "engage").size() == 1, "an engagement that never reached a hit stores nothing", str(_episodes(store, "engage").size()))

	# The suggestion tool's lines over a store: too few episodes say so, enough print a table.
	var tool_store := DotBotDemoStoreMemory.new()
	var few := await ArenaDemoStatsScript.preset_lines(tool_store, "lane", "1")
	_check(not few.is_empty() and few[few.size() - 1].contains("not enough"), "no recordings print a message", str(few))
	for i in 40:
		var ep := DotBotDemoEpisode.new()
		ep.map_id = "lane"
		ep.map_version = "1"
		ep.kind = "engage"
		ep.key = "all"
		ep.rate = 10.0
		ep.frame_size = 3
		ep.day = Time.get_date_string_from_system(true)
		for f in 20:
			ep.ticks.append_array(PackedFloat32Array([4.0 + i * 0.1, 1.0 if f >= 2 + i % 8 else 0.0, 3.0]))
		var _kept := ep.ticks.size()
		var _added := await tool_store.append([ep])
	var many := await ArenaDemoStatsScript.preset_lines(tool_store, "lane", "1", 10)
	_check(many.size() > 3 and "\n".join(many).contains("aim_error") and "\n".join(many).contains("hard"), "enough recordings print every preset", "\n".join(many))

	var off_game: PackedStringArray = stats.describe_lines()
	_check(off_game.size() >= 2, "it describes itself")
	var ok := _failed == 0 and _checks == EXPECTED_CHECKS
	print("%d checks, %d failed (expected %d)" % [_checks, _failed, EXPECTED_CHECKS])
	_game.demo_stats.call(&"release")
	_game.demo_stats = null
	get_tree().quit(0 if ok else 1)
