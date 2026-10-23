extends RefCounted

const ArenaBindings := preload("arena_bindings.gd")
const ArenaBrowser := preload("arena_browser.gd")
const ArenaModes := preload("arena_modes.gd")

## The Escape menu and the Tab board: dot-menu's, with this game's pages on it.
##
## [b]dot-menu's since 2026-10-10, like every other game here.[/b] It was dot-ui's
## `DotPauseScreen` (Resume, Settings, Interface, Controls, Servers, Leave) over two generated
## `DotSettingsScreen`s, a `DotBindingsPanel` rebinder and a browser screen, each a different
## look. Now it is the one menu: dot-menu's stock General, Video, Audio, Controls and
## Advanced pages as views of this game's settings document ([ArenaPresentation]), plus
## this game's own:
##
## - **Interface**: the theme, the frame-rate counter, the crosshair and the HUD's margin.
## - **Controls**: the stock mouse card, this game's look switches and every key from
##   [ArenaBindings], each a key button (rebindable, swapping on a conflict).
## - **Servers**: dot-browser's list, drawn as a page ([method _servers_page]).
##
## **Leave** is dot-menu's stock one ([member DotMenu.leave_on_its_own]): off the server when
## connected, which hands the player back to whatever loaded the client, and a quit when solo
## on a desktop. Until 2026-10-11 Leave only emitted `ArenaClient.leave_requested`, which
## nothing listened to, so the button did nothing; the signal is still emitted for an
## embedder. **H opens help** ([method _fill_help]: the goal and every mode), and the HUD's
## own key hints list it, so dot-menu's corner plate is off here.

const CHANNEL := "arena.menus"

## The action id Leave sends.
const LEAVE := &"leave"


## Builds the menu under [param host], with its pages, and the console as one of its
## overlays. [param browser] null leaves the Servers page out of the sidebar.
static func build(host: Node, presentation: Node, browser: ArenaBrowser = null) -> DotMenu:
	var settings: DotSettingsManager = presentation.settings if presentation != null else null

	var menu := DotMenu.new()
	menu.name = "GameMenu"
	# Under the HUD's clock, mode label and portraits (to y 160) and its notice line (182..): the
	# default 64 drew "Loadout equipped." over the mode label. By name: the web shell pinned
	# 2026-10-17 has dot-menu 0.1.3, older than `toast_top`, and assigning it there stopped
	# this function with a script error, so that shell's client had no menu at all.
	if &"toast_top" in menu:
		menu.set(&"toast_top", 236.0)
	menu.settings = settings
	menu.bindings = presentation.bindings if presentation != null else ArenaBindings.make()
	var config := DotMenuConfig.new()
	config.brand_name = "Arena"
	var _layered := config.load_layered()
	menu.config = config
	# Escape keeps its two steps here (the first releases the pointer, the second opens the
	# menu; see `ArenaClient._unhandled_input`), and the client is the one owner of the
	# pointer. Escape still closes the menu.
	menu.open_on_escape = false
	menu.manage_pointer = false
	menu.scoreboard_action = ArenaBindings.SCOREBOARD
	menu.leave_on_its_own = true
	# The HUD's key hints have H (`ArenaHud`), so dot-menu's corner plate would say it twice.
	config.help_hint = &"off"
	# The chat box or the console has the keyboard: Tab is a letter then, not the board.
	if presentation != null:
		menu.busy = func() -> bool: return presentation.swallows_input()
	host.add_child(menu)
	DotLog.result(CHANNEL, "the menu", menu.setup())

	add_pages(menu, browser)
	fill_help(menu.help)

	# The console after the menu, so DotConsoleKit registers it as one of the menu's
	# overlays: opening it frees the pointer and stops the player through
	# `overlays_changed`, which the client listens to.
	if presentation != null and presentation.has_method(&"build_console"):
		DotLog.result(CHANNEL, "the console", presentation.build_console(menu))
	return menu


