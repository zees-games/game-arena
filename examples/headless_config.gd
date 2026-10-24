extends Node

## ArenaConfig through DotGameConfigBinder: fields, cvars, the horde reading them, strict refusal, the diff.
##
## [codeblock]
## godot --headless --path . res://examples/headless_config.tscn
## [/codeblock]

const ArenaGame := preload("../game/arena_game.gd")
const ArenaHorde := preload("../game/arena_horde.gd")
const CHECKS := 9

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
	print("arena: config binder")
	var game := ArenaGame.new()
	var binder := DotGameConfigBinder.create(game.config, "game-arena", "arena")
	binder.strict = true
	_check(binder.load_layers().ok, "defaults load")
	_check(binder.schema().size() == 8 and binder.diff().is_empty(), "eight horde fields, no diff at the code defaults")
	var console := DotConsole.new()
	add_child(console)
	binder.bind_cvars(console.cvar, DotConVar.FLAG_ARCHIVE, console.has_name)
	_check(console.get_int("arena_horde_cap") == 36, "cvar starts at the default")
	console.set_cvar("arena_horde_cap", "12")
	_check(game.config.horde_cap == 12 and binder.source_of("horde_cap") == "cvar", "cvar writes the field")
	var horde := ArenaHorde.new()
	horde.game = game
	var rules: DotNpcDirectorRules = horde._rules()
	_check(rules.absolute_cap == 12 and rules.spawn_burst == 3, "the horde's rules read the config")
	_check(binder.diff_yaml().contains("horde_cap: 12"), "the diff names the edit")
	game.config.horde_spawn_max_distance = 5.0
	_check(not game.config.validate().ok, "validate refuses max <= min distance")
	_check(not binder.check_map("dm_nowhere", ["dm_box"]).ok, "strict: an unknown map is refused")
	_check(binder.schema()[0]["description"].begins_with("Horde monsters per player"), "doc comments reach the schema")
	print("%d passed, %d failed" % [_passed, _failed])
	horde.free()
	game.free()
	if _passed + _failed != CHECKS:
		_failed += 1
		print("FAIL: expected %d checks" % CHECKS)
	get_tree().quit(1 if _failed > 0 else 0)
