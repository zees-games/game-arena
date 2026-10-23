extends SceneTree

const ArenaAvatars := preload("../game/arena_avatars.gd")
const ArenaAwards := preload("../game/arena_awards.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaDrops := preload("../game/arena_drops.gd")
const ArenaJailView := preload("../game/arena_jail_view.gd")
const ArenaHud := preload("../game/arena_hud.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMapLighting := preload("../maps/arena_map_lighting.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")

## Renders a map to a PNG so a person can look at it.
##
## [b]A map is a rendered thing and this family has shipped a 0 x 0 Control twice and a
## black screen once.[/b] Every other check on a map is an assertion about a list of
## boxes, and a list of boxes passes just as happily when they are all in the same
## place. This is the only tool here whose output is looked at rather than compared.
##
##   xvfb-run -a godot --path . --script tools/screenshot.gd -- --map dm_atrium
##   tools/screenshot.sh dm_box --admin      # an administrator's beacon and blind
##   tools/screenshot.sh dm_atrium --view keep -30,3,-28 -15,2,-12   # one more frame
##   tools/screenshot.sh dm_box --fx 0,1.7,10 30,1.5,12   # shots from the first point at the second
##   tools/screenshot.sh surf_10x_reloaded_fixed          # an imported map, played for a while
##
## [b]`--admin` puts players in the map and renders what the two screen-shaped mod tools
## look like[/b]: a beaconed player on open floor beside one who is not, the same beacon
## behind a pillar (its column is drawn through walls, which is the half no check can see),
## and a first-person view through the real HUD before and after a blind. The players are
## real `ArenaPlayer`s drawn by their own `present`, and the darkness is the real HUD's.
##
## Needs a real rendering context, so it does NOT run under `--headless`; `xvfb-run` is
## how it runs on a machine with no display. It writes into `screenshots/`, which is
## gitignored — the frame is evidence for a review, not an asset.

const OUT_DIR := "screenshots"

var _shots: Array[Dictionary] = []
var _index := 0
var _camera: Camera3D = null

## `--admin`'s cast: drawn every frame by their own `present`, as a client draws them.
var _players: Array[ArenaPlayer] = []
var _local: ArenaPlayer = null
var _hud: ArenaHud = null


func _initialize() -> void:
	# A scratch settings document, never this machine's real one (see
	# `ArenaPresentation.use_scratch_settings`): a render must not save into a player's file,
	# and must draw from the defaults rather than whatever the last run left there.
	var _scratch := ArenaPresentation.use_scratch_settings("screenshot")
	var args := OS.get_cmdline_user_args()
	var map_index := args.find("--map")
	var id := StringName(args[map_index + 1]) if map_index >= 0 and map_index + 1 < args.size() else &"dm_box"
	var map := ArenaMap.by_id(id)

	if map == null:
		push_error("no such map: %s. Known: %s" % [String(id), ArenaMap.ids()])
		quit(1)
		return

	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	# --no-bake draws a built-in map with its live lights, for before/after frames of a bake.
	ArenaMap.use_bakes = not args.has("--no-bake")
	root.add_child(map.to_scene())
	_stage_packs.call_deferred(map)
	# The map's toys, as a client draws them: frozen where the map puts them. Built in the
	# first frame, because the box builds in the tree and nothing here is in it yet.
	if not map.toys.is_empty():
		_toy_box = DotPropToyBox.new()
		_toy_box.name = "Toys"
		_toy_box.authoritative = false
		root.add_child(_toy_box)
		_toy_placements = map.toys

	# Every map, built-in or imported, is drawn under the lighting the client builds for it
	# (`ArenaMapLighting.build`): a frame lit by this tool's idea of a sun says nothing about
	# the game. Until 2026-10-11 an imported map got a sun and sky of this tool's own, which
	# was neither the client's fixed light then nor the map's own block now.
	root.add_child(ArenaMapLighting.build(map))

	_camera = Camera3D.new()
	_camera.fov = 70.0
	root.add_child(_camera)

	if args.has("--admin"):
		_stage_admin(map, id)
		return

	if args.has("--feel"):
		_stage_feel(map, id)
		return

	var glance_at := args.find("--glance")
	if glance_at >= 0:
		var mode := StringName(args[glance_at + 1]) if glance_at + 1 < args.size() and not args[glance_at + 1].begins_with("--") else &"ffa"
		_glance_game = ArenaGame.new()
		_glance_game.name = "Game"
		_glance_game.headless = true
		_glance_game.is_authority = true
		_glance_game.register_service = false
		_glance_game.mode_id = mode
		root.add_child(_glance_game)
		_staged_map = map
		_staged_id = id
		_glance_ballot = args.has("--ballot") or args.has("--map-ballot")
		_glance_map_ballot = args.has("--map-ballot")
		_glance_chat = args.has("--chat")
		return

	if map.is_imported():
		_stage_imported(map, id)
		return

	var fx_at := args.find("--fx")
	if fx_at >= 0:
		var eye: Variant = _vector(args[fx_at + 1]) if fx_at + 2 < args.size() else null
		var aim_at: Variant = _vector(args[fx_at + 2]) if fx_at + 2 < args.size() else null
		if eye == null or aim_at == null:
			push_error("--fx wants <eye x,y,z> <aim at x,y,z>")
			quit(1)
			return
		_stage_fx(map, id, eye, aim_at)
		return

	var far := map.extent * 1.5

	# Three frames, because one camera angle is one thing you did not get wrong. An
	# overview says whether there is a map; eye level says whether it is a space a
	# person could be inside of.
	_shots = [
		{
			"name": "%s_overview" % String(id),
			"from": Vector3(-far, map.extent * 1.15, -far),
			"at": Vector3.ZERO,
		},
		{
			"name": "%s_eye" % String(id),
			"from": Vector3(-map.extent * 0.72, 1.7, -map.extent * 0.55),
			"at": Vector3(0.0, 3.0, 0.0),
		},
		{
			"name": "%s_roof" % String(id),
			"from": Vector3(map.extent * 0.62, 12.0, map.extent * 0.62),
			"at": Vector3(0.0, 3.0, 0.0),
		},
	]

	# `--view <name> <x,y,z> <x,y,z>`, repeatable: one more frame, from the first point
	# looking at the second. The three above are fixed so two renders of a map are
	# comparable across nights; a new piece of a map is usually somewhere none of them
	# points, and the keep on dm_atrium was a blank wall in the eye frame and a lid in
	# the overview -- neither says whether its doorways read as doorways.
	_append_views(args, id)


## The `--view` frames of [param args], appended to the shots. An imported map takes them too
## (a jail or a pack on it is somewhere none of the fixed frames points).
func _append_views(args: PackedStringArray, id: StringName) -> void:
	var at := 0

	while true:
		at = args.find("--view", at)
		if at < 0 or at + 3 >= args.size():
			break

		var from: Variant = _vector(args[at + 2])
		var target: Variant = _vector(args[at + 3])

		if from == null or target == null:
			push_error("--view wants <name> <x,y,z> <x,y,z>, got %s" % str(args.slice(at, at + 4)))
		else:
			_shots.append({
				"name": "%s_%s" % [String(id), args[at + 1]],
				"from": from,
				"at": target,
			})

		at += 4


## `"x,y,z"` as a Vector3, or null when it is not three numbers.
static func _vector(text: String) -> Variant:
	var parts := text.split(",")

	if parts.size() != 3:
		return null

	for part in parts:
		if not part.strip_edges().is_valid_float():
			return null

	return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))


