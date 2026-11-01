extends "arena_net_toys.gd"
## Glass panes of a converted map: the server decides when one breaks and tells every client, which only follows.

## Server, every tick: hooks each pane not yet followed (a map change builds new ones).
func _watch_panes() -> void:
	if net == null or not net.is_server or game == null or not is_inside_tree():
		return
	for pane: Node in get_tree().get_nodes_in_group(&"dot_map_glass"):
		if pane.has_meta(&"arena_watched"):
			continue
		pane.set_meta(&"arena_watched", true)
		pane.connect(&"broken", _on_pane_broken.bind(pane))


func _send_event(peer_id: int, kind: int, body: PackedByteArray) -> void:
	call(&"send_event", peer_id, kind, body)


func _on_pane_broken(_at: Vector3, _by: StringName, pane: Node) -> void:
	_send_event(0, ArenaEvents.Kind.PANE_BROKEN, ArenaEvents.write_taken(int(pane.get("model")), 0))


## Tells a joiner which panes are already gone.
func _send_panes_signon(peer_id: int) -> void:
	if not is_inside_tree():
		return
	for pane: Node in get_tree().get_nodes_in_group(&"dot_map_glass"):
		if bool(pane.call(&"is_broken")):
			_send_event(peer_id, ArenaEvents.Kind.PANE_BROKEN, ArenaEvents.write_taken(int(pane.get("model")), 0))


## Client: the host's word that a pane broke. This end never decides, so it stops deciding.
func _apply_pane_broken(reader: DotNetReader) -> void:
	var told := ArenaEvents.read_taken(reader)
	if not bool(told["ok"]) or not is_inside_tree():
		return
	for pane: Node in get_tree().get_nodes_in_group(&"dot_map_glass"):
		if int(pane.get("model")) == int(told["id"]):
			pane.set(&"authoritative", false)
			pane.call(&"apply_broken")
