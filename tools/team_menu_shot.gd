extends SceneTree

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaTeamMenu := preload("../game/arena_team_menu.gd")

## Saves screenshots/teams_{two,four,ffa}.png: the team menu over a plain backdrop, fed by the real server half.
## tools/screenshot.sh --team-menu

var _cvars := {}
var _menus: Array = []


func _add(n: String, v: Variant, d: String, f: int) -> DotConVar:
	var cv := DotConVar.new(n, str(v), d, f)
	_cvars[n] = cv
	return cv


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _shot(name: String, mode: ArenaMode, names: String, colours: String, extra: int) -> void:
	_cvars.clear()
	var game := ArenaGame.new()
	game.tick_rate = 64
	game.headless = true
	game.register_service = false
	game.mode = mode
	root.add_child(game)
	var _s := game.setup(ArenaMap.dm_atrium())
	game.start(0)
	for i in extra:
		var _p := game.add_player(60 + i, "Bot%d" % i)
	var _me := game.add_player(51, "Me")
	var menu := ArenaTeamMenu.new()
	menu.bind(game, _add, null)
	_menus.append(menu)
	if names != "":
		(_cvars["mp_team_names"] as DotConVar).force_set(names)
	if colours != "":
		(_cvars["mp_team_colours"] as DotConVar).force_set(colours)
	var back := ColorRect.new()
	back.color = Color(0.1, 0.12, 0.16)
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(back)
	var screen := DotMenuTeamScreen.new()
	root.add_child(screen)
	screen.open((menu.server as Object).call("menu_for", 51))
	for i in 4:
		await process_frame
	root.get_texture().get_image().save_png("res://screenshots/%s.png" % name)
	screen.queue_free()
	back.queue_free()
	game.queue_free()
	await process_frame


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://screenshots"))
	await _shot("teams_two", ArenaMode.team_deathmatch(), "", "", 3)
	var four := ArenaMode.team_deathmatch()
	four.team_count = 4
	await _shot("teams_four", four, "Wolves,Hawks,Bears,Sharks", "#dd3333,#3388dd,#33bb55,#eebb33", 6)
	await _shot("teams_ffa", ArenaMode.free_for_all(), "", "", 3)
	for m in _menus:
		m.release()
	quit(0)
