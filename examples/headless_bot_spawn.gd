extends DotGameCheckSuite

const ArenaBots := preload("../game/arena_bots.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")

## Bots set loose on each imported map must leave their spawns: no bot may move less than [constant MIN_MOVE] m in [constant SECONDS] s. Prints one line per map.
## Run: [code]./game.sh test headless_bot_spawn[/code], or with map names after [code]--[/code].
const TICK_RATE := 64
const BOTS := 8
const SECONDS := 20.0
const MIN_MOVE := 3.0
const DEFAULT_MAPS: Array[StringName] = [&"crackhouse", &"blackhawkdown", &"dm-morpheus", &"gg-woods", &"dm-overwatch", &"gg-garage", &"aim-forts"]


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena bots leave their spawns")
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
	var start := {}
	var far := {}
	for b in BOTS:
		var m := ArenaBots.Mind.new()
		m.seed = 11 + b
		minds[b + 1] = m
	var tick := 1000
	var nav := world.nav_for_rides()
	for i in int(SECONDS * TICK_RATE):
		var commands := {}
		for b in BOTS:
			var p := game.player_for(b + 1)
			if p != null:
				commands[b + 1] = ArenaBots.think(game, p, minds[b + 1], tick, float(TICK_RATE))
		game.tick(commands)
		tick += 1
		if i == 1:
			for b in BOTS:
				var p := game.player_for(b + 1)
				start[b + 1] = p.controller.state.position
				far[b + 1] = 0.0
		elif i > 1:
			for b in BOTS:
				var p := game.player_for(b + 1)
				if p != null and p.controller.state.position.distance_to(start[b + 1]) > far[b + 1]:
					far[b + 1] = p.controller.state.position.distance_to(start[b + 1])
		if i % 16 == 0:
			await get_tree().physics_frame
	var stuck := 0
	var detail := PackedStringArray()
	for b in BOTS:
		if far[b + 1] < MIN_MOVE:
			stuck += 1
			var sp: Vector3 = start[b + 1]
			var off := nav.closest(sp).distance_to(sp) if nav != null and nav.is_ready() else -1.0
			var linked := 0
			for o in BOTS:
				if o != b and nav != null and nav.joined(sp, start[o + 1]):
					linked += 1
			var brain: DotBotBrain = (minds[b + 1] as ArenaBots.Mind).brain
			var tag := " %s unstick %d" % [str(brain.last.state), brain._unstick.total] if brain != null else ""
			detail.append("%.1f,%.1f,%.1f(nav %.1f, joined to %d of %d others%s)" % [sp.x, sp.y, sp.z, off, linked, BOTS - 1, tag])
	print("MAP %s: stuck %d of %d (moved < %.0f m in %.0f s); nav ready=%s; %s" % [id, stuck, BOTS, MIN_MOVE, SECONDS,
		str(nav != null and nav.is_ready()), " ".join(detail)])
	_check(stuck == 0, "%s: no bot stuck at spawn" % id, "%d of %d" % [stuck, BOTS])
	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