var _wait := 0
var _armed := false


## [b]Frame-counted rather than awaited.[/b] `SceneTree._process` is expected to return
## a bool synchronously; making it a coroutine returns a signal object instead, which is
## truthy, so the tree quits on the first frame and writes nothing. That is what the
## first version of this file did, and its symptom was a clean exit with an empty
## `screenshots/`.
var _toy_box: DotPropToyBox = null
var _toy_placements: Array = []


func _process(delta: float) -> bool:
	if _toy_box != null and not _toy_placements.is_empty():
		var _built := _toy_box.build(_toy_placements)
		_toy_placements = []
		_wait = maxi(_wait, 2)

	if _imported_game != null and _shots.is_empty():
		_play_imported()
		return false

	if _glance_game != null and _shots.is_empty():
		_play_glance()
		return false

	for body in _players:
		body.present(delta)

	if _index >= _shots.size():
		return true

	if _wait > 0:
		_wait -= 1
		# `late`: [frames before the grab, Callable] pairs, for what must still be on screen
		# when the frame is taken. The HUD animates in real time and a frame here takes
		# about 70 ms, so a hit marker (0.6 s) staged with the shot was gone by the grab.
		var current: Dictionary = _shots[_index]
		if _armed and current.has("late"):
			for stage: Array in current["late"]:
				if _wait == int(stage[0]):
					(stage[1] as Callable).call()
		return false

	if not _armed:
		var shot: Dictionary = _shots[_index]
		if shot.has("arm"):
			(shot["arm"] as Callable).call()
		if shot.get("local", false):
			_local.camera.current = true
		else:
			_camera.current = true
			_camera.position = shot["from"]
			_camera.look_at(shot["at"], Vector3.UP)
		_armed = true
		# Three frames before grabbing. The viewport's texture is the last COMPLETED
		# frame, so grabbing in the same frame the camera moved saves the previous
		# shot under the new shot's name — which looks exactly like a camera that did
		# not move. More for a shot that has something fading in.
		_wait = int(shot.get("wait", 3))
		return false

	var image := root.get_texture().get_image()
	# SHOT_SUFFIX names a run's frames apart (`_compat`, `_1280x960`) so two runs at two
	# sizes or in two renderers can be looked at side by side.
	var suffix := OS.get_environment("SHOT_SUFFIX")
	var path := OUT_DIR.path_join("%s%s.png" % [_shots[_index]["name"], suffix])
	image.save_png(path)
	print("wrote %s (%d x %d)" % [path, image.get_width(), image.get_height()])

	_index += 1
	_armed = false
	return false


# --- --glance: the whole HUD over a real match -------------------------------

## The HUD as a player sees it mid-match, every piece with something in it: a real
## [ArenaGame] (free-for-all, or `--glance tdm`) with eight players and a few kills filed
## through dot-match, so the scores, the clock, the portraits and the kill feed are the
## match's own; the local player's hands, a weapon with a part-spent magazine, abilities
## charging, a slide on, and the kill feedback staged late so it is still up at the grab.
## What `ArenaHud`'s layout is judged by, at 16:9 and 4:3 (`RESOLUTION=1280x960`).
var _glance_game: ArenaGame = null

## `--glance --ballot`: the game vote open over the HUD, as a server running several games
## shows it. See [method _stage_shell_ballot].
var _glance_ballot := false

## `--glance --map-ballot`: the tallest ballot this game puts up, its own map vote (six maps and
## Extend, seven rows), which reaches further down the right edge than the game vote's six.
var _glance_map_ballot := false

## `--glance --chat`: a full chat log (eight rows, a vote line wrapped across two) in the box
## the game builds, scaled with the HUD as [ArenaPresentation] scales it.
var _glance_chat := false

## `--glance --theme <id>`: which of dot-menu's themes the HUD is drawn in; empty is dot-ui's
## default. Names the frame.
var _glance_theme := ""

const GLANCE_NAMES := ["You", "gamemann", "a_very_long_display_name", "bo", "quiet_one", "newcomer", "Rocket", "Viper"]


