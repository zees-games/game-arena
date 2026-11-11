extends RefCounted

## Two steps of the net suite's flight windows that touch only the clients and the queue they are given.


## Every client plays [param tick] with its own command, the receive timeline walked on by hand.
static func client_step(clients: Dictionary, commands: Dictionary, tick: int) -> void:
	# The receive timeline walks with the clock (`DotNetClock.advance` does it in the game);
	# ticks set by hand skip that, and the view lag would then grow by one on every tick
	# without a snapshot, which no client's does. dot-net has no public step for this.
	for peer_id in clients:
		var walked: DotNetClock = clients[peer_id]["net"].clock
		walked._received_tick = maxi(walked._received_tick, tick - 1)
	for peer_id in clients:
		var pair2: Array = commands[peer_id]
		clients[peer_id]["net"].clock.tick = tick
		clients[peer_id]["bridge"].client_tick(tick, pair2[0], pair2[1])


## Hands every queued snapshot to the client it is for, and empties the queue.
static func deliver_downstream(clients: Dictionary, downstream: Array) -> void:
	for entry_down in downstream:
		var peer: int = entry_down["peer"]
		var targets: Array = clients.keys() if peer == 0 else [peer]

		for target in targets:
			if clients.has(target):
				clients[target]["bridge"].receive_snapshot(entry_down["bytes"])

	downstream.clear()
