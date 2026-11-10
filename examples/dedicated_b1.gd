extends DotGameCheckSuite

const ArenaBrowser := preload("../game/arena_browser.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaModule := preload("../game/arena_module.gd")
const ArenaTestPorts := preload("test_ports.gd")


const ArenaVote := preload("../game/arena_vote.gd")
const ArenaVoteSource := preload("../game/arena_vote_source.gd")

## A real [DotServer], listening, with the arena loaded into it; exits non-zero on any failure.
## Unlike `headless_match` (an [ArenaGame] driven directly) this binds a port, loads
## [ArenaModule] and exercises its console commands, cvar, sessions and unload. No client connects.


var PORT := ArenaTestPorts.free_port(2)


var _entered := 0
var _finished := 0


var _server: DotServer = null
var _game: ArenaGame = null


## What the bridge sent to the sessions this suite adopts with no socket behind them,
## caught on the link's loopback instead of going out as an `rpc_id`. See
## [method _test_client_spawn].
var _caught: Array[Dictionary] = []


## The vote and map clocks, the ballot's ids and cooldown, and dot-vote's commands.
func _test_vote_wiring(module: ArenaModule, options: Array) -> void:
	# Both map clocks follow hibernation; their own suites assert what following does.
	_check(
		_server.hibernation_changed.is_connected(module.vote.director.set_hibernating),
		"the vote's clock follows the server's hibernation"
	)
	_check(
		_server.hibernation_changed.is_connected(module.maps.session.set_hibernating),
		"and so does the map director's fallback clock"
	)

	# A bare id would be ambiguous the day somebody names a mode after a map.
	var unprefixed := PackedStringArray()

	for choice in options:
		var text := String(choice.id)

		if not text.begins_with(ArenaVoteSource.MAP_PREFIX) 				and not text.begins_with(ArenaVoteSource.MODE_PREFIX):
			unprefixed.append(text)

	_check(
		unprefixed.is_empty(),
		"and every choice says whether it is a map or a mode",
		", ".join(unprefixed)
	)

	_check(
		module.vote.director.source.has(StringName("map:dm_atrium")),
		"dm_atrium is on the ballot"
	)

	# Two maps ship, so "not in the last five" would leave nothing to offer.
	_check(
		module.vote.director.rules.cooldown <= 1,
		"the cooldown fits a two-map catalogue",
		"%d" % module.vote.director.rules.cooldown
	)

	# `begin_on_apply` off stops one play being counted twice in the cooldown history.
	_check(
		not module.vote.director.begin_on_apply,
		"and the director does not announce a change the host already announces"
	)

	# A refusal is a legitimate answer; the point is that the clock did not latch.
	var opened := module.vote.director.open_vote(DotVoteClock.REASON_MANUAL)
	_check(
		opened.ok or opened.error != null,
		"a vote can be asked for and answers either way",
		"" if opened.ok else opened.error.message
	)

	if opened.ok:
		_check(module.vote.is_voting(), "and the ballot is open")
		module.vote.director.close_vote()
		_check(not module.vote.is_voting(), "and closes again")

	# The operator's four commands once did not exist here at all.
	var absent := PackedStringArray()

	for name in [
		"rtv", "unrtv", "nominate", "vote", "timeleft", "nextmap",
		"setnextmap", "nominate_addmap", "forcertv", "votereload",
	]:
		if _server.console.find_command(name) == null:
			absent.append(name)

	_check(
		absent.is_empty(),
		"dot-vote's commands are on the console, the operator's with the players'",
		"missing: %s" % ", ".join(absent)
	)


## dot-map and dot-vote, on a server with a rotation and a ballot.
func _test_maps_and_vote() -> void:
	_begin()
	print("")
	print("maps and the vote")

	var module := _server.modules.get_module("arena") as ArenaModule

	if not _check(module != null and module.maps != null, "the map director is up"):
		return

	_check(
		module.maps.current != null and module.maps.current.id == _game.map.id,
		"and it adopted the map the server booted on"
	)

	# The sync host has a transport. Without one it announces a change to nobody and
	# every client carries on playing a map that no longer exists — which is the
	# absence dot-map's own notes call "the structural one".
	_check(
		module.maps.sync != null and module.maps.sync.send_fn.is_valid(),
		"the map sync host has somewhere to send its announcements"
	)

	if not _check(module.vote != null, "the vote is up"):
		return

	var options := module.vote.source.choices()
	_check(options.size() > 0, "and there is something to vote for", "%d" % options.size())

	_test_vote_wiring(module, options)

	# The map menu's server half (M): the maps and the modes of this ballot, each said to be
	# which; the owner's flag changes the map now through the director (so peers follow),
	# anybody else gets a vote. Contexts as dot-server makes them for a chat line.
	var menu_half: Object = module.vote.commands.get("map_menu")
	_check(menu_half != null and _server.console.find_command("mapmenu") != null
		and _server.console.find_cvar("sv_map_menu_flag").get_string() == "generic",
		"the map menu is there, staff-only by default")
	var menu_player := DotCmdContext.new()
	menu_player.source = DotCmdContext.Source.CHAT
	var offered: Dictionary = menu_half.call("offer", menu_player) if menu_half != null else {"maps": []}
	var rows: Array = offered["maps"]
	_check(rows.filter(func(r: Dictionary) -> bool: return r["mode"] == "Map").size() > 1
		and not bool(offered.get("allowed", true)) and bool(offered.get("vote", false)),
		"a player is offered the maps (and modes), as a vote", str(rows.map(func(r: Dictionary) -> String: return str(r["id"]))))
	var start_map := "map:%s" % _game.map.id
	var target := &""
	for row: Dictionary in rows:
		if row["mode"] == "Map" and not bool(row["current"]):
			target = StringName(str(row["id"]))
			break
	var staff := DotCmdContext.new()
	staff.source = DotCmdContext.Source.CHAT
	staff.permissions = PackedStringArray(["generic"])
	# The adopted player has no client to say it has the map, so it is off the sync host for the
	# change and back on after. Not awaited directly: a hung change would say nothing.
	var sync_peers := module.maps.sync.peers.duplicate()
	for peer in sync_peers:
		module.maps.sync.remove_peer(int(peer))
	var box: Array = []
	var run := func() -> void: box.append(await menu_half.call("choose", staff, target))
	run.call()
	# Up to half a minute: the sync host waits for this suite's adopted player, who has no
	# client to say it is ready, before it swaps without them.
	for _i in 300:
		if not box.is_empty():
			break
		await get_tree().create_timer(0.1).timeout
	var menu_result: Dictionary = box[0] if not box.is_empty() else {}
	_check(bool(menu_result.get("ok", false)) and "map:%s" % _game.map.id == String(target),
		"staff choosing a map changes it on the spot", "%s: %s" % [target, menu_result.get("text", "no answer")])
	# Back to the map the rest of this suite expects.
	var back: Array = []
	var undo := func() -> void: back.append(await menu_half.call("choose", staff, StringName(start_map)))
	undo.call()
	for _i in 300:
		if not back.is_empty():
			break
		await get_tree().create_timer(0.1).timeout

	# Every row the menu lists is one the source offers, and a mode row changes the mode on the
	# same map. A stale row is refused with the reason (ArenaVoteSource.unavailable_reason).
	var fresh: Array = (menu_half.call("offer", staff) as Dictionary)["maps"]
	var unknown := fresh.filter(func(r: Dictionary) -> bool:
		return not module.vote.director.source.has(StringName(str(r["id"]))))
	_check(unknown.is_empty() and fresh.any(func(r: Dictionary) -> bool: return r["mode"] == "Mode"),
		"every row the map menu lists is one the ballot offers, modes among them", str(unknown))
	var mode_box: Array = []
	var to_tdm := func() -> void: mode_box.append(await menu_half.call("choose", staff, &"mode:tdm"))
	to_tdm.call()
	for _i in 300:
		if not mode_box.is_empty():
			break
		await get_tree().create_timer(0.1).timeout
	var mode_result: Dictionary = mode_box[0] if not mode_box.is_empty() else {}
	_check(bool(mode_result.get("ok", false)) and _game.mode != null and _game.mode.id == &"tdm"
		and "map:%s" % _game.map.id == start_map,
		"staff choosing a mode row changes the mode on the same map",
		"%s on %s: %s" % [_game.mode.id if _game.mode != null else &"", _game.map.id, mode_result.get("text", "no answer")])
	mode_box.clear()
	var to_ffa := func() -> void: mode_box.append(await menu_half.call("choose", staff, &"mode:ffa"))
	to_ffa.call()
	for _i in 300:
		if not mode_box.is_empty():
			break
		await get_tree().create_timer(0.1).timeout
	_check(_game.mode != null and _game.mode.id == &"ffa", "and back to free-for-all the same way",
		str((mode_box[0] as Dictionary).get("text", "")) if not mode_box.is_empty() else "no answer")
	# The two tabs together: `/mapmenu map:x mode:y` changes the map under the mode in one change.
	var pair_target := &""
	for row: Dictionary in (menu_half.call("offer", staff) as Dictionary)["maps"]:
		if row["mode"] == "Map" and not bool(row["current"]) and module.vote.director.source.has(StringName(str(row["id"]))):
			pair_target = StringName(str(row["id"]))
			break
	mode_box.clear()
	var to_pair := func() -> void: mode_box.append(await menu_half.call("choose", staff, pair_target, &"mode:tdm"))
	to_pair.call()
	for _i in 300:
		if not mode_box.is_empty():
			break
		await get_tree().create_timer(0.1).timeout
	var pair_result: Dictionary = mode_box[0] if not mode_box.is_empty() else {}
	_check(pair_target != &"" and _game.mode != null and _game.mode.id == &"tdm" and "map:%s" % _game.map.id == String(pair_target),
		"a map and a mode picked together change both", "%s: %s" % [pair_target, pair_result.get("text", "no answer")])
	_check(not module.maps.current.meta.has("mode"), "and leave no mode stamped in the map's def")
	mode_box.clear()
	var back_pair := func() -> void: mode_box.append(await menu_half.call("choose", staff, StringName(start_map), &"mode:ffa"))
	back_pair.call()
	for _i in 300:
		if not mode_box.is_empty():
			break
		await get_tree().create_timer(0.1).timeout
	# A mode vote is a one-off, not a standing order: the stamp it puts in the map's def is
	# gone once the change is done, or the next visit to that map flips the mode back over
	# whatever was chosen since.
	_check(not module.maps.current.meta.has("mode"),
		"a mode change leaves no mode behind in the map's def", str(module.maps.current.meta.get("mode", "")))
	# A row from a list opened on a map with team spawns, chosen after a change to dm_pit
	# (none): refused, saying why. The director's current map is swapped for the check
	# only; nothing awaits in between, and the refusal changes nothing.
	var director_here: DotMapDef = module.maps.current
	module.maps.current = module.maps.session.catalogue.get_map(&"dm_pit")
	var stale: Dictionary = await menu_half.call("choose", staff, &"mode:tdm")
	module.maps.current = director_here
	_check(not bool(stale.get("ok", true)) and str(stale.get("text", "")).contains("no team spawns"),
		"a stale team-mode row on a map with no team spawns is refused with that reason", str(stale.get("text", "")))
	for peer in sync_peers:
		module.maps.sync.add_peer(int(peer))

	# A player's `!nominate dm_atrium`, as chat hands it to the console, from the session
	# the client-spawn section adopted. The ballot's id is `map:dm_atrium`; a command that
	# took the text as it came would nominate an id nothing has.
	var session := _server.session_by_userid(77)

	if _check(session != null, "the adopted player is still here"):
		var replies := PackedStringArray()
		var ctx := session.make_context(
			"nominate", PackedStringArray(["dm_atrium"]), DotCmdContext.Source.CHAT,
			func(line: String) -> void: replies.append(line)
		)
		_server.console.execute("nominate dm_atrium", ctx)
		_check(
			module.vote.director.nominated_ids().has(&"map:dm_atrium"),
			"a player's bare map name is nominated under the ballot's own id",
			"%s / %s" % [str(module.vote.director.nominated_ids()), " ".join(replies)]
		)
		_check(
			module.vote.director.nominations.by_voter(&"77").has(&"map:dm_atrium"),
			"and counted against the voter the rest of the game knows them as (77, not u77)"
		)

	# One clock. The map director's ran beside the vote's, and whichever expired
	# first won — which at the end of every map was a second ballot over a winner the
	# players had already chosen.
	var map_left := module.maps.session.time_limit.remaining
	var vote_left := module.vote.director.clock.remaining
	module._physics_process(0.5)
	_check(
		is_equal_approx(module.maps.session.time_limit.remaining, map_left)
			and module.vote.director.clock.remaining < vote_left,
		"only the vote's clock runs when there is a vote (map %.1f -> %.1f, vote %.1f -> %.1f)"
			% [map_left, module.maps.session.time_limit.remaining,
				vote_left, module.vote.director.clock.remaining]
	)

	# What reaches the wire. The module turns every `cue_due` into a VOTE event for every
	# ready client; this is the half of that join a server with no client can see.
	var heard: Array = []
	var probe := func(cue: StringName, seconds_left: int, runoff: bool) -> void:
		heard.append([String(cue), seconds_left, runoff])
	module.vote.cue_due.connect(probe)

	# Past the cooldown the ballot opened above left behind.
	module.vote.director.advance(module.vote.director.rules.vote_cooldown_sec + 1.0)

	var was_min := module.vote.director.rules.min_players_to_vote
	module.vote.director.rules.min_players_to_vote = 0
	var started := module.vote.director.start_vote(DotVoteClock.REASON_MANUAL)
	module.vote.director.rules.min_players_to_vote = was_min

	_check(
		started.ok and module.vote.director.is_counting_down(),
		"a vote starts with this game's countdown",
		"" if started.ok else started.error.message
	)
	_check(
		heard.has([String(ArenaVote.CUE_WARNING), 0, false]) and heard.has(["", 10, false]),
		"and its warning cue and first second are handed on for the wire (%s)" % str(heard)
	)

	module.vote.cue_due.disconnect(probe)
	module.vote.director.cancel_countdown()
	_end()


## [b]`time_up: finish_round` waits for a round being played, never for warmup.[/b] Run on a
## director of its own carrying the game's `round_in_progress_fn`; the match state is set by
## hand and put back.
func _test_finish_round_waits_for_a_live_round() -> void:
	_begin()
	print("")
	print("finish_round waits for a live round, not warmup")
	var module := _server.modules.get_module("arena") as ArenaModule
	var director: DotVoteDirector = module.vote.director if module != null and module.vote != null else null
	var hook: Variant = director.get("round_in_progress_fn") if director != null else null
	var hooked := hook is Callable and (hook as Callable).is_valid()

	if not _check(hooked and _game.match_node != null, "the game tells its vote whether a round is live"):
		# Three checks that cannot run without it, counted as failures so the total holds.
		for what in ["in warmup", "during a live round", "at the round's end"]:
			_check(false, "finish_round %s: no hook to try" % what)
		return

	var match_node: DotMatch = _game.match_node
	var was := match_node.state
	match_node.state = DotMatch.State.WARMUP
	var warm_applied := []
	var warm := _finish_round_probe(hook, warm_applied)
	_check(warm_applied == [&"b"] and not warm.is_finishing_round(),
		"in warmup a time limit with finish_round changes at once", str(warm_applied))

	match_node.state = DotMatch.State.LIVE
	var live_applied := []
	var live := _finish_round_probe(hook, live_applied)
	_check(live_applied.is_empty() and live.is_finishing_round(),
		"during a live round it waits for the round", str(live_applied))

	match_node.state = DotMatch.State.INTERMISSION
	live.advance(0.1)
	_check(live_applied == [&"b"], "and the round ending is the change", str(live_applied))

	match_node.state = was
	warm.queue_free()
	live.queue_free()
	_end()


## A director under `time_up: finish_round` carrying [param hook], its clock run out with a
## winner already decided: what dot-vote's own suite builds, with the game's answer in it.
func _finish_round_probe(hook: Callable, applied: Array) -> DotVoteDirector:
	var source := DotVoteListSource.new()
	var _a := source.add(DotVoteChoice.of(&"a", "A"))
	var _b := source.add(DotVoteChoice.of(&"b", "B"))
	source.apply_fn = func(id: StringName) -> DotResult:
		applied.append(id)
		return DotResult.success(id)

	var rules := DotVoteRules.new()
	rules.apply_delay_sec = 0.0
	rules.duration_sec = 100.0
	rules.vote_lead_sec = 40.0
	rules.vote_duration_sec = 5.0
	rules.include_extend = false
	rules.apply = DotVoteRules.Apply.END_OF_TIME
	rules.cooldown = 0
	rules.time_up = DotVoteRules.TimeUp.FINISH_ROUND
	# For ever: only the hook may release it.
	rules.finish_round_max_sec = 0.0

	var probe := DotVoteDirector.new()
	probe.rules = rules
	probe.source = source
	probe.register_service = false
	probe.self_advance = false
	probe.round_based = true
	probe.player_count_fn = func() -> int: return 4
	probe.set(&"round_in_progress_fn", hook)
	add_child(probe)
	probe.begin(&"a")
	source.current = &"a"

	for i in range(61):
		probe.advance(1.0)

	probe.cast_one(&"p1", &"b")

	# The ballot closes, then the limit (100 s) runs out with the winner decided.
	for i in range(46):
		probe.advance(1.0)

	return probe


## What a server browser is told: dot-browser is the client half; this is the server half, a
## query provider contributing the numbers a browser filters on.
func _test_query() -> void:
	_begin()
	print("")
	print("the server browser's half")

	var module := _server.modules.get_module("arena") as ArenaModule

	if module == null:
		return

	var snapshot := DotQuerySnapshot.new()

	for provider in module._query_providers:
		provider.call("_contribute", snapshot)

	_check(snapshot.game.has("mode"), "the query says what mode is being played")
	_check(snapshot.game.has("map"), "and on what map")
	_check(snapshot.game.has("state"), "and how far through it is")
	_check(
		String(snapshot.game.get("map", "")) == String(_game.map.id),
		"and the map it names is the one that is running",
		str(snapshot.game.get("map", ""))
	)
	# The standard field, which is the one A2S answers with and every listing prints. It
	# was the content id whatever the game said in its own section.
	_check(
		_server.games.reported_map() == String(_game.map.id),
		"and the query's own map field names it too, not the content id",
		_server.games.reported_map()
	)
	_end()


## dot-browser asking a real [DotServer]: a real UDP round trip between two objects in one
## process, the shape a player opening a server list is in.
func _test_browser() -> void:
	_begin()
	print("")
	print("a browser asking this server")

	var browser := ArenaBrowser.new()
	browser.name = "Browser"
	browser.timeout_ms = 2000
	# In memory. A suite that wrote a player's favourites to disk is a suite that
	# passes differently the second time it is run.
	browser.favourites_path = ""
	add_child(browser)

	var started := browser.setup()

	if not _check(started.ok, "the browser starts", str(started.error)):
		browser.queue_free()
		remove_child(browser)
		return

	# The query port, not the game port. dot-server listens for queries separately —
	# a browser that asked the game port would get no answer and report every server
	# as offline, which reads as the browser being broken.
	var query_port := _server.config.query_port

	if query_port <= 0:
		_check(false, "the server has a query port to ask", "query_enabled is off")
		browser.queue_free()
		remove_child(browser)
		return

	# The query port as a separate argument: a three-part address parses as a malformed IPv6 one
	# and fails at `connect_to_host` far from the cause.
	var added := browser.add("127.0.0.1:%d" % PORT, query_port)
	_check(added.ok, "a server can be added by address", str(added.error))

	var refreshed: DotResult = await browser.refresh()
	_check(refreshed.ok, "and asked", str(refreshed.error))

	var entries := browser.browser.entries()

	if not _check(entries.size() == 1, "there is one entry", "%d" % entries.size()):
		browser.queue_free()
		remove_child(browser)
		return

	var entry := entries[0]

	_check(
		entry.is_online(),
		"the server answered",
		entry.error.message if entry.error != null else entry.status_name()
	)

	if entry.is_online():
		_check(
			entry.name == _server.config.hostname,
			"with its hostname",
			"%s vs %s" % [entry.name, _server.config.hostname]
		)
		_check(
			entry.max_players == _server.config.max_players,
			"and its slot count",
			"%d vs %d" % [entry.max_players, _server.config.max_players]
		)

		# The game half, which is what `ArenaModule`'s query provider contributes. It is NOT
		# `entry.map` (dot-server's `info.map`, empty before any game switch); dot-browser nests
		# the game's section under `rules["game"]` so a field named `map` cannot overwrite it.
		_check(
			ArenaBrowser.game_field(entry, "map") == String(_game.map.id),
			"and the map the GAME says it is running",
			"%s vs %s" % [ArenaBrowser.game_field(entry, "map"), String(_game.map.id)]
		)
		_check(
			ArenaBrowser.game_field(entry, "mode") != "",
			"and the mode, which only the query provider knows",
			ArenaBrowser.game_field(entry, "mode")
		)

	# Favourites and history, which is the half a list is actually for.
	browser.favourite(entry.key(), true)
	_check(browser.browser.is_favourite(entry.key()), "a server can be favourited")

	browser.favourite(entry.key(), false)
	_check(
		not browser.browser.is_favourite(entry.key()),
		"and un-favourited again"
	)

	# Filtering is LOCAL. A server does not get to decide whether it appears in your
	# list; you queried it, you hold the answer, and a filter the server applied would
	# be a filter the server could lie about.
	browser.filter.hide_empty = true
	var hidden := browser.listing().size()
	browser.filter.hide_empty = false
	var shown := browser.listing().size()

	_check(
		hidden <= shown,
		"and the filter runs on what this client holds",
		"%d hidden, %d shown" % [hidden, shown]
	)

	browser.queue_free()
	remove_child(browser)
	_end()


func _test_client_spawn() -> void:
	_begin()
	print("")
	print("a client spawning")

	# `client_spawn` carries `userid` and `name`, not `peer_id`. The module once looked the
	# session up by `peer_id` (0 on every event) and nobody joined; this suite fires the event
	# dot-server fires and asserts somebody joined.
	var module := _server.modules.get_module("arena") as ArenaModule

	if not _check(module != null, "the module is loaded"):
		return

	var before := _game.player_ids().size()

	# `adopt_session` is for exactly this: a test that needs the session table populated without
	# a socket. A participant without a session is invisible to the roster, slots and queries.
	var session := DotClientSession.new()
	session.peer_id = 4242
	session.userid = 77
	session.display_name = "Ada"

	if not _check(_server.adopt_session(session).ok, "a session is adopted"):
		return

	# 4242 has no socket, so everything the bridge sends it was an `rpc_id` to an unknown peer
	# ("Attempt to call RPC with unknown peer ID" on every run). Caught on the link's loopback:
	# what was sent becomes a check. `_test_bots` silences dot-net's own send the same way.
	var link: Variant = module.bridge.link if module.bridge != null else null
	if link != null:
		link.loopback = func(method: StringName, peer_id: int, _payload: PackedByteArray) -> void:
			_caught.append({"method": method, "peer": peer_id})

	# The payload dot-server actually fires: `{"userid", "name"}`. No peer_id.
	_server.events.fire("client_spawn", {"userid": session.userid, "name": session.display_name})

	_check(
		link != null and _caught.any(func(c: Dictionary) -> bool: return c["method"] == &"event" and c["peer"] == 4242),
		"the join is announced to the joiner's PEER (4242), caught on the link's loopback",
		str(_caught)
	)

	_check(
		_game.player_ids().size() == before + 1,
		"a spawning client is added to the match",
		"%d -> %d" % [before, _game.player_ids().size()]
	)
	_check(
		_game.player_for(77) != null,
		"under its SESSION id (77), not its peer id (4242)"
	)
	_check(
		_game.player_for(4242) == null,
		"and the peer id is not a player key here"
	)

	# **The map sync admits a peer at its READY, and that admission names the map.** `add_peer`
	# only enrolls for the NEXT change, leaving a joiner on dm_box (4773e55). This is the
	# module's own path, seat then READY, read off the link.
	var sync: DotMapSyncHost = module.maps.sync if module.maps != null else null
	var announced: Array = []
	if link != null:
		link.loopback_map = func(_m: StringName, peer: int, payload: Dictionary) -> void:
			if peer == 4242 and DotMapMessage.kind_of(payload) == DotMapMessage.KIND_ANNOUNCE:
				announced.append(str((payload.get("map", {}) as Dictionary).get("id", "")))
	_check(sync != null and not sync.peers.has(4242),
		"a seated peer that has not said READY is not on the map sync yet",
		str(sync.peers) if sync != null else "no sync host")
	module.bridge.mark_ready(4242)
	_check(sync != null and sync.peers.has(4242) and announced == [String(_game.map.id)],
		"its READY admits it and announces the server's map (%s), once" % _game.map.id,
		str(announced))
	_end()


func _test_commands() -> void:
	_begin()
	print("")
	print("its commands")

	# Run through the console rather than calling the handlers, so the permission
	# checks and the argument plumbing are exercised too.
	var status := _server.console.execute("arena_status")
	_check(status.ok, "arena_status runs", str(status.error))

	var score := _server.console.execute("arena_score")
	_check(score.ok, "arena_score runs", str(score.error))

	var before := _game.match_node.round_number
	var restart := _server.console.execute("arena_restart")
	_check(restart.ok, "arena_restart runs", str(restart.error))
	_check(
		_game.match_node.round_number <= before,
		"and puts the match back to the start",
		"round %d -> %d" % [before, _game.match_node.round_number]
	)

	var modes := _server.console.execute("arena_modes")
	_check(modes.ok, "arena_modes runs", str(modes.error))

	# **The cvar that makes the two modes which are not about killing people reachable
	# from a deployment.** `ArenaGame.mode_id` is an export read once at setup, so
	# without this an operator has a game with five modes and one of them.
	var was := String(_game.mode.id)
	var switched := _server.console.execute("arena_mode koth")
	_check(switched.ok, "arena_mode koth runs", str(switched.error))
	_check(
		_game.mode.id == &"koth",
		"and the game is playing it",
		String(_game.mode.id)
	)
	_check(
		_game.objectives != null and _game.objectives.layout == &"koth",
		"with the objectives that mode asks for",
		String(_game.objectives.layout) if _game.objectives != null else "<none>"
	)

	# A mode that does not exist is refused AND the cvar is put back, without recursing through
	# its own `changed` signal: a cvar reading `koth` on a free-for-all server is believed.
	var bad := _server.console.execute("arena_mode not_a_mode")
	_check(bad.ok, "a bad mode does not error the console", str(bad.error))
	_check(
		_game.mode.id == &"koth",
		"and the game keeps playing what it was",
		String(_game.mode.id)
	)
	_check(
		_server.console.get_string("arena_mode", "") == "koth",
		"with the cvar put back to what is actually running",
		_server.console.get_string("arena_mode", "")
	)

	# And back, so the rest of the suite sees the game it expects.
	var restored := _server.console.execute("arena_mode %s" % was)
	_check(restored.ok, "and it changes back", str(restored.error))
	_check(_game.mode.id == StringName(was), "to the mode it started on")
	_end()


## The match cvars on a real console. `set_cvar` is the path a game.yml / content.yml value
## takes after the module loads; `execute` is the console's and rcon's.
func _test_match_cvars() -> void:
	_begin()
	print("")
	print("the match cvars")

	var rules := _game.match_node.rules
	var was_min := rules.min_players

	var score := _server.console.set_cvar("arena_scorelimit", "7")
	_check(
		score.ok and _game.match_node.rules.score_limit == 7,
		"arena_scorelimit 7 from a config is the running match's score limit",
		"%s, limit %d" % [str(score.error), _game.match_node.rules.score_limit]
	)

	var timed := _server.console.execute("arena_timelimit 90")
	_check(
		timed.ok and is_equal_approx(_game.match_node.rules.time_limit_sec, 90.0),
		"arena_timelimit 90 at the console is its time limit",
		"%s, %.1f" % [str(timed.error), _game.match_node.rules.time_limit_sec]
	)

	var warm := _server.console.execute("arena_warmup 3")
	var fewer := _server.console.execute("arena_minplayers 1")
	_check(
		warm.ok and fewer.ok and is_equal_approx(_game.match_node.rules.warmup_sec, 3.0)
			and _game.match_node.rules.min_players == 1,
		"arena_warmup 3 and arena_minplayers 1 are its warmup and its minimum",
		str(_game.match_node.rules.describe())
	)

	# A map change builds a new match from the mode; the server's numbers go with it.
	var changed := _game.change_map(ArenaMap.dm_box())
	var after := _game.match_node.rules
	_check(
		changed.ok and after != rules and after.score_limit == 7
			and is_equal_approx(after.time_limit_sec, 90.0)
			and is_equal_approx(after.warmup_sec, 3.0) and after.min_players == 1,
		"and all four survive a map change, which builds a new match",
		"%s: %d, %.1f, %.1f, %d" % [
			str(changed.error), after.score_limit, after.time_limit_sec, after.warmup_sec, after.min_players
		]
	)

	# Zero is the mode's own, not "no limit": a server can hand the number back.
	var back := _server.console.execute("arena_timelimit 0")
	_check(
		back.ok and is_equal_approx(_game.match_node.rules.time_limit_sec, _game.mode.rules.time_limit_sec),
		"arena_timelimit 0 gives the match the mode's own time limit back",
		"%.1f, the mode's %.1f" % [_game.match_node.rules.time_limit_sec, _game.mode.rules.time_limit_sec]
	)

	# Put back what the rest of the suite expects.
	var _a := _server.console.set_cvar("arena_scorelimit", "25")
	var _b := _server.console.set_cvar("arena_timelimit", "600")
	var _c := _server.console.set_cvar("arena_warmup", "-1")
	var _d := _server.console.set_cvar("arena_minplayers", str(was_min))
	_end()


func _begin() -> void:
	_entered += 1


func _end() -> void:
	_finished += 1
