@tool
extends "arena_hud_base.gd"


func build(p_game: ArenaGame) -> void:
	game = p_game

	# First, so every widget added below draws over it. See [member blind_overlay].
	blind_overlay = ColorRect.new()
	blind_overlay.name = "Blind"
	blind_overlay.color = BLIND_COLOUR
	# Not anchored to this HUD's rect: `DotHud` insets itself by the safe area, and a blind the size
	# of the HUD left a 16-pixel frame of the world visible round the edge of the first rendered.
	blind_overlay.set_anchors_preset(Control.PRESET_TOP_LEFT)
	blind_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	blind_overlay.modulate.a = 0.0
	blind_overlay.visible = false
	add_child(blind_overlay)

	hurt_overlay = ColorRect.new()
	hurt_overlay.name = "Hurt"
	# Clear over the middle, so it reads as the edge of vision closing in rather than as a
	# red filter over the screen (the first render was the second).
	var shader := Shader.new()
	shader.code = HURT_SHADER
	var material := ShaderMaterial.new()
	material.shader = shader
	hurt_overlay.material = material
	hurt_overlay.color = Color.WHITE
	# Top-left anchored and sized to the viewport in `present_body`, like the blind: full-rect
	# anchors with a size written every frame drew an engine warning per write.
	hurt_overlay.set_anchors_preset(Control.PRESET_TOP_LEFT)
	hurt_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hurt_overlay.modulate.a = 0.0
	add_child(hurt_overlay)

	scope = AwScopeOverlay.new()
	scope.name = "Scope"
	add_child(scope)

	crosshair = DotCrosshair.new()
	crosshair.name = "Crosshair"
	crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	crosshair.fov_degrees = 75.0
	crosshair.length = 7.0
	crosshair.base_gap = 3.0
	crosshair.thickness = 2.0
	# Bound to the weapon's actual spread, so the crosshair opening means something.
	# A crosshair that opens by an arbitrary factor tells the player something
	# confident and wrong about where their shots will go.
	crosshair.bind(func() -> Variant:
		return player.spread_degrees() if _live() else 0.0
	)
	if _crosshair_hides:
		crosshair.set(&"alive_source", func() -> bool: return _live() and player.is_alive())
	add_child(crosshair)

	# Bottom left: health as a thick bar with its number at the end, armour as a thin one
	# under it when there is any. The bars ease and the numbers do not (`DotVitals`).
	vitals = DotVitals.new()
	vitals.name = "Vitals"
	_place(vitals, Control.PRESET_BOTTOM_LEFT, Rect2(0.0, -112.0, 380.0, 104.0))
	vitals.streak_icon = Look.medal_icon("fire")
	vitals.bar_start = 38.0
	vitals.bar_end = 300.0

	# Bottom right: the weapon's name, then `magazine | reserve`.
	ammo = DotAmmoCounter.new()
	ammo.name = "Ammo"
	_place(ammo, Control.PRESET_BOTTOM_RIGHT, Rect2(-300.0, -84.0, 290.0, 70.0))

	# The right edge below 110 px belongs to the client shell's ballot column (`SHELL_COLUMN_TOP`)
	# and this game cannot see when one is open, so the hints sit left and the weapon slots
	# stack up from the ammunition counter (checked with `screenshot.sh --glance --ballot`).
	hints = DotKeyHints.new()
	hints.name = "KeyHints"
	# Seven rows: started high so the last ends above the streak meter's words.
	_place(hints, Control.PRESET_CENTER_LEFT, Rect2(62.0, -170.0, 200.0, 196.0))

	slots = ArenaHudGlance.WeaponSlots.new()
	slots.name = "Slots"
	_place(slots, Control.PRESET_BOTTOM_RIGHT, Rect2(-170.0, -294.0, 160.0, 202.0))

	# Bottom centre: the abilities, clear of the hands at the bottom right.
	abilities = ArenaHudGlance.AbilityBar.new()
	abilities.name = "Abilities"
	_place(abilities, Control.PRESET_CENTER_BOTTOM, Rect2(-200.0, -98.0, 400.0, 90.0))

	slide_label = DotKeyPrompt.new()
	slide_label.name = "Prompt"
	_place(slide_label, Control.PRESET_CENTER, Rect2(-330.0, 120.0, 300.0, 36.0))
	slide_label.visible = false

	feed = ArenaHudGlance.KillFeed.new()
	feed.name = "KillFeed"
	_place(feed, Control.PRESET_TOP_RIGHT, Rect2(-470.0, 0.0, 460.0, 170.0))
	_fit_feed()
	feed.lifetime_sec = config.feed_lifetime_sec if config != null else 6.0

	strip = DotScoreStrip.new()
	strip.name = "Scores"
	_place(strip, Control.PRESET_CENTER_TOP, Rect2(-260.0, 0.0, 520.0, 72.0))

	portraits = ArenaHudGlance.Portraits.new()
	portraits.name = "Portraits"
	_place(portraits, Control.PRESET_CENTER_TOP, Rect2(-270.0, 74.0, 540.0, 80.0))
	portrait_cache = ArenaHudGlance.PortraitCache.new()
	portrait_cache.name = "PortraitCache"
	add_child(portrait_cache)

	objective_label = _make_label(
		"Objective", Control.PRESET_CENTER_TOP, Vector2(0.0, 154.0)
	)
	# No match, nothing to score: a render tool or a suite building the HUD alone.
	strip.visible = game != null
	portraits.visible = game != null

	if game != null:
		game.player_killed.connect(_on_kill)


