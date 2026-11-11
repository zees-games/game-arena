extends RefCounted

## The bots' brains on worker threads (cvar `bot_threads`, 0 = off: the stock one-bot-at-a-time loop). A tick of bot commands is three steps (see [method ArenaBots.think_begin]): on the main thread, once,
## the stagger switches, which bots coast, the contacts and each thinking bot's brain and contact; then over [member threads] threads each thinking bot's brain, which reads
## that snapshot and writes one [DotBotIntent], and its commands from the intent ([method ArenaBots.think_finish]), and each coasting bot's repeated commands; last, on the main
## thread, the woken marks in bot order (and on a surf map every bot's commands, whose steer shares the rides). The motor and weapons run after, from those commands.
## The brains touch no node: sight and wall rays use queries of their own, routes and waypoints take the world's lock ([member ArenaBots.World.par]); a brain is only its bot's, so answers do not depend on which thread runs which bot.

const ArenaBots := preload("arena_bots.gd")
const ArenaFrameProbe := preload("arena_frame_probe.gd")
const ArenaPlayer := preload("arena_player.gd")

## Fewer bots than this think on the main thread: the hand-off costs more than it saves.
const MIN_BOTS := 8

## Brains per grab from the shared queue.
const CHUNK := 4

## Threads that decide (the main thread is one); 0 and 1 think on the main thread.
static var threads: int = 0

## Ticks whose brains went through the worker path (for the suite).
static var par_ticks: int = 0

## Bot indices: the thinking bots first (job j < [member _thinkers] logs its wall rays as job j), then the coasting ones.
var _jobs: Array[int] = []
var _thinkers := 0
## Whether the workers make the thinking bots' commands too (off a surf map).
var _finish := false
var _players: Array = []
var _minds: Array = []
var _game: Object = null
var _tick := 0
var _rate := 0.0
var _world_lock: Mutex = null
var _next := 0
var _lock := Mutex.new()


## Whether [param bot_count] bots go through [method think_all] this tick.
static func active(bot_count: int) -> bool:
	return threads > 0 and bot_count >= MIN_BOTS and DotPlatform.has_threads()


## [move, fire] per bot, in order, as [method ArenaBots.think] gives each one. [param players] and
## [param minds] are parallel arrays.
static func think_all(game: Object, players: Array, minds: Array, tick: int, tick_rate: float) -> Array:
	var out: Array = []
	out.resize(players.size())
	var run := new()
	var coasts: Array[int] = []
	var world: ArenaBots.World = null
	for i in players.size():
		var bot: ArenaPlayer = players[i]
		if game == null or bot == null:
			out[i] = [DotFpsCommand.new(), DotWeaponCommand.new()]
			continue
		if world == null:
			world = ArenaBots.tick_setup(game)
		if ArenaBots.coasts_now(minds[i], tick, world, bot.player_id):
			coasts.append(i)
		else:
			run._jobs.append(i)
	if world == null:
		return out
	run._thinkers = run._jobs.size()
	if run._thinkers > 0:
		ArenaBots.refresh_world(world, tick, tick_rate)
		for i in run._jobs:
			ArenaBots.ready_brain(game, players[i], minds[i], world)
	run._jobs.append_array(coasts)
	run._players = players
	run._minds = minds
	run._game = game
	run._tick = tick
	run._rate = tick_rate
	var started := Time.get_ticks_usec()
	if run._thinkers < MIN_BOTS or not world.par_begin():
		for j in run._jobs.size():
			var i := run._jobs[j]
			var mind: ArenaBots.Mind = minds[i]
			if j < run._thinkers:
				mind.t_intent = mind.brain.think(mind.t_me, mind.t_world, mind.t_world.now())
			else:
				out[i] = ArenaBots.coast_commands(players[i], mind, tick, tick_rate)
		ArenaFrameProbe.add(&"bot_brain", started)
		for j in run._thinkers:
			var i := run._jobs[j]
			out[i] = ArenaBots.think_finish(game, players[i], minds[i], tick, tick_rate)
		return out
	par_ticks += 1
	run._finish = world.surf_for_map() == null
	run._world_lock = world._par_lock
	var helpers := mini(threads, run._jobs.size() / CHUNK + 1) - 1
	var group := WorkerThreadPool.add_group_task(run._work, helpers, helpers, true, "arena bot brains") if helpers > 0 else -1
	run._work(0)
	if group >= 0:
		WorkerThreadPool.wait_for_group_task_completion(group)
	world.par_end()
	# bot_brain here is the whole threaded pass: brains, their commands (bot_after on the main-thread path) and coasts.
	ArenaFrameProbe.add(&"bot_brain", started)
	for j in run._jobs.size():
		var i := run._jobs[j]
		var mind: ArenaBots.Mind = minds[i]
		if j < run._thinkers and not run._finish:
			out[i] = ArenaBots.think_finish(game, players[i], mind, tick, tick_rate)
			continue
		out[i] = mind.t_out
		mind.t_out = []
		if j < run._thinkers:
			# think_finish's own clear on the main-thread path; only hits write woken, and none land mid-pass.
			world.woken.erase((players[i] as ArenaPlayer).player_id)
	return out


## Takes bots off the shared queue until it is empty.
func _work(_slot: int) -> void:
	while true:
		_lock.lock()
		var from := _next
		_next += CHUNK
		_lock.unlock()
		if from >= _jobs.size():
			return
		for j in range(from, mini(from + CHUNK, _jobs.size())):
			var i := _jobs[j]
			var mind: ArenaBots.Mind = _minds[i]
			if j >= _thinkers:
				mind.t_out = ArenaBots.coast_commands(_players[i], mind, _tick, _rate)
				continue
			(mind.t_world as ArenaBots.World).par_job(j)
			mind.t_intent = mind.brain.think(mind.t_me, mind.t_world, mind.t_world.now())
			if _finish:
				mind.t_out = ArenaBots.think_finish(_game, _players[i], mind, _tick, _rate, _world_lock)
