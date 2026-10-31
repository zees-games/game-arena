extends SceneTree

## A rifle round through a thin wall: close-ups of the entry hole, the exit hole and a ricochet mark.
## Each close-up is diffed against the same view without the decal, so a hidden mark fails the run.
##
##     tools/render_wallbang.sh [map]       # frames in screenshots/wallbang/, exit 1 if a mark is invisible

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


## Hides what would stand between a close-up camera and the wall: hands, body, HUD.
func _clear_view(me) -> void:
	for n: Variant in [client.get("view_model"), client.get("view_arms"), me.body_mesh, me.avatar]:
		if n is Node3D:
			(n as Node3D).visible = false
		elif n is CanvasItem:
			(n as CanvasItem).visible = false


func _frame() -> Image:
	return root.get_texture().get_image()


## The player's eye 0.6 m off the wall along the decal's normal, looking at it (the client owns the
## current camera and rewrites a spare one's transform, so the player is moved instead). Returns the diff
## (pixels near the projected centre that change when the decal is hidden), failing the run at zero.
func _closeup(me, decal: Node3D, at: Vector3, normal: Vector3, name: String) -> int:
	_clear_view(me)
	var cam: Camera3D = me.camera
	var eye := at + normal * 0.6
	var look := -normal
	var yaw := atan2(-look.x, -look.z)
	me.controller.teleport(eye - Vector3.UP * 1.5, yaw, 0.0)
	# The look is the client's sampler's, not the controller's (see arena_client's spawn facing).
	client.get("_sampler").look_at_angles(rad_to_deg(yaw), 0.0)
	await _wait(0.4)
	var with_decal := _frame()
	with_decal.save_png(ProjectSettings.globalize_path("%s/%s_%s.png" % [OUT_DIR, _map, name]))
	decal.visible = false
	await _wait(0.3)
	var bare := _frame()
	decal.visible = true
	var c := cam.unproject_position(at)
	var changed := 0
	for y in range(int(c.y) - 40, int(c.y) + 41):
		for x in range(int(c.x) - 40, int(c.x) + 41):
			if x < 0 or y < 0 or x >= with_decal.get_width() or y >= with_decal.get_height():
				continue
			var d := with_decal.get_pixel(x, y)
			var e := bare.get_pixel(x, y)
			if absf(d.r - e.r) + absf(d.g - e.g) + absf(d.b - e.b) > 0.06:
				changed += 1
	print("closeup %s: %d px differ from the bare wall" % [name, changed])
	return changed


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
	var decals: Array[Node3D] = []
	pres.fx.spawned.connect(func(_id, node, _why) -> void:
		if node is Node3D:
			decals.append(node))
	var made: int = pres.fx.spawn_penetration_decals(shot.penetrations)
	print("decals=%d" % made)
	if shot.penetrations.is_empty() or made < 2:
		print("FAIL no wallbang")
		quit(1)
		return
	# A second round glancing off the exit face, so the "exit" frame holds both marks.
	var side0 := dir.cross(Vector3.UP).normalized()
	var exit0: Vector3 = shot.penetrations[0]["exit"]
	var skim_from := exit0 + dir * 0.8 - side0 * 1.5
	var skim := DotShot.make(&"rifle", me.player_id, game.current_tick(), 1)
	skim.origin = skim_from
	skim.direction = (exit0 + side0 * 0.6 - skim_from).normalized()
	skim.damage = 20.0
	skim.scatter()
	skim.penetration = round_of.make_penetration()
	skim.penetration.ricochet_materials = PackedStringArray(["concrete"])
	skim.penetration.ricochet_angle = 40.0
	game.combat.ricochet_enabled = true
	game.combat.set_authoritative_origin(me.player_id, skim_from)
	var _skim_res: DotShot = game.combat.resolve_shot(skim)
	var made_before := decals.size()
	var bounced: int = pres.fx.spawn_ricochet_decals(skim.ricochets)
	print("ricochet decals=%d" % bounced)
	if bounced < 1:
		print("FAIL no ricochet")
		quit(1)
		return
	await _wait(0.3)
	var pen: Dictionary = shot.penetrations[0]
	var marks := [
		["entry", pen["entry"], pen["entry_normal"], decals[0]],
		["exit", pen["exit"], pen["exit_normal"], decals[1]],
		["ricochet", skim.ricochets[0]["point"], skim.ricochets[0]["normal"], decals[made_before]],
	]
	_clear_view(me)
	me.camera.near = 0.02
	me.camera.cull_mask = 1
	var failed := false
	for m: Array in marks:
		var n: int = await _closeup(me, m[3], m[1], (m[2] as Vector3).normalized(), m[0])
		if n < 20:
			print("FAIL %s decal is not visible against the bare wall" % m[0])
			failed = true
	quit(1 if failed else 0)
