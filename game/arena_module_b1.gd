extends "arena_module_cvars.gd"

const ArenaBoards := preload("arena_boards.gd")


const ArenaAmbience := preload("arena_ambience.gd")
## The workbench kind of the ambience cvar set (saved to cfg/.../ambience/server.yml).
const AMBIENT_KIND := "ambience"
## The workbench kind of the wall-move cvar set (arena_wall*).
const WALL_KIND := "wallmoves"
const SPEED_KIND := "speeds"
const SPEED_CVARS: PackedStringArray = ["arena_speed_scale", "arena_run_speed", "arena_walk_scale", "arena_sprint_scale", "arena_crouch_scale"]
const ArenaMapConfig := preload("arena_map_config.gd")
const ArenaIdentity := preload("arena_identity.gd")


const ArenaBspMap := preload("../maps/arena_bsp_map.gd")


const ArenaMapDirector := preload("arena_map_director.gd")


const ArenaNetBridge := preload("arena_net_bridge.gd")
const ArenaServices := preload("arena_services.gd")
const ArenaStats := preload("arena_stats.gd")


const ArenaVote := preload("arena_vote.gd")

## Binds an [ArenaGame] to a [DotServer].


const CHANNEL := "arena.module"


## dot-combat's cvars (mp_teammate_passthrough), kept to put on each map's new combat manager.
var _combat_cvars: Array = []


var bridge: ArenaNetBridge = null
## Carries the workbench's profile runtime (rows down) over this manager; null without a workbench.
var profile_link: DotNetProfileLink = null


## Chat, voice and moderation. See [ArenaServices] for why it is not this file.
var services: ArenaServices = null


## Content, profiles, avatars and admission.
var identity: ArenaIdentity = null


## Maps as content: a catalogue, a rotation, a clock and a change that reaches clients.
var maps: ArenaMapDirector = null


## The per-map cvars a map's `cfg/.../dot_map/map/<name>.yml` sets, put back on the next map.
var map_config: DotGameMapConfig = null


## What plays next, decided by the players.
var vote: ArenaVote = null


## dot-server session id -> whether we have put them in the match.
var _joined: Dictionary = {}


## Who is still behind their loading cover, from dot-game's roster used for that alone: this module
## is not on DotGameModule, so it seats people itself and only borrows the bookkeeping (loading from
## the spawn event until the client says its cover lifted, again from a map change).
var loading: DotGameRoster = null
var _handles_cover: bool = false


func _on_player_spawned_for_tools(player: ArenaPlayer) -> void:
	if services != null and services.mod_tools != null:
		services.mod_tools.respawned(StringName(str(player.player_id)))


## maps.yml's `commands:` block (prefix and names), or empty with no file.
func _rotation_commands() -> Dictionary:
	return maps.rotation_file.commands() if maps != null and maps.rotation_file != null else {}


## `arena_scorelimit`, `arena_timelimit` and `arena_warmup`: the server's numbers over the mode's, live and kept across map changes ([member ArenaGame.score_limit]). A cvar writes the game's export, which every match built after it reads,
## and the live match through `_apply_match_limits`, because a server's config is applied after this module loads, when the first match is already running.
## Zero, for the two limits, is "the mode's own"; a negative warmup is too.
func _add_match_cvars() -> void:
	add_cvar(
		"arena_scorelimit", str(game.score_limit),
		"Kills to win the match (a side's in a team mode); 0 for the mode's own. Gun game ends at its last gun",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.score_limit = maxi(new_value.to_int(), 0)
			_apply_match_limits()
			log_info("score limit changed", {"score_limit": game.match_node.rules.score_limit})
	)
	add_cvar(
		"arena_timelimit", str(int(game.time_limit_sec)),
		"Seconds a match lasts; 0 for the mode's own",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.time_limit_sec = maxf(new_value.to_float(), 0.0)
			_apply_match_limits()
			log_info("time limit changed", {"time_limit_sec": game.match_node.rules.time_limit_sec})
	)
	add_cvar(
		"arena_warmup", str(game.warmup_sec),
		"Seconds of warmup before a match; -1 for the mode's own",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	).with_min(-1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.warmup_sec = new_value.to_float()
			_apply_match_limits()
			log_info("warmup changed", {"warmup_sec": game.match_node.rules.warmup_sec})
	)
	add_cvar(
		"mp_freezetime", str(game.freeze_sec),
		"Seconds everyone is frozen at their spawn before a round; 0 for none, -1 for the mode's own",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	).with_min(-1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.freeze_sec = new_value.to_float()
			_apply_match_limits()
			log_info("freeze time changed", {"countdown_sec": game.match_node.rules.countdown_sec})
	)