## Adds [param piece] with [param preset]'s anchors and [param rect] as its offsets from
## them. Every piece ignores the mouse: a HUD that takes a click eats the shot.
func _place(piece: Control, preset: Control.LayoutPreset, rect: Rect2) -> void:
	piece.set_anchors_preset(preset)
	piece.offset_left = rect.position.x
	piece.offset_top = rect.position.y
	piece.offset_right = rect.end.x
	piece.offset_bottom = rect.end.y
	piece.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Icons drawn smaller than their files: without mipmaps a silhouette's thin parts break up.
	piece.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	add_child(piece)


## Where each piece of the HUD draws, in frame pixels: what it puts on screen, not its
## `Control`'s box (the feed's box is 460 wide; its rows are as wide as their names). Only
## pieces drawn now. What `headless_presentation` checks for overlap on small frames.
func footprints() -> Dictionary:
	var out := {}
	var pieces := {
		"scores": strip, "portraits": portraits, "feed": feed, "vitals": vitals,
		"ammo": ammo, "slots": slots, "abilities": abilities, "hints": hints,
		"prompt": slide_label, "medals": medal_row,
	}
	for key: String in pieces:
		var piece: Control = pieces[key]
		if piece == null or not piece.is_visible_in_tree():
			continue
		var local: Rect2 = piece.call(&"footprint")
		if local.has_area():
			out[key] = piece.get_global_transform() * local
	for label: Label in [notice_label, objective_label, death_label, points_label]:
		if label != null and label.is_visible_in_tree() and label.text != "":
			out[String(label.name)] = label.get_global_rect()
	return out


## Points the HUD at a player. Called on every spawn.
##
## The widgets hold a `Callable` that reads `player`, so re-pointing this one field
## repoints all of them. Binding each widget to a body would mean rebinding six
## callables every time someone respawns, and the one that got missed would show the
## previous life's health for ever.
func follow(p_player: ArenaPlayer) -> void:
	player = p_player


func _live() -> bool:
	return player != null and is_instance_valid(player)