func _play_glance() -> void:
	var game := _glance_game
	var res := game.setup(_staged_map)
	if not res.ok:
		push_error("the glance game did not set up: %s" % res.error.message)
		quit(1)
		return
	for i in GLANCE_NAMES.size():
		var _added := game.add_player(112 + i, GLANCE_NAMES[i])
	# Live, through the real state machine (headless_match's `_go_live`): in warmup
	# nobody scores, and the strip would say so.
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	game.match_node.rules.min_players = 1
	game.start(game.current_tick())
	var guard := 0
	while not game.match_node.is_live() and guard < 64 * 20:
		game.tick({})
		guard += 1
	for _t in range(64 * 23):
		game.tick({})
	# Kills filed through dot-match, as the game files them: the scores, the ranks and the
	# feed all come from these.
	var kills := [
		[113, 115, &"rifle", false], [112, 114, &"sniper", true], [116, 112, &"shotgun", false],
		[113, 117, &"smg", false], [112, 118, &"rifle", true], [119, 113, &"launcher", false],
		[113, 114, &"marksman", false], [112, 119, &"pistol", false], [117, 116, &"minigun", false],
		[113, 118, &"knife", false], [112, 116, &"rifle", false], [114, 119, &"beamer", true],
	]
	for k in kills:
		var _entry := game.match_node.report_kill(str(k[0]), str(k[1]), k[2], game.current_tick(), bool(k[3]))
	for player in game.players():
		if player.player_id != 112:
			player.attach_body_mesh(Color.from_hsv(fmod(float(player.player_id) * 0.37, 1.0), 0.55, 0.85),
				ArenaAvatars.stock_avatar(StringName(ArenaGame.storage_key(player.player_id))))
			_players.append(player)

	_local = game.player_for(112)
	_local.attach_camera(100.0)
	ZeeModelCache.set_asset_root("res://")
	var hands := ZeeViewModel.new()
	hands.name = "Hands"
	_local.camera.add_child(hands)
	_local.arm_first_person(hands, true)
	var _given := _local.weapons.give_everything()
	var ask := DotWeaponCommand.new()
	ask.slot = ZeeWeaponIds.SLOT_PRIMARY
	for tick in range(game.current_tick() + 1, game.current_tick() + 60):
		var _o := _local.simulate_tick(tick, 1.0 / 64.0, DotFpsCommand.new(), ask)
		ask = DotWeaponCommand.new()
	_players.append(_local)

	_hud = ArenaHud.new()
	_hud.name = "Hud"
	_hud.config = DotUiConfig.new()
	_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(_hud)
	_hud.build(game)
	_hud.follow(_local)
	var _caught := _hud.catch_up()
	# `--theme <id>`: the HUD in one of dot-menu's themes, as the menu sets it
	# (`DotMenu.follow_hud`); without it, dot-ui's default, which is the dark HUD.
	# `--hud-scale <k>`: at the player's HUD size.
	var args := OS.get_cmdline_user_args()
	var theme_at := args.find("--theme")
	if theme_at >= 0 and theme_at + 1 < args.size():
		_glance_theme = args[theme_at + 1]
		_hud.theme = DotMenuThemes.stock().named(StringName(_glance_theme)).hud_theme(ArenaHud.accent_theme())
	var scale_at := args.find("--hud-scale")
	if scale_at >= 0 and scale_at + 1 < args.size():
		_hud.user_scale = float(args[scale_at + 1])

	var slot := _local.arsenal.current()
	if slot != null and slot.def.magazine > 0:
		slot.magazine = maxi(1, slot.def.magazine / 3)
	_local.health.health = _local.health.max_health * 0.64
	_local.health.armour = 35.0
	_local.controller.state.launch_cooldown_left = 4.2
	_local.controller.state.dash_cooldown_left = 1.3
	_local.controller.state.slide_time = 0.3
	_local.controller.state.wall_jumps_in_air = 1

	var late: Array = []
	if _glance_chat:
		_stage_full_chat()
	if _glance_ballot:
		_stage_shell_ballot()
		# What the server says in chat as the ballot opens, which this client centre-prints
		# (`ArenaClient._on_said`, a system line). Staged late: the notice fades in 4 s.
		# dot-vote's opening line for this game's own map vote, the same shape.
		var said := "Vote: Box, Atrium, Pit, Foundry, Canals, Spire (20s)" if _glance_map_ballot \
			else "Vote: Smash Copter, Hide & Seek, Dangerous Delivery, Playground, g2gfast (20s)"
		late.append([10, func() -> void: _hud.notice(said)])

	_shots = [{
		"name": "%s_glance_%s%s" % [String(_staged_id), String(game.mode_id), ("_mapballot" if _glance_map_ballot else "_ballot") if _glance_ballot else ""] + ("_chat" if _glance_chat else "") + ("_" + _glance_theme if _glance_theme != "" else ""),
		"local": true,
		"late": [
			[12, func() -> void:
				var medals := [ArenaAwards.Medal.HEADSHOT, ArenaAwards.Medal.DOUBLE_KILL]
				_hud.note_award(
					{"killer_id": 112, "victim_id": 118, "medals": medals,
						"points": ArenaAwards.points_for(medals), "streak": 3},
					112, "newcomer", "You"
				)],
			[4, func() -> void:
				var target := game.player_for(117)
				if target != null:
					_hud.note_hit(117, 34.0, target.global_position + Vector3(0.0, 1.5, 0.0), false, false)],
		] + late,
		"wait": 34,
	}]


## A stand-in for the client shell's notice overlay with the game vote open: its drawn
## ballot, placed where dot-server-deploy's `client/notice_overlay.gd` places it (a copy,
## since that project is not an addon this game links; keep the two in step). The shell
## draws one column down the right-hand side, 110 px down and a third of the frame wide
## (240..360 px), and does not draw the vote's HUD line while its ballot is open. The shell
## draws over every game, so whether it covers this HUD is a question only a frame of both
## together answers.
func _stage_full_chat() -> void:
	var layer := CanvasLayer.new()
	layer.name = "ChatLayer"
	layer.layer = 100
	root.add_child(layer)
	var screen := Control.new()
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(screen)
	var window := ArenaPresentation.make_chat_window()
	screen.add_child(window)
	ArenaPresentation.fit_chat_screen(screen, root.get_visible_rect().size)
	window.add_text("Vote: Smash Copter, Hide & Seek, Dangerous Delivery, Playground, g2gfast (20s)", Color(0.80, 0.82, 0.86))
	for i in range(6):
		window.add_said("Player %d" % (i + 1), "line %d of a full log" % (i + 1), Color(0.62, 0.78, 1.0))


