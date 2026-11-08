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

	await _check_crosshair_sights(client, me, game)
	remove_child(client)
	client.free()
	await get_tree().process_frame
	_done()


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
	# The clock is dot-ui's `DotScoreStrip.clock_text`, which rounds up: a clock never says
	# 0:00 with time left. Arena's own rounded down until 2026-10-11 (9:37.4 read 9:37).
	_check(DotScoreStrip.clock_text(577.4) == "9:38" and DotScoreStrip.clock_text(0.3) == "0:01"
			and DotScoreStrip.clock_text(0.0) == "0:00" and DotScoreStrip.clock_text(600.0) == "10:00",
		"the clock rounds the seconds left up (%s, %s)" % [DotScoreStrip.clock_text(577.4), DotScoreStrip.clock_text(0.3)])

	hud.queue_free()
	_done()


## The weapon slots under a ballot: this game's own map vote is seven rows (six maps and Extend),
## and the client shell draws it down the right-hand side to y 437 at 1280x720, over slots 1 and 2
## of five.
func _test_hud_makes_room_for_a_ballot() -> void:
	_section("The weapon slots and the centre line make room for a ballot")

	var hud := ArenaHud.new()
	hud.config = DotUiConfig.new()
	add_child(hud)
	hud.build(null)
	hud.set_process(false)
	hud.fit_to_frame(Vector2(1280, 720))
	var carried: Array[Dictionary] = []
	for slot in range(1, 6):
		carried.append({"slot": slot, "id": &"", "name": "Gun %d" % slot, "key": str(slot)})
	hud.slots.show_slots(carried, 3)
	hud.make_room()
	var free_top: float = hud.footprints()["slots"].position.y

	# Where the shell puts a seven-row ballot at 1280 wide, on a layer of its own.
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)
	var ballot := Control.new()
	ballot.add_to_group(&"dot_hud_cover")
	ballot.position = Vector2(904.0, 110.0)
	ballot.size = Vector2(360.0, 327.0)
	layer.add_child(ballot)
	var cover := Rect2(ballot.position, ballot.size)

	hud.make_room()
	var under: Rect2 = hud.footprints()["slots"]
	var laid: Dictionary = hud.slots.layout()
	_check(free_top < cover.end.y and under.position.y >= cover.end.y and not under.intersects(cover)
			and (laid["rows"] as Array).size() == 5,
		"all five slots end below a seven-row ballot, where they reached under it",
		"top %.0f free, %.0f under a ballot to %.0f, %d rows" % [free_top, under.position.y, cover.end.y, (laid["rows"] as Array).size()])
	_check(float(laid["pitch"]) < ArenaHud.ArenaHudGlance.WeaponSlots.ROW_H
			and float(laid["pitch"]) >= ArenaHud.ArenaHudGlance.WeaponSlots.MIN_ROW_H,
		"by drawing the rows closer, never under the tightest pitch", "pitch %.1f" % float(laid["pitch"]))

	var many: Array[Dictionary] = []
	for slot in range(1, 9):
		many.append({"slot": slot, "id": &"", "name": "Gun %d" % slot, "key": str(slot)})
	hud.slots.show_slots(many, 7)
	hud.make_room()
	laid = hud.slots.layout()
	var shown := (laid["rows"] as Array).map(func(r: Dictionary) -> int: return int(r["slot"]))
	under = hud.footprints()["slots"]
	_check(shown.size() < 8 and shown.size() >= 3 and shown.has(7) and under.position.y >= cover.end.y,
		"eight that cannot fit even close together show the run around the current one",
		"%s, top %.0f" % [shown, under.position.y])

	ballot.visible = false
	hud.make_room()
	laid = hud.slots.layout()
	_check((laid["rows"] as Array).size() == 8 and float(laid["pitch"]) == ArenaHud.ArenaHudGlance.WeaponSlots.ROW_H,
		"and every row comes back at its own pitch the frame the ballot goes")
	ballot.visible = true

	var opening := "Vote: Box, Atrium, Pit, Foundry, Canals, Spire (20s)"
	var yes_no := "Vote: Kick quiet_one?  —  type !yes or !no (20s)"
	_check(ArenaHud.is_ballot_line(opening) and not ArenaHud.is_ballot_line(yes_no)
			and not ArenaHud.is_ballot_line("Changing map to Box…") and not ArenaHud.is_ballot_line("Vote: Box (soon)"),
		"a vote's opening list is told from the yes/no vote's line and every other system line")
	hud.notice(opening)
	_check(hud.notice_label == null or hud.notice_label.text != opening,
		"with a ballot on screen its opening list is not centre-printed as well")
	hud.notice(yes_no)
	_check(hud.notice_label != null and hud.notice_label.text == yes_no,
		"but the yes/no vote's line, which says how to answer, still is")

	# A line that arrived the frame before its ballot did goes when the ballot does arrive.
	ballot.visible = false
	hud.notice(opening)
	ballot.visible = true
	hud.make_room()
	_check(hud.notice_label.text == "", "and a list printed before its ballot appeared is taken down",
		hud.notice_label.text)

	layer.queue_free()
	hud.queue_free()
	_done()


