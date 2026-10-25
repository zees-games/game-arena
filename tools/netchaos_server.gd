extends DotGameNetchaosServer

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaModule := preload("../game/arena_module.gd")
const ArenaNetBridge := preload("../game/arena_net_bridge.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")

## The arena's side of `tools/netchaos.sh` (dot-game's DotGameNetchaosServer): no bots, no limits.

var _game: ArenaGame = null


func _configure() -> void:
	ArenaNetBridge.solid_trace = OS.get_environment("NC_SOLID_TRACE") == "1"
	map_id = "dm_box"


func _prepare(label: String) -> Variant:
	return ArenaPresentation.use_scratch_settings(label)


func _boot_world() -> void:
	_game = ArenaGame.new()
	_game.name = "Arena"
	_game.tick_rate = 60
	_game.score_limit = 0
	_game.time_limit_sec = 0.0
	_game.warmup_sec = 0.0
	_game.headless = true
	_game.register_service = true
	add_child(_game)
	var map := ArenaMap.by_id(StringName(map_id))
	var _set := _game.setup(map if map != null else ArenaMap.dm_box())
	if not (await boot_server()).ok:
		return
	var loaded: DotResult = await server.modules.load_module("res://game/arena_module.gd")
	if not loaded.ok:
		printerr("netchaos server: ", loaded.error)
		return
	module = server.modules.get_module("arena") as ArenaModule
	var quota: DotBotQuota = module.get("_bot_quota")
	if quota != null and quota.mode_cvar != null:
		quota.mode_cvar.force_set("off")
	if solid != "":
		# NC_SOLID=0 on netchaos.sh: players pass through each other, which attributes the
		# corrections a bump causes (the client predicts against interpolated hulls).
		var cv: DotConVar = server.console.find_cvar("mp_solidplayers")
		if cv != null:
			cv.force_set(solid)
	_game.start(0)


func _players() -> Array:
	return _game.players()


func _net_alive(p: Object) -> Variant:
	var b = module.bridge.behaviour_for(p.player_id) if module.bridge != null else null
	return b.net_alive if b != null else null
