extends "arena_client_vars.gd"

## The client's warm-up: the weapon views, flash scenes, effect pool, drop bodies and kill screens built a slice
## a frame under the loading cover, and the weapon-model preparation that goes with them.

const ArenaLoadTimeline := preload("arena_load_timeline.gd")

## Whether the local weapon draws its own shot. True on a client shell carrying a
## arena-weapons with `AwShotFx`; through `has_method`, because an older shell's copy
## of the rig has no `shot_fx` and a call by name would not compile there.
func weapon_draws_shots() -> bool:
	if player == null or player.weapons == null or not player.weapons.has_method(&"shot_fx"):
		return false

	return player.weapons.call(&"shot_fx") != null

## One frame of the warm-up: weapon views, then the flash scenes, then one draw of every flash and
## the explosion in front of the camera (the first shot cost 375-420 ms, the first explosion 95).
## How many throwaway people the warm-up builds, so their art and materials are loaded before the first bot.
const PREWARM_FIGURES := 4
## Effects parked for other players' hands: one per seat of a full 16 v 16, and a charge ball for a squad's worth.
const FX_POOL_SHOTS := 32
const FX_POOL_CHARGES := 12
const FX_POOL_FLASH_FRAMES := 600

## Builds the pool every remote hand takes its first shot, charge and flash from, [param budget_msec] a frame.
## True when it is full. The first shot of each of 24 bots built its own in the tick (345 ms in the owner's profile).
func _fill_fx_pool(budget_msec: float) -> bool:
	if fx_pool == null:
		fx_pool = AwFxPool.new()
		fx_pool.name = "FxPool"
		add_child(fx_pool)
	var full := fx_pool.fill(FX_POOL_SHOTS, FX_POOL_CHARGES, budget_msec)
	var _drawn := fx_pool.fill_flashes()
	return full

