extends CanvasLayer

## The killer's own screen over a replay camera: their viewmodel, crosshair and ammo, from the recorded aux.

const KillPov := preload("arena_kill_pov.gd")
const ArenaContent := preload("arena_content.gd")
const ArenaViewArms := preload("arena_view_arms.gd")
const ArenaKillPovRecoil := preload("arena_kill_pov_recoil.gd")
const ArenaRecoilView := preload("arena_recoil_view.gd")
const ArenaFrameProbe := preload("arena_frame_probe.gd")
const ArenaAvatars := preload("arena_avatars.gd")
const AMMO_FONT := 22
## Metres per second the lens may slide out of a wall.
const EASE_SPEED := 6.0

## Layers the replay lens must stay out of (world and props); 0 skips the clearance.
var world_mask := 0
var feel_rules: AwViewFeel = null
var ads_rules: AwAdsRules = null

var hands: AwViewModel = null
var flashes: AwShotFx = null
## The killer's arms on dot-player-char's rig, as the live view draws them; null below its API 8.
var arms: DotPlayerViewArms = null

var _grip: DotViewGrip = null
## Returns [key, look] of the killer now playing; unset draws a stock person.
var killer_look_fn: Callable = Callable()
## The game whose `fp_arms` rule may put one arm set on everybody (see ArenaViewArms.arm_set_look).
var rules: Object = null
var _arm_set: Array = []
var _boxes: Dictionary = {}
## Whose look [member arms] and [member _spare_arms] were built with, so a kill by the same person reuses the rig.
var _arms_key := ""
var _spare_key := ""
var crosshair: DotCrosshair = null
var label: Label = null

var _camera: Camera3D = null
## Most view models kept parked between kills (each holds one weapon, built).
const RIGS := 4
## View models parked under this layer, hidden and stopped: built in advance and kept after a kill with the
## weapon they drew, so a kill starts by moving nodes, not by making them (KillerHands and its weapon cost 100-430 ms).
var _rigs: Array[AwViewModel] = []
var _spare_arms: DotPlayerViewArms = null
## The flash pool, crosshair and ammo line of the last kill, parked for the next.
var _spare_fx: AwShotFx = null
var _spare_crosshair: DotCrosshair = null
var _spare_label: Label = null
var _warm_rig: AwViewModel = null
var _push := Vector3.ZERO
var _hits := -1.0
## The killer's recoil, shot by shot, on the replay camera.
var recoil := ArenaKillPovRecoil.new()


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
		_start(cam, KillPov.weapon_of(aux[0]))
	KillPov.mark_replay_camera(cam, true)
	if not behind:
		_clear_lens(cam)
	visible = not behind
	if hands != null:
		hands.visible = not behind
		if arms != null:
			arms.visible = not behind
	_move_hands(aux, cam)
	if not behind:
		_kick(cam)
	_hud(aux, cam.fov)


## Pulls the lens out of any solid the recorded eye stood in or against; the move eases so a cut never snaps.
func _clear_lens(cam: Camera3D) -> void:
	if world_mask == 0 or not cam.is_inside_tree():
		return
	var want := KillPov.clear_eye(cam.get_world_3d().direct_space_state, cam.global_position, -cam.global_basis.z, world_mask)
	var step := want - cam.global_position
	# Out of a solid at once, back toward the recorded eye gradually.
	_push = step if step.length() >= _push.length() else _push.move_toward(step, EASE_SPEED * get_process_delta_time())
	cam.global_position += _push


## The killer's recoil and aim on the replay camera, as [code]ArenaPlayer.present[/code] puts them on a live one;
## the host or client places the camera afresh each frame, so nothing accumulates.
func _kick(cam: Camera3D) -> void:
	var punch := hands.view_punch() + recoil.step(get_process_delta_time(), ArenaRecoilView.POSE_SHARE)
	if punch.is_finite():
		cam.rotate_object_local(Vector3.RIGHT, deg_to_rad(punch.x))
		cam.global_rotate(Vector3.UP, deg_to_rad(punch.y))
	cam.fov *= hands.aim_fov_scale()


