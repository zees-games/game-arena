extends CanvasLayer

## The killer's own screen over a replay camera: their viewmodel, crosshair and ammo, from the recorded aux.

const KillPov := preload("arena_kill_pov.gd")
const ArenaContent := preload("arena_content.gd")
const AMMO_FONT := 22

var feel_rules: ZeeViewFeel = null
var ads_rules: ZeeAdsRules = null

var hands: ZeeViewModel = null
var flashes: ZeeShotFx = null
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
	if aux.size() < DotKillViewRing.AUX:
		aux.resize(DotKillViewRing.AUX)
	var behind: bool = view.get("behind", false)
	var own: Variant = view.get("crosshair")
	if own is CanvasItem:
		(own as CanvasItem).visible = false
	if cam != _camera:
		_start(cam)
	visible = not behind
	if hands != null:
		hands.visible = not behind
	_move_hands(aux, cam)
	if not behind:
		_kick(cam)
	_hud(aux, cam.fov)


## The killer's recoil and aim on the replay camera, as [code]ArenaPlayer.present[/code] puts them on a live one;
## the host or client places the camera afresh each frame, so nothing accumulates.
func _kick(cam: Camera3D) -> void:
	var punch := hands.view_punch()
	if punch.is_finite():
		cam.rotate_object_local(Vector3.RIGHT, deg_to_rad(punch.x))
		cam.global_rotate(Vector3.UP, deg_to_rad(punch.y))
	cam.fov *= hands.aim_fov_scale()


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
	flashes = ZeeShotFx.new()
	flashes.name = "KillerShotFx"
	flashes.catalogue = ArenaContent.weapon_catalogue()
	cam.add_child(flashes)
	crosshair = DotCrosshair.new()
	crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(crosshair)
	label = Label.new()
	# Just above the killcam's bottom bar (16% of the height), which would cover it.
	label.anchor_left = 1.0
	label.anchor_right = 1.0
	label.anchor_top = 0.83
	label.anchor_bottom = 0.83
	label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	label.offset_right = -40.0
	label.add_theme_font_size_override("font_size", AMMO_FONT)
	add_child(label)


func _move_hands(aux: PackedFloat32Array, cam: Camera3D) -> void:
	var id := KillPov.weapon_of(aux[0])
	if id != &"" and hands.equipped() != id:
		var art: Variant = ZeeWeaponArtTable.table().get(id)
		if art is ZeeWeaponArt:
			var _drawn := hands.equip(art as ZeeWeaponArt)
	hands.aim(aux[1] > 0.5)
	var flags := int(aux[10])
	var look := cam.global_basis.get_euler()
	hands.drive(Vector2(rad_to_deg(look.y), rad_to_deg(look.x)), aux[11], flags & KillPov.GROUNDED != 0 or aux[11] == 0.0, flags & KillPov.CROUCHED != 0)
	if _fire >= 0.0 and aux[2] != _fire:
		_fired(id, Vector2(aux[8], aux[9]), flags & KillPov.SIGNED != 0, cam)
	_fire = aux[2]
	hands.advance(get_process_delta_time())


## A shot in the replay: the recorded recoil through the view model's own kick, and the muzzle flash.
func _fired(id: StringName, recoil: Vector2, signed: bool, cam: Camera3D) -> void:
	var outcome := DotWeaponOutcome.new()
	outcome.used = true
	outcome.kind = DotWeaponOutcome.KIND_SHOT
	outcome.recoil = recoil if recoil != Vector2.ZERO else Vector2(0.5, 0.1)
	outcome.recoil_signed = signed and recoil != Vector2.ZERO
	hands.on_used(outcome)
	if flashes != null:
		flashes.play_remote(ZeeWeaponNet.KIND_SHOT, hands.muzzle_transform(), -cam.global_basis.z, id)


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
	for n: Node in [crosshair, label, flashes]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	crosshair = null
	label = null
	flashes = null
	_camera = null


## Puts the killer's screen under [param parent] and hands it to a kill view or killcam host as its `present_fn`.
static func mount(parent: Node, game: Object, target: Object, label: String) -> void:
	var view := new()
	view.name = label
	view.feel_rules = game.get(&"feel_rules") as ZeeViewFeel
	view.ads_rules = game.get(&"ads_rules") as ZeeAdsRules
	parent.add_child(view)
	target.set(&"present_fn", view.present)