## This game's rows and pages onto [param menu]'s stock ones. Public so a suite can build
## a menu without a client.
static func add_pages(menu: DotMenu, browser: ArenaBrowser = null) -> void:
	# Interface: the look of the screen. The theme and the counter move here from General.
	var general := menu.page(&"general")
	var interface := DotMenuPage.make(&"interface", "Interface", "The crosshair, the HUD and the colours of the menus.")
	var look := interface.section("Look")
	if general != null:
		for id in [&"ui_theme", &"show_fps"]:
			var row := general.take_row(id)
			if row != null:
				look.add(row)
		var _gone := general.remove_section(&"interface")
		general.blurb = "Comfort, camera motion, and whether there is a chat box."
	var theme_row := interface.find_row(&"ui_theme")
	if theme_row != null:
		theme_row.described("The colours of the menus and the scoreboard.")
	interface.section("HUD") \
		.add(DotMenuRow.select(&"crosshair", "Crosshair", "Circle draws the cross for now.",
			[[&"cross", "Cross"], [&"dot", "Dot"], [&"circle", "Circle"], [&"none", "None"]])) \
		.add(DotMenuRow.slider(&"hud_safe_area", "Edge margin", "Room between the HUD and the edge of the screen, for a television or a notch.")
			.formatted(func(v: float) -> String: return "%d px" % roundi(v)))
	menu.add_page(interface, &"video")

	# Camera motion, beside Comfort on General: the dip, the roll, the wall lean and the widening,
	# each a slider to Off for a player whom motion makes sick.
	if general != null:
		var motion := general.section("Camera motion")
		for row: Array in [
			[&"camera_landing_dip", "Landing dip"],
			[&"camera_strafe_roll", "Strafe lean"],
			[&"camera_wall_lean", "Wall-run lean"],
			[&"camera_speed_fov", "Speed widening"],
		]:
			# The words are the setting's own (`ArenaPresentation.CAMERA_MOTION_KEYS`), read from the
			# schema: this file cannot preload the presentation without a cycle through the HUD.
			var def: DotSettingsDef = menu.settings.schema.find(row[0]) if menu.settings != null else null
			motion.add(DotMenuRow.slider(row[0], row[1], def.description if def != null else "")
				.formatted(func(v: float) -> String: return "Off" if v <= 0.0 else "%d%%" % roundi(v * 100.0)))
		var calm: DotSettingsDef = menu.settings.schema.find(&"reduce_motion") if menu.settings != null else null
		motion.add(DotMenuRow.toggle(&"reduce_motion", "Reduce motion", calm.description if calm != null else ""))

	# Solo bots: dot-bot's presets, saved. A server's bots follow the server's bot_difficulty.
	if general != null:
		general.section("Solo bots").add(DotMenuRow.select(&"solo_bot_difficulty", "Bot difficulty",
			"How well the bots play when you play alone. Easy misses and reacts late; nightmare does neither. A server sets its own.",
			[[&"easy", "Easy"], [&"medium", "Medium"], [&"hard", "Hard"], [&"nightmare", "Nightmare"]]))

	var video := menu.page(&"video")
	if video != null:
		video.section("Image").add(DotMenuRow.toggle(&"view_model", "Weapon in view", "Your hands and gun. A server may turn them off."))

	var audio := menu.page(&"audio")
	if audio != null:
		audio.section("Voice").add(DotMenuRow.toggle(&"push_to_talk", "Push to talk", "Hold the Push to talk key (Controls) to talk. Off: an open microphone."))

	var controls := menu.page(&"controls")
	if controls != null:
		# This game's invert is `invert_pitch`, stored before dot-menu's `invert_mouse`
		# existed; the stock row for the stock key is not drawn, because it is not declared.
		controls.section("Mouse") \
			.add(DotMenuRow.toggle(&"invert_pitch", "Invert vertical look")) \
			.add(DotMenuRow.toggle(&"right_mouse_aims", "Right mouse aims", "Off: the Aim key (right mouse) bashes with the weapon instead of aiming."))

	if browser != null:
		menu.add_page(_servers_page(menu, browser), &"advanced")


