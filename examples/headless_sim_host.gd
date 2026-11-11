extends Node

const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaSimHost := preload("../game/arena_sim_host.gd")

## `--sim_host 1`: the solo game runs as a loopback server process and this client joins it, so
## the simulation is off the render thread. Off unless asked for; the client sees the bots, lives,
## and the server process ends with the client.

const BOTS := 4

var _checks := 0
var _failed := 0
var _client: Node = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	var _scratch := ArenaPresentation.use_scratch_settings("headless_sim_host")
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	if not condition or OS.get_environment("VERBOSE") != "":
		print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return bool(condition.call())


func _players() -> int:
	var game: Object = _client.get("game")
	return (game.call("players") as Array).size() if game != null else 0


func _run() -> void:
	print("game-fatal-contact: the solo game hosted beside the client")
	_check(not ArenaSimHost.wanted(), "a suite's or a tool's client stays in this process")
	_check(ArenaSimHost.wanted(true), "the launched game is hosted")
	_check(ArenaSimHost.wanted_for(PackedStringArray(["--offline", "+bot_quota", "8"]), true), "a launcher's --offline is still hosted")
	_check(not ArenaSimHost.wanted_for(PackedStringArray(["--offline", "--sim_host", "0"]), true), "--sim_host 0 opts out under --offline")
	ArenaSimHost.forced = 0
	_check(not ArenaSimHost.wanted(true), "and can be told not to be")

	ArenaSimHost.forced = 1
	ArenaSimHost.ask_map = "dm_box"
	ArenaSimHost.ask_mode = "ctf"
	_check(ArenaSimHost.wanted(), "a tool can ask for it")
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	# What a bench sets: the host is joined all the same.
	_client.set("force_offline", true)
	_client.set("offline_bots", BOTS)
	_client.set("mouse_capture_override", true)
	add_child(_client)
	var built := await _until(func() -> bool: return _client.get("game") != null, 90.0)
	_check(built, "the client builds once the server answered")
	if not built:
		_end()
		return
	var host: ArenaSimHost = _client.get("_sim_host")
	_check(host != null and host.up, "the client joined its own server")
	if host == null:
		_end()
		return
	var pid: int = host.get("_pid")
	var game: Object = _client.get("game")
	_check(not bool(game.get("is_authority")), "this process is not the authority")
	_check(not bool(_client.get("_offline")), "the client runs the connected path")
	var platform: Object = _client.get("platform")
	_check(platform != null and bool(platform.get("local_link")) and platform.get("link") == host.link,
		"the platform holds the host's link as local, so --offline keeps it")
	var seen := await _until(func() -> bool: return _players() >= BOTS + 1, 40.0)
	_check(seen, "the client sees itself and the bots", "%d of %d" % [_players(), BOTS + 1])
	# A client's own `mode` stays the default; what the server plays arrives as `shown_mode`.
	var served := await _until(func() -> bool:
		var shown: Object = game.get("shown_mode")
		return shown != null and String(shown.get("id")) == "ctf", 20.0)
	var shown_now: Object = game.get("shown_mode")
	_check(served, "the server plays the mode that was asked for", "none" if shown_now == null else String(shown_now.get("id")))
	var alive := await _until(func() -> bool:
		var p: Object = _client.get("player")
		return p != null and bool(p.call("is_alive")), 40.0)
	_check(alive, "the local player is alive on the server")
	# The boot map's match must start running without waiting for a map change.
	var running := await _until(func() -> bool:
		var match_node: Object = game.get("match_node")
		return match_node != null and int(match_node.get("state")) != DotMatch.State.IDLE, 15.0)
	_check(running, "the boot map's match runs before any map change")
	var net: Object = _client.get("net")
	var synced := await _until(func() -> bool: return net != null and net.get("clock") != null and bool(net.get("clock").call("is_synced")), 20.0)
	_check(synced, "the clock is synced to the server")
	_check(OS.is_process_running(pid), "the server process is running")
	await _menu_checks(host)
	_board_checks()
	await _kill_feed_checks(host, game)
	await _owner_checks(game)
	_check(OS.is_process_running(pid), "the server process outlived all of that")

	_client.queue_free()
	_client = null
	var gone := await _until(func() -> bool: return not OS.is_process_running(pid), 20.0)
	_check(gone, "the server process ends with the client")
	_end()


func _ask(line: String) -> DotResult:
	return await (_client.get("host_console") as Node).call("ask", line)


