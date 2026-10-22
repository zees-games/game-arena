extends Node

const ArenaAvatars := preload("../game/arena_avatars.gd")
const ArenaBrowser := preload("../game/arena_browser.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaModule := preload("../game/arena_module.gd")
const ArenaServer := preload("../game/arena_server.gd")
const ArenaServices := preload("../game/arena_services.gd")
const ArenaVote := preload("../game/arena_vote.gd")
const ArenaVoteSource := preload("../game/arena_vote_source.gd")

## A real [DotServer], listening, with the arena loaded into it.
##
## [codeblock]
## godot --headless --path . res://examples/dedicated.tscn
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]What this proves that [code]headless_match[/code] cannot.[/b] That test drives an
## [ArenaGame] directly and never opens a socket. This boots a [DotServer], binds a
## port, loads [ArenaModule] into it, and exercises the module's own surface — its
## console commands, its cvar, its session bookkeeping and its unload path.
##
## dot-platform found two long-standing dot-server bugs the first time it did
## something like this, neither of which was reachable from dot-server's own 104-check
## suite. **A code path only one deployment shape reaches is a code path nothing has
## run**, and a module loaded by no server is exactly that.
##
## It does not connect a client. dot-platform already runs that seam — a real
## `DotClientLink` over a real socket into a real `DotServer` — and repeating it here
## would test dot-server rather than this game.

const PORT := 27078
const SERVER_DIR := "user://arena_dedicated"

## The app's URL segment on the website, which is this game's code name.
##
## Unique and lowercase because the site already made it so. Display only — a
## listing prints it to say which game this is, and nothing treats it as proof.
const APP_URL := "arena"

## Every check this suite runs. It has no section counter, so this is its only guard
## against a runtime error that aborts a test function part-way: the checks after the
## error never happen, the ones before it still print ok, and "N passed, 0 failed" cannot
## show the difference. See docs/testing.md.
const CHECKS := 181

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

var _server: DotServer = null
var _game: ArenaGame = null

## What the bridge sent to the sessions this suite adopts with no socket behind them,
## caught on the link's loopback instead of going out as an `rpc_id`. See
## [method _test_client_spawn].
var _caught: Array[Dictionary] = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena dedicated server")
	print("")

	var probe: Array = []
	if not _is_exit_probe():
		probe = await _run_exit_probe()

	# A member's site avatar, translated into this game's schema. The site's document is the
	# Kenney skins spelt `skin-c`; without a translation every member is stock here.
	var site_avatars = preload("res://game/arena_avatars.gd")
	var site_doc := DotAvatar.make(&"builtin")
	site_doc.set_part(&"top", &"skin-c")
	site_doc.set_part(&"face", &"skin-k")
	var as_ours: DotAvatar = site_avatars.from_site(site_doc)
	_check(
		as_ours != null and site_avatars.schema().validate(as_ours).ok and as_ours.part_in(&"body") == &"arena_body_kenney_c" and as_ours.part_in(&"head") == &"arena_head_kenney_k",
		"a member's site avatar becomes this game's, and its schema accepts it",
		str(as_ours.to_dict()) if as_ours != null else "null"
	)
	var unknown_skin := DotAvatar.make(&"builtin")
	unknown_skin.set_part(&"top", &"skin-z")
	unknown_skin.set_part(&"face", &"skin-z")
	var not_site := DotAvatar.make(&"elsewhere")
	not_site.set_part(&"top", &"skin-c")
	_check(
		site_avatars.from_site(unknown_skin) == null and site_avatars.from_site(not_site) == null,
		"a skin this game does not draw, or a document that is not the site's, is stock"
	)

	_cleanup()

	var built := await _build()

	if built:
		_test_module_loaded()
		_test_client_spawn()
		await _test_services()
		await _test_maps_and_vote()
		_test_map_rotation_file()
		_test_finish_round_waits_for_a_live_round()
		_test_query()
		await _test_browser()
		_test_commands()
		_test_match_cvars()
		await _test_loadout_command()
		await _test_bots()
		_test_unload()
		_test_no_message_preloads_itself()

	if not probe.is_empty():
		_test_exits_clean(probe)

	_teardown()
	_cleanup()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	# The copy of this suite that the exit probe runs does not run the probe itself.
	var checks := CHECKS - (EXIT_PROBE_CHECKS if _is_exit_probe() else 0)

	if _passed + _failed != checks:
		print("ERROR: %d checks ran, %d expected. A test aborted part-way." % [
			_passed + _failed, checks
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _cleanup() -> void:
	DotPaths.remove_tree(SERVER_DIR)


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else " — " + detail])
	return condition


# --- Bring-up --------------------------------------------------------------

