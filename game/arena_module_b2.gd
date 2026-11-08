extends "arena_module_b1.gd"

const ArenaPaths := preload("arena_paths.gd")


const ArenaEvents := preload("arena_events.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const DotGameRelevance := preload("res://addons/dot_game/net/dot_game_relevance.gd")
const ArenaMaps := preload("arena_maps.gd")
const ArenaModTools := preload("arena_mod_tools.gd")
const ArenaModes := preload("arena_modes.gd")
const ArenaModule := preload("arena_module.gd")


## The drawn map ballot's notice topic. The client shell draws one menu per topic, and a
## server running several games sends its own `game_ballot` beside this one.
const MAP_BALLOT_TOPIC := &"map_ballot"


## dot-platform's own module, loaded beside this one. A path, because that is what
## [code]DotModuleHost.load_module[/code] takes — see [method _build_identity].
const PLATFORM_MODULE_PATH := "res://addons/dot_platform/dot_platform_module.gd"


## Where the services keep punishments. Empty is dot-moderation's own default,
## `user://moderation.json` — the store a real server enforces.
static var punishments_file: String = ""


## The live tools' commands. See [method _build_mod_commands].
var mod_commands: DotModToolCommands = null


## The authoritative tick. Counted here because the module is what drives it.
var _tick: int = 0


## Binds dot-audio's sv_surf_* cvars with the `surf_*` profile values as their defaults, which every client follows.
func _bind_surf_cvars(flags: int) -> void:
	var values := game.config.surf_values()
	for spec: Dictionary in preload("res://addons/dot_game/runtime/dot_game_slide_sounds.gd").surf_cvar_specs():
		var key := String(spec["name"]).trim_prefix("sv_surf_")
		var v: Variant = values.get(key, spec["value"])
		var text := ("1" if v else "0") if v is bool else str(v)
		var cv := add_cvar(String(spec["name"]), text, String(spec["description"]), flags)
		if cv != null:
			cv.with_range(float(spec["min"]), float(spec["max"]))


## Binds the cvars of the game's rule sets (fall, ragdoll, toys, views, spectate, bodies, noblock, feel).
func _bind_rule_cvars() -> void:
	# Replicated where each client draws or predicts under the rule; the rules are the game's, so one bind lasts.
	var replicated := DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	# sv_falldamage and its tunables: dot-combat's, on here (not on surf maps); server side, the damage arrives as health.
	var _fall := game.fall_rules.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY)

	# Dead bodies: dot-player-char's sv_ragdoll* (the server picks each reaction, ArenaGame.decide_death).
	var _ragdoll_cvars := game.ragdoll_rules.bind_cvars(add_cvar, replicated)
	var _weapon_drop_cvars := game.weapon_drop_rules.bind_cvars(add_cvar, replicated)  # sv_weapon_drop*
	var _use_cvars := game.map_use.bind_cvars(add_cvar, replicated)  # sv_use_reach, sv_use_cooldown

	# The map's toys: dot-props' sv_toys, sv_toys_awake, sv_toys_push.
	var _toy_cvars := game.toy_rules.bind_cvars(add_cvar, replicated)

	# mp_forceview: free view (0), held in first (1) or third (2) person.
	var _view_cvars := game.view_rules.bind_cvars(add_cvar, replicated)

	# mp_killview*: dot-replay's kill view.
	var _killview_cvars := game.killview_rules.bind_cvars(add_cvar, replicated)

	# snd_shot_*: dot-audio's DotShotRules (layered shots, room tails).
	var _shot_cvars := game.shot_rules.bind_cvars(add_cvar, replicated)

	# arena_ambient*: dot-audio's DotAmbienceRules; the directory cvar stays local.
	var _ambient_cvars := game.ambient_rules.bind_cvars(add_cvar, replicated, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY)

	# mp_forcecamera, mp_freeroam, mp_freeroam_speed: dot-spectate's rules (ArenaClient.toggle_roam).
	var _spectate_cvars := game.spectate_rules.bind_cvars(add_cvar, replicated)

	_bind_surf_cvars(replicated)

	# mp_solidplayers: players and bots stop at each other (1) or pass through (0) (ArenaGame.solid_hulls_for).
	var _solid_cvars := game.body_rules.bind_cvars(add_cvar, replicated)

	# mp_teamblock, mp_enemyblock, !block / !noblock: dot-game's module builds DotGameNoblock after this load.

	# mp_vm_sway* and friends: arena-weapons' view model feel, drawn on each client.
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
	config.snapshot_rate = ArenaGame.snapshot_rate_for(game.tick_rate, snapshot_target())
	config.enable_prediction = true
	# On: a player shoots where they SEE someone, which is where that player was half a round trip ago.
	config.enable_lag_compensation = true
	config.max_entities_per_snapshot = 0  # unlimited: interest management and the mtu bound a snapshot
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

	# net_skip_idle and net_visibility, the switches dot-game's own games get from DotGameNetcode (dot-game 52; by name, so an older host still parses this).
	if DotAddonApi.build_level("dot_game") >= 52:
		(DotGameRelevance as GDScript).call(&"bind_toggles", console, net)

	bridge = ArenaNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	var attached := bridge.attach(game, net)

	if not attached.ok:
		return attached

	# Under the DotServer node, whose name is the first half of the RPC routing. The
	# client parents its copy under `DotClientLink`, which is named to match.
	bridge.open_link(server)

	# The switch a server owner uses to forbid clients' artificial lag; dot-game's module does the same.
	var _latency := net.latency.bind_server_cvar(Callable(self, "add_cvar"), DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED)

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


## Content, profiles, avatars and admission.
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
		_refresh_aoi()

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

	_follow_npc_lod(game.horde.spawner if game != null and game.horde != null else null, delta)


## The NPC level of detail and sense workers follow the `npc_lod*` cvars (dot-game's DotGameNpcLod; all off by default). This module is a DotModule, so it holds the attachment itself.
var _npc_lod: DotGameNpcLod = null


func _follow_npc_lod(spawner: Object, delta: float) -> void:
	if spawner == null or console == null:
		return
	if _npc_lod == null or _npc_lod.spawner != spawner:
		if _npc_lod != null:
			_npc_lod.release()
		_npc_lod = DotGameNpcLod.attach(self, console, spawner, server.config if server != null else null)
	if _npc_lod != null:
		_npc_lod.follow(delta)


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
		ctx.reply("%s %s  (%s by %s%s)" % [
			"*" if String(id) == current else " ", String(id),
			ArenaMaps.imported_label(id).to_lower(), author,
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


## Disconnects a peer whose message schema this server cannot play with, with dot-net's
## sentence as the reason. See `peer_schema_refused` above.
func _refuse_peer(peer_id: int, error: DotError) -> void:
	var session: DotClientSession = server.session_of(peer_id) if server != null else null
	if session != null:
		server.kick(session, error.message, error)
