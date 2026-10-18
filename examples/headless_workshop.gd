extends Node

const ArenaMode := preload("../game/arena_mode.gd")
const ArenaMap := preload("../maps/arena_map.gd")
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

const SECTIONS := 6
const MAP := &"fixture_hill"
const OTHER_KIND := &"fixture_run"
const BAD_DOC := &"fixture_bad"
const BAD_ID := &"fixture_wrong_id"
const NO_SPAWN := &"fixture_no_spawn"
const DIR := "user://workshop_fixture/"

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
	_write_fixtures()
	_test_accepts()
	_test_solo()
	_test_online()
	_test_ids()
	_test_play()
	_test_bad()

	print("")
	_check(_completed == _entered and _entered == SECTIONS,
		"every section ran to its last line (%d of %d, %d expected)" % [_completed, _entered, SECTIONS])
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	get_tree().quit(1 if _failed > 0 or _completed != SECTIONS else 0)


func _write_fixtures() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var hill := {"schema": 1, "id": String(MAP), "name": "Fixture Hill", "extent": 20, "wall_height": 6,
		"boxes": [[-4, 0, -4, 8, 1, 8], [8, 0, 8, 3, 2, 3]],
		"spawns": [{"at": [-14, 0.1, 0], "yaw": 270}, {"at": [14, 0.1, 0], "yaw": 90}]}
	_write("hill.json", JSON.stringify(hill))
	_write("run.json", JSON.stringify(hill))
	_write("box.json", JSON.stringify(hill))
	_write("bad.json", "{ this is not json")
	var wrong := hill.duplicate(true)
	wrong["id"] = "somebody_else"
	_write("wrong.json", JSON.stringify(wrong))
	var bare := hill.duplicate(true)
	bare["id"] = String(NO_SPAWN)
	bare["spawns"] = []
	_write("nospawn.json", JSON.stringify(bare))


func _write(file: String, text: String) -> void:
	var out := FileAccess.open(DIR + file, FileAccess.WRITE)
	out.store_string(text)
	out.close()


## A pack with an arena map, a surf-run map the game does not accept, and a map that claims
## the id of a built-in, then three documents that are not maps.
func _index(session: StringName) -> DotContentIndex:
	var index := DotContentIndex.new()
	index.set_session(session)
	var added := index.add_pack({
		"content_id": "fixture/hills", "version": "1.0.0", "prefix": DIR,
		"session": session, "source": &"subscription",
		"provides": {"schema": 1, "title": "Fixture Pack", "kinds": ["map"], "entries": [
			{"kind": "map", "id": String(MAP), "name": "Fixture Hill", "scene": "hill.json", "map_kind": "arena"},
			{"kind": "map", "id": String(OTHER_KIND), "name": "Fixture Run", "scene": "run.json", "map_kind": "surf"},
			{"kind": "map", "id": "dm_box", "name": "Not The Box", "scene": "box.json", "map_kind": "arena"},
			{"kind": "map", "id": String(BAD_DOC), "name": "Broken", "scene": "bad.json", "map_kind": "arena"},
			{"kind": "map", "id": String(BAD_ID), "name": "Wrong Id", "scene": "wrong.json", "map_kind": "arena"},
			{"kind": "map", "id": String(NO_SPAWN), "name": "No Spawn", "scene": "nospawn.json", "map_kind": "arena"},
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


func _test_play() -> void:
	_entered += 1
	print("")
	print("playing a pack map in solo")
	var catalogue := ArenaMaps.catalogue(_index(DotContentIndex.SESSION_SOLO))
	var def := catalogue.get_map(MAP)
	var built := ArenaMaps.build_workshop(def)
	_check(built.ok, "the document builds a map", str(built.error) if not built.ok else "")
	if not built.ok:
		return
	var map: ArenaMap = built.value
	_check(map.id == MAP and map.display_name == "Fixture Hill", "with the entry's id and name")
	_check(map.spawns.size() == 2 and map.boxes.size() == 2 + 4, "two spawns, its two boxes and the four walls")
	var game := ArenaGame.new()
	game.name = "WorkshopGame"
	game.tick_rate = 64
	game.headless = true
	game.register_service = false
	game.mode = ArenaModes.by_id(&"ffa")
	add_child(game)
	_check(game.setup(ArenaMap.dm_box()).ok, "a game is set up on a built-in map")
	game.start(0)
	var changed := game.change_map(ArenaMaps.build_workshop(def).value)
	_check(changed.ok, "and changes to the pack map", str(changed.error) if not changed.ok else "")
	_check(game.map.id == MAP, "the game is on it")
	var added := game.add_player(900, "Walker")
	_check(added.ok, "a player joins it", str(added.error) if not added.ok else "")
	var at := Vector3.ZERO
	if added.ok:
		var _spawned := game.respawn_player(900)
		at = game.player_for(900).controller.state.position
	_check(absf(absf(at.x) - 14.0) < 1.0 and absf(at.z) < 1.0,
		"and spawns at one of the document's spawns", str(at))
	remove_child(game)
	game.free()
	_completed += 1


func _test_bad() -> void:
	_entered += 1
	print("")
	print("a bad document")
	var catalogue := ArenaMaps.catalogue(_index(DotContentIndex.SESSION_SOLO))
	for id: StringName in [BAD_DOC, BAD_ID, NO_SPAWN]:
		_check(catalogue.get_map(id) == null, "%s is refused and not in the catalogue" % id)
	var names := _names(ArenaMaps.menu_rows(catalogue, &"dm_box", null, ArenaModes.all()))
	for label in ["Broken [Fixture Pack]", "Wrong Id [Fixture Pack]", "No Spawn [Fixture Pack]"]:
		_check(not names.has(label), "%s is not on the map menu" % label)
	_check(names.has("Fixture Hill [Fixture Pack]"), "while the good map beside them is")
	# The catalogue re-adds its followed rows on a session turn, so the menu checks again.
	var index := _index(DotContentIndex.SESSION_SOLO)
	var live := ArenaMaps.catalogue(index)
	index.set_session(DotContentIndex.SESSION_ONLINE)
	index.set_session(DotContentIndex.SESSION_SOLO)
	var bad_def := live.get_map(BAD_DOC)
	_check(bad_def == null or not ArenaMaps.supports_mode(bad_def, ArenaModes.by_id(&"ffa")),
		"and stays refused after the catalogue refreshes")
	_check(not _names(ArenaMaps.menu_rows(live, &"dm_box", null, ArenaModes.all())).has("Broken [Fixture Pack]"),
		"and off the menu")
	var gone := ArenaMaps.build_workshop(null)
	_check(not gone.ok, "a null def is a refusal, not a crash")
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