## The help screen's goal and modes; the keys come from [ArenaBindings]. The modes are read
## from [ArenaModes], so a mode added there is on the help screen with nothing else edited.
static func fill_help(help: DotMenuHelp) -> void:
	if help == null:
		return
	help.about = "Fast deathmatch: run, slide, dash and shoot. Score by fragging, or by whatever the mode asks; the scoreboard (Tab) says who is ahead."
	var lines: Array = []
	for mode in ArenaModes.all():
		lines.append([mode.display_name, mode.description])
	help.add_section("Modes", lines, &"plain")
	help.add_text("Moving", "Duck while running to slide (C slides too), Shift dashes when the server turns arena_dash on, and E launches you. In a props mode E grabs a prop and F freezes it.")


## dot-browser's list as a page: a card of servers, each with a Join, and a Refresh.
##
## [b]A page rather than a screen of its own[/b], so it is in the menu's sidebar, theme and
## pointer handling like everything else. It is drawn fresh each time it is shown, which is
## what a page is; the listing it draws is the browser's, so nothing is kept between draws.
static func _servers_page(menu: DotMenu, browser: ArenaBrowser) -> DotMenuPage:
	var page := DotMenuPage.make(&"servers", "Servers", "Other servers running this game. Join says where to go.")
	# What the last refresh said, kept across draws: empty once it finished cleanly.
	var state := {"status": ""}
	browser.listing_changed.connect(func() -> void:
		if menu.is_open() and menu.screen.current_page() == &"servers":
			menu.screen.refresh())
	page.build = func(kit: DotMenuKit, body: VBoxContainer) -> void:
		var top := HBoxContainer.new()
		top.add_theme_constant_override(&"separation", 12)
		var status := kit.paragraph(str(state["status"]), kit.size_small, kit.palette.dim)
		status.name = "Status"
		status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		top.add_child(status)
		var refresh := Button.new()
		refresh.name = "Refresh"
		refresh.text = "Refresh"
		refresh.pressed.connect(func() -> void:
			state["status"] = "Looking..."
			status.text = state["status"]
			var done: DotResult = await browser.refresh()
			state["status"] = "" if done.ok else done.error.message
			if menu.is_open():
				menu.screen.refresh())
		top.add_child(refresh)
		body.add_child(top)

		var listing := browser.listing()
		if listing.is_empty():
			if str(state["status"]) == "":
				status.text = "Nothing listed yet. Refresh to ask the servers this game knows."
			return
		var card := kit.card()
		card.name = "List"
		var rows := VBoxContainer.new()
		card.add_child(rows)
		for entry in listing:
			if rows.get_child_count() > 0:
				rows.add_child(HSeparator.new())
			var line := HBoxContainer.new()
			line.add_theme_constant_override(&"separation", 18)
			line.custom_minimum_size = Vector2(0, 52)
			var words := VBoxContainer.new()
			words.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			words.alignment = BoxContainer.ALIGNMENT_CENTER
			words.add_child(kit.label(entry.name, kit.size_body, kit.palette.text))
			words.add_child(kit.label("%s  ·  %d/%d players  ·  %s" % [
				ArenaBrowser.game_field(entry, "map", entry.map),
				entry.players, entry.max_players,
				("%d ms" % entry.ping_ms) if entry.is_online() else "no answer",
			], kit.size_small, kit.palette.dim))
			line.add_child(words)
			var join := Button.new()
			join.text = "Join"
			join.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			var chosen := entry
			join.pressed.connect(func() -> void:
				menu.close()
				browser.join_requested.emit(chosen))
			line.add_child(join)
			rows.add_child(line)
		body.add_child(card)
	return page


