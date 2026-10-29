extends SceneTree

## Renders the loadout screen over three saved loadouts, saved through the arena's own store.
##
##   xvfb-run -a godot --path . --resolution 1600x900 --script tools/loadout_shot.gd

const ArenaGame := preload("../game/arena_game.gd")
const ArenaLoadoutIdentity := preload("../game/arena_loadout_identity.gd")
const DIR := "user://shot_loadouts"
const KEY := "scoped0123456789"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DotPaths.remove_tree(DIR)
	var game := ArenaGame.new()
	root.add_child(game)
	game._build_loadouts()
	game.loadouts.store = ArenaLoadoutIdentity.make_store(DIR)
	var picks := [["Rusher", &"smg", &"pistol"], ["Sniper", &"sniper", &"pistol"], ["Breacher", &"shotgun", &"pistol"]]
	for pick: Array in picks:
		var l := game.loadouts.schema.default_loadout()
		l.set_item(&"primary", pick[1])
		var saved: DotResult = await game.loadouts.save_as(KEY, l, pick[0])
		if not saved.ok:
			print("save failed: ", saved.error)
	var _s: DotResult = await game.loadouts.select(KEY, 1)

	var menu := DotMenu.new()
	menu.manage_pointer = false
	root.add_child(menu)
	var res := menu.setup()
	if not res.ok:
		print("menu setup: ", res.error.message)
	var lo := menu.use_loadout(
		func() -> Variant: return await game.loadout_command.call(&"offer", KEY),
		func(_p: Dictionary) -> bool: return true)
	await process_frame
	lo.open()
	for i in 12:
		await process_frame
	DirAccess.make_dir_recursive_absolute("screenshots")
	root.get_texture().get_image().save_png("screenshots/loadout_saved.png")
	print("saved: ", game.loadouts.saved_list(KEY).size())
	DotPaths.remove_tree(DIR)
	quit(0)