func _stage_shell_ballot() -> void:
	var layer := CanvasLayer.new()
	layer.name = "ShellStandIn"
	layer.layer = 20
	root.add_child(layer)
	# Below 1280x720 the shell draws on a 1280x720 canvas stretched to the window, its
	# ballot and the game's HUD alike, so the stand-in is scaled by the HUD's own factor
	# (`ArenaHud.fit_scale`): a full-size ballot over a scaled HUD is a frame the shell
	# never draws. 1 from 1280x720 up, where nothing changes.
	var fit := ArenaHud.fit_scale(Vector2(root.size))
	var canvas := Vector2(root.size) / fit
	var overlay := Control.new()
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.theme = DotUiTheme.space().build()
	layer.add_child(overlay)
	overlay.scale = Vector2(fit, fit)
	overlay.size = canvas

	var width := clampf(canvas.x * 0.34, 240.0, 360.0)
	var column := VBoxContainer.new()
	column.anchor_left = 1.0
	column.anchor_right = 1.0
	column.anchor_bottom = 1.0
	column.offset_left = -16.0 - width
	column.offset_right = -16.0
	column.offset_top = 110.0
	column.offset_bottom = -16.0
	overlay.add_child(column)
	var ballot := DotBallotPanel.new()
	ballot.ui_theme = DotUiTheme.space()
	ballot.panel_width = width
	column.add_child(ballot)
	if _glance_map_ballot:
		var maps: Array = []
		for label: String in ["Box", "Atrium", "Pit", "Foundry", "Canals", "Spire", "Extend"]:
			maps.append({"id": label.to_lower(), "label": label, "votes": 0.0})
		ballot.show_state({
			"open": true, "title": "Vote for the next map", "command": "vote",
			"seconds": 19.0, "input": "both", "options": maps, "voters": {}, "people": {},
		})
		return
	ballot.show_state({
		"open": true, "title": "Vote for the next game", "command": "game_vote",
		"seconds": 19.0, "input": "both",
		"options": [
			{"id": "smash", "label": "Smash Copter", "votes": 0.0},
			{"id": "hideseek", "label": "Hide & Seek", "votes": 0.0},
			{"id": "delivery", "label": "Dangerous Delivery", "votes": 0.0},
			{"id": "playground", "label": "Playground", "votes": 0.0},
			{"id": "g2gfast", "label": "g2gfast", "votes": 0.0},
			{"id": "keep", "label": "Don't change", "votes": 0.0},
		],
		"voters": {}, "people": {},
	})


# --- An imported map --------------------------------------------------------

## An imported combat surf map, with a deathmatch played on it for a few seconds first.
##
## [b]Played rather than posed, because what can be wrong is where people END UP[/b]: a
## spawn inside a brush, a floor nobody lands on, a map at the wrong scale under a 1.8 m
## player, textures that never loaded, a lightmap drawn black. So a real [ArenaGame] —
## authority, the map's solid in the tree, bots shooting at each other — runs
## [constant IMPORTED_TICKS] ticks, and the frames are taken of where its players are:
## behind one at head height looking at the others, one player's own eye, the spawn area
## from above, and the map's biggest surf ramp from beside it.
const IMPORTED_TICKS := 160
var _imported_game: ArenaGame = null


## The map's health and ammo packs, drawn the way a client draws the ones the server announces:
## through the drops layer's own `mirror_drop`.
func _stage_packs(map: ArenaMap) -> void:
	if map.packs.is_empty():
		return
	var layer := ArenaDrops.new()
	layer.name = "Packs"
	layer.is_authority = false
	layer.draws = true
	root.add_child(layer)
	for index in range(map.packs.size()):
		var pack: Dictionary = map.packs[index]
		layer.mirror_drop(ArenaDrops.PACK_ID_BASE + index, int(pack["kind"]), pack["at"], pack["at"], 0)


func _stage_imported(map: ArenaMap, id: StringName) -> void:
	_imported_game = ArenaGame.new()
	_imported_game.name = "Game"
	_imported_game.headless = true
	_imported_game.is_authority = true
	_imported_game.register_service = false
	root.add_child(_imported_game)
	_staged_map = map
	_staged_id = id


var _staged_map: ArenaMap = null
var _overview_box := AABB()
var _overview_reach := 1.0


## What the overview frames: the map's bounds, but for an imported map only what is drawn. The
## manifest's bounds take in the 3D skybox (the backdrop of a map built to float in one, scaled
## far outside the play space, and never drawn here), which put surf_snipers_island's whole island
## in a corner of an empty frame.
func _frame_overview() -> void:
	_overview_box = _staged_map.bounds
	_overview_reach = _staged_map.extent

	# A map with no 3D skybox writes `"skybox": null`, which does not cast to a Dictionary.
	var sky: Variant = ArenaMap.ArenaImportedMaps.manifest(_staged_map.id).get("skybox", null) if _staged_map.is_imported() else null
	if not (sky is Dictionary) or not bool((sky as Dictionary).get("drawn", false)):
		return

	var drawn := _staged_map.to_scene()
	var box := AABB()
	var first := true

	for child in drawn.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).mesh != null:
			var part: AABB = (child as MeshInstance3D).transform * (child as MeshInstance3D).mesh.get_aabb()
			box = part if first else box.merge(part)
			first = false

	drawn.free()

	if not first:
		_overview_box = box
		_overview_reach = maxf(box.size.x, box.size.z) * 0.5
var _staged_id: StringName = &""