func _prewarm_tick() -> void:
	var body: Variant = _warm.get("body")
	if not is_instance_valid(body) or body.camera == null:
		_prewarm_end()
		return
	var tick_start := Time.get_ticks_usec()
	var phase_now := int(_warm.phase)
	match phase_now:
		0:
			var arts: Array = _warm.arts
			var until := Time.get_ticks_msec() + (int(gate.call(&"slice_msec", 8)) if gate.has_method(&"slice_msec") else 8)
			while _warm.next < arts.size() and Time.get_ticks_msec() < until:
				if not is_instance_valid(_warm.spare):
					break
				(_warm.spare as AwViewModel).prewarm(arts[_warm.next] as AwWeaponVisual)
				_warm.next += 1
			if _warm.next >= arts.size() or not is_instance_valid(_warm.spare):
				if is_instance_valid(_warm.spare):
					(_warm.spare as Node).queue_free()
				_warm.erase("spare")
				gate.warm_up(AwViewModel.prepared_materials())
				gate.warm_up(AwShotFx.warm())
				_warm.phase = 1
				ArenaLoadTimeline.mark("prewarm 0 done: view models of %d arts, own work %d ms" % [arts.size(), int(_warm_work_usec.get(0, 0) + Time.get_ticks_usec() - tick_start) / 1000])
		1:
			if not DotMuzzleFlash.available() or DotMuzzleFlash.pin_scenes(8):
				var rig: Node3D = DotMuzzleFlash.prewarm(body.camera)
				if rig != null:
					rig.position = Vector3(0.0, 0.0, -1.5)
				_warm.rig = rig
				# One pool per size and view, built a node a frame, for the first real shot to take.
				var host: Node = player.weapons.call(&"shot_fx") if weapon_draws_shots() else self
				for category in ["pistol", "smg", "rifle", "shotgun"]:
					for fp in [true, false]:
						DotWeaponMuzzle.warm(host, category, null, fp)
				# The first death builds bodies, joints and shapes the physics server has never made (32 ms in a web build): make and drop one now.
				if ragdolls != null:
					ragdolls.prewarm()
				if presentation != null and presentation.fx != null:
					var cam: Transform3D = body.camera.global_transform
					var at := Transform3D(Basis.IDENTITY, cam.origin - cam.basis.z * 6.0)
					presentation.fx.warm([ArenaPresentation.EXPLOSION, &"impact_spark"], at)
				_warm.phase = 2
				ArenaLoadTimeline.mark("prewarm 1 done: flash scenes, muzzle pools, explosion, own work %d ms" % (int(_warm_work_usec.get(1, 0) + Time.get_ticks_usec() - tick_start) / 1000))
		2:
			# Drop bodies for the first throw (a death drops one), a slice a frame like the views.
			var ids: Array = _warm.get("drop_ids", ArenaWeaponDropWiring.prewarm_ids())
			_warm.drop_ids = ids
			var slice := int(gate.call(&"slice_msec", 8)) if gate.has_method(&"slice_msec") else 8
			var drops_until := Time.get_ticks_msec() + slice
			_warm.drop_next = ArenaWeaponDropWiring.prewarm_step(game, ids, int(_warm.get("drop_next", 0)), drops_until)
			# Their shaders too: a parked body is outside the tree and a carried weapon is built at its carrier's
			# spawn, so the cover drew neither (first drop 163 ms, first held weapon 360 ms in the owner's profile).
			if _warm.drop_next >= ids.size() and int(_warm.get("look_next", 0)) < ids.size():
				var looks: Array = []
				_warm.look_next = ArenaWeaponDropWiring.warm_looks(ids, int(_warm.get("look_next", 0)), drops_until, looks)
				gate.warm_up(looks)
			elif _warm.drop_next >= ids.size() and int(_warm.get("screens", 0)) < KILL_SCREENS.size():
				# The killer's screen: view models holding the starting weapons, arms, flash pool, crosshair. One screen a frame.
				_warm_kill_screen(int(_warm.get("screens", 0)))
				_warm.screens = int(_warm.get("screens", 0)) + 1
			elif _warm.drop_next >= ids.size() and _warm_kill_meshes(drops_until):
				pass
			elif _warm.drop_next >= ids.size() and not _fill_fx_pool(float(slice)):
				pass
			elif _warm.drop_next >= ids.size():
				ArenaLoadTimeline.mark("prewarm: fx pool holds %d shot effects, %d charge balls, %d flashes" % [fx_pool.spare_shots(), fx_pool.spare_charges(), fx_pool.flash_count()])
				_warm.phase = 3
				ArenaLoadTimeline.mark("prewarm 2 done: weapon drop bodies, own work %d ms" % (int(_warm_work_usec.get(2, 0) + Time.get_ticks_usec() - tick_start) / 1000))
		3:
			# What the first bot, the first hit and the first kill would otherwise load mid-match:
			# a few people's figures (rig, art, materials), the health bar's mesh and the hit sounds.
			ArenaPlayer.warm_health_tag()
			var slice_end := Time.get_ticks_msec() + (int(gate.call(&"slice_msec", 8)) if gate.has_method(&"slice_msec") else 8)
			while int(_warm.get("figures", 0)) < PREWARM_FIGURES and Time.get_ticks_msec() < slice_end:
				var key := StringName("prewarm-%d" % int(_warm.get("figures", 0)))
				var host := Node3D.new()
				add_child(host)
				var person := DotHumanoidFigure.new()
				host.add_child(person)
				person.build(ArenaAvatars.look_of(ArenaAvatars.stock_avatar(key), key), 1.8)
				host.queue_free()
				_warm.figures = int(_warm.get("figures", 0)) + 1
			if int(_warm.get("figures", 0)) >= PREWARM_FIGURES:
				_warm.phase = 4
				ArenaLoadTimeline.mark("prewarm 3 done: figures, own work %d ms" % (int(_warm_work_usec.get(3, 0) + Time.get_ticks_usec() - tick_start) / 1000))
		_:
			_warm.frames += 1
			# The shared flashes build a node a frame; a renderer that never finishes one must not hold the cover.
			var flashes_drawn: bool = fx_pool == null or fx_pool.flashes_ready() or int(_warm.frames) > FX_POOL_FLASH_FRAMES
			if _warm.frames >= 3 and DotWeaponMuzzle.warm_done() and flashes_drawn and not (_previews != null and _previews.is_warming()):
				_prewarm_end()
	# CPU time this phase spent in its own ticks (a slow frame with little of it is the renderer).
	_warm_work_usec[phase_now] = int(_warm_work_usec.get(phase_now, 0)) + Time.get_ticks_usec() - tick_start