## Puts the game's limits on the running match and tells every client: MATCH carries the
## score limit the HUD divides by and the clock, which a new time limit has just moved.
func _apply_match_limits() -> void:
	game.apply_match_limits()
	if bridge != null:
		bridge.note_score_limit_changed()


## Puts dot-combat's cvars on the world's current combat manager: after a change, and after a
## map change built a new manager the cvar knows nothing about.
func _reapply_combat_cvars() -> void:
	if game == null or not is_instance_valid(game) or game.combat == null:
		return
	for cv in _combat_cvars:
		if cv is DotConVar and is_instance_valid(cv) and game.combat.has_method(&"set_cvar"):
			var _applied: Variant = game.combat.call(&"set_cvar", (cv as DotConVar).name, (cv as DotConVar).get_string())


## The loading roster and the handler for the client's cover report on dot-server's envelope.
## A kind on the existing envelope because the RPC set is frozen; a client that predates it is
## released by the roster's timeout. Duck-typed so an older dot-server still loads this.
func _build_loading() -> void:
	loading = DotGameRoster.new()
	loading.server = server

	if game != null:
		game.loading_fn = loading.is_loading

	if server == null or not ("envelope" in server):
		return

	var env: Object = server.get(&"envelope")

	if env != null and env.has_method("register"):
		env.call("register", DotGameRoster.COVER_KIND, Callable(self, "_on_cover_report"), false)
		_handles_cover = true


func _on_cover_report(peer_id: int, payload: Dictionary) -> void:
	var covered: Variant = payload.get("covered")

	if loading != null and covered is bool:
		loading.report_cover(peer_id, covered)


## Starts the workbench the server scene built: the config files, noblock and the arena_ambient* cvars as sets.
func _start_workbench() -> void:
	var wb := game.workbench
	if wb == null:
		return
	if game.player_stack != null and game.player_stack.spawn_overrides != null:
		wb.add_set(game.player_stack.spawn_overrides, "Spawn points (per map)")
	var ambient_set := DotGameWorkbench.cvar_set(console, ArenaAmbience.cvar_types(), AMBIENT_KIND)
	if ambient_set != null:
		wb.add_set(ambient_set, "Ambience (arena_ambient*)")
	var wall_types := {}
	for cvar: String in MOVEMENT_CVARS:
		if cvar.begins_with("arena_wall"):
			wall_types[cvar] = "float"
	var wall_set := DotGameWorkbench.cvar_set(console, wall_types, WALL_KIND)
	if wall_set != null:
		wb.add_set(wall_set, "Wall moves (arena_wall*)")
	var speed_types := {}
	for cvar in SPEED_CVARS:
		speed_types[cvar] = "float"
	var speed_set := DotGameWorkbench.cvar_set(console, speed_types, SPEED_KIND)
	if speed_set != null:
		wb.add_set(speed_set, "Speeds (arena_speed_scale, arena_run_speed, ...)")
	var started := wb.start()
	if not started.ok:
		DotLog.result(CHANNEL, "the workbench", started)
		return
	if wb.api == null:
		return
	var rt := wb.api.runtime as DotProfileRuntime
	if rt == null:
		return
	if game.config_binder != null:
		game.config_binder.attach(rt)
	if game.flashlight_binder != null:
		game.flashlight_binder.attach(rt)
	if ambient_set != null:
		var _applied := DotGameWorkbench.bind_cvar_set(ambient_set, rt, console)
	if wall_set != null:
		var _wall_applied := DotGameWorkbench.bind_cvar_set(wall_set, rt, console)


