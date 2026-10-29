extends DotGameCheckSuite

## ArenaConfig through DotGameConfigBinder: fields, cvars, the horde reading them, strict refusal, the diff.
##
## [codeblock]
## godot --headless --path . res://examples/headless_config.tscn
## [/codeblock]

const ArenaGame := preload("../game/arena_game.gd")
const ArenaHorde := preload("../game/arena_horde.gd")
const ArenaAmbience := preload("../game/arena_ambience.gd")
const ArenaConfig := preload("../game/arena_config.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ROOT := "user://arena_cfgtest"
const GAME := "game-arena"
const CHECKS := 39


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _run() -> void:
	if OS.get_cmdline_user_args().has("--probe"):
		_probe()
		return
	print("arena: config binder")
	var game := ArenaGame.new()
	var binder := ArenaConfig.make_binder(game.config)
	binder.strict = true
	_check(binder.load_layers().ok, "defaults load")
	_check(binder.schema().size() == 31 and binder.diff().is_empty(), "31 fields, no diff at the code defaults")
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
	# The rest of the audit's tunables reach the game they tune.
	game.config.horde_spawn_max_distance = 34.0
	console.set_cvar("arena_player_health", "150")
	console.set_cvar("arena_respawn_delay_sec", "7")
	console.set_cvar("arena_award_nemesis_at", "5")
	console.set_cvar("arena_bot_quota", "2")
	_check(game.config.player_health == 150.0 and game.config.bot_quota == 2, "player and bot cvars write the fields")
	game.headless = true
	game.is_authority = true
	game.register_service = false
	add_child(game)
	game.setup(ArenaMap.dm_box())
	game.add_player(1, "A")
	_check(game.player_for(1).health.max_health == 150.0, "a new player has the configured health")
	_falls(game)
	game.apply_match_limits()
	_check(game.match_node.rules.respawn_delay_sec == 7.0, "the respawn delay overrides the mode's")
	game._sync_award_config()
	_check(game.medals.nemesis_at == 5, "the medal book reads the award thresholds")
	var schema_path := OS.get_cache_dir().path_join("arena_schema_check.json")
	_check(binder.write_schema(schema_path).ok, "write_schema writes the schema")
	DirAccess.remove_absolute(schema_path)
	_stats_keys(game)
	_layers()
	_templates(binder)
	_workbench(binder, game)
	print("%d passed, %d failed" % [_passed, _failed])
	horde.free()
	game.free()
	if _passed + _failed != CHECKS:
		_failed += 1
		print("FAIL: expected %d checks" % CHECKS)
	get_tree().quit(1 if _failed > 0 else 0)


## sv_falldamage: the controller's landed(impact) is what the component hears.
func _falls(game: ArenaGame) -> void:
	var faller := game.player_for(1)
	var fall := faller.get_node_or_null("FallDamage") as DotFallDamage
	_check(game.fall_rules.enabled and fall != null, "fall damage is on, a component per player")
	faller.controller.landed.emit(game.fall_rules.threshold + 5.0)
	_check(faller.health.health == 150.0, "warmup or intermission: the landing is absorbed")
	game.match_node.state = DotMatch.State.LIVE
	faller.controller.landed.emit(game.fall_rules.threshold - 1.0)
	_check(faller.health.health == 150.0, "a landing under the threshold costs nothing")
	faller.controller.landed.emit(game.fall_rules.threshold + 5.0)
	_check(faller.health.health < 150.0, "a landing over it costs health")
	faller.health.health = 150.0
	game.fall_rules.enabled = false
	faller.controller.landed.emit(game.fall_rules.threshold + 5.0)
	_check(faller.health.health == 150.0, "sv_falldamage 0: no damage")
	game.fall_rules.enabled = true
	game.map.movement_profile = &"surf"
	faller.controller.landed.emit(game.fall_rules.threshold + 5.0)
	_check(faller.health.health == 150.0, "a surf map absorbs the landing")
	game.map.movement_profile = &""
	faller.controller.landed.emit(60.0)
	_check(150.0 - faller.health.health <= game.fall_rules.max_damage and faller.health.health > 0.0, "a huge drop is capped, never lethal")


## Child process: loads the layers strictly over the test root and prints what the live config holds.
class _Member extends RefCounted:
	var uid := "backbone:arena-test"
	var is_guest := false
	var claims: Dictionary = {}


## Stats go under dot-game's stable per-server key once a session is known, the seat's key without one.
func _stats_keys(game: ArenaGame) -> void:
	var p := game.progress
	if not _check(p != null, "the authority keeps progress"):
		return
	var file := ROOT + "_stats.key"
	p.stats_keys.scope_key_file = file
	var who := DotClientSession.new()
	who.userid = 2
	who.identity = _Member.new()
	p.session_fn = func(_id: int) -> DotClientSession: return who
	var key := p._key_of(2)
	_check(key.length() == 22 and not key.begins_with("backbone:"), "a member is filed under a scoped pseudonym", key)
	_check(p._id_from_key(key) == 2, "and the key maps back to the player")
	p.session_fn = Callable()
	_check(p._key_of(3) == ArenaGame.storage_key(3), "with no session, the seat's key")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(file))