func _build() -> bool:
	print("booting")

	# The game first, and registered: ArenaModule finds it through DotRegistry rather
	# than being handed it, which is what makes `load_module(path)` work at all —
	# dot-server loads a module from a script path and has nowhere to pass an argument.
	_game = ArenaGame.new()
	_game.name = "Arena"
	_game.tick_rate = 64
	_game.score_limit = 25
	_game.headless = true
	_game.register_service = true
	add_child(_game)

	var ready := _game.setup(ArenaMap.dm_box())

	if not _check(ready.ok, "the arena sets up", str(ready.error)):
		return false

	_check(
		DotRegistry.get_node_service(ArenaGame.SERVICE) == _game,
		"and registers itself so a module can find it"
	)

	var config := DotServerConfig.new()
	config.hostname = "arena dedicated"
	config.port = PORT
	config.bind_address = "127.0.0.1"
	# Empty means the RCON listener does not open, which is what a test wants and is
	# also what dotserve treats as "RCON is off" rather than as a weak password.
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % SERVER_DIR
	config.bans_path = "%s/bans.json" % SERVER_DIR
	config.audit_log_path = "%s/audit.jsonl" % SERVER_DIR
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""
	# The query listener, which `_test_browser` needs. On by default on a real server;
	# named here so a suite that stopped exercising it fails rather than skipping.
	config.query_enabled = true
	config.query_port = PORT + 1
	# A self-test takes no commands, and its stdin is whatever the runner left open — for the
	# exit probe's copy, a pipe this suite holds for as long as it waits. The console's reader
	# thread blocks in `read_string_from_stdin`, which nothing can wake, and a process with a
	# reader blocked on an open pipe prints its whole result, its leak report, and then never
	# exits: the copy ran to its deadline on every run until this was off.
	# Kept after dot-server 5f46687, which no longer reads a pipe unless `stdin_console_pipes`
	# is on: a terminal is still read, and a suite takes no commands from either.
	config.stdin_console_enabled = false

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	add_child(_server)

	# The query responder is its own addon now, and a server only answers queries
	# if one is plugged in. `_test_browser` asks this server over a real UDP
	# socket, so without the host that section fails rather than skipping — which
	# is the right way round.
	var query_host := DotQueryHost.new()
	query_host.name = "QueryHost"
	query_host.app_url = APP_URL
	query_host.server_ref = DotNodeRef.of_path(NodePath("../Server"))
	add_child(query_host)

	var booted: DotResult = await _server.boot()

	if not _check(booted.ok, "the server boots and listens on %d" % PORT, str(booted.error)):
		return false

	# Into this run's own directory, which is deleted on the way in and out. Before this
	# line every run wrote an hour-long gag into the store a real server enforces.
	ArenaModule.punishments_file = "%s/punishments.json" % SERVER_DIR

	var loaded: DotResult = await _server.modules.load_module(
		"res://game/arena_module.gd"
	)

	if not _check(loaded.ok, "the arena module loads into it", str(loaded.error)):
		return false

	return true


func _teardown() -> void:
	if _server != null and is_instance_valid(_server):
		_server.shutdown("test over")
		remove_child(_server)
		_server.queue_free()

	if _game != null and is_instance_valid(_game):
		remove_child(_game)
		_game.queue_free()


# --- Checks ----------------------------------------------------------------

func _test_module_loaded() -> void:
	print("")
	print("the module")

	_check(_server.modules.has_module("arena"), "is listed among the server's modules")

	var module := _server.modules.get_module("arena") as ArenaModule
	_check(module != null, "and is an ArenaModule")

	if module == null:
		return

	_check(module.game == _game, "holding the game it found in the registry")
	_check(ArenaServer.host_tick_rate() == _server.config.tickrate,
		"the server scene declares the host's sv_tickrate", "%d vs %d" % [ArenaServer.host_tick_rate(), _server.config.tickrate])
	var spacing := PackedStringArray()
	for rate in [30, 60, 64, 120, 128]:
		var snaps := ArenaGame.snapshot_rate_for(rate)
		if rate % snaps != 0 or absi(snaps - ArenaGame.NET_SNAPSHOT_RATE) > 6:
			spacing.append("%d->%d" % [rate, snaps])
	_check(spacing.is_empty(), "snapshots are a whole number of ticks apart near 32 a second", ", ".join(spacing))

	# The registration helpers exist so that unloading is safe by construction. A
	# module that registered directly would leave a console command pointing at a
	# freed object, and the console would crash the server the next time anyone ran
	# it.
	for command in ["arena_status", "arena_score", "arena_restart"]:
		_check(
			_server.console.find_command(command) != null,
			"registered %s" % command
		)

	_check(
		_server.console.find_cvar("arena_scorelimit") != null, "and its cvar"
	)

	# The NPC skill cvars, on a real console. A fake in dot-npc-ai's suite proves the
	# binding's arithmetic; only this proves `add_cvar` hands back something it can bind to.
	_check(
		_server.console.find_cvar("npc_skill") != null
			and _server.console.find_cvar("npc_reaction_scale") != null
			and _server.console.find_cvar("npc_reaction_min") != null,
		"and the three NPC skill cvars"
	)

	# Shooting through team-mates, the operator's: dot-combat's cvar on the world's own rules.
	var through := _server.console.set_cvar("mp_teammate_passthrough", "2")
	_check(
		through.ok and _game.combat.rules.pass_through_team_mates
			and _game.combat.rules.pass_through_team_mate_at_muzzle,
		"and `mp_teammate_passthrough 2` at the console reaches the damage rules",
		str(_game.combat.rules.describe())
	)
	_check(
		_server.console.find_cvar("mp_teammate_passthrough").has_flag(DotConVar.FLAG_REPLICATED)
			and _server.console.replicated_values().get("mp_teammate_passthrough", "") == "2",
		"and it is replicated: every client is sent the server's level",
		str(_server.console.replicated_values())
	)
	# A map change builds a new combat manager; the operator's level has to survive it, or a
	# server on 2 is back on 1 from the second map on.
	var rebuilt := _game.change_map(_game.map)
	_check(
		rebuilt.ok and _game.combat.rules.pass_through_level() == 2,
		"and it survives a map change, which builds a new combat manager",
		"%s, level %d" % [str(rebuilt.error) if not rebuilt.ok else "ok", _game.combat.rules.pass_through_level()]
	)
	var _never := _server.console.set_cvar("mp_teammate_passthrough", "0")
	_check(_game.combat.rules.pass_through_level() == 0, "and a change after it reaches the new manager")
	var _back := _server.console.set_cvar("mp_teammate_passthrough", "1")

	var harder := _server.console.set_cvar("npc_skill", "hard")
	_check(
		harder.ok and is_equal_approx(_game.npc_skill.skill, 0.5),
		"and `npc_skill hard` at the console reaches the monsters' skill"
	)
	_check(
		not _server.console.set_cvar("npc_skill", "hrad").ok
			and is_equal_approx(_game.npc_skill.skill, 0.5),
		"and a typo is refused rather than ignored"
	)
	var _reset := _server.console.set_cvar("npc_skill", "0")

	# dot-map's own commands, on a real console. `map` was dot-server's and it changed the
	# GAME; on a server running one game and several maps that is the one thing an operator
	# typing it does not mean.
	for command in ["map", "maps", "mapinfo"]:
		_check(
			_server.console.find_command(command) != null,
			"and dot-map's %s" % command
		)
	_check(
		_server.console.find_command("game") != null,
		"while `game` is what changes the game, which is what dot-server's `map` used to do"
	)

	# It read "NOT typable in chat" until `sv_chat_commands` landed. Ending a round in
	# progress is still a thing only CHANGEMAP does — what changed is that the flag is what
	# says so, on the line where it was typed, instead of a prefix check that ran first and
	# never looked at who was asking.
	var map_command := _server.console.find_command("map")
	_check(
		map_command != null
			and map_command.permission == DotAdminFlags.CHANGEMAP
			and map_command.allows_chat(_server.console.chat_commands_are_open()),
		"and changing the map is typable in chat by whoever holds changemap, and nobody else"
	)


