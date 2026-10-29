extends "arena_module_cvars.gd"

const ArenaPaths := preload("arena_paths.gd")

const ArenaBoards := preload("arena_boards.gd")
const ArenaEvents := preload("arena_events.gd")
const ArenaAmbience := preload("arena_ambience.gd")
## The workbench kind of the ambience cvar set (saved to cfg/.../ambience/server.yml).
const AMBIENT_KIND := "ambience"
## The workbench kind of the wall-move cvar set (arena_wall*).
const WALL_KIND := "wallmoves"
const ArenaMapConfig := preload("arena_map_config.gd")
const ArenaIdentity := preload("arena_identity.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMaps := preload("arena_maps.gd")
const ArenaMapDirector := preload("arena_map_director.gd")
const ArenaModTools := preload("arena_mod_tools.gd")
const ArenaModes := preload("arena_modes.gd")
const ArenaModule := preload("arena_module.gd")
const ArenaNetBridge := preload("arena_net_bridge.gd")
const ArenaServices := preload("arena_services.gd")
const ArenaStats := preload("arena_stats.gd")
const ArenaVote := preload("arena_vote.gd")

## Binds an [ArenaGame] to a [DotServer].
##
## [b]This is the only file in the project that names dot-server, and it is the only
## place the family's own documentation says such a bridge belongs.[/b] dot-match does
## not import dot-server, dot-combat does not, and dot-loadout does not — so a game
## that wants a dedicated server writes about forty lines, and they are these.
##
## Loaded the way any module is:
##
## [codeblock]
## server.modules.load_module("res://game/arena_module.gd")
## [/codeblock]
##
## The game itself is found through [DotRegistry] rather than being handed in, which is
## what makes loading by path rather than by instance work at all.

const CHANNEL := "arena.module"

## The drawn map ballot's notice topic. The client shell draws one menu per topic, and a
## server running several games sends its own `game_ballot` beside this one.
const MAP_BALLOT_TOPIC := &"map_ballot"

## dot-platform's own module, loaded beside this one. A path, because that is what
## [code]DotModuleHost.load_module[/code] takes — see [method _build_identity].
const PLATFORM_MODULE_PATH := "res://addons/dot_platform/dot_platform_module.gd"

## dot-combat's cvars (mp_teammate_passthrough), kept to put on each map's new combat manager.
var _combat_cvars: Array = []

var bridge: ArenaNetBridge = null
## Carries the workbench's profile runtime (rows down) over this manager; null without a workbench.
var profile_link: DotNetProfileLink = null

## Chat, voice and moderation. See [ArenaServices] for why it is not this file.
var services: ArenaServices = null

## Where the services keep punishments. Empty is dot-moderation's own default,
## `user://moderation.json` — the store a real server enforces.
##
## [b]Static, because nothing holds this module before it exists[/b]: dot-server constructs
## it from a path inside `load_module`, so there is no instance for a host to set a field on
## first. `examples/dedicated.tscn` points it at a directory of its own; before it could,
## every run wrote an hour-long gag against the same test uid into the real store, 457
## records by the time anybody counted.
static var punishments_file: String = ""

## The live tools' commands. See [method _build_mod_commands].
var mod_commands: DotModToolCommands = null

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

## Who is still behind their loading cover, from dot-game's roster used for that alone: this
## module is not on DotGameModule, so it seats people itself and only borrows the bookkeeping
## (loading from the spawn event until the client says its cover lifted, again from a map
## change). A player id is the userid, so [method ArenaGame.can_be_harmed] asks it by that.
## Bots are never seated here, so they are never loading.
var loading: DotGameRoster = null
var _handles_cover: bool = false

## The authoritative tick. Counted here because the module is what drives it.
var _tick: int = 0


func _module_name() -> String:
	return "arena"


func _module_version() -> String:
	return "0.1.0"


func _module_description() -> String:
	return "Deathmatch: match flow, combat, loadouts and spawning."


func _module_author() -> String:
	return "dot"


func _module_load() -> DotResult:
	game = DotRegistry.get_node_service(ArenaGame.SERVICE) as ArenaGame

	if game == null:
		# Refusing to load is right: a module that loaded and then did nothing would
		# leave a server that accepts players into a match that does not exist, and
		# the symptom is players who connect and never spawn.
		return DotResult.fail(
			DotError.CODE_STATE,
			"No ArenaGame is registered. Create one and call setup() before loading "
			+ "this module."
		)

	hook_post("client_spawn", _on_client_spawn)

	add_command(
		"arena_status", _cmd_status, "Show the match state", DotAdminFlags.GENERIC
	)
	add_command(
		"arena_score", _cmd_score, "Show the scoreboard", ""
	)
	add_command(
		"arena_restart", _cmd_restart, "Restart the match", DotAdminFlags.CHANGEMAP
	)
	add_command(
		"arena_maps", _cmd_maps, "List the maps this server can boot", ""
	)

	_add_match_cvars()

	# B, the loadout menu: `/loadout` and its notice, and the owner's mp_loadout_menu,
	# mp_loadout_allow and mp_loadout_fixed and the mp_loadout_random* dice (dot-loadout's DotLoadoutCommand). Absent on a host
	# whose dot-loadout predates it, and then B says the server did not answer.
	if game.loadout_command != null:
		game.loadout_command.call(&"bind", self)

	_add_movement_cvars()
	_add_drop_cvars()
	_add_jail_cvars()
	_add_spawn_cvars()
	_add_unlag_cvar()
	_add_stats_report_cvar()
	_add_fire_buffer_cvar()
	_add_grenade_cvars()
	_add_rate_cvar()
	if game.config_binder != null:
		game.config_binder.bind_cvars(add_cvar, DotConVar.FLAG_ARCHIVE, console.has_name)
		game.config_binder.bind_commands(add_command)
	var _rides := game.start_ride_recording(add_cvar)

	add_cvar(
		"arena_streak_rewards", "3:heal,5:haste,7:empowered",
		"Kill streak rewards, as streak:reward pairs (heal, armour, haste, empowered); empty for none",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.streak_rewards = ArenaGame.parse_streak_rewards(new_value)
			log_info("streak rewards changed", {"rewards": new_value})
	)
	game.streak_reward.connect(
		func(player_id: int, streak: int, reward: String) -> void:
			var who := game.player_for(player_id)
			if services != null:
				services.announce(
					"%s is on a %d kill streak: %s" % [who.display_name if who != null else "?", streak, reward]
				)
	)

	# npc_skill, npc_reaction_scale, npc_reaction_min. Registered whether or not this mode
	# has monsters, so a config that sets them does not fail on a deathmatch map and then
	# not apply when the rotation reaches a horde one. Through `add_cvar`, so they go when
	# the module does; NOTIFY, because players should know the monsters just got harder.
	game.npc_skill.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY)

	# Whether shots pass through team-mates: `mp_teammate_passthrough` 0 never, 1 a team-mate
	# holding the muzzle (the default), 2 every team-mate in the line. dot-combat's cvar,
	# defined there once for every game and live from the next shot; the projectile sweep
	# reads the same rules. By name, like ArenaProjectiles' pass_through_sets: a host whose
	# dot-combat predates it loads arena without the cvar.
	#
	# REPLICATED, because each client's own manager predicts tracers under it and follows the
	# server's value through its link (ArenaClient). And re-applied on every map change: the
	# world builds a NEW combat manager per map, and the one bind_cvars tied the cvar to is
	# gone, so without this a server on 0 or 2 was back on 1 from the second map on.
	if game.combat != null and game.combat.has_method(&"bind_cvars"):
		var bound: Variant = game.combat.call(
			&"bind_cvars", add_cvar,
			DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
		)
		_combat_cvars = bound as Array if bound is Array else []
		for cv in _combat_cvars:
			(cv as DotConVar).changed.connect(_reapply_combat_cvars.unbind(2))
		game.map_changed.connect(_reapply_combat_cvars.unbind(1))

	_bind_rule_cvars()

	_start_workbench()

	# A real server keeps what its monsters learn of each map across restarts. Here and
	# not in ArenaGame, because every suite builds an ArenaGame and only a server loads this.
	game.persist_npc_heat = true

	if game.horde != null and game.horde.spawner != null:
		game.horde.heat.persist = game.horde.persist_heat
		# The horde was built before this module loaded, with saving off — so it adopted
		# the map without reading what earlier runs learned. Read it now.
		game.horde.heat.adopt(
			game.map.id if game.map != null else &"", game.horde.spawner.now(), game.horde.spawner
		)

	# [b]How many players before a round starts, and it has to be an operator's
	# choice.[/b] The default is 2, which is right for a deathmatch and makes a public
	# demonstration server look broken: one person connects, the match sits in WARMUP
	# for ever, nobody spawns, and the only thing on screen is a HUD saying WARMUP. A
	# server with one player and no bots is a legitimate configuration and the operator
	# is the one who knows whether it is theirs.
	# [b]Bots, on by default.[/b] Fill mode: a server with one person on it plays a match of
	# four, and every person who joins takes a bot's place. dot-server's DotBotQuota is the
	# rule and its three cvars (bot_quota, bot_quota_mode, bot_quota_empty) are the
	# operator's; `bot_quota_mode off` is a server with no bots.
	_bot_quota = DotBotQuota.install(self, game.config.bot_quota)

	# [b]How the bots play[/b]: dot-bot's `bot_difficulty` (easy, medium, hard, nightmare;
	# medium by default) and every `bot_*` setting it bundles, each overridable. On the game,
	# where the bots' brains read it (ArenaBots), never in the registry: two servers in one
	# process must not share a difficulty.
	var _bot_cvars := DotBotSettings.of(game).bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY, add_command)

	# Through `game.min_players` like the other match cvars (`_add_match_cvars`): written to
	# the live match alone, it was back to the mode's 2 after the first map change, and a
	# one-player server sat in warmup from then on.
	add_cvar(
		"arena_minplayers",
		str(game.match_node.rules.min_players),
		"Players needed before a round starts",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	).with_min(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.min_players = maxi(new_value.to_int(), 1)
			_apply_match_limits()
			log_info("minimum players changed", {
				"min_players": game.match_node.rules.min_players
			})
	)

	# **What is being played, on a running server.**
	#
	# Without this the two modes that are not about killing people are unreachable from
	# a deployment: `ArenaGame.mode_id` is an export read once at setup, and a vote can
	# offer a mode only where somebody has configured one. A game with modes nobody can
	# select is a game with one mode and some dead code — the family's own "produced
	# correctly and consumed by nothing", at the level of a whole feature.
	#
	# It goes through `change_map`, which is the only re-entrant path this game has:
	# `setup` builds the combat trace, the match node and every spawn point in one pass
	# and calling it twice leaves two of each. The map stays the same unless the new
	# mode asks for another one.
	add_cvar(
		"arena_mode",
		String(game.mode.id),
		"What is being played: %s" % ", ".join(_mode_ids()),
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	).changed.connect(
		func(old_value: String, new_value: String) -> void:
			_change_mode(old_value, new_value)
	)

	add_command(
		"arena_modes", _cmd_modes, "What can be played here", ""
	)

	add_command(
		"arena_net", _cmd_net, "Show the netcode's state", ""
	)

	server.client_disconnected.connect(_on_client_disconnected)
	game.player_killed.connect(_on_player_killed)

	_build_loading()

	var netted := _build_netcode()

	if not netted.ok:
		return netted.wrap("The arena netcode could not start")

	# Everything below this line is optional in the sense that the game runs without
	# it. None of it is optional in the sense that matters: a server with no chat, no
	# rotation and no vote is a server nobody stays on.
	#
	# [b]Each one logs and continues rather than refusing to load.[/b] A module that
	# would not load because a punishment file was unreadable is a module that takes
	# the whole game down over a permissions mistake, and the game is what the players
	# came for.
	var identified: DotResult = await _build_identity()
	DotLog.result(CHANNEL, "the identity layer", identified)

	var serviced: DotResult = await _build_services()
	DotLog.result(CHANNEL, "chat, voice and moderation", serviced)

	if serviced.ok:
		_build_mod_commands()

	var mapped := _build_maps()
	DotLog.result(CHANNEL, "the map director", mapped)

	if mapped.ok:
		var voted := _build_vote()
		DotLog.result(CHANNEL, "the vote", voted)

	_follow_hibernation()

	_add_extra_commands()
	_build_query_provider()
	_register_game()

	if game.map != null:
		_report_map(String(game.map.id))

	log_info("arena loaded", {"map": game.map.display_name})
	return DotResult.success(null)


