extends Node

## The loadout menu's weapon pictures: the model itself, rendered once at card size with MSAA, so a card is smooth at any
## scale where the sprite sheet's 4x nearest upscale was blocks. A weapon with no model keeps the sprite.

const SIZE := Vector2i(512, 256)

var _textures: Dictionary = {}


## A smooth picture of [param id]'s model, or null when it has no art (the caller falls back to the sprite).
func texture(id: StringName) -> Texture2D:
	if _textures.has(id):
		return _textures[id]
	var art := ZeeWeaponArtTable.get_art(id)
	var made: Texture2D = null
	if art != null and art.model_path != "":
		made = _build(art)
	_textures[id] = made
	return made


func _build(art: ZeeWeaponArt) -> Texture2D:
	var model := ZeeModelCache.instantiate(art.model_path)
	if model == null:
		return null
	var port := SubViewport.new()
	port.size = SIZE
	port.transparent_bg = true
	port.own_world_3d = true
	port.msaa_3d = Viewport.MSAA_4X
	port.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(port)

	var env := Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.7, 0.75)
	var we := WorldEnvironment.new()
	we.environment = env
	port.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, -30, 0)
	port.add_child(sun)

	var forward := art.model_forward.normalized()
	if forward.is_equal_approx(Vector3.LEFT):
		model.basis = Basis(Vector3.UP, PI)
	elif not forward.is_equal_approx(Vector3.RIGHT):
		model.basis = Basis(Quaternion(forward, Vector3.RIGHT))
	port.add_child(model)
	var box := Transform3D(model.basis, Vector3.ZERO) * ZeeModelCache.bounds(art.model_path)
	model.position = -box.get_center()

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	camera.size = maxf(box.size.x, box.size.y * float(SIZE.x) / float(SIZE.y)) * 1.08
	camera.position = Vector3(0, 0, 10)
	port.add_child(camera)
	camera.current = true
	return port.get_texture()
