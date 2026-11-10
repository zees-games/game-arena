extends "arena_net_weapon_drops.gd"
## A solo client owns the server process it plays on: its console lines go up and the answers come
## down here. A public server never sets [member host_line_fn], so the ask is dropped there.

const ArenaHostWire := preload("arena_host_wire.gd")

## Client side: one line of the answer to ask [param seq]; [param done] ends it and [param good] is the result.
signal host_replied(seq: int, done: bool, good: bool, text: String)

## Server side, set only by the solo server process: `(peer_id, seq, line)`.
var host_line_fn: Callable = Callable()
## Server side: the owner paused. The game is not ticked; the link and the snapshots carry on.
var host_paused := false


func send_host_reply(peer_id: int, seq: int, done: bool, good: bool, text: String) -> void:
	_send_event(peer_id, ArenaEvents.Kind.MORE, ArenaHostWire.write_reply(seq, done, good, text))


func _on_host_ask(peer_id: int, reader: DotNetReader) -> void:
	if not host_line_fn.is_valid():
		return
	var asked := ArenaHostWire.read_line(reader)
	if bool(asked["ok"]):
		host_line_fn.call(peer_id, int(asked["seq"]), str(asked["line"]))


func _apply_host_reply(reader: DotNetReader) -> void:
	var r := ArenaHostWire.read_reply(reader)
	if bool(r["ok"]):
		host_replied.emit(int(r["seq"]), bool(r["done"]), bool(r["good"]), str(r["text"]))