func _start(cam: Camera3D, weapon: StringName = &"") -> void:
	var began := Time.get_ticks_usec()
	_end()
	_camera = cam
	_hits = -1.0
	recoil.clear()
	hands = _take_rig(weapon)
	hands.process_mode = Node.PROCESS_MODE_INHERIT
	hands.visible = true
	hands.name = "KillerHands"
	if feel_rules != null:
		hands.feel_rules = feel_rules
	hands.ads_rules = ads_rules
	if hands.get_parent() != null:
		hands.get_parent().remove_child(hands)
	cam.add_child(hands)
	_mount_arms(cam)
	flashes = _spare_fx if _live(_spare_fx) else _new_fx()
	_spare_fx = null
	if flashes.get_parent() != null:
		flashes.get_parent().remove_child(flashes)
	cam.add_child(flashes)
	crosshair = _spare_crosshair if _live(_spare_crosshair) else _new_crosshair()
	_spare_crosshair = null
	crosshair.visible = true
	label = _spare_label if _live(_spare_label) else _new_label()
	_spare_label = null
	label.text = ""
	label.visible = true
	# A frame or so on, not this one: the next kill finds it built.
	get_tree().create_timer(0.5).timeout.connect(_prepare_spare)
	ArenaFrameProbe.add(&"killview_start", began)


static func _live(node: Variant) -> bool:
	return node != null and is_instance_valid(node) and not (node as Node).is_queued_for_deletion()


## A parked view model already holding [param weapon]; else one holding nothing; else the oldest; else a new one.
func _take_rig(weapon: StringName) -> AwViewModel:
	var pick := -1
	for i in _rigs.size():
		if not _live(_rigs[i]):
			continue
		var held := _rigs[i].equipped()
		if weapon != &"" and held == weapon:
			pick = i
			break
		if pick < 0 or (held == &"" and _rigs[pick].equipped() != &""):
			pick = i
	if pick < 0:
		return _new_hands()
	var rig := _rigs[pick]
	_rigs.remove_at(pick)
	return rig


## Parks [param rig] under this layer, hidden and stopped; past [constant RIGS] the oldest goes.
func _park_rig(rig: AwViewModel) -> void:
	rig.aim(false)
	rig.on_reset()
	rig.visible = false
	rig.process_mode = Node.PROCESS_MODE_DISABLED
	rig.name = "SpareHands"
	if rig.get_parent() != self:
		if rig.get_parent() != null:
			rig.get_parent().remove_child(rig)
		add_child(rig, true)
	_rigs.append(rig)
	while _rigs.size() > RIGS:
		var old: AwViewModel = _rigs.pop_front()
		if _live(old):
			old.queue_free()


func _new_fx() -> AwShotFx:
	var fx := AwShotFx.new()
	fx.name = "KillerShotFx"
	fx.catalogue = ArenaContent.weapon_catalogue()
	return fx


func _new_crosshair() -> DotCrosshair:
	var cross := DotCrosshair.new()
	cross.set_anchors_preset(Control.PRESET_FULL_RECT)
	cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(cross)
	return cross


func _new_label() -> Label:
	var line := Label.new()
	# Just above the killcam's bottom bar (16% of the height), which would cover it.
	line.anchor_left = 1.0
	line.anchor_right = 1.0
	line.anchor_top = 0.83
	line.anchor_bottom = 0.83
	line.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	line.grow_vertical = Control.GROW_DIRECTION_BEGIN
	line.offset_right = -40.0
	line.add_theme_font_size_override("font_size", AMMO_FONT)
	add_child(line)
	return line


## An unbuilt view model with its arms setting made, which [method _start] would otherwise make.
func _new_hands() -> AwViewModel:
	var model := AwViewModel.new()
	model.show_arms = not _shares_arms(model)
	return model


func _exit_tree() -> void:
	# The spare rig waits outside the tree, so nothing frees it with the view.
	if _spare_arms != null and is_instance_valid(_spare_arms) and not _spare_arms.is_inside_tree():
		_spare_arms.free()
	_spare_arms = null


## An arm rig built with [param look], drawn as the server's arm set while one is on; [method _mount_arms] puts it under the replay camera.
func _new_arms(look: DotHumanoidLook) -> DotPlayerViewArms:
	var rig := DotPlayerViewArms.new()
	if rig.has_method(&"set_look_override"):
		rig.set_look_override(ArenaViewArms.arm_set_look(rules, _arm_set))
	add_child(rig)
	rig.build(look, 1.8)
	remove_child(rig)
	return rig