func _probe() -> void:
	var config := ArenaConfig.new()
	var binder := ArenaConfig.make_binder(config)
	binder.strict = true
	binder.roots = PackedStringArray([ProjectSettings.globalize_path(ROOT)])
	var loaded := binder.load_layers()
	var console := DotConsole.new()
	add_child(console)
	binder.bind_cvars(console.cvar, DotConVar.FLAG_ARCHIVE, console.has_name)
	print("PROBE ok=%s cap=%s cap_src=%s health=%s health_src=%s cvar=%s nem=%s nem_src=%s resp=%s resp_src=%s" % [
		loaded.ok, config.horde_cap, binder.source_of("horde_cap"), config.player_health, binder.source_of("player_health"),
		console.find_cvar("arena_player_health").get_string(), config.award_nemesis_at, binder.source_of("award_nemesis_at"),
		config.respawn_delay_sec, binder.source_of("respawn_delay_sec")])
	get_tree().quit(0)


func _write(rel: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ROOT.path_join(rel).get_base_dir())
	var f := FileAccess.open(ROOT.path_join(rel), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _child() -> String:
	var out: Array = []
	OS.execute(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"),
		"res://examples/headless_config.tscn", "--", "--probe", "--arena-respawn-delay-sec=4.5", "--arena-award-nemesis-at=6"], out, true)
	return "".join(PackedStringArray(out))


## A value set in a cfg file, the environment and argv each reaches the live config, and later layers win.
func _layers() -> void:
	_write("game/%s/config_horde/game.yml" % GAME, "horde_cap: 77\n")
	_write("game/%s/config_awards/game.yml" % GAME, "award_nemesis_at: 4\n")
	_write("game/%s/config_match/game.yml" % GAME, "respawn_delay_sec: 2.0\n")
	OS.set_environment("ARENA_PLAYER_HEALTH", "130")
	var text := _child()
	_check(text.contains("PROBE ok=true"), "the layers load strictly in a fresh process: " + text.right(300))
	_check(text.contains("cap=77") and text.contains("cap_src=yml"), "a cfg file reaches the live config (horde_cap)")
	_check(text.contains("health=130") and text.contains("health_src=env") and text.contains("cvar=130"), "the environment reaches the config and the cvar")
	_check(text.contains("resp=4.5") and text.contains("resp_src=argv"), "argv beats the file")
	_check(text.contains("nem=6") and text.contains("nem_src=argv"), "argv beats a second file (config_awards)")
	OS.unset_environment("ARENA_PLAYER_HEALTH")
	_write("game/%s/config_horde/game.yml" % GAME, "player_health: 90\n")
	_check(_child().contains("PROBE ok=false"), "strict: a key in the wrong file is refused")
	for f in ["config_horde", "config_awards", "config_match"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(ROOT.path_join("game/%s/%s/game.yml" % [GAME, f])))


## The shipped cfg files hold every key, in step with ArenaConfig, and change nothing as they are.
func _templates(binder: DotGameConfigBinder) -> void:
	var files := binder.template_files()
	_check(files.size() == 4, "four shipped cfg files: " + str(files.size()))
	var stale := PackedStringArray()
	for path: String in files:
		if not FileAccess.file_exists("res://" + path) or FileAccess.get_file_as_string("res://" + path) != files[path]:
			stale.append(path)
	_check(stale.is_empty(), "the shipped files match the config (run addons/dot_game/qa/dot_game_cfg_templates.gd): " + ",".join(stale))


## Every key is listed by the workbench, an edit lands in the right file, and the ambience cvars are a set.
func _workbench(binder: DotGameConfigBinder, game: Node) -> void:
	var keys := PackedStringArray()
	for e: Dictionary in binder.schema():
		keys.append(e["key"])
	var wb := DotGameWorkbench.new()
	wb.panel_mode = 1
	wb.config = {"enabled": false}
	wb.thread_cvars = false
	for set: DotProfileSet in binder.profile_sets():
		wb.add_set(set, set.rel_path)
	add_child(wb)
	_check(wb.start().ok, "the workbench starts")
	binder.attach(wb.api.runtime)
	var listed := PackedStringArray()
	for kind: String in wb.api.kinds():
		var got: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "get", "kind": kind, "id": binder.profile_id})
		if got.ok:
			listed.append_array(PackedStringArray((got.value as Dictionary).get("values", {}).keys()))
	var missing := PackedStringArray()
	for k in keys:
		if not listed.has(k):
			missing.append(k)
	_check(missing.is_empty() and binder.profile_sets().size() == 4, "the workbench lists all %d keys over %d files: %s" % [keys.size(), binder.profile_sets().size(), ",".join(missing)])
	var res: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "set", "kind": "config_awards", "id": binder.profile_id, "key": "award_kill_points", "value": 150})
	_check(res.ok and game.config.award_kill_points == 150, "a workbench edit reaches the live config")
	var files: Dictionary = wb.exporter.call("collect")
	var text: String = files.get("cfg/game/game-arena/config_awards/game.yml", "")
	_check(text.contains("award_kill_points: 150"), "the export holds the edit in the right file")
	var console := DotConsole.new()
	add_child(console)
	var _bound: Variant = game.ambient_rules.bind_cvars(console.cvar, DotConVar.FLAG_ARCHIVE, DotConVar.FLAG_ARCHIVE)
	var ambient := DotGameWorkbench.cvar_set(console, ArenaAmbience.cvar_types(), "ambience")
	_check(ambient != null and ambient.schema.size() >= 4, "the arena_ambient* cvars make a workbench set")
	wb.api.add_set(ambient)
	DotGameWorkbench.bind_cvar_set(ambient, wb.api.runtime, console)
	var amb: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "set", "kind": "ambience", "id": DotGameWorkbench.CVAR_SET_ID, "key": "arena_ambient_volume", "value": 0.2})
	_check(amb.ok and is_equal_approx(console.get_float("arena_ambient_volume"), 0.2), "an edit of the ambience set moves the cvar")
	wb.free()
	console.free()