## Run on the first frame, once the game is in the tree (its children ready there).
func _play_imported() -> void:
	var game := _imported_game
	var res := game.setup(_staged_map)

	if not res.ok:
		push_error("the imported map did not set up: %s" % res.error.message)
		quit(1)
		return

	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0

	# The jail's gate and button, as a client draws them (the game here is headless, which
	# draws none of its own presentation).
	if _staged_map.jail != null:
		var jail_view := ArenaJailView.new()
		root.add_child(jail_view)
		jail_view.build(_staged_map.jail, func() -> int: return 0)

	for i in range(5):
		var _added := game.add_player(201 + i, "Bot %d" % (i + 1))

	game.start(0)

	for tick in range(IMPORTED_TICKS):
		var commands := {}

		for player in game.players():
			var move := DotFpsCommand.new()
			# Each bot walks its own way, turning slowly, so they spread out of the
			# spawn room the way players do, without a fight ending it in a second.
			move.yaw = fmod(float(player.player_id) * 77.0 + float(tick) * 0.6, 360.0)
			# Three stand where they spawned and two walk off into the map, so the
			# frames have both somebody on a spawn's floor and somebody on a ramp.
			move.move = Vector2(0.0, 1.0) if tick > 40 and player.player_id > 203 else Vector2.ZERO
			move.sanitise()
			commands[player.player_id] = [move, DotWeaponCommand.new()]

		game.tick(commands)

	var mechanics_shots := _stage_mechanics(game)
	var players := game.players()

	for player in players:
		player.attach_body_mesh(
			Color.from_hsv(fmod(float(player.player_id) * 0.37, 1.0), 0.55, 0.85),
			ArenaAvatars.stock_avatar(StringName(ArenaGame.storage_key(player.player_id)))
		)
		_players.append(player)
		print("  %s at %s, %s" % [
			player.display_name, player.controller.state.position,
			"standing" if player.controller.state.is_grounded() else "in the air"
		])

	# Over the shoulder of somebody STANDING, at whoever is nearest them: a frame whose
	# subject is in mid-air on a ramp says nothing about the floor.
	var first: ArenaPlayer = players[0]

	for player in players:
		if player.controller.state.is_grounded():
			first = player
			break

	_frame_overview()
	var feet := first.controller.state.position
	var facing := Basis(Vector3.UP, deg_to_rad(first.controller.state.yaw)) * Vector3.FORWARD
	var centre := Vector3.ZERO
	var nearest := INF

	for player in players:
		var d := player.controller.state.position.distance_to(feet)

		if player != first and player.controller.state.is_grounded() and d < nearest:
			nearest = d
			centre = player.controller.state.position

	if nearest == INF:
		centre = feet + facing * 6.0
	else:
		facing = Vector3(centre.x - feet.x, 0.0, centre.z - feet.z).normalized()

	# Below the horizon is sky too: these maps float in their skybox, and the procedural
	# sky's brown "ground" reads as a floor a long way down that is not there.
	for node in root.get_children():
		if node is WorldEnvironment:
			var material := (node as WorldEnvironment).environment.sky.sky_material as ProceduralSkyMaterial
			material.ground_bottom_color = material.sky_horizon_color
			material.ground_horizon_color = material.sky_horizon_color

	_shots = [
		{
			# Behind the first player, over their shoulder, at the others.
			"name": "%s_players" % String(_staged_id),
			"from": feet - facing * 3.0 + Vector3.UP * 2.2,
			"at": centre + Vector3.UP * 0.9,
		},
		{
			# Their own body hidden, as a first-person view draws it: a camera at the eye of
			# a body that is drawn has that body's arm across the frame.
			"name": "%s_eye" % String(_staged_id),
			"from": feet + Vector3.UP * 1.6,
			"at": feet + Vector3.UP * 1.6 + facing * 10.0,
			"arm": func() -> void:
				if first.body_mesh != null:
					first.body_mesh.visible = false,
		},
		{
			"name": "%s_spawns" % String(_staged_id),
			"arm": func() -> void:
				if first.body_mesh != null:
					first.body_mesh.visible = true,
			"from": feet + Vector3(-14.0, 18.0, -14.0),
			"at": feet,
		},
		{
			"name": "%s_overview" % String(_staged_id),
			"from": _overview_box.get_center() + Vector3(-1.0, 0.6, -1.0) * _overview_reach,
			"at": _overview_box.get_center(),
		},
	]

	_shots.append_array(mechanics_shots)
	_append_views(OS.get_cmdline_user_args(), _staged_id)
	var ramp := _biggest_ramp(_staged_map)

	if not ramp.is_empty():
		var normal: Vector3 = ramp["normal"]
		var across := normal.cross(Vector3.UP).normalized()
		_shots.append({
			"name": "%s_ramp" % String(_staged_id),
			"from": (ramp["centre"] as Vector3) + normal * 6.0 + across * 10.0 + Vector3.UP * 3.0,
			"at": ramp["centre"],
		})

	_camera.far = 2000.0


## Two of the walking bots handed to the map's own mechanics, and a frame of each: one put
## in its deepest pool to the chest and left to sink (`<id>_water`), one put on its
## strongest floor booster and ticked until it has been thrown off the end
## (`<id>_booster`). A map with neither gets neither frame. The players are moved by the
## game's own tick, so what is drawn is where the mechanics put them.
func _stage_mechanics(game: ArenaGame) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var mech := _staged_map.mechanics
	var swimmer := game.player_for(205)
	var rider := game.player_for(204)

	if mech == null or swimmer == null or rider == null:
		return out

	var probe := DotFpsPhysicsBody.for_node(_staged_map.collision_root)
	var tunables := swimmer.controller.tunables
	var depth := swimmer.swim.waist + 0.3
	var pool := AABB()
	var in_water := Vector3.ZERO

	for w in mech.water:
		if w.size.x < 3.0 or w.size.z < 3.0 or w.size.y < 1.5 or w.size.y <= pool.size.y:
			continue
		for i in range(1, 8):
			for j in range(1, 8):
				var at := Vector3(w.position.x + w.size.x * i / 8.0, w.end.y - depth,
					w.position.z + w.size.z * j / 8.0)
				var height := tunables.stand_height - 0.2
				if not probe.overlaps(at + Vector3.UP * (0.1 + height * 0.5), height, tunables.radius - 0.05):
					pool = w
					in_water = at
					break
			if pool == w:
				break

	var booster := {}
	for p: Dictionary in mech.pushes:
		var push: Vector3 = p["push"]
		if not p["once"] and (p["box"] as AABB).size.y < 0.5 and Vector2(push.x, push.z).length() \
				> Vector2(booster.get("push", Vector3.ZERO).x, booster.get("push", Vector3.ZERO).z).length():
			booster = p

	if pool.size != Vector3.ZERO:
		swimmer.controller.teleport(in_water, 0.0, 0.0)
	if not booster.is_empty():
		var pad: AABB = booster["box"]
		rider.controller.teleport(Vector3(pad.get_center().x, pad.end.y + 0.02, pad.get_center().z), 0.0, 0.0)

	# Long enough for the rider to be carried off the end of a booster most of a
	# hundred metres long, and the swimmer to sink a little.
	var start := rider.controller.state.position
	for _i in range(18):
		var idle := {}
		for player in game.players():
			idle[player.player_id] = [DotFpsCommand.new(), DotWeaponCommand.new()]
		game.tick(idle)

	if pool.size != Vector3.ZERO:
		var at := swimmer.controller.state.position
		print("  swimmer at %s, mode %s, %.2f m under the surface" % [
			at, swimmer.controller.motor.mode_name(swimmer.controller.state.mode), pool.end.y - at.y])
		out.append({
			"name": "%s_water" % String(_staged_id),
			"from": Vector3(at.x, pool.end.y + 1.2, at.z) + Vector3(3.0, 0.0, 3.0),
			"at": at + Vector3.UP * 0.9,
		})

	if not booster.is_empty():
		var at := rider.controller.state.position
		var push: Vector3 = booster["push"]
		var along := Vector3(push.x, 0.0, push.z).normalized()
		print("  booster rider carried %.1f m to %s, %.1f m/s" % [
			start.distance_to(at), at, rider.controller.state.horizontal_speed()])
		out.append({
			"name": "%s_booster" % String(_staged_id),
			"from": at - along * 7.0 + along.cross(Vector3.UP) * 3.0 + Vector3.UP * 2.5,
			"at": at + Vector3.UP * 0.9,
		})

	return out