func _test_vote_is_heard() -> void:
	_section("The map vote is heard: every cue its rules name is a sound here")

	var p := _make()
	var sink := p.audio.sink as DotAudioSinkNull

	# The rules this game votes by, as the server builds them. dot-vote ships every cue
	# empty, so a cue id the rules name and the catalogue lacks is a sound that is
	# configured, sent to every client each second of a countdown, and never heard.
	var vote := ArenaVote.new()
	var rules := vote._rules()
	vote.free()

	var named: Array[StringName] = []
	for cue in [
		rules.cue_vote_start, rules.cue_vote_end, rules.cue_warning,
		rules.cue_runoff_warning, rules.countdown_cue_id(3),
	]:
		named.append(StringName(cue))

	_check(
		not named.has(&""),
		"the rules name a cue for the start, the end, both warnings and a countdown second",
		str(named)
	)

	var missing: Array[String] = []
	for id in named:
		if not p.audio.catalogue.has(id):
			missing.append(String(id))
	_check(missing.is_empty(), "and every one is in the catalogue (missing: %s)" % str(missing))

	_check(
		rules.vote_warning_sec > 0.0,
		"with a countdown before the ballot, so the countdown cue has seconds to play in"
	)

	sink.forget()
	_check(p.on_vote_cue(StringName(rules.cue_vote_start)) != 0, "a ballot opening plays")
	_check(sink.count_of(StringName(rules.cue_vote_start)) == 1, "once")

	sink.forget()
	p.on_vote_cue(&"")
	p.on_vote_cue(&"a_sound_set_this_client_was_not_built_with")
	_check(
		sink.count_of(&"") == 0 and sink.count_of(&"a_sound_set_this_client_was_not_built_with") == 0,
		"and an empty cue or one this client does not know is silence, not an error"
	)

	p.queue_free()
	_done()


