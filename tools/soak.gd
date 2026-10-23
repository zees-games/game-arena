extends Node

const ArenaBots := preload("../game/arena_bots.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaStats := preload("../game/arena_stats.gd")

## Bot soak on the real Arena: N bots play a free-for-all on one map for M simulated minutes
## through dot-bot's DotBotSoak, fed by dot-spawn's DotSpawnWatch and the game's kill stats.
##
## [codeblock]
## ./game.sh soak [map] [minutes]
## godot --headless --path . res://tools/soak.tscn -- --map surf_the_flow --bots 8 --minutes 2
## [/codeblock]
##
## Also takes the harness's own flags (--soak-max-stuck-sec and the rest of DotBotSoakConfig).
## Writes .godot/test-logs/soak-<map>.json, prints the SOAK line, exits 1 when the run fails.

const TICK_RATE := 64
const DEFAULT_MAP := &"surf_the_flow"
## Below the harness's 2 minutes of grace for "no kills", short enough for CI.
const DEFAULT_MINUTES := 1.0
const DEFAULT_BOTS := 8
## Never reached: a finished match would rotate the map under the soak.
const SCORE_LIMIT := 1000000

var _game: ArenaGame
var _kills := 0
var _deaths := 0
var _damage := 0.0
var _commands: Dictionary = {}
var _minds: Dictionary = {}
var _tick := 0
## Positions of bots mid-ride: in the air by design, so not off the navigation.
var _riding := {}
## Where a lone player would stand: the first spawn, which every bot must be able to reach.
var _goal := Vector3.ZERO


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--" + name)
	if at >= 0 and at + 1 < args.size():
		return args[at + 1]
	return fallback


func _run() -> void:
	var map_id := StringName(_arg("map", String(DEFAULT_MAP)))
	var map := ArenaMap.by_id(map_id)
	if map == null:
		_fail("unknown map %s (is arena-surf-dm-maps linked?)" % map_id)
		return

	var cfg := DotBotSoakConfig.new()
	cfg.minutes = DEFAULT_MINUTES
	cfg.bots = DEFAULT_BOTS
	cfg.apply_cli()
	cfg.minutes = float(_arg("minutes", str(cfg.minutes)))
	cfg.bots = int(_arg("bots", str(cfg.bots)))

	_game = ArenaGame.new()
	_game.tick_rate = TICK_RATE
	_game.headless = true
	_game.is_authority = true
	_game.register_service = false
	_game.mode = ArenaMode.free_for_all(SCORE_LIMIT)
	_game.score_limit = SCORE_LIMIT
	add_child(_game)
	var res := _game.setup(map)
	if not res.ok:
		_fail("setup: %s" % res.error.message)
		return
	_game.match_node.rules.warmup_sec = 0.0
	_game.match_node.rules.countdown_sec = 0.0
	for i in range(cfg.bots):
		var added := _game.add_player(i + 1, "bot%d" % (i + 1))
		if not added.ok:
			_fail("bot %d: %s" % [i + 1, added.error.message])
			return

	_game.start(0)
	var world := ArenaBots.world_for(_game)
	var frames := 0
	while not world.warm() and frames < 1200:
		await get_tree().process_frame
		frames += 1

	_game.player_killed.connect(func(_entry: DotKillFeed.Entry) -> void: _kills += 1)
	_game.hit_confirmed.connect(func(_a: int, _v: int, amount: float, _p: Vector3, _h: bool, lethal: bool) -> void:
		_damage += amount
		if lethal:
			_deaths += 1)

	if not map.spawns.is_empty():
		_goal = map.spawns[0].origin
	var watch := DotSpawnWatch.new()
	watch.rules.enabled = true
	watch.rules.kill_y = map.bounds.position.y - 20.0
	for player in _game.players():
		var mind := ArenaBots.Mind.new()
		mind.seed = cfg.seed_value * 1000 + player.player_id
		_minds[player.player_id] = mind

	var soak := DotBotSoak.new(cfg)
	soak.watch = watch
	soak.movers_fn = _movers
	soak.stats_fn = func() -> Dictionary: return {"kills": _kills, "deaths": _deaths, "damage": _damage}
	soak.object_count_fn = func() -> int: return int(Performance.get_monitor(Performance.OBJECT_COUNT))
	soak.step_fn = _step
	var nav := world.nav_for_rides()
	if nav != null and nav.is_ready():
		watch.nav_distance_fn = func(at: Vector3) -> float: return 0.0 if _riding.has(at) else at.distance_to(nav.closest(at))
		watch.reachable_fn = func(at: Vector3) -> bool: return not nav.route(at, _goal).get("points", PackedVector3Array()).is_empty()
		soak.players_fn = func() -> PackedVector3Array: return PackedVector3Array([_goal])

	var delta := 1.0 / float(TICK_RATE)
	while not soak.is_done():
		soak.advance(delta)
		# Yield now and then so the engine's own work (deferred frees, the nav bake) runs.
		if soak.ticks % 32 == 0:
			await get_tree().physics_frame

	var report := soak.finish()
	report["map"] = String(map_id)
	print(DotBotSoak.summary(report))
	print(DotBotSoak.report_line(report))
	var path := ProjectSettings.globalize_path("res://.godot/test-logs/soak-%s.json" % map_id)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if soak.write_report(report, path) != OK:
		push_error("could not write %s" % path)
	get_tree().quit(0 if report["ok"] else 1)


func _step(_delta: float) -> void:
	_commands.clear()
	for player in _game.players():
		if player.is_alive():
			_commands[player.player_id] = ArenaBots.think(_game, player, _minds[player.player_id], _tick, float(TICK_RATE))
	_game.tick(_commands)
	_tick += 1


func _movers() -> Array:
	var out: Array = []
	_riding.clear()
	for player in _game.players():
		if player.is_alive():
			if _minds[player.player_id].ride != null:
				_riding[player.controller.state.position] = true
			out.append({"id": player.player_id, "position": player.controller.state.position, "kind": &"bot", "has_goal": true})
	return out


func _fail(why: String) -> void:
	printerr("SOAK setup failed: ", why)
	get_tree().quit(2)
