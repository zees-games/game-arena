extends "arena_client_prewarm.gd"

const ArenaContentGroups := preload("arena_content_groups.gd")

## Milliseconds of level building between frames while the map loads ([method _enter_level]).
const LEVEL_SLICE_MS := 10

## Whether E is the prop tool's key here: only in a mode where players use props. Anywhere
## else E is the launch, which is what most of the arena's modes want it for.
func props_on_e() -> bool:
	if game == null:
		return false
	# The mode the server says, not the one this client was built with: a client's own
	# `mode` is never replaced, and in Siege it read free-for-all and E launched.
	var shown := game.displayed_mode()
	return shown != null and shown.player_props

## The launch's action: the Launch row (E), or its own row (X) in a mode where the Launch
## key is the prop tool's grab.
func launch_action() -> StringName:
	return ArenaBindings.LAUNCH_PROPS if props_on_e() else ArenaBindings.LAUNCH

## The keys the HUD's buttons, hints and prompts name, from the key table as the player
## has it bound. Slide says C while Duck is on its default, because that is where C slides.
func _hud_keys() -> void:
	if hud == null or presentation == null or presentation.bindings == null:
		return
	var table: DotMenuBindings = presentation.bindings
	hud.keys[&"jump"] = table.key_for(&"dot_fps_jump")
	hud.keys[&"dash"] = table.key_for(ArenaBindings.DASH)
	hud.keys[&"chat"] = table.key_for(ArenaBindings.CHAT)
	hud.keys[&"scoreboard"] = table.key_for(ArenaBindings.SCOREBOARD)
	hud.keys[&"reload"] = table.key_for(ArenaBindings.RELOAD)
	hud.keys[&"fire_mode"] = table.key_for(ArenaBindings.FIRE_MODE)
	hud.keys[&"use"] = table.key_for(ArenaBindings.USE)
	hud.keys[&"help"] = table.key_for(DotMenuBindings.HELP_ACTION)
	hud.keys[&"maps"] = table.key_for(&"dot_menu_maps")
	hud.keys[&"loadout"] = table.key_for(&"dot_menu_loadout") if loadout_menu != null else ""
	hud.keys[&"launch"] = table.key_for(launch_action())
	hud.keys[&"roam"] = table.key_for(ArenaBindings.ROAM)
	for i in range(ArenaBindings.SLOTS.size()):
		hud.keys[StringName("slot_%d" % (i + 1))] = table.key_for(ArenaBindings.SLOTS[i])
	hud.keys[&"slide"] = "C" if _slide_on_c() else table.key_for(ArenaBindings.DUCK)

## Adds [param key] to [param action] if neither is missing and it is not bound already.
static func _add_key(action: StringName, key: Key) -> void:
	if action == &"" or not InputMap.has_action(action):
		return

	for existing in InputMap.action_get_events(action):
		if existing is InputEventKey and (existing as InputEventKey).physical_keycode == key:
			return

	var event := InputEventKey.new()
	event.physical_keycode = key
	InputMap.action_add_event(action, event)

## C slides as well as Duck, while Duck is on its default key and no other row has been
## given C. A slide IS a duck at a run, and C is where the genre puts it. Deferred after a
## rebind: the table applies the row after the setting changes, and that apply would take
## C off again.
##
## [b]Taken off again when another row gets C.[/b] C is not a stored binding, so the
## table's swap cannot see it: binding Last weapon to C would otherwise have one press
## switch weapons and slide.
func _add_slide_key() -> void:
	if _sampler == null:
		return
	var duck := _sampler.actions.get("crouch", &"") as StringName
	if _slide_on_c():
		_add_key(duck, KEY_C)
	elif presentation != null and presentation.bindings != null:
		var row := presentation.bindings.row_for_action(duck)
		if not row.is_empty():
			var _bound := presentation.bindings.apply_row(row, presentation.bindings.stored(row, presentation.settings))

func _build_interface_rest() -> void:
	_add_slide_key()
	_hud_keys()

## Puts the drawn level on the layout's `world` layer.
func _classify_level() -> void:
	if _level == null or game == null or game.player_stack == null:
		return

	var done := game.player_stack.classify_tree(_level, &"world")
	DotLog.debug(CHANNEL, "level classified", {"bodies": done})

