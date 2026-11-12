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
## False skips the weapon warm-up below (views, flashes, effect pool, drop bodies, kill screens): the perf bench's `--prewarm 0`,
## for the A/B of what it buys a first shot. Read when the local player first spawns.
static var prewarm_weapons_enabled := true

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
			_prewarm_phase0(tick_start)
		1:
			_prewarm_phase1(body, tick_start)
		2:
			_prewarm_phase2(tick_start)
		3:
			_prewarm_phase3(tick_start)
		_:
			_warm.frames += 1
			# The shared flashes build a node a frame; a renderer that never finishes one must not hold the cover.
			var flashes_drawn: bool = fx_pool == null or fx_pool.flashes_ready() or int(_warm.frames) > FX_POOL_FLASH_FRAMES
			if _warm.frames >= 3 and DotWeaponMuzzle.warm_done() and flashes_drawn and not (_previews != null and _previews.is_warming()):
				_prewarm_end()
	# CPU time this phase spent in its own ticks (a slow frame with little of it is the renderer).
	_warm_work_usec[phase_now] = int(_warm_work_usec.get(phase_now, 0)) + Time.get_ticks_usec() - tick_start

## Phase 3: the figures, the health bar and the hit sounds.
func _prewarm_phase3(tick_start: int) -> void:
	# What the first bot, the first hit and the first kill would otherwise load mid-match:
	# a few people's figures (rig, art, materials), the health bar's mesh and the hit sounds.
	ArenaPlayer.warm_health_tag()
	var slice_end := Time.get_ticks_msec() + (int(gate.call(&"slice_msec", 8)) if gate.has_method(&"slice_msec") else 8)
	while int(_warm.get("figures", 0)) < PREWARM_FIGURES and Time.get_ticks_msec() < slice_end:
		var figure_began := Time.get_ticks_usec()
		var key := StringName("prewarm-%d" % int(_warm.get("figures", 0)))
		var host := Node3D.new()
		add_child(host)
		var person := DotHumanoidFigure.new()
		host.add_child(person)
		person.build(ArenaAvatars.look_of(ArenaAvatars.stock_avatar(key), key), 1.8)
		host.queue_free()
		_step_mark("figure %d" % int(_warm.get("figures", 0)), figure_began)
		_warm.figures = int(_warm.get("figures", 0)) + 1
	if int(_warm.get("figures", 0)) >= PREWARM_FIGURES:
		_warm.phase = 4
		ArenaLoadTimeline.mark("prewarm 3 done: figures, own work %d ms" % (int(_warm_work_usec.get(3, 0) + Time.get_ticks_usec() - tick_start) / 1000))


## Phase 2: weapon drop bodies, their shaders, the kill screens, the effect pool.
func _prewarm_phase2(tick_start: int) -> void:
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
		var screen_began := Time.get_ticks_usec()
		_warm_kill_screen(int(_warm.get("screens", 0)))
		_step_mark("kill screen %d" % int(_warm.get("screens", 0)), screen_began)
		_warm.screens = int(_warm.get("screens", 0)) + 1
	elif _warm.drop_next >= ids.size() and _warm_kill_meshes(drops_until):
		pass
	elif _warm.drop_next >= ids.size() and not _fill_fx_pool(float(slice)):
		pass
	elif _warm.drop_next >= ids.size():
		ArenaLoadTimeline.mark("prewarm: fx pool holds %d shot effects, %d charge balls, %d flashes" % [fx_pool.spare_shots(), fx_pool.spare_charges(), fx_pool.flash_count()])
		_warm.phase = 3
		ArenaLoadTimeline.mark("prewarm 2 done: weapon drop bodies, own work %d ms" % (int(_warm_work_usec.get(2, 0) + Time.get_ticks_usec() - tick_start) / 1000))