## Gives the crosshair the field of view the camera is actually drawing with.
##
## [b]The crosshair turns an angle of spread into pixels, and that conversion is only
## as right as the field of view it is given.[/b] It was a constant 75 here while the
## camera was the player's own setting converted from horizontal-at-4:3 — 83.6 degrees
## vertical at the default of 100 — so every gap was drawn 17% wider than the cone the
## shots actually leave in, and at a setting of 120 it was 69% wider. A crosshair that is
## confidently wrong about where the shots go is exactly what `DotCrosshair` says it
## exists to avoid.
##
## Read off the camera once a frame rather than pushed from the settings, because the
## camera is the one place the field of view is written: a player's slider, a server's
## clamp and the first `attach_camera` all end there, and a copy fed by one of them
## would disagree with the other two.
func match_view() -> void:
	if crosshair == null or not _live() or player.camera == null:
		return

	crosshair.fov_degrees = player.camera.fov


## Puts a kill on the feed.
##
## Public because on a NETWORKED client nothing local scores anything: `game.player_killed`
## fires on the server, and the client learns about a kill from an `ArenaEvents.Kind.KILL`
## event. `ArenaClient` rebuilds the entry and calls this; the signal path below is the
## offline and listen-server one. Both end in the same place deliberately — a feed that
## looked different depending on how the kill arrived would be two feeds.
func show_kill(entry: DotKillFeed.Entry) -> void:
	_on_kill(entry)


## A kill's cause as a player reads it: a weapon's display name ("Machine Pistol", not
## `machine_pistol`), and anything that is not a weapon — a monster, `slay`, the world —
## as it came.
static func cause_label(cause: Variant) -> String:
	var def := ArenaPlayer.weapon_catalogue().get_def(StringName(str(cause)))
	return def.display_name if def != null else str(cause)


func _on_kill(entry: DotKillFeed.Entry) -> void:
	if feed == null:
		return

	var me := str(player.player_id) if _live() else ""

	feed.add_kill(
		entry.killer_name if entry.killer_key != entry.victim_key else "",
		_name_colour(entry.killer_key, entry.killer_team, me),
		entry.cause,
		cause_label(entry.cause),
		entry.victim_name,
		_name_colour(entry.victim_key, entry.victim_team, me),
		entry.headshot,
		me != "" and (entry.killer_key == me or entry.victim_key == me)
	)


## A name's colour in the feed: gold for you, the side's colour in a team mode, else white.
func _name_colour(key: String, team: int, me: String) -> Color:
	if key == me and me != "":
		return GOLD
	var side := _team_colour(team)
	return side.lightened(0.35) if side.a > 0.0 else Color(0.95, 0.96, 0.98)


## [param team]'s colour, or transparent when it is no side (a free-for-all, nobody).
func _team_colour(team: int) -> Color:
	if team <= 0 or game == null or game.match_node == null or game.match_node.teams == null:
		return Color(0, 0, 0, 0)
	var mode := game.displayed_mode()
	if mode == null or not mode.is_team_mode():
		return Color(0, 0, 0, 0)
	var side := game.match_node.teams.team(team)
	return side.colour if side != null else Color(0, 0, 0, 0)


## Fills the feed from kills that happened before this HUD existed.
##
## What a client joining a match in progress needs, and what a HUD rebuilt after a
## settings change needs. `DotKillFeed` is bounded and keeps its entries, so the last
## few are always available -- taking them is one call and not having it is a feed that
## is empty until the next person dies.
func catch_up(since_tick: int = -1) -> int:
	if game == null or feed == null:
		return 0

	var entries := (
		game.match_node.feed.recent(feed.max_lines) if since_tick < 0
		else game.match_node.feed.since(since_tick)
	)

	for entry in entries:
		_on_kill(entry)

	return entries.size()


## Refreshes the two labels that are not widgets.
##
## The round timer and the score are read once a frame rather than through a
## `DotHudWidget`, because both are strings assembled from several values and a widget
## exists to bind one.
func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var t := Time.get_ticks_usec()
	_present(delta)
	ArenaFrameProbe.add(&"hud", t)