## The two screens that draw a killer's view: the kill view's and the final killcam's.
const KILL_SCREENS: Array[String] = ["KillViewScreen", "KillcamScreen"]

## Builds kill screen [param index]'s parked nodes and hands their meshes and materials to the cover.
func _warm_kill_screen(index: int) -> void:
	var screen := get_node_or_null(KILL_SCREENS[index])
	if screen != null and screen.has_method(&"warm"):
		# Every starting weapon for the kill view (most kills); the final killcam plays once a match, the primary does.
		var weapons: Array = ArenaContent.default_loadout()
		if index > 0:
			weapons = [ArenaContent.Roles.resolve(&"primary")]
		gate.warm_up(screen.call(&"warm", weapons))
	if index == 0 and killcam_shots != null:
		gate.warm_up(killcam_shots.warm())

## Holds every weapon once on the kill view's own kind of view model, a slice a frame: true while there is more.
func _warm_kill_meshes(until_msec: int) -> bool:
	var screen := get_node_or_null(KILL_SCREENS[0])
	var arts: Array = _warm.get("kill_ids", AwWeaponArtTable.table().keys())
	_warm.kill_ids = arts
	var at := int(_warm.get("kill_next", 0))
	if screen == null or not screen.has_method(&"warm_meshes") or at >= arts.size():
		return false
	var began := Time.get_ticks_usec()
	_warm.kill_next = int(screen.call(&"warm_meshes", arts, at, until_msec))
	_warm.kill_usec = int(_warm.get("kill_usec", 0)) + Time.get_ticks_usec() - began
	if int(_warm.kill_next) >= arts.size():
		ArenaLoadTimeline.mark("prewarm: kill view held %d weapons, own work %d ms" % [arts.size(), int(_warm.kill_usec) / 1000])
	return true

## Parks the drop bodies again after the game was rebuilt (a map or mode change frees the drop layer and its
## parked bodies with it, and the warm-up above runs once): under the new map's cover, a slice a frame.
func _repool_drops() -> void:
	if DotPlatform.is_headless() or gate == null or _repool_next >= 0:
		return
	# The old map's hands took their effects with them: top the pool up as well as the drop layer.
	var fx_short := fx_pool != null and (fx_pool.spare_shots() < FX_POOL_SHOTS or fx_pool.spare_charges() < FX_POOL_CHARGES)
	if not ArenaWeaponDropWiring.needs_pool(game) and not fx_short:
		return
	_repool_next = 0
	gate.hold(&"pools", "Preparing weapons")
	get_tree().process_frame.connect(_repool_tick)

func _repool_tick() -> void:
	var ids := ArenaWeaponDropWiring.prewarm_ids()
	var slice := int(gate.call(&"slice_msec", 8)) if gate != null and gate.has_method(&"slice_msec") else 8
	if ArenaWeaponDropWiring.needs_pool(game):
		_repool_next = ArenaWeaponDropWiring.prewarm_step(game, ids, _repool_next, Time.get_ticks_msec() + slice)
		if _repool_next < ids.size():
			return
	if fx_pool != null and not fx_pool.fill(FX_POOL_SHOTS, FX_POOL_CHARGES, float(slice)):
		return
	_repool_next = -1
	get_tree().process_frame.disconnect(_repool_tick)
	ArenaLoadTimeline.mark("drop bodies parked again for the new map")
	if gate != null:
		gate.release(&"pools")

