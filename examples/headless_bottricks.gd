extends DotGameCheckSuite

const ArenaBots := preload("../game/arena_bots.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")

## Bots use the movement tricks on the real motor: slides, wall runs, ducks and the air-jump,
## often at nightmare and rarely at easy, with the air-jump only where the game has it on.
##
## [codeblock]
## godot --headless --path . res://examples/headless_bottricks.tscn
## ./game.sh test headless_bottricks
## [/codeblock]

const TICK_RATE := 64
const SECONDS := 240.0
const BOT := 1
const OTHER := 2
const MAPS: Array[StringName] = [&"dm_atrium", &"dm_pit"]

const CHECKS := 20
const SECTIONS := 6

var _entered := 0
var _completed := 0
var _results: Dictionary = {}


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena headless bot tricks")
	for map_id in MAPS:
		for preset in ["easy", "nightmare"]:
			await _play(map_id, preset, true)
	_compare()
	_section("the air-jump stays unused where the game has it off")
	var off := await _play(MAPS[0], "nightmare", false)
	_check(int(off["launches"]) == 0 and int(off["air_jump"]) == 0, "no launch while launch_enabled is off", "%d launches" % off["launches"])
	_done()
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _play(map_id: StringName, preset: String, launch: bool) -> Dictionary:
	if launch:
		_section("%s on %s" % [preset, map_id])
	var game := ArenaGame.new()
	game.name = "Arena_%s_%s" % [preset, map_id]
	game.tick_rate = TICK_RATE
	game.score_limit = 100000
	game.time_limit_sec = 0.0
	game.headless = true
	game.is_authority = true
	game.register_service = false
	add_child(game)
	_check(game.setup(ArenaMap.by_id(map_id)).ok, "the game sets up")
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	game.match_node.rules.respawn_delay_sec = 1.0
	var settings := DotBotSettings.of(game)
	var _d := settings.set_difficulty(preset)
	var _a := game.add_player(BOT, "Wren")
	var _b := game.add_player(OTHER, "Other")
	game.start(0)
	game.tick({})
	await get_tree().process_frame
	for id in [BOT, OTHER]:
		game.player_for(id).controller.tunables.launch_enabled = launch

	var minds := {BOT: ArenaBots.Mind.new(), OTHER: ArenaBots.Mind.new()}
	minds[BOT].seed = 7
	minds[OTHER].seed = 19
	var ducks := 0
	var seen_crouch := 0
	var seen_slide := 0
	var wire_ok := true
	for i in range(int(SECONDS * TICK_RATE)):
		var tick := game.current_tick()
		var commands := {}
		for id in [BOT, OTHER]:
			commands[id] = ArenaBots.think(game, game.player_for(id), minds[id], tick, float(TICK_RATE))
		var move: DotFpsCommand = commands[BOT][0]
		if game.player_for(BOT).is_alive() and move.is_pressed(DotFpsCommand.BUTTON_CROUCH):
			ducks += 1
		game.tick(commands)
		var bot_player: Object = game.player_for(BOT)
		var flags: int = bot_player.move_flags()
		if flags & DotFpsState.Move.CROUCH: seen_crouch += 1
		if flags & DotFpsState.Move.SLIDE: seen_slide += 1
		if i % 8 == 0:
			# What a remote client rebuilds from net_flags must read the same crouch and slide.
			var remote := DotFpsState.new()
			DotFpsNetSync.unpack_flags(remote, DotFpsNetSync.pack_flags(bot_player.controller.state))
			remote.crouch_fraction = bot_player.controller.state.crouch_fraction
			var mask: int = DotFpsState.Move.SLIDE | DotFpsState.Move.WALL_RUN
			wire_ok = wire_ok and (remote.move_flags() & mask) == (flags & mask)
		if i % 4 == 0:
			await get_tree().process_frame

	var motor: Variant = game.player_for(BOT).controller.motor
	var counts: Dictionary = minds[BOT].brain.tricks.counts
	var result := {"slides": motor.slides, "wall_runs": motor.wall_runs, "launches": motor.launches, "ducks": ducks, "air_jump": counts[&"air_jump"], "started_slide": counts[&"slide"], "started_wall": counts[&"wall"], "seen_crouch": seen_crouch, "seen_slide": seen_slide, "wire_ok": wire_ok}
	if launch:
		_results["%s/%s" % [preset, map_id]] = result
		print("       %s" % [result])
		_check(int(result["ducks"]) >= 0, "the run completed")
		_done()
	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
	return result


func _compare() -> void:
	_section("nightmare tricks often, easy rarely")
	var easy := {"slides": 0, "wall_runs": 0, "ducks": 0, "launches": 0}
	var hard := easy.duplicate()
	var wire := true
	for key: String in _results:
		wire = wire and bool(_results[key]["wire_ok"])
	for key: String in _results:
		var into := easy if key.begins_with("easy") else hard
		for field: String in into:
			into[field] += int(_results[key][field])
	print("       easy %s | nightmare %s" % [easy, hard])
	for field: String in ["seen_crouch", "seen_slide"]:
		easy[field] = 0
		hard[field] = 0
	for key: String in _results:
		var into2 := easy if key.begins_with("easy") else hard
		into2["seen_crouch"] += int(_results[key]["seen_crouch"])
		into2["seen_slide"] += int(_results[key]["seen_slide"])
	_check(int(hard["seen_crouch"]) > 0, "a crouching bot reads CROUCH in move_flags", str(hard["seen_crouch"]))
	_check(int(hard["seen_slide"]) > 0, "a sliding bot reads SLIDE in move_flags", str(hard["seen_slide"]))
	_check(wire, "slide and wall-run flags survive the net_flags pack and unpack")
	_check(int(hard["slides"]) >= 20, "nightmare bots slide on the real motor", str(hard["slides"]))
	_check(int(hard["wall_runs"]) >= 4, "nightmare bots wall run on the real motor", str(hard["wall_runs"]))
	_check(int(hard["ducks"]) >= 64, "nightmare bots duck", str(hard["ducks"]))
	_check(int(hard["launches"]) >= 2, "nightmare bots air-jump where it is on", str(hard["launches"]))
	_check(int(easy["slides"]) * 3 <= int(hard["slides"]), "easy bots slide far less", "%d vs %d" % [easy["slides"], hard["slides"]])
	_check(int(easy["wall_runs"]) * 3 <= int(hard["wall_runs"]), "easy bots rarely wall run", "%d vs %d" % [easy["wall_runs"], hard["wall_runs"]])
	_check(int(easy["launches"]) * 3 <= int(hard["launches"]), "easy bots rarely air-jump", "%d vs %d" % [easy["launches"], hard["launches"]])
	_done()


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1
