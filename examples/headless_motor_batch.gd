extends DotGameCheckSuite

const ArenaBots := preload("../game/arena_bots.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaHullGrid := preload("../game/arena_hull_grid.gd")
const ArenaMap := preload("../maps/arena_map.gd")

## `arena_motor_batch`: the players' motors ticked in runs of one dot-sim call play exactly the match the loop one player
## after another plays. A match of bots is played once and its commands recorded; the recording is then replayed through
## both loops and every player's position, velocity, movement mode, stance, view and health, to the bit, hashed every
## few ticks, is identical: a box of walkers and a map with a pit to die in (analytic collision, where the motors leave
## the batch and tick by themselves), an imported map and surf ramps (where they run in it). Run:
##
## [codeblock]
## godot --headless --path . res://examples/headless_motor_batch.tscn
## ./game.sh test headless_motor_batch
## [/codeblock]

const TICK_RATE := 33
const BOTS := 24
const SECONDS := 15.0
const SMALL_BOTS := 16
const SMALL_SECONDS := 8.0
const IMPORTED_MAPS: Array[StringName] = [&"dm-morpheus", &"surf_ski_2"]

const SECTIONS := 3
const CHECKS := 12

var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena: arena_motor_batch plays the same match")
	ArenaBots.tiers.above = -1
	var was := ArenaHullGrid.batch
	if not DotFpsMotorBatch.available() or not ClassDB.class_exists(&"DotSimHullWorld"):
		# Natives older than the batch: the cvar changes nothing and there is nothing to compare.
		print("skip: the loaded dot-sim has no motor batch")
		for i in CHECKS:
			_check(true, "(skipped: no motor batch in dot-sim)")
		_report_sections(SECTIONS, SECTIONS, SECTIONS, CHECKS)
		return

	_section("a box of walkers: recorded, replayed through both loops")
	var streams: Array = []
	var thought := await _play(false, &"", BOTS, SECONDS, streams, true)
	var off := await _play(false, &"", BOTS, SECONDS, streams, false)
	var on := await _play(true, &"", BOTS, SECONDS, streams, false)
	var live := await _play(true, &"", BOTS, SECONDS, [], true)
	_check(thought[0].size() > 10 and thought[1] > 0, "the match was played (%d digests, %d kills)" % [thought[0].size(), thought[1]])
	_check(off[0] == thought[0], "the recorded commands replay the match (%s)" % _first_diff(thought[0], off[0]))
	_check(on[0] == off[0], "the batched loop plays the recording to the bit (%s)" % _first_diff(off[0], on[0]))
	_check(live[0] == thought[0], "and the bots' own match, thinking on what it gives them (%s)" % _first_diff(thought[0], live[0]))
	_check(on[1] == off[1], "as many kills (%d, batched %d)" % [off[1], on[1]])
	_check(off[2] == 0, "and none with the cvar off")
	_check(on[3] == 0 and live[3] == 0, "no player was changed by another's turn (%d, %d faults)" % [on[3], live[3]])
	_done()

	_section("a pit: players die and respawn in their own turn")
	streams = []
	off = await _play(false, &"dm_pit", SMALL_BOTS, SECONDS, streams, true)
	on = await _play(true, &"dm_pit", SMALL_BOTS, SECONDS, streams, false)
	_check(on[0] == off[0] and off[0].size() > 10, "the batched loop plays the pit's match to the bit (%s; %d kills)" % [_first_diff(off[0], on[0]), off[1]])
	_check(on[3] == 0, "no player was changed by another's turn (%d faults)" % on[3])
	_done()

	_section("imported maps: a deathmatch and surf ramps")
	var rows := 0
	var ran := 0
	for id in IMPORTED_MAPS:
		if ArenaMap.by_id(id) == null:
			print("skip %s: not linked" % id)
			_check(true, "(skipped: %s is not linked)" % id)
			continue
		streams = []
		off = await _play(false, id, SMALL_BOTS, SMALL_SECONDS, streams, true)
		var again: Array = await _play(false, id, SMALL_BOTS, SMALL_SECONDS, streams, false)
		on = await _play(true, id, SMALL_BOTS, SMALL_SECONDS, streams, false)
		rows += on[2]
		ran += 1
		print("%s: %d digests, %d kills, %d rows, %d faults" % [id, off[0].size(), again[1], on[2], on[3]])
		# A map with moving things may not replay its recording; the two loops are held to the same replay.
		print("%s: replay against the recording: %s" % [id, _first_diff(off[0], again[0])])
		_check(on[0] == again[0] and again[0].size() > 5, "the batched loop plays %s to the bit (%s)" % [id, _first_diff(again[0], on[0])])
	_check(ran == 0 or rows > 0, "through the batch (%d rows)" % rows)
	_done()
	ArenaHullGrid.batch = was
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


func _first_diff(a: PackedStringArray, b: PackedStringArray) -> String:
	for i in mini(a.size(), b.size()):
		if a[i] != b[i]:
			return "first differing window %d of %d" % [i, a.size()]
	return "%d windows" % a.size() if a.size() == b.size() else "%d and %d windows" % [a.size(), b.size()]


## One match, the bots thinking ([param think], their commands appended to [param streams]) or [param streams] replayed:
## [digests, kills, batch rows, batch faults].
func _play(batched: bool, map_id: StringName, bots: int, seconds: float, streams: Array, think: bool) -> Array:
	ArenaHullGrid.batch = batched
	ArenaHullGrid.batch_rows = 0
	ArenaHullGrid.batch_faults = 0
	var game := ArenaGame.new()
	game.name = "Arena_%d_%d" % [int(batched), int(think)]
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
	for i in bots:
		var made := game.add_player(100 + i, "Bot%d" % i)
		if made.ok:
			players.append(made.value)
			var mind := ArenaBots.Mind.new()
			mind.seed = 100 + i
			minds.append(mind)
	game.start(0)
	game.tick({})
	# The map's collision reaches the physics space in a physics frame; every run starts after it.
	for _i in 3:
		await get_tree().physics_frame
	if think and map_id != &"" and map_id != &"dm_pit":
		# The routes start when the mesh bake lands; start every run from there.
		var world := ArenaBots.world_for(game)
		var _first := world.route(Vector3.ZERO, Vector3.ONE)
		var frames := 0
		while world.is_route_pending() and frames < 3000:
			await get_tree().process_frame
			frames += 1
		var _warm := world.warm()
	var digests := PackedStringArray()
	var window := PackedByteArray()
	for tick_index in int(seconds * TICK_RATE):
		var commands := {}
		if think:
			var recorded := {}
			var tick := game.current_tick()
			for i in players.size():
				var pair: Array = ArenaBots.think(game, players[i], minds[i], tick, float(TICK_RATE))
				var move: DotFpsCommand = pair[0]
				var fire: DotWeaponCommand = pair[1]
				commands[players[i].player_id] = pair
				recorded[players[i].player_id] = [move.duplicate_command(), fire.duplicate_command()]
			streams.append(recorded)
		else:
			var recorded: Dictionary = streams[tick_index]
			for id: int in recorded:
				var move: DotFpsCommand = recorded[id][0]
				var fire: DotWeaponCommand = recorded[id][1]
				commands[id] = [move.duplicate_command(), fire.duplicate_command()]
		game.tick(commands)
		for player: Object in players:
			var state: DotFpsState = player.controller.state if player.controller != null else null
			if state != null:
				window.append_array(var_to_bytes([state.position, state.velocity, state.mode, state.move_flags(), state.ground_id != 0,
					state.yaw, state.pitch, player.health.health, player.health.alive]))
		if tick_index % 10 == 9:
			var hashing := HashingContext.new()
			var _started := hashing.start(HashingContext.HASH_MD5)
			var _fed := hashing.update(window)
			digests.append(hashing.finish().hex_encode())
			window.clear()
		if tick_index % 8 == 0:
			await get_tree().process_frame
	var out := [digests, kills[0], ArenaHullGrid.batch_rows, ArenaHullGrid.batch_faults]
	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
	return out