## Binds the cvars of the game's rule sets (fall, ragdoll, toys, views, spectate, bodies, noblock, feel).
func _bind_rule_cvars() -> void:
	# Replicated where each client draws or predicts under the rule; the rules are the game's, so one bind lasts.
	var replicated := DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	# sv_falldamage and its tunables: dot-combat's, on here (not on surf maps); server side, the damage arrives as health.
	var _fall := game.fall_rules.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY)

	# Dead bodies: dot-player-char's sv_ragdoll* (the server picks each reaction, ArenaGame.decide_death).
	var _ragdoll_cvars := game.ragdoll_rules.bind_cvars(add_cvar, replicated)
	var _weapon_drop_cvars := game.weapon_drop_rules.bind_cvars(add_cvar, replicated)  # sv_weapon_drop*

	# The map's toys: dot-props' sv_toys, sv_toys_awake, sv_toys_push.
	var _toy_cvars := game.toy_rules.bind_cvars(add_cvar, replicated)

	# mp_forceview: free view (0), held in first (1) or third (2) person.
	var _view_cvars := game.view_rules.bind_cvars(add_cvar, replicated)

	# mp_killview*: dot-replay's kill view.
	var _killview_cvars := game.killview_rules.bind_cvars(add_cvar, replicated)

	# arena_ambient*: dot-audio's DotAmbienceRules; the directory cvar stays local.
	var _ambient_cvars := game.ambient_rules.bind_cvars(add_cvar, replicated, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY)

	# mp_forcecamera, mp_freeroam, mp_freeroam_speed: dot-spectate's rules (ArenaClient.toggle_roam).
	var _spectate_cvars := game.spectate_rules.bind_cvars(add_cvar, replicated)

	# mp_solidplayers: players and bots stop at each other (1) or pass through (0) (ArenaGame.solid_hulls_for).
	var _solid_cvars := game.body_rules.bind_cvars(add_cvar, replicated)

	# mp_teamblock, mp_enemyblock, mp_blockcmd*, mp_blockscope, mp_blockstate and !block / !noblock:
	# dot-game's DotGameNoblock, REPLICATED for the same reason as mp_solidplayers. The server
	# scene builds it (strict cfg layers); a suite that only builds a module gets a lenient one.
	# A module loaded again over the same game gets fresh rules: the old ones are bound to the
	# old console.
	if game.noblock == null or game.noblock_bound:
		DotLog.result(CHANNEL, "noblock", game.make_noblock(false))
	if game.noblock != null:
		DotLog.result(CHANNEL, "noblock cvars", game.noblock.bind(add_cvar, self))
		game.noblock_bound = true

	# mp_vm_sway* and friends: zee-dot-weapons' view model feel, drawn on each client.
	var _feel_cvars := game.feel_rules.bind_cvars(add_cvar, replicated)

	# Aim down sights: spread and pace while aimed are predicted, so they cross as one JSON cvar.
	var _ads_cvars := game.ads_rules.bind_cvars(add_cvar, replicated)

	game.combat_feel.bind_cvars(add_cvar)