func _present(delta: float) -> void:
	match_view()
	present_blind(delta)
	present_body()

	if feed != null:
		feed.advance(delta)
	present_gear()
	make_room()

	if game == null or strip == null:
		return

	present_scores()
	_portraits_in -= delta
	if _portraits_in <= 0.0:
		_portraits_in = 0.25
		present_portraits()

	if objective_label != null:
		objective_label.text = _objective_line()


## The clock, the two scores, the target and the mode, into the strip. Public so a render
## tool or a suite can put it up without a frame.
func present_scores() -> void:
	# The override first, when there is one.
	#
	# [b]A networked client's own `DotMatch` never runs.[/b] Nothing ticks it, so
	# `seconds_remaining()` is derived from `_ticks_in_state` against a `_current_tick`
	# that is still 0 — a number nothing ever wrote, not a stale one. A connected
	# browser client showed "IDLE" for ever while the server was playing a round.
	# `ArenaClient` writes the server's figure here from the MATCH event.
	var remaining := (
		remaining_override if not is_nan(remaining_override)
		else game.match_node.seconds_remaining()
	)
	var clock := (
		String(DotMatch.State.keys()[game.match_node.state]).capitalize() if remaining < 0.0
		# Rounded up, so the clock never says 0:00 with time left (dot-ui's; arena's own
		# rounded down until 2026-10-11).
		else DotScoreStrip.clock_text(remaining)
	)
	var mode := game.displayed_mode()
	var limit := game.match_node.rules.score_limit if game.match_node.rules != null else 0
	strip.show_clock(clock, remaining >= 0.0 and remaining <= 30.0,
		"First to %d" % limit if limit > 0 else "", mode.display_name if mode != null else "")

	var board := game.match_node.scoreboard
	var me := str(player.player_id) if _live() else ""
	var mine_record: DotPlayerScore = board.find(me) if me != "" else null
	if mode != null and mode.is_team_mode() and game.match_node.teams != null:
		# Your side on the left, as the genre has it.
		var sides: Array[int] = []
		for id: int in game.match_node.teams.team_ids():
			var side := game.match_node.teams.team(id)
			if side != null and not side.is_spectator:
				sides.append(id)
		if sides.size() >= 2:
			var mine := mine_record.team if mine_record != null else sides[0]
			var left := mine if sides.has(mine) else sides[0]
			var right := sides[1] if left == sides[0] else sides[0]
			var l := game.match_node.teams.team(left)
			var r := game.match_node.teams.team(right)
			_show_scores(board.team_score(left), board.team_score(right),
				l.display_name.to_upper(), r.display_name.to_upper(), l.colour, r.colour)
			return
	# A free-for-all: you, and whoever is ahead of you (behind you, when you lead).
	var other: DotPlayerScore = null
	for record in board.ranked():
		if record.present and record != mine_record:
			other = record
			break
	var leading := mine_record != null and (other == null or mine_record.score >= other.score)
	_show_scores(
		mine_record.score if mine_record != null else 0, other.score if other != null else 0,
		"YOU", "%s  %s" % ["2ND" if leading else "1ST", other.display_name.to_upper() if other != null else "-"],
		ArenaHudGlance.BLUE, ArenaHudGlance.RED)


## `strip.show_scores` only when something it shows changed: it queues a redraw on every call, and this runs every frame.
func _show_scores(p_left: int, p_right: int, p_left_tag: String, p_right_tag: String, p_left_colour: Color, p_right_colour: Color) -> void:
	if strip.sides and strip.left_score == p_left and strip.right_score == p_right and strip.left_tag == p_left_tag \
			and strip.right_tag == p_right_tag and strip.left_colour == p_left_colour and strip.right_colour == p_right_colour:
		return
	strip.show_scores(p_left, p_right, p_left_tag, p_right_tag, p_left_colour, p_right_colour)


