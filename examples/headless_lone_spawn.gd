extends DotGameCheckSuite

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")

## A lone human with no bots (bot_quota_mode off) on a deathmatch whose ruleset wants two players waits in warmup, but is alive on a spawn point, not dead or parked at the origin.
## Run: [code]godot --headless --path . res://examples/headless_lone_spawn.tscn[/code]

const TICK_RATE := 64

func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena: a lone player is not left dead")
	var game := ArenaGame.new()
	game.tick_rate = TICK_RATE
	game.headless = true
	game.is_authority = true
	game.register_service = false
	add_child(game)
	var ok := game.setup(ArenaMap.dm_box()).ok
	_check(ok, "sets up")
	if ok:
		var m := game.match_node
		print("min_players=%d warmup=%s state=%s" % [m.rules.min_players, m.rules.warmup_sec, m.state])
		game.start(0)
		var _a := game.add_player(1, "Lone")
		for i in TICK_RATE * 15:
			game.tick({})
		var p := game.player_for(1)
		print("state=%s alive=%s pos=%s" % [m.state, p.is_alive(), p.controller.state.position])
		_check(p.is_alive(), "the lone player is alive in warmup")
		_check(p.controller.state.position.length() > 0.01, "and stands on a spawn point")
	game.queue_free()
	_report_sections(1, 1, 1, 3)
