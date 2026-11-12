extends "headless_presentation_b1.gd"

const ArenaWeaponRoles := preload("../game/arena_weapon_roles.gd")


## Records 9.5 s of the killer running down +x with the victim standing down its aim, and a kill at 8 s.
func _record_kill_run(kc: DotKillcamHost, killer: ArenaPlayer, victim: ArenaPlayer, clock: Array, at: Callable) -> void:
	var step := 1.0 / 60.0
	var start := killer.controller.state.position
	killer.controller.state.pitch = 0.0
	var aim := -Basis(Vector3.UP, deg_to_rad(killer.controller.state.yaw)).z
	victim.controller.state.position = start + Vector3(8.0, 0.0, 0.0) + aim * 10.0
	victim.global_position = victim.controller.state.position
	while clock[0] < 9.5:
		clock[0] += step
		killer.controller.state.position = at.call(clock[0])
		killer.global_position = at.call(clock[0])
		kc.frame()
		if absf(clock[0] - 8.0) < step * 0.5:
			kc.note_kill(41, 42, "rifle")


## A killcam host over [param players] and the game's rules, driven by hand from [param clock].
func _killcam_host(g: ArenaGame, players: Array, clock: Array) -> DotKillcamHost:
	var kc := DotKillcamHost.new()
	ArenaKillcamBodies.configure(kc)
	kc.players_fn = func() -> Array: return players
	kc.player_for_fn = g.player_for
	kc.now_fn = func() -> float: return clock[0]
	kc.seconds_fn = func() -> float: return g.rule("killcam")
	add_child(kc)
	kc.killcam.auto_process = false
	return kc


func _check_banner_icon(kc: DotKillcamHost) -> void:
	var icon_tex := ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))
	kc.weapon_icon_fn = func(id: String) -> Texture2D: return icon_tex if id == "rifle" else null
	kc.killcam.banner.present({"killer": "Killer", "weapon": "Rifle", "weapon_id": "rifle"})
	_check(kc.killcam.banner.icon_rect.visible and kc.killcam.banner.icon_rect.texture == icon_tex,
		"the banner shows the weapon's icon from weapon_icon_fn")


## Christian's first play test: B opens the loadout (primary, secondary, melee, grenades), a choice
## applies at once in warmup or spawn protection and otherwise on the next spawn.
func _test_the_loadout_menu() -> void:
	_section("B is the loadout menu, and the crosshair fades down the sights")
	var client := ArenaClient.new()
	client.force_offline = true
	add_child(client)
	for _i in 6:
		await get_tree().process_frame
	var menu: DotMenu = client.game_menu
	var keys: DotMenuBindings = menu.bindings if menu != null else null
	_check(keys != null and keys.key_for(DotMenuBindings.LOADOUT_ACTION) == "B" and keys.defaults_on("B").size() == 1,
		"the loadout menu is on B, and nothing else in the table is",
		str(keys.defaults_on("B").map(func(r: Dictionary) -> String: return str(r["label"]))) if keys != null else "no menu")
	await _check_loadout_accounts(client)
	var game: ArenaGame = client.game
	var me := client.player
	if not _check(game.loadout_command != null and me != null, "the game has the menu's server half, and a player"):
		remove_child(client)
		client.free()
		_done()
		return
	var offer: Dictionary = await client.loadout_offer()
	var slot_ids: Array = (offer.get("slots", []) as Array).map(func(sl: Dictionary) -> String: return str(sl["id"]))
	_check(slot_ids == ["primary", "secondary", "melee", "thrown", "gear"], "primary, secondary, melee, grenades and gear, in that order", str(slot_ids))
	var decorated: Dictionary = client.decorate_loadout_choice("primary", {"id": "rifle"})
	_check(decorated.get("icon") is Texture2D and (decorated.get("stats", []) as Array).size() >= 4 and str(decorated.get("detail", "")) != "",
		"a card has the weapon's picture, a line and its numbers")

	var b := InputEventKey.new()
	b.physical_keycode = KEY_B
	b.keycode = KEY_B
	b.pressed = true
	menu.close_all()
	_check(menu.handle_event(b), "B is the menu's")
	for _i in 2:
		await get_tree().process_frame
	_check(menu.loadout_screen != null and menu.loadout_screen.is_open() and menu.loadout_screen.slots().size() == 5,
		"and opens the loadout screen on the five slots")
	menu.loadout_screen.cancel()

	game.match_node.state = DotMatch.State.WARMUP
	var now: Dictionary = await client.choose_loadout({"primary": "marksman", "thrown": "sticky"})
	_check(bool(now.get("ok", false)) and bool(now.get("now", false)) and me.arsenal.carries(&"marksman") and me.arsenal.carries(&"sticky"),
		"in warmup a choice is in the player's hands at once", str(now))

	game.match_node.state = DotMatch.State.LIVE
	me.health.spawn_protection_ticks = 0
	me.health.invulnerable_until_tick = -1
	var later: Dictionary = await client.choose_loadout({"primary": "carbine"})
	_check(bool(later.get("ok", false)) and not bool(later.get("now", true)) and not me.arsenal.carries(&"carbine"),
		"mid-round it waits for the next spawn", str(later))
	var _back := game.respawn_player(me.player_id)
	for _i in 3:
		await get_tree().process_frame
	_check(me.arsenal.carries(&"carbine") and me.arsenal.carries(&"sticky"), "and the next spawn carries it")

	await _check_loadout_rules(client, me, game)

	await _check_crosshair_sights(client, me, game)
	remove_child(client)
	client.free()
	await get_tree().process_frame
	_done()