func _module_unload() -> void:
	if team_menu != null:
		team_menu.release()
		team_menu = null
	# The link and the runtime hold each other through broadcast.
	if profile_link != null:
		profile_link.release()
		profile_link = null
	if _handles_cover and server != null:
		var env: Object = server.get(&"envelope")

		if env != null and env.has_method("handle"):
			env.call("handle", DotGameRoster.COVER_KIND, Callable())

		_handles_cover = false

	if game != null and is_instance_valid(game):
		game.loading_fn = Callable()

	if loading != null:
		loading.clear()
		loading = null

	if map_config != null:
		map_config.restore()
		map_config = null

	if net != null and is_instance_valid(net):
		net.stop()

	if server != null and server.client_disconnected.is_connected(_on_client_disconnected):
		server.client_disconnected.disconnect(_on_client_disconnected)

	if game != null and is_instance_valid(game):
		if game.player_killed.is_connected(_on_player_killed):
			game.player_killed.disconnect(_on_player_killed)

		if game.player_spawned.is_connected(_on_player_spawned_for_tools):
			game.player_spawned.disconnect(_on_player_spawned_for_tools)

		for connection in game.map_changed.get_connections():
			var callable: Callable = connection["callable"]
			if callable.get_object() == self:
				game.map_changed.disconnect(callable)

		# Every player this module put in the match comes back out. A module that
		# unloaded and left them there would leave the game holding bodies whose
		# sessions no longer exist, and the next kill would credit a ghost.
		for userid in _joined.keys():
			var session := server.session_by_userid(int(userid)) if server != null else null

			if session != null and bridge != null and is_instance_valid(bridge):
				bridge.remove_peer(session.peer_id)
			else:
				game.remove_player(int(userid))

	_joined.clear()

	# The platform module is loaded by this one and has to go with it. Left behind, it
	# holds admissions for a game that no longer exists and its commands answer about
	# a hub nothing is feeding.
	if server != null and server.modules != null and server.modules.has_module("platform"):
		var unloaded := server.modules.unload_module("platform")
		DotLog.result(CHANNEL, "unloading the platform module", unloaded)


## [b]Admission finishes AFTER a player is seated[/b], so the name and figure they are seated with are a guest's whenever the profile store is slower than the join. `player_admitted` is the moment the real ones exist;
## a new avatar and an operator's `platform_name` are the same thing later. All three end in a JOIN to every client, which a client already applies to a player it has.
func _wire_identity() -> void:
	if bridge == null:
		return

	bridge.avatar_fn = _avatar_for
	if game.progress != null:
		game.progress.session_fn = server.session_by_userid
	hook_post("player_admitted", _on_profile)
	hook_post("player_avatar_changed", _on_profile)
	hook_post("player_renamed", _on_profile)


## What a session looks like: what dot-platform resolved for them, or null for the stock
## figure. Through `player_for`, because the hub keys a player by their scoped profile key.
func _avatar_for(session_id: int) -> DotAvatar:
	var session := server.session_by_userid(session_id) if server != null else null
	var platform: Object = server.modules.get_module("platform") \
		if server != null and server.modules != null else null

	if session == null or platform == null or not platform.has_method("player_for"):
		return null

	var held: Variant = platform.call("player_for", session)

	if held is Object and (held as Object).get("avatar") is DotAvatar:
		return (held as Object).get("avatar") as DotAvatar

	return null


func _on_profile(event: DotEvent) -> void:
	var session_id := event.get_int("userid")
	var session := server.session_by_userid(session_id) if server != null else null

	if session == null or bridge == null:
		return

	bridge.refresh_player(session_id, session.display_name, _avatar_for(session_id))


## A client finished the signon and is in the world. [b]`client_spawn`, not `client_connected`.[/b] A connected client has a socket and nothing else (no identity, no content, no confirmation it can load the map),
## so adding them to the match there produces a body for someone who may still fail to join.
func _on_client_spawn(event: DotEvent) -> void:
	# [b]`client_spawn` carries `userid` and `name`, not `peer_id`.[/b] Reading `event.get_int("peer_id")` gives 0 on every event, so `session_of(0)` returned null and nobody ever joined a dedicated arena server, silently;
	# a null session is legitimate, so nothing errored, and `dedicated.tscn` never connects a client. The family's notes carry this bug, found in game-hungario.
	var session := server.session_by_userid(event.get_int("userid"))

	if session == null:
		return

	# dot-moderation's records, checked here rather than at connect. [b]dot-server has its own ban list and this is not it.[/b] Its mute is two booleans on a session that dies with its connection, so a muted player reconnects and talks;
	# dot-moderation's records are durable, expiring and scoped. Both are consulted: dot-server's admission runs first and this is the second gate.
	if services != null:
		var admitted := services.check_admission(session)

		if not admitted.ok:
			server.kick(session, admitted.error.message)
			return

	_add(session)