## The manager, the bridge and the link.
##
## [b]The module drives the tick, not the game.[/b] The game's tick has to happen
## INSIDE dot-net's — between applying each peer's inputs and building the snapshot —
## which is what `ArenaNetBridge.server_tick` arranges through
## `ArenaPlayerNet._net_simulate`. A game ticking itself as well would move everybody
## twice.
func _build_netcode() -> DotResult:
	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = true
	net.local_peer_id = 1
	net.auto_tick = false
	net.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = game.tick_rate
	config.snapshot_rate = ArenaGame.snapshot_rate_for(game.tick_rate)
	config.enable_prediction = true
	# On: a player shoots where they SEE someone, which is where that player was half a round trip ago.
	config.enable_lag_compensation = true
	config.max_entities_per_snapshot = 64
	# Unlimited: tools/net_probe.gd measured ~6 kB/s steady and ~16 kB/s at a join, so a cap
	# could only hold a packet back (see _add_rate_cvar).
	config.per_client_budget = _cv_maxrate.get_int() if _cv_maxrate != null else 0
	config.per_client_packet_rate = 0
	# From the game, so the client cannot be given a different one. See
	# ArenaGame.NET_WORLD_EXTENT.
	config.world_extent = ArenaGame.NET_WORLD_EXTENT
	net.config = config
	add_child(net)

	var started := net.setup()

	if not started.ok:
		return started

	bridge = ArenaNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	var attached := bridge.attach(game, net)

	if not attached.ok:
		return attached

	# Under the DotServer node, whose name is the first half of the RPC routing. The
	# client parents its copy under `DotClientLink`, which is named to match.
	bridge.open_link(server)

	# Who somebody is reaches the match: a figure as they are seated, and the real name
	# and figure once dot-platform has them. See `_wire_identity`.
	_wire_identity()

	# Avatar actions: the relay, and the loadouts the join/leave handlers below tell.
	var avatar := DotGameAvatarActionRelay.serve(net, self, server)
	if not avatar.ok:
		log_warn("avatar actions not served", {"why": avatar.error.message})

	# The remote workbench's frame (inert until sv_workbench_remote) and the profile rows an admin's edit sends.
	var bench := DotGameWorkbenchRemote.serve(net)
	if not bench.ok:
		log_warn("remote workbench not served", {"why": bench.error.message})
	var wb_runtime: DotProfileRuntime = game.workbench.api.runtime as DotProfileRuntime if game.workbench != null and game.workbench.api != null else null
	if wb_runtime != null:
		profile_link = DotNetProfileLink.attach(net, wb_runtime)
		if bench.ok and game.workbench.serve_remote(net) == null:
			log_warn("remote workbench not bound", {})

	# Sealed after every type is registered: a type added later is one the peer was told is absent.
	net.messages.seal()

	# A client whose schema cannot work with this server's is dropped, in words: dot-net only
	# says so and owns no socket (as DotGameNetcode.refuse_peer).
	net.peer_schema_refused.connect(_refuse_peer)

	return net.start()


