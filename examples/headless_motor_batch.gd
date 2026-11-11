extends DotGameCheckSuite

const ArenaBots := preload("../game/arena_bots.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaHullGrid := preload("../game/arena_hull_grid.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaModTools := preload("../game/arena_mod_tools.gd")

## `arena_motor_batch`: the players' motors ticked in runs of one dot-sim call play exactly the
## match the loop one player after another plays. A recorded bot match is replayed through both
## loops and every player's state, hashed every few ticks, is identical, on box, pit, imported and surf maps.

const TICK_RATE := 33
const BOTS := 24
const SECONDS := 15.0
const SMALL_BOTS := 16
const SMALL_SECONDS := 8.0
const IMPORTED_MAPS: Array[StringName] = [&"dm-morpheus", &"surf_ski_2"]

## A player is changed every this many ticks, each of these ways in turn.
const MEDDLE_EVERY := 5
const MEDDLES: Array[StringName] = [&"slay", &"slap", &"push"]
const PUSH := Vector3(3.0, 6.0, -2.0)

const SECTIONS := 5
const CHECKS := 21


## Kills, slaps and pushes players: between two ticks as the admin tools do, or in the place of the demo's statistics,
## which the loop calls after each player's turn, to a player whose turn that tick is over or still to come.
class Meddler extends RefCounted:
	var game: ArenaGame = null
	## &"between", &"earlier" or &"later".
	var where: StringName = &""
	var done := 0

	func process(_delta: float) -> void:
		pass

	func release() -> void:
		pass

	func between(tick: int) -> void:
		if where != &"between" or tick % MEDDLE_EVERY != 0:
			return
		var ids: Array[int] = game.player_ids()
		var turn := tick / MEDDLE_EVERY
		_change(ids[turn % ids.size()], turn)

	func after(id: int, _player: Object, _move: Object, _fire: Object, tick: int) -> void:
		if where == &"between" or tick % MEDDLE_EVERY != 0:
			return
		var ids: Array[int] = game.player_ids()
		var n := ids.size()
		var turn := tick / MEDDLE_EVERY
		var from := 3 + turn % (n - 6)
		if ids[from] != id:
			return
		var step := 1 + (turn / 3) % 3
		_change(ids[from - step if where == &"earlier" else from + step], turn)

	func _change(id: int, turn: int) -> void:
		var victim: Object = game.player_for(id)
		if victim == null or not victim.is_alive():
			return
		done += 1
		match MEDDLES[turn % MEDDLES.size()]:
			&"slay":
				var _slain := ArenaModTools.slay(game, StringName(str(id)))
			&"slap":
				var _slapped := ArenaModTools.slap(game, StringName(str(id)), 0.0)
			&"push":
				victim.controller.apply_external_velocity(PUSH)

var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact: arena_motor_batch plays the same match")
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
	var kept: StringName = &""
	var kept_streams: Array = []
	for id in IMPORTED_MAPS:
		if ArenaMap.by_id(id) == null:
			print("skip %s: not linked" % id)
			_check(true, "(skipped: %s is not linked)" % id)
			continue
		streams = []
		off = await _play(false, id, SMALL_BOTS, SMALL_SECONDS, streams, true)
		var again: Array = await _play(false, id, SMALL_BOTS, SMALL_SECONDS, streams, false)
		on = await _play(true, id, SMALL_BOTS, SMALL_SECONDS, streams, false)
		if kept == &"":
			kept = id
			kept_streams = streams
		rows += on[2]
		ran += 1
		print("%s: %d digests, %d kills, %d rows, %d faults" % [id, off[0].size(), again[1], on[2], on[3]])
		# A map with moving things may not replay its recording; the two loops are held to the same replay.
		print("%s: replay against the recording: %s" % [id, _first_diff(off[0], again[0])])
		_check(on[0] == again[0] and again[0].size() > 5, "the batched loop plays %s to the bit (%s)" % [id, _first_diff(again[0], on[0])])
	_check(ran == 0 or rows > 0, "through the batch (%d rows)" % rows)
	_done()

	await _run_part2(was, off, on, rows, kept, kept_streams)


func _run_part2(was, off, on, rows, kept: StringName, kept_streams: Array) -> void:
	_section("lag compensation: shots judged against the past, lagged movers colliding with it")
	if kept == &"":
		for i in 4:
			_check(true, "(skipped: no imported map is linked)")
	else:
		off = await _play(false, kept, SMALL_BOTS, SMALL_SECONDS, kept_streams, false, {lag = true})
		on = await _play(true, kept, SMALL_BOTS, SMALL_SECONDS, kept_streams, false, {lag = true})
		print("%s, shots rewound: %d hits, %d rewound places, %d rows, %d faults" % [kept, off[4], off[5], on[2], on[3]])
		_check(off[4] > 0 and off[5] > 0, "shots hit players stood back where the shooter saw them (%d hits, %d places)" % [off[4], off[5]])
		_check(on[0] == off[0] and off[0].size() > 5, "the same rewound places and hits in both loops (%s)" % _first_diff(off[0], on[0]))
		var rewound_rows: int = on[2]
		off = await _play(false, kept, SMALL_BOTS, SMALL_SECONDS, kept_streams, false, {lag = true, collide = true})
		on = await _play(true, kept, SMALL_BOTS, SMALL_SECONDS, kept_streams, false, {lag = true, collide = true})
		print("%s, lagged movers: %d hits, %d rewound places, %d rows, %d faults" % [kept, off[4], off[5], on[2], on[3]])
		_check(on[0] == off[0] and off[0].size() > 5, "and with the lagged movers colliding with the past (%s)" % _first_diff(off[0], on[0]))
		_check(rewound_rows > 0 and on[2] > 0, "through the batch (%d and %d rows)" % [rewound_rows, on[2]])
	_done()

	_section("killed, slapped or pushed: between two ticks, after the player's own turn, before it")
	if kept == &"":
		for i in 5:
			_check(true, "(skipped: no imported map is linked)")
	else:
		for where: StringName in [&"between", &"earlier"]:
			off = await _play(false, kept, SMALL_BOTS, SMALL_SECONDS, kept_streams, false, {meddle = where})
			on = await _play(true, kept, SMALL_BOTS, SMALL_SECONDS, kept_streams, false, {meddle = where})
			print("%s, %s: %d changed (batched %d), %d kills, %d rows, %d faults" % [kept, where, off[5], on[5], off[1], on[2], on[3]])
			_check(on[0] == off[0] and off[0].size() > 5, "%s: both loops play the same match (%s)" % [where, _first_diff(off[0], on[0])])
			_check(off[5] > 3 and on[2] > 0 and on[3] == 0, "%s: %d players changed, through the batch with no fault" % [where, off[5]])
		# Before its turn the player's tick has started in the batched loop and not in the other: not the same match, and counted.
		off = await _play(false, kept, SMALL_BOTS, SMALL_SECONDS, kept_streams, false, {meddle = &"later"})
		on = await _play(true, kept, SMALL_BOTS, SMALL_SECONDS, kept_streams, false, {meddle = &"later"})
		print("%s, later: %d changed, %d faults, %s" % [kept, on[5], on[3], _first_diff(off[0], on[0])])
		_check(on[5] > 3 and on[3] >= on[5], "before its turn: the batched loop counts each (%d changed, %d faults)" % [on[5], on[3]])
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


## One match, the bots thinking ([param think], commands appended to [param streams]) or
## [param streams] replayed: [digests, kills, batch rows, batch faults, hits, rewound changes].
## [param opts]: `lag`, `collide`, `meddle` (where a [Meddler] acts).
func _play(batched: bool, map_id: StringName, bots: int, seconds: float, streams: Array, think: bool, opts: Dictionary = {}) -> Array:
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
	var hits: Array = []
	var counts := [0, 0]
	game.hit_confirmed.connect(func(attacker: int, victim: int, amount: float, point: Vector3, headshot: bool, lethal: bool) -> void:
		hits.append([attacker, victim, amount, point, headshot, lethal])
		counts[0] += 1)
	var lagging: bool = opts.get("lag", false)
	if opts.get("collide", false):
		game.remote_lags_fn = func(mover_id: int) -> bool: return _lag_of(mover_id) > 0.0
		game.remote_feet_fn = func(other_id: int, mover_id: int, tick: int) -> Variant:
			var lag := _lag_of(mover_id)
			return game.unlag_position_at(other_id, float(tick) - lag) if lag > 0.0 else null
	var meddler: Meddler = null
	if opts.has("meddle"):
		meddler = Meddler.new()
		meddler.game = game
		meddler.where = opts.meddle
		game.demo_stats = meddler
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
				if lagging and _lag_of(id) > 0.0:
					commands[id].append(_lag_of(id))
		var now := game.current_tick()
		game.tick(commands)
		if meddler != null:
			meddler.between(now)
		for player: Object in players:
			var state: DotFpsState = player.controller.state if player.controller != null else null
			if state != null:
				window.append_array(var_to_bytes([state.position, state.velocity, state.mode, state.move_flags(), state.ground_id != 0,
					state.yaw, state.pitch, player.health.health, player.health.alive]))
			if lagging:
				var then: Variant = game.unlag_position_at(player.player_id, float(now) - _lag_of(player.player_id))
				window.append_array(var_to_bytes(then))
				if then is Vector3 and state != null and not (then as Vector3).is_equal_approx(state.position):
					counts[1] += 1
		window.append_array(var_to_bytes(hits))
		hits.clear()
		if tick_index % 10 == 9:
			var hashing := HashingContext.new()
			var _started := hashing.start(HashingContext.HASH_MD5)
			var _fed := hashing.update(window)
			digests.append(hashing.finish().hex_encode())
			window.clear()
		if tick_index % 8 == 0:
			await get_tree().process_frame
	var out := [digests, kills[0], ArenaHullGrid.batch_rows, ArenaHullGrid.batch_faults, counts[0], meddler.done if meddler != null else counts[1]]
	game.demo_stats = null
	game.remote_feet_fn = Callable()
	game.remote_lags_fn = Callable()
	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
	return out


## The view lag, in ticks, of the player's commands in a lagged run: none for one player in four, as a bot has none.
func _lag_of(id: int) -> float:
	return float(id % 4) * 1.5
