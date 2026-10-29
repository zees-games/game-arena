extends CanvasLayer

## The killer's own screen over a replay camera: their viewmodel, crosshair and ammo, from the recorded aux.

const KillPov := preload("arena_kill_pov.gd")
const AMMO_FONT := 22

var feel_rules: ZeeViewFeel = null
var ads_rules: ZeeAdsRules = null

var hands: ZeeViewModel = null
var crosshair: DotCrosshair = null
var label: Label = null

var _camera: Camera3D = null
var _fire := -1.0
var _hits := -1.0


func _init() -> void:
	layer = 4


## Draws one frame of the killer's screen; {} ends it.
func present(view: Dictionary) -> void:
	if view.is_empty():
		_end()
		return
	var cam: Camera3D = view["camera"]
	var aux: PackedFloat32Array = view["aux"]
	if aux.size() < 8:
		aux.resize(8)
	var behind: bool = view.get("behind", false)
	var own: Variant = view.get("crosshair")
	if own is CanvasItem:
		(own as CanvasItem).visible = false
	if cam != _camera:
		_start(cam)
	visible = not behind
	if hands != null:
		hands.visible = not behind
	_move_hands(aux)
	_hud(aux, cam.fov)


func _start(cam: Camera3D) -> void:
	_end()
	_camera = cam
	_fire = -1.0
	_hits = -1.0
	hands = ZeeViewModel.new()
	hands.name = "KillerHands"
	if feel_rules != null:
		hands.feel_rules = feel_rules
	hands.ads_rules = ads_rules
	cam.add_child(hands)
	crosshair = DotCrosshair.new()
	crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(crosshair)
	label = Label.new()
	label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	label.position = Vector2(-260.0, -80.0)
	label.add_theme_font_size_override("font_size", AMMO_FONT)
	add_child(label)


func _move_hands(aux: PackedFloat32Array) -> void:
	var id := KillPov.weapon_of(aux[0])
	if id != &"" and hands.equipped() != id:
		var art: Variant = ZeeWeaponArtTable.table().get(id)
		if art is ZeeWeaponArt:
			var _drawn := hands.equip(art as ZeeWeaponArt)
	hands.aim(aux[1] > 0.5)
	if _fire >= 0.0 and aux[2] != _fire:
		hands.on_fired()
	_fire = aux[2]
	hands.advance(get_process_delta_time())


func _hud(aux: PackedFloat32Array, fov: float) -> void:
	crosshair.fov_degrees = fov
	crosshair.set_aim(aux[1])
	crosshair.set_spread(aux[6])
	if _hits >= 0.0 and aux[7] != _hits:
		crosshair.flash_hit()
	_hits = aux[7]
	label.text = "%d / %d" % [int(aux[4]), int(aux[5])] if aux[4] > 0.0 or aux[5] > 0.0 else ""


func _end() -> void:
	if hands != null and is_instance_valid(hands):
		hands.queue_free()
	hands = null
	for n: Node in [crosshair, label]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	crosshair = null
	label = null
	_camera = null


## Puts the killer's screen under [param parent] and hands it to a kill view or killcam host as its `present_fn`.
static func mount(parent: Node, game: Object, target: Object, label: String) -> void:
	var view := new()
	view.name = label
	view.feel_rules = game.get(&"feel_rules") as ZeeViewFeel
	view.ads_rules = game.get(&"ads_rules") as ZeeAdsRules
	parent.add_child(view)
	target.set(&"present_fn", view.present)