# --- The rest of the server -------------------------------------------------

## Chat, voice, moderation and the identity chain, on a real server.
##
## [b]Every one of these five addons passes its own suite with a stub host.[/b] What is
## untested anywhere else is that they can all be brought up in one process against one
## [DotServer] — and specifically that dot-moderation is up before the two routers that
## look up its `dot_mute_source`, because a router that starts first finds nothing,
## warns once, and then enforces no gag for the life of the server.
func _test_services() -> void:
	print("")
	print("chat, voice and moderation")

	var module := _server.modules.get_module("arena") as ArenaModule

	if not _check(module != null and module.services != null, "the services layer is up"):
		return

	var services := module.services

	_check(services.chat != null, "chat is running")
	_check(services.voice != null, "voice is running")

	# The operator's switch: registered by the module, replicated so clients hide their key,
	# and enforced on the router.
	var voice_cvar: DotConVar = _server.console.find_cvar("sv_voice_enable")
	_check(voice_cvar != null and DotConsole.is_replicated(voice_cvar),
		"sv_voice_enable is registered and replicated to clients")
	var off_enabled := true
	if voice_cvar != null and services.voice != null:
		var _off := voice_cvar.set_value("0")
		off_enabled = services.voice.enabled
		var _on := voice_cvar.set_value("1")
	_check(not off_enabled and services.voice != null and services.voice.enabled, "and turns the router off and on")
	_check(services.moderation != null, "moderation is running")

	# The registry names, which are how the three reach each other without importing
	# one another. dot-moderation publishes both; dot-chat's router and dot-voice's
	# router each look one of them up.
	_check(
		DotRegistry.get_service(DotModerationManager.MUTE_SERVICE) != null,
		"and it published a mute source for the two routers to find"
	)
	_check(
		DotRegistry.get_service(DotModerationManager.BAN_SERVICE) != null,
		"and a ban source for the admission check"
	)

	# Four channels, and the one that matters is the radius channel: it is the only
	# one whose audience the players can change by moving.
	var ids := services.chat.channel_ids()
	_check(
		ids.size() == 4,
		"four chat channels are installed",
		", ".join(PackedStringArray(ids.map(func(x: StringName) -> String: return String(x))))
	)
	_check(
		services.chat.has_channel(ArenaServices.CH_NEAR),
		"including a radius channel"
	)

	var near := services.chat.channel(ArenaServices.CH_NEAR)
	_check(
		near != null and near.scope == DotChatChannel.Scope.RADIUS,
		"which really is scoped by distance"
	)

	# The rules. Markup escaping is not cosmetic: a chat line is drawn by a client
	# that may render BBCode, so a player who can write markup can write something
	# that looks like a server announcement.
	_check(services.chat.rules.escape_markup, "markup is escaped")
	_check(services.chat.rules.strip_invisible, "and invisible characters stripped")

	var dirty := DotChatFilter.sanitise(
		"[color=red]server[/color]: free stuff", services.chat.rules
	)
	_check(
		dirty.ok and not String(dirty.value).contains("[color=red]"),
		"and a player cannot write a colour tag",
		str(dirty.value)
	)

	# --- Moderation, which is the whole reason it is not dot-server's mute ---
	#
	# dot-server's mute is two booleans on a session object and a session dies with
	# its connection, so a muted player reconnects and talks. A punishment is a record.
	var subject := DotPunishmentSubject.for_uid("4242")

	# [b]The store, and that it is empty before this run writes to it.[/b] The gag below is
	# an hour long against a fixed uid, so a suite that carried its store between runs would
	# find this person already gagged and could not tell its own gag from the last one.
	var store: Object = services.moderation.store
	var store_path := str(store.get("path")) if store != null else ""
	_check(store_path.begins_with(SERVER_DIR),
		"punishments go to this run's own store, not the one a real server enforces", store_path)
	_check(services.moderation.count() == 0,
		"and it starts empty, so nothing a previous run did is in it",
		"%d records" % services.moderation.count())

	# Awaited, and typed. A punishment store may be a shared database behind a
	# community's four servers — the whole reason both halves of the interface are
	# allowed to be coroutines — and an un-awaited one returns at its first suspension.
	var issued: DotResult = await services.moderation.issue(
		DotPunishment.Kind.GAG, subject, "testing", "suite", 3600
	)

	_check(issued.ok, "a gag can be issued", str(issued.error))
	_check(
		services.moderation.is_gagged_key(subject),
		"and it is held against the person rather than the connection"
	)

	# The unconfigured scope is the case a one-server community always has, and it is
	# the one dot-moderation once had silently enforcing nothing.
	_check(
		services.server_scope == "",
		"this server has no scope, which is the case that has to work"
	)

	# Revoked by ID, not by subject: one person may hold a gag, a mute and a ban at
	# once, and "lift the punishment on this person" is not a question with one answer.
	var record: DotPunishment = issued.value if issued.ok else null
	var lifted: DotResult = (
		await services.moderation.revoke(record.id, "suite", "over")
		if record != null
		else DotResult.fail(DotError.CODE_STATE, "nothing was issued")
	)
	_check(lifted.ok, "and it can be lifted again", str(lifted.error))
	_check(
		not services.moderation.is_gagged_key(subject),
		"leaving nothing behind"
	)

	# --- Identity ---------------------------------------------------------

	if _check(module.identity != null, "the identity layer is up"):
		_check(module.identity.platform != null, "with a platform hub")
		_check(
			DotRegistry.get_node_service(DotPlatformHub.SERVICE) != null,
			"registered, which is how dot-platform's module finds it"
		)
		_check(
			_server.modules.has_module("platform"),
			"and dot-platform's own module is loaded beside this one"
		)

		# Never null, for anybody. A caller that had to branch on "did this player
		# have an avatar" is a caller that draws nothing for a guest.
		var stock := module.identity.avatar_for("arena-player-00000007")
		_check(stock != null, "every player has an avatar, their own or a stock one")

		var conformed := ArenaAvatars.schema().conform(stock, null)
		_check(
			conformed.ok,
			"and a stock avatar conforms to the schema it was built from",
			str(conformed.error)
		)


