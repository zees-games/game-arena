extends Node

const ArenaMode := preload("../game/arena_mode.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMaps := preload("../game/arena_maps.gd")
const ArenaModes := preload("../game/arena_modes.gd")
const ArenaVoteSource := preload("../game/arena_vote_source.gd")

## What a subscribed map pack does to this game's lists, against a fixture
## [DotContentIndex] and never the process's shared one.
##
## [codeblock]
## godot --headless --path . res://examples/headless_workshop.tscn
## [/codeblock]
##
## Three things are the point: a solo map is listed (with its pack's name, in the solo map
## menu and on the ballot), an online session lists none of it, and a map kind the game does
## not accept is left out. The game's own ids winning is the fourth.

const SECTIONS := 4
const MAP := &"fixture_hill"
const OTHER_KIND := &"fixture_run"

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0
var _failures: Array[String] = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena — Workshop maps")
	_test_accepts()
	_test_solo()
	_test_online()
	_test_ids()

	print("")
	_check(_completed == _entered and _entered == SECTIONS,
		"every section ran to its last line (%d of %d, %d expected)" % [_completed, _entered, SECTIONS])
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	get_tree().quit(1 if _failed > 0 or _completed != SECTIONS else 0)


## A pack with an arena map, a surf-run map the game does not accept, and a map that claims
## the id of a built-in.
func _index(session: StringName) -> DotContentIndex:
	var index := DotContentIndex.new()
	index.set_session(session)
	var added := index.add_pack({
		"content_id": "fixture/hills", "version": "1.0.0", "prefix": "res://fixture/",
		"session": session, "source": &"subscription",
		"provides": {"schema": 1, "title": "Fixture Pack", "kinds": ["map"], "entries": [
			{"kind": "map", "id": String(MAP), "name": "Fixture Hill", "scene": "hill.tscn", "map_kind": "arena"},
			{"kind": "map", "id": String(OTHER_KIND), "name": "Fixture Run", "scene": "run.tscn", "map_kind": "surf"},
			{"kind": "map", "id": "dm_box", "name": "Not The Box", "scene": "box.tscn", "map_kind": "arena"},
		]},
	})
	_check(added.ok, "the fixture pack registers for %s" % session)
	return index


func _names(rows: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for row: Dictionary in rows:
		out.append(str(row["name"]))
	return out


func _ballot_labels(catalogue: DotMapCatalogue) -> PackedStringArray:
	var out := PackedStringArray()
	# A game with a mode, because a ballot offers a map only for a mode that can be played on it.
	var game := ArenaGame.new()
	game.mode = ArenaModes.by_id(&"ffa")
	var source := ArenaVoteSource.of(catalogue, null, game)
	source.include_modes = false
	for choice in source.choices():
		out.append(choice.label())
	game.free()
	return out


func _test_accepts() -> void:
	_entered += 1
	print("")
	print("what the game accepts")
	var kinds := ArenaMaps.accepted_map_kinds()
	_check(kinds == PackedStringArray(["arena"]), "provides.json accepts the arena map kind only", str(kinds))
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://provides.json"))
	var accepts: Dictionary = (parsed as Dictionary).get("accepts", {})
	_check(accepts.get("kinds") == ["map"], "and only maps (weapons need a loadout change)", str(accepts))
	_completed += 1


func _test_solo() -> void:
	_entered += 1
	print("")
	print("solo")
	var catalogue := ArenaMaps.catalogue(_index(DotContentIndex.SESSION_SOLO))
	var def := catalogue.get_map(MAP)
	_check(def != null, "the accepted map is in the catalogue")
	_check(def != null and def.label() == "Fixture Hill [Fixture Pack]", "its label names the pack")
	_check(catalogue.get_map(OTHER_KIND) == null, "a map kind the game does not accept is filtered out")
	var rows := ArenaMaps.menu_rows(catalogue, &"dm_box", null, ArenaModes.all())
	_check(_names(rows).has("Fixture Hill [Fixture Pack]"), "the solo map menu shows it as Name [Pack]")
	_check(not _names(rows).has("Fixture Run [Fixture Pack]"), "and not the other kind")
	_check(_ballot_labels(catalogue).has("Fixture Hill [Fixture Pack]"), "the vote lists it as Name [Pack]")
	# Playable-in-every-mode would build a navmesh and objectives out of boxes it does not have.
	var horde: Array = ArenaModes.all().filter(func(m: ArenaMode) -> bool: return ArenaMaps.needs_built_world(m))
	_check(horde.is_empty() or not ArenaMaps.supports_mode(def, horde[0]),
		"a mode built out of a box list is not offered on it")
	_completed += 1


func _test_online() -> void:
	_entered += 1
	print("")
	print("online")
	var index := _index(DotContentIndex.SESSION_SOLO)
	var catalogue := ArenaMaps.catalogue(index)
	_check(catalogue.get_map(MAP) != null, "listed while the index is solo")
	index.set_session(DotContentIndex.SESSION_ONLINE)
	_check(catalogue.get_map(MAP) == null, "gone from the same catalogue when the session turns online")
	_check(not _names(ArenaMaps.menu_rows(catalogue, &"dm_box", null, ArenaModes.all())).has("Fixture Hill [Fixture Pack]"),
		"gone from the map menu")
	_check(not _ballot_labels(catalogue).has("Fixture Hill [Fixture Pack]"), "gone from the ballot")
	# Built while the index is already online, from a pack that was only ever mounted solo.
	var late := _index(DotContentIndex.SESSION_SOLO)
	late.set_session(DotContentIndex.SESSION_ONLINE)
	_check(ArenaMaps.catalogue(late).get_map(MAP) == null, "a catalogue built online never lists it")
	_completed += 1


func _test_ids() -> void:
	_entered += 1
	print("")
	print("the game's own ids")
	var catalogue := ArenaMaps.catalogue(_index(DotContentIndex.SESSION_SOLO))
	var box := catalogue.get_map(&"dm_box")
	_check(box != null and box.pack_title == "" and box.name_or_id() != "Not The Box",
		"a pack map claiming dm_box does not replace the built-in")
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else " — " + detail])
	return condition
