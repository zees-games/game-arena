extends DotGameCheckSuite

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMaps := preload("../game/arena_maps.gd")
const ArenaModes := preload("../game/arena_modes.gd")
const ArenaMapDirector := preload("../game/arena_map_director.gd")
const ArenaMapConfig := preload("../game/arena_map_config.gd")

## A maps.yml entry's profile (`DotMapDef.profile`, dot-map's `mode:`/`cfg:`): its mode on the map change when the
## map can host it, the server's mode back on the next map, its cvars for that map only, and the rotation filter.
##
## [codeblock]
## godot --headless --path . res://examples/headless_rotation_profile.tscn
## [/codeblock]

const CHECKS := 15


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena: per-map rotation profiles (mode and cvars)")
	var catalogue := ArenaMaps.catalogue()
	var ffa := ArenaModes.by_id(&"ffa")
	var tdm := ArenaModes.by_id(&"tdm")
	var team_map: StringName = &""
	var other_map: StringName = &""
	for id in ArenaMap.ids():
		var def := catalogue.get_map(id)
		if def != null and team_map == &"" and ArenaMaps.supports_mode(def, tdm):
			team_map = id
		elif def != null and other_map == &"" and id != &"dm_pit":
			other_map = id
	if not _check(team_map != &"" and other_map != &"" and not ArenaMaps.supports_mode(catalogue.get_map(&"dm_pit"), tdm),
			"a built-in map hosts tdm, another does not need to and dm_pit cannot", "%s %s" % [team_map, other_map]):
		_report(CHECKS)
		return

	var game := ArenaGame.new()
	game.tick_rate = 64
	game.headless = true
	game.is_authority = true
	game.register_service = false
	game.mode = ffa
	add_child(game)
	var started := game.setup(ArenaMap.by_id(other_map))
	var director := ArenaMapDirector.new()
	director.name = "Maps"
	director.game = game
	director.map_seconds = 0.0
	add_child(director)
	var ready := director.setup()
	if not _check(started.ok and ready.ok, "the game and the map director set up"):
		_report(CHECKS)
		return
	var defs := director.session.catalogue

	# A profile mode the map hosts: the change plays it.
	defs.get_map(team_map).profile = {"value": "tdm", "mode": "tdm", "cfg_path": "", "values": {}}
	var changed: DotResult = await director.change_to(team_map)
	_check(changed.ok and game.map.id == team_map, "the profile map is built", str(changed.error))
	_check(game.mode.id == &"tdm", "in its profile's mode", String(game.mode.id))

	# The next map names none: the server's mode comes back.
	changed = await director.change_to(other_map)
	_check(changed.ok and game.mode.id == &"ffa", "the next map without a profile has the server's mode back", String(game.mode.id))

	# A profile naming a mode the map cannot host: the map still plays, in the current mode.
	defs.get_map(&"dm_pit").profile = {"value": "tdm", "mode": "tdm", "cfg_path": "", "values": {}}
	changed = await director.change_to(&"dm_pit")
	_check(changed.ok and game.map.id == &"dm_pit", "a map whose profile mode it cannot host still plays", str(changed.error))
	_check(game.mode.id == &"ffa", "and the current mode stays", String(game.mode.id))

	# A mode id nothing knows: the same.
	defs.get_map(other_map).profile = {"value": "nosuch", "mode": "nosuch", "cfg_path": "", "values": {}}
	changed = await director.change_to(other_map)
	_check(changed.ok and game.mode.id == &"ffa", "an unknown profile mode keeps the current mode", String(game.mode.id))
	defs.get_map(other_map).profile = {}

	# An operator's mode is not a profile's to undo.
	changed = await director.change_to(team_map)
	director.session.forget_profile_mode()
	var after := director.session.mode_after(defs.get_map(other_map))
	_check(changed.ok and after != null and after.id == &"tdm", "after an operator's mode the next plain map keeps it",
		String(after.id) if after != null else "null")

	# The rotation filter, with a team mode running: dm_pit is kept only for its ffa profile.
	game.change_map(ArenaMap.by_id(team_map), tdm)
	director.session.forget_profile_mode()
	defs.get_map(&"dm_pit").profile = {}
	director.restrict_rotation()
	_check(not director.session.rotation.order.has(&"dm_pit"), "a team mode drops a map with no team spawns from the rotation")
	defs.get_map(&"dm_pit").profile = {"value": "ffa", "mode": "ffa", "cfg_path": "", "values": {}}
	director.restrict_rotation()
	_check(director.session.rotation.order.has(&"dm_pit"), "but keeps it when its profile names a mode it hosts")
	_check(director.session.mode_after(defs.get_map(&"dm_pit")).id == &"ffa", "mode_after answers the profile's mode")

	# The profile's cvars, for one map only.
	var console := DotConsole.new()
	add_child(console)
	console.cvar("arena_profile_a", "1", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("arena_mode", "ffa", "", DotConVar.FLAG_ARCHIVE)
	var applier := ArenaMapConfig.build_profile(console)
	var with := DotMapDef.new()
	with.id = &"p_with"
	with.profile = {"value": "x", "mode": "", "cfg_path": "/x.yml", "values": {"arena_profile_a": 5, "arena_mode": "ctf", "no_such_cvar": 2}}
	var got := ArenaMapConfig.apply_profile(applier, console, with)
	_check(console.find_cvar("arena_profile_a").get_int() == 5 and got.size() == 1, "a profile's cvar is set for its map", str(got))
	_check(console.find_cvar("arena_mode").get_string() == "ffa", "a profile cannot set arena_mode through its cvars")
	var plain := DotMapDef.new()
	plain.id = &"p_plain"
	ArenaMapConfig.apply_profile(applier, console, plain)
	_check(console.find_cvar("arena_profile_a").get_int() == 1, "the next map has the server's value back")

	_report(CHECKS)
