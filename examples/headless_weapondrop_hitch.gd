extends Node

## The first throw of a weapon must not hitch. Times a spawn and the next physics frames for a cold
## layer (the model is built and measured on the throw) and for one that was prewarmed, on a server
## layer (no drawing) and a client layer (the real model), over a flat floor.
## Checks the prewarmed throw takes a parked body (nothing built) and is not slower than cold.
## Run: [code]godot --headless --path . res://examples/headless_weapondrop_hitch.tscn[/code]

const Wiring := preload("../game/arena_weapon_drop_wiring.gd")
const ArenaWeaponRoles := preload("../game/arena_weapon_roles.gd")

var _checks := 0
var _failed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	Engine.physics_ticks_per_second = 64
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	if not condition or OS.get_environment("VERBOSE") != "":
		print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _floor(root: Node3D) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(80, 1, 80)
	cs.shape = box
	body.add_child(cs)
	root.add_child(body)
	body.position = Vector3(0, -0.5, 0)


func _layer(world: Node3D, draws: bool) -> DotWeaponDrops:
	var layer := DotWeaponDrops.new()
	layer.is_authority = true
	layer.draws = draws
	layer.look_of = Wiring.look
	layer.rules.lifetime = 0.0
	layer.rules.max_count = 0
	world.add_child(layer)
	return layer


func _spawn(layer: DotWeaponDrops, weapon: StringName, at: Vector3) -> float:
	var t0 := Time.get_ticks_usec()
	var _id := layer.spawn({"id": weapon, "magazine": 1, "reserve": 1}, at, Vector3(5, 2, -3), 0)
	return (Time.get_ticks_usec() - t0) / 1000.0


func _frames() -> float:
	var worst := 0.0
	for _i in 3:
		var f0 := Time.get_ticks_usec()
		await get_tree().physics_frame
		worst = maxf(worst, (Time.get_ticks_usec() - f0) / 1000.0)
	return worst


func _run() -> void:
	ArenaWeaponRoles.ensure()
	var ids: Array = AwWeaponArtTable.table().keys()
	ids.sort()
	var weapon: StringName = &"rifle" if ids.has(&"rifle") else ids[0]
	var world := Node3D.new()
	add_child(world)
	_floor(world)
	for draws in [false, true]:
		var label := "client" if draws else "server"
		var cold := _layer(world, draws)
		var c_spawn := _spawn(cold, weapon, Vector3(0, 1, 0))
		var c_frames: float = await _frames()
		var warm := _layer(world, draws)
		warm.prewarm(weapon, 2)
		var parked_before: int = (warm._parked.get(weapon, []) as Array).size()
		var w_spawn := _spawn(warm, weapon, Vector3(3, 1, 0))
		var parked_after: int = (warm._parked.get(weapon, []) as Array).size()
		var w_frames: float = await _frames()
		print("  %s %s: cold spawn %.2f ms (+frames %.2f), prewarmed spawn %.2f ms (+frames %.2f)" % [label, weapon, c_spawn, c_frames, w_spawn, w_frames])
		_check(parked_before == 2, "%s: prewarm parks the bodies" % label, str(parked_before))
		_check(parked_after == 1, "%s: the throw takes a parked body instead of building" % label, str(parked_after))
		_check(w_spawn <= c_spawn + 2.0, "%s: prewarmed spawn not slower than cold" % label, "%.2f vs %.2f" % [w_spawn, c_spawn])
		if not draws:
			var again := _spawn(cold, weapon, Vector3(6, 1, 0))
			print("  server second cold spawn %.2f ms" % again)
			_check(again < 25.0, "server: a second throw of a known weapon builds no model", "%.2f ms" % again)
	# The server's own warm-up (ArenaWeaponDropWiring.build starts it on a layer that draws nothing):
	# afterwards the first throw of any weapon, even one never thrown, builds nothing.
	var served := _layer(world, false)
	await Wiring.warm_server(served, 1000)
	var last: StringName = ids[ids.size() - 1]
	var parked_all := 0
	for id: StringName in ids:
		parked_all += (served._parked.get(id, []) as Array).size()
	_check(parked_all == ids.size(), "warm_server parks one body per weapon", "%d of %d" % [parked_all, ids.size()])
	var first := _spawn(served, last, Vector3(9, 1, 0))
	print("  server first throw of %s after warm_server: %.2f ms" % [last, first])
	_check((served._parked.get(last, []) as Array).is_empty(), "the first throw takes the warmed body")
	_check(first < 25.0, "server: first throw after warm_server is cheap", "%.2f ms" % first)
	print("weapondrop_hitch: %d checks, %d failed" % [_checks, _failed])
	get_tree().quit(1 if _failed > 0 else 0)
