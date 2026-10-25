extends Node

## The arena's config through the workbench: DotGameWorkbench over the binder's set, an edit, and the
## "Export changes as defaults" diff in the cfg/ layout.
##
## [codeblock]
## godot --headless --path . res://examples/headless_workbench.tscn
## [/codeblock]

const ArenaConfig := preload("../game/arena_config.gd")
const ArenaGame := preload("../game/arena_game.gd")
const CHECKS := 10

var _passed := 0
var _failed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("FAIL: ", what)


func _run() -> void:
	print("arena: workbench")
	var game := ArenaGame.new()
	var binder := ArenaConfig.make_binder(game.config)
	_check(binder.load_layers().ok, "defaults load")
	var wb := DotGameWorkbench.new()
	wb.panel_mode = 2
	wb.config = {"enabled": false}
	var set: DotProfileSet = binder.profile_sets()[0]
	wb.add_set(set, "Game settings")
	add_child(wb)
	var started := wb.start()
	_check(started.ok and started.value == true, "the workbench starts with a panel")
	binder.attach(wb.api.runtime)
	_check(wb.overlay != null and not wb.is_open(), "the window is built and closed")
	wb.open()
	_check(wb.is_open(), "F9 or the command opens it")
	_check(wb.console_command(PackedStringArray(["close"])) == "workbench closed", "the console command closes it")
	var res: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "set", "kind": set.rel_path, "id": binder.profile_id, "key": "horde_cap", "value": 12})
	_check(res.ok and game.config.horde_cap == 12, "an edit in the window reaches the live config")
	var files: Dictionary = wb.exporter.call("collect")
	var text: String = files.get("cfg/game/game-arena/config_horde/game.yml", "")
	_check(text == "horde_cap: 12\n", "the export holds just the changed field in the cfg layout")
	var root := "user://cfgtest_arena_export"
	var dir := root.path_join("game/game-arena/config_horde")
	DirAccess.make_dir_recursive_absolute(dir)
	var out := FileAccess.open(dir.path_join("game.yml"), FileAccess.WRITE)
	out.store_string(text)
	out.close()
	var again := ArenaGame.new()
	var reload := ArenaConfig.make_binder(again.config)
	reload.strict = true
	reload.roots = PackedStringArray([root])
	_check(reload.load_layers().ok and again.config.horde_cap == 12, "the export loads back as the defaults")
	again.free()
	DirAccess.remove_absolute(dir.path_join("game.yml"))
	var other: Variant = wb.api.handle("somebody", {"op": "set", "kind": set.rel_path, "id": binder.profile_id, "key": "horde_cap", "value": 13})
	_check(not other.ok, "another actor is refused without a permit")
	wb.permit_fn = func(actor: Variant, _flag: String) -> bool: return actor == "mod"
	_check(wb.api.handle("mod", {"op": "set", "kind": set.rel_path, "id": binder.profile_id, "key": "horde_cap", "value": 14}).ok, "a permitted actor edits")
	print("%d passed, %d failed" % [_passed, _failed])
	wb.free()
	game.free()
	if _passed + _failed != CHECKS:
		_failed += 1
		print("FAIL: expected %d checks" % CHECKS)
	get_tree().quit(1 if _failed > 0 else 0)