## The Tab board's rows from dot-match, with the server's roster merged in by key for what
## only the server knows (time connected and ping).
##
## [b]dot-menu's `DotMenuScoreboard` since 2026-10-09[/b]; it hung off a dot-ui screen until
## the Escape menu moved, and is the menu's own `scoreboard` now. Held on Tab
## ([constant ArenaBindings.SCOREBOARD]), never one of the menu's overlays, so holding it
## stops nobody moving.
class Board extends RefCounted:
	var board: DotMenuScoreboard = null
	var _records: DotScoreboard = null
	var _teams: DotTeamManager = null
	var _me: String = ""
	var _game: Object = null

	## With [param p_game] (an `ArenaGame`) the records and teams are read off its current
	## match each time, because [param records] cannot be trusted to last: a client builds its
	## board before the match node has entered the tree (`DotMatch` makes its scoreboard only
	## then, so a null was held for ever and the server's roster, the local player alone with
	## K and D dashes, was drawn in place of every record), and a change of mode builds a new
	## match node, leaving the old scoreboard to be freed.
	func _init(p_board: DotMenuScoreboard, records: DotScoreboard, link: Object = null, teams: DotTeamManager = null, p_game: Object = null) -> void:
		board = p_board
		_records = records
		_game = p_game
		_teams = teams
		board.title_text = "Arena"
		board.columns = [
			{"key": &"name", "title": "Player", "width": 3.0},
			{"key": &"kills", "title": "K", "kind": DotMenuScoreboard.KIND_NUMBER},
			{"key": &"deaths", "title": "D", "kind": DotMenuScoreboard.KIND_NUMBER},
			{"key": &"assists", "title": "A", "kind": DotMenuScoreboard.KIND_NUMBER},
			{"key": &"score", "title": "Score", "kind": DotMenuScoreboard.KIND_NUMBER},
			{"key": &"seconds", "title": "Time", "kind": DotMenuScoreboard.KIND_DURATION},
			{"key": &"ping", "title": "Ping", "kind": DotMenuScoreboard.KIND_PING},
		]
		# dot-match's own order: best score, then kills.
		board.sort_with = func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("rank", 0)) < int(b.get("rank", 0))
		board.prepare = _rows_from_match
		if link != null and link.has_signal(&"scoreboard_received"):
			board.feed_from(link)
		else:
			# Offline nothing sends a roster; an empty one pulled twice a second keeps the
			# rows from the match current while the board is held.
			board.source = func() -> Dictionary: return {}

	## Which record is this client's. The roster says so online; offline nobody else will.
	func follow(key: String) -> void:
		_me = key

	func _rows_from_match(snap: Dictionary) -> void:
		# Looked up every time, for the reasons at `_init`.
		if _game != null and is_instance_valid(_game):
			var match_node: DotMatch = _game.get(&"match_node")
			if match_node != null and match_node.scoreboard != null:
				_records = match_node.scoreboard
				_teams = match_node.teams
		if _records == null:
			return
		var roster := {}
		for r in (snap.get("players", []) as Array):
			if r is Dictionary:
				roster[str(r.get("id", ""))] = r
		var you := str(snap.get("you", ""))
		var rows: Array = []
		var rank := 1
		var sides := {}
		for record in _records.ranked():
			if not record.present:
				continue
			var known: Dictionary = roster.get(record.key, {})
			rows.append({
				"id": record.key, "rank": rank, "name": record.display_name, "team": record.team,
				"kills": record.kills, "deaths": record.deaths, "assists": record.assists, "score": record.score,
				"seconds": int(known.get("seconds", -1)), "ping": int(known.get("ping", -1)),
				"you": record.key == _me or (you != "" and record.key == you),
			})
			if record.team > 0:
				sides[record.team] = true
			rank += 1
		snap["players"] = rows
		if _teams != null and sides.size() > 1:
			var listed: Array = []
			for id: int in _teams.team_ids():
				var side := _teams.team(id)
				if side != null and not side.is_spectator:
					listed.append({"id": id, "name": side.display_name, "color": side.colour,
						"score": _records.team_score(id)})
			snap["teams"] = listed
		if not snap.has("server"):
			snap["server"] = {"name": "Arena"}
