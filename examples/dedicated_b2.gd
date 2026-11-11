extends "dedicated_b1.gd"

const ArenaAvatars := preload("../game/arena_avatars.gd")
const ArenaServer := preload("../game/arena_server.gd")
const ArenaServices := preload("../game/arena_services.gd")


const SERVER_DIR := "user://arena_dedicated"


## The app's URL segment on the website, which is this game's code name.
##
## Unique and lowercase because the site made it so. Display only, never proof.
const APP_URL := "arena"


func _cleanup() -> void:
	DotPaths.remove_tree(SERVER_DIR)


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
	# A self-test takes no commands, and a console reader blocked on an open stdin pipe
	# (the exit probe's copy holds one) keeps the process from ever exiting. dot-server no
	# longer reads a pipe unless `stdin_console_pipes` is on; a terminal is still read.
	config.stdin_console_enabled = false

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	add_child(_server)

	# A server only answers queries if the query responder is plugged in, and `_test_browser`
	# asks over a real UDP socket, so without it that section fails rather than skipping.
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


func _test_module_loaded() -> void:
	_begin()
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

	# Registration helpers make unloading safe: a direct registration would leave a console
	# command pointing at a freed object.
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

	# Ending a round in progress is still only CHANGEMAP; the `sv_chat_commands` flag says so
	# on the line where it was typed, not a prefix check that ignored who was asking.
	var map_command := _server.console.find_command("map")
	_check(
		map_command != null
			and map_command.permission == DotAdminFlags.CHANGEMAP
			and map_command.allows_chat(_server.console.chat_commands_are_open()),
		"and changing the map is typable in chat by whoever holds changemap, and nobody else"
	)
	_end()


## Chat, voice, moderation and the identity chain, on a real server: all five addons up in one
## process on one [DotServer], with dot-moderation before the two routers that look up its
## `dot_mute_source` (a router that starts first enforces no gag).
func _test_services() -> void:
	_begin()
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

	# --- Moderation: dot-server's mute is two booleans that die with the connection, so a muted
	# player reconnects and talks. A punishment is a record. ---
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

	# identity

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
	_end()


## maps.yml on the live module: a map outside the active rotation stays installed and is never
## chosen, balloted or nominated; a rotation switch takes effect; a renamed command exists.
func _test_map_rotation_file() -> void:
	_begin()
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
	_end()


## B's server half: the `loadout` command and the owner's mp_loadout_* cvars, enforced HERE,
## whatever a client's screen showed. From the session the client-spawn section adopted (77).
func _test_loadout_command() -> void:
	_begin()
	print("\nthe loadout command and the owner's rules")

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

	await _test_loadout_command_part2(cmd, say)


func _test_loadout_command_part2(cmd: Object, say: Callable) -> void:
	var _a := _server.console.set_cvar("mp_loadout_menu", "1")
	var _b := _server.console.set_cvar("mp_loadout_fixed", "")
	var _c := _server.console.set_cvar("mp_loadout_allow", "")
	_check(_game.loadouts.rules == null, "and emptied, the cvars are no restriction")

	# Random: server-authoritative, new each time, and a cvar turns it off for a modified client too.
	var offer: Dictionary = cmd.call(&"offer", ArenaGame.storage_key(77))
	_check(_server.console.find_cvar("mp_loadout_random") != null and bool((offer.get("random", {}) as Dictionary).get("enabled", false)),
		"the offer advertises Random while mp_loadout_random is on")
	_check(_server.console.find_cvar("mp_loadout_random_on_spawn") != null and int((offer.get("random", {}) as Dictionary).get("spawn", 0)) == 1,
		"the offer carries the Every spawn rule (mp_loadout_random_on_spawn 1) so the menu shows the toggle")
	# One key per roll: a player's own publishes are rate-limited, and that is not what this asks.
	var seen := {}
	var rolled_ok := true
	for i in 6:
		var rk := ArenaGame.storage_key(9100 + i)
		var r: Dictionary = await cmd.call(&"choose_random", null, rk)
		rolled_ok = rolled_ok and bool(r.get("ok", false))
		var got: DotResult = await _game.loadouts.active_for(rk)
		seen[str((got.value as DotLoadout).item_in(&"primary")) + "/" + str((got.value as DotLoadout).item_in(&"secondary"))] = true
	_check(rolled_ok and seen.size() > 1, "a random roll is taken and is not the same loadout every time", str(seen.keys()))
	var _r_off := _server.console.set_cvar("mp_loadout_random", "0")
	var offer_off: Dictionary = cmd.call(&"offer", ArenaGame.storage_key(77))
	var refused: Dictionary = say.call("loadout random")
	_check(not bool((offer_off.get("random", {}) as Dictionary).get("enabled", true)) and not bool(refused.get("ok", true)),
		"with mp_loadout_random 0 the entry is hidden and the server refuses a modified client", str(refused))
	var _r_on := _server.console.set_cvar("mp_loadout_random", "1")
	var _r_slots := _server.console.set_cvar("mp_loadout_random_slots", "primary")
	var sk := ArenaGame.storage_key(9200)
	var before: DotResult = await _game.loadouts.active_for(sk)
	var sec_before := (before.value as DotLoadout).item_in(&"secondary")
	var only: Dictionary = await cmd.call(&"choose_random", null, sk)
	var after: DotResult = await _game.loadouts.active_for(sk)
	_check(bool(only.get("ok", false)) and (after.value as DotLoadout).item_in(&"secondary") == sec_before,
		"mp_loadout_random_slots primary leaves the other slots as they were", str(only))
	var _r_clear := _server.console.set_cvar("mp_loadout_random_slots", "")
	_end()