## Builds the movers and the drawn level in slices behind the cover, then optionally lifts the map hold.
func _enter_level(release: bool) -> void:
	_level_busy = true
	# 10 ms between yields, not the 40 ms default: the cover is up, but bots and the
	# network keep ticking behind it, and a 40 ms build frame is a hitch they feel.
	var slice := DotFrameSlice.new(LEVEL_SLICE_MS)
	await game.build_map_io_async(slice)
	ArenaLoadTimeline.mark("map_io_built")
	var drawn := game.map
	var made: Node3D = await game.map.to_scene_async(slice)
	ArenaLoadTimeline.mark("map_scene_built")
	if _level != null and is_instance_valid(_level):
		remove_child(_level)
		# free(), not queue_free(): a deferred free leaves two levels drawn for a frame.
		_level.free()
	_level = made
	_level_map = drawn
	_classify_level()
	add_child(_level)
	_light()
	_level_busy = false
	if release:
		gate.release(&"map")

## The world was replaced under this client.
func _on_map_changed(map: DotMapDef) -> void:
	# Cover and stop the frozen body until the new level is in (released below).
	gate.hold(&"map", "Loading the map")
	while _level_busy:
		await get_tree().process_frame
	# The new map's own files (its bake, its rides) are a download group of their own; fetch them first.
	var _topped: DotResult = await ArenaContentGroups.top_up(map.id)
	# **The client has to ADOPT the map it was handed, and this is where that was missing.**
	# `ArenaGame.map` is assigned in exactly three places — `setup`, the module's mode change, and
	# `change_map` — and every one of them runs on the SERVER.
	var adopted := (
		game.map if game.map != null and game.map.id == map.id else ArenaMap.by_id(map.id)
	)

	if adopted != null:
		game.map = adopted
		# **And every player already here moves with it** (2026-10-18).
		for player in game.players():
			if player != null and player.map_in_hand() != adopted:
				player.apply_map_movement(game.map_movement())
				player.rebind_map(adopted)
	else:
		# A delivered map this build has no geometry for. The level cannot be drawn,
		# and drawing the OLD one is what this whole comment is about — so say so
		# rather than silently showing a world that is not there.
		DotLog.warn(CHANNEL, "the announced map has no local geometry", {
			"map": String(map.id),
		})

	if _level_map != null and _level_map == game.map:
		# The game was not rebuilt (ArenaMapSession: the client was set up on this map; a rebuild makes a
		# new ArenaMap), so the drawn level and the drop pool are still this map's. A map with no movers has no map_io.
		gate.release(&"map")
	else:
		# The rebuilt game's drop layer is empty; fill it before the cover lifts (the hold must precede the map's release).
		_repool_drops()
		await _enter_level(true)

	# A mirroring client's combat manager is never rebuilt — `change_map` is the server's —
	# and its trace is what the copies of every rocket and grenade bounce off. Left alone,
	# a grenade on the new map bounces off the walls of the old one.
	if not _offline and game.combat != null:
		game.combat.trace = game.map.shot_trace()
	if game.projectiles != null:
		game.projectiles.clear()
	if ragdolls != null:
		# A body lying on the old map's floor would hang in the new one's air.
		ragdolls.clear()

	if presentation != null:
		# Everything drawn for the old map is meaningless now -- a decal is a hole in a
		# wall that no longer exists, and a decal ring that survives a map change is one
		# that survives the map it was about.
		presentation.on_map_changed(game.map.id if game.map != null else &"")

	if hud != null:
		# An imported map is somebody else's work, and its author is named where it starts.
		var by := (
			", by %s" % game.map.author
			if game.map != null and game.map.is_imported() and game.map.author != "" else ""
		)
		hud.notice("Now playing %s%s." % [map.name_or_id(), by])

## Solo: a map (`map:<id>`) or a mode on this map (`mode:<id>`), now. The game changes and the
## level is rebuilt as a server's change would have it rebuilt ([method _on_map_changed]).
func change_from_menu(id: StringName, picked_mode: StringName = &"") -> DotResult:
	if host_console != null:
		return await _change_on_host(String(id), String(picked_mode))
	if not _offline:
		return DotResult.fail(DotError.CODE_STATE, "The server changes the map.")
	var text := String(id)
	var map := game.map
	var mode: ArenaMode = null
	if text.begins_with("map:"):
		var fetched := await _fetch_picked(StringName(text.substr(4)))
		if not fetched.ok:
			return fetched
		var built := _build_map(StringName(text.substr(4)))
		if not built.ok:
			return built
		map = built.value
		if String(picked_mode).begins_with("mode:"):
			mode = ArenaModes.by_id(StringName(String(picked_mode).substr(5)))
	elif text.begins_with("mode:"):
		mode = ArenaModes.by_id(StringName(text.substr(5)))
		if mode == null:
			return DotResult.fail(DotError.CODE_INVALID, "There is no mode called '%s'." % text.substr(5))
		var rebuilt := _build_map(game.map.id)
		if not rebuilt.ok:
			return rebuilt
		map = rebuilt.value
	if map == null:
		return DotResult.fail(DotError.CODE_INVALID, "There is no map called '%s'." % text)
	var changed := game.change_map(map, mode)
	if not changed.ok:
		return changed
	var def := _catalogue().get_map(map.id)
	if def != null:
		_on_map_changed.call(def)
	return DotResult.success(id)

