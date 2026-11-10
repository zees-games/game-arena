extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaModule := preload("../game/arena_module.gd")
const LoopbackServer := preload("loopback_server.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaFlagView := preload("../game/arena_flag_view.gd")

## Capture the flag online: a dedicated arena server (this script again with `--role server`, real ENet, CTF on `--map`) and the real client (arena.tscn) connected to it; the server walks the human onto the enemy flag, then their own stand.
## The client must see two flags at the server's homes, the pickup, the HUD's carry line, the capture and the score. Frames go to screenshots/ctf_online/; exit 1 on a failed check. `xvfb-run -a godot --path . res://tools/play_ctf_online.tscn -- --map cp-orange-x3`

const PORT := 27198
const OUT := "res://screenshots/ctf_online"

var _role := "client"
var _map := "cp-orange-x3"
var _client: Node = null
var _server_pid := -1
var _failed := 0
var _seen: Array[String] = []
var _carry_line := ""
var _watch_hud := false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--role": _role = args[i + 1]
			"--map": _map = args[i + 1]
	DotLog.set_level(DotLog.Level.WARN)
	var _scratch := ArenaPresentation.use_scratch_settings("play_ctf_online_" + _role)
	if _role == "server":
		_serve.call_deferred()
	else:
		_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print("  %s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failed += 1


func _serve() -> void:
	var data := "user://play_ctf_server"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(data))
	var game := ArenaGame.new()
	game.name = "Arena"
	game.tick_rate = 60
	game.score_limit = 0
	game.time_limit_sec = 0.0
	game.warmup_sec = 0.0
	game.headless = true
	game.register_service = true
	game.mode = ArenaMode.capture_the_flag(3)
	add_child(game)
	var map := ArenaMap.by_id(StringName(_map))
	var set := game.setup(map if map != null else ArenaMap.dm_box())
	if not set.ok:
		printerr("play_ctf server setup: ", set.error)
	var config := LoopbackServer.config("play ctf", PORT, data, "warn")
	var server := await LoopbackServer.boot(self, config, "play_ctf server")
	if server == null:
		get_tree().quit(1)
		return
	var module := server.modules.get_module("arena") as ArenaModule
	var g: ArenaGame = module.game
	g.start(0)
	print("play_ctf server: ready, mode %s, ctf %s" % [g.mode.id, g.objectives != null and g.objectives.ctf != null])
	_script_server.call_deferred(g)


## Waits for the human, then puts them on the enemy flag and on their own stand (the server is the authority).
func _script_server(g: ArenaGame) -> void:
	var human := 0
	while human == 0:
		await get_tree().create_timer(0.5).timeout
		for id in g.player_ids():
			var p = g.player_for(id)
			if p != null and not bool(p.get_meta(&"bot", false)) and str(p.display_name) == "Looker":
				human = id
	print("play_ctf server: human %d on team %d" % [human, g.team_of(human)])
	await get_tree().create_timer(10.0).timeout
	var ctf: DotObjectiveCtf = g.objectives.ctf
	var mine := g.team_of(human)
	var enemy := 2 if mine == 1 else 1
	var me = g.player_for(human)
	me.health.invulnerable = true
	var enemy_flag := ctf.flag_of(enemy)
	var own_flag := ctf.flag_of(mine)
	print("play_ctf server: flags mine %s enemy %s" % [own_flag.at, enemy_flag.at])
	var yaw := 0.0
	me.controller.teleport(enemy_flag.at + Vector3.UP * 0.05, yaw, 0.0)
	for i in 100:
		await get_tree().create_timer(0.1).timeout
		if enemy_flag.state == DotObjectiveFlag.State.CARRIED:
			break
	print("play_ctf server: enemy flag state %s carrier %s" % [enemy_flag.state, enemy_flag.carrier])
	await get_tree().create_timer(5.0).timeout
	me.controller.teleport(own_flag.at + Vector3.UP * 0.05, yaw, 0.0)
	for i in 100:
		await get_tree().create_timer(0.1).timeout
		if int(ctf.scores.get(mine, 0)) >= 1:
			break
	print("play_ctf server: scores %s" % [ctf.scores])


func _process(_delta: float) -> void:
	if not _watch_hud or _carry_line != "" or _client == null:
		return
	var hud = _client.get("hud")
	if hud != null:
		var line := str(hud.carrying_flag_text())
		if line != "":
			_carry_line = line
			_shot("carrying")


func _shot(name: String) -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path("%s/%s_%s.png" % [OUT, _map.replace("-", "_"), name]))
	print("  wrote %s" % name)