# --- The rest of the server ------------------------------------------------

## Content, profiles, avatars and admission.
##
## Loaded as a SECOND module rather than wired in here, because dot-platform ships one
## and it is the right shape: everything it registers is removed again when it unloads,
## and a server that wants a different admission flow replaces one module instead of
## editing this one.
func _build_identity() -> DotResult:
	identity = ArenaIdentity.new()
	identity.name = "Identity"
	add_child(identity)

	var ready: DotResult = await identity.setup()

	if not ready.ok:
		remove_child(identity)
		identity.queue_free()
		identity = null
		return ready

	# [b]Loaded by PATH, not by instance, and the hub is found through the
	# registry.[/b] `DotModuleHost.load_module` takes a path and constructs the module
	# itself — it has to, because that is the shape that lets an operator name a module
	# in a config file — so a pre-built instance with `platform` already assigned would
	# be thrown away and a fresh one made with `platform` null.
	#
	# dot-platform's module falls back to `DotRegistry.get_service(DotPlatformHub.SERVICE)`
	# for exactly this, which is why `ArenaIdentity` registers the hub.
	if server.modules != null and not server.modules.has_module("platform"):
		# Awaited: loading a module runs its `_module_load`, which is allowed to be a
		# coroutine. An un-awaited one returns at its first suspension, and the line
		# below then reads `.ok` off null.
		var loaded_module: DotResult = await server.modules.load_module(
			PLATFORM_MODULE_PATH
		)

		if not loaded_module.ok:
			return loaded_module.wrap("The platform module would not load")

	return DotResult.success(identity)


func _build_services() -> DotResult:
	services = ArenaServices.new()
	services.name = "Services"
	services.punishments_file = punishments_file

	# Before `setup`, not after. The relay is built inside it, and a client assigned
	# afterwards is a client the relay has already decided it does not have — the same
	# ordering that left dot-server's audit log unopened in every default configuration.
	if identity != null:
		services.backbone = identity.backbone

	add_child(services)

	var ready: DotResult = await services.setup(server, game, bridge.link)

	if not ready.ok:
		remove_child(services)
		services.queue_free()
		services = null
		return ready

	# Voice arrives on the link, is relayed by the router, and goes back out on the
	# link. The bridge is the only file that names both ends, which is why the callable
	# is set here rather than either of them knowing about the other.
	if services.voice != null:
		bridge.voice_relay_fn = services.relay_voice

		# sv_voice_enable and sv_voice_mode: enforced on the router, replicated so a client
		# hides its key. On this module, so they go when it unloads.
		var _voice_cvars := services.voice.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED)

	services.command_entered.connect(_on_chat_command)

	return DotResult.success(services)


## noclip, god, slay, bring and the rest, on this server's console and in chat.
##
## Through this module as the host, so every one of them is removed on unload like the
## module's own commands. The handlers are `ArenaModTools`; the flags, the targets and the
## immunity rule are dot-moderation's `DotModToolCommands`, and neither names the other.
func _build_mod_commands() -> void:
	if services == null or services.mod_tools == null:
		return

	mod_commands = DotModToolCommands.install(self, services.mod_tools, server)
	mod_commands.alive_fn = func(id: StringName) -> bool:
		var player := game.player_for(String(id).to_int()) if String(id).is_valid_int() else null
		return player != null and player.is_alive()
	mod_commands.team_fn = func(id: StringName) -> String:
		return str(game.team_of(String(id).to_int())) if String(id).is_valid_int() else ""
	mod_commands.items_fn = func() -> PackedStringArray:
		return ArenaModTools.item_ids(game)

	# A new body is a new body: a respawn switches a freeze or a noclip off and puts god
	# back on. `player_spawned` is the match's respawn AND an admin's, because
	# `ArenaGame.respawn_player` takes the same path.
	if not game.player_spawned.is_connected(_on_player_spawned_for_tools):
		game.player_spawned.connect(_on_player_spawned_for_tools)


func _on_player_spawned_for_tools(player: ArenaPlayer) -> void:
	if services != null and services.mod_tools != null:
		services.mod_tools.respawned(StringName(str(player.player_id)))


func _build_maps() -> DotResult:
	maps = ArenaMapDirector.new()
	maps.name = "Maps"
	maps.game = game
	# A dedicated server draws nothing, so there is no world node to put meshes in.
	# `ArenaGame.change_map` has already replaced everything that decides the game.
	maps.world_ref = null
	# The server owner's map list (`cfg/content.yml` -> `DotGameDescriptor.maps`): the
	# combat surf maps this server offers as packs. See `ArenaMaps.delivered_def`.
	maps.server = server
	add_child(maps)

	var ready := maps.setup()

	if not ready.ok:
		remove_child(maps)
		maps.queue_free()
		maps = null
		return ready

	# The transport. dot-map is deliberately transport-agnostic — it depends on nothing
	# but dot-core — so the host says where a payload goes, one peer at a time.
	maps.sync.send_fn = func(peer: int, payload: Dictionary) -> void:
		if bridge != null and bridge.link != null:
			bridge.link.send_map(peer, payload)

	bridge.map_report_fn = func(peer: int, payload: Dictionary) -> void:
		if maps != null:
			maps.handle(peer, payload)

	# Admitted at READY rather than at the seat: a client builds its world on the default
	# map, and only an admission tells it the one the server is on. Before this every client
	# that joined after a map change predicted against the wrong level for the whole map:
	# a correction on most frames, and walls in the wrong place.
	bridge.peer_ready_fn = func(peer: int) -> void:
		if maps != null:
			maps.admit_peer(peer)
		if profile_link != null:
			profile_link.peer_joined(peer)

	maps.map_changed.connect(_on_map_changed)
	maps.map_over.connect(_on_map_over)

	# Which imported combat surf maps the rotation and the vote offer. A server setting
	# rather than a per-player one, written onto the running catalogue in place because
	# the rotation holds it by reference. See `ArenaMaps.imported_rotation`.
	add_cvar(
		"arena_imported_rotation", ArenaMaps.imported_rotation,
		"Imported combat surf maps in the rotation: all, none, or ids separated by commas",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	).changed.connect(
		func(_old: String, new_value: String) -> void:
			ArenaMaps.imported_rotation = new_value
			ArenaMaps.apply_rotation(maps.session.catalogue if maps != null and maps.session != null else null)
			log_info("imported rotation changed", {"rotation": new_value})
	)

	# Which installed maps rotate: cfg/maps.yml, read at boot (the director) and again when
	# this is set.
	add_cvar(
		"sv_map_rotation_file", maps.rotation_file_name,
		"maps.yml: the maps that rotate, in named rotations. Unlisted maps stay installed.",
	).changed.connect(
		func(_old: String, new_value: String) -> void:
			maps.rotation_file_name = new_value.strip_edges()
			var _read := maps.load_rotation()
	)

	return DotResult.success(maps)


