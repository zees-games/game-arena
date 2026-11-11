extends "lossy_base.gd"

const EXPECTED_CHECKS := 14
const MAP := &"crackhouse"

## A pane the server's shot breaks breaks on a real client too: a real `DotServer` running `ArenaModule` and a real ENet
## client in one process (as headless_lossy), no loss. The server's game changes to a converted dm world, the client follows
## it, a DotShot goes through the server game's `_resolve_shot`, and the client's copy of that pane (the same `model`) breaks
## from the PANE_BROKEN event alone: its own pane is not `authoritative`.


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		print("FAIL: watchdog, the suite took over 300 s")
		get_tree().quit(1))


func _panes_under(root: Node) -> Array[Node3D]:
	var out: Array[Node3D] = []
	for pane in get_tree().get_nodes_in_group(&"dot_map_glass"):
		if root.is_ancestor_of(pane) and String(pane.get(&"kind")).begins_with("glass"):
			out.append(pane as Node3D)
	return out


func _box(pane: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for cs in pane.get_children():
		if cs is CollisionShape3D and (cs as CollisionShape3D).shape is ConvexPolygonShape3D:
			for p in ((cs as CollisionShape3D).shape as ConvexPolygonShape3D).points:
				var q: Vector3 = pane.global_transform * p
				box = AABB(q, Vector3.ZERO) if first else box.expand(q)
				first = false
	return box


func _broken_count(panes: Array[Node3D]) -> int:
	var n := 0
	for pane in panes:
		n += 1 if bool(pane.call(&"is_broken")) else 0
	return n


func _by_model(panes: Array[Node3D], model: int) -> Node3D:
	for pane in panes:
		if int(pane.get(&"model")) == model:
			return pane
	return null


func _run() -> void:
	print("game-fatal-contact: a broken pane over a real server and a real client")
	DotPaths.remove_tree(DATA)
	Engine.physics_ticks_per_second = TICK_RATE
	var ok := await _boot()
	var a: Dictionary = {}
	if ok:
		a = await _connect_client("A", _server.config.effective_enet_port())
		ok = _check(a.get("bridge") != null and int(a["session"]) != 0, "a client connects over ENet", str(a.get("error", "")))
	if ok:
		_clients["A"] = a
		ok = await _body(a)
	await _teardown()
	DotPaths.remove_tree(DATA)
	_report_sections(_entered, _completed, 2, EXPECTED_CHECKS)


func _teardown() -> void:
	for label in _clients:
		var link: DotClientLink = _clients[label]["link"]
		if link != null and is_instance_valid(link):
			link.disconnect_from_server("test over")
	await get_tree().process_frame
	for label in _clients:
		var side: Node = _clients[label]["side"]
		if side != null and is_instance_valid(side):
			remove_child(side)
			side.queue_free()
	_clients.clear()
	if _relay != null:
		_relay.stop()
	await get_tree().process_frame
	if _server != null and is_instance_valid(_server):
		_server.shutdown("test over")
	if _server_side != null and is_instance_valid(_server_side):
		remove_child(_server_side)
		_server_side.queue_free()
	await get_tree().process_frame


func _body(a: Dictionary) -> bool:
	_section("the server breaks a pane and the client's copy breaks")
	var a_game: ArenaGame = a["game"]
	var map := ArenaMap.by_id(MAP)
	# A bare ArenaGame stands for the client: the real client loads the map itself (fetch, then `change_map`), the wire
	# carries only what happens in it.
	if not _check(map != null and _game.change_map(map).ok and a_game.change_map(map).ok, "both ends move to crackhouse"):
		_done()
		return false
	var followed := await _until(func() -> bool: return a_game.map != null and a_game.map.id == MAP \
			and not _panes_under(a["side"]).is_empty(), RELIABLE_SECONDS)
	var server_panes := _panes_under(_server_side)
	var client_panes := _panes_under(a["side"])
	if not _check(followed and not server_panes.is_empty() and server_panes.size() == client_panes.size(),
			"both ends build the same panes", "server %d client %d, client map %s, %d glass in the tree, A's game is %s" % [server_panes.size(), client_panes.size(),
					str(a_game.map.id) if a_game.map != null else "none", get_tree().get_nodes_in_group(&"dot_map_glass").size(),
					str(a_game.get_path())]):
		_done()
		return false
	_check(_broken_count(server_panes) == 0 and _broken_count(client_panes) == 0, "none starts broken")

	var trace: DotTrace = _game.combat.trace
	var target: Node3D = null
	var origin := Vector3.ZERO
	var dir := Vector3.ZERO
	for pane in server_panes:
		var box := _box(pane)
		if box.size == Vector3.ZERO:
			continue
		var axis := 0
		for i in 3:
			if box.size[i] < box.size[axis]:
				axis = i
		for sgn: float in [1.0, -1.0]:
			var d := Vector3.ZERO
			d[axis] = sgn
			var o: Vector3 = box.get_center() - d * 1.5
			var hit := trace.ray(o, d, 3.0, [])
			if hit.ok() and hit.collider == pane:
				target = pane
				origin = o
				dir = d
				break
		if target != null:
			break
	if not _check(target != null, "the server's trace stops on a pane"):
		_done()
		return false
	var model := int(target.get(&"model"))
	var mine := _by_model(client_panes, model)
	_check(mine != null and not bool(mine.call(&"is_broken")), "the client has its copy of it, standing", "model %d" % model)

	# The server hooks a pane on its next tick, as it does in a running game.
	await _until(func() -> bool: return target.has_meta(&"arena_watched") and not target.get_signal_connection_list(&"broken").is_empty(), 5.0)
	var shot := DotShot.new()
	shot.origin = origin
	shot.direction = dir
	shot.pellets = [dir]
	shot.damage = 100.0
	shot.max_range = 3.0
	shot.tick = _game.current_tick()
	_game.call(&"_resolve_shot", shot, -1.0)
	_check(bool(target.call(&"is_broken")), "the server's shot breaks the server's pane")
	var told := await _until(func() -> bool: return mine != null and bool(mine.call(&"is_broken")), RELIABLE_SECONDS)
	_check(told, "and the client's copy breaks from the wire")
	_check(_broken_count(client_panes) == 1 and _broken_count(server_panes) == 1, "one pane each, no other",
			"server %d client %d" % [_broken_count(server_panes), _broken_count(client_panes)])
	_check(int(mine.get(&"collision_layer")) == 0, "the client's broken pane leaves the collision layers")
	_done()

	return true