## The cursor, from one place. A screen that wants the mouse gets it; otherwise the game does, subject to the
## browser having been clicked at least once.
func _apply_mouse() -> void:
	if _menu_open():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return

	if _awaiting_click:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

## The hit drawn on the body the server says was hit: the pack's red burst at [param point].
func _draw_body_hit(point: Vector3) -> void:
	if not weapon_draws_shots():
		return
	var fx: Object = player.weapons.call(&"shot_fx")
	if fx == null or not fx.has_method(&"play_body_hit"):
		return
	var from: Vector3 = player.global_position + Vector3(0.0, ArenaPlayer.eye_height(), 0.0)
	fx.call(&"play_body_hit", point, point - from)

## Where the camera actually is, or the origin when there is none.
func camera_position() -> Vector3:
	return player.camera.global_position if player != null and player.camera != null \
		else Vector3.ZERO

## The server confirmed this player's damage landed. The hit marker, the number and the
## sound; nothing about a hit is drawn from the client's own prediction of its shot.
func _on_hit(info: Dictionary) -> void:
	if hud == null:
		return
	var point: Vector3 = info.get("point", Vector3.ZERO)
	var victim := game.player_for(int(info.get("victim_id", 0))) if game != null else null
	# Near zero rather than zero: the wire quantises, and "no point" comes back as a few
	# millimetres off the origin.
	if point.length() < 0.05 and victim != null:
		# A hit with no point (world damage passed on): the chest of who took it.
		point = victim.global_position + Vector3(0.0, 1.3, 0.0)
	var lethal := bool(info.get("lethal", false))
	hud.note_hit(int(info.get("victim_id", 0)), float(info.get("amount", 0.0)), point, bool(info.get("headshot", false)), lethal)
	if presentation != null:
		presentation.on_hit_confirmed(lethal)
		presentation.on_body_hit(int(info.get("victim_id", 0)), point, camera_position())
	_draw_body_hit(point)

## A stomp landed somewhere: its sound and puff where it happened.
func _on_stomp(info: Dictionary) -> void:
	if presentation != null:
		presentation.on_stomp(info["point"], StringName(info["sound"]), StringName(info["effect"]))

func _on_grenade_fx(info: Dictionary) -> void:
	if presentation != null:
		presentation.on_grenade_fx(info, player.player_id if player != null else 0)

## A kill's medals and points, as the server judged them. Every client hears every
## award; the HUD draws only the followed player's own and the nemesis line on their death.
func _on_award(info: Dictionary) -> void:
	if hud == null or game == null:
		return
	var own := player.player_id if player != null else 0
	var killer := game.player_for(int(info.get("killer_id", 0)))
	var victim := game.player_for(int(info.get("victim_id", 0)))
	hud.note_award(
		info, own,
		victim.display_name if victim != null else "?",
		killer.display_name if killer != null else "?"
	)
	if presentation != null and int(info.get("killer_id", 0)) == own and own != 0:
		presentation.on_medals(info.get("medals", []))

## The server sent the replay of the view that killed this player. Not over the final killcam.
func _on_killview(clip: Dictionary, info: Dictionary) -> void:
	if killview == null or (killcam != null and killcam.is_playing()):
		return
	var shown := info.merged({})
	shown["killer"] = String(info.get("killer", ""))
	shown["victim_id"] = player.player_id if player != null else 0
	var weapon := String(info.get("weapon", ""))
	var def: DotWeaponDef = ArenaPlayer.weapon_catalogue().get_def(StringName(weapon)) if weapon != "" else null
	shown["weapon"] = def.display_name if def != null and def.display_name != "" else weapon.capitalize()
	var _started := killview.play(clip, shown)