func _tick_of(answer: DotResult) -> int:
	return str(answer.value).get_slice("tick ", 1).to_int() if answer.ok else -1


func _row(prefix: String) -> String:
	for row: Dictionary in _client.call("map_menu_rows"):
		if str(row["id"]).begins_with(prefix) and not bool(row["current"]) and (prefix == "mode:" or str(row.get("detail", "")) == ""):
			return str(row["id"])
	return ""


## B and the team screen ask the server process over its link, as a connected client's do; the
## server must answer and not refuse them as "sending messages too quickly".
func _menu_checks(host: ArenaSimHost) -> void:
	var refused := [0]
	host.link.chat_received.connect(func(payload: Dictionary) -> void:
		if str(payload).contains("too quickly"):
			refused[0] += 1)
	var loadout: Object = _client.get("loadout_menu")
	_check(loadout != null and bool(loadout.call(&"is_online")), "the loadout menu asks the server process")
	if loadout == null:
		return
	var menu: Object = _client.get("game_menu")
	var opened := false
	for _press in range(8):
		loadout.call(&"open")
		var _answered := await _until(func() -> bool: return int(loadout.get(&"_waiting_since_msec")) < 0, 5.0)
		var screen: Object = menu.get(&"loadout_screen")
		if screen != null and bool(screen.call(&"is_open")):
			opened = true
			screen.call(&"close")
	var said := str(loadout.get(&"last_said"))
	_check(int(loadout.get(&"_waiting_since_msec")) < 0 and (opened or (said != "" and not said.contains("did not answer"))),
		"the server answers B", str(loadout.call(&"describe")))
	var teams: Object = menu.get(&"teams")
	_check(teams != null and teams.get(&"link") == host.link, "the team screen asks the server process too")
	await get_tree().create_timer(0.5).timeout
	_check(refused[0] == 0, "eight presses of B are not refused as too quick", "%d refusals" % refused[0])


## Solo CTF drew one column on Tab; a team mode gets the team board in solo too.
func _board_checks() -> void:
	var board: Object = _client.get("board")
	_check(board != null, "the client has a Tab board")
	if board == null:
		return
	var snap := {}
	board.call(&"_rows_from_match", snap)
	var sides: Array = snap.get("teams", [])
	var rows: Array = snap.get("players", [])
	var teamed := 0
	for row: Dictionary in rows:
		if int(row.get("team", 0)) > 0:
			teamed += 1
	_check(sides.size() == 2, "solo CTF's Tab board has both teams", str(sides))
	_check(teamed > 0, "and its rows carry their team", "%d of %d" % [teamed, rows.size()])


## Every kill was said again in chat; the feed top-right is the only place for it.
func _kill_feed_checks(host: ArenaSimHost, game: Object) -> void:
	var chat: Array[String] = []
	var kills: Array[String] = []
	var heard := func(payload: Dictionary) -> void: chat.append(str(payload))
	# A connected client hears a kill as the bridge's KILL, and its feed is built from that;
	# the server said it again in chat as `DotKillFeed.Entry`'s line, "<killer> [<cause>] <victim>".
	var killed := func(info: Dictionary) -> void:
		var victim: Object = game.call(&"player_for", int(info["victim_id"]))
		kills.append("[%s" % info["weapon"] if int(info["killer_id"]) != 0 else "died (%s)" % info["weapon"])
		if victim != null:
			kills.append("] %s" % victim.get(&"display_name"))
	var bridge: Object = _client.get("bridge")
	host.link.chat_received.connect(heard)
	bridge.connect(&"kill_received", killed)
	var bound := await _until(func() -> bool:
		var console: Node = _client.get("host_console")
		return console != null and (console.get("source") as DotConsoleRemote).names().has("bot_quota"), 20.0)
	var slay := ""
	if bound:
		for name: String in (_client.get("host_console").get("source") as DotConsoleRemote).names():
			if name.ends_with("slay"):
				slay = name
	var said := "no slay command"
	if slay != "":
		var slain: DotResult = await _ask("%s @alive" % slay)
		said = "ok" if slain.ok else slain.error.message
	var seen := await _until(func() -> bool: return kills.size() > 0, 10.0)
	await get_tree().create_timer(1.0).timeout
	_check(seen, "a slay reaches the client's kill feed", "%s: %s, %d kills" % [slay, said, kills.size()])
	var repeated: Array[String] = []
	for line in chat:
		for kill in kills:
			if line.contains(kill):
				repeated.append(line)
	_check(repeated.is_empty(), "no kill is said again in chat", str(repeated))
	host.link.chat_received.disconnect(heard)
	bridge.disconnect(&"kill_received", killed)