## The biggest triangle the map draws as a surf ramp, `{centre, normal}`.
static func _biggest_ramp(map: ArenaMap) -> Dictionary:
	var manifest: Dictionary = ArenaMap.ArenaImportedMaps.manifest(map.id)
	var dir := map.manifest_path.get_base_dir()
	var blob := FileAccess.get_file_as_bytes(dir.path_join("%s.bin" % String(map.id)))
	var stride := ArenaMap.ArenaBspMap.VERTEX_FLOATS
	var scale := ArenaMap.ArenaBspMap.METRES_PER_UNIT
	var best := {}
	var best_area := 0.0

	for entry: Variant in manifest.get("surfaces", []):
		var surface: Dictionary = entry

		if str(surface.get("role", "")) != "RAMP":
			continue

		var vcount := int(surface["vertex_count"])
		var icount := int(surface["index_count"])
		var floats := blob.slice(int(surface["vertex_offset"]),
			int(surface["vertex_offset"]) + vcount * stride * 4).to_float32_array()
		var indices := blob.slice(int(surface["index_offset"]),
			int(surface["index_offset"]) + icount * 4).to_int32_array()

		for t in range(0, icount - 2, 3):
			var p: Array[Vector3] = []

			for k in range(3):
				var o := int(indices[t + k]) * stride
				p.append(Vector3(floats[o], floats[o + 1], floats[o + 2]) * scale)

			var cross := (p[1] - p[0]).cross(p[2] - p[0])

			if cross.length() * 0.5 > best_area:
				best_area = cross.length() * 0.5
				var normal := cross.normalized()
				best = {"centre": (p[0] + p[1] + p[2]) / 3.0, "normal": normal if normal.y >= 0.0 else -normal}

	return best


# --- --admin ----------------------------------------------------------------

## Players in the map, and the frames that show an administrator's beacon and blind.
##
## Written against `dm_box`'s layout — open floor at the south end, a five-metre pillar
## at (-12, -4) — and still renders on another map, where the pillar frame may simply not
## have a pillar in it.
func _stage_admin(map: ArenaMap, id: StringName) -> void:
	# Beaconed, on open floor, with a player who is not beside them for contrast.
	var marked := _cast(map, 101, "Marked", Vector3(1.0, 0.05, 11.0), 200.0)
	var plain := _cast(map, 102, "Plain", Vector3(4.2, 0.05, 12.5), 160.0)
	marked.beacon = true
	# Behind the pillar from where the second frame stands.
	var hidden := _cast(map, 103, "Hidden", Vector3(-12.0, 0.05, -9.0), 0.0)
	hidden.beacon = true

	# Whose eyes the last two frames are behind, looking north at the other two.
	_local = ArenaPlayer.new()
	_local.name = "Local"
	_local.setup(ArenaPlayer.Mode.HEADLESS, map, 104, "You")
	root.add_child(_local)
	_local.spawn(Transform3D(Basis(), Vector3(-1.0, 0.05, 20.0)), 0)
	_local.attach_camera(100.0)
	_local.camera.current = false
	_players.append(_local)

	_hud = ArenaHud.new()
	_hud.name = "Hud"
	_hud.config = DotUiConfig.new()
	_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(_hud)
	_hud.build(null)
	_hud.follow(_local)
	_hud.visible = false

	var _unused := plain

	_shots = [
		{
			"name": "%s_beacon" % String(id),
			"from": Vector3(-4.5, 3.4, 18.5),
			"at": Vector3(2.0, 0.6, 11.5),
		},
		{
			# Eye level, the pillar between the camera and the player: the body is hidden
			# and the column is not, which is the reason it is drawn through walls.
			"name": "%s_beacon_wall" % String(id),
			"from": Vector3(-11.0, 1.7, 9.0),
			"at": Vector3(-12.0, 4.0, -9.0),
		},
		{
			"name": "%s_eye_hud" % String(id),
			"local": true,
			"arm": func() -> void: _hud.visible = true,
		},
		{
			"name": "%s_blind" % String(id),
			"local": true,
			"arm": func() -> void: _local.blinded = true,
			# The HUD fades a blind in over a quarter of a second; software rendering is
			# slow enough that three frames can be less than that.
			"wait": 12,
		},
	]


# --- --feel -----------------------------------------------------------------

## What the arena's 2026-10-06 additions look like, which no suite can say: the sniper's
## scope, the HUD (hurt, the launch counting down, the slide prompt), a body exploding on a
## lethal critical, and your own body when you look down.
var _feel_tick: int = 1