## maps.yml on the live module: a map outside the active rotation stays installed and is never
## chosen, balloted or nominated; a rotation switch takes effect; a renamed command exists.
func _test_map_rotation_file() -> void:
	print("")
	print("maps.yml")

	var module := _server.modules.get_module("arena") as ArenaModule

	if not _check(module != null and module.maps != null and module.vote != null, "the module has maps and a vote"):
		return

	var maps := module.maps
	var catalogue := maps.session.catalogue
	var built := DotMapRotationFile.from_trees([{"defaults": {
		"rotation": "two",
		"rotations": {
			"two": {"mode": "cycle", "cooldown": 0, "maps": ["dm_box", "dm_atrium"]},
			"pit": {"maps": ["dm_pit"]},
		},
		"commands": {"names": {"rtv": "rockthevote"}},
	}}], "game-arena")
	if not _check(built.ok, "a maps.yml with two rotations and a renamed rtv parses",
		"" if built.ok else built.error.message):
		return

	maps.rotation_file = built.value
	maps.apply_rotation()

	var box := catalogue.get_map(&"dm_box")
	var pit := catalogue.get_map(&"dm_pit")
	_check(box.in_rotation and not pit.in_rotation, "the active rotation puts dm_pit out and dm_box in")
	_check(catalogue.get_map(&"dm_pit") != null and ArenaMap.ids().has(&"dm_pit"),
		"and dm_pit stays installed and loadable")
	_check(not catalogue.available().has(pit) and catalogue.available().has(box),
		"available() leaves it out")

	# next-map: the pool and a hundred draws never show it, and it cannot be forced.
	var drew_pit := false
	for i in 100:
		var chosen := maps.session.rotation.choose(0)
		if chosen != null and chosen.id == &"dm_pit":
			drew_pit = true
	_check(not drew_pit, "100 draws of the next map never choose a map outside the rotation")
	maps.restrict_rotation()
	_check(not maps.session.rotation.order.has(&"dm_pit"),
		"restrict_rotation does not widen the file's list again")
	_check(not maps.set_next(&"dm_pit"), "and it cannot be forced as the next map")
	_check(maps.set_next(&"dm_box"), "while one in the rotation can")
	maps.session.rotation.clear_next()

	# the ballot and nominations
	var ids := module.vote.source.choices().map(func(c: DotVoteChoice) -> StringName: return c.id)
	_check(not ids.has(&"map:dm_pit"), "a map outside the rotation is not on the ballot")
	_check(ids.has(&"map:dm_box") or ids.has(&"map:dm_atrium"), "the maps inside it are")
	var nominated := module.vote.nominate(&"77", &"dm_pit")
	_check(not nominated.ok, "nominate refuses a map outside the rotation")
	_check(not module.vote.director.nominated_ids().has(&"map:dm_pit"), "and nothing was recorded")

	# a switch
	var switched := maps.rotation_file.switch(maps.session.rotation, "pit")
	_check(switched.ok and pit.in_rotation and not box.in_rotation,
		"switching to the pit rotation takes effect")
	var drew_box := false
	for i in 50:
		var chosen := maps.session.rotation.choose(0)
		if chosen != null and chosen.id != &"dm_pit":
			drew_box = true
	_check(not drew_box, "and the next map is drawn from the new one")
	ids = module.vote.source.choices().map(func(c: DotVoteChoice) -> StringName: return c.id)
	_check(not ids.has(&"map:dm_box"), "and the ballot follows it")
	_check(not maps.rotation_file.switch(maps.session.rotation, "nope").ok, "an unknown rotation is refused")

	# a renamed command
	var rtv := DotVoteCommands.new()
	rtv.director = module.vote.director
	rtv.spec_fn = module._rotation_commands
	rtv.with_map_menu = false
	var bound := rtv.bind(_server.console)
	_check(bound.ok and rtv.command_name("rtv") == "rockthevote"
		and _server.console.find_command("rockthevote") != null,
		"a renamed rtv command is registered from maps.yml's commands")
	var session := _server.session_by_userid(77)
	if _check(session != null, "the adopted player is still here"):
		var replies := PackedStringArray()
		var ctx := session.make_context(
			"rockthevote", PackedStringArray(), DotCmdContext.Source.CHAT,
			func(line: String) -> void: replies.append(line)
		)
		_server.console.execute("rockthevote", ctx)
		_check(not replies.is_empty(), "and answers", " ".join(replies))

	# No file again: everything back in, as before maps.yml.
	maps.rotation_file = null
	maps.apply_rotation()
	var all_in := true
	for def in catalogue.maps:
		all_in = all_in and def.in_rotation
	_check(all_in, "with no file every map is in rotation again")
	_check(module._rotation_commands.call().is_empty(), "and no command is renamed")


