extends Node3D

## The jail's gate and button, drawn. Presentation only: the gate is a volume that puts a player
## back (`maps/arena_jail.gd`), and nothing here is solid, so a client that drew it wrong would
## see a wrong door and walk the same way.
##
## A slab over each exit: red and solid-looking while shut, a pale green ghost while open, and
## fading as the open time runs out. A flat disc on the button's floor: bright while a press
## works, dull while it is cooling down, and the same colour as the gate while it is open.

const SHUT := Color(0.9, 0.15, 0.1, 0.55)
const OPEN := Color(0.2, 0.9, 0.35, 0.12)
const READY := Color(0.25, 0.8, 1.0, 0.7)
const COOLING := Color(0.35, 0.4, 0.45, 0.5)

var jail: RefCounted = null

## A callable returning the simulation tick to draw for, since the view lives in a scene that
## does not know which end it is on.
var tick_fn: Callable = Callable()

var _slabs: Array[MeshInstance3D] = []
var _slab_materials: Array[StandardMaterial3D] = []
var _disc: MeshInstance3D = null
var _disc_material: StandardMaterial3D = null


func build(p_jail: RefCounted, p_tick_fn: Callable) -> void:
	jail = p_jail
	tick_fn = p_tick_fn
	name = "JailView"

	for box in jail.exit_boxes():
		var slab := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = box.size
		slab.mesh = mesh
		var material := _material(SHUT)
		slab.material_override = material
		add_child(slab)
		slab.global_position = box.get_center()
		_slabs.append(slab)
		_slab_materials.append(material)

	var button: AABB = jail.button_box()
	_disc = MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = minf(button.size.x, button.size.z) * 0.5
	disc.bottom_radius = disc.top_radius
	disc.height = 0.06
	_disc.mesh = disc
	_disc_material = _material(READY)
	_disc.material_override = _disc_material
	add_child(_disc)
	_disc.global_position = Vector3(button.get_center().x, button.position.y + 0.08, button.get_center().z)


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = color
	return material


func _process(_delta: float) -> void:
	if jail == null or not tick_fn.is_valid():
		return

	var tick: int = tick_fn.call()
	visible = bool(jail.enabled)
	var open: bool = jail.is_open(tick)
	var color := SHUT
	if open:
		color = OPEN
		color.a = 0.06 + 0.12 * float(jail.open_left(tick))

	for material in _slab_materials:
		material.albedo_color = color

	_disc_material.albedo_color = OPEN.lerp(Color(0.2, 0.9, 0.35, 0.7), 1.0) if open \
		else (READY if jail.can_press(tick) else COOLING)
