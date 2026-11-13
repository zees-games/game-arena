extends RefCounted

## The bots' brains on worker threads (cvar `bot_threads`, 0 = off: the stock one-bot-at-a-time loop). A tick of bot commands is three steps (see [method ArenaBots.think_begin]): per bot on the main thread the snapshot and bookkeeping;
## the brains' decisions, which read that snapshot and write one [DotBotIntent] each, split over [member threads] threads; per bot on the main thread the commands from the intent. The motor and weapons run after, from those commands.
## The brains touch no node: sight and wall rays use queries of their own, routes and waypoints take the world's lock ([member ArenaBots.World.par]); a brain is only its bot's, so answers do not depend on which thread runs which bot.

const ArenaBots := preload("arena_bots.gd")
const ArenaFrameProbe := preload("arena_frame_probe.gd")

## Fewer bots than this think on the main thread: the hand-off costs more than it saves.
const MIN_BOTS := 8

## Brains per grab from the shared queue.
const CHUNK := 4

## Threads that decide (the main thread is one); 0 and 1 think on the main thread.
static var threads: int = 0

## Ticks whose brains went through the worker path (for the suite).
static var par_ticks: int = 0

var _jobs: Array = []
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
	var pending: Array[int] = []
	var t_fine := Time.get_ticks_usec() if ArenaFrameProbe.fine else 0
	for i in players.size():
		var early := ArenaBots.think_begin(game, players[i], minds[i], tick, tick_rate)
		if early.is_empty():
			pending.append(i)
		else:
			out[i] = early
	if t_fine != 0:
		ArenaFrameProbe.add(&"bt_begin", t_fine)
	if not pending.is_empty():
		_decide(pending, minds)
		if t_fine != 0:
			t_fine = Time.get_ticks_usec()
		for i in pending:
			out[i] = ArenaBots.think_finish(game, players[i], minds[i], tick, tick_rate)
		if t_fine != 0:
			ArenaFrameProbe.add(&"bt_finish", t_fine)
	return out


static func _decide(pending: Array[int], minds: Array) -> void:
	var jobs: Array = []
	for i in pending:
		jobs.append(minds[i])
	var world: ArenaBots.World = (jobs[0] as ArenaBots.Mind).t_world
	var started := Time.get_ticks_usec()
	if jobs.size() < MIN_BOTS or not world.par_begin():
		for mind: ArenaBots.Mind in jobs:
			mind.t_intent = mind.brain.think(mind.t_me, mind.t_world, mind.t_world.now())
	else:
		# Native (godot-rust) brain state may only be touched on the main thread: brains that think
		# on workers move into script first (a no-op once they are).
		for mind: ArenaBots.Mind in jobs:
			if mind.brain.has_method(&"leave_native"):
				mind.brain.leave_native()
		var run := new()
		par_ticks += 1
		run._jobs = jobs
		var helpers := mini(threads, jobs.size() / CHUNK + 1) - 1
		var group := WorkerThreadPool.add_group_task(run._work, helpers, helpers, true, "arena bot brains") if helpers > 0 else -1
		run._work(0)
		if group >= 0:
			WorkerThreadPool.wait_for_group_task_completion(group)
		world.par_end()
	ArenaFrameProbe.add(&"bot_brain", started)


## Takes brains off the shared queue until it is empty.
func _work(_slot: int) -> void:
	while true:
		_lock.lock()
		var from := _next
		_next += CHUNK
		_lock.unlock()
		if from >= _jobs.size():
			return
		for j in range(from, mini(from + CHUNK, _jobs.size())):
			var mind: ArenaBots.Mind = _jobs[j]
			(mind.t_world as ArenaBots.World).par_job(j)
			mind.t_intent = mind.brain.think(mind.t_me, mind.t_world, mind.t_world.now())