## The ranked row under the strip: a portrait, rank and kill count per player.
func present_portraits() -> void:
	var entries: Array[Dictionary] = []
	var me := str(player.player_id) if _live() else ""
	var mode := game.displayed_mode()
	var teams := mode != null and mode.is_team_mode()
	var ids: Array = []
	var rank := 1
	for record in game.match_node.scoreboard.ranked():
		if not record.present or rank > ArenaHudGlance.Portraits.MAX_SHOWN:
			continue
		var id := int(record.key) if record.key.is_valid_int() else 0
		ids.append(id)
		var who := game.player_for(id) if id != 0 else null
		var avatar: DotAvatar = who.avatar if who != null and who.avatar != null \
			else ArenaAvatars.stock_avatar(StringName(ArenaGame.storage_key(id)))
		var side := _team_colour(record.team) if teams else Color(0, 0, 0, 0)
		entries.append({
			"name": record.display_name, "rank": rank, "kills": record.kills, "me": record.key == me,
			"ring": side if side.a > 0.0 else Color(1, 1, 1, 0.85),
			"colour": Color.from_hsv(fmod(float(id) * 0.37, 1.0), 0.55, 0.85),
			"texture": portrait_cache.portrait(id, avatar) if portrait_cache != null else null,
		})
		rank += 1
	portraits.show_players(entries)
	if portrait_cache != null:
		portrait_cache.keep_only(ids)


## Health, ammunition, the carried weapons and the key hints, from the followed player.
func present_gear() -> void:
	var live := _live() and player.is_alive()
	if vitals != null:
		vitals.visible = _live()
		if _live() and player.health != null:
			vitals.show_vitals(player.health.health, player.health.max_health, player.health.armour, player.health.max_armour)

	var slot: DotWeaponSlot = player.arsenal.current() if live and player.arsenal != null else null
	var fire_key := String(keys.get(&"fire_mode", ""))
	if ammo != null and slot != null and (slot != _label_slot or slot.fire_mode() != _label_mode or fire_key != _label_key):
		_label_slot = slot
		_label_mode = slot.fire_mode()
		_label_key = fire_key
		_weapon_label = mode_label(slot, fire_key)
	if ammo != null:
		if slot == null:
			ammo.show_ammo("", -1, -1, false)
		elif slot.def.magazine <= 0 and slot.def.ammo_type == &"":
			ammo.show_ammo(_weapon_label, -1, -1, false)
		elif slot.def.magazine <= 0:
			var pool := player.arsenal.ammo().count(slot.def.ammo_type)
			ammo.show_ammo(_weapon_label, pool, -1, pool <= 0)
		else:
			var reserve := player.arsenal.ammo().count(slot.def.ammo_type) if slot.def.ammo_type != &"" else -1
			ammo.show_ammo(_weapon_label, slot.magazine, reserve,
				float(slot.magazine) <= float(slot.def.magazine) * 0.25)

	if slots != null:
		var rows: Array[Dictionary] = []
		if live and player.arsenal != null:
			for index in player.arsenal.slots():
				var held := player.arsenal.slot_at(index)
				if held != null:
					rows.append({"slot": index, "id": held.def.id, "name": held.def.display_name,
						"key": String(keys.get(SLOT_KEYS[index] if index < SLOT_KEYS.size() else &"", String.num_int64(index)))})
		slots.show_slots(rows, player.arsenal.current_slot() if live and player.arsenal != null else 0)

	if hints != null:
		# Keyboard keys mean nothing on a phone, and the list covers the view there.
		hints.visible = live and not DotPlatform.has_touch()
		var shown: Array = [
			["Scoreboard", keys[&"scoreboard"]], ["Menu", keys[&"menu"]], ["Help", keys[&"help"]],
			["Maps", keys[&"maps"]],
		]
		# The loadout's key only where there is a loadout menu: an older shell, or a mode that
		# hands out the weapons, has none to open.
		var shown_mode: Variant = game.displayed_mode() if game != null else null
		if String(keys.get(&"loadout", "")) != "" and (shown_mode == null or not bool(shown_mode.call(&"arms_players"))):
			shown.append(["Loadout", keys[&"loadout"]])
		shown.append_array([["Chat", keys[&"chat"]], ["Slide", keys[&"slide"]]])
		hints.show_hints(shown)