func _prewarm_end() -> void:
	if get_tree().process_frame.is_connected(_prewarm_tick):
		get_tree().process_frame.disconnect(_prewarm_tick)
	if is_instance_valid(_warm.get("spare")):
		(_warm.spare as Node).queue_free()
	if is_instance_valid(_warm.get("rig")):
		(_warm.rig as Node).queue_free()
	_warm = {}
	# Draw the (hidden) loadout screen on the solo offer, so the first B finds the cards made; a dot-menu without it just draws on B.
	if loadout_menu != null and loadout_menu.has_method(&"prepare"):
		var began := Time.get_ticks_usec()
		var _drawn: Variant = loadout_menu.call(&"prepare")
		ArenaLoadTimeline.mark("prewarm: loadout screen drawn hidden, %d ms" % ((Time.get_ticks_usec() - began) / 1000))
	ArenaLoadTimeline.mark("prewarm end")
	if gate != null:
		gate.release(&"weapons")

## Builds every weapon's first-person view once on a spare view model, under the loading cover.
func _prewarm_weapons(body: ArenaPlayer) -> void:
	# Headless draws nothing, so the spare views only add nodes, memory and frames (perf smoke).
	if DotPlatform.is_headless() or gate == null or gate.is_open() or body == null or body.camera == null or view_model == null:
		return
	var spare := AwViewModel.new()
	spare.name = "WeaponPrewarm"
	spare.feel_rules = view_model.feel_rules
	spare.ads_rules = view_model.ads_rules
	spare.feel = view_model.feel
	spare.view_layer = view_model.view_layer
	spare.finish_materials = view_model.finish_materials
	spare.finish_metal = view_model.finish_metal
	spare.finish_metal_roughness = view_model.finish_metal_roughness
	spare.finish_polymer_roughness = view_model.finish_polymer_roughness
	spare.finish_wood_roughness = view_model.finish_wood_roughness
	spare.finish_lift = view_model.finish_lift
	spare.visible = false
	body.camera.add_child(spare)
	gate.hold(&"weapons", "Preparing weapons")
	# The loadout menu's weapon pictures, one a frame beside the view models below (they wait on the renderer, this on a frame each), so B finds them drawn.
	if loadout_menu != null:
		weapon_previews().warmed.connect(func() -> void: ArenaLoadTimeline.mark("prewarm: %d weapon pictures, own work %d ms" % [weapon_previews().cached_count(), int(weapon_previews().warm_msec())]), CONNECT_ONE_SHOT)
		weapon_previews().warm()
	_warm = {"body": body, "spare": spare, "arts": AwWeaponArtTable.table().values(), "next": 0, "phase": 0, "frames": 0, "rig": null}
	# A tick on process_frame, not an await: a coroutine resumed after this client was freed is an
	# engine error, while a connection to a method dies with the object.
	get_tree().process_frame.connect(_prewarm_tick)

## Reads every weapon's model file once, a few ms a frame under the loading cover (also headless: it is
## only file reads), so the first equip of each - a bot picking one up, a pickup, a drop - does not pay
## 90-110 ms for the load in the middle of a fight. Hitch capture: AwModelCache.warm was never called.
func _prewarm_models() -> void:
	if _model_paths_next >= 0 or gate == null or gate.is_open():
		return
	_model_paths = []
	for art: Variant in AwWeaponArtTable.table().values():
		if art is AwWeaponVisual and (art as AwWeaponVisual).has_model():
			_model_paths.append((art as AwWeaponVisual).model_path)
	_model_paths_next = 0
	ArenaLoadTimeline.mark("model reads start: %d files" % _model_paths.size())
	gate.hold(&"weapon_models", "Preparing weapon models")
	get_tree().process_frame.connect(_prewarm_models_tick)

func _prewarm_models_tick() -> void:
	var until := Time.get_ticks_msec() + (int(gate.call(&"slice_msec", 8)) if gate != null and gate.has_method(&"slice_msec") else 8)
	while _model_paths_next < _model_paths.size() and Time.get_ticks_msec() < until:
		AwModelCache.warm([_model_paths[_model_paths_next]])
		_model_paths_next += 1
	if _model_paths_next >= _model_paths.size():
		if get_tree().process_frame.is_connected(_prewarm_models_tick):
			get_tree().process_frame.disconnect(_prewarm_models_tick)
		if gate != null:
			gate.release(&"weapon_models")
