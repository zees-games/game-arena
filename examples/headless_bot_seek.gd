extends DotGameCheckSuite

const ArenaBots := preload("../game/arena_bots.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")

## Bots roaming an imported map must find a player who stands still: some bot must come within
## [constant REACH] m of the player inside [constant SECONDS] s. Prints the time per map.
##
## [codeblock]
## ./game.sh test headless_bot_seek            # the default maps
## godot --headless --path . res://examples/headless_bot_seek.tscn -- crackhouse gg-woods
## [/codeblock]
const TICK_RATE := 64
const BOTS := 4
const SECONDS := 120.0
const REACH := 8.0
const PLAYER := 100
const DEFAULT_MAPS: Array[StringName] = [&"crackhouse", &"dm-morpheus", &"gg-woods", &"dm-overwatch", &"gg-garage", &"aim-forts"]


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena bots find a player")
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
	_report_sections(maps.size(), ran, maps.size(), maps.size())


func _one(id: StringName) -> void:
	var game := ArenaGame.new()
	game.tick_rate = TICK_RATE
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
	for b in BOTS:
		var _a := game.add_player(b + 1, "Bot%d" % b)
	var _h := game.add_player(PLAYER, "Human")
	game.start(0)
	game.tick({})
	await get_tree().process_frame
	var world := ArenaBots.world_for(game)
	var _first := world.route(Vector3.ZERO, Vector3.ONE)
	var frames := 0
	while world.is_route_pending() and frames < 2400:
		await get_tree().process_frame
		frames += 1
	var minds := {}
	for b in BOTS:
		var m := ArenaBots.Mind.new()
		m.seed = 11 + b
		minds[b + 1] = m
	var tick := 1000
	var found := -1.0
	var human := game.player_for(PLAYER)
	var best := INF
	var first := -1.0
	for i in int(SECONDS * TICK_RATE):
		var commands := {}
		for b in BOTS:
			var p := game.player_for(b + 1)
			if p != null:
				commands[b + 1] = ArenaBots.think(game, p, minds[b + 1], tick, float(TICK_RATE))
		game.tick(commands)
		tick += 1
		if i % 16 == 0:
			for b in BOTS:
				var p := game.player_for(b + 1)
				if p != null and human != null:
					var d := p.controller.state.position.distance_to(human.controller.state.position)
					best = minf(best, d)
					if first < 0.0:
						first = best
					if d <= REACH and found < 0.0:
						found = float(i) / TICK_RATE
			if found >= 0.0:
				break
			await get_tree().physics_frame
	print("MAP %s: start gap %.1f m; nearest bot %.1f m; reached within %.0f m after %s s" % [id, first, best, REACH, "%.1f" % found if found >= 0.0 else "never"])
	_check(found >= 0.0, "%s: a bot reaches the player" % id, "nearest %.1f m in %.0f s" % [best, SECONDS])
	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