## What the ammunition counter shows for [param who]: the magazine, or for a weapon that
## has none, what is left in its pool. Static so a suite can ask it without a HUD.
static func rounds_in_hand(who: ArenaPlayer) -> int:
	if who == null or who.arsenal == null:
		return 0

	var slot := who.arsenal.current()

	if slot == null:
		return 0

	if slot.def.magazine > 0:
		return slot.magazine

	if slot.def.ammo_type == &"":
		return 0

	return who.arsenal.ammo().count(slot.def.ammo_type)


## The line over the counter: the weapon's name and, for one with a magazine, the reserve.
## A melee weapon is its name alone.
static func weapon_line(who: ArenaPlayer) -> String:
	if who == null or who.arsenal == null or not who.is_alive():
		return ""

	var slot := who.arsenal.current()

	if slot == null:
		return ""

	if slot.def.magazine <= 0 or slot.def.ammo_type == &"":
		return slot.def.display_name

	return "%s   %d" % [slot.def.display_name, who.arsenal.ammo().count(slot.def.ammo_type)]


## The scope, the hurt edge, the launch's readiness and the slide prompt, from the
## followed player. Public so a suite can drive it without a frame.
func present_body() -> void:
	var live := _live()
	var hands: AwViewModel = (
		player.weapons.view_model() as AwViewModel
		if live and player.weapons != null else null
	)
	# The scope's view comes up over the aim-in (aw_ads_rules), so the crosshair gives way as it does.
	var scope_up := hands != null and hands.scope_fraction() > 0.0

	if scope != null:
		if hands != null:
			scope.follow(hands)
		else:
			scope.fraction = 0.0
		if scope_up:
			_fill_viewport(scope)
	if crosshair != null:
		# The scope has its own reticle; a crosshair drawn over it is two.
		# Dead or in a kill view: DotCrosshair hides itself (alive_source); older dot-ui is hidden here.
		crosshair.visible = not scope_up and (_crosshair_hides or (live and player.is_alive()))
		# Down an iron sight the sight is the aiming mark: the crosshair fades out as the gun
		# comes up and back as it goes down (dot-ui's DotCrosshair, API 5; Christian's first
		# play test had both on screen at once). Hip fire keeps it.
		if _crosshair_fades:
			crosshair.call(&"set_aim", hands.aim_fraction() if hands != null and not scope_up else 0.0)

	_present_hurt(live)

	var state: DotFpsState = player.controller.state if live else null
	var tunables: DotFpsTunables = player.controller.tunables if live else null
	present_abilities(state, tunables)

	# What can be done right now, as the genre prompts it.
	if slide_label != null:
		if state != null and state.is_sliding():
			slide_label.show_prompt("Cancel slide", _key_label(&"slide"))
		elif live and player.is_alive() and _needs_reload():
			slide_label.show_prompt("Reload", _key_label(&"reload"))
		elif live and player.is_alive() and use_hint != "":
			slide_label.show_prompt(use_hint, _key_label(&"use"))
		elif roam_hint != "" and player != null and not player.is_alive():
			slide_label.show_prompt(roam_hint, _key_label(&"roam"))
		else:
			slide_label.show_prompt("", "")

	_build_feedback()
	if death_label == null:
		death_label = _make_label("Death", Control.PRESET_CENTER_TOP, Vector2(0.0, 222.0))
		death_label.add_theme_font_size_override(&"font_size", 22)

	var delta := get_process_delta_time()
	var streak := int(streaks.get(player.player_id, 0)) if player != null else 0
	vitals.show_streak(streak, STREAK_FULL)
	# The hit marker and the damage numbers advance themselves (`DotHudPiece._process`).
	medal_row.advance(delta)

	if notice_label != null:
		_notice_age += delta
		notice_label.modulate.a = clampf((NOTICE_SEC - _notice_age) / 0.5, 0.0, 1.0)

	death_label.visible = player != null and not player.is_alive() and _death_text != ""
	death_label.text = _death_text

	if points_label == null:
		# Top left: a count, not something to watch.
		points_label = _make_label("Points", Control.PRESET_TOP_LEFT, Vector2(0.0, 8.0))
		points_label.grow_horizontal = Control.GROW_DIRECTION_END
		points_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		points_label.offset_left = 8.0
		points_label.add_theme_color_override(&"font_color", Color(1.0, 0.82, 0.25))
	var count := 0
	if live and game != null and game.drops != null:
		count = int(game.drops.points.get(player.player_id, 0))
	points_label.visible = count > 0
	points_label.text = points_text(count)

	if _points_seen >= 0 and count > _points_seen:
		popup("".join(["+", points_text(count - _points_seen)]), Color(1.0, 0.82, 0.25))
	_points_seen = count

	_advance_popups(get_process_delta_time())