func _check_loadout_rules(client: ArenaClient, me, game: ArenaGame) -> void:
	var snipers: DotResult = game.loadout_command.call(&"apply_strings", true, "primary=tag:scoped", "")
	var limited: Dictionary = await client.loadout_offer()
	var primaries: Array = ((limited["slots"] as Array)[0]["choices"] as Array).map(func(c: Dictionary) -> String: return str(c["id"]))
	_check(snipers.ok and not primaries.is_empty() and not primaries.has("rifle") and primaries.has("marksman"),
		"an owner's 'snipers only' is what the menu offers", str(primaries))
	var refused: Dictionary = await client.choose_loadout({"primary": "rifle"})
	_check(not bool(refused.get("ok", true)), "and a rifle is refused by the game, not only hidden", str(refused))
	var active: DotResult = await game.loadouts.active_for(ArenaGame.storage_key(me.player_id))
	_check(primaries.has(str((active.value as DotLoadout).item_in(&"primary"))),
		"a saved carbine spawns as a scoped gun while the rule is on", str((active.value as DotLoadout).item_in(&"primary")))
	var locked: DotResult = game.loadout_command.call(&"apply_strings", false, "", "primary=sniper")
	var fixed_offer: Dictionary = await client.loadout_offer()
	_check(locked.ok and fixed_offer["choose"] == false and str((fixed_offer["slots"] as Array)[0]["current"]) == "sniper",
		"an owner can lock the loadout: nothing to choose, and the fixed slot is what everybody gets")
	var _open: Variant = game.loadout_command.call(&"apply_strings", true, "", "")

	var was_mode := game.mode
	game.mode = ArenaMode.only_snipers()
	var closed: Dictionary = await client.loadout_offer()
	_check(closed["choose"] == false and str(closed["note"]).contains("hands out the weapons"),
		"a mode that hands out the weapons says so, and lets nothing be picked", str(closed.get("note", "")))
	game.mode = was_mode


