extends Node

const ArenaBots := preload("../game/arena_bots.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

## The bots, in the real game: one bot per difficulty preset against one reference player on
## dm_box, with arena's own weapons, movement, trace and match.
##
## [codeblock]
## godot --headless --path . res://examples/headless_bots.tscn
## ./game.sh test headless_bots
## [/codeblock]
##
## [b]What it holds still.[/b] dot-bot's own suite measures the brain against a scripted
## opponent in a world of rays. This is the same brain fed from arena (ArenaBots): a bot at
## each preset plays [constant SECONDS] of a one-on-one deathmatch against a reference player
## whose settings are pinned here and never follow a preset, so the kill/death ratio moves only
## with the preset. Alongside it, every tick:
##
## [codeblock]
## no shot without line of sight   a bot with the trigger down can see whom it is fighting
## no snap                         no tick turns the view faster than bot_turn_rate
## reaction and aim                first shot after first sight, and how far off it was,
##                                 per engagement, against the preset's bot_reaction
## [/codeblock]
##
## The solo client runs these bots too (ArenaClient._drive_bots), which is the point: the
## first play test met a test-fixture aimbot there instead.

const TICK_RATE := 64

## Game seconds per preset. 600 since the respawn started hiding from the killer (a spawn
## an enemy can see is charged in a headless game too): one-on-one, that means fewer fights
## per minute, and at 300 s hard and medium swapped places on one seed (1.25 against 1.37).
const SECONDS := 600.0

## The bot and the reference player's session ids.
const BOT := 1
const REFERENCE := 2

## K/D per preset against the reference player: [low, high].
##
## The reference is an ordinary player (below). Medium, the default, wins a share of its fights
## and loses more; hard is a good player who wins most of them; nightmare is beyond that.
##
## Measured when the bands were set, 300 s each: easy 0.45, medium 1.20, hard 1.72, nightmare 2.75.
## With hidden respawns, 600 s each: easy 0.62, medium 1.42, hard 1.67, nightmare 2.91.
const KD_BANDS := {
	"easy": [0.0, 0.7],
	"medium": [0.5, 1.6],
	"hard": [0.9, 6.0],
	"nightmare": [1.6, 1000.0],
}

## The reference player: an ordinary one, pinned, whatever the presets say.
const REFERENCE_PROFILE := {
	"reaction": 0.35, "notice": 0.2, "aim_error": 4.0, "aim_settle": 0.7, "aim_floor": 1.5,
	"turn_rate": 450.0, "turn_smooth": 0.5, "prediction": 0.5, "fire_cone": 5.0,
	"burst": 0.5, "burst_pause": 0.3, "burst_range": 15.0, "strafe": 0.6, "stop_to_shoot": 0.3,
	"peek": 0.3, "crouch": 0.1, "jump": 0.05, "cover": 0.3, "map_knowledge": 0.4,
	# No grenades: the bands were measured against a reference that could not throw (bots had
	# no throw until fpt-arena-bots-2), and a reference cooking frags fights less and moved easy
	# past its band.
	"grenades": 0.0,
}

const CHECKS := 46
const SECTIONS := 5

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

## preset -> {kd, kills, deaths, reaction, first_error, blind_shots, fastest_turn}
var _results: Dictionary = {}


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena headless bots")

	for preset in DotBotProfile.PRESETS:
		await _play(preset)

	_test_order()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	print("%d of %d sections ran to their last line" % [_completed, _entered])
	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected." % [_entered, _completed, SECTIONS])
		get_tree().quit(1)
		return
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _play(preset: String) -> void:
	_section("%s against the reference player" % preset)

	var game := ArenaGame.new()
	game.name = "Arena_%s" % preset
	game.tick_rate = TICK_RATE
	game.score_limit = 100000
	game.time_limit_sec = 0.0
	game.headless = true
	game.is_authority = true
	game.register_service = false
	add_child(game)
	_check(game.setup(ArenaMap.dm_box()).ok, "the game sets up")
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	game.match_node.rules.respawn_delay_sec = 1.0

	var settings := DotBotSettings.of(game)
	_check(settings.set_difficulty(preset).ok, "bot_difficulty %s" % preset)

	var reference := DotBotSettings.new()
	for field: String in REFERENCE_PROFILE:
		var _set := reference.set_value(field, str(REFERENCE_PROFILE[field]))

	var kills: Array[int] = [0, 0]
	game.player_killed.connect(func(entry: DotKillFeed.Entry) -> void:
		if entry.killer_key == str(BOT) and entry.victim_key == str(REFERENCE):
			kills[0] += 1
		elif entry.killer_key == str(REFERENCE) and entry.victim_key == str(BOT):
			kills[1] += 1
	)

	var _a := game.add_player(BOT, "Wren")
	var _b := game.add_player(REFERENCE, "Reference")
	game.start(0)
	game.tick({})
	await get_tree().process_frame

	var bot_mind := ArenaBots.Mind.new()
	bot_mind.seed = 7
	var ref_mind := ArenaBots.Mind.new()
	ref_mind.brain = DotBotBrain.new(11, reference)

	var reactions: Array[float] = []
	var first_errors: Array[float] = []
	var last_first_shot := NAN
	var blind_shots := 0
	var shots := 0
	# Grenades the bot let go of: a throw is not a shot (a frag lobbed at where a target went
	# behind cover is meant to be blind), so it is counted here and not judged by sight.
	var thrown: Array[int] = [0]
	game.player_for(BOT).used.connect(func(outcome: DotWeaponOutcome) -> void:
		if outcome != null and outcome.used and not outcome.spawns.is_empty() and game.player_for(BOT).arsenal.current_slot() == ZeeWeaponIds.SLOT_THROWN:
			thrown[0] += 1
	)
	var fastest := 0.0
	var trace: DotTrace = game.combat.trace

	var ticks := int(SECONDS * TICK_RATE)
	for i in range(ticks):
		var tick := game.current_tick()
		var bot := game.player_for(BOT)
		var ref := game.player_for(REFERENCE)
		var commands := {
			BOT: ArenaBots.think(game, bot, bot_mind, tick, float(TICK_RATE)),
			REFERENCE: ArenaBots.think(game, ref, ref_mind, tick, float(TICK_RATE)),
		}

		# What the bot did this tick, judged from outside the brain.
		var brain := bot_mind.brain
		var fire: DotWeaponCommand = commands[BOT][1]
		var move: DotFpsCommand = commands[BOT][0]
		if bot.is_alive():
			# Against the view the bot had going into the tick, never the last command: a
			# spawn turns the view too, and that is the map's doing, not the bot's.
			fastest = maxf(fastest, absf(wrapf(move.yaw - bot.controller.state.yaw, -180.0, 180.0)) * TICK_RATE)
			if fire.is_pressed(DotWeaponCommand.BUTTON_ATTACK) and bot_mind.throw_stage == 0:
				shots += 1
				var target := game.player_for(brain.last.target_id) if brain.last.target_id >= 0 else null
				if target == null or not trace.line_of_sight(bot.muzzle_position(), target.global_position + Vector3.UP * ArenaBots.CHEST):
					if target == null or not trace.line_of_sight(bot.muzzle_position(), target.muzzle_position()):
						blind_shots += 1

		var e := brain.engagement()
		var first := float(e["first_shot_at"])
		if not is_nan(first) and first != last_first_shot:
			last_first_shot = first
			reactions.append(first - float(e["seen_at"]))
			first_errors.append(float(e["first_shot_error_deg"]))

		game.tick(commands)
		if i % 4 == 0:
			await get_tree().process_frame

	var p := settings.profile
	var kd := float(kills[0]) / float(maxi(kills[1], 1))
	var reaction := _mean(reactions)
	var first_error := _mean(first_errors)
	_results[preset] = {"kd": kd, "kills": kills[0], "deaths": kills[1], "reaction": reaction, "first_error": first_error}
	print("       %-9s %2d kills %2d deaths  K/D %.2f  reaction %.3f s (bot_reaction %.2f, %d engagements)  first shot %.2f deg off  turn %.0f deg/s  %d of %d shots blind  %d grenades" % [
		preset, kills[0], kills[1], kd, reaction, p.reaction, reactions.size(), first_error, fastest, blind_shots, shots, thrown[0]])

	var band: Array = KD_BANDS[preset]
	_check(kills[0] + kills[1] >= 4, "%s: the two actually fight (%d deaths in %d s)" % [preset, kills[0] + kills[1], int(SECONDS)])
	_check(kd >= float(band[0]) and kd <= float(band[1]), "%s: K/D %.2f inside %.2f..%.2f" % [preset, kd, band[0], band[1]])
	_check(blind_shots == 0, "%s: never fires at somebody it cannot see" % preset, "%d blind of %d" % [blind_shots, shots])
	if p.grenades > 0.0:
		_check(thrown[0] > 0, "%s: throws grenades (bot_grenades %.1f) through the throwable slot" % [preset, p.grenades], "%d thrown" % thrown[0])
	else:
		_check(thrown[0] == 0, "%s: throws no grenade (bot_grenades 0)" % preset, "%d thrown" % thrown[0])
	_check(fastest <= p.turn_rate * 1.02, "%s: never turns faster than bot_turn_rate (%.0f deg/s)" % [preset, p.turn_rate], "%.0f" % fastest)
	_check(reactions.size() > 0 and reaction >= p.reaction * 0.5 and reaction <= p.reaction + p.notice * 2.0 + 0.3,
		"%s: first shot about bot_reaction after first sight" % preset, "%.3f over %d" % [reaction, reactions.size()])

	# The world walks bots round the boxes: a route between the two spawns furthest apart, each
	# leg clear at knee height (the horde's graph, built for this map).
	var world := ArenaBots.world_for(game)
	var spawns: Array[Transform3D] = game.map.spawns
	var a := spawns[0].origin
	var b := a
	for spawn in spawns:
		if spawn.origin.distance_to(a) > b.distance_to(a):
			b = spawn.origin
	var route := world.route(a, b)
	var clear := route.size() >= 2
	var from := a
	for corner in route:
		clear = clear and trace.line_of_sight(from + Vector3.UP * 0.5, corner + Vector3.UP * 0.5)
		from = corner
	_check(clear, "%s: the world routes between spawns %.0f m apart, every leg clear of the boxes" % [preset, a.distance_to(b)], "%d corners" % route.size())

	# A rocket is led by its speed; a rifle is not.
	var me := world.contact(BOT)
	var rifle := world.projectile_speed(me)
	var bot := game.player_for(BOT)
	# Into an empty arsenal, so it is in hand at once.
	bot.arsenal.clear()
	var _given := bot.arsenal.give(ZeeWeaponIds.LAUNCHER)
	var rocket := world.projectile_speed(me)
	_check(rifle == 0.0 and rocket > 0.0, "%s: the brain is told a rocket's speed (%.0f m/s) and a rifle's is none" % [preset, rocket], "rifle %.0f" % rifle)

	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
	_done()


func _test_order() -> void:
	_section("the presets are in order")
	_check(_results["easy"]["kd"] < _results["medium"]["kd"], "medium beats easy")
	_check(_results["medium"]["kd"] < _results["hard"]["kd"], "hard beats medium")
	_check(_results["hard"]["kd"] <= _results["nightmare"]["kd"], "nightmare at least matches hard")
	_check(_results["easy"]["reaction"] > _results["medium"]["reaction"] and _results["medium"]["reaction"] > _results["hard"]["reaction"],
		"reaction quickens easy to medium to hard")
	_check(_results["medium"]["kd"] < 1.5, "the default (medium) is not the bot that killed a person twelve times in ninety seconds")
	_check(DotBotSettings.new().difficulty() == "medium", "and medium is the default")
	_done()


func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return NAN
	var total := 0.0
	for v in values:
		total += v
	return total / float(values.size())


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else " — " + detail])
	return condition