func _until(cond: Callable, limit: float) -> bool:
	var t := 0.0
	while t < limit:
		if cond.call():
			return true
		await get_tree().create_timer(0.1).timeout
		t += 0.1
	return cond.call()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
		"res://tools/play_ctf_online.tscn", "--", "--role", "server", "--map", _map])
	_server_pid = OS.create_process(OS.get_executable_path(), args)
	await get_tree().create_timer(10.0).timeout
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Looker"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % PORT
	add_child(link)
	link.connect_to_server("127.0.0.1:%d" % PORT)
	_check(await _until(func() -> bool: return link.is_playing(), 40.0), "the client connects to the dedicated server")
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("mouse_capture_override", true)
	add_child(_client)
	var ready: bool = await _until(func() -> bool:
		var pl = _client.get("player")
		var nt = _client.get("net")
		return pl != null and pl.is_alive() and nt != null and nt.clock.is_synced(), 60.0)
	_check(ready, "the client is in the world")
	var game = _client.get("game")
	var me = _client.get("player")
	var has_ctf: bool = await _until(func() -> bool: return game.objectives != null and game.objectives.ctf != null and game.objectives.ctf.flags().size() == 2, 20.0)
	_check(has_ctf, "the client mirrors the server's two flags (mode %s)" % game.mode.id)
	if not has_ctf:
		await _finish(link)
		return
	var ctf: DotObjectiveCtf = game.objectives.ctf
	game.ctf_seen.connect(func(what: StringName, team: int, by: int) -> void: _seen.append("%d:%s:%d" % [team, what, by]))
	_watch_hud = true
	var view = game.objectives.flag_view
	_check(view != null and view.drawn_count() == 2, "the client draws both flags")
	# The server tells the client its side (ArenaEvents.Kind.TEAM); until it has, team_of is a local guess.
	var known: bool = await _until(func() -> bool: return game.replicated_teams.has(me.player_id) and game.team_of(me.player_id) in [1, 2], 20.0)
	_check(known, "the client learns its own team from the server (team %d, announced %s)" % [game.team_of(me.player_id), game.replicated_teams])
	var mine: int = game.team_of(me.player_id)
	var enemy := 2 if mine == 1 else 1
	var presentation = _client.get("presentation")
	var played: Array[StringName] = []
	if presentation != null and presentation.audio != null:
		presentation.audio.played.connect(func(id: StringName, _handle: int, _why: StringName) -> void: played.append(id))
	for team in [mine, enemy]:
		var at: Vector3 = ctf.flag_of(team).at
		var drawn: Vector3 = view.view_position(team)
		_check(Vector2(drawn.x, drawn.z).distance_to(Vector2(at.x, at.z)) < 0.3, "flag %d is drawn at its home (%s)" % [team, at])
	await _shot("spawn")
	var hud = _client.get("hud")
	var taken: bool = await _until(func() -> bool: return _seen.has("%d:taken:%d" % [enemy, me.player_id]), 60.0)
	_check(taken, "the client sees the enemy flag picked up")
	var carried_home := 0
	for flag in ctf.flags():
		if flag.state == DotObjectiveFlag.State.CARRIED and flag.carrier == str(me.player_id):
			carried_home = flag.home_team()
	_check(carried_home != mine, "the flag this player carries (if still held when sampled) is not their own team's (carries %d, my team %d)" % [carried_home, mine])
	var line: String = _carry_line
	print("  carry line: '%s'  me %d" % [line, me.player_id])
	_check(line != "", "the HUD says the local player has the flag")
	_check(line.contains(ArenaFlagView.name_of(enemy)) and not line.contains(ArenaFlagView.name_of(mine)), "the HUD line names the enemy flag, not mine ('%s')" % line)
	var side_colour: Color = hud._team_colour(mine)
	var enemy_colour: Color = hud._team_colour(enemy)
	_check(side_colour.a > 0.0 and enemy_colour.a > 0.0 and side_colour != enemy_colour, "the HUD colours my side and the enemy's differently (%s, %s)" % [side_colour, enemy_colour])
	_check(side_colour == game.team_def(mine).colour, "the HUD colours my side with my team's colour")
	var scored: bool = await _until(func() -> bool: return int(ctf.scores.get(mine, 0)) >= 1, 40.0)
	_check(scored, "the client sees the capture score (%s)" % [ctf.scores])
	await get_tree().create_timer(0.5).timeout
	_check(str(hud.carrying_flag_text()) == "", "the carry line goes away after the capture")
	await _shot("after_capture")
	print("  seen: %s" % [_seen])
	_check(_seen.has("%d:taken:%d" % [enemy, me.player_id]) and _seen.has("%d:captured:%d" % [enemy, me.player_id]), "the client raised taken and captured (the flag sounds)")
	_check(played.has(&"flag_taken_by_me") and played.has(&"flag_captured"), "the flag sounds played for my pickup and capture (%s)" % [played])
	# The own-team check of the flag sounds: somebody else taking MY flag is a loss, taking THEIRS is a gain.
	played.clear()
	presentation.on_flag_event(&"taken", mine, false, game.team_of(me.player_id))
	presentation.on_flag_event(&"taken", enemy, false, game.team_of(me.player_id))
	_check(played == [&"flag_lost", &"flag_taken"], "somebody taking my flag sounds as a loss, theirs as a gain (%s)" % [played])
	await _finish(link)


func _finish(link: DotClientLink) -> void:
	print("play_ctf_online: %d failed" % _failed)
	link.disconnect_from_server("done")
	OS.kill(_server_pid)
	get_tree().quit(1 if _failed > 0 else 0)