## Christian's first play test: a darker HUD by default, which follows the menu's theme so a player
## can change it.
func _test_the_hud_follows_the_theme() -> void:
	_section("The HUD is dark by default and follows the menu's theme live")
	var client := ArenaClient.new()
	client.force_offline = true
	add_child(client)
	for _i in 6:
		await get_tree().process_frame
	var menu: DotMenu = client.game_menu
	var hud: ArenaHud = client.hud
	var piece: DotHudPiece = null
	# The kill feed: one of the pieces arena keeps, drawn with its own `Ink`.
	var own: Control = hud.feed
	for n in hud.find_children("*", "Control", true, false):
		if n is DotHudPiece:
			piece = n
			break
	_check(menu != null and piece != null and own != null and menu.followed_huds().has(hud), "the client hands the menu its HUD",
		"menu %s, piece %s, own %s" % [menu, piece, own])
	if menu == null or piece == null or own == null:
		remove_child(client)
		client.free()
		_done()
		return
	var Ink = ArenaHud.ArenaHudGlance.Ink
	var _m := menu.settings.set_value(&"ui_theme", &"midnight")
	var plate := piece.colour(&"plate")
	_check(plate.get_luminance() < 0.1 and plate.a >= 0.7 and piece.colour(&"keycap").get_luminance() < 0.3,
		"the default HUD is dark: deep plates and dark key caps", str(plate))
	_check(Ink.c(own, &"plate") == plate and Ink.bright(own) < 0.5, "and this game's own pieces draw in the same theme")
	_check(piece.colour(&"highlight") == ArenaHud.GOLD, "with arena's gold as its accent")
	var _a := menu.settings.set_value(&"ui_theme", &"arcade")
	_check(piece.number(&"team_fill") == 100 and piece.colour(&"keycap").get_luminance() > 0.8 and Ink.bright(own) > 0.99,
		"the bright first HUD is a theme a player can pick, and both kinds of piece follow it")
	var _p := menu.settings.set_value(&"ui_theme", &"contrast")
	var contrast := menu.themes.named(&"contrast")
	_check(piece.colour(&"plate") == contrast.hud_plate and Ink.c(own, &"plate_edge") == contrast.hud_edge
		and piece.colour(&"highlight") == ArenaHud.GOLD, "another theme reaches every piece at once, the accent kept")
	var _s := menu.settings.set_value(&"hud_scale", 1.2)
	_check(is_equal_approx(hud.user_scale, 1.2), "and the HUD size setting resizes the HUD")
	_s = menu.settings.set_value(&"hud_scale", 1.0)
	_m = menu.settings.set_value(&"ui_theme", &"midnight")
	_check(piece.colour(&"plate") == plate, "and back")
	remove_child(client)
	client.free()
	await get_tree().process_frame
	_done()


## The pack carries its art (a delivered game has only what is vendored in assets/), so every model
## the weapons table names must exist here. v0.1.13 shipped without low-poly-guns/ and ammo/: eleven
## weapons were invisible in production and nothing failed.
func _test_the_weapon_art_is_vendored() -> void:
	_section("Every model the weapon art table names is vendored in this game")
	# The table holds only registered packs; the suite's order must not decide whether it is empty.
	ArenaWeaponRoles.ensure()
	var count := AwWeaponArtTable.model_paths().size()
	_check(count > 20, "the table names models (%d)" % count)
	var models := AwWeaponArtTable.validate_models()
	_check(models.ok, "no weapon model is missing", "" if models.ok else models.error.message)
	_done()


