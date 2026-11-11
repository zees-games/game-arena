extends DotGameCheckSuite

const ArenaMap := preload("../maps/arena_map.gd")

const EXPECTED_CHECKS := 10
const MAP := &"crackhouse"

## A hitscan shot breaks a glass pane of a converted dm world in the running game: the pane is on the shot layer, the shot
## goes through the game's own `_resolve_shot` (dot-combat's pellet trace, `Hit.collider`), the pane breaks and the shot
## carries on through, and no other pane breaks.
var _client: Node = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


## An offline client with an instant match. Its bots are scripted (no brain) as soon as they exist, so no stray shot breaks a pane.
func _start_client() -> Object:
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("mouse_capture_override", true)
	add_child(_client)
	var gm: Object = null
	while gm == null or gm.match_node == null:
		await _wait(0.1)
		gm = _client.get("game")
	gm.match_node.rules.warmup_sec = 0.0
	gm.match_node.rules.countdown_sec = 0.0
	gm.match_node.rules.min_players = 1
	return gm


## The pane's box in world space, from its hulls.
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


func _script_bots() -> void:
	var bots: Dictionary = _client.get("_bots")
	for id in bots:
		bots[id].set_meta(&"bot_scripted", true)


func _panes() -> Array[Node]:
	return get_tree().get_nodes_in_group(&"dot_map_glass")


func _broken_count() -> int:
	var n := 0
	for pane in _panes():
		n += 1 if bool(pane.call(&"is_broken")) else 0
	return n


func _run() -> void:
	var gm: Object = await _start_client()
	var map := ArenaMap.by_id(MAP)
	_check(map != null and gm.change_map(map).ok, "the game moves to crackhouse")
	var live := false
	var me: Object = null
	for i in 1200:
		await _wait(0.1)
		_script_bots()
		me = _client.get("player")
		if me != null and me.is_alive() and gm.match_node.state == DotMatch.State.LIVE and gm.map != null and gm.map.id == MAP:
			live = true
			break
	var seen := "state %d map %s" % [int(gm.match_node.state), str(gm.map.id) if gm.map != null else "-"]
	if not _check(live, "the offline match is live on crackhouse", seen):
		_report(EXPECTED_CHECKS)
		return
	await _wait(0.5)

	var glass: Array[Node3D] = []
	for pane in _panes():
		if String(pane.get(&"kind")).begins_with("glass"):
			glass.append(pane as Node3D)
	_check(glass.size() > 0, "the world's breakable glass is built as panes", "%d glass of %d" % [glass.size(), _panes().size()])
	_check(_broken_count() == 0, "no pane starts broken")

	var trace: DotTrace = gm.combat.trace
	var target: Node3D = null
	var origin := Vector3.ZERO
	var dir := Vector3.ZERO
	var box := AABB()
	for pane in glass:
		box = _box(pane)
		if box.size == Vector3.ZERO:
			continue
		var axis := 0
		for a in 3:
			if box.size[a] < box.size[axis]:
				axis = a
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
	if not _check(target != null, "the game's shot trace stops on a glass pane (Hit.collider is the pane)"):
		_report(EXPECTED_CHECKS)
		return

	var shot := DotShot.new()
	shot.origin = origin
	shot.direction = dir
	shot.pellets = [dir]
	shot.damage = 100.0
	shot.max_range = 3.0
	shot.tick = int(gm.get(&"_tick"))
	gm.call(&"_resolve_shot", shot, -1.0)
	_check(bool(target.call(&"is_broken")), "a shot through the game's resolve breaks it", str(target.get(&"kind")))
	var end: Vector3 = shot.impacts.back() if not shot.impacts.is_empty() else origin
	var past := (end - box.get_center()).dot(dir)
	_check(past > 0.05, "and the shot carries on through", "%.2f m past the pane" % past)
	_check(_broken_count() == 1, "no other pane breaks", "%d broken" % _broken_count())

	await get_tree().physics_frame
	await get_tree().physics_frame
	var again := trace.ray(origin, dir, 3.0, [])
	_check(not again.ok() or again.collider != target, "a broken pane no longer stops a shot")
	_check(int(target.get(&"collision_layer")) == 0, "and it leaves every collision layer")
	_report(EXPECTED_CHECKS)
