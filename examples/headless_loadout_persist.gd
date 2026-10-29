extends DotGameCheckSuite

## Saved loadouts survive a restart and a reconnect: a new store, manager and identity get them back.
##
## [codeblock]
## godot --headless --path . res://examples/headless_loadout_persist.tscn
## [/codeblock]

const ArenaContent := preload("../game/arena_content.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaLoadoutIdentity := preload("../game/arena_loadout_identity.gd")
const ROOT := "user://arena_loadout_persist"
const CHECKS := 15


class FakeIdentity:
	extends RefCounted
	var uid := "guest-device-1"
	var claims := {"scoped_key": "scoped0123456789"}


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _make(dir: String) -> DotLoadoutManager:
	var manager := DotLoadoutManager.new()
	manager.register_service = false
	manager.schema = ArenaContent.loadout_schema()
	var config := DotLoadoutConfig.new()
	config.backend = "local"
	config.allow_default_loadout = true
	config.conform_on_load = true
	manager.config = config
	manager.store = ArenaLoadoutIdentity.make_store(dir)
	add_child(manager)
	return manager


func _session(userid: int, with_identity: bool) -> DotClientSession:
	var session := DotClientSession.new()
	session.userid = userid
	if with_identity:
		session.identity = FakeIdentity.new()
	return session


func _run() -> void:
	print("arena: saved loadouts persist")
	DotPaths.remove_tree(ROOT)

	var who := ArenaLoadoutIdentity.new()
	who.feed.scope_key_file = ROOT + "/scope.key"
	var key := who.bind(_session(7, true))
	_check(key == "scoped0123456789" and who.key_of(7) == key and who.id_of(key) == 7, "an identified player is filed under a stable key", key)
	_check(who.bind(_session(9, false)) == "" and who.key_of(9) == ArenaGame.storage_key(9) and who.id_of(ArenaGame.storage_key(9)) == 9, "a seat with no identity keeps the seat key")
	_check(ArenaLoadoutIdentity.is_durable(key) and not ArenaLoadoutIdentity.is_durable(who.key_of(9)), "only the stable key goes to disk")

	var first := _make(ROOT)
	for label: String in ["Rusher", "Sniper", "Medic"]:
		var saved: DotResult = await first.save_as(key, first.schema.default_loadout(), label)
		_check(saved.ok, "saves %s" % label, str(saved.error))
	var _picked: DotResult = await first.select(key, 1)
	var seat_saved: DotResult = await first.save_as(who.key_of(9), first.schema.default_loadout(), "Seat")
	_check(seat_saved.ok and DirAccess.get_files_at(ROOT).size() == 1, "a seat key stays in memory (only the stable key has a file)", str(DirAccess.get_files_at(ROOT)))
	first.queue_free()
	remove_child(first)

	var again := _make(ROOT)
	var rejoin := ArenaLoadoutIdentity.new()
	rejoin.feed.scope_key_file = ROOT + "/scope.key"
	var key2 := rejoin.bind(_session(31, true))
	var _loaded: DotResult = await again.load_for(key2)
	var list := again.saved_list(key2)
	var names: Array = []
	for entry in list:
		names.append(entry["name"])
	_check(key2 == key and names == ["Rusher", "Sniper", "Medic"], "a restart and a new session id get the same loadouts", str(names))
	_check(again.selected_index(key2) == 1, "and the same selection", str(again.selected_index(key2)))
	_check(rejoin.id_of(key2) == 31, "the key maps to the new player id")
	rejoin.release(31)
	_check(rejoin.key_of(31) == ArenaGame.storage_key(31), "a released player falls back to the seat key")

	var path := "%s/%s.json" % [ROOT, key]
	DotPaths.write_text(path, "{ not json", false)
	var broken := _make(ROOT)
	var got: DotResult = await broken.load_for(key)
	_check(got.ok and FileAccess.file_exists(path + ".corrupt"), "a corrupt file is set aside, not fatal", str(got.error))
	var healed: DotResult = await broken.save_as(key, broken.schema.default_loadout(), "Fresh")
	_check(healed.ok and FileAccess.file_exists(path), "and the player can save again", str(healed.error))
	broken.queue_free()
	remove_child(broken)

	var capped := _make(ROOT + "_capped")
	var tiered := capped.store as DotLoadoutStoreTiered
	(tiered.durable as DotLoadoutStoreLocal).max_file_bytes = 200
	var over: DotResult = await capped.save_as(key, capped.schema.default_loadout(), "Too big")
	_check(not over.ok and not FileAccess.file_exists("%s_capped/%s.json" % [ROOT, key]), "a save past the byte cap is refused and writes nothing", str(over.error))
	var caps_ok := (tiered.durable as DotLoadoutStoreLocal).max_files == 20000
	_check(caps_ok, "the file-count cap defaults on")
	capped.queue_free()
	remove_child(capped)
	again.queue_free()
	remove_child(again)

	DotPaths.remove_tree(ROOT)
	DotPaths.remove_tree(ROOT + "_capped")
	_report(CHECKS)