func _test_the_final_killcam() -> void:
	_section("The final killcam replays the last kill from behind the killer (or its eye), and 0 turns it off")
	var g := ArenaGame.new()
	g.is_authority = true
	add_child(g)
	var _set := g.setup(ArenaMap.dm_box())
	var killer: ArenaPlayer = g.add_player(41, "Killer").value
	var victim: ArenaPlayer = g.add_player(42, "Victim").value
	_check(is_equal_approx(g.match_node.rules.match_end_sec, g.mode.rules.match_end_sec + 7.0),
		"the end of the match waits the killcam's 7 s on top of the mode's")
	var clock := [0.0]
	var kc := _killcam_host(g, [killer, victim], clock)
	kc.camera_mode_fn = func() -> int: return DotKillViewRules.Camera.BEHIND
	var ended: Array = []
	kc.over.connect(func(skipped: bool) -> void: ended.append(skipped))
	var start := killer.controller.state.position
	var step := 1.0 / 60.0
	var at := func(t: float) -> Vector3: return start + Vector3(t, 0.0, 0.0)
	_record_kill_run(kc, killer, victim, clock, at)
	_check(kc.buffer.frame_count() > 400 and int(kc.buffer.last_event(&"kill")["data"]["killer"]) == 41,
		"every frame drawn and the kill went into the buffer")
	var drawn: Array = []
	kc.killcam.frame_drawn.connect(func(s: Dictionary) -> void:
		var kb: Node3D = killer.body_mesh
		drawn.append([float(s["time"]), kc.camera.global_transform, kb.global_position if kb != null else Vector3.INF, kb != null and kb.visible]))
	_check(kc.match_ended() and kc.is_playing(), "the match's end starts it")
	kc.killcam.advance(step)
	_check(not drawn.is_empty() and absf(float(drawn[0][0]) - 4.5) < 0.05, "from 3.5 s before the kill (%.2f)" % (float(drawn[0][0]) if not drawn.is_empty() else NAN))
	var first: Array = drawn[0] if not drawn.is_empty() else [0.0, Transform3D(), Vector3.INF, false]
	var want: Vector3 = at.call(4.5)
	var cam: Transform3D = first[1]
	var gap := cam.origin.distance_to(want + Vector3(0.0, 1.6, 0.0))
	_check(gap > 1.5 and gap < 8.0 and cam.origin.y > want.y + 1.0, "with the camera a few metres behind and above the killer (%.2f m)" % gap)
	_check(first[3] and (first[2] as Vector3).distance_to(want) < 0.1, "and the killer's body drawn where it was recorded", "%s vs %s" % [first[2], want])
	var chest := victim.global_position + Vector3(0.0, 1.2, 0.0)
	var look := (-cam.basis.z).dot((chest - cam.origin).normalized())
	_check(look > 0.95, "looking at the victim (%.3f)" % look)
	for _i in 60:
		kc.killcam.advance(step)
	var later: Array = drawn[-1]
	_check(float(later[0]) > float(first[0]) + 0.2 and (later[2] as Vector3).x > (first[2] as Vector3).x + 0.2,
		"time advances and the killer's body moves with the recording", "t %.2f -> %.2f, x %.2f -> %.2f" % [first[0], later[0], (first[2] as Vector3).x, (later[2] as Vector3).x])
	_check(kc.killcam.banner != null and kc.killcam.banner.killer_label.text == "Killer", "under a banner naming the killer")
	_check_banner_icon(kc)
	var n := 0
	while kc.is_playing() and n < 1000:
		kc.killcam.advance(step)
		n += 1
	_check(ended == [false] and n * step < 7.0, "it ends by itself inside the budget (%.2f s)" % (n * step))
	_check(killer.body_mesh == null or not killer.body_mesh.visible, "a body attached only for the replay goes back hidden")

	kc.camera_mode_fn = func() -> int: return DotKillViewRules.Camera.EYE
	drawn.clear()
	ended.clear()
	var _again := kc.match_ended()
	kc.killcam.advance(step)
	var eye: Vector3 = (drawn[0][1] as Transform3D).origin if not drawn.is_empty() else Vector3.INF
	_check(absf(eye.x - want.x) < 0.1 and eye.y > want.y + 0.5 and not (drawn[0][3] if not drawn.is_empty() else true),
		"mp_killview_camera 0: the camera at the killer's eye, its body not drawn (%s, feet %s)" % [eye, want])
	kc.skip()
	_check(ended == [true], "and a skip ends it")

	g.set_movement_rules({"killcam": 0.0})
	ended.clear()
	_check(not kc.match_ended() and ended == [false] and not kc.is_playing(),
		"mp_killcam_time 0: nothing plays and the end goes straight on")
	_check(is_equal_approx(g.match_node.rules.match_end_sec, g.mode.rules.match_end_sec),
		"and the end of the match is the mode's again")
	kc.queue_free()
	g.queue_free()
	_done()


