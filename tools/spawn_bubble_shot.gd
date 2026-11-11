extends SceneTree

## Spawn-protection bubble (DotSpawnBubble3D) round a stand-in body, beside an unprotected one.
## xvfb-run -a godot --path . --resolution 1280x720 --script res://tools/spawn_bubble_shot.gd -- [out.png]

var _ticks := 0
## Frame sequence after the still (DOT_SHOT_FRAMES): the bubble animates. See DotShotSeq.
var _clip := DotShotSeq.new()
var _out := "screenshots/spawn_bubble.png"


func _body(x: float, colour: Color) -> Node3D:
	var n := Node3D.new()
	n.position = Vector3(x, 0, 0)
	var m := MeshInstance3D.new()
	var c := CapsuleMesh.new()
	c.radius = 0.35
	c.height = 1.8
	m.mesh = c
	m.position.y = 0.9
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	m.material_override = mat
	n.add_child(m)
	root.add_child(n)
	return n


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	var floor_mesh := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(30, 30)
	floor_mesh.mesh = pm
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.42, 0.45, 0.5)
	floor_mesh.material_override = fm
	root.add_child(floor_mesh)
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
	var _plain := _body(-1.6, Color(0.8, 0.3, 0.25))
	var prot := _body(0.0, Color(0.25, 0.4, 0.85))
	var bubble := DotSpawnBubble3D.new()
	prot.add_child(bubble)
	bubble.sync(true)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.look_at_from_position(Vector3(-0.3, 1.3, 4.0), Vector3(-0.8, 0.9, 0))


func _process(_delta: float) -> bool:
	if _clip.follow(root):
		return false
	if _ticks >= 60:  # the still is saved and the clip (if any) is done
		quit()
		return false
	_ticks += 1
	if _ticks == 60:
		DirAccess.make_dir_recursive_absolute(_out.get_base_dir() if _out.get_base_dir() != "" else ".")
		var _e := root.get_viewport().get_texture().get_image().save_png(_out)
		print("saved ", _out)
		if _clip.start_follow(_out):
			return false
		quit()
	return false