## A lethal critical breaks a body, a respawn mends it, and the HUD shows what a body is
## doing: badly hurt, ready to launch, sliding.
func _test_criticals_and_the_body() -> void:
	_section("A critical breaks a body, a respawn mends it, the HUD shows the rest")

	var player := ArenaPlayer.new()
	player.setup(ArenaPlayer.Mode.HEADLESS, ArenaMap.dm_box(), 6, "Broken")
	add_child(player)
	player.spawn(Transform3D(Basis(), Vector3(0.0, 0.05, 18.0)), 0)
	player.attach_body_mesh(Color.WHITE, ArenaAvatars.stock_avatar(&"broken"))

	var rules := DotPlayerBreakRules.new()
	rules.mode = DotPlayerBreakRules.Mode.LIMBS
	rules.limbs = 1
	rules.criticals_only = true
	# The body is a skinned person (dot-player-char's people): a limb is baked off the skin and
	# its bones shrink to the stump, so what is counted is the shrunk bones.
	var whole := _shrunk_bones(player)

	player.make_dead()
	_check(player.break_body(rules, Vector3.FORWARD, 42, false) == null,
		"an ordinary death leaves the body whole")
	var broke := player.break_body(rules, Vector3.FORWARD, 42, true)
	var left := _shrunk_bones(player)
	_check(broke != null and broke.piece_count() == 1 and left > whole,
		"a lethal critical takes a limb off (%d bones shrunk to the stump)" % left)

	player.health.alive = true
	player.present(0.016)
	_check(_shrunk_bones(player) == whole,
		"and a respawn puts the body back together")

	_check_health_tag(player)
	_check_tag_rules(player)

	var hud := ArenaHud.new()
	hud.config = DotUiConfig.new()
	add_child(hud)
	hud.build(null)
	hud.follow(player)

	player.health.health = player.health.max_health * 0.1
	hud.present_body()
	_check(hud.hurt_overlay.modulate.a > 0.5, "badly hurt, the screen's edge goes red (%.2f)" % hud.hurt_overlay.modulate.a)
	player.health.health = player.health.max_health
	hud.present_body()
	_check(hud.hurt_overlay.modulate.a == 0.0, "and healthy, it does not")
	# Per pixel, never a stretched texture: the play test's edge was a 64-pixel gradient
	# blown up to the screen, in visible steps.
	_check(hud.hurt_overlay.material is ShaderMaterial,
		"the red edge is drawn by a shader, not a stretched texture")

	# The play test's "+1 POINTS".
	_check(ArenaHud.points_text(1) == "1 point" and ArenaHud.points_text(5) == "5 points",
		"one point is a point (%s, %s)" % [ArenaHud.points_text(1), ArenaHud.points_text(5)])

	player.controller.tunables.launch_enabled = true  # off by default; the button only shows when on
	hud.present_body()
	_check(hud.abilities.visible and hud.abilities.line(&"launch").contains("LAUNCH"),
		"the launch's button reads ready (%s)" % hud.abilities.line(&"launch"))
	player.controller.state.launch_cooldown_left = 5.5
	hud.present_body()
	_check(hud.abilities.line(&"launch").contains("5.5"), "and counts its cooldown down (%s)" % hud.abilities.line(&"launch"))

	player.controller.state.slide_time = 0.2
	hud.present_body()
	_check(hud.slide_label.visible, "sliding, it says how to stop")
	player.controller.state.slide_time = -1.0

	# The streak meter counts from KILL events, as a client hears them. The points, the
	# hit marker and the medals do not: those come from the server's HIT and AWARD.
	for v in [7, 8, 9]:
		hud.note_kill({"killer_id": 6, "victim_id": v, "headshot": v == 9, "weapon": "rifle"}, 6, "Broken")
	hud.present_body()
	_check(hud.vitals.streak == 3, "three kills fill the streak row to three")
	_check(hud._popups.is_empty() and hud.hit_marker.alpha() == 0.0 and hud.medal_row.shown.is_empty(),
		"and a KILL alone draws no points, no hit marker and no medal: the client decides none of them")

	# The achievement the player is nearest to (still sent to the client).
	var awards: DotAchievementCatalogue = load("res://game/arena_awards.gd").catalogue()
	var progress := DotAchievementProgress.new()
	progress.set_value(&"arena.kills", 11.0)
	var picked: Array = load("res://game/arena_progress.gd").challenge_for(awards, progress)
	var picked_def: DotAchievement = awards.achievements[int(picked[0])] if int(picked[0]) >= 0 else null
	_check(picked_def != null and int(picked[1]) == 11 and picked_def.requirements[0].stat == &"arena.kills",
		"a challenge is the goal a player is furthest along (%s)" % (picked_def.display_name if picked_def != null else "none"))
	for i in range(3):
		hud.note_kill({"killer_id": 7, "victim_id": 6, "weapon": "sniper"}, 6, "Sniper")
	_check(hud.streaks.get(6, -1) == 0 and not hud._death_text.contains("NEMESIS"),
		"dying ends the streak, and three deaths alone name nobody: that is the server's call")
	hud.note_award({"killer_id": 7, "victim_id": 6, "medals": [ArenaAwards.Medal.NEMESIS], "points": 125, "streak": 3}, 6, "Broken", "Sniper")
	_check(hud._death_text.contains("Sniper is your NEMESIS"), "the server's Nemesis medal for a kill of you names them")
	player.make_dead()
	hud.present_body()
	_check(hud.death_label.visible and hud.death_label.text.contains("Killed by Sniper"),
		"dead, it says who did it and with what")
	hud.crosshair.call(&"_process", 0.016)
	_check(hud.crosshair != null and not hud.crosshair.is_shown(), "and the crosshair is gone: nothing in hand to aim")

	hud.note_kill({"killer_id": 6, "victim_id": 7, "weapon": "rifle"}, 6, "Broken")
	hud.note_award({"killer_id": 6, "victim_id": 7, "medals": [ArenaAwards.Medal.REVENGE], "points": 150, "streak": 1}, 6, "Sniper", "Broken")
	hud.medal_row.advance(0.05)
	_check(hud.medal_row.labels().has("Revenge") and not hud.nemeses.has(7),
		"killing them back is the server's Revenge medal, and they are nobody's nemesis now")
	hud.notice("hello")
	_check(hud.notice_label.text == "hello", "and notice() exists, which the client had called for a month")

	# The client shell's column (ballots, its lines) is the right edge from 110 px down. A
	# headless frame is 64 px, so where things land is the render's to judge
	# (`screenshot.sh --glance --ballot`); these are the structure that put them there.
	_check(ArenaHud.feed_lines_clear(16.0) == 3 and hud.feed.max_lines == 3,
		"the kill feed keeps to the rows that end above the shell's column (%d)" % hud.feed.max_lines)
	hud.set_safe_area(40.0)
	var inset_rows := hud.feed.max_lines
	hud.set_safe_area(16.0)
	_check(inset_rows == 2 and hud.feed.max_lines == 3,
		"and to fewer when the safe area pushes it down (%d at 40 px)" % inset_rows)
	_check(is_zero_approx(hud.hints.anchor_right) and is_equal_approx(hud.slots.anchor_top, 1.0)
			and hud.slots.offset_bottom <= hud.ammo.offset_top,
		"the key hints are on the left, the carried weapons on the ammunition counter")

	# The end of the match names the MVP, through the client's own MATCH handler.
	var summary_game := ArenaGame.new()
	summary_game.headless = true
	summary_game.register_service = false
	add_child(summary_game)
	var _set := summary_game.setup(ArenaMap.dm_box())
	var best := summary_game.match_node.scoreboard.join("6", "Broken")
	best.kills = 3
	best.score = 3
	var client := ArenaClient.new()
	client.game = summary_game
	client.hud = hud
	client._on_match({"state": DotMatch.State.MATCH_END, "round": 1, "remaining_ticks": 0})
	_check(hud.notice_label.text.begins_with("MVP: Broken") and hud.notice_label.text.contains("3 kills"),
		"the end of the match names the MVP (%s)" % hud.notice_label.text)
	client.free()
	summary_game.queue_free()

	hud.queue_free()
	player.queue_free()
	_done()