## Covers the whole viewport, like the blind: the HUD's own size leaves the safe-area strip showing.
func _fill_viewport(control: Control) -> void:
	if not is_inside_tree():
		return
	var inverse := get_global_transform().affine_inverse()
	control.position = inverse * Vector2.ZERO
	control.size = inverse.basis_xform(get_viewport_rect().size)


## The key a prompt names; none on a touch device, which has no keyboard.
func _key_label(action: StringName) -> String:
	return "" if DotPlatform.has_touch() else String(keys[action])


## The red edge from low health and from a flash.
func _present_hurt(live: bool) -> void:
	if hurt_overlay == null:
		return
	var hurt := 0.0
	if live and player.health != null and player.health.max_health > 0.0:
		var fraction := player.health.health / player.health.max_health
		hurt = clampf((HURT_FROM - fraction) / HURT_FROM, 0.0, 1.0)
	if live and flash_source != null and is_instance_valid(flash_source):
		var flash: Color = flash_source.get(&"flash_colour")
		hurt = maxf(hurt, minf(flash.a * HURT_PULSE_GAIN, HURT_PULSE_MAX))
	hurt_overlay.modulate.a = hurt
	if hurt > 0.0:
		_fill_viewport(hurt_overlay)


## The ability buttons from the followed player's movement state: slide, launch and dash
## with their cooldowns, and the wall jump with its jumps left in the air. Only the ones
## the server's rules turn on.
func present_abilities(state: DotFpsState, tunables: DotFpsTunables) -> void:
	if abilities == null:
		return
	var buttons: Array[Dictionary] = []
	if state != null and tunables != null:
		if tunables.slide_enabled:
			buttons.append(_button(&"slide", "Slide", state.slide_cooldown_left, tunables.slide_cooldown, state.is_sliding()))
		if tunables.launch_enabled:
			buttons.append(_button(&"launch", "Launch", state.launch_cooldown_left, tunables.launch_cooldown, false))
		if tunables.dash_enabled:
			buttons.append(_button(&"dash", "Dash", state.dash_cooldown_left, tunables.dash_cooldown, false))
		if tunables.wall_jump_enabled:
			var b := _button(&"wall_jump", "Wall jump", 0.0, 0.0, state.is_wall_running())
			b["key"] = keys[&"jump"]
			b["pips_max"] = tunables.wall_jump_max_per_air
			b["pips"] = maxi(0, tunables.wall_jump_max_per_air - state.wall_jumps_in_air)
			buttons.append(b)
	abilities.visible = not buttons.is_empty()
	abilities.show_buttons(buttons)


func _button(id: StringName, label: String, left: float, total: float, active: bool) -> Dictionary:
	return {
		"id": id, "label": label, "key": str(keys.get(id, "")), "left": maxf(left, 0.0), "total": total,
		"active": active, "icon": ArenaHudGlance.Ink.texture("%s/%s.png" % [ArenaHudGlance.HUD_ICON_DIR, String(id)]),
	}


