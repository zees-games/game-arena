extends SceneTree

## Renders every zee weapon as a white side-on silhouette into `assets/weapon_icons/<id>.png`,
## for the kill feed and the weapon slots on the HUD.
##
## [b]Generated from the models, not drawn by hand[/b], for the reason the avatar parts are:
## twenty-six hand-made icons are twenty-six chances to draw a weapon the model is not, and a
## pack that swaps a model would leave its icon behind. The model, its forward axis and its
## scale all come from `ZeeWeaponArtTable`, the one table that knows a filename. The art is
## Kenney's CC0 blaster and tool kits, already vendored under `assets/`.
##
## Run `tools/build_weapon_icons.sh` (xvfb-run: under `--headless` every frame is empty)
## after the weapon pack's art changes, and commit the PNGs.

const OUT_DIR := "res://assets/weapon_icons"

## The render, before cropping: wide, because every weapon is long and thin side-on.
const RENDER := Vector2i(640, 256)

## The saved icon's height: twice the largest the HUD draws one (the slot in hand, 24 px).
const ICON_HEIGHT := 48

## Frames to let a model settle into the viewport before the grab.
const SETTLE := 4

var _viewport: SubViewport = null
var _camera: Camera3D = null
var _holder: Node3D = null
var _arts: Array[ZeeWeaponArt] = []
var _at := 0
var _wait := SETTLE
var _written := 0


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	_viewport = SubViewport.new()
	_viewport.size = RENDER
	_viewport.transparent_bg = true
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)

	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.keep_aspect = Camera3D.KEEP_WIDTH
	_camera.position = Vector3(0.0, 0.0, 10.0)
	_viewport.add_child(_camera)
	_camera.current = true

	for art in ZeeWeaponArtTable.all():
		if art.model_path != "":
			_arts.append(art)


func _process(_delta: float) -> bool:
	if _at >= _arts.size():
		print("wrote %d weapon icons to %s" % [_written, OUT_DIR])
		return true

	var art := _arts[_at]

	if _wait == SETTLE:
		_place(art)

	if _wait > 0:
		_wait -= 1
		return false

	var image := _viewport.get_texture().get_image()
	var used := image.get_used_rect()
	if used.size.x > 0 and used.size.y > 0:
		image = image.get_region(used.grow(2).intersection(Rect2i(Vector2i.ZERO, image.get_size())))
		# Down to the size the HUD draws at or a little over, filtered here once: drawn at a
		# tenth of a 600-pixel render, the thin parts of a rifle broke into dashes.
		var scale := float(ICON_HEIGHT) / float(image.get_height())
		if scale < 1.0:
			image.resize(maxi(1, int(round(image.get_width() * scale))), ICON_HEIGHT, Image.INTERPOLATE_LANCZOS)
		var path := "%s/%s.png" % [OUT_DIR, String(art.id)]
		var err := image.save_png(ProjectSettings.globalize_path(path))
		if err == OK:
			_written += 1
			print("  %s  %d x %d" % [path, image.get_width(), image.get_height()])
		else:
			push_error("could not save %s" % path)
	else:
		push_error("%s rendered nothing (%s)" % [art.id, art.model_path])

	_at += 1
	_wait = SETTLE
	return false


## The model of [param art], turned so its barrel (or blade) points right, flat white, and
## the camera fitted to it.
func _place(art: ZeeWeaponArt) -> void:
	if _holder != null:
		_holder.queue_free()
	_holder = Node3D.new()
	_viewport.add_child(_holder)

	var model := ZeeModelCache.instantiate(art.model_path)
	if model == null:
		return
	_holder.add_child(model)

	var forward := art.model_forward.normalized()
	if forward.is_equal_approx(Vector3.LEFT):
		model.basis = Basis(Vector3.UP, PI)
	elif not forward.is_equal_approx(Vector3.RIGHT):
		model.basis = Basis(Quaternion(forward, Vector3.RIGHT))

	var white := StandardMaterial3D.new()
	white.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	white.albedo_color = Color.WHITE
	_paint(model, white)

	var box := Transform3D(model.basis, Vector3.ZERO) * ZeeModelCache.bounds(art.model_path)
	model.position = -box.get_center()
	_camera.size = maxf(box.size.x, box.size.y * float(RENDER.x) / float(RENDER.y)) * 1.08


func _paint(node: Node, material: Material) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).material_override = material
	for child in node.get_children():
		_paint(child, material)
