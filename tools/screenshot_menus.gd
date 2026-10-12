extends SceneTree

const ArenaBrowser := preload("../game/arena_browser.gd")
const ArenaHud := preload("../game/arena_hud.gd")
const ArenaMenus := preload("../game/arena_menus.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")

## Renders this game's own screens to `screenshots/` so a person can look at them.
##
## [b]Separate from `screenshot.gd`, which renders MAPS.[/b] A map wants a camera framing
## a world and a menu wants a viewport-sized stack with nothing behind it; one script that
## did both would spend most of itself deciding which it was doing.
##
## The menu here is dot-menu's with this game's pages on it, so every page is rendered:
## dot-menu's own `tools/screenshot.sh` draws its demo's pages, not these rows.
##
## Run through `tools/screenshot_menus.sh`. [b]Not `--headless`[/b]: that gives a null
## renderer, a 64 x 64 viewport, and every frame it saves is empty — which is worse than no
## screenshot because it looks like one.

const OUT_DIR := "res://screenshots"
const SETTLE := 3

var _menu: DotMenu = null
var _board: ArenaMenus.Board = null
var _browser: ArenaBrowser = null
var _hud: ArenaHud = null
var _chat: DotChatWindow = null
var _presentation: ArenaPresentation = null
var _shots: Array[Dictionary] = []
var _at := 0
var _wait := SETTLE
var _done := false


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	# A scratch settings document, never this machine's real one (see
	# `ArenaPresentation.use_scratch_settings`): a render must not save into a player's file,
	# and must draw from the defaults rather than whatever the last run left there.
	var _scratch := ArenaPresentation.use_scratch_settings("screenshot_menus")
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_shots = [
		{"id": &"menu", "page": &"general", "file": "menu_general.png"},
		{"id": &"menu", "page": &"general", "file": "menu_general_2.png", "scroll": 600},
		{"id": &"menu", "page": &"interface", "file": "menu_interface.png"},
		{"id": &"menu", "page": &"video", "file": "menu_video.png"},
		{"id": &"menu", "page": &"audio", "file": "menu_audio.png"},
		{"id": &"menu", "page": &"controls", "file": "menu_controls.png"},
		# Every key is a row, so the page is long: the keys further down, scrolled to.
		{"id": &"menu", "page": &"controls", "file": "menu_controls_2.png", "scroll": 560},
		{"id": &"menu", "page": &"controls", "file": "menu_controls_3.png", "scroll": 1120},
		{"id": &"menu", "page": &"controls", "file": "menu_controls_4.png", "scroll": 1680},
		{"id": &"menu", "page": &"servers", "file": "menu_servers.png"},
		{"id": &"help", "file": "menu_help.png"},
		{"id": &"board", "file": "menu_scoreboard.png"},
		# Nothing open, so what is drawn is the HUD and the chat box over it. This one is
		# about where they are relative to EACH OTHER: the box sits in the same corner as
		# health and armour, and at the default inset it draws its log through both.
		{"id": &"", "file": "hud_chat.png"},
		# The console, open over the HUD: the real `ArenaPresentation`, so the panel is the
		# one `DotConsoleKit` builds, registered with the menu as the client registers it.
		{"id": &"console", "file": "hud_console.png"},
	]