## Waits [param seconds] of the server's own physics ticks.
func _wait_ticks(seconds: float) -> void:
	for _i in int(seconds * Engine.physics_ticks_per_second):
		await get_tree().physics_frame


func _test_bots() -> void:
	_begin()
	print("")
	print("bots")

	var module := _server.modules.get_module("arena") as ArenaModule
	if not _check(module != null and module.bridge != null, "the module has a bridge to add bots through"):
		return

	var bots := await _test_bots_fill(module)
	await _test_bots_swap(module, bots)
	await _test_bots_fight(module)

	_server.console.execute("bot_quota_mode off")
	await _wait_ticks(1.5)
	_check(module.bridge.bot_ids().is_empty(), "bot_quota_mode off takes them all out",
		"%d left" % module.bridge.bot_ids().size())
	_server.console.execute("bot_quota_mode fill")
	_end()


## Fill mode tops the game up to bot_quota; returns the bot ids that were added.
func _test_bots_fill(module: ArenaModule) -> Array:
	_check(_server.console.find_cvar("bot_quota") != null and _server.console.get_string("bot_quota_mode", "") == "fill",
		"bot_quota is the module's and fill is the default", _server.console.get_string("bot_quota_mode", ""))

	# Everything sent since the client spawned went to 4242 alone, snapshots included.
	var peers := {}
	var snapshots := 0
	for c: Dictionary in _caught:
		peers[c["peer"]] = true
		if c["method"] == &"snapshot":
			snapshots += 1
	_check(peers.keys() == [4242] and snapshots > 0,
		"the adopted session was sent its snapshots, and nobody else was sent anything",
		"%d snapshots, peers %s" % [snapshots, str(peers.keys())])

	# Adopted sessions have no peer; silence the send so ticking raises no RPC errors.
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
	return bots


## A person joining takes a bot's place and leaving gives it back.
func _test_bots_swap(module: ArenaModule, bots: Array) -> void:
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

	_server.client_disconnected.emit(session, "test")
	await _wait_ticks(1.5)
	_check(module.bridge.bot_ids().size() == bots.size(), "and a bot comes back when they leave",
		"%d" % module.bridge.bot_ids().size())


## Within a few seconds a bot fires at somebody it can see, and fires once the round is live.
func _test_bots_fight(module: ArenaModule) -> void:
	# They fight: within a few seconds one of them has fired at somebody it can see.
	var fired := false
	# A pressed trigger is not a shot (no weapon ready fires nothing): count real shots.
	var shots := [0]
	for id in module.bridge.bot_ids():
		_game.player_for(id).used.connect(func(outcome: DotWeaponOutcome) -> void:
			if outcome != null and outcome.used:
				shots[0] += 1)
	for _i in int(6.0 * Engine.physics_ticks_per_second):
		await get_tree().physics_frame
		for id in module.bridge.bot_ids():
			var behaviour := module.bridge.behaviour_for(id)
			if behaviour != null and behaviour.last_fire.is_pressed(DotWeaponCommand.BUTTON_ATTACK):
				fired = true
		if fired:
			break
	_check(fired, "the bots fight")
	# The warmup and the frozen countdown come first: nobody shoots in them, by design.
	var waited := 0.0
	while _game.match_node.state != DotMatch.State.LIVE and waited < 40.0:
		await _wait_ticks(1.0)
		waited += 1.0
	_check(_game.match_node.state == DotMatch.State.LIVE, "the first round of a fresh server goes live", "%.0f s" % waited)
	shots[0] = 0
	for _i in int(10.0 * Engine.physics_ticks_per_second):
		if shots[0] > 0:
			break
		await get_tree().physics_frame
	_check(shots[0] > 0, "and the bots fire within 10 s of it going live, on the first map of a fresh server", str(shots[0]))


func _test_unload() -> void:
	_begin()
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
	_end()


## The one line that leaked a game's whole script graph at exit: a script that `extends
## DotNetMessage` and preloads ITSELF, loaded by a running [DotServer]'s module. Asserted on
## the source (every message script in `game/`), as the engine reports the leak after `quit()`.
func _test_no_message_preloads_itself() -> void:
	_begin()
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
	_end()


func _extends_message(source: String) -> bool:
	for line in source.split("\n"):
		if line.begins_with("extends "):
			return line.contains("DotNetMessage") or line.contains("dot_net_message.gd")
	return false


## The flag this suite hands the copy of itself it runs. See [method _run_exit_probe].
const EXIT_PROBE_FLAG := "--exit-probe"


## What the exit probe adds to a run — one section, these checks — and the copy does not.
const EXIT_PROBE_CHECKS := 3


## How long the copy may run before it is killed. A copy still running is hung, likeliest a
## scene whose script failed to parse. `-- --exit-probe-seconds N` lowers it.
const EXIT_PROBE_SECONDS := 300


func _is_exit_probe() -> bool:
	return EXIT_PROBE_FLAG in OS.get_cmdline_user_args()