func _stage_feel(map: ArenaMap, id: StringName) -> void:
	var victim := _cast(map, 111, "Victim", Vector3(1.0, 0.05, 12.0), 180.0)
	var hurt := _cast(map, 113, "Hurt", Vector3(4.0, 0.05, 13.0), 200.0)

	_local = ArenaPlayer.new()
	_local.name = "Local"
	_local.setup(ArenaPlayer.Mode.HEADLESS, map, 112, "You")
	root.add_child(_local)
	_local.spawn(Transform3D(Basis(), Vector3(-1.0, 0.05, 20.0)), 0)
	_local.attach_camera(100.0)
	_local.camera.current = false
	# Where the arena's vendored weapon art is; the client says so at boot, and without it
	# the hands are drawn holding nothing.
	ZeeModelCache.set_asset_root("res://")
	_players.append(_local)

	# The hands are armed on the first frame, not here: this runs in the script's _init,
	# before anything is in the tree, so the rig's `get_path()` of the hands failed ("Cannot
	# get path of node") and every frame showed empty hands.
	var arm_hands := func() -> void:
		if _local.get_node_or_null(^"Camera/Hands") != null or _local.weapons == null:
			pass
		var hands := ZeeViewModel.new()
		hands.name = "Hands"
		_local.camera.add_child(hands)
		_local.arm_first_person(hands, true)
		var _given := _local.weapons.give_everything()

	_hud = ArenaHud.new()
	_hud.name = "Hud"
	_hud.config = DotUiConfig.new()
	_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(_hud)
	_hud.build(null)
	_hud.follow(_local)
	_hud.visible = false

	var hold := func(slot: int) -> void:
		# Asked for through the command, as the client does, and ticked the way the game
		# ticks a player: the rig equips the view model on a tick and nothing else here
		# ticks it.
		var ask := DotWeaponCommand.new()
		ask.slot = slot
		for tick in range(_feel_tick, _feel_tick + 80):
			var _o := _local.simulate_tick(tick, 1.0 / 64.0, DotFpsCommand.new(), ask)
			ask = DotWeaponCommand.new()
		_feel_tick += 80

	_shots = [
		{
			# The sniper at the hip: its view model against the vendored art.
			"name": "%s_feel_sniper_hip" % String(id),
			"local": true,
			"arm": func() -> void:
				arm_hands.call()
				var _g := _local.arsenal.give(ZeeWeaponIds.SNIPER)
				hold.call(ZeeWeaponIds.SLOT_HEAVY),
			"wait": 30,
		},
		{
			"name": "%s_feel_scope" % String(id),
			"local": true,
			"arm": func() -> void:
				arm_hands.call()
				# The sniper itself: give_everything leaves the heavy slot holding the last
				# heavy it gave, which is not the sniper.
				var _g := _local.arsenal.give(ZeeWeaponIds.SNIPER)
				hold.call(ZeeWeaponIds.SLOT_HEAVY)
				_local.aim_held = true
				_hud.visible = true,
			"wait": 30,
		},
		{
			"name": "%s_feel_hud" % String(id),
			"local": true,
			"arm": func() -> void:
				_local.aim_held = false
				hold.call(ZeeWeaponIds.SLOT_PRIMARY)
				_local.health.health = _local.health.max_health * 0.12
				_local.controller.state.launch_cooldown_left = 5.5
				_local.controller.state.slide_time = 0.3
				for v in [201, 202, 203]:
					_hud.note_kill({"killer_id": 112, "victim_id": v, "headshot": v == 203, "weapon": "rifle"}, 112, "You")
				_hud.notice("Victim is on a 3 kill streak: heal")
				_local.challenge = 1
				_local.challenge_value = 11,
			"wait": 30,
		},
		{
			# Kill feedback: medals from the server's AWARD, "+points  Victim", the streak
			# meter, and, staged late so they are still up, the hit marker and the numbers.
			"name": "%s_feel_kill" % String(id),
			"local": true,
			"arm": func() -> void:
				_local.health.health = _local.health.max_health
				_local.controller.state.launch_cooldown_left = 0.0
				_local.controller.state.slide_time = -1.0
				_hud.notice("")
				_local.challenge = -1,
			"late": [
				[12, func() -> void:
					var medals := [ArenaAwards.Medal.FIRST_BLOOD, ArenaAwards.Medal.HEADSHOT, ArenaAwards.Medal.DOUBLE_KILL]
					_hud.note_kill({"killer_id": 112, "victim_id": 111, "headshot": true, "weapon": "rifle"}, 112, "You")
					_hud.note_award(
						{"killer_id": 112, "victim_id": 111, "medals": medals,
							"points": ArenaAwards.points_for(medals), "streak": 4},
						112, "Victim", "You"
					)],
				[4, func() -> void:
					_hud.note_hit(113, 47.0, hurt.global_position + Vector3(0.0, 1.5, 0.0), false, false)
					_hud.note_hit(111, 100.0, victim.global_position + Vector3(0.0, 1.7, 0.0), true, true)],
			],
			"wait": 34,
		},
		{
			"name": "%s_feel_break" % String(id),
			# From the east: the west side of this floor is the stair block, which hid
			# all but a flying head in the first two renders.
			"from": Vector3(6.5, 2.6, 16.5),
			"at": Vector3(1.0, 0.9, 12.0),
			"arm": func() -> void:
				_hud.visible = false
				var rules := DotPlayerBreakRules.new()
				rules.mode = DotPlayerBreakRules.Mode.EXPLODE
				rules.criticals_only = false
				# Slowed, so the frame is mid-burst rather than after it.
				rules.force = 2.5
				rules.lift = 2.0
				victim.make_dead()
				var _b := victim.break_body(rules, Vector3(0.0, 0.0, -1.0), 7, true),
			"wait": 8,
		},
		{
			"name": "%s_feel_health" % String(id),
			"from": Vector3(4.0, 2.4, 18.5),
			"at": Vector3(4.0, 1.6, 13.0),
			"arm": func() -> void:
				hurt.health.health = 40.0,
			"wait": 6,
		},
		{
			"name": "%s_feel_drops" % String(id),
			"from": Vector3(3.5, 2.4, 19.0),
			"at": Vector3(0.0, 0.3, 14.5),
			"arm": func() -> void:
				var drops := ArenaDrops.new()
				drops.is_authority = false
				drops.draws = true
				root.add_child(drops)
				var from := Vector3(0.0, 0.05, 14.5)
				for i in range(5):
					var a := TAU * float(i) / 5.0
					drops.mirror_drop(i + 1, ArenaDrops.Kind.COIN, from + Vector3(cos(a) * 1.6, 0.0, sin(a) * 1.6), from, 1)
				drops.mirror_drop(9, ArenaDrops.Kind.HEALTH, from + Vector3(0.0, 0.0, 0.3), from, 25),
			"wait": 40,
		},
		{
			"name": "%s_feel_body" % String(id),
			"local": true,
			"arm": func() -> void:
				_local.controller.state.slide_time = -1.0
				# Through teleport, which sets the drawn state too: the camera draws from the
				# controller's interpolated render state, and a pitch written into `state`
				# alone never reached it (the first two body frames looked at the horizon).
				_local.controller.teleport(_local.controller.state.position, _local.controller.state.yaw, -62.0)
				# And the sampler, which owns a local player's look and writes it every tick.
				if _local.get("sampler") != null:
					_local.sampler.look_at_angles(_local.controller.state.yaw, -62.0)
				_local.health.health = _local.health.max_health
				# A real avatar: a player with none is drawn as a capsule, which has no legs to keep.
				_local.avatar = load("res://game/arena_avatars.gd").stock_avatar(&"you")
				# Current first: present_own_body draws nothing for a camera nobody looks through.
				_local.camera.current = true
				_local.present_own_body(true, _local.controller.state.yaw)
				_hud.visible = true,
			"wait": 12,
		},
	]