## The killer's [key, look]: their avatar's person, or a stock one when nobody is known.
func _killer_look() -> Array:
	var got: Variant = killer_look_fn.call() if killer_look_fn.is_valid() else null
	if got is Array and (got as Array).size() == 2 and got[1] is DotHumanoidLook:
		return got
	return ["", DotHumanoidLook.stock(1)]


## The kill's killer, read from the kill view (its describe) or the final killcam (its last kill); 0 when neither says.
static func killer_of(target: Object) -> int:
	if target == null:
		return 0
	if target.has_method(&"describe"):
		var said: Variant = target.call(&"describe")
		if said is Dictionary and (said as Dictionary).has("killer"):
			return int(said["killer"])
	var buffer: Variant = target.get(&"buffer")
	if buffer is Object and (buffer as Object).has_method(&"last_event"):
		var kill: Variant = (buffer as Object).call(&"last_event", &"kill")
		if kill is Dictionary and (kill as Dictionary).has("data"):
			var data: Variant = kill["data"]
			if data is Dictionary:
				return int((data as Dictionary).get("killer", 0))
	return 0


## [key, look] for player [param id] of [param game], keyed like the live view's own arms.
static func look_for(game: Object, id: int) -> Array:
	var key := StringName("arena-player-%08d" % id)
	var player: Variant = game.call(&"player_for", id) if id != 0 and game != null and game.has_method(&"player_for") else null
	var avatar: DotAvatar = (player as Object).get(&"avatar") as DotAvatar if player is Object else null
	return [String(key), ArenaAvatars.look_of(avatar, key)]


## Builds the spare view model, arms, effects, crosshair and ammo line a kill would otherwise make on its first frame.
func prepare_spare() -> void:
	_prepare_spare()

func _prepare_spare() -> void:
	if not is_inside_tree():
		return
	for i in range(_rigs.size() - 1, -1, -1):
		if not _live(_rigs[i]):
			_rigs.remove_at(i)
	if _rigs.is_empty():
		var rig := _new_hands()
		add_child(rig)
		_park_rig(rig)
	if not _live(_spare_arms) and _shares_arms(_rigs[0]):
		_spare_arms = _new_arms(DotHumanoidLook.stock(1))
		_spare_key = ""
	if not _live(_spare_fx) and flashes == null:
		# In the tree once, so its light and mesh pools are built here and not under the kill's camera.
		_spare_fx = _new_fx()
		add_child(_spare_fx)
	if not _live(_spare_crosshair) and crosshair == null:
		_spare_crosshair = _new_crosshair()
		_spare_crosshair.visible = false
	if not _live(_spare_label) and label == null:
		_spare_label = _new_label()
		_spare_label.visible = false


## Builds, under a loading cover, everything a kill would otherwise make on its first frame: a parked view
## model holding each of [param weapons] (at most [constant RIGS]), the arms, the flash pool, the crosshair
## and the ammo line. Returns the materials and meshes made, for the cover to draw once (their shaders).
func warm(weapons: Array) -> Array:
	if not is_inside_tree() or hands != null:
		return []
	_prepare_spare()
	var table := AwWeaponArtTable.table()
	for id: Variant in weapons:
		var art: Variant = table.get(id)
		if not (art is AwWeaponVisual) or _holds(id):
			continue
		var rig: AwViewModel = null
		for parked in _rigs:
			if _live(parked) and parked.equipped() == &"":
				rig = parked
				break
		if rig == null:
			if _rigs.size() >= RIGS:
				break
			rig = _new_hands()
			add_child(rig)
			_park_rig(rig)
		if feel_rules != null:
			rig.feel_rules = feel_rules
		rig.ads_rules = ads_rules
		var _drawn := rig.equip(art as AwWeaponVisual)
	var out: Array = []
	for rig in _rigs:
		if _live(rig):
			DotRenderWarmup.collect(rig, out)
	if _live(_spare_arms):
		DotRenderWarmup.collect(_spare_arms, out)
	if _live(_spare_fx):
		DotRenderWarmup.collect(_spare_fx, out)
	return out