## An empty magazine with rounds in reserve: the moment to say R.
func _needs_reload() -> bool:
	if player.arsenal == null:
		return false
	var slot := player.arsenal.current()
	if slot == null or slot.def.magazine <= 0 or slot.magazine > 0 or slot.def.ammo_type == &"":
		return false
	return player.arsenal.ammo().count(slot.def.ammo_type) > 0 and not player.arsenal.is_reloading()


## Fades [member blind_overlay] toward whether the followed player is blinded.
##
## Read off [member player] rather than pushed by anybody, because the flag arrives in a
## snapshot on a networked client and is set directly offline, and a HUD that had to be
## told would need telling from two places. Public so a check can step it.
func present_blind(delta: float) -> void:
	if blind_overlay == null:
		return

	var want := 1.0 if _live() and player.blinded else 0.0
	blind_overlay.modulate.a = move_toward(
		blind_overlay.modulate.a, want, maxf(delta, 0.0) / BLIND_FADE_SEC
	)
	blind_overlay.visible = blind_overlay.modulate.a > 0.0

	if blind_overlay.visible and is_inside_tree():
		# The whole viewport, in this HUD's own coordinates — whatever the safe area and
		# the interface scale did to where this HUD starts.
		var inverse := get_global_transform().affine_inverse()
		blind_overlay.position = inverse * Vector2.ZERO
		blind_overlay.size = inverse.basis_xform(get_viewport_rect().size)


## Capture the flag: each team's captures and what became of its flag, and the clock when there is a limit.
func _ctf_line(ctf: DotObjectiveCtf) -> String:
	var state := ctf.hud_state()
	var teams: Dictionary = state["teams"]
	var ids: Array = teams.keys()
	ids.sort()
	var parts := PackedStringArray()
	for id: int in ids:
		var t: Dictionary = teams[id]
		var what := String(t["state"]).substr(0, 4)
		if t["state"] == "DROPPED":
			what += " %d" % ceili(float(t["returns_in"]))
		parts.append("T%d %d [%s]" % [id, t["captures"], what])
	var left := float(state["time_left"])
	if left >= 0.0:
		parts.append("%d:%02d" % [int(left) / 60, int(left) % 60])
	return "  ".join(parts)


## One line about the objectives, or nothing at all.
##
## Reads the mirroring manager on a client and the real one on a listen server, which
## is the same object either way: `ArenaObjectives` holds a `DotObjectiveManager` whose
## `authoritative` decides whether it simulates, and a HUD asking it for a fraction does
## not care which.
func _objective_line() -> String:
	if game.objectives == null or game.objectives.manager == null:
		return ""

	var manager := game.objectives.manager

	if not manager.has_objectives():
		return ""

	if game.objectives.ctf != null:
		return _ctf_line(game.objectives.ctf)

	var parts := PackedStringArray()

	for objective in manager.objectives.objectives:
		var label := objective.def.label if objective.def.label != "" \
			else String(objective.id())

		if objective is DotObjectiveHoldout:
			var holdout := objective as DotObjectiveHoldout
			var lead := holdout.leader()
			if lead <= 0:
				parts.append("%s --" % label)
			else:
				var left := holdout.remaining_for(lead)
				parts.append(
					"%s %d:%02d" % [
						label,
						left / (60 * game.tick_rate),
						(left / game.tick_rate) % 60,
					]
				)
		elif objective is DotObjectiveFlag:
			var flag := objective as DotObjectiveFlag
			parts.append(
				"%s %s" % [
					label,
					DotObjectiveFlag.State.keys()[flag.state].substr(0, 4),
				]
			)
		elif objective.owner_team > 0:
			parts.append("%s:%d" % [label, objective.owner_team])
		else:
			parts.append("%s %d%%" % [label, int(objective.progress() * 100.0)])

	return "  ".join(parts)
