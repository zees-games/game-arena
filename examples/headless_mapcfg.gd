extends Node

const ArenaMapConfig := preload("../game/arena_map_config.gd")

## A surf map gets the shipped `surf_%.yml` and a map that is not a surf map does not.
##
## [codeblock]
## godot --headless --path . res://examples/headless_mapcfg.tscn
## [/codeblock]
##
## The cvars start away from the file's values, so "got them" cannot be the default showing through.

const CHECKS := 8

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena: per-map cvars from cfg/game/game-arena/dot_map/map")
	var console := DotConsole.new()
	add_child(console)
	console.cvar("arena_surf", "0", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("arena_surf_airaccelerate", "90", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("arena_other", "5", "", DotConVar.FLAG_ARCHIVE)
	var cfg := ArenaMapConfig.build(console)

	var got := cfg.apply("surf_beginner")
	_check(got.size() == 2, "a surf map applies both keys (%s)" % [got])
	_check(console.find_cvar("arena_surf_airaccelerate").get_float() == 150.0, "arena_surf_airaccelerate is 150 on a surf map")
	_check(console.find_cvar("arena_surf").get_int() == 1, "arena_surf is 1 on a surf map")

	cfg.apply("dm_plain")
	_check(console.find_cvar("arena_surf_airaccelerate").get_float() == 90.0, "the next, non-surf map has the previous value back")
	_check(console.find_cvar("arena_surf").get_int() == 0, "arena_surf is back too")
	_check(cfg.applied().is_empty(), "a non-surf map applies nothing")

	cfg.apply("surf_other")
	_check(console.find_cvar("arena_surf_airaccelerate").get_float() == 150.0, "another surf map gets the same wildcard file")
	_check(console.find_cvar("arena_other").get_int() == 5, "a cvar outside the whitelist is untouched")

	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what)
		print("  FAIL  %s" % what)