## Every piece of the HUD put up at once, as `screenshot.sh --glance` stages it, on five frames, and
## no piece's drawn rect may meet another's.
func _test_hud_fits_the_frame() -> void:
	_section("No piece of the HUD lies over another, from a phone to a desktop frame")

	var hud := ArenaHud.new()
	hud.config = DotUiConfig.new()
	add_child(hud)
	hud.build(null)
	# Nothing reads a player here: the pieces draw what they are handed, and `_process`
	# would hand them a dead player's nothing.
	hud.set_process(false)
	hud._build_feedback()

	_fill_hud(hud)

	# The chat box, scaled with the HUD as ArenaPresentation scales it: unscaled, a full log
	# at 854x480 reached the killstreak meter and the key hints.
	var chat_screen := Control.new()
	add_child(chat_screen)
	var chat := ArenaPresentation.make_chat_window()
	chat_screen.add_child(chat)
	var chat_met := PackedStringArray()

	var frames := [Vector2(854, 480), Vector2(960, 720), Vector2(720, 1280), Vector2(1280, 720), Vector2(1600, 900)]
	for frame: Vector2 in frames:
		hud.fit_to_frame(frame)
		hud.notice("Vote: Smash Copter, Hide & Seek, Dangerous Delivery, Playground, g2gfast (20s)")
		# The labels take their text's size on the next frame.
		await get_tree().process_frame
		var rects := hud.footprints()
		var keys: Array = rects.keys()
		var met := PackedStringArray()
		var outside := PackedStringArray()
		var bounds := Rect2(Vector2.ZERO, frame)
		for i in range(keys.size()):
			var a: Rect2 = rects[keys[i]]
			if not bounds.encloses(a):
				outside.append("%s %s" % [keys[i], a])
			for j in range(i + 1, keys.size()):
				if a.intersects(rects[keys[j]]):
					met.append("%s/%s" % [keys[i], keys[j]])
		var size_name := "%dx%d" % [int(frame.x), int(frame.y)]
		_check(met.is_empty() and keys.size() == 11,
			"at %s, none of the %d pieces meets another" % [size_name, keys.size()], ", ".join(met))
		_check(outside.is_empty(), "and every one is inside the frame", ", ".join(outside))

		ArenaPresentation.fit_chat_screen(chat_screen, frame)
		var fit := chat_screen.scale.x
		var rows := float(chat.max_lines) * (chat.line_height + chat.line_gap)
		var log_top := frame.y / fit - chat.margin_bottom - chat.entry_height - rows
		var log_box := chat_screen.get_global_transform() * Rect2(chat.margin_left, log_top, chat.width, rows)
		for key: String in rects:
			if log_box.intersects(rects[key]):
				chat_met.append("%s: %s %s vs log %s" % [size_name, key, rects[key], log_box])

	_check(chat_met.is_empty(), "a full chat log meets no HUD piece at any of those frames",
		", ".join(chat_met))
	chat_screen.queue_free()

	# 1280x720 and up are laid out exactly as dot-ui's full-rect inset laid them out.
	var same := true
	for frame: Vector2 in [Vector2(1280, 720), Vector2(1600, 900), Vector2(1920, 1080)]:
		hud.fit_to_frame(frame)
		same = same and hud.scale == Vector2.ONE and hud.position == Vector2(16, 16) and hud.size == frame - Vector2(32, 32)
	_check(same, "from 1280x720 up the HUD is not scaled, and sits where it always did")
	_check(is_equal_approx(ArenaHud.fit_scale(Vector2(854, 480)), 480.0 / 720.0)
			and is_equal_approx(ArenaHud.fit_scale(Vector2(960, 720)), 0.75)
			and is_equal_approx(ArenaHud.fit_scale(Vector2(720, 1280)), 0.5625)
			and ArenaHud.fit_scale(Vector2(200, 100)) == hud.fit_min
			and hud.fit_design == ArenaHud.DESIGN_FRAME and hud.fit_min == 0.5,
		"below it, it is scaled by the short side's share of 1280x720, never under half")

	await _check_crowded_frames(hud)

	hud.queue_free()
	_done()