func _add(session: DotClientSession) -> void:
	if _joined.has(session.userid):
		return

	# The session id, not the peer id: a peer id is reassigned when someone reconnects, and the scoreboard, combat entity and damage attribution would go to the next player to join. dot-server's userid is stable for the session.
	# Through the bridge, which adds them to the game AND registers them as a replicated entity owned by their peer. `game.add_player` alone gives the server a player nothing is sent about:
	# the manager only builds snapshots and input buffers for peers it knows, so the server would simulate them perfectly and alone.
	game.loadout_identity.bind(session)
	var added := bridge.add_player(
		session.peer_id, session.userid, session.display_name
	)

	if not added.ok:
		log_warn("could not add a player to the match", {
			"userid": session.userid, "error": str(added.error)
		})
		return

	_joined[session.userid] = true

	var loadouts := DotGameAvatarActionRelay.loadouts_of(net)
	if loadouts != null:
		loadouts.add_peer(session.peer_id)

	if loading != null:
		var _seated := loading.add(session)

	# Chat, voice and map changes, all keyed on the PEER because all three are about a
	# connection rather than about a person: a chat backlog goes to a socket, a voice
	# frame is relayed to a socket, and a map change waits on a socket.
	if services != null:
		services.add_peer(session.peer_id)

	# Not the map sync: that admits the peer when it says READY (`bridge.peer_ready_fn`),
	# because admitting tells it the current map and nothing reaches a client before then.

	log_info("player joined the match", {
		"userid": session.userid, "name": session.display_name
	})


func _on_client_disconnected(session: DotClientSession, _reason: String) -> void:
	if not _joined.has(session.userid):
		return

	# Through the bridge again: it releases the peer's entities, its input buffer and
	# its acknowledgement record as well as taking the player out of the match.
	bridge.remove_peer(session.peer_id)
	_joined.erase(session.userid)
	game.loadout_identity.release(session.userid)

	var loadouts := DotGameAvatarActionRelay.loadouts_of(net)
	if loadouts != null:
		loadouts.remove_peer(session.peer_id)

	if loading != null:
		loading.remove(session)

	if services != null:
		services.remove_peer(session.peer_id)

		# Who they were frozen or noclipped by, and where a bring would return them to.
		# The next player given this userid must not inherit any of it.
		if services.mod_tools != null:
			services.mod_tools.forget(StringName(str(session.userid)))

	if maps != null:
		# Otherwise the next map change waits out its whole timeout for somebody who
		# left — `swap_without_stragglers` saves it, but only after five minutes of
		# everybody standing on a map the vote already replaced.
		maps.remove_peer(session.peer_id)

	if vote != null:
		# Their rock-the-vote and their nominations. `rtv_forgets_leavers` is what
		# decides whether the tally shrinks with them, and it cannot do its job if
		# nothing tells it they went.
		vote.forget_voter(StringName(str(session.userid)))


func _on_player_killed(entry: DotKillFeed.Entry) -> void:
	# The server log, not chat: every client draws the kill feed top-right, so a chat
	# line repeated it (owner 2026-11-10). A headless operator still reads kills here.
	log_info("kill", {"line": str(entry)})


## A player typed `!something`. [b]Claimed, or it is broadcast as chat.[/b] dot-chat holds a command until somebody says they handled it;
## an unclaimed one with `broadcast_unknown_commands` off is dropped, so a player typing `!rtv` on a server where the vote failed to load gets silence rather than "there is no vote here".
func _on_chat_command(peer: int, command: String, args: PackedStringArray) -> void:
	var session := server.session_of(peer)

	if session == null:
		return

	# [b]The vote's own commands are not here.[/b] `!rtv`, `!nominate`, `!vote`, `!nextmap` and `!timeleft` are dot-vote's, registered on the console by `ArenaVote.install_commands` with `.with_chat()`, and an unclaimed `!` line carries on to the console.
	# Answering them here as well made two paths to one director, one without `setnextmap`. Only a server whose vote did not load answers them here, so a player gets "no vote" rather than silence.
	if vote == null:
		match command:
			"rtv", "nominate", "vote":
				_reply_chat(peer, "There is no vote on this server.")
				services.claim_command()
				return
			"nextmap":
				_reply_chat(
					peer, "Next: %s" % (maps.next_map_hint() if maps != null else "-")
				)
				services.claim_command()
				return
			"timeleft":
				_reply_chat(peer, _timeleft_line())
				services.claim_command()
				return

	match command:
		"score":
			for line in game.match_node.scoreboard.describe_lines():
				_reply_chat(peer, line)
			services.claim_command()
		"stats":
			for line in _stat_lines(session.userid):
				_reply_chat(peer, line)
			services.claim_command()


