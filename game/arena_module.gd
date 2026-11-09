extends "arena_module_b2.gd"


const ArenaTeamMenu := preload("arena_team_menu.gd")


func _module_name() -> String:
	return "arena"


func _map_config_game() -> String:
	return "game-arena"


## FFA stays solid; see [method ArenaGame.block_side].
func _noblock_side(id: Variant) -> Variant:
	return game.block_side(id)


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
	_add_tag_cvars()
	_add_drop_cvars()
	_add_knife_cvars()
	_add_ctf_cvars()
	game.ctf_announced.connect(func(text: String) -> void:
		if services != null:
			services.announce(text))
	_add_jail_cvars()
	_add_spawn_cvars()
	_add_team_spawn_split_cvar()
	_add_loadout_roll_text_cvar()
	_add_unlag_cvar()
	_add_stats_report_cvar()
	_add_rank_cvar()
	_add_fire_buffer_cvar()
	_add_bot_think_cvars()
	_add_grenade_cvars()
	var _glass_cvars := game.glass_rules.bind_cvars(add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY)
	_add_rate_cvar()
	_add_snapshot_rate_cvar()
	_add_aoi_cvars()
	if game.config_binder != null:
		game.config_binder.bind_cvars(add_cvar, DotConVar.FLAG_ARCHIVE, console.has_name)
		game.config_binder.bind_commands(add_command)
	var _fl := game.flashlight_conf()
	if game.flashlight_binder != null:
		var _fl_cvars := game.flashlight_binder.bind_cvars(add_cvar, DotConVar.FLAG_ARCHIVE, console.has_name)
		game.flashlight_binder.bind_commands(add_command)
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
	game.loadout_rolled.connect(
		func(player_id: int, text: String) -> void:
			var peer := bridge.peer_for_session(player_id) if bridge != null else 0
			if services != null and peer != 0:
				services.notice(peer, text)
	)
	game.streak_reward.connect(
		func(player_id: int, streak: int, reward: String) -> void:
			var who := game.player_for(player_id)
			if services != null:
				services.announce(
					"%s is on a %d kill streak: %s" % [who.display_name if who != null else "?", streak, reward]
				)
	)

	# npc_skill, npc_reaction_scale, npc_reaction_min. Registered whether or not this mode has
	# monsters, so a config that sets them does not fail on a deathmatch map and then not apply when
	# the rotation reaches a horde one.
	game.npc_skill.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY)

	# Whether shots pass through team-mates: `mp_teammate_passthrough` 0 never, 1 a team-mate
	# holding the muzzle (the default), 2 every team-mate in the line.
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

	# The team menu (period): mp_teamswitch_*, mp_team_names, mp_team_colours, mp_team_max and the `teams` command.
	team_menu = ArenaTeamMenu.new()
	team_menu.bind(game, add_cvar, self)

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

	# [b]How many players before a round starts, and it has to be an operator's choice.[/b] The
	# default is 2, which is right for a deathmatch and makes a public demonstration server look
	# broken: one person connects, the match sits in WARMUP for ever, nobody spawns.
	_bot_quota = DotBotQuota.install(self, game.config.bot_quota)

	# [b]How the bots play[/b]: dot-bot's `bot_difficulty` (easy, medium, hard, nightmare; medium by
	# default) and every `bot_*` setting it bundles, each overridable.
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

	# **What is being played, on a running server.**  Without this the two modes that are not about
	# killing people are unreachable from a deployment: `ArenaGame.mode_id` is an export read once
	# at setup, and a vote can offer a mode only where somebody has configured one.
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

	# Everything below this line is optional in the sense that the game runs without it. None of it
	# is optional in the sense that matters: a server with no chat, no rotation and no vote is a
	# server nobody stays on.
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
		# The boot map never fires map_changed, so its PVS is attached here.
		_attach_visibility(game.map)

	log_info("arena loaded", {"map": game.map.display_name})
	return DotResult.success(null)


# --- Commands --------------------------------------------------------------


func _cmd_restart(ctx: DotCmdContext) -> void:
	game.start(game.current_tick())
	ctx.reply("Match restarted.")