func _check_crowded_frames(hud: ArenaHud) -> void:
	# Four sides' plates and a capture-ranked row with two stats a card still fit, the row
	# dropping players where the frame is too narrow.
	var sides: Array[Dictionary] = []
	for s in [["RED · TAKEN", Color.RED], ["BLUE", Color.BLUE], ["GREEN · 12s", Color.GREEN], ["GOLD", Color.GOLD]]:
		sides.append({"tag": s[0], "score": sides.size() * 3, "colour": s[1]})
	hud.strip.show_teams(sides)
	hud.strip.show_clock("9:37", false, "First to 3 captures", "Capture the flag")
	var cards: Array[Dictionary] = []
	for i in range(10):
		cards.append({"name": "P%d" % i, "rank": i + 1, "kills": 20 - i, "objectives": 3 - int(i / 3.0), "me": i == 9})
	hud.portraits.show_players(cards, true)
	var crowded := PackedStringArray()
	for frame: Vector2 in [Vector2(854, 480), Vector2(960, 720), Vector2(1280, 720)]:
		hud.fit_to_frame(frame)
		hud.notice("Vote: Smash Copter, Hide & Seek, Dangerous Delivery, Playground, g2gfast (20s)")
		await get_tree().process_frame
		var rects := hud.footprints()
		var keys: Array = rects.keys()
		for i in range(keys.size()):
			if not Rect2(Vector2.ZERO, frame).encloses(rects[keys[i]]):
				crowded.append("%s outside at %s" % [keys[i], frame])
			for j in range(i + 1, keys.size()):
				if (rects[keys[i]] as Rect2).intersects(rects[keys[j]]):
					crowded.append("%s/%s at %s" % [keys[i], keys[j], frame])
	_check(crowded.is_empty() and hud.strip.teams.size() == 4 and hud.portraits.objective,
		"four sides' plates and the capture row fit every frame, meeting nothing", ", ".join(crowded))
	var kept: Array = hud.portraits.shown()
	_check(not kept.is_empty() and bool((kept.back() as Dictionary).get("me", false)),
		"a card row cut short still ends with your own card", "%d shown" % kept.size())
	hud.strip.show_scores(1, 2, "RED", "BLUE", Color.RED, Color.BLUE)
	_check(hud.strip.teams.is_empty() and hud.strip.left_score == 1 and hud.strip.right_score == 2,
		"two sides go back to the plain two plates")
	# The clock is dot-ui's `DotScoreStrip.clock_text`, which rounds up: a clock never says
	# 0:00 with time left. Arena's own rounded down (9:37.4 read 9:37).
	_check(DotScoreStrip.clock_text(577.4) == "9:38" and DotScoreStrip.clock_text(0.3) == "0:01"
			and DotScoreStrip.clock_text(0.0) == "0:00" and DotScoreStrip.clock_text(600.0) == "10:00",
		"the clock rounds the seconds left up (%s, %s)" % [DotScoreStrip.clock_text(577.4), DotScoreStrip.clock_text(0.3)])


## Every piece of the HUD at its busiest.
func _fill_hud(hud: ArenaHud) -> void:
	hud.strip.visible = true
	hud.strip.show_scores(4, 4, "YOU", "2ND  GAMEMANN", Color.BLUE, Color.RED)
	hud.strip.show_clock("9:37", false, "First to 25", "Free-For-All")
	hud.portraits.visible = true
	var faces: Array[Dictionary] = []
	for i in range(8):
		faces.append({"name": "P%d" % i, "rank": i + 1, "kills": 8 - i, "me": i == 0})
	hud.portraits.show_players(faces)
	hud.feed.add_kill("gamemann", Color.WHITE, &"launcher", "launcher", "Rocket", Color.WHITE)
	hud.feed.add_kill("You", Color.WHITE, &"marksman", "marksman", "quiet_one", Color.WHITE, false, true)
	hud.feed.add_kill("a_very_long_display_name", Color.WHITE, &"sniper", "sniper", "Viper", Color.WHITE, true)
	hud.vitals.show_vitals(64.0, 100.0, 35.0)
	hud.ammo.show_ammo("Marksman rifle", 3, 240, false)
	var carried: Array[Dictionary] = []
	for slot in range(1, 6):
		carried.append({"slot": slot, "id": &"rifle", "name": "Rifle", "key": str(slot)})
	hud.slots.show_slots(carried, 3)
	var buttons: Array[Dictionary] = []
	for b in [["slide", "C"], ["launch", "E"], ["dash", "Shift"], ["walljump", "Space"]]:
		buttons.append({"id": StringName(b[0]), "label": b[0], "icon": null, "key": b[1],
			"left": 0.0, "total": 1.0, "active": false, "pips": 2, "pips_max": 3 if b[0] == "walljump" else 0})
	hud.abilities.show_buttons(buttons)
	hud.hints.show_hints([["Scoreboard", "Tab"], ["Menu", "Esc"], ["Chat", "Y"], ["Slide", "C"]])
	hud.slide_label.show_prompt("Cancel slide", "C")
	hud.vitals.show_streak(3, ArenaHud.STREAK_FULL)
	hud.medal_row.add(ArenaAwards.Medal.HEADSHOT, "Headshot")
	hud.medal_row.add(ArenaAwards.Medal.DOUBLE_KILL, "Double Kill")
	hud.medal_row.advance(1.0)

