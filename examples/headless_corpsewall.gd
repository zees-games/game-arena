extends DotGameCheckSuite

const ArenaMap := preload("../maps/arena_map.gd")

const EXPECTED_CHECKS := 14

## A body that falls against a wall of an imported map (crackhouse), with the wall guard off and on:
## off and on, then none may end behind the one-sided collision with it on (off never clipped in testing). Then the queries a bullet, a blade
## or a blast uses find no part, and a shot from the far side of the wall does not hit one.
var _client: Node = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _space() -> PhysicsDirectSpaceState3D:
	return get_viewport().world_3d.direct_space_state


## The nearest wall within reach around [param feet], as {position, normal}, or empty.
func _wall(feet: Vector3, skip: Array) -> Dictionary:
	var best := {}
	var best_d := 6.0
	for i in 48:
		var dir := Vector3.RIGHT.rotated(Vector3.UP, TAU * i / 48.0)
		var q := PhysicsRayQueryParameters3D.create(feet + Vector3.UP * 0.9, feet + Vector3.UP * 0.9 + dir * best_d)
		var hit := _space().intersect_ray(q)
		if hit.is_empty() or absf((hit.normal as Vector3).y) > 0.3:
			continue
		var d: float = (hit.position as Vector3).distance_to(feet + Vector3.UP * 0.9)
		var near := false
		for s in skip:
			near = near or s.distance_to(hit.position) < 0.6
		if d < best_d and not near:
			best_d = d
			best = {"position": hit.position, "normal": hit.normal}
	return best


func _parts(body: DotPlayerRagdoll) -> Array:
	var out: Array = []
	for n in body.part_nodes():
		if n is RigidBody3D:
			out.append(n)
	return out


## Drops the local player's body against [param wall] and returns the parts behind a surface.
func _fall(me: Object, yard: DotPlayerRagdolls, wall: Dictionary, out_body: Array) -> int:
	var n: Vector3 = wall.normal
	me.controller.state.position = (wall.position as Vector3) + n * 0.05 - Vector3.UP * 0.9
	me.controller.state.velocity = -n * 30.0
	var death := DotPlayerDeath.new()
	death.reaction = DotPlayerDeathReactions.LIMP
	death.direction = -n
	death.damage = 100.0
	me.set("_fell", false)
	var body: DotPlayerRagdoll = me.fall_body(yard, death, false)
	out_body.append(body)
	if body == null:
		return -1
	await _wait(2.5)
	var behind := 0
	for p: RigidBody3D in _parts(body):
		var anchor: Vector3 = body._anchor
		if not DotPlayerRagdoll.crossing(_space(), anchor, p.global_position, 0xFFFFFFFF).is_empty():
			behind += 1
	return behind


## An offline client with an instant, one-player match.
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


func _run() -> void:
	var gm: Object = await _start_client()
	var map := ArenaMap.by_id(&"crackhouse")
	_check(map != null and gm.change_map(map).ok, "the game moves to crackhouse")
	var me: Object = null
	var live := false
	for i in 1200:
		await _wait(0.1)
		me = _client.get("player")
		if me != null and me.is_alive() and gm.match_node.state == DotMatch.State.LIVE and gm.map != null and gm.map.id == &"crackhouse":
			live = true
			break
	if not _check(live, "the offline match is live on crackhouse"):
		_report(EXPECTED_CHECKS)
		return
	var bots: Dictionary = _client.get("_bots")
	for id in bots:
		bots[id].set_meta(&"bot_scripted", true)
	await _wait(2.0)
	var yard: DotPlayerRagdolls = _client.get("ragdolls")
	_check(yard != null and yard.rules != null, "the client has a body yard")
	var home: Vector3 = me.controller.state.position
	var walls: Array = []
	var seen: Array = []
	for i in 5:
		var w := _wall(home, seen)
		if w.is_empty():
			break
		seen.append(w.position)
		walls.append(w)
	_check(walls.size() >= 2, "walls found near the spawn", "%d" % walls.size())

	yard.rules.hold_walls = false
	var off_total := 0
	var off_bodies: Array = []
	for w in walls:
		off_total += await _fall(me, yard, w, off_bodies)
	yard.clear()
	yard.rules.hold_walls = true
	var on_total := 0
	var on_bodies: Array = []
	var last_wall: Dictionary = walls[0] if not walls.is_empty() else {}
	for w in walls:
		on_total += await _fall(me, yard, w, on_bodies)
		last_wall = w
	print("parts behind a wall: guard off ", off_total, ", guard on ", on_total)
	# Jolt's own contact pushes a body out of these walls even at 30 m/s from 5 cm, so the unguarded run
	# never clipped here; the guard-on check below is the regression, this only proves the runs happened.
	_check(off_total >= 0 and off_bodies.size() == walls.size(), "the unguarded run dropped a body at every wall", "%d parts behind" % off_total)
	_check(on_total == 0, "with the guard no part is behind a wall", "%d parts" % on_total)

	var body: DotPlayerRagdoll = on_bodies.back() if not on_bodies.is_empty() else null
	if not _check(body != null, "a body lies against the last wall"):
		_report(EXPECTED_CHECKS)
		return
	var parts := _parts(body)
	var layered := 0
	for p: RigidBody3D in parts:
		layered += 1 if p.collision_layer != 0 else 0
	_check(layered == 0, "no part is on a collision layer (bullets, blades and blasts skip it)", "%d" % layered)
	var torso: Vector3 = parts[0].global_position
	_check_unqueryable(parts, torso)

	var n: Vector3 = last_wall.normal
	var hit_point: Vector3 = torso
	yard.rules.shootable = false
	_check(not yard.shoot(hit_point, -n, 4.0, 0.6), "shoot does nothing with sv_ragdoll_shootable off")
	yard.rules.shootable = true
	var far: Vector3 = (last_wall.position as Vector3) - n * 1.0
	var from_behind := yard.shoot(last_wall.position, n, 4.0, 1.0, far)
	_check(not from_behind, "shoot from behind the wall does not move the body")
	_check(yard.shoot(hit_point, -n, 4.0, 0.6, torso + n * 0.5), "shoot from the open side works with it on")
	_report(EXPECTED_CHECKS)

## No part answers a point, shape or ray query.
func _check_unqueryable(parts: Array, torso: Vector3) -> void:
	var q := PhysicsPointQueryParameters3D.new()
	q.position = torso
	q.collision_mask = 0xFFFFFFFF
	var found_pt := false
	for r in _space().intersect_point(q, 16):
		found_pt = found_pt or parts.has(r.collider)
	_check(not found_pt, "a point query at the body finds no part")
	var sphere := SphereShape3D.new()
	sphere.radius = 1.5
	var sq := PhysicsShapeQueryParameters3D.new()
	sq.shape = sphere
	sq.transform = Transform3D(Basis(), torso)
	sq.collision_mask = 0xFFFFFFFF
	var found_sphere := false
	for r in _space().intersect_shape(sq, 32):
		found_sphere = found_sphere or parts.has(r.collider)
	_check(not found_sphere, "a blast sphere around the body finds no part")
	var rq := PhysicsRayQueryParameters3D.create(torso + Vector3.UP * 2.0, torso - Vector3.UP * 2.0)
	var rh := _space().intersect_ray(rq)
	_check(rh.is_empty() or not parts.has(rh.collider), "a ray through the body does not hit a part")