## Phase 1: the muzzle flash scenes, the shot pools, the first explosion.
func _prewarm_phase1(body: Variant, tick_start: int) -> void:
	# Items while the slice lasts: built together these were one 410-650 ms frame on staging02, one a frame 14 frames.
	var items_until := Time.get_ticks_msec() + (int(gate.call(&"slice_msec", 8)) if gate.has_method(&"slice_msec") else 8)
	while int(_warm.get("step", 0)) < PHASE1_STEPS and Time.get_ticks_msec() < items_until:
		if not _prewarm_one_step(body, int(_warm.get("step", 0))):
			break
		_warm.step = int(_warm.get("step", 0)) + 1
	if int(_warm.get("step", 0)) >= PHASE1_STEPS:
		_warm.phase = 2
		ArenaLoadTimeline.mark("prewarm 1 done: flash scenes, muzzle pools, explosion, own work %d ms" % (int(_warm_work_usec.get(1, 0) + Time.get_ticks_usec() - tick_start) / 1000))


## Phase 0: the view models of every weapon art, a slice a frame.
func _prewarm_phase0(tick_start: int) -> void:
	var arts: Array = _warm.arts
	var until := Time.get_ticks_msec() + (int(gate.call(&"slice_msec", 8)) if gate.has_method(&"slice_msec") else 8)
	while _warm.next < arts.size() and Time.get_ticks_msec() < until:
		if not is_instance_valid(_warm.spare):
			break
		var spare := _warm.spare as AwViewModel
		var step_began := Time.get_ticks_usec()
		var stage_now := int(_warm.get("stage", 0)) if bool(_warm.get("stepping", false)) else 0
		_warm.stage = stage_now + 1
		var step_of := "view %d stage %d" % [int(_warm.next), stage_now]
		# One weapon's equip split into stages (a cold sight fit, cuts and red dot are 220-440 ms in one go). As many
		# stages a frame as fit the slice: one a frame was ~250 frames for 27 weapons, most stages well under the
		# slice, and every load frame also runs the match's ticks (11.6 s of a 21 s cover on staging02).
		if bool(_warm.get("stepping", false)):
			if not spare.prewarm_step():
				_warm.stepping = false
				_warm.next += 1
		else:
			_warm.stepping = spare.prewarm_begin(arts[_warm.next] as AwWeaponVisual)
			if not _warm.stepping:
				_warm.next += 1
		_step_mark(step_of, step_began)
	if _warm.next >= arts.size() or not is_instance_valid(_warm.spare):
		if is_instance_valid(_warm.spare):
			(_warm.spare as Node).queue_free()
		_warm.erase("spare")
		gate.warm_up(AwViewModel.prepared_materials())
		gate.warm_up(AwShotFx.warm())
		_warm.phase = 1
		ArenaLoadTimeline.mark("prewarm 0 done: view models of %d arts, own work %d ms" % [arts.size(), int(_warm_work_usec.get(0, 0) + Time.get_ticks_usec() - tick_start) / 1000])


## The muzzle pools phase 1 builds, one size and view a frame.
const MUZZLE_CATEGORIES: Array[String] = ["pistol", "smg", "rifle", "shotgun"]
## Phase 1's items: the flash scenes, a muzzle pool per category and view, the layered shot, the launcher round, a ragdoll, two effects.
const PHASE1_STEPS := 2 + 8 + 4
## A single warm-up item over this is stamped on the load timeline, so a slow frame names its cause.
const STEP_MARK_MSEC := 50

