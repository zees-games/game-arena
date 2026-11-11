extends "arena_net_toys.gd"
## Glass panes of a converted map: the server decides when one breaks and tells every client, which only follows.

## Panes only change with a map, so a tick costs O(1) reads: the group's size and the dirty flag a
## map change sets. The pane scan itself runs only when either moved.
var _panes_seen := -1
var _panes_dirty := true
var _panes_game_hooked: Object = null


## Server, every tick: hooks each pane not yet followed (a map change builds new ones).
func _watch_panes() -> void:
	if net == null or not net.is_server or game == null or not is_inside_tree():
		return
	if _panes_game_hooked != game:
		_panes_game_hooked = game
		if game.has_signal(&"map_changed"):
			game.connect(&"map_changed", func(_m: Variant) -> void: _panes_dirty = true)
	var tree := get_tree()
	var props := tree.get_first_node_in_group(&"arena_props")
	if props != null and not props.has_meta(&"arena_watched"):
		props.set_meta(&"arena_watched", true)
		props.connect(&"prop_broke", _on_prop_broke)
	var count := tree.get_node_count_in_group(&"dot_map_glass")
	if count == _panes_seen and not _panes_dirty:
		return
	_panes_seen = count
	_panes_dirty = false
	for pane: Node in tree.get_nodes_in_group(&"dot_map_glass"):
		if pane.has_meta(&"arena_watched"):
			continue
		pane.set_meta(&"arena_watched", true)
		_pane_quiet(pane)
		pane.connect(&"broken", _on_pane_broken.bind(pane))


func _send_event(peer_id: int, kind: int, body: PackedByteArray) -> void:
	call(&"send_event", peer_id, kind, body)


func _on_pane_broken(at: Vector3, _by: StringName, pane: Node) -> void:
	_pane_fx(pane, at)
	_send_event(0, ArenaEvents.Kind.PANE_BROKEN, ArenaEvents.write_taken(int(pane.get("model")), 0))


func _on_prop_broke(material: String, at: Vector3) -> void:
	_burst_at(material, at)
	_send_event(0, ArenaEvents.Kind.PROP_BROKEN, ArenaEvents.write_npc(0, StringName(material), at))


## Client: a prop the server broke.
func _apply_prop_broken(reader: DotNetReader) -> void:
	var told := ArenaEvents.read_npc(reader)
	if bool(told["ok"]) and is_inside_tree():
		_burst_at(String(told["kind_id"]), told["position"])


func _burst_at(material: String, at: Vector3) -> void:
	var fx := get_tree().get_first_node_in_group(&"arena_break_fx") as DotFxBreak
	if fx != null:
		var _n := fx.burst(material, at, Vector3.UP, 1.0)


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
			_pane_quiet(pane)
			pane.call(&"apply_broken")
			_pane_fx(pane, pane.global_position)


## Glass shards and the crack, from dot-fx; the pane's own bare quads are switched off for them.
func _pane_fx(pane: Node, at: Vector3) -> void:
	var fx := get_tree().get_first_node_in_group(&"arena_break_fx") as DotFxBreak if is_inside_tree() else null
	if fx == null:
		return
	fx.burst(String(pane.get(&"kind")), at, Vector3.UP, 1.0)


## The pane's own bare quads would double dot-fx's shards, so they go before it breaks.
func _pane_quiet(pane: Node) -> void:
	if is_inside_tree() and get_tree().get_first_node_in_group(&"arena_break_fx") != null:
		pane.set(&"shard_count", 0)