## Where a roster row's player stands, for dot-game's look-to-gag key (J, K).
func _look_position(row: Dictionary) -> Variant:
	if game == null:
		return null
	for who: ArenaPlayer in game.players():
		if who != player and who.display_name == row["name"]:
			return who.global_position + Vector3.UP * 1.5
	return null

## The level's layers: what the third-person and spectator cameras stop against.
func _level_mask() -> int:
	var stack := game.player_stack if game != null else null
	if stack != null and stack.physics != null and stack.physics.layout != null:
		return stack.physics.layout.mask_of([&"world", &"prop"])
	return 1

## Everybody else's drawn figure, for the camera fade.
func _other_figures() -> Array:
	var out: Array = []
	if game == null:
		return out
	for id in game.player_ids():
		var other := game.player_for(id)
		# During a replay our own body is posed like everybody else's, and can stand at its lens.
		if other != null and (other != player or _replay_lens() != null) and other.body_mesh != null:
			out.append(other.body_mesh)
	return out

## The camera a kill view or final killcam is drawing through, or null when neither plays.
func _replay_lens() -> Camera3D:
	if killview != null and killview.is_active() and killview.camera != null and killview.camera.current:
		return killview.camera
	if killcam != null and killcam.is_playing() and killcam.camera != null and killcam.camera.current:
		return killcam.camera
	return null

## The camera fade follows the camera on screen. It hangs off the player's camera, which a dead
## player's death camera keeps moving while a replay plays: left to itself it faded whoever the
## replay had posed near that unseen camera (a figure gone see-through mid-replay) and nothing at
## the replay's own lens (a torso filling the screen). Called after the replay has posed the bodies.
func _fade_for_replay(delta: float) -> void:
	var fade := player.camera.get_node_or_null(^"Fade") as DotCameraFade if player != null and player.camera != null else null
	if fade == null:
		return
	var lens := _replay_lens()
	if lens == null:
		if not fade.is_processing():
			fade.set_process(true)
		return
	fade.set_process(false)
	# Focus on the lens itself: the near test only, so a body inside the lens is hidden outright, and
	# at once: the replay steps at the killer's speed, and an eased fade left a torso solid for a frame.
	var _n := fade.update(lens.global_position, lens.global_position, maxf(delta, 1.0))

func _set_third_person(on: bool) -> void:
	if player == null:
		return
	player.third_person = on
	var fade := player.camera.get_node_or_null(^"Fade") as DotCameraFade if player.camera != null else null
	if fade != null:
		fade.focus = player.view if on else null

## The server changed `mp_forceview`: the view it now allows.
func _on_view_rules_changed() -> void:
	if player != null:
		_set_third_person(game.view_rules.resolve(player.third_person))

## The camera's two guards from dot-core, once a player is adopted.
func _guard_camera(p: ArenaPlayer) -> void:
	if p == null or p.camera == null:
		return
	p.third_person_mask = _level_mask()
	# Seen from behind, a player with no site avatar is the stock figure everybody else
	# already sees them as (the same document, from the same key), not a plain capsule.
	if p.avatar == null:
		p.rewear(ArenaAvatars.stock_avatar(StringName(ArenaGame.storage_key(p.player_id))))
	if p.camera.get_node_or_null(^"Fade") == null:
		var fade := DotCameraFade.new()
		fade.name = "Fade"
		fade.bodies_fn = _other_figures
		p.camera.add_child(fade)
	if not game.view_rules.changed.is_connected(_on_view_rules_changed):
		game.view_rules.changed.connect(_on_view_rules_changed)
	_set_third_person(game.view_rules.resolve(p.third_person))

## The hands under the camera, and the player's rig rebuilt to draw them.
func _arm(body: ArenaPlayer) -> void:
	if body == null or body.camera == null or view_model != null:
		return

	ArenaLoadTimeline.mark("arming")
	view_model = AwViewModel.new()
	view_model.name = "Hands"
	view_model.feel_rules = game.feel_rules
	body.ads_rules = game.ads_rules
	view_model.ads_rules = game.ads_rules
	body.camera.add_child(view_model)
	view_arms = ArenaViewArms.mount(self, view_model, body, ArenaAvatars.look_of(body.avatar, StringName("arena-player-%08d" % body.player_id)), game)
	body.arm_first_person(view_model, _offline)
	ArenaLoadTimeline.mark("hands armed")
	if _builds_in_frames():
		# Each in a frame of its own: the arming and both starts shared one frame with the joins.
		get_tree().process_frame.connect(_prewarm_weapons_next_frame, CONNECT_ONE_SHOT)
	else:
		_prewarm_weapons.call_deferred(body)
		_prewarm_models.call_deferred()