func _timeleft_line() -> String:
	if vote != null:
		return vote.director.clock.timeleft_line()

	if maps == null or maps.session == null:
		return "This map has no time limit."

	return maps.session.time_limit.timeleft_line()


func _stat_lines(userid: int) -> PackedStringArray:
	var out := PackedStringArray()

	if game.progress == null:
		out.append("This server keeps no statistics.")
		return out

	var values := game.progress.session_values(userid)

	out.append("This session: %d kills, %d deaths, %.0f%% accuracy" % [
		int(values.get_value(ArenaStats.KILLS, 0.0)),
		int(values.get_value(ArenaStats.DEATHS, 0.0)),
		ArenaStats.accuracy_of(values) * 100.0,
	])
	out.append("Achievement points: %d" % game.progress.points_of(userid))

	return out


func _reply_chat(peer: int, text: String) -> void:
	if services != null:
		services.notice(peer, text)
		return

	var session := server.session_of(peer)

	if session != null and server.chat != null:
		server.chat.send_system_to(session, text)


## The map changed, whatever caused it: a vote, a rotation, or an admin typing it. [b]This is the one call site that tells the vote what is running, and having two is the bug.[/b]
## `DotVoteDirector.begin_on_apply` is off so this signal is the only source: it fires for an operator's `arena_map` as well as a voted change,
## and both firing means two play-history entries for one play, a "not in the last five" cooldown that is quietly two or three.
func _on_map_changed(map: DotMapDef) -> void:
	if map_config == null and console != null:
		map_config = ArenaMapConfig.build(console)
	if map_config != null:
		map_config.apply(String(map.id))

	# Every client covers for the new map and says so when it lifts; until it does nobody is
	# harmed, and one that never re-covers is released after the roster's grace.
	if loading != null:
		loading.mark_reloading()

	if vote != null:
		vote.note_changed()

	# [b]Every `return` point is a place on the map that just went.[/b] DotModTools keeps a stack of positions per player; without this `return Ada` after a change put her where she had stood on the previous map,
	# inside whatever the new one has there (`[modtools-return-1]`; playground, hungario and the lobby do the same).
	if services != null and services.mod_tools != null:
		services.mod_tools.clear_history()

	if services != null:
		services.announce("Now playing %s." % map.name_or_id())

	_report_map(String(map.id))
	_attach_visibility(map)

	log_info("map changed", {"map": String(map.id)})


## The converted world's PVS as the snapshot visibility (cvar net_visibility); a built-in map clears it.
## [param map] is untyped: ArenaMap is not a DotMapDef subclass (as in arena_map_io).
func _attach_visibility(map) -> void:
	if net == null or map == null or DotAddonApi.build_level("dot_game") < 52:
		return
	var mesh: Object = null
	if map.has_method(&"is_imported") and map.is_imported():
		var prefix := ArenaBspMap.world_prefix(String(map.id), String(map.manifest_path).get_base_dir())
		var got: DotResult = DotMapBspMesh.load_prefix(prefix) if not prefix.is_empty() else null
		mesh = got.value if got != null and got.ok else null
	var on: bool = (DotGameNetcode as GDScript).call(&"attach_visibility", net, mesh)
	log_info("snapshot visibility", {"map": String(map.id), "in_force": on})


## Tells dot-server which map this is, so A2S and DQP print it in their map field (and
## the backbone report does too) rather than this game's content id.
func _report_map(map_id: String) -> void:
	if server != null and server.games != null:
		server.games.set_current_map(map_id)


## The map's clock ran out. The director deliberately does not act on it: on a server with a vote the answer is "open the ballot" and on one without it is "next in rotation",
## and only this file knows which this server is.
func _on_map_over(_map: DotMapDef, reason: StringName) -> void:
	if vote != null:
		var opened := vote.director.open_vote(reason)

		if opened.ok:
			return

		log_info("the map is over and a vote could not open", {
			"why": opened.error.message
		})

	if maps != null:
		var changed: DotResult = await maps.change_to_next(game.players().size())
		DotLog.result(CHANNEL, "changing to the next map", changed)


