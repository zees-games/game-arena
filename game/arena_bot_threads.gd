extends RefCounted

## The bots' brains on worker threads (cvar `bot_threads`, default [method auto_threads]; 0 = off: the stock one-bot-at-a-time loop).
##
## A tick of bot commands is three steps (see [method ArenaBots.think_begin]): per bot on the main thread the
## snapshot (the world's contacts, taken once per tick) and the bookkeeping; the brains' decisions, which read
## that snapshot and write one [DotBotIntent] each, split over [member threads] threads (the main thread is
## one); per bot on the main thread the commands from the intent (ride steering, throw, view limits). The
## motor and the weapons run after, on the main thread, from the commands this returns.
##
## The brains touch no node: sight and wall rays go to the physics space with queries of their own, routes and
## waypoints take the world's lock (see [member ArenaBots.World.par]). A brain is only its bot's, so the
## answers do not depend on which thread runs which bot.

const ArenaBots := preload("arena_bots.gd")
const ArenaFrameProbe := preload("arena_frame_probe.gd")

## Fewer bots than this think on the main thread: the hand-off costs more than it saves.
const MIN_BOTS := 8

## Brains per grab from the shared queue.
const CHUNK := 4

## Threads that decide (the main thread is one); 0 and 1 think on the main thread. On by default
## ([method auto_threads]): the brains decide the same on any count (headless_botthreads), and on a
## 16v16 the parallel brains take about a quarter off the bots' share of the tick.
static var threads: int = auto_threads()

## Most threads the default takes: past this the hand-off and the world's lock eat the gain.
const AUTO_MAX := 4

## Ticks whose brains went through the worker path (for the suite).
static var par_ticks: int = 0

var _jobs: Array = []
var _next := 0
var _lock := Mutex.new()


## The default [member threads]: the cores but one (for the render and the engine), at most
## [constant AUTO_MAX]; 0 where there are no threads (web without them) or one or two cores.
static func auto_threads() -> int:
	if not DotPlatform.has_threads():
		return 0
	var n := mini(OS.get_processor_count() - 1, AUTO_MAX)
	return n if n >= 2 else 0


## Whether [param bot_count] bots go through [method think_all] this tick.
static func active(bot_count: int) -> bool:
	return threads > 0 and bot_count >= MIN_BOTS and DotPlatform.has_threads()


## [move, fire] per bot, in order, as [method ArenaBots.think] gives each one. [param players] and
## [param minds] are parallel arrays.
static func think_all(game: Object, players: Array, minds: Array, tick: int, tick_rate: float) -> Array:
	var out: Array = []
	out.resize(players.size())
	var pending: Array[int] = []
	for i in players.size():
		var early := ArenaBots.think_begin(game, players[i], minds[i], tick, tick_rate)
		if early.is_empty():
			pending.append(i)
		else:
			out[i] = early
	if not pending.is_empty():
		_decide(pending, minds)
		for i in pending:
			out[i] = ArenaBots.think_finish(game, players[i], minds[i], tick, tick_rate)
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