## What solo does in its own process, asked of the server process: bots, difficulty, cheats, pause, map and mode.
func _owner_checks(game: Object) -> void:
	var bound := await _until(func() -> bool:
		var console: Node = _client.get("host_console")
		return console != null and (console.get("source") as DotConsoleRemote).names().has("bot_quota"), 20.0)
	_check(bound, "the client knows the server's console names")
	if _client.get("host_console") == null:
		return
	await get_tree().create_timer(2.0).timeout
	_check(_players() == BOTS + 1, "joining did not change the bot count", str(_players()))
	var quota: DotResult = await _ask("bot_quota 3")
	var three := await _until(func() -> bool: return _players() == 3, 20.0)
	_check(quota.ok and three, "bot_quota counts the player, as solo does", "%s, %d players" % [quota.ok, _players()])
	var hard: DotResult = await _ask("bot_difficulty hard")
	var hard_now: DotResult = await _ask("bot_difficulty")
	_check(hard.ok and str(hard_now.value).contains("hard"), "bot_difficulty reaches the server", str(hard_now.value))
	var cheats: DotResult = await _ask("sv_cheats 1")
	var cheats_now: DotResult = await _ask("sv_cheats")
	_check(cheats.ok and str(cheats_now.value).contains("1"), "sv_cheats reaches the server", str(cheats_now.value))
	var unknown: DotResult = await _ask("no_such_thing_at_all 1")
	_check(not unknown.ok and unknown.error.message != "", "a wrong name is answered with the server's refusal", "" if unknown.ok else unknown.error.message)

	var paused: DotResult = await _ask("host_pause 1")
	await get_tree().create_timer(0.5).timeout
	var still: DotResult = await _ask("host_pause")
	_check(paused.ok and _tick_of(paused) >= 0 and _tick_of(still) == _tick_of(paused), "pause stops the game", "%s | %s" % [paused.value, still.value])
	var resumed: DotResult = await _ask("host_pause 0")
	await get_tree().create_timer(0.5).timeout
	var later: DotResult = await _ask("host_pause")
	_check(resumed.ok and _tick_of(later) > _tick_of(still), "and it runs on when resumed", "%s | %s" % [still.value, later.value])
	_check((_client.get("link") as Object) != null and _players() == 3, "the pause did not drop the player")

	var rows: Array = _client.call("map_menu_rows")
	var lists_mode := false
	for row: Dictionary in rows:
		lists_mode = lists_mode or (str(row["id"]) == "mode:ctf" and bool(row["current"]))
	_check(lists_mode, "the map menu marks the mode the server plays")
	var mode_id := _row("mode:")
	var moded: DotResult = await _client.call("change_from_menu", StringName(mode_id))
	var mode_seen := await _until(func() -> bool:
		var shown: Object = game.get("shown_mode")
		return shown != null and "mode:%s" % shown.get("id") == mode_id, 30.0)
	_check(moded.ok and mode_seen, "a mode picked in the menu is played", "%s %s" % [mode_id, "" if moded.ok else moded.error.message])
	var map_id := _row("map:")
	var mapped: DotResult = await _client.call("change_from_menu", StringName(map_id))
	var map_seen := await _until(func() -> bool:
		return game.get("map") != null and "map:%s" % game.get("map").id == map_id, 60.0)
	_check(mapped.ok and map_seen, "a map picked in the menu is played", "%s %s" % [map_id, "" if mapped.ok else mapped.error.message])
	var alive := await _until(func() -> bool:
		var p: Object = _client.get("player")
		return p != null and bool(p.call("is_alive")), 40.0)
	_check(alive and _players() == 3, "the player and the bots are on the new map", str(_players()))
	var bad: DotResult = await _client.call("change_from_menu", &"map:no_such_map_at_all")
	_check(not bad.ok and bad.error.message != "The server changes the map.", "a map that does not exist is refused with the reason", "" if bad.ok else bad.error.message)


func _end() -> void:
	ArenaSimHost.forced = -1
	ArenaSimHost.ask_map = ""
	ArenaSimHost.ask_mode = ""
	if _client != null:
		_client.queue_free()
		await get_tree().process_frame
		await get_tree().process_frame
	print("headless_sim_host: %d checks, %d failed" % [_checks, _failed])
	get_tree().quit(1 if _failed > 0 else 0)
