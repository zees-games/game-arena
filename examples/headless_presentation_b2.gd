extends "headless_presentation_b2a.gd"

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
	_check_tag_colours(Rules)
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


## Bar colour: enemies red, team-mates light green, a side's own colour only with more than two sides; smaller and lower.
func _check_tag_colours(Rules) -> void:
	var saved_count: int = Rules.team_count
	var saved_cols: Dictionary = Rules.team_colours
	Rules.team_colours = {1: Color.BLUE, 2: Color.YELLOW, 3: Color.PURPLE}
	Rules.team_count = 2
	_check(Rules.bar_tone(false, 2) == Rules.ENEMY_COLOUR and Rules.bar_tone(true, 1) == Rules.FRIEND_COLOUR,
		"two sides: enemies red, team-mates light green")
	Rules.team_count = 0
	_check(Rules.bar_tone(false, 0) == Rules.ENEMY_COLOUR, "free-for-all or 1v1: enemies red")
	Rules.team_count = 3
	_check(Rules.bar_tone(false, 3) == Color.PURPLE and Rules.bar_tone(true, 1) == Color.BLUE,
		"more than two sides: the side's own colour")
	Rules.team_count = saved_count
	Rules.team_colours = saved_cols
	_check(Rules.tag_scale < 1.0 and Rules.tag_height < 2.25, "the tag is smaller and lower than before")
