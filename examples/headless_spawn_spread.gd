extends DotGameCheckSuite

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")

## Free-for-all spawns must spread over every eligible point: 32 players respawned many times
## on each map, counted per point.
const PLAYERS := 32
const ROUNDS := 30
const DEFAULT_MAPS: Array[StringName] = [&"crackhouse", &"blackhawkdown", &"dm-morpheus", &"gg-woods", &"dm-overwatch", &"gg-garage", &"aim-forts"]


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact spawn spread")
	var maps: Array[StringName] = []
	for a in OS.get_cmdline_user_args():
		maps.append(StringName(a))
	if maps.is_empty():
		maps = DEFAULT_MAPS
	var ran := 0
	for id in maps:
		if ArenaMap.by_id(id) == null:
			print("skip %s: not linked" % id)
			continue
		await _one(id)
		ran += 1
	_report_sections(maps.size(), ran, maps.size(), ran * 4)


func _one(id: StringName) -> void:
	var game := ArenaGame.new()
	game.tick_rate = 64
	game.score_limit = 100000
	game.time_limit_sec = 0.0
	game.headless = true
	game.is_authority = true
	game.register_service = false
	add_child(game)
	var map := ArenaMap.by_id(id)
	if not game.setup(map).ok:
		_check(false, "%s sets up" % id)
		return
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	for b in PLAYERS:
		var _a := game.add_player(b + 1, "P%d" % b)
	game.player_stack.spawn_settings["mode"] = OS.get_environment("SPAWN_MODE") if OS.get_environment("SPAWN_MODE") != "" else "scatter"
	game.player_stack.refresh_spawn_rules()
	game.start(0)
	game.tick({})
	var first := {}
	for b in PLAYERS:
		var at: Vector3 = game.player_for(b + 1).controller.state.position
		var key := "%.1f,%.1f" % [at.x, at.z]
		first[key] = int(first.get(key, 0)) + 1
	var firsttop := 0
	for k in first:
		firsttop = maxi(firsttop, int(first[k]))
	print("START %s: %d players on %d distinct places, most on one %d" % [id, PLAYERS, first.size(), firsttop])
	_check(first.size() >= mini(PLAYERS, map.spawns.size()) * 2 / 3, "%s: the start places spread" % id, "%d places" % first.size())
	var counts := {}
	var total := 0
	var dupes := 0
	var stacked := 0
	var fell := 0
	for r in ROUNDS:
		var batch := {}
		for b in PLAYERS:
			var _r := game.respawn_player(b + 1)
			var ch: DotSpawnChoice = game.player_stack.spawns.last_choice()
			if ch == null:
				continue
			var sid := String(ch.site_id())
			counts[sid] = int(counts.get(sid, 0)) + 1
			total += 1
			if ch.fell_back:
				fell += 1
			var me: Vector3 = game.player_for(b + 1).controller.state.position
			for o in PLAYERS:
				if o != b and game.player_for(o + 1).controller.state.position.distance_to(me) < 1.0:
					stacked += 1
					break
			if batch.has(sid):
				dupes += 1
			batch[sid] = true
		game.tick({})
	var points: int = game.player_stack.spawns.sites().size()
	var top := 0
	var topid := ""
	for k in counts:
		if int(counts[k]) > top:
			top = int(counts[k])
			topid = k
	var share := float(top) / maxf(total, 1)
	print("MAP %s: tags %s; points %d, used %d, top %s %.1f%%, stacked %d, repeats %d, fallbacks %d" % [id,
		Array(map.spawn_tags).count(""), points, counts.size(), topid, share * 100.0, stacked, dupes, fell])
	_check(share <= maxf(0.12, 3.0 / maxf(points, 1)), "%s: no point over its share" % id, "%s %.1f%%" % [topid, share * 100.0])
	_check(counts.size() >= int(points * 0.9), "%s: nearly every point used" % id, "%d of %d" % [counts.size(), points])
	_check_apart(game, id, dupes, total)

## Points at least 2 m apart decide how strict the repeat check is.
func _check_apart(game: ArenaGame, id: StringName, dupes: int, total: int) -> void:
	var apart: Array[Vector3] = []
	for site in game.player_stack.spawns.sites():
		var clear := true
		for q in apart:
			if q.distance_to(site.position) < 2.0:
				clear = false
				break
		if clear:
			apart.append(site.position)
	print("MAP %s: %d points are 2 m or more apart" % [id, apart.size()])
	if apart.size() >= PLAYERS * 3 / 2:
		_check(dupes == 0, "%s: no point drawn twice in one batch" % id, "%d of %d" % [dupes, total])
	else:
		_check(dupes <= total * 3 / 4, "%s: fewer points than players, repeats are bounded" % id, "%d of %d" % [dupes, total])