## dot-map and dot-vote, on a server with a rotation and a ballot.
func _test_maps_and_vote() -> void:
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

	# Both map clocks follow the server's hibernation: they wait while nobody is here and
	# start again from the top when somebody joins (dot-vote's and dot-map's own suites
	# assert what following does; this asserts the game wired it).
	_check(
		_server.hibernation_changed.is_connected(module.vote.director.set_hibernating),
		"the vote's clock follows the server's hibernation"
	)
	_check(
		_server.hibernation_changed.is_connected(module.maps.session.set_hibernating),
		"and so does the map director's fallback clock"
	)

	# Every choice id says what kind of change it is. A bare id would have to be
	# looked up in the map catalogue and then in the mode catalogue, which is a lookup
	# that silently does the wrong thing the day somebody names a mode after a map.
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

	# A player types `dm_atrium`, not `map:dm_atrium`. The qualifier resolves against
	# the ballot's own options rather than guessing.
	_check(
		module.vote.director.source.has(StringName("map:dm_atrium")),
		"dm_atrium is on the ballot"
	)

	# The cooldown. Two maps ship, so "not in the last five" would leave nothing to
	# offer — dot-vote caps it against the pool at runtime and the rules ask for one.
	_check(
		module.vote.director.rules.cooldown <= 1,
		"the cooldown fits a two-map catalogue",
		"%d" % module.vote.director.rules.cooldown
	)

	# `begin_on_apply` off is what stops one play being counted twice. Two entries in
	# the history for one play is a "last five" cooldown that is quietly two or three.
	_check(
		not module.vote.director.begin_on_apply,
		"and the director does not announce a change the host already announces"
	)

	# Opening one. With one player the quorum and `min_players_to_vote` decide whether
	# it can, so the assertion is that it answers rather than that it succeeds — a
	# refusal is a legitimate answer and the point is that the clock did not latch.
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

	# dot-vote's commands, which this game never installed. The operator's four did not
	# exist here at all, and the players' five were the module's own chat handler — a
	# second path to the director with none of the first's commands.
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
	# The adopted player has no client to say it has the map, and the sync host would wait
	# out its whole timeout for it (headless_admin's note), so it is off the host for the
	# change and back on after. Not awaited directly either: a suite that hung on a change
	# would say nothing at all.
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

	# Every row the menu lists is one the source offers, and a mode row chosen changes the
	# mode on the same map. Found by dot-server-deploy's burst_probe walking a list fetched
	# once: after a change to dm_pit the team-mode rows were refused as "There is no map
	# called 'mode:tdm'". A list from now offers only what can run now; a stale row is
	# refused with the reason (ArenaVoteSource.unavailable_reason).
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

	# One clock. The map director's used to run beside the vote's, and whichever expired
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


## [b]`time_up: finish_round` waits for a round being played, never for warmup.[/b] The game
## hands dot-vote its match's answer (`round_in_progress_fn`); without it a limit that ran out
## in warmup held the change for `finish_round_max_sec` over a round that had not started.
## Run on a director of its own carrying the game's own hook, so the real vote's clock is
## untouched; the match's state is set by hand and put back.
func _test_finish_round_waits_for_a_live_round() -> void:
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


## What a server browser is told.
##
## [b]dot-browser is the client half of this and it has never asked a real DotServer
## anything.[/b] This is the server half: a query provider contributing the numbers a
## person filtering a list actually filters on. Without one, a query says only that the
## game is called Arena.
func _test_query() -> void:
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


## dot-browser asking a real [DotServer] — which nothing in this family had done.
##
## [b]This is the seam the family's own notes name.[/b] dot-server has answered A2S and
## its own richer protocol since it was written; dot-browser's suite queries a DQP
## server over a real loopback socket. Neither had ever met the other, and by this
## family's repeated lesson that is where the next bugs are.
##
## The listening query port is the server's own, so this is a real UDP round trip
## between two objects in one process — which is exactly the deployment shape a player
## opening a server list is in, minus the distance.
func _test_browser() -> void:
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

	# The query port as a separate argument, not a third part of the string. A
	# three-part address parses as a malformed IPv6 one and fails at `connect_to_host`
	# with "Invalid IPv6 address", several layers below anything that could say what
	# was actually wrong.
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

		# The game half, which is what `ArenaModule`'s query provider contributes. A
		# `DotGameDescriptor` alone would say only that the game is called Arena — the
		# mode, the map and the state are the provider's, and until a browser asked,
		# nothing had ever read them.
		#
		# [b]It is NOT `entry.map`.[/b] That is dot-server's `info.map`, which means
		# "the content id of the loaded game" and is empty on a server that has never
		# switched games — so the first version of this check read it, got "", and
		# reported a browser fault for a browser that was working. dot-browser nests
		# the game's own section under `rules["game"]` precisely so a game putting a
		# field called `map` in it cannot overwrite the other one.
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


func _test_client_spawn() -> void:
	print("")
	print("a client spawning")

	# **`client_spawn` carries `userid` and `name`. It does not carry `peer_id`.**
	#
	# This module read `event.get_int("peer_id")` and looked the session up by it. That
	# is 0 on every event, `session_of(0)` is null, and a null session is a legitimate
	# thing to find — so the handler returned and **nobody ever joined a dedicated arena
	# server**, silently, for as long as this module has existed.
	#
	# This suite passed its twenty-one checks the whole time, because it never connected
	# a client. It still does not: connecting one is dot-platform's seam and repeating it
	# here would test dot-server. What it does instead is fire the event dot-server fires,
	# with the payload dot-server puts in it, and assert somebody joined — which is the
	# smallest thing that can tell the two spellings apart.
	var module := _server.modules.get_module("arena") as ArenaModule

	if not _check(module != null, "the module is loaded"):
		return

	var before := _game.player_ids().size()

	# `adopt_session` exists for exactly this: dot-server's own documentation calls it
	# "a test that needs the session table populated without a socket". Everything that
	# counts players counts sessions, so a participant without one is invisible to the
	# roster, the slots and the queries — and to `session_by_userid`, which is what the
	# module has to call.
	var session := DotClientSession.new()
	session.peer_id = 4242
	session.userid = 77
	session.display_name = "Ada"

	if not _check(_server.adopt_session(session).ok, "a session is adopted"):
		return

	# 4242 has no socket behind it, so everything the bridge sends it from here on (the
	# schema announcement on join, then a snapshot every server tick through the services,
	# maps, query and browser sections) was an `rpc_id` to a peer the multiplayer API has
	# never heard of, and every green run printed "Attempt to call RPC with unknown peer
	# ID: 4242" six times. Caught on the link's loopback instead, for the rest of the run
	# (the module's reload in `_test_unload` builds a new link without it): what was sent
	# becomes a check, and a real unknown-peer line in this suite's stderr is a real one.
	# `_test_bots` silences dot-net's own send for the same reason, before its sessions.
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

	# **The map sync admits a peer at its READY, and that admission is what names the map.**
	# The module used to register a joiner at the seat with `add_peer`, which only enrolls it
	# for the NEXT change, so a client that joined a server on any map but dm_box stayed on
	# dm_box until the next change: drawn on the wrong level, predicting against walls the
	# server did not have (4773e55). Nothing asserted the wiring; this is the module's own
	# path, seat then READY, read off the link.
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