## Whether setup is spread over frames: in a client that draws, and not headless (see `_setup_frame`).
func _builds_in_frames() -> bool:
	return not DotPlatform.is_headless() and is_inside_tree()

func _prewarm_weapons_next_frame() -> void:
	_prewarm_weapons(player)
	get_tree().process_frame.connect(_prewarm_models, CONNECT_ONE_SHOT)

## One tick of weapon use, predicted. An outcome rather than a shot, because a use is
## not always one: a rocket produces a spawn and no shot at all, and a burst produces
## several shots that are all one trigger pull.
func _on_local_used(outcome: DotWeaponOutcome) -> void:
	if presentation == null or outcome == null or not outcome.used:
		return

	presentation.on_used(outcome, weapon_draws_shots())

func _on_local_wall_run(running: bool) -> void:
	if presentation != null:
		var _voice := presentation.on_wall_run(running)

## The jump-started run turns the look input along the wall.
func _on_local_view_turned(degrees: float) -> void:
	_view_turn_left += degrees

func _on_local_wall_jumped() -> void:
	if presentation != null:
		var _voice := presentation.on_wall_jumped()

func _on_local_damaged(damage: DotDamage) -> void:
	if player != null and player.controller != null:
		var held := player.weapons.current_def() if player.weapons != null else null
		var scale := game.ads_rules.hit_flinch_for(held.id) if held != null and game != null else 1.0
		_aim_break.note_hit(Time.get_ticks_msec() * 0.001, player.controller.tunables, damage.amount, scale)
	if presentation != null:
		presentation.on_hurt(damage.amount, player != null and player.health != null and not player.health.alive)

func _on_local_died(_damage: DotDamage) -> void:
	if presentation == null or player == null:
		return
	var where := Transform3D.IDENTITY
	where.origin = player.global_position
	presentation.on_died(where)

## Connects the local player's own noises and pictures.
##
## [b]Only the local player's.[/b] Somebody else being hurt is their business: a damage
## tint for every player in the match would be a screen that is permanently red, and a
## shake for somebody else's rifle would make a crowded room unplayable. What everybody
## hears is the positional half -- the shot, the impact -- which comes from the world.
func _hear_the_local_player() -> void:
	if presentation == null or player == null:
		return

	presentation.on_spawned()

	if player.health != null and not player.health.damaged.is_connected(_on_local_damaged):
		player.health.damaged.connect(_on_local_damaged)
		player.health.died.connect(_on_local_died)

	# The wall moves, predicted like the shot below and for the same reason: a sound never
	# changes the simulation. The controller does not emit either during a replay, so a
	# corrected tick is never heard twice.
	var controller := player.controller
	if controller != null and not controller.wall_run_changed.is_connected(_on_local_wall_run):
		controller.wall_run_changed.connect(_on_local_wall_run)
		controller.wall_jumped.connect(_on_local_wall_jumped)
		controller.view_turned.connect(_on_local_view_turned)

	if not player.used.is_connected(_on_local_used):
		# The PREDICTED use, on the client that made it. Waiting for the server's
		# confirmation would put the bang a round trip after the click, which is the one
		# piece of feedback a player judges the whole game's responsiveness by -- and it
		# is safe to predict for exactly the reason dot-fx is built the way it is: a sound
		# never changes the simulation, so a shot the server later refuses cost a noise.
		#
		# ArenaPlayer.used rather than arsenal.used, because ArenaPlayer already forwards
		# it and is the one node this client is handed. Going through the arsenal means
		# reaching two levels into somebody else's addon for a signal the player above it
		# re-emits unchanged.
		player.used.connect(_on_local_used)

func _on_beacon_pulsed(at: Vector3) -> void:
	if presentation != null:
		var _voice := presentation.on_beacon(at)

## Plays a beacon's ping wherever its ripple goes out, for [param body] — every player,
## this client's own included: somebody who has been beaconed should hear it too.
##
## From both [method _on_player_added] and [method _adopt], because a player found by
## `_watch` is adopted without passing through the first, and the connection is guarded so
## the two never make it twice.
func _hear_beacon(body: ArenaPlayer) -> void:
	if body == null or body.beacon_pulsed.is_connected(_on_beacon_pulsed):
		return

	body.beacon_pulsed.connect(_on_beacon_pulsed)