## Built on the first frame rather than in `_initialize`, where nothing is in the tree yet
## and the presentation's settings, audio and console would set up outside it.
func _build() -> void:
	_build_hud()

	_presentation = ArenaPresentation.new()
	_presentation.name = "Presentation"
	root.add_child(_presentation)
	DotLog.result("screenshot", "the presentation", _presentation.setup())

	# The menu the client builds (dot-menu's, through ArenaMenus), over this game's own
	# settings document and key table, with a browser holding two servers as a list
	# would after a refresh.
	_browser = ArenaBrowser.new()
	_browser.name = "Browser"
	root.add_child(_browser)
	var _listed := _browser.setup()
	# Two servers as a refresh would leave them: answered, named, with a map and a ping.
	# Written by hand because nothing answers a query in a render tool; what this frame is
	# for is the page's layout.
	var fixtures := [
		["play.example.com:27015", "Arena  |  deathmatch all day", "dm_atrium", 9, 16, 34],
		["eu.example.net:27016", "a server with a long name that has to fit on one line", "dm_box", 2, 12, 88],
	]
	for f in fixtures:
		var added := _browser.add(str(f[0]))
		if added.ok:
			var entry := added.value as DotBrowserEntry
			entry.status = DotBrowserEntry.Status.ONLINE
			entry.name = str(f[1])
			entry.map = str(f[2])
			entry.players = int(f[3])
			entry.max_players = int(f[4])
			entry.ping_ms = int(f[5])
	_menu = ArenaMenus.build(root, _presentation, _browser)

	# A scoreboard with names of the length a real one has, and a row that is the local
	# player, because a highlight that reads at "bo" and not at a real handle is the kind
	# of thing only a picture shows.
	var records := DotScoreboard.new()
	var names := ["gamemann", "a_very_long_display_name", "bo", "quiet_one", "newcomer"]
	for i in names.size():
		var key := "p%d" % (i + 1)
		records.join(key, names[i])
		# Through the real scoring calls rather than by writing the fields, because a
		# picture of numbers assigned by hand is a picture of an assignment.
		for _k in range((names.size() - i) * 2):
			records.note_kill(key, "p%d" % (i + 2), 0)
		records.note_assist(key, 0, 0)
	_board = ArenaMenus.Board.new(_menu.scoreboard, records)
	_board.follow("p1")


## This game's own HUD, with the chat box over it, both at the real offsets.
func _build_hud() -> void:
	_hud = ArenaHud.new()
	_hud.name = "Hud"
	# Assigned rather than left to `DotHud._ready` to fill in: nothing added during
	# `SceneTree._initialize` is inside the tree yet, so no `_ready` has run and
	# `ArenaHud.build` would read `config.feed_lines` off a null.
	_hud.config = DotUiConfig.new()
	root.add_child(_hud)
	_hud.build(null)

	_chat = DotChatWindow.new()
	_chat.name = "Chat"
	_chat.register_actions = false
	# Nothing expires in a screenshot: under software rendering a frame takes the better
	# part of a second, so a lifetime is spent before the grab and the picture is of an
	# empty log — which looks exactly like a log that cannot draw.
	_chat.lifetime_sec = 0.0
	_chat.margin_left = 24.0
	_chat.margin_bottom = 110.0
	_chat.channels = [
		{"id": &"all", "label": "Say", "colour": Color(0.88, 0.90, 0.94)},
		{"id": &"team", "label": "Say (TEAM)", "colour": Color(0.55, 0.85, 0.60), "team": true},
	]
	_hud.add_child(_chat)

	_chat.add_text("Welcome to the server.", Color(0.80, 0.82, 0.86))
	_chat.add_said("gamemann", "anybody up for a round on the atrium map?")
	_chat.add_said(
		"a_very_long_display_name",
		"a line long enough to have to wrap, which is the ordinary case in chat"
	)
	_chat.add_said("quiet_one", "rotating B, need one more", Color(0.55, 0.85, 0.60))
	_chat.open(&"team")


func _process(_delta: float) -> bool:
	if _done:
		return true

	if _menu == null:
		_build()
		return false

	if _at >= _shots.size():
		_done = true
		return false

	var shot: Dictionary = _shots[_at]

	if _wait == SETTLE:
		_menu.close_all()
		_menu.scoreboard.close()
		match StringName(shot["id"]):
			&"menu":
				_menu.open(StringName(shot["page"]))
			&"help":
				_menu.open_help()
			&"board":
				_menu.scoreboard.open()
			&"console":
				# No setting typed: it would be written to the settings file.
				for line in ["help", "where"]:
					var _ran := _presentation.console.submit(line)
				var _opened := _presentation.console.open()

	# A scroll is set on every settling frame: the page lays itself out over the first few,
	# and a scroll set before its content is that tall is clamped to what fits then.
	if shot.has("scroll") and _menu.screen != null:
		for found in _menu.screen.find_children("*", "ScrollContainer", true, false):
			(found as ScrollContainer).scroll_vertical = int(shot["scroll"])

	if _wait > 0:
		_wait -= 1
		return false

	var image := root.get_texture().get_image()
	var path := OUT_DIR.path_join(str(shot["file"]))
	image.save_png(path)
	print("wrote %s (%d x %d)" % [path, image.get_width(), image.get_height()])

	_at += 1
	_wait = SETTLE
	return false