## maps.yml's `commands:` block (prefix and names), or empty with no file.
func _rotation_commands() -> Dictionary:
	return maps.rotation_file.commands() if maps != null and maps.rotation_file != null else {}


## Both map clocks follow the server's hibernation: they stop while nobody is here and start
## again from the top when somebody joins. The vote's is the one that runs; the map
## director's is the fallback for a server whose vote did not load. With hibernation off the
## vote's own [code]empty_choice[/code] changes the map when the limit runs out on nobody.
## This module is not on DotGameModule, which does this by itself for the games that are.
func _follow_hibernation() -> void:
	if vote != null and vote.director != null:
		vote.director.follow_hibernation(server)

	if maps != null and maps.session != null:
		maps.session.follow_hibernation(server)


func _build_vote() -> DotResult:
	vote = ArenaVote.new()
	vote.name = "Vote"
	vote.game = game
	vote.maps = maps
	vote.commands_spec_fn = _rotation_commands
	vote.authoritative = true
	add_child(vote)

	vote.announce_fn = func(line: String) -> void:
		if services != null:
			services.announce(line)
		else:
			server.broadcast_message(line)

	vote.is_admin_fn = func(voter: StringName) -> bool:
		var session := server.session_by_userid(String(voter).to_int())
		# has_permission, not permissions.has: the second misses `root`.
		return session != null and session.has_permission(DotAdminFlags.CHANGEMAP)

	# The drawn ballot, to each playing session with its own voter id — this game's voters
	# are the bare userid — so the client shell marks the player's own choice. Topic
	# `map_ballot`, beside a server's `game_ballot` when both votes are open at once.
	vote.ballot_fn = func(state: Dictionary) -> void:
		for session in server.playing_sessions():
			var data := state.duplicate()
			data["you"] = str(session.userid)
			server.send_notice(session, DotNotice.make(
				&"", "", float(state.get("seconds", -1.0)), MAP_BALLOT_TOPIC, data
			))

	vote.people_fn = func(voter: StringName) -> Dictionary:
		var session := server.session_by_userid(String(voter).to_int())

		if session == null:
			return {}

		var avatar: Variant = session.identity.get("avatar_url") if session.identity != null else ""
		return {"name": session.display_name, "avatar": avatar if avatar is String else ""}

	vote.score_limit_raised.connect(func(_limit: int) -> void:
		if bridge != null:
			bridge.note_score_limit_changed()
	)

	var ready := vote.setup()

	if not ready.ok:
		remove_child(vote)
		vote.queue_free()
		vote = null
		return ready

	vote.change_due.connect(
		func(id: StringName, _choice: DotVoteChoice) -> void:
			log_info("a vote decided what plays next", {"choice": String(id)})
	)

	# The cues and the countdown, to every ready client. Chat carries what the ballot
	# SAYS — that is `announce_fn` above — and cannot carry a sound or a number a HUD
	# counts down, which is why this is an event of its own rather than more chat.
	vote.cue_due.connect(
		func(cue: StringName, seconds_left: int, runoff: bool) -> void:
			if bridge != null:
				bridge.send_event(0, ArenaEvents.Kind.VOTE, ArenaEvents.write_vote(
					String(cue), seconds_left, runoff
				))
	)

	return DotResult.success(vote)


## How often the bot count is put right, seconds. Not every tick: adding a player is a
## spawn, a loadout and a JOIN to everybody, and nobody notices a bot arriving a second late.
const BOT_CHECK_SEC := 1.0

var _bot_quota: DotBotQuota = null
var _bot_roster := DotBotRoster.new()
var _since_bot_check := 0.0


## Adds or removes bots until there are as many as the quota wants for the people here.
##
## Newest out first, so a person joining takes the place of the bot that came last and the
## longest-standing bots keep their scores. A bot an admin's map change or a mode change
## took out is simply counted again.
func _keep_bots() -> void:
	if _bot_quota == null or bridge == null or game == null:
		return

	var humans := _joined.size()
	var slots := server.config.max_players if server != null and server.config != null else -1
	var wanted := _bot_quota.wanted(humans, slots)
	var bots := bridge.bot_ids()

	# Named from dot-bot's pool, never a person's name and never "Bot 3".
	var taken: Array = []
	for p in game.players():
		taken.append(p.display_name)
	var _kept := _bot_roster.keep(wanted, bots,
		func(bot_name: String) -> int: return bridge.add_bot(bot_name),
		func(id: int) -> void: bridge.remove_bot(id),
		taken)


## One authoritative tick.
func _physics_process(delta: float) -> void:
	if not loaded or bridge == null:
		return

	_tick += 1
	if loading != null:
		loading.poll_loading()
	bridge.server_tick(_tick)

	_since_bot_check += delta
	if _since_bot_check >= BOT_CHECK_SEC:
		_since_bot_check = 0.0
		_keep_bots()

	# The map clock and the vote clock, from the SIMULATED tick rather than from the
	# frame. Both addons make the same point and it is the same point: a server that
	# stalls should not lose that time off its map, and a test must be able to run an
	# hour of a map in a millisecond.
	#
	# [b]One clock, and it is the vote's when there is a vote.[/b] The map director's own
	# `DotMapTimeLimit` and the vote's `DotVoteClock` both ran here, both thirty minutes
	# from boot, and the first to expire won: the map director's reached `_on_map_over`,
	# which opened a SECOND ballot over a winner the players had already chosen and was
	# waiting for its moment. The map director's clock is the fallback for a server whose
	# vote did not load, which is the only server that advances it.
	if maps != null and vote == null:
		maps.advance(delta)

	if vote != null:
		vote.advance(delta)

	# The clock, once a second rather than once a state change.
	#
	# `match_state_changed` covers the transitions and nothing covers the time passing
	# INSIDE one, so a client told the state at signon showed a frozen clock for the
	# whole round — a number produced correctly on the server and never sent, which is
	# this family's most repeated shape. Once a second because it is a clock displayed
	# to whole seconds; at the tick rate it would be 64 reliable messages a second per
	# client to move a digit sixty times less often than that.
	if _tick % maxi(game.tick_rate, 1) == 0:
		bridge.announce_match_state()


