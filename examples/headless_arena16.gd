extends DotGameCheckSuite

const ArenaBots := preload("../game/arena_bots.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaImportedMaps := preload("../maps/arena_imported_maps.gd")
const ArenaTickBudget := preload("../game/arena_tick_budget.gd")

## 16v16 sanity on cp-orange-x3 (dm_box when unlinked): 31 bots and a still human, driven from _physics_process like the client (ArenaTickBudget caps the catch-up), check that time keeps up, the bots hit the human at a plausible rate and CTF has two flags.
## Run: [code]./game.sh test headless_arena16 [-- SECONDS][/code]

const MAP := &"cp-orange-x3"
var TICK_RATE := int(Engine.physics_ticks_per_second)
const PER_SIDE := 16
const HUMAN := 1000
const DEFAULT_SECONDS := 60.0

var _seconds := DEFAULT_SECONDS


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	for a in OS.get_cmdline_user_args():
		if a.is_valid_float():
			_seconds = a.to_float()
	_run.call_deferred()


func _map() -> ArenaMap:
	if ArenaImportedMaps.has(MAP):
		return ArenaMap.by_id(MAP)
	print("  %s is not linked: using dm_box" % MAP)
	return ArenaMap.dm_box()


func _new_game(mode: ArenaMode) -> ArenaGame:
	var game := ArenaGame.new()
	game.tick_rate = TICK_RATE
	game.score_limit = 100000
	game.time_limit_sec = 0.0
	game.headless = true
	game.is_authority = true
	game.register_service = false
	game.mode = mode
	add_child(game)
	if not game.setup(_map()).ok:
		return null
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	game.freeze_sec = 0.0
	return game


func _run() -> void:
	print("game-arena: 16v16 sanity (%s)" % ("cp-orange-x3" if ArenaImportedMaps.has(MAP) else "dm_box"))
	print("")
	if not await _team_match():
		_report_sections(1, 0, 2, -1)
		return
	_ctf()


## The 16v16 team match; false when it did not set up.
func _team_match() -> bool:
	print("-- 16v16 team match, 31 bots and a still human, %.0f s" % _seconds)
	var game := _new_game(ArenaMode.team_deathmatch(100000))
	_check(game != null, "the 16v16 game sets up")
	if game == null:
		return false
	var minds := {}
	for i in PER_SIDE * 2 - 1:
		var id := i + 1
		var _a := game.add_player(id, "Bot%d" % id)
		var m := ArenaBots.Mind.new()
		m.seed = 7 + id
		minds[id] = m
	var _h := game.add_player(HUMAN, "Human")
	game.start(0)
	var _r := game.respawn_player(HUMAN)
	game.tick({})
	var red := 0
	var blue := 0
	for p in game.players():
		if game.team_of(p.player_id) == game.team_of(HUMAN):
			red += 1
		else:
			blue += 1
	_check(red == PER_SIDE and blue == PER_SIDE, "16 on each side (%d vs %d)" % [red, blue])

	# Left on his own spawn the human is out of every enemy's reach on this large map: put him on an enemy's.
	var enemy: Object = null
	for p in game.players():
		if game.team_of(p.player_id) != game.team_of(HUMAN):
			enemy = p
			break
	game.player_for(HUMAN).controller.state.position = enemy.controller.state.position
	game.player_for(HUMAN).controller.state.velocity = Vector3.ZERO

	var world := ArenaBots.world_for(game)
	var _first := world.route(Vector3.ZERO, Vector3.ONE)
	var warm := 0
	while world.is_route_pending() and warm < 2400:
		await get_tree().process_frame
		warm += 1

	var hits := {"n": 0, "dmg": 0.0, "all_n": 0, "all_dmg": 0.0, "kills": 0}
	game.player_killed.connect(func(_entry: DotKillFeed.Entry) -> void:
		hits["kills"] += 1)
	game.hit_confirmed.connect(func(_att: int, victim: int, amount: float, _pt: Vector3, _hs: bool, _lethal: bool) -> void:
		hits["all_n"] += 1
		hits["all_dmg"] += amount
		if victim == HUMAN:
			hits["n"] += 1
			hits["dmg"] += amount)

	var driver := await _drive(game, minds)
	_report_hits(hits, driver)
	driver.queue_free()
	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
	return true


## Drives the match for `_seconds` of game time, checks the catch-up and returns the driver.
func _drive(game: ArenaGame, minds: Dictionary) -> _Driver:
	var driver := _Driver.new()
	driver.game = game
	driver.minds = minds
	driver.human = HUMAN
	driver.human_team = game.team_of(HUMAN)
	driver.target_ticks = int(_seconds * TICK_RATE)
	add_child(driver)
	var t0 := Time.get_ticks_usec()
	while not driver.done:
		await get_tree().process_frame
		driver.frames += 1
	var wall := float(Time.get_ticks_usec() - t0) / 1000000.0

	var per_frame := float(driver.ticks) / float(maxi(driver.frames, 1))
	var speed := float(driver.ticks) / float(TICK_RATE) / wall
	var tick_ms := driver.tick_usec / float(maxi(driver.ticks, 1)) / 1000.0
	print("  NUMBERS physics ticks %d over %d frames: %.3f ticks/frame; %.1f s simulated in %.1f s wall (x%.2f); tick %.2f ms avg, %.2f ms max; cap now %d" % [
		driver.ticks, driver.frames, per_frame, float(driver.ticks) / TICK_RATE, wall, speed, tick_ms, driver.max_tick_usec / 1000.0, Engine.max_physics_steps_per_frame])
	# A tick dearer than its period (PH's slow thread: 29 ms at 66 Hz) cannot keep up, and ArenaTickBudget
	# then runs its floor of 2 steps a frame by design; both checks hold only where the tick fits.
	var dear := tick_ms * TICK_RATE / 1000.0 > 0.9
	_check(per_frame <= 1.0 + 0.02 or dear, "the physics catch-up averages at most 1 tick per frame (or the tick itself is too dear)", "%.3f" % per_frame)
	_check(speed >= 0.9 or dear,
		"the simulation keeps wall-clock time (or the tick itself is too dear)", "x%.2f at %.2f ms/tick" % [speed, tick_ms])
	return driver


func _report_hits(hits: Dictionary, driver: _Driver) -> void:
	var rate := float(hits["dmg"]) / _seconds
	print("  NUMBERS bot hits on the still human: %d hits, %.0f damage, %.1f hp/s, %d deaths, %d respawns" % [
		hits["n"], hits["dmg"], rate, driver.human_deaths, driver.human_deaths])
	print("  NUMBERS all hits (any victim): %d hits, %.0f damage, %.1f hp/s, %d kills; closest an enemy bot got to the human: %.1f m" % [
		hits["all_n"], hits["all_dmg"], float(hits["all_dmg"]) / _seconds, hits["kills"], driver.closest])
	_check(hits["all_n"] >= 1, "the bots hurt each other (hit registration works at all)", "%d hits" % hits["all_n"])
	_check(hits["n"] >= 1, "the bots hit the stationary human at least once", "%d hits" % hits["n"])
	_check(rate <= 400.0, "and not at an aimbot rate", "%.1f hp/s" % rate)


func _ctf() -> void:
	print("")
	print("-- capture the flag on %s" % MAP)
	if not ArenaImportedMaps.has(MAP):
		print("  skipped: %s is not linked" % MAP)
		_report_sections(2, 2, 2, -1)
		return
	var ctf := _new_game(ArenaMode.capture_the_flag(3))
	_check(ctf != null and ctf.objectives != null, "capture the flag sets up on %s" % MAP)
	if ctf != null and ctf.objectives != null:
		var flags := ctf.objectives.manager.objectives.flags()
		_check(flags.size() == 2, "two flags exist", "%d" % flags.size())
	if ctf != null:
		remove_child(ctf)
		ctf.queue_free()
	_report_sections(2, 2, 2, -1)


## Runs the bots and the game from _physics_process, like the client, until `target_ticks` ran.
class _Driver extends Node:
	var game: ArenaGame = null
	var minds := {}
	var human := 0
	var target_ticks := 0
	var ticks := 0
	var frames := 0
	var tick_usec := 0
	var max_tick_usec := 0
	var human_deaths := 0
	var closest := INF
	var human_team := -1
	var done := false
	var _budget := ArenaTickBudget.new()
	var _tick := 1000
	var _cmds := {}

	func _physics_process(_delta: float) -> void:
		if done:
			return
		var t := Time.get_ticks_usec()
		var cmds := _cmds
		cmds.clear()
		for id in minds:
			var p: Object = game.player_for(id)
			if p != null:
				cmds[id] = ArenaBots.think(game, p, minds[id], _tick, float(Engine.physics_ticks_per_second))
		game.tick(cmds)
		_tick += 1
		var hp: Object = game.player_for(human)
		if hp != null and not hp.is_alive():
			human_deaths += 1
			var _r := game.respawn_player(human)
		var cost := Time.get_ticks_usec() - t
		tick_usec += cost
		max_tick_usec = maxi(max_tick_usec, cost)
		ticks += 1
		if ticks % 16 == 0 and hp != null:
			for id in minds:
				var bp: Object = game.player_for(id)
				if bp != null and bp.is_alive() and game.team_of(id) != human_team:
					closest = minf(closest, bp.controller.state.position.distance_to(hp.controller.state.position))
		Engine.max_physics_steps_per_frame = _budget.steps_for(float(cost) / 1000000.0)
		if ticks >= target_ticks:
			done = true