## Somebody else, hurt: a bar over their head for a few seconds.
func _check_health_tag(player: ArenaPlayer) -> void:
	player.health.health = player.health.max_health
	player.present(0.016)
	player.health.health = player.health.max_health * 0.4
	player.present(0.016)
	var tag := player._health_tag
	_check(tag != null and tag.visible and tag.get_node("Bar").visible,
		"a hurt player shows a bar over their head")
	for _i in 120:
		player.present(0.016)
	_check(tag != null and absf(tag.shown_fraction - 0.4) < 0.01 and absf(tag.trail_fraction - 0.4) < 0.01,
		"filled to what is left, the trail caught up")
	player.present(ArenaPlayer.HEALTH_TAG_SEC + 0.1)
	_check(not player._health_tag.visible, "and it goes after a few seconds")
	player.health.health = player.health.max_health


## When tags draw: the player's pick, the server's ceiling, team, cursor and a recent hit.
func _check_tag_rules(player: ArenaPlayer) -> void:
	var Rules := preload("res://game/arena_name_tag_rules.gd")
	_check(Rules.parse("team") == Rules.TEAM and Rules.parse("team,hover") == (Rules.TEAM | Rules.HOVER)
		and Rules.parse("smart") == (Rules.TEAM | Rules.HOVER | Rules.HURT) and Rules.parse("off") == 0
		and Rules.parse("bogus") == -1 and Rules.parse("team,bogus") == -1,
		"tag settings parse as presets and lists, and refuse what they do not know")
	_check(Rules.parse(Rules.describe(Rules.TEAM | Rules.HURT)) == (Rules.TEAM | Rules.HURT)
		and Rules.describe(0) == "off" and Rules.describe(Rules.ALL | Rules.TEAM) == "always",
		"and a mask reads back as the cvar writes it")
	_check(Rules.shows(Rules.ALL, Rules.ALL, false, false, false)
		and not Rules.shows(Rules.ALL, Rules.TEAM, false, false, false)
		and Rules.shows(Rules.ALL, Rules.TEAM, true, false, false)
		and not Rules.shows(Rules.TEAM, Rules.ALL, false, false, false)
		and not Rules.shows(Rules.ALL, 0, true, true, true)
		and Rules.shows(Rules.HOVER, Rules.TEAM | Rules.HOVER, false, true, false),
		"the server's value is a ceiling the player's choice can narrow and never widen")
	_check(Rules.needs_hover(Rules.HOVER, Rules.ALL) and not Rules.needs_hover(Rules.ALL, Rules.HOVER | Rules.ALL)
		and not Rules.needs_hover(Rules.TEAM, Rules.ALL),
		"the cursor test is only run when a setting asks for it")
	var feet := Vector3(0.0, 0.0, -10.0)
	_check(Rules.ray_hits_body(Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.0, -1.0), feet, 1.8)
		and Rules.ray_hits_body(Vector3(0.0, 1.7, 0.0), Vector3(0.0, -0.17, -1.0).normalized(), feet, 1.8)
		and not Rules.ray_hits_body(Vector3(2.0, 1.0, 0.0), Vector3(0.0, 0.0, -1.0), feet, 1.8)
		and not Rules.ray_hits_body(Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.0, 1.0), feet, 1.8)
		and not Rules.ray_hits_body(Vector3(0.0, 4.0, 0.0), Vector3(0.0, 0.0, -1.0), feet, 1.8),
		"the cursor is on a body when the view ray passes through it, in front, not beside or over it")

	# A player on the viewer's team, with names on for team-mates: name and bar both show.
	var saved := [Rules.client_names, Rules.client_bars, Rules.server_names, Rules.server_bars, Rules.viewer_id, Rules.viewer_team]
	Rules.client_names = Rules.TEAM
	Rules.client_bars = Rules.TEAM | Rules.HURT
	Rules.server_names = Rules.ALL
	Rules.server_bars = Rules.ALL
	Rules.viewer_id = player.player_id + 1000
	player.team = 1
	Rules.viewer_team = 1
	player.health.health = player.health.max_health
	player.present(0.016)
	var tag := player._health_tag
	_check(player.team >= 0 and tag != null and tag.visible and tag.get_node("Name").visible
		and tag.get_node("Name").text == player.display_name,
		"a team-mate wears their name and a bar at full health")
	Rules.server_names = 0
	player.present(0.016)
	_check(tag.visible and not tag.get_node("Name").visible and tag.get_node("Bar").visible,
		"the server turning names off hides the name and leaves the bar")
	Rules.server_bars = 0
	player.present(0.016)
	_check(not tag.visible, "and both off hides the tag")
	Rules.server_names = Rules.ALL
	Rules.server_bars = Rules.ALL
	Rules.viewer_team = -1
	player.present(0.016)
	_check(not tag.visible, "a stranger, unhurt and not under the cursor, gets no tag")
	player.health.health = player.health.max_health * 0.5
	player.present(0.016)
	_check(tag.visible, "until they are hurt")
	player.health.health = player.health.max_health
	Rules.client_names = saved[0]
	Rules.client_bars = saved[1]
	Rules.server_names = saved[2]
	Rules.server_bars = saved[3]
	Rules.viewer_id = saved[4]
	Rules.viewer_team = saved[5]
	player.present(ArenaPlayer.HEALTH_TAG_SEC + 0.1)