# --- --fx -------------------------------------------------------------------

## A burst of rifle shots at a wall, drawn by the real presentation layer the way a client
## draws its own: [method ArenaPresentation.on_used] with a [DotWeaponOutcome] whose
## impacts are where the map's own trace says each shot stopped.
##
## [b]The particles are slowed to a twentieth of real speed and restarted once spawned.[/b]
## A muzzle flash lives 80 ms and a software renderer under xvfb takes longer than that per
## frame, so at full speed the frame this saves is the one after it went out. The holes are
## decals and are not affected.
func _stage_fx(map: ArenaMap, id: StringName, eye: Vector3, aim_at: Vector3) -> void:
	var presentation := ArenaPresentation.new()
	presentation.name = "Presentation"
	root.add_child(presentation)
	var built := presentation.setup()
	if not built.ok:
		push_error("the presentation layer: %s" % built.error.message)

	var trace := map.to_trace()
	var aim := (aim_at - eye).normalized()
	var side := aim.cross(Vector3.UP).normalized()
	var refused := {}
	presentation.fx.spawned.connect(func(fx_id: StringName, node: Node, why: StringName) -> void:
		if node == null:
			refused["%s: %s" % [fx_id, why]] = true
	)
	var fire := func() -> void:
		# A small group, the last one freshest: holes from the earlier shots, the spark
		# and the flash from the last. One shot per frame's budget, as a client fires one
		# a tick: six in one frame is over dot-fx's budget and the last are refused.
		for i in range(6):
			presentation.present(0.016, eye, aim)
			var angle := float(i) * 1.1
			var spread := side * sin(angle) * 0.012 * i + Vector3.UP * cos(angle) * 0.012 * i
			var dir := (aim + spread).normalized()
			var hit := trace.ray(eye, dir, 500.0)
			var shot := DotShot.new()
			shot.weapon_id = &"rifle"
			shot.origin = eye
			shot.direction = dir
			if hit.ok():
				shot.impacts = [hit.point]
				if i == 0:
					print("fx: the first shot stopped at %s, %.1f m away" % [hit.point, hit.distance])
			var outcome := DotWeaponOutcome.new()
			outcome.used = true
			outcome.add_shot(shot)
			presentation.on_used(outcome)
		for particles in presentation.fx.find_children("*", "CPUParticles3D", true, false):
			(particles as CPUParticles3D).speed_scale = 0.05
			# And started again at the slowed speed. A one-shot's first update ages it by
			# the whole frame's delta, and a software frame is longer than a flash lives,
			# so without this the flash has already finished when the slowing lands.
			(particles as CPUParticles3D).restart()
		if not refused.is_empty():
			print("fx: refused %s" % ", ".join(PackedStringArray(refused.keys())))
			refused.clear()

	var hit0 := trace.ray(eye, aim, 500.0)
	var wall := hit0.point if hit0.ok() else aim_at

	_shots = [
		{
			# Through the shooter's own eye: the flash low and right, the spark on the wall.
			"name": "%s_fx_eye" % String(id),
			"from": eye,
			"at": eye + aim,
			"arm": fire,
			"wait": 4,
		},
		{
			# Beside the wall, looking at the holes, re-fired so the spark is fresh again.
			"name": "%s_fx_wall" % String(id),
			"from": wall - aim * 2.2 + side * 1.2 + Vector3.UP * 0.3,
			"at": wall,
			"arm": fire,
			"wait": 4,
		},
		{
			# A death two metres short of the wall, seen from where the shots came from.
			"name": "%s_fx_death" % String(id),
			"from": eye + side * 1.5,
			"at": wall - aim * 2.0 + Vector3.UP * 0.5,
			"arm": func() -> void:
				var where := Transform3D(Basis.IDENTITY, Vector3(wall.x, map.floor_y, wall.z) - aim * 2.0)
				presentation.present(0.016, eye, aim)
				presentation.on_died(where)
				# The burst's two emitters (blood drops and a mist; it was one of red cubes).
				for particles in presentation.fx.find_children("*", "CPUParticles3D", true, false):
					if not (particles.name in [&"Drops", &"Mist"]):
						continue
					(particles as CPUParticles3D).speed_scale = 0.2
					(particles as CPUParticles3D).restart(),
			"wait": 4,
		},
		{
			# The same death from four metres, where a player who was nearby sees it: what the
			# burst looks like, not where it is.
			"name": "%s_fx_death_near" % String(id),
			"from": wall - aim * 6.0 + side * 1.5 + Vector3.UP * 0.4,
			"at": wall - aim * 2.0 + Vector3.UP * 1.0,
			"arm": func() -> void:
				var where := Transform3D(Basis.IDENTITY, Vector3(wall.x, map.floor_y, wall.z) - aim * 2.0)
				presentation.on_died(where)
				for particles in presentation.fx.find_children("*", "CPUParticles3D", true, false):
					if particles.name in [&"Drops", &"Mist"]:
						(particles as CPUParticles3D).speed_scale = 0.2
						(particles as CPUParticles3D).restart(),
			"wait": 6,
		},
	]


func _cast(map: ArenaMap, pid: int, name_text: String, at: Vector3, yaw: float) -> ArenaPlayer:
	var body := ArenaPlayer.new()
	body.name = name_text
	body.setup(ArenaPlayer.Mode.HEADLESS, map, pid, name_text)
	root.add_child(body)
	body.spawn(Transform3D(Basis(Vector3.UP, deg_to_rad(yaw)), at), 0)
	body.attach_body_mesh(
		Color.from_hsv(fmod(float(pid) * 0.37, 1.0), 0.55, 0.85),
		ArenaAvatars.stock_avatar(StringName(ArenaGame.storage_key(pid)))
	)
	_players.append(body)
	return body