## So `changegame`, a vote and the server browser have something to name.
##
## Ships inside the build, so `client_scene` stays empty and the signon takes the
## documented "you already have it" path — dot-server used to fall back to the server's
## own absolute path there, which `DotClientLink` correctly refuses, and the client
## then failed signon and timed out.
## What a server browser is told about this game.
##
## [b]dot-browser is the client half of this and it has never asked a real
## `DotServer` anything.[/b] dot-server answers A2S and its own richer protocol; what
## a query returns about the GAME comes from providers like this one, and
## `DotGameDescriptor` alone would say only that the game is called Arena.
##
## The numbers here are the ones a person filtering a server list actually filters on:
## what is being played, on what, how far through it is, and whether it is worth
## joining.
func _build_query_provider() -> void:
	var provider := ArenaQueryProvider.new()
	provider.module = self
	add_query_provider(provider)


## A [DotQueryProvider] over this module. An inner class because it is one method and
## a reference, and a file for it would be a file about nothing else.
class ArenaQueryProvider extends DotQueryProvider:
	var module: ArenaModule = null

	func _provider_name() -> String:
		return "arena"

	func _contribute(snapshot: DotQuerySnapshot) -> void:
		if module == null or module.game == null:
			return

		var game := module.game
		var values := {
			"mode": String(game.mode.id) if game.mode != null else "ffa",
			"mode_name": game.mode.display_name if game.mode != null else "",
			"map": String(game.map.id) if game.map != null else "",
			"score_limit": game.match_node.rules.score_limit,
			"state": DotMatch.State.keys()[game.match_node.state],
			"round": game.match_node.round_number,
			"teams": game.mode.team_count if game.mode != null else 0,
			"monsters": game.horde.count() if game.horde != null else 0,
			"props": game.props.count() if game.props != null else 0,
		}

		if module.maps != null:
			values["next_map"] = module.maps.next_map_hint()
			values["time_left"] = int(module.maps.session.time_limit.remaining)

		if module.vote != null:
			values["voting"] = module.vote.is_voting()
			# The vote's clock is the one that runs when there is a vote; see
			# `_physics_process`. Left out when the vote has none (`rtv_only`,
			# `duration_sec: 0`): a 0 there reads, in a server browser, as a map about to end.
			var clock := DotVoteClockView.state_of(module.vote.director)
			if bool(clock["has_clock"]):
				values["time_left"] = int(clock["seconds_left"])
			else:
				values.erase("time_left")

		snapshot.contribute_game(values)


func _register_game() -> void:
	if server.games == null or server.games.find_game("arena") != null:
		return

	var descriptor := DotGameDescriptor.new()
	descriptor.game_id = "arena"
	descriptor.display_name = "Arena"
	descriptor.scene = ArenaPaths.rebase(ArenaPaths.rebase("res://scenes/arena_server.tscn"))

	# [b]`metadata["module"]`, not `descriptor.module`. There is no such property.[/b]
	# This line read `descriptor.module = "res://game/arena_module.gd"` and Godot
	# refuses a dynamic property on a Resource — so it pushed an error and set
	# nothing, on every registration, and the game descriptor named no module at all.
	#
	# What that would have cost: `changegame arena` loads the scene and no module, and
	# the server then reports "the game loaded but its module did not" — which is
	# exactly the failure this family has already shipped once, from the other end,
	# when a script under `scenes/` never reached a build.
	#
	# `metadata` is where a module path goes, and dot-server-deploy's host reads
	# it from precisely there.
	descriptor.metadata = {
		"module": ArenaPaths.rebase(ArenaPaths.rebase("res://game/arena_module.gd")),
		"kind": "arena",
	}

	server.games.add_game(descriptor)


## `arena_scorelimit`, `arena_timelimit` and `arena_warmup`: the server's numbers over the
## mode's, live and kept across map changes ([member ArenaGame.score_limit]).
##
## [b]`arena_scorelimit` was registered with no handler[/b] and nothing read it, so a game.yml
## or content.yml value was a line in the config and nothing else (the shipped "25" equalled
## the default, which hid it). A cvar writes the game's export, which every match built after
## it reads, and the live match through `_apply_match_limits`, because a server's config is
## applied after this module loads, when the first match is already running. Zero, for the
## two limits, is "the mode's own"; a negative warmup is too.
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
	if game.noblock != null:
		game.noblock.binder.attach(rt)
	if ambient_set != null:
		var _applied := DotGameWorkbench.bind_cvar_set(ambient_set, rt, console)
	if wall_set != null:
		var _wall_applied := DotGameWorkbench.bind_cvar_set(wall_set, rt, console)


func _module_unload() -> void:
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


## [b]Admission finishes AFTER a player is seated[/b], so the name and figure they are
## seated with are a guest's whenever the profile store is slower than the join.
## `player_admitted` is the moment the real ones exist; a new avatar and an operator's
## `platform_name` are the same thing later. All three end in a JOIN to every client,
## which a client already applies to a player it has.
func _wire_identity() -> void:
	if bridge == null:
		return

	bridge.avatar_fn = _avatar_for
	hook_post("player_admitted", _on_profile)
	hook_post("player_avatar_changed", _on_profile)
	hook_post("player_renamed", _on_profile)


## What a session looks like: what dot-platform resolved for them, or null for the stock
## figure. Through the platform module's `player_for`, because the hub keys a player by
## their scoped profile key, which only admission knows. Duck-typed: a server without
## dot-platform is a configuration.
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


# --- Sessions --------------------------------------------------------------