## Holds each of [param ids] once on a scratch view model set up as a killer's hands are, from index [param from] until [param until_msec]: the view model's mesh work (sight cut, hand reach, magazine carve) is cached by its rules,
## so a killer's weapon outside the parked [constant RIGS] costs a swap, not a build (350 ms mid-match in the owner's profile). Returns the next index; [code]ids.size()[/code] when done.
func warm_meshes(ids: Array, from: int, until_msec: int) -> int:
	if not is_inside_tree():
		return ids.size()
	if not _live(_warm_rig):
		_warm_rig = _new_hands()
		_warm_rig.visible = false
		add_child(_warm_rig)
	if feel_rules != null:
		_warm_rig.feel_rules = feel_rules
	_warm_rig.ads_rules = ads_rules
	var table := AwWeaponArtTable.table()
	var next := from
	while next < ids.size():
		var art: Variant = table.get(ids[next])
		if art is AwWeaponVisual:
			var _drawn := _warm_rig.equip(art as AwWeaponVisual)
		next += 1
		if Time.get_ticks_msec() >= until_msec:
			break
	if next >= ids.size():
		_warm_rig.queue_free()
		_warm_rig = null
	return next


func _holds(weapon: Variant) -> bool:
	for rig in _rigs:
		if _live(rig) and rig.equipped() == weapon:
			return true
	return false


## How many view models wait parked, and which weapons they hold (tests, the load timeline).
func parked() -> Array:
	var out: Array = []
	for rig in _rigs:
		if _live(rig):
			out.append(rig.equipped())
	return out


## Whether the shared arm rig draws the hands; the view model's own sleeves are then built off, not left drawn under the gun.
func _shares_arms(model: AwViewModel = null) -> bool:
	var m := model if model != null else hands
	return DotAddonApi.build_level("dot_player_char") >= ArenaViewArms.NEEDS_LEVEL and m.has_signal(&"hands_reached")


func _mount_arms(cam: Camera3D) -> void:
	if not _shares_arms():
		return
	var who := _killer_look()
	if _live(_spare_arms):
		arms = _spare_arms
		if arms.has_method(&"set_look_override"):
			arms.set_look_override(ArenaViewArms.arm_set_look(rules, _arm_set))
		# The parked rig is the last killer's; another killer's arms cost a rebuild, not a new rig.
		if _spare_key != String(who[0]):
			arms.build(who[1], 1.8)
	else:
		arms = _new_arms(who[1])
	_arms_key = String(who[0])
	_spare_arms = null
	_spare_key = ""
	arms.name = "KillerArms"
	arms.visible = true
	if arms.get_parent() != null:
		arms.get_parent().remove_child(arms)
	cam.add_child(arms)
	if not hands.hands_reached.is_connected(_on_hands):
		hands.hands_reached.connect(_on_hands)


func _on_hands(anchor: Node3D, grip: Vector3, fore: Vector3, pose: StringName) -> void:
	if arms == null:
		return
	var one: bool = pose in ArenaViewArms.ONE_HAND
	if _grip == null or _grip.anchor != anchor or _grip.is_two_hand() == one:
		_grip = DotViewGrip.one_hand(anchor, grip) if one else DotViewGrip.two_hand(anchor, grip, fore)
		arms.set_held(_grip)
	_grip.grip = grip
	if not one:
		_grip.support = fore
	_grip.bounds = ArenaViewArms.weapon_bounds(hands, _boxes)


func _move_hands(aux: PackedFloat32Array, cam: Camera3D) -> void:
	var id := KillPov.weapon_of(aux[0])
	if id != &"" and hands.equipped() != id:
		var art: Variant = AwWeaponArtTable.table().get(id)
		if art is AwWeaponVisual:
			var began := Time.get_ticks_usec()
			var _drawn := hands.equip(art as AwWeaponVisual)
			ArenaFrameProbe.add(&"killview_equip", began)
	hands.aim(aux[1] > 0.5)
	var flags := int(aux[10])
	var look := cam.global_basis.get_euler()
	hands.drive(Vector2(rad_to_deg(look.y), rad_to_deg(look.x)), aux[11], flags & KillPov.GROUNDED != 0 or aux[11] == 0.0, flags & KillPov.CROUCHED != 0)
	for outcome in recoil.shots(aux, get_process_delta_time()):
		_fired(id, outcome, cam)
	hands.advance(get_process_delta_time())
	if arms != null:
		arms.tick(aux[11], get_process_delta_time())


