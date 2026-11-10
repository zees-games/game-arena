extends DotGameCheckSuite

const ArenaBots := preload("../game/arena_bots.gd")
const ArenaBotThreads := preload("../game/arena_bot_threads.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")

## `bot_threads`: the bots' brains on worker threads play exactly what they play on one. The same
## 24 bots on dm_box play a deathmatch at threads 0, 0 again, 1, 4 and 8; every bot's position,
## view, health and commands, hashed every few ticks, are identical in all of them.

const TICK_RATE := 33
const BOTS := 24
const SECONDS := 20.0
const THREADS := [0, 0, 1, 4, 8]

const SECTIONS := 3
const CHECKS := 13

## An imported map, whose sight is the physics space's (dm_box's is analytic) and whose routes come from a baked mesh.
const IMPORTED_MAP := &"dm-morpheus"
const IMPORTED_BOTS := 16
const IMPORTED_SECONDS := 10.0

var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena: bot_threads plays the same match")
	# 24 bots and no person would coast on think tiers, leaving fewer thinkers a tick than the pool starts for.
	ArenaBots.tiers.above = -1
	_section("the same match at every thread count")
	var digests: Array[PackedStringArray] = []
	var kills: Array[int] = []
	var parallel: Array[int] = []
	for count: int in THREADS:
		var played := await _play(count)
		digests.append(played[0])
		kills.append(played[1])
		parallel.append(played[2])
	_check(digests[0].size() > 10 and kills[0] >= 0, "the match was played (%d digests, %d kills)" % [digests[0].size(), kills[0]])
	_check(digests[0] == digests[1], "two runs on one thread are identical (the match is deterministic)")
	for i in range(2, THREADS.size()):
		_check(digests[i] == digests[0], "bot_threads %d plays the match thread 0 plays (%d kills)" % [THREADS[i], kills[i]])
	_check(parallel[2] > 100 and parallel[3] > 100 and parallel[4] > 100, "the brains really ran through the parallel path (%d, %d, %d ticks)" % [parallel[2], parallel[3], parallel[4]])
	_check(parallel[0] == 0, "and bot_threads 0 never did")
	_done()

	_section("an imported map, sight through the physics space")
	if ArenaMap.by_id(IMPORTED_MAP) == null:
		print("skip %s: not linked" % IMPORTED_MAP)
		_check(true, "(skipped: no imported map linked)")
		_check(true, "(skipped: no imported map linked)")
	else:
		var off := await _play(0, IMPORTED_MAP)
		var off_again := await _play(0, IMPORTED_MAP)
		var on := await _play(4, IMPORTED_MAP)
		var first_diff := -1
		for i in mini(off[0].size(), on[0].size()):
			if off[0][i] != on[0][i]:
				first_diff = i
				break
		var first_off_diff := -1
		for i in mini(off[0].size(), off_again[0].size()):
			if off[0][i] != off_again[0][i]:
				first_off_diff = i
				break
		var one := await _play(1, IMPORTED_MAP)
		var first_one_diff := -1
		for i in mini(off[0].size(), one[0].size()):
			if off[0][i] != one[0][i]:
				first_one_diff = i
				break
		print("imported: threads 1 vs off first differing window %d" % first_one_diff)
		print("imported: off vs off-again first differing window %d, off vs on %d (of %d)" % [first_off_diff, first_diff, off[0].size()])
		_check(off[0] == off_again[0], "two runs on one thread are identical on %s too" % IMPORTED_MAP)
		_check(off[0] == on[0] and off[0].size() > 5, "bot_threads 4 plays the %s match thread 0 plays (%d, %d kills)" % [IMPORTED_MAP, off[1], on[1]])
		_check(on[2] > 50 and off[2] == 0, "through the parallel path (%d ticks)" % on[2])
	_done()

	_section("under the minimum, or off, nothing changes")
	ArenaBotThreads.threads = 4
	_check(not ArenaBotThreads.active(ArenaBotThreads.MIN_BOTS - 1), "fewer bots than the minimum think on the main thread")
	_check(ArenaBotThreads.active(ArenaBotThreads.MIN_BOTS), "the minimum goes parallel")
	ArenaBotThreads.threads = 0
	_check(not ArenaBotThreads.active(64), "bot_threads 0 is off at any count")
	_done()
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


## One match with [param count] threads: [digests, kills, parallel ticks].
func _play(count: int, map_id: StringName = &"") -> Array:
	ArenaBotThreads.threads = count
	ArenaBotThreads.par_ticks = 0
	var game := ArenaGame.new()
	game.name = "Arena_%d" % count
	game.tick_rate = TICK_RATE
	game.score_limit = 100000
	game.time_limit_sec = 0.0
	game.headless = true
	game.is_authority = true
	game.register_service = false
	add_child(game)
	var _setup := game.setup(ArenaMap.dm_box() if map_id == &"" else ArenaMap.by_id(map_id))
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	game.match_node.rules.respawn_delay_sec = 1.0
	var kills := [0]
	game.player_killed.connect(func(_entry: DotKillFeed.Entry) -> void: kills[0] += 1)
	var players: Array = []
	var minds: Array = []
	for i in BOTS if map_id == &"" else IMPORTED_BOTS:
		var made := game.add_player(100 + i, "Bot%d" % i)
		if made.ok:
			players.append(made.value)
			var mind := ArenaBots.Mind.new()
			mind.seed = 100 + i
			minds.append(mind)
	game.start(0)
	game.tick({})
	await get_tree().process_frame
	if map_id != &"":
		# The routes start when the mesh bake lands; start every run from there.
		var world := ArenaBots.world_for(game)
		var _first := world.route(Vector3.ZERO, Vector3.ONE)
		var frames := 0
		while world.is_route_pending() and frames < 3000:
			await get_tree().process_frame
			frames += 1
		var _warm := world.warm()
	var digests := PackedStringArray()
	var window := PackedStringArray()
	for tick_index in int((SECONDS if map_id == &"" else IMPORTED_SECONDS) * TICK_RATE):
		var tick := game.current_tick()
		var made: Array = []
		if ArenaBotThreads.active(players.size()):
			made = ArenaBotThreads.think_all(game, players, minds, tick, float(TICK_RATE))
		else:
			for i in players.size():
				made.append(ArenaBots.think(game, players[i], minds[i], tick, float(TICK_RATE)))
		var commands := {}
		for i in players.size():
			var pair: Array = made[i]
			var move: DotFpsCommand = pair[0]
			var fire: DotWeaponCommand = pair[1]
			commands[players[i].player_id] = pair
			window.append("%d:%.4f,%.4f,%d,%d" % [i, move.yaw, move.pitch, move.buttons, fire.buttons])
			var state: DotFpsState = players[i].controller.state if players[i].controller != null else null
			if state != null:
				window.append("%.4f,%.4f,%.4f" % [state.position.x, state.position.y, state.position.z])
		game.tick(commands)
		if tick_index % 10 == 9:
			digests.append(" ".join(window).md5_text())
			window.clear()
		if tick_index % 8 == 0:
			await get_tree().process_frame
	var parallel := ArenaBotThreads.par_ticks
	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
	ArenaBotThreads.threads = 0
	return [digests, kills[0], parallel]