## Phase 1 item [param step]. False while it is still waiting (the flash scenes pin over several frames).
func _prewarm_one_step(body: Variant, step: int) -> bool:
	var began := Time.get_ticks_usec()
	var what := ""
	var host: Node = player.weapons.call(&"shot_fx") if weapon_draws_shots() else self
	if step == 0:
		what = "flash scenes"
		if DotMuzzleFlash.available() and not (_take_flash_scenes() and DotMuzzleFlash.pin_scenes(8) and _warm_flash_materials(body)):
			_step_mark(what, began)
			return false
	elif step == 1:
		what = "flash draw"
		var rig: Node3D = DotMuzzleFlash.prewarm(body.camera)
		if rig != null:
			rig.position = Vector3(0.0, 0.0, -1.5)
		_warm.rig = rig
	elif step < 10:
		# One pool per size and view, built a node a frame, for the first real shot to take.
		var category := MUZZLE_CATEGORIES[(step - 2) / 2]
		var fp := (step - 2) % 2 == 0
		what = "muzzle %s %s" % [category, "view" if fp else "world"]
		DotWeaponMuzzle.warm(host, category, null, fp)
	elif step == 10:
		# The first layered shot builds dot-audio's manager, room and player (65 ms on the first knife swing): now, under the cover.
		what = "layered shot"
		if host != self and host.has_method(&"prewarm_layers"):
			var _layered: Variant = host.call(&"prewarm_layers")
	elif step == 11:
		# The launcher's round: its glowing sphere compiled on the first launcher shot.
		what = "launcher round"
		if projectile_view != null:
			gate.warm_up(projectile_view.warm())
	elif step == 12:
		# The first death builds bodies, joints and shapes the physics server has never made (32 ms in a web build): make and drop one now.
		what = "ragdoll"
		if ragdolls != null:
			ragdolls.prewarm()
	else:
		what = "explosion, impact spark"
		if presentation != null and presentation.fx != null:
			var cam: Transform3D = body.camera.global_transform
			var at := Transform3D(Basis.IDENTITY, cam.origin - cam.basis.z * 6.0)
			presentation.fx.warm([ArenaPresentation.EXPLOSION, &"impact_spark"], at)
	_step_mark(what, began)
	return true

## Every muzzle flash scene's path, as [method DotMuzzleFlash.pin_scenes] loads them.
static func _flash_scene_paths() -> Array[String]:
	var out: Array[String] = []
	for s: int in DotMuzzleFlash.FOLDERS:
		for v in range(1, DotMuzzleFlash.VARIANTS + 1):
			out.append("%s%s%02d.tscn" % [DotMuzzleFlash.ROOT, DotMuzzleFlash.FOLDERS[s], v])
	return out

## Starts reading the flash scenes on the loader's threads while phase 0 runs: read inline,
## one scene was a 205 ms frame on staging02.
func _request_flash_scenes() -> void:
	if not DotMuzzleFlash.available():
		return
	var asked: Array[String] = []
	for path in _flash_scene_paths():
		if ResourceLoader.exists(path) and ResourceLoader.load_threaded_request(path) == OK:
			asked.append(path)
	_warm.flash_asked = asked

## Takes the flash scenes the loader has read, false while one is still reading. Held in
## [member _warm] until the flash's own pin loads them again from the cache.
func _take_flash_scenes() -> bool:
	var asked: Array = _warm.get("flash_asked", [])
	for path: Variant in asked:
		if ResourceLoader.load_threaded_get_status(str(path)) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			return false
	var landed: Array = _warm.get("flash_landed", [])
	for path: Variant in asked:
		landed.append(ResourceLoader.load_threaded_get(str(path)))
	_warm.flash_landed = landed
	_warm.flash_asked = []
	return true

## Draws every flash scene's materials on tiny quads, rounds sized to the gate's warm budget, and
## true once done: drawn first as four whole flashes, their compiles were 200-540 ms frames.
func _warm_flash_materials(body: Variant) -> bool:
	if _warm.has("flash_warm"):
		return not is_instance_valid(_warm.flash_warm)
	var items: Array = []
	for path in _flash_scene_paths():
		var scene := load(path) as PackedScene  # pinned: a cache hit
		if scene != null:
			var node := scene.instantiate()
			var _found := DotRenderWarmup.collect(node, items)
			node.free()
	_warm.flash_landed = []
	var warm := DotRenderWarmup.new()
	warm.name = "FlashWarmup"
	warm.budget_msec = float(gate.get(&"warm_budget_msec")) if &"warm_budget_msec" in gate else 100.0
	warm.process_mode = Node.PROCESS_MODE_ALWAYS
	warm.add_items(items)
	_warm.flash_warm = warm
	body.camera.add_child(warm)
	warm.start()
	ArenaLoadTimeline.mark("prewarm: drawing %d flash materials and meshes" % warm.item_count())
	return false

