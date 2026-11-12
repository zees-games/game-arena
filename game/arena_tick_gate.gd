extends RefCounted

## Work heard between ticks that queries the physics space, held for the next server tick.
##
## [b]Why.[/b] A server owner may run physics on its own thread (`physics/3d/run_on_separate_thread`,
## or Jolt) through an `override.cfg`. Then a ray or shape query is safe only inside the physics
## step, and console lines, chat commands, admin actions and the map sync's peer reports all
## arrive in the idle frame. A respawn's spawn sight (`combat.trace`, the physics space on an
## imported map) or a map change's respawns there would race the step. The rule is dot-physics'
## (`docs/threading.md`): a handler queues, and the next tick answers.
##
## [b]Armed only by [code]ArenaModule[/code][/b]; `ArenaNetBridge.server_tick` (the dedicated
## server's tick, from the module's `_physics_process`) calls [method open] first. Unarmed (solo, a client, a suite driving a bare
## game) everything runs at once, as before. Inside a physics frame it runs at once too: a vote
## clock or a match end is already in the tick.
##
## [codeblock]
## game.tick_gate.run(func() -> void: game.start(game.current_tick()))
## await game.tick_gate.reached()   # the coroutine resumes inside the next tick
## [/codeblock]

## Emitted by [method open] after the queued calls ran; an awaiting [method reached] resumes here.
signal opened

## True on a server whose tick calls [method open]. Off: [method run] and [method reached] never wait.
var armed := false

## Whether this is the physics step; a suite stands in for the engine's answer.
var in_step: Callable = func() -> bool: return Engine.is_in_physics_frame()

var _calls: Array[Callable] = []


## Runs [param fn] now when this is the tick (or the gate is unarmed), else at the top of the next tick.
func run(fn: Callable) -> void:
	if not waits():
		fn.call()
		return
	_calls.append(fn)


## A coroutine: returns at once in the tick or unarmed, else resumes inside the next tick.
func reached() -> void:
	if waits():
		await opened


## Whether a call made now would wait for the next tick.
func waits() -> bool:
	return armed and not bool(in_step.call())


## How many calls are queued for the next tick.
func pending() -> int:
	return _calls.size()


## The top of a server tick: the queued calls in arrival order, then whoever awaits [method reached].
func open() -> void:
	if not _calls.is_empty():
		var calls := _calls
		_calls = []
		for fn: Callable in calls:
			if fn.is_valid():
				fn.call()
	opened.emit()


## The server is going away: nothing queued runs, and whoever awaits [method reached] goes on now.
func disarm() -> void:
	armed = false
	_calls.clear()
	opened.emit()
