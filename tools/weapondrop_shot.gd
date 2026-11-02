extends SceneTree

const Wiring := preload("../game/arena_weapon_drop_wiring.gd")

## Dropped weapons settled on a floor, a ramp and a step, seen from low and close: any gun sunk
## into the surface shows. The server layer draws nothing; the client layer mirrors it.
## xvfb-run -a godot --path . --resolution 1280x720 --script res://tools/weapondrop_shot.gd -- [out.png]

var _ticks := 0
var _out := "screenshots/weapondrops.png"
var _cam: Camera3D


func _slab(pos: Vector3, size: Vector3, tilt: float = 0.0) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	body.add_child(cs)
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mesh.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.45, 0.5)
	mesh.material_override = mat
	body.add_child(mesh)
	root.add_child(body)
	body.position = pos
	body.rotation.x = tilt


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	Engine.physics_ticks_per_second = 64
	_slab(Vector3(0, -0.5, 0), Vector3(30, 1, 30))
	_slab(Vector3(-3.0, 0.1, -1.0), Vector3(3, 0.2, 2))
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	root.add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.6, 0.7, 0.8)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.7, 0.7, 0.7)
	root.add_child(env)
	var server := DotWeaponDrops.new()
	server.is_authority = true
	server.draws = false
	server.look_of = Wiring.look
	var client := DotWeaponDrops.new()
	client.draws = true
	client.look_of = Wiring.look
	root.add_child(server)
	root.add_child(client)
	server.dropped.connect(func(i: int, s: Dictionary, at: Transform3D, v: Vector3, _o: int) -> void: client.mirror_drop(i, s, at, v))
	server.settled.connect(func(i: int, at: Transform3D) -> void: client.mirror_settled(i, at))
	var ids: Array = ZeeWeaponArtTable.table().keys()
	ids.sort()
	var k := 0
	for w in ["pistol", "smg", "charge_rifle", "pickaxe", "spade", "sticky", "hatchet", "shotgun"]:
		if not ids.has(StringName(w)):
			continue
		var x := -1.8 + (k % 4) * 1.2
		var z := -1.0 + (k / 4) * 1.4
		var _id := server.spawn({"id": StringName(w), "magazine": 1, "reserve": 1}, Vector3(x, 1.0, z), Vector3(0.2, 0.0, 0.2), 0)
		k += 1
	_cam = Camera3D.new()
	root.add_child(_cam)
	_cam.look_at_from_position(Vector3(0.4, 0.55, 2.6), Vector3(0.4, 0.05, -0.4))


func _process(_delta: float) -> bool:
	_ticks += 1
	if _ticks == 360:
		DirAccess.make_dir_recursive_absolute(_out.get_base_dir() if _out.get_base_dir() != "" else ".")
		var _e := root.get_viewport().get_texture().get_image().save_png(_out)
		print("saved ", _out)
		quit()
	return false