## The commands that only exist once the optional halves loaded. Registered after them rather than beside the others,
## because a command that reports on a subsystem that failed to load can only answer "that is not running", and an operator reading the command list should see what this server has.
func _add_extra_commands() -> void:
	if maps != null:
		# CHANGEMAP and nothing else, like g2gfast's. A map change ends every round in progress, which is about who may do it, not where they typed it, and the flag settles that on every source alike.
		# `sv_chat_commands 0` makes it console-only for a deployment that wants it.
		add_command(
			"arena_map", _cmd_map,
			"Change the map: arena_map <id>", DotAdminFlags.CHANGEMAP
		)
		add_command(
			"arena_nextmap", _cmd_nextmap, "What plays next", ""
		)

		# `map`, `maps` and `mapinfo` come from dot-map itself (dot-server's `map` changed the GAME, which is not what an operator typing `map` means); dot-server's game change is `changelevel`, `game` and `gamechange`.
		# `allow_chat_change` stays at its default, ON, matching `arena_map`: CHANGEMAP decides who may end a round in progress, wherever typed. A relayed website command arrives as `Source.CHAT`;
		# `DotChatRelayConfig.command_source` can promote a relay to RCON. The SYNC HOST is the changer, not the session: `ArenaMapDirector.session` alone swaps the world in this process and tells nobody.
		var map_commands := DotMapCommands.new()
		map_commands.session = maps.session
		map_commands.changer = maps.sync
		map_commands.player_count_fn = func() -> int:
			return game.players().size() if game != null else 0
		map_commands.rotation_file_fn = func() -> DotMapRotationFile:
			return maps.rotation_file if maps != null else null
		map_commands.spec_fn = _rotation_commands
		map_commands.bind(self)

	if vote != null:
		add_command(
			"arena_vote", _cmd_vote, "Open a vote now", DotAdminFlags.VOTE
		)

		var commanded := vote.install_commands(self)
		DotLog.result(CHANNEL, "the vote's commands", commanded)

	if services != null:
		add_command(
			"arena_services", _cmd_services,
			"Show chat, voice and moderation", DotAdminFlags.GENERIC
		)

	if identity != null:
		add_command(
			"arena_identity", _cmd_identity,
			"Show the platform layer", DotAdminFlags.GENERIC
		)

	if game.progress != null:
		add_command(
			"arena_boards", _cmd_boards, "Show a leaderboard: arena_boards [id]", ""
		)

	if game.horde != null:
		add_command(
			"arena_horde", _cmd_horde,
			"Show or clear the monsters: arena_horde [clear]", DotAdminFlags.GENERIC
		)


func _cmd_map(ctx: DotCmdContext) -> void:
	if ctx.args.is_empty():
		ctx.reply("Usage: arena_map <id>")
		return

	var changed: DotResult = await maps.change_to(StringName(ctx.args[0]))
	ctx.reply("Changed." if changed.ok else changed.error.message)


func _cmd_nextmap(ctx: DotCmdContext) -> void:
	ctx.reply("Next: %s" % maps.next_map_hint())
	ctx.reply(_timeleft_line())


func _cmd_vote(ctx: DotCmdContext) -> void:
	var opened := vote.director.open_vote(DotVoteClock.REASON_MANUAL)
	ctx.reply("Vote opened." if opened.ok else opened.error.message)


func _cmd_services(ctx: DotCmdContext) -> void:
	for line in services.describe_lines():
		ctx.reply(line)


func _cmd_identity(ctx: DotCmdContext) -> void:
	for line in identity.describe_lines():
		ctx.reply(line)


func _cmd_boards(ctx: DotCmdContext) -> void:
	# A remote board takes a moment; say so rather than leave the console silent.
	if game.progress.boards.backend == "backbone":
		ctx.reply("Fetching the board...")

	var board_id: StringName = (
		StringName(ctx.args[0]) if not ctx.args.is_empty() else ArenaBoards.KILLS
	)
	var scope := ArenaBoards.scope_for(game.mode.id if game.mode != null else &"ffa")
	var page := await game.progress.boards.page_async(board_id, scope, 0, 10)

	if not page.ok:
		ctx.reply(page.error.message)
		return

	var board := game.progress.boards.board_for(board_id, scope)
	var rank := 0

	for entry in (page.value as Array):
		rank += 1
		ctx.reply("%2d. %-20s %s" % [
			rank,
			(entry as DotLeaderboardEntry).player_name,
			board.format_value((entry as DotLeaderboardEntry).value),
		])

	if rank == 0:
		ctx.reply("Nobody is on that board yet.")


func _cmd_horde(ctx: DotCmdContext) -> void:
	if not ctx.args.is_empty() and ctx.args[0] == "clear":
		ctx.reply("Removed %d monster(s)." % game.horde.clear())
		return

	for line in game.horde.describe_lines():
		ctx.reply(line)
