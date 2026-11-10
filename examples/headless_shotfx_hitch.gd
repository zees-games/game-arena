extends Node

## Somebody else's first shot must not build an audio stack: the presentation hands every remote
## hand its one shot player (`ArenaPresentation.share_shots`). Times the first shot of 31
## shooters on hands that share it and that do not, and checks the real client wires its bots' hands.

const SHOOTERS := 31
const ArenaPresentation := preload("../game/arena_presentation.gd")

var _checks := 0
var _failed := 0
var _build_ms := 0.0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	if not condition or OS.get_environment("VERBOSE") != "":
		print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _nodes() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))


## What a world model does on its hand's first shot: make the effects node, then play. Returns ms.
func _fire(hand: Node3D, id: StringName) -> float:
	var t0 := Time.get_ticks_usec()
	var fx: AwShotFx = hand.get_node_or_null("ShotFx")
	if fx == null:
		fx = AwShotFx.new()
		fx.name = "ShotFx"
		hand.add_child(fx)
	fx.play_remote(AwWeaponNet.KIND_SHOT, Transform3D(Basis.IDENTITY, hand.position), Vector3.FORWARD, id)
	return (Time.get_ticks_usec() - t0) / 1000.0


func _layers(hand: Node) -> int:
	var count := 0
	for child in (hand.get_node("ShotFx") as Node).get_children():
		if child is AwShotLayers:
			count += 1
	return count


## [param shared] hands get the presentation's player, the way the client wires its remote players.
func _volley(world: Node3D, p: ArenaPresentation, shared: bool) -> Dictionary:
	var ids: Array[StringName] = [&"rifle", &"pistol", &"smg", &"shotgun"]
	var worst := 0.0
	var total := 0.0
	var layered := 0
	var nodes := 0
	for i in SHOOTERS:
		var hand := Node3D.new()
		world.add_child(hand)
		hand.position = Vector3(float(i % 8) * 3.0 - 10.0, 1.2, -6.0 - float(i / 8) * 4.0)
		if shared:
			p.share_shots(hand)
		var n0 := _nodes()
		var ms := _fire(hand, ids[i % ids.size()])
		nodes += _nodes() - n0
		layered += _layers(hand)
		# The very first shot of the process loads streams for everyone; the rest are what a match's 31 shooters each cost.
		if i > 0:
			worst = maxf(worst, ms)
			total += ms
		await get_tree().process_frame
	return {"worst": worst, "mean": total / float(SHOOTERS - 1), "layered": layered, "nodes": nodes}


func _run() -> void:
	var p := ArenaPresentation.new()
	add_child(p)
	p.setup()
	var world := Node3D.new()
	add_child(world)
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.current = true
	cam.position = Vector3(0, 1.6, 0)
	await get_tree().process_frame

	var own: Dictionary = await _volley(world, p, false)
	var shared: Dictionary = await _volley(world, p, true)
	print("  first shots, one per shooter: own stack worst %.2f mean %.2f ms (%d AwShotLayers, +%d nodes); shared worst %.2f mean %.2f ms (%d AwShotLayers, +%d nodes)" % [
		own.worst, own.mean, own.layered, own.nodes, shared.worst, shared.mean, shared.layered, shared.nodes])
	_check(int(own.layered) == SHOOTERS, "without sharing every shooter builds its own audio stack (the cause)", str(own.layered))
	_check(int(shared.layered) == 0, "with sharing no shooter builds one", str(shared.layered))
	_check(int(shared.nodes) < int(own.nodes), "and a shared volley builds fewer nodes", "%d vs %d" % [shared.nodes, own.nodes])
	_check(p.remote_shot(&"rifle", &"shot", Vector3(0, 1, -5), false), "the presentation plays a rifle's report for another player")
	_check(p.remote_shot(&"pistol", &"shot", Vector3(0, 1, -5), false), "and a pistol's (every stock class is registered)")
	_check(float(shared.mean) < float(own.mean), "and the shared first shot is cheaper", "%.2f vs %.2f ms" % [shared.mean, own.mean])

	# Hands that take their effects from a pool filled under the cover: the first shot builds nothing at all.
	var pool := AwFxPool.new()
	add_child(pool)
	while not pool.fill(SHOOTERS, 2, 2.0):
		await get_tree().process_frame
	await get_tree().process_frame
	var pooled_nodes := 0
	var pooled_worst := 0.0
	for i in SHOOTERS:
		var hand := Node3D.new()
		world.add_child(hand)
		hand.position = Vector3(float(i % 8) * 3.0 - 10.0, 1.2, -6.0 - float(i / 8) * 4.0)
		var held := AwWorldModel.new()
		hand.add_child(held)
		p.share_shots(held)
		var n0 := _nodes()
		var t0 := Time.get_ticks_usec()
		var fx: AwShotFx = held.call(&"_shot_fx")
		fx.play_remote(AwWeaponNet.KIND_SHOT, Transform3D(Basis.IDENTITY, hand.position), Vector3.FORWARD, [&"rifle", &"pistol", &"smg", &"shotgun"][i % 4])
		pooled_worst = maxf(pooled_worst, (Time.get_ticks_usec() - t0) / 1000.0)
		pooled_nodes += _nodes() - n0
		await get_tree().process_frame
	print("  pooled first shots: worst %.2f ms, +%d nodes, %d handed, %d missed" % [pooled_worst, pooled_nodes, pool.handed, pool.missed])
	_check(pooled_nodes == 0, "a pooled first shot creates no node", str(pooled_nodes))
	_check(pool.handed == SHOOTERS and pool.missed == 0, "every hand took its effects from the pool", "%d handed, %d missed" % [pool.handed, pool.missed])
	_check(pooled_worst < float(shared.worst) or pooled_worst < 1.0, "and it is cheaper than building them", "%.2f vs %.2f ms" % [pooled_worst, shared.worst])
	pool.queue_free()

	# The real client: its bots' hands are wired, and their first shot builds no audio stack.
	var client: Node = (load("res://game/arena.tscn") as PackedScene).instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	add_child(client)
	var bots: Dictionary = {}
	for i in 600:
		await get_tree().create_timer(0.1).timeout
		bots = client.get("_bots")
		if bots.size() >= 3:
			break
	_check(bots.size() >= 3, "the offline client has its bots", str(bots.size()))
	await get_tree().create_timer(0.5).timeout
	var wired := 0
	var layered := 0
	for id in bots:
		var held: Node = bots[id].get("held")
		if held == null:
			continue
		var pres: Object = client.get("presentation")
		if pres != null and held.child_entered_tree.is_connected(Callable(pres, &"_share_shots_with")):
			wired += 1
		var fx: Variant = held.call(&"_shot_fx")
		if fx != null and (fx as AwShotFx).shot_sound.is_valid() and not (fx as AwShotFx).layered_shots:
			layered += 1
	_check(wired == bots.size() and wired > 0, "every bot's hand is wired to the presentation's shot player", "%d of %d" % [wired, bots.size()])
	_check(layered == bots.size() and layered > 0, "and its effects, made on the first shot, report through it", "%d of %d" % [layered, bots.size()])
	print("headless_shotfx_hitch: %d checks, %d failed" % [_checks, _failed])
	get_tree().quit(1 if _failed > 0 else 0)