func _test_commands() -> void:
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

	# A mode that does not exist is refused AND the cvar is put back. A cvar reading
	# `koth` on a server playing free-for-all is worse than one that refused, because
	# an operator believes it — and the put-back must not recurse through its own
	# `changed` signal.
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


## The match cvars on a real console: `arena_scorelimit` was registered and read by nothing,
## and there was no cvar for the time limit or warmup, so a config's numbers were ignored.
## `set_cvar` is the path a game.yml / content.yml value takes after the module loads (dot-
## server's descriptor cvars); `execute` is the console's and rcon's.
func _test_match_cvars() -> void:
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


## B's server half: the `loadout` command and the owner's mp_loadout_* cvars, enforced HERE,
## whatever a client's screen showed. From the session the client-spawn section adopted (77).
func _test_loadout_command() -> void:
	print("")
	print("the loadout command and the owner's rules")

	var cmd: Object = _game.loadout_command
	if not _check(cmd != null and _server.console.find_command("loadout") != null
			and _server.console.find_cvar("mp_loadout_allow") != null
			and _server.console.find_cvar("mp_loadout_fixed") != null
			and _server.console.find_cvar("mp_loadout_menu") != null,
			"the server has the loadout command and the owner's three cvars"):
		return
	var session := _server.session_by_userid(77)
	if not _check(session != null, "the adopted player is still here"):
		return

	var say := func(line: String) -> Dictionary:
		var words := line.split(" ", false)
		var ctx := session.make_context("loadout", words.slice(1), DotCmdContext.Source.CHAT, func(_l: String) -> void: pass)
		var _r := _server.console.execute(line, ctx)
		return cmd.get(&"last_result")

	var snipers := _server.console.execute("mp_loadout_allow primary=tag:scoped")
	var rifle: Dictionary = say.call("loadout primary=rifle")
	_check(snipers.ok and not bool(rifle.get("ok", true)),
		"with mp_loadout_allow primary=tag:scoped, a player's rifle is refused by the server", str(rifle))
	var marksman: Dictionary = say.call("loadout primary=marksman")
	var active: DotResult = await _game.loadouts.active_for(ArenaGame.storage_key(77))
	_check(bool(marksman.get("ok", false)) and active.ok and (active.value as DotLoadout).item_in(&"primary") == &"marksman",
		"and a scoped gun is taken and is what they spawn with", str(marksman))

	var typo := _server.console.execute("mp_loadout_allow barrel=rifle")
	_check(not typo.ok and _server.console.find_cvar("mp_loadout_allow").get_string() == "primary=tag:scoped"
			and _game.loadouts.rules != null and _game.loadouts.rules.allowed.has(&"primary"),
		"a value naming a slot that does not exist is refused at the console, and the rules stay", str(typo.error))

	var _fixed := _server.console.execute("mp_loadout_fixed primary=sniper")
	var _off := _server.console.execute("mp_loadout_menu 0")
	var locked: Dictionary = say.call("loadout primary=marksman")
	var spawned: DotResult = await _game.loadouts.active_for(ArenaGame.storage_key(77))
	_check(not bool(locked.get("ok", true)) and (spawned.value as DotLoadout).item_in(&"primary") == &"sniper",
		"locked by the owner, nobody chooses and everybody spawns with the fixed slot", str(locked))

	var _a := _server.console.set_cvar("mp_loadout_menu", "1")
	var _b := _server.console.set_cvar("mp_loadout_fixed", "")
	var _c := _server.console.set_cvar("mp_loadout_allow", "")
	_check(_game.loadouts.rules == null, "and emptied, the cvars are no restriction")


## Waits [param seconds] of the server's own physics ticks.
func _wait_ticks(seconds: float) -> void:
	for _i in int(seconds * Engine.physics_ticks_per_second):
		await get_tree().physics_frame