## A client finished the signon and is in the world.
##
## [b]`client_spawn`, not `client_connected`.[/b] A connected client has a socket and
## nothing else — no identity, no content, no confirmation it can load the map. Adding
## them to the match there produces a body for someone who may still fail to join.
func _on_client_spawn(event: DotEvent) -> void:
	# [b]`client_spawn` carries `userid` and `name`. It does not carry `peer_id`.[/b]
	# This read `event.get_int("peer_id")`, which is 0 on every event, so `session_of(0)`
	# returned null and the function returned — **nobody ever joined a dedicated arena
	# server**, silently, for as long as this module has existed. A null session is a
	# legitimate thing to find, so nothing errored, and `dedicated.tscn` passes its
	# twenty-one checks without noticing because it never connects a client.
	#
	# The family's notes have carried this exact bug, found in game-hungario, since
	# before this module was written. Nobody checked here.
	var session := server.session_by_userid(event.get_int("userid"))

	if session == null:
		return

	# dot-moderation's records, checked here rather than at connect.
	#
	# [b]dot-server has its own ban list and this is not it.[/b] Its mute is two
	# booleans on a session object and a session dies with its connection, so a muted
	# player reconnects and talks; dot-moderation's records are durable, expiring and
	# scoped. Both are consulted — dot-server's own admission runs first and this is
	# the second gate.
	if services != null:
		var admitted := services.check_admission(session)

		if not admitted.ok:
			server.kick(session, admitted.error.message)
			return

	_add(session)


func _add(session: DotClientSession) -> void:
	if _joined.has(session.userid):
		return

	# The session id, not the peer id. A peer id is reassigned the moment someone
	# reconnects, and everything downstream of this -- the scoreboard, the combat
	# entity, the damage attribution -- would then be handed to the next player to
	# join. dot-server's userid is stable for the life of the session.
	#
	# Through the bridge, which adds them to the game AND registers them as a
	# replicated entity owned by their peer. `game.add_player` alone gives the server a
	# player nothing is ever sent about: the manager only builds snapshots for peers it
	# knows and only holds an input buffer for those, so the server would simulate them
	# perfectly and alone.
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
	# The kill feed as chat is a placeholder for a real one, and it is deliberately
	# not nothing: a dedicated server with no HUD still has to be able to show an
	# operator what is happening in the match it is running.
	if server.chat == null:
		return

	server.broadcast_message(str(entry))


# --- Events from the rest of the server -------------------------------------

## A player typed `!something`.
##
## [b]Claimed, or it is broadcast as chat.[/b] dot-chat holds a command until somebody
## says they handled it; an unclaimed one with `broadcast_unknown_commands` off is
## simply dropped, which means a player typing `!rtv` on a server where the vote failed
## to load gets silence rather than "there is no vote here".
func _on_chat_command(peer: int, command: String, args: PackedStringArray) -> void:
	var session := server.session_of(peer)

	if session == null:
		return

	# [b]The vote's own commands are not here.[/b] `!rtv`, `!nominate`, `!vote`,
	# `!nextmap` and `!timeleft` are dot-vote's, registered on the console by
	# `ArenaVote.install_commands` with `.with_chat()`, and an unclaimed `!` line carries
	# on to the console. This handler answered all five itself once, beside a console with
	# none of dot-vote's operator commands: two paths to one director, one of them without
	# `setnextmap`. Only a server whose vote did not load answers them here, so a player
	# gets "no vote" rather than silence.
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


## The map changed, whatever caused it — a vote, a rotation, or an admin typing it.
##
## [b]This is the one call site that tells the vote what is running, and having two is
## the bug.[/b] `DotVoteDirector.begin_on_apply` is off precisely so that this signal
## is the only source: it fires for an operator's `arena_map` as well as for a voted
## change, and both firing means two entries in the play history for one play — a
## "not in the last five" cooldown that is quietly a cooldown of two or three.
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

	# [b]Every `return` point is a place on the map that just went.[/b] DotModTools
	# keeps a stack of positions per player, and without this `return Ada` after a
	# change put her where she had stood on the previous map, inside whatever the new
	# one has there. `[modtools-return-1]`; playground, hungario and the lobby do the
	# same.
	if services != null and services.mod_tools != null:
		services.mod_tools.clear_history()

	if services != null:
		services.announce("Now playing %s." % map.name_or_id())

	_report_map(String(map.id))

	log_info("map changed", {"map": String(map.id)})


## Tells dot-server which map this is, so A2S and DQP print it in their map field (and
## the backbone report does too) rather than this game's content id.
func _report_map(map_id: String) -> void:
	if server != null and server.games != null:
		server.games.set_current_map(map_id)


## The map's clock ran out.
##
## The director deliberately does not act on it: on a server with a vote the answer is
## "open the ballot" and on one without it is "next in rotation", and only this file
## knows which of those this server is.
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


# --- Commands --------------------------------------------------------------

## The commands that only exist once the optional halves loaded.
##
## Registered after them rather than beside the others, because a command that reports
## on a subsystem that failed to load is a command whose only possible answer is "that
## is not running" — and an operator reading the command list should see what this
## server actually has.
func _add_extra_commands() -> void:
	if maps != null:
		# CHANGEMAP and nothing else, like g2gfast's. A map change ends every round in
		# progress — which is an argument about who may do it, not about where they typed
		# it, and the flag is what settles that on every source alike. It was console-only
		# once, and the refusal that produced landed on operators holding the flag rather
		# than on the players it was written for. `sv_chat_commands 0` puts that back for a
		# deployment that wants it.
		add_command(
			"arena_map", _cmd_map,
			"Change the map: arena_map <id>", DotAdminFlags.CHANGEMAP
		)
		add_command(
			"arena_nextmap", _cmd_nextmap, "What plays next", ""
		)

		# `map`, `maps` and `mapinfo` come from dot-map itself. They were dot-server's
		# `map`, which changed the GAME -- and on a server running one game and several
		# maps, that is the one thing an operator typing `map` does not mean. dot-server's
		# game change is `changelevel`, `game` and `gamechange` now.
		#
		# `allow_chat_change` is left at its default, which is ON, matching `arena_map`
		# beside it: CHANGEMAP decides who may end a round in progress, wherever the line
		# was typed. A relayed website command arrives as `Source.CHAT` and now reaches it
		# on the same terms; `DotChatRelayConfig.command_source` still promotes a relay to
		# RCON for an operator who wants their site admins treated as administrators.
		# The SYNC HOST as the changer, not the session: a map change on this server has to
		# reach the clients, and `ArenaMapDirector.session` on its own swaps the world in
		# this process and tells nobody -- which is the absence dot-map's own notes call
		# "the structural one".
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