## A round in the replay: its kick through the view model's spring and the camera's share, and the muzzle flash.
func _fired(id: StringName, outcome: DotWeaponOutcome, cam: Camera3D) -> void:
	hands.on_used(outcome)
	recoil.kick(outcome)
	if flashes != null:
		flashes.play_remote(AwWeaponNet.KIND_SHOT, hands.muzzle_transform(), -cam.global_basis.z, id)


func _hud(aux: PackedFloat32Array, fov: float) -> void:
	crosshair.fov_degrees = fov
	crosshair.set_aim(aux[1])
	crosshair.set_spread(aux[6])
	if _hits >= 0.0 and aux[7] != _hits:
		crosshair.flash_hit()
	_hits = aux[7]
	label.text = "%d / %d" % [int(aux[4]), int(aux[5])] if aux[4] > 0.0 or aux[5] > 0.0 else ""


## Ends the killer's screen. Its nodes are parked for the next kill, not freed: the next one then makes nothing.
func _end() -> void:
	if _live(hands):
		if hands.has_signal(&"hands_reached") and hands.hands_reached.is_connected(_on_hands):
			hands.hands_reached.disconnect(_on_hands)
		_park_rig(hands)
	hands = null
	if _live(arms):
		# Outside the tree, as a spare rig waits ([method _exit_tree] frees it).
		if arms.get_parent() != null:
			arms.get_parent().remove_child(arms)
		if _live(_spare_arms):
			arms.queue_free()
		else:
			arms.visible = false
			_spare_arms = arms
			_spare_key = _arms_key
	arms = null
	_arms_key = ""
	_grip = null
	_push = Vector3.ZERO
	if _live(flashes):
		flashes.stop_flashes()
		if flashes.get_parent() != null:
			flashes.get_parent().remove_child(flashes)
		if _live(_spare_fx) or not is_inside_tree():
			flashes.queue_free()
		else:
			add_child(flashes)
			_spare_fx = flashes
	flashes = null
	if _live(crosshair):
		crosshair.visible = false
		_spare_crosshair = crosshair
	crosshair = null
	if _live(label):
		label.visible = false
		_spare_label = label
	label = null
	KillPov.mark_replay_camera(_camera, false)
	_camera = null


## Puts the killer's screen under [param parent] and hands it to a kill view or killcam host as its `present_fn`.
## Its spare is built at the end of this frame, unless [param defer_spare] is false: then the caller builds it
## with [method prepare_spare] (a client that draws, a frame each: two in one frame made a 414 ms frame).
static func mount(parent: Node, game: Object, target: Object, label: String, defer_spare := true) -> Node:
	var view := new()
	view.name = label
	view.feel_rules = game.get(&"feel_rules") as AwViewFeel
	view.ads_rules = game.get(&"ads_rules") as AwAdsRules
	var feel: Variant = game.get(&"combat_feel")
	if feel != null:
		view.recoil.rules = feel.get(&"recoil") as DotWeaponRecoilRules
	view.recoil.catalogue = ArenaContent.weapon_catalogue()
	var rate: Variant = game.get(&"tick_rate")
	if rate != null:
		view.recoil.tick_rate = int(rate)
	var stack: Variant = game.get(&"player_stack")
	if stack != null and stack.physics != null and stack.physics.layout != null:
		var layers: Array[StringName] = [&"world", &"prop"]
		view.world_mask = stack.physics.layout.mask_of(layers)
	view.rules = game
	view.killer_look_fn = func() -> Array: return look_for(game, killer_of(target))
	parent.add_child(view)
	target.set(&"present_fn", view.present)
	# The first kill view found its 30-odd view-model nodes unbuilt (KillerHands, 125 ms); build the spare now, off the kill's frame.
	if defer_spare:
		view._prepare_spare.call_deferred()
	return view
