extends DotGameCheckSuite

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")

## The COUNTDOWN-start bulk spawn: the director's cost per player, and what ArenaGame.respawn_player costs, on the largest map.
const PLAYERS := 11
const BUDGET_MS := 4.0
## The very first respawn pays lazy loadout/resource setup once (5-9 ms on PH 2026-11-11, 12-20 ms on 2026-11-07); budget is one 60 fps frame.
const FIRST_BUDGET_MS := 16.0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact spawn cost")
	var maps: Array[StringName] = []
	for a in OS.get_cmdline_user_args():
		maps.append(StringName(a))
	if maps.is_empty():
		maps = [&"crackhouse", &"dm-overwatch"]
	var ran := 0
	for id in maps:
		if ArenaMap.by_id(id) == null:
			print("skip %s: not linked" % id)
			continue
		await _one(id)
		ran += 1
	_report_sections(maps.size(), ran, maps.size(), ran * 3)


func _one(id: StringName) -> void:
	var game := ArenaGame.new()
	game.tick_rate = 64
	game.score_limit = 100000
	game.time_limit_sec = 0.0
	game.headless = true
	game.is_authority = true
	game.register_service = false
	add_child(game)
	if not game.setup(ArenaMap.by_id(id)).ok:
		_check(false, "%s sets up" % id)
		return
	for b in PLAYERS:
		var _a := game.add_player(b + 1, "P%d" % b)
	game.player_stack.refresh_spawn_rules()
	game.start(0)
	game.tick({})
	var worst_choose := 0.0
	var sum_choose := 0.0
	var worst_respawn := 0.0
	var first_respawn := 0.0
	for r in 5:
		var t_batch := Time.get_ticks_usec()
		for b in PLAYERS:
			var t0 := Time.get_ticks_usec()
			var _c := game.player_stack.choose_spawn(b + 1)
			var ms := (Time.get_ticks_usec() - t0) / 1000.0
			worst_choose = maxf(worst_choose, ms)
			sum_choose += ms
		for b in PLAYERS:
			var t0 := Time.get_ticks_usec()
			var _r := game.respawn_player(b + 1)
			var rms := (Time.get_ticks_usec() - t0) / 1000.0
			if r == 0 and b == 0:
				first_respawn = rms
			else:
				worst_respawn = maxf(worst_respawn, rms)
		game.tick({})
		var _tb := t_batch
	var mean := sum_choose / float(PLAYERS * 5)
	print("COST %s: choose_spawn mean %.2f ms worst %.2f ms; respawn_player first %.2f ms, then worst %.2f ms (sites %d)" % [id, mean, worst_choose, first_respawn, worst_respawn, game.player_stack.spawns.sites().size()])
	_check(mean <= BUDGET_MS, "%s: choose_spawn mean under %.0f ms" % [id, BUDGET_MS], "%.2f ms" % mean)
	_check(first_respawn <= FIRST_BUDGET_MS, "%s: first respawn_player under %.0f ms" % [id, FIRST_BUDGET_MS], "first %.2f ms" % first_respawn)
	_check(worst_respawn <= BUDGET_MS * 4.0, "%s: respawn_player worst under %.0f ms" % [id, BUDGET_MS * 4.0], "%.2f ms" % worst_respawn)
	game.queue_free()