func _test_bots() -> void:
	print("")
	print("bots")

	var module := _server.modules.get_module("arena") as ArenaModule
	if not _check(module != null and module.bridge != null, "the module has a bridge to add bots through"):
		return

	_check(_server.console.find_cvar("bot_quota") != null and _server.console.get_string("bot_quota_mode", "") == "fill",
		"bot_quota is the module's and fill is the default", _server.console.get_string("bot_quota_mode", ""))

	# Everything sent between the client spawning and here went to 4242 alone, and the
	# snapshots did reach it: the loopback caught them rather than nothing being sent.
	var peers := {}
	var snapshots := 0
	for c: Dictionary in _caught:
		peers[c["peer"]] = true
		if c["method"] == &"snapshot":
			snapshots += 1
	_check(peers.keys() == [4242] and snapshots > 0,
		"the adopted session was sent its snapshots, and nobody else was sent anything",
		"%d snapshots, peers %s" % [snapshots, str(peers.keys())])

	# The sessions this suite adopts have no peer behind them, and seconds of ticking would
	# send each a snapshot an RPC error at a time; headless_admin does the same.
	if module.net != null:
		module.net.send_fn = func(_peer: int, _payload: PackedByteArray, _delivery: int) -> void:
			pass

	_server.console.execute("bot_quota 4")
	await _wait_ticks(2.5)
	var people := module._joined.size()
	var bots := module.bridge.bot_ids()
	_check(bots.size() == 4 - people, "fill: bots and people make four", "%d bots, %d people" % [bots.size(), people])
	_check(bots.size() > 0 and _game.player_for(bots[0]) != null and _game.player_for(bots[0]).has_meta(&"bot"),
		"a bot is a player in the game, marked as one")

	# A person joins and takes a bot's place.
	var session := DotClientSession.new()
	session.peer_id = 4343
	session.userid = 78
	session.display_name = "Bea"
	var _adopted := _server.adopt_session(session)
	_server.events.fire("client_spawn", {"userid": session.userid, "name": session.display_name})
	await _wait_ticks(1.5)
	_check(module.bridge.bot_ids().size() == bots.size() - 1, "a person joining takes a bot's place",
		"%d -> %d" % [bots.size(), module.bridge.bot_ids().size()])
	_check(not module.bridge.bot_ids().has(bots[bots.size() - 1]), "the newest bot is the one that goes")

	# And the bot comes back when they leave.
	_server.client_disconnected.emit(session, "test")
	await _wait_ticks(1.5)
	_check(module.bridge.bot_ids().size() == bots.size(), "and a bot comes back when they leave",
		"%d" % module.bridge.bot_ids().size())

	# They fight: within a few seconds one of them has fired at somebody it can see.
	var fired := false
	for _i in int(6.0 * Engine.physics_ticks_per_second):
		await get_tree().physics_frame
		for id in module.bridge.bot_ids():
			var behaviour := module.bridge.behaviour_for(id)
			if behaviour != null and behaviour.last_fire.is_pressed(DotWeaponCommand.BUTTON_ATTACK):
				fired = true
		if fired:
			break
	_check(fired, "the bots fight")

	_server.console.execute("bot_quota_mode off")
	await _wait_ticks(1.5)
	_check(module.bridge.bot_ids().is_empty(), "bot_quota_mode off takes them all out",
		"%d left" % module.bridge.bot_ids().size())
	_server.console.execute("bot_quota_mode fill")


func _test_unload() -> void:
	print("")
	print("unloading")

	var unloaded := _server.modules.unload_module("arena")
	_check(unloaded.ok, "the module unloads", str(unloaded.error))

	# The point of the helpers: everything the module registered is gone. A stale
	# command is a handler pointing at a freed object.
	_check(
		_server.console.find_command("arena_status") == null,
		"and takes its commands with it"
	)
	_check(
		_server.console.find_cvar("arena_scorelimit") == null,
		"and its cvar"
	)
	_check(
		_server.console.find_cvar("npc_skill") == null,
		"and the NPC skill cvars"
	)
	_check(not _server.modules.has_module("arena"), "and is no longer listed")

	# Reloading has to work, because that is what a live configuration change does.
	var again: DotResult = await _server.modules.load_module(
		"res://game/arena_module.gd"
	)
	_check(again.ok, "and it loads again cleanly", str(again.error))
	_check(
		_server.console.find_command("arena_status") != null,
		"with its commands back"
	)


## [b]The one line that leaked mg-buses-from-hell's whole script graph at exit.[/b]
##
## A script that `extends DotNetMessage` and preloads ITSELF, first loaded from a module a
## running [DotServer] loads — which is how every deployed server loads this game — leaves
## every loaded script alive at exit on Godot 4.7.2 (measured in mg-buses-from-hell,
## 8ed866c). This game's event and request both did it, for a typed `of()` factory.
##
## [b]Asserted on the source, because the symptom is where no check can reach.[/b] The
## leak is reported after `quit()`, by the engine, as warnings a CI filter already treats
## as noise; an assertion here runs before any of it exists. So this checks the cause
## instead: every message script in `game/`, read as text.
func _test_no_message_preloads_itself() -> void:
	print("")
	print("exiting clean")

	var messages := PackedStringArray()
	var offenders := PackedStringArray()
	var pending: Array[String] = ["res://game"]

	while not pending.is_empty():
		var dir_path: String = pending.pop_back()

		for sub in DirAccess.get_directories_at(dir_path):
			pending.append(dir_path.path_join(sub))

		for file in DirAccess.get_files_at(dir_path):
			if not file.ends_with(".gd"):
				continue

			var path := dir_path.path_join(file)
			var source := FileAccess.get_file_as_string(path)

			if not _extends_message(source):
				continue

			messages.append(path)

			if source.contains('preload("%s")' % file) or source.contains('preload("%s")' % path):
				offenders.append(path)

	_check(
		messages.size() >= 2,
		"this game's message scripts are found, so the next check is about something",
		", ".join(messages)
	)
	_check(
		offenders.is_empty(),
		"and none of them preloads itself, which leaks every script at exit",
		", ".join(offenders)
	)


func _extends_message(source: String) -> bool:
	for line in source.split("\n"):
		if line.begins_with("extends "):
			return line.contains("DotNetMessage") or line.contains("dot_net_message.gd")
	return false


# --- Exiting clean ----------------------------------------------------------------

## The flag this suite hands the copy of itself it runs. See [method _run_exit_probe].
const EXIT_PROBE_FLAG := "--exit-probe"

## What the exit probe adds to a run — one section, these checks — and the copy does not.
const EXIT_PROBE_CHECKS := 3


## How long the copy may run before it is killed and this probe fails. A copy that is still
## running this long after it started is hung, and the likeliest reason is the one that says
## nothing at all: a scene whose script failed to parse never reaches `quit()` and prints
## nothing. `-- --exit-probe-seconds N` lowers it, which is how the deadline itself is armed —
## any N shorter than the suite takes is a copy that is still running when it expires.
const EXIT_PROBE_SECONDS := 300


func _is_exit_probe() -> bool:
	return EXIT_PROBE_FLAG in OS.get_cmdline_user_args()


func _exit_probe_seconds() -> int:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--exit-probe-seconds")
	if at >= 0 and at + 1 < args.size() and args[at + 1].is_valid_int():
		return maxi(1, args[at + 1].to_int())
	return EXIT_PROBE_SECONDS


