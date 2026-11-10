extends Node

## A shot builds no node once the warm-up has run. This runs the client's warm-up
## (`ArenaClient._prewarm_tick` phase 1) on the local player's `AwShotFx`, fires every weapon
## class several times, plays impacts, and counts nodes entering the tree by the shot: zero.

const CLASSES: Array[StringName] = [
	AwWeaponSound.LIGHT, AwWeaponSound.MAGNUM, AwWeaponSound.SMG, AwWeaponSound.RIFLE, AwWeaponSound.HEAVY,
	AwWeaponSound.SNIPER, AwWeaponSound.SHOTGUN, AwWeaponSound.MINIGUN, AwWeaponSound.LAUNCHER,
]

var _checks := 0
var _failed := 0
var _added: Array[String] = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	if not condition or OS.get_environment("VERBOSE") != "":
		print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _on_added(node: Node) -> void:
	_added.append("%s(%s)" % [node.name, node.get_class()])


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## The client's own warm-up for flashes (ArenaClient._prewarm_tick, phase 1), without the gate.
func _warm(cam: Camera3D, host: AwShotFx) -> void:
	DotMuzzleFlash.pin_scenes(1 << 30)
	var rig: Node3D = DotMuzzleFlash.prewarm(cam)
	for category in ["pistol", "smg", "rifle", "shotgun"]:
		for fp in [true, false]:
			DotWeaponMuzzle.warm(host, category, null, fp)
	var waited := 0
	while not DotWeaponMuzzle.warm_done() and waited < 600:
		await get_tree().process_frame
		waited += 1
	await _frames(4)
	if rig != null:
		rig.queue_free()
	await _frames(2)


func _run() -> void:
	DotMuzzleFlash.force_available = true
	var world := Node3D.new()
	add_child(world)
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.current = true
	cam.position = Vector3(0, 1.6, 0)
	var fx := AwShotFx.new()
	fx.first_person = true
	world.add_child(fx)
	await _frames(2)
	await _warm(cam, fx)

	get_tree().node_added.connect(_on_added)
	var worst_ms := 0.0
	for round in 3:
		for weapon_class in CLASSES:
			_added.clear()
			var at := Transform3D(Basis.IDENTITY, Vector3(0.2, 1.5, -0.6))
			var t0 := Time.get_ticks_usec()
			fx.call(&"_flash", at, 1.0, weapon_class, &"", true)
			var ms := (Time.get_ticks_usec() - t0) / 1000.0
			worst_ms = maxf(worst_ms, ms)
			var made := _added.size()
			_check(made == 0, "round %d: a %s shot's flash builds no node" % [round, weapon_class], "%d: %s (%.1f ms)" % [made, _added.slice(0, 4), ms])
			await _frames(6)
		_added.clear()
		for i in 4:
			fx.play_impact(Vector3(1.0 + i, 1.0, -8.0), Vector3.BACK, null)
		_check(_added.is_empty(), "round %d: impacts build no node" % round, "%d: %s" % [_added.size(), _added.slice(0, 4)])
		await _frames(30)
	get_tree().node_added.disconnect(_on_added)
	await _ragdoll()
	print("  worst flash call %.2f ms" % worst_ms)
	print("headless_shot_nodes: %d checks, %d failed" % [_checks, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


## A death's first body: the yard's prewarm makes and drops one stock body (no signal, no sound, none left), and a real spawn after it builds the same nodes.
func _ragdoll() -> void:
	var yard := DotPlayerRagdolls.new()
	add_child(yard)
	var spawned := [0]
	var _c := yard.spawned.connect(func(_r: DotPlayerRagdoll) -> void: spawned[0] += 1)
	var t0 := Time.get_ticks_usec()
	yard.prewarm()
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	await _frames(1)
	_check(yard.get_child_count() > 0, "the prewarm built a body in the yard", str(yard.get_child_count()))
	for i in 6:
		await get_tree().physics_frame
	await _frames(2)
	_check(yard.get_child_count() == 0, "and dropped it: nothing is left in the yard", str(yard.get_child_count()))
	_check(spawned[0] == 0, "and announced nothing", str(spawned[0]))
	print("  ragdoll prewarm call %.2f ms" % ms)
	yard.queue_free()
