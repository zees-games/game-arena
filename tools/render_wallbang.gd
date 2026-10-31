extends SceneTree

## A rifle round through a thin wall: frames of the entry face, the exit face and a side view
## of both holes. The look no assertion gives: do the decals sit on the surfaces, not in them?
##
##     tools/render_wallbang.sh [map]       # frames in screenshots/wallbang/

const ArenaPresentation := preload("../game/arena_presentation.gd")
const OUT_DIR := "res://screenshots/wallbang"

var client: Node = null
var _map := "dm_atrium"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--map")
	if at >= 0 and at + 1 < args.size():
		_map = args[at + 1]
	var _scratch := ArenaPresentation.use_scratch_settings("render_wallbang")
	client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	client.set("offline_bots", 0)
	root.add_child(client)
	_run.call_deferred()


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	return root.world_3d.direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, 0xFFFFFFFF))


func _spot(game) -> Dictionary:
	for spawn: Transform3D in game.map.spawns:
		var foot: Vector3 = spawn.origin
		for n in 16:
			var dir := Vector3(sin(n * TAU / 16.0), 0.0, cos(n * TAU / 16.0))
			if _ray(foot + Vector3.UP, foot + Vector3.UP + dir * 6.0).is_empty():
				return {"me": foot, "dir": dir}
	return {}


func _shot(me, foot: Vector3, face: Vector3, name: String) -> void:
	# The client owns the current camera, so move the player rather than a spare camera.
	var d := face - (foot + Vector3.UP * 1.5)
	me.controller.teleport(foot, atan2(-d.x, -d.z), asin(clampf(d.normalized().y, -1.0, 1.0)))
	await _wait(0.5)
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path("%s/%s_%s.png" % [OUT_DIR, _map, name]))


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var game = client.get("game")
	for i in range(80):
		await _wait(0.25)
		if game != null and game.map != null and client.get("player") != null:
			break
	var _changed = game.change_map(load("res://maps/arena_map.gd").by_id(StringName(_map)))
	await _wait(3.0)
	var gate: Variant = client.get("gate")
	for i in 240:
		if gate == null or (gate as Object).call(&"is_open"):
			break
		await _wait(0.5)
	var me = client.get("player")
	me.health.invulnerable = true
	var spot := _spot(game)
	if spot.is_empty():
		print("FAIL no spot")
		quit(1)
		return
	var dir: Vector3 = spot["dir"]
	dir = Vector3(signf(dir.x), 0.0, 0.0) if absf(dir.x) > absf(dir.z) else Vector3(0.0, 0.0, signf(dir.z))
	if _ray(spot["me"] + Vector3.UP, spot["me"] + Vector3.UP + dir * 6.0).size() > 0:
		dir = spot["dir"].normalized()
	var eye: Vector3 = spot["me"] + Vector3.UP * 1.5
	var yaw := atan2(-dir.x, -dir.z)
	me.controller.teleport(spot["me"], yaw, 0.0)
	var size := Vector3(4.0, 3.0, 0.2) if absf(dir.z) > 0.5 else Vector3(0.2, 3.0, 4.0)
	var center: Vector3 = spot["me"] + dir * 3.0 + Vector3.UP * 1.5
	game.combat.trace.add_box(AABB(center - size * 0.5, size), &"concrete")
	var wall := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	wall.mesh = mesh
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = size
	col.shape = box_shape
	body.add_child(col)
	wall.add_child(body)
	root.add_child(wall)
	wall.global_position = center
	await _wait(0.3)

	var round_of = me.arsenal.round_for(&"rifle")
	me.give_default_loadout()
	round_of = me.arsenal.round_for(&"rifle")
	var shot := DotShot.make(&"rifle", me.player_id, game.current_tick(), 0)
	shot.origin = eye
	shot.direction = dir
	shot.damage = 20.0
	shot.penetration = round_of.make_penetration() if round_of != null else null
	shot.scatter()
	game.combat.set_authoritative_origin(me.player_id, eye)
	var res: DotShot = game.combat.resolve_shot(shot)
	var pres = client.get("presentation")
	var made: int = pres.fx.spawn_penetration_decals(shot.penetrations)
	print("decals=%d" % made)
	if shot.penetrations.is_empty() or made < 2:
		print("FAIL no wallbang")
		quit(1)
		return
	await _wait(0.3)
	var entry: Vector3 = shot.penetrations[0]["entry"]
	var exit_p: Vector3 = shot.penetrations[0]["exit"]
	var side := dir.cross(Vector3.UP).normalized()
	var foot: Vector3 = spot["me"]
	await _shot(me, foot, entry, "entry")
	var past: Vector3 = exit_p + dir * 1.5 + side * 0.3
	past.y = foot.y
	await _shot(me, past, exit_p, "exit")
	var beside: Vector3 = (entry + exit_p) * 0.5 + side * 1.5 - dir * 0.8
	beside.y = foot.y
	await _shot(me, beside, (entry + exit_p) * 0.5, "side")
	quit(0)