## Runs this same suite in a fresh process: `[exit code, its stdout, its stderr, whether it
## had to be killed, the seconds it was allowed]`.
##
## [b]A leak is reported after `quit()`, by the engine, where nothing in the process that
## leaked can read it.[/b] "N ObjectDB instances were leaked at exit" is printed once the
## scene tree is gone, so the only process that can check a run's exit is another one. On
## Godot 4.7.2 a script that names itself, loaded after its base, cuts the engine's exit
## teardown short and every script loaded before it is reported leaked — hundreds of lines
## a passing run printed for weeks, which is why this is a check now and not a warning.
##
## [b]First, before this run opens a port[/b], so the two never contend for a socket — and
## so this run is always the second one against the same `user://`, which is the other
## thing no single run can see.
##
## [b]Not `OS.execute`.[/b] That blocks until the copy exits, so a copy that hangs held this
## run for ever; and when the outer `timeout` then killed this run, the copy was left behind
## holding the suite's directory and port. So the copy is started, polled against a deadline
## and killed at it. Two deadlines, because Godot dies on SIGTERM without running a line of
## script — nothing in this process can clean up after it is killed:
##
## - coreutils `timeout` wraps the copy where it exists. It is an exec wrapper, not a shell,
##   and it outlives this process, so a copy orphaned by the outer `timeout` still dies on
##   time. Its exit status 124 is how its expiry is recognised.
## - this loop's own deadline, a little later, for a platform without it.
##
## `execute_with_pipe` rather than `create_process`, because the latter captures nothing and
## the whole point is reading what the copy printed. Non-blocking, and drained on every pass
## rather than once at the end: a pipe holds 64 KiB, and a copy that fills it blocks on its
## next print — a hang this probe would then report as the suite's own. The copy's stdin is
## the other end of a pipe this process holds open, which is why every suite turns the
## server's stdin console off: a reader blocked on it never lets the copy exit.
func _run_exit_probe() -> Array:
	var seconds := _exit_probe_seconds()
	print("(running this suite once more in a fresh process, to read what it leaves at exit — %d s allowed)" % seconds)
	var scene := scene_file_path if scene_file_path != "" else "res://examples/dedicated.tscn"
	var exe := OS.get_executable_path()
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		scene, "--", EXIT_PROBE_FLAG,
	])
	var wrapped := false
	for wrapper: String in ["/usr/bin/timeout", "/bin/timeout"]:
		if FileAccess.file_exists(wrapper):
			var outer := PackedStringArray(["--kill-after=10", str(seconds), exe])
			outer.append_array(args)
			exe = wrapper
			args = outer
			wrapped = true
			break

	var proc := OS.execute_with_pipe(exe, args, false)
	if proc.is_empty():
		return [-1, "", "could not start %s" % exe, false, seconds]
	var pid: int = proc["pid"]
	var pipes: Array[FileAccess] = [proc["stdio"], proc["stderr"]]
	var bytes: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray()]
	var deadline := Time.get_ticks_msec() + (seconds + 30) * 1000
	var hung := false
	while OS.is_process_running(pid):
		_drain_exit_probe(pipes, bytes)
		if Time.get_ticks_msec() > deadline:
			OS.kill(pid)
			hung = true
			break
		await get_tree().create_timer(0.1).timeout
	# Once more after it exits: what it wrote between the last pass and its exit is still in
	# the pipe, and the leak report is always the last thing it writes.
	_drain_exit_probe(pipes, bytes)

	# OS.kill has already reaped it, and asking for the exit code of a reaped pid is an error.
	var code := -1 if hung else OS.get_process_exit_code(pid)
	if wrapped and code == 124:
		hung = true
	return [code, bytes[0].get_string_from_utf8(), bytes[1].get_string_from_utf8(), hung, seconds]


func _drain_exit_probe(pipes: Array[FileAccess], bytes: Array[PackedByteArray]) -> void:
	for i in pipes.size():
		while true:
			var chunk := pipes[i].get_buffer(65536)
			if chunk.is_empty():
				break
			bytes[i].append_array(chunk)


func _test_exits_clean(probe: Array) -> void:
	print("")
	print("exiting clean, as a second process saw it")

	var code: int = probe[0]
	var stdout: String = probe[1]
	var stderr: String = probe[2]
	var hung: bool = probe[3]
	var seconds: int = probe[4]
	# Every leak line is the engine's, and the engine writes them to stderr; both are
	# searched so that stays a fact about the engine rather than an assumption here. Shown
	# apart, because a pipe each is two streams whose interleaving is lost, and where a hung
	# copy had got to is the end of its stdout.
	var text := stdout + "\n" + stderr
	var tail := "its last lines:\n%s\nand the last on stderr:\n%s" % [
		_last_lines(stdout, 15), _last_lines(stderr, 10)
	]

	# A copy that was killed never reached its exit, so neither of the last two was seen, and
	# passing them on an absence of lines would be passing them blind.
	var passes_detail := ""
	if hung:
		passes_detail = ("still running after %d s, so it was killed — a scene that failed to "
			+ "parse, or a thread still blocked when it quit; %s") % [seconds, tail]
	elif code != 0:
		passes_detail = "exit %d; %s" % [code, tail]
	_check(not hung and code == 0, "this suite, run again in a fresh process, passes",
		passes_detail)
	_check(not hung and not text.contains("leaked at exit"), "and leaves no object alive at exit",
		"it was killed before it reached its exit" if hung else _line_with(text, "leaked at exit"))
	_check(not hung and not text.contains("still in use at exit"), "and no resource",
		"it was killed before it reached its exit" if hung else _line_with(text, "still in use at exit"))


func _line_with(text: String, needle: String) -> String:
	for line in text.split("\n"):
		if line.contains(needle):
			return line.strip_edges()
	return ""


func _last_lines(text: String, count: int) -> String:
	var lines := text.strip_edges().split("\n")
	return "\n".join(lines.slice(maxi(0, lines.size() - count)))