## A client turns the server's HIT and AWARD into the hit marker, a damage number, the medals and
## "+points  Victim", read back off the wire exactly as a link delivers them.
func _test_stock_avatars_differ() -> void:
	_section("Consecutive players do not wear the same stock face")

	var heads := {}
	var bodies := {}
	var shared_with_previous := 0
	var previous := &""
	for id in range(112, 128):
		var avatar := ArenaAvatars.stock_avatar(StringName(ArenaGame.storage_key(id)))
		var head := avatar.part_in(ArenaAvatars.SLOT_HEAD)
		heads[head] = true
		bodies[avatar.part_in(ArenaAvatars.SLOT_BODY)] = true
		if head == previous:
			shared_with_previous += 1
		previous = head

	# 16 picks from 20 heads land on about 11 distinct by chance; 8 leaves room for an
	# unlucky but honest mix and fails the old pick, which gave 4 (12 of 15 neighbours shared).
	_check(heads.size() >= 8, "16 consecutive players wear at least 8 different heads",
		"%d distinct" % heads.size())
	_check(shared_with_previous <= 3, "and few players share a head with the id before them",
		"%d of 15 neighbours" % shared_with_previous)
	_check(bodies.size() >= 8, "and at least 8 different bodies", "%d distinct" % bodies.size())

	var again := ArenaAvatars.stock_avatar(StringName(ArenaGame.storage_key(117)))
	_check(
		again.equals(ArenaAvatars.stock_avatar(StringName(ArenaGame.storage_key(117)))),
		"and a player's stock look is the same every time it is asked for"
	)
	_done()