## Stamps warm-up item [param what] when its own work since [param began_usec] passed [constant STEP_MARK_MSEC].
func _step_mark(what: String, began_usec: int) -> void:
	var msec := (Time.get_ticks_usec() - began_usec) / 1000
	if msec >= STEP_MARK_MSEC:
		ArenaLoadTimeline.mark("prewarm step %s: %d ms" % [what, msec])

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
	if is_instance_valid(_warm.get("flash_warm")):
		(_warm.flash_warm as Node).queue_free()
	# An end before phase 1 (the body went) takes what the loader still holds, or those scenes outlive the run.
	for path: Variant in _warm.get("flash_asked", []):
		var _dropped := ResourceLoader.load_threaded_get(str(path))
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
	if not prewarm_weapons_enabled or DotPlatform.is_headless() or gate == null or gate.is_open() or body == null or body.camera == null or view_model == null:
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
	_request_flash_scenes()
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
	# The reads run on the loader's own threads: a big model read inline held one frame for seconds
	# (7455 ms on a slow disk), and the tick below only takes a file once it has landed.
	# Not headless: the dummy renderer's mesh storage is not safe against a loader thread creating
	# meshes beside the main thread (RID errors, a mesh leaked at exit, an odd viewarms failure), and
	# there the tick below simply loads each file itself, a few ms a frame.
	if DisplayServer.get_name() != "headless":
		for path: Variant in _model_paths:
			var real := AwModelCache.resolve(str(path))
			if ResourceLoader.exists(real):
				ResourceLoader.load_threaded_request(real)
	ArenaLoadTimeline.mark("model reads start: %d files" % _model_paths.size())
	gate.hold(&"weapon_models", "Preparing weapon models")
	get_tree().process_frame.connect(_prewarm_models_tick)

## A client freed mid-read takes what the loader holds for it, or those scenes outlive the run: every
## requested file (not only those the tick has not reached), the tick disconnected so it cannot take
## one after this, and the model cache emptied so no scene or mesh outlives the renderer at exit.
func _drain_model_reads() -> void:
	if is_inside_tree() and get_tree().process_frame.is_connected(_prewarm_models_tick):
		get_tree().process_frame.disconnect(_prewarm_models_tick)
	if _model_paths_next < 0:
		return
	for path: Variant in _model_paths:
		var real := AwModelCache.resolve(str(path))
		if ResourceLoader.load_threaded_get_status(real) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			var _dropped := ResourceLoader.load_threaded_get(real)
	_model_paths_next = _model_paths.size()
	AwModelCache.clear()

func _prewarm_models_tick() -> void:
	var until := Time.get_ticks_msec() + (int(gate.call(&"slice_msec", 8)) if gate != null and gate.has_method(&"slice_msec") else 8)
	while _model_paths_next < _model_paths.size() and Time.get_ticks_msec() < until:
		var real := AwModelCache.resolve(str(_model_paths[_model_paths_next]))
		if ResourceLoader.load_threaded_get_status(real) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			break
		# Landed (or never requested). Taking it from the loader frees the loader's hold on it; kept in
		# `landed` while the cache loads it, that load is a cache hit, a few ms at most.
		var landed: Resource = ResourceLoader.load_threaded_get(real) if ResourceLoader.load_threaded_get_status(real) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE else null
		AwModelCache.warm([_model_paths[_model_paths_next]])
		landed = null
		_model_paths_next += 1
	if _model_paths_next >= _model_paths.size():
		if get_tree().process_frame.is_connected(_prewarm_models_tick):
			get_tree().process_frame.disconnect(_prewarm_models_tick)
		if gate != null:
			gate.release(&"weapon_models")