## The field of view to use: the player's own, under any cap a server has applied.
func _field_of_view() -> float:
	if presentation == null:
		return FIELD_OF_VIEW
	return float(presentation.settings.get_int(&"field_of_view", int(FIELD_OF_VIEW)))

func _build_interface() -> void:
	hud = ArenaHud.new()
	hud.name = "Hud"
	add_child(hud)
	hud.build(game)
	# The hit pulse at the screen's edge is dot-fx's hurt flash, drawn: so it obeys the
	# player's "no flashes" and the flash rate limit like every other flash.
	if presentation != null:
		hud.flash_source = presentation.fx

	# The server browser: the one page that is about something other than this game.
	browser = ArenaBrowser.new()
	browser.name = "Browser"
	add_child(browser)
	var listed := browser.setup()
	DotLog.result(CHANNEL, "the server browser", listed)
	browser.join_requested.connect(_on_join_requested)

	# [b]dot-menu's menu, and the client still owns the pointer.[/b] The menu is told not to manage
	# it: pointer lock needs a click in a browser, which only this client knows about.
	game_menu = ArenaMenus.build(self, presentation, browser if listed.ok else null)
	# The HUD in the menu's theme and at the player's HUD size, switched live (dot-menu 7). By
	# name, so a client shell older than that still runs the game in dot-ui's dark default.
	if game_menu.has_method(&"follow_hud"):
		game_menu.call(&"follow_hud", hud, ArenaHud.accent_theme())
	_touch = ArenaTouch.build(self, hud, _sampler, game.mobile_rules, game_menu.menu_button)
	if DotPlatform.has_touch() and _touch.get(&"buttons") != null and platform.has_method(&"fit_touch_buttons"):
		platform.call(&"fit_touch_buttons", _touch.buttons, ArenaTouch.LAYOUT)
	# M: the maps and the modes (dot-menu's map menu).
	if game_menu.has_method(&"use_maps"):
		var maps: Variant = game_menu.call(&"use_maps", map_menu_rows, change_from_menu)
		if maps is Object:
			(maps as Object).set(&"noun", "maps and modes")
			# The server's rows say "Mode" or "Map" on their mode line; a mode pick is kept and the next map pick carries it.
			if &"mode_group" in maps:
				(maps as Object).set(&"mode_group", "Mode")
	_use_loadout_menu()
	if game_menu.has_method(&"use_teams"):
		var offer := Callable()
		var choose := Callable()
		if _offline:
			_local_team_menu = ArenaTeamMenu.new()
			var pair := _local_team_menu.bind_local(game, func() -> int: return player.player_id if player != null else 0)
			offer = pair[0]
			choose = pair[1]
		var teams: Variant = game_menu.call(&"use_teams", offer, choose)
		if teams is Object:
			_link_menu(teams as Object)
	platform.add_store_panel(game_menu, func() -> String:
		var key := loadout_account_key(DotRegistry.get_node_service(AUTH_SERVICE))
		return "" if key == "local" else key)
	game_menu.action_requested.connect(func(id: StringName) -> void:
		if id != ArenaMenus.LEAVE:
			return
		# Closed first, so a client that cannot actually leave (an embedded one, a
		# single-process test) is not left showing a menu over a game that carried on.
		game_menu.close()
		leave_requested.emit())
	# The menu, its help or the console opening or closing: the pointer and the sampler.
	game_menu.overlays_changed.connect(func(_open: bool) -> void:
		_apply_mouse())

	_build_interface_part2()


func _build_interface_part2() -> void:
	board = ArenaMenus.Board.new(
		game_menu.scoreboard, game.match_node.scoreboard,
		link if not _offline else null, game.match_node.teams, game
	)

	if presentation != null:
		applier = DotMenuApplier.new()
		applier.name = "Applier"
		applier.settings = presentation.settings
		add_child(applier)
		applier.bind_audio(presentation.audio)
		applier.bind_fx(presentation.fx)
		DotLog.result(CHANNEL, "the settings applier", applier.setup())
		presentation.settings.changed.connect(func(key: StringName, value: Variant, _w: StringName) -> void:
			if key == &"hud_safe_area" and hud != null:
				hud.set_safe_area(float(value))
			elif presentation.bindings.row_for_setting(key).size() > 0:
				# Deferred: the table applies a rebound row after the setting changes. Any
				# row, not only Duck's: one given C takes C off the slide.
				_add_slide_key.call_deferred()
				_hud_keys.call_deferred())
		hud.set_safe_area(presentation.settings.get_float(&"hud_safe_area", 16.0))
	_build_interface_rest()