## Set while a refused mode change is being put back, so the `changed` handler does not
## run on its own correction.
##
## A cvar's `changed` signal fires for every write, including the one that undoes a
## refusal — and without this the undo is a second mode change, which fails for the same
## reason, and undoes itself. One flag, and the alternative is a stack overflow the first
## time somebody types a mode that does not exist.
var _reverting_mode: bool = false


## Every mode id, for a cvar's help line and for a refusal that names the alternatives.
static func _mode_ids() -> PackedStringArray:
	var out := PackedStringArray()

	for id in ArenaModes.ids():
		out.append(String(id))

	return out


## `arena_mode <id>` — switch what is being played, under the players standing in it.
func _change_mode(old_value: String, new_value: String) -> void:
	if _reverting_mode or new_value == old_value:
		return

	var wanted := ArenaModes.by_id(StringName(new_value))

	if wanted == null:
		# Refused and put back, rather than left showing a mode the game is not
		# playing. A cvar that reads as `koth` on a server running free-for-all is
		# worse than one that refused: an operator believes it.
		log_warn("no such mode", {"wanted": new_value, "known": str(_mode_ids())})
		_revert_mode(old_value)
		return

	var map := game.map

	if wanted.preferred_map != &"" and wanted.preferred_map != map.id:
		var preferred := ArenaMap.by_id(wanted.preferred_map)

		if preferred != null:
			map = preferred

	var changed := game.change_map(map, wanted)

	if not changed.ok:
		log_warn("the mode did not change", {"why": changed.error.message})
		_revert_mode(old_value)
		return

	log_info("the mode changed", {
		"mode": new_value,
		"map": String(game.map.id),
		"objectives": String(game.mode.objective_layout),
	})


## Put the cvar back to what the game is actually playing.
##
## Refused and put back rather than left showing a mode the game is not playing: a cvar
## that reads `koth` on a server running free-for-all is worse than one that refused,
## because an operator believes it.
func _revert_mode(value: String) -> void:
	_reverting_mode = true
	var _res := server.console.set_cvar("arena_mode", value)
	_reverting_mode = false


func _cmd_modes(ctx: DotCmdContext) -> void:
	ctx.reply_lines(PackedStringArray(ArenaModes.describe_lines()))
	ctx.reply("Playing: %s" % String(game.mode.id))


func _cmd_net(ctx: DotCmdContext) -> void:
	if net == null:
		ctx.reply("The netcode is not running.")
		return

	for line in net.describe_lines():
		ctx.reply(line)

	if bridge != null:
		ctx.reply(str(bridge.describe()))


func _cmd_status(ctx: DotCmdContext) -> void:
	for line in game.describe_lines():
		ctx.reply(line)


## What `arena_maps` prints.
##
## [b]It lists and does not change, and that is the whole state of map handling here.[/b]
## `ArenaGame.setup` is not re-entrant — it builds the combat trace, the match node and
## every spawn point as children in one pass — so a `changelevel` that called it twice
## would leave two matches and two sets of spawns in one tree. The command that would
## do it properly has to tear that down and tell every connected client, which is a
## feature and not a line. Until then an operator restarts with `-- --map <id>`, and
## this is how they find out what to type.
func _cmd_maps(ctx: DotCmdContext) -> void:
	var current := game.map.display_name if game.map != null else "?"

	for id in ArenaMap.ids():
		ctx.reply("%s %s%s" % [
			"*" if String(id) == current else " ", String(id),
			"" if _in_rotation(id) else "  (not in rotation)",
		])

	# The imported maps, with their author (somebody else's work, and the credit travels
	# with it) and whether the rotation offers them.
	for id in ArenaMap.imported_ids():
		var author := str(ArenaMap.ArenaImportedMaps.manifest(id).get("author", "?"))
		var walked := ArenaMap.ArenaImportedMaps.movement_of(id) == &""
		ctx.reply("%s %s  (%s by %s%s)" % [
			"*" if String(id) == current else " ", String(id),
			"deathmatch" if walked else "combat surf", author,
			"" if ArenaMaps.in_rotation(id) and _in_rotation(id) else ", not in rotation",
		])

	# The maps the server names as packs: fetched the first time one is changed to.
	if maps != null and maps.session != null and maps.session.catalogue != null:
		for def in maps.session.catalogue.maps:
			if not ArenaMaps.is_delivered(def):
				continue

			ctx.reply("%s %s  (delivered: %s%s%s)" % [
				"*" if game.map != null and game.map.id == def.id else " ", String(def.id),
				str(def.meta.get("key", "")),
				", mounted" if ArenaMap.ArenaImportedMaps.is_mounted(def.id) else ", fetched on change",
				"" if def.enabled and def.in_rotation else ", not in rotation",
			])

	ctx.reply("`arena_map <id>` changes it under the players. `arena_maps` lists them.")


## Whether maps.yml's active rotation plays [param id]. A map the catalogue lacks is not.
func _in_rotation(id: StringName) -> bool:
	if maps == null or maps.session == null or maps.session.catalogue == null:
		return true

	var def := maps.session.catalogue.get_map(id)

	return def != null and def.in_rotation


func _cmd_score(ctx: DotCmdContext) -> void:
	for line in game.match_node.scoreboard.describe_lines():
		ctx.reply(line)


func _cmd_restart(ctx: DotCmdContext) -> void:
	game.start(game.current_tick())
	ctx.reply("Match restarted.")


## Disconnects a peer whose message schema this server cannot play with, with dot-net's
## sentence as the reason. See `peer_schema_refused` above.
func _refuse_peer(peer_id: int, error: DotError) -> void:
	var session: DotClientSession = server.session_of(peer_id) if server != null else null
	if session != null:
		server.kick(session, error.message, error)
