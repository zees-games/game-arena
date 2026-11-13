@tool
extends "arena_game_part1.gd"

func _loadout_key(id: int) -> String:
	return loadout_identity.key_of(id)

## Applies a player's saved loadout. Falls back to the default on any failure: a failure here must never stop a player spawning,
## and an unreachable loadout store is a reason to give them a rifle, not to leave them watching.
func apply_loadout(id: int, at_spawn := false) -> void:
	var player := player_for(id)

	if player == null:
		return

	if at_spawn and (player.has_meta(&"bot") or id >= BOT_SESSION_BASE) and _give_bot_loadout(player):
		return

	if at_spawn and loadout_command != null and not player.has_meta(&"bot") and id < 900_000_000:
		var rolled: DotLoadout = await loadout_command.roll_for_spawn(_loadout_key(id))
		player = player_for(id)
		if rolled != null and player != null:
			player.give_loadout(ArenaContent.in_give_order(loadouts.resolve(rolled)))
			arm_for_mode(player)
			if loadout_roll_text:
				loadout_rolled.emit(id, loadout_command.spawn_text(rolled))
			return
		if player == null:
			return

	var res: DotResult = await loadouts.active_for(_loadout_key(id))

	if not res.ok:
		DotLog.debug(CHANNEL, "loadout unavailable, using the default", {
			"player": id, "error": str(res.error)
		})
		player.give_default_loadout()
		arm_for_mode(player)
		return

	player.give_loadout(ArenaContent.in_give_order(loadouts.resolve(res.value)))
	arm_for_mode(player)

## Gives bot [param player] the next kit it draws from [member bot_loadouts]; false (the bot then
## takes the stored or default loadout) when no kit can be drawn. The difficulty filter reads the
## server's `bot_difficulty`.
func _give_bot_loadout(player: ArenaPlayer) -> bool:
	if loadouts == null:
		return false
	if bot_loadouts == null:
		bot_loadouts = ArenaBotLoadouts.new()
		DotLog.info(CHANNEL, "bot loadouts loaded", {"kits": bot_loadouts.load_from(), "sv_bot_loadouts": ArenaBotLoadouts.mode})
	var difficulty := ""
	if has_meta(DotBotSettings.META):
		difficulty = DotBotSettings.of(self).difficulty()
	var drawn := bot_loadouts.draw(loadouts, _loadout_key(player.player_id), player.player_id, difficulty)
	if drawn == null:
		return false
	player.give_loadout(ArenaContent.in_give_order(loadouts.resolve(drawn.loadout)))
	player.set_meta(&"bot_loadout", drawn.kit.id)
	_fit_bot_attachments(player, drawn.kit)
	arm_for_mode(player)
	return true

## Fits [param kit]'s attachments to the guns [param player] carries, through the arsenal's attachments catalogue.
func _fit_bot_attachments(player: ArenaPlayer, kit: ArenaBotLoadouts.Kit) -> void:
	if kit.attachments.is_empty() or player.arsenal.attachments == null:
		return
	for slot in player.arsenal.slots():
		var held := player.arsenal.slot_at(slot)
		if held == null or held.def == null or not kit.attachments.has(String(held.def.id)):
			continue
		var fitting := DotWeaponFitting.make(held.def.id)
		var mounts: Variant = kit.attachments[String(held.def.id)]
		if mounts is Dictionary:
			for mount: Variant in mounts:
				fitting.fit(StringName(str(mount)), StringName(str(mounts[mount])))
		var res: DotResult = player.arsenal.fit(slot, fitting)
		if not res.ok:
			DotLog.debug(CHANNEL, "a bot attachment did not fit", {"kit": String(kit.id), "weapon": String(held.def.id), "error": str(res.error)})

## Why the B menu has nothing to choose right now, or "": a mode that decides what everybody
## carries (gun game, Only Snipers) makes a loadout pointless, and the menu says so rather than
## saving a choice the next spawn throws away.
func loadout_closed_reason() -> String:
	if mode != null and mode.arms_players():
		return "%s hands out the weapons. Your loadout is kept for the next mode." % mode.display_name
	return ""

func players() -> Array[ArenaPlayer]:
	var out: Array[ArenaPlayer] = []
	for key in _players.keys():
		out.append(_players[key])
	return out

## The facts DotLoadoutInstantSwap judges for a loadout key: seconds since spawn and last shot
## (-1: none) and metres to the nearest living enemy (-1: none).
func loadout_instant_facts(key: String) -> Dictionary:
	var id := loadout_identity.id_of(key)
	var rate := float(maxi(tick_rate, 1))
	var out := {"now": float(_tick) / rate, "since_spawn": -1.0, "since_fire": -1.0, "enemy_dist": -1.0}
	var me := player_for(id)
	if me == null or not me.is_alive():
		return out
	if _spawned_tick.has(id):
		out["since_spawn"] = float(_tick - int(_spawned_tick[id])) / rate
	if _fired_tick.has(id):
		out["since_fire"] = float(_tick - int(_fired_tick[id])) / rate
	var my_team := team_of(id)
	var best := -1.0
	for other in players():
		if other == me or not other.is_alive():
			continue
		var oid: int = other.player_id
		if my_team != 0 and team_of(oid) == my_team:
			continue
		var d := me.global_position.distance_to(other.global_position)
		if best < 0.0 or d < best:
			best = d
	out["enemy_dist"] = best
	return out

## Hands [param id]'s saved loadout over now (the instant-swap rule has already agreed).
func rearm_instant(id: int) -> bool:
	var player := player_for(id)
	if not is_authority or player == null or not player.is_alive():
		return false
	await apply_loadout(id)
	return true

## Whether a new loadout goes into [param id]'s hands now rather than at the next spawn: in
## warmup, and while their spawn protection lasts (they have not been in a fight with what they
## spawned holding). Anything later would be a free reload and a weapon swap mid-fight.
func loadout_now_allowed(id: int) -> bool:
	var player := player_for(id)
	if player == null or not player.is_alive():
		return false
	if match_node != null and match_node.state == DotMatch.State.WARMUP:
		return true
	return player.health != null and player.health.is_protected(_tick)

## Puts [param id]'s saved loadout in their hands when [method loadout_now_allowed]. True when it
## did. Authority only: the arsenal replicates from here.
func rearm_if_allowed(id: int) -> bool:
	if not is_authority or not loadout_now_allowed(id):
		return false
	await apply_loadout(id)
	DotLog.debug(CHANNEL, "loadout handed over at once", {"player": id})
	return true

## The B menu's server half, when the host's dot-loadout has one (API 2).
func _build_loadout_command() -> void:
	if DotAddonApi.build_level("dot_loadout") < 2 or not ResourceLoader.exists(LOADOUT_COMMAND_SCRIPT):
		return
	loadout_command = (load(LOADOUT_COMMAND_SCRIPT) as GDScript).new()
	loadout_command.set(&"manager", loadouts)
	# The player a command came from: the session's userid, which is this game's player id.
	loadout_command.set(&"key_fn", func(ctx: Object) -> String:
		var session: Variant = ctx.get(&"session") if ctx != null else null
		return _loadout_key(int((session as Object).get(&"userid"))) if session is Object else "")
	loadout_command.set(&"closed_fn", func(_key: String) -> String: return loadout_closed_reason())
	# Default ON here (sv_loadout_instant_after_spawn); the addon's own default is off.
	var instant: Variant = loadout_command.get(&"instant")
	if instant is Object:
		(instant as Object).set(&"enabled", true)
	loadout_command.set(&"instant_facts_fn", loadout_instant_facts)
	loadout_command.set(&"instant_apply_fn", func(_ctx: Object, key: String) -> bool:
		return await rearm_instant(loadout_identity.id_of(key)))
	loadout_command.set(&"item_alias_fn", Callable(ArenaContent.Roles, &"alias"))
	loadout_command.set(&"applied_fn", func(_ctx: Object, key: String) -> bool:
		return await rearm_if_allowed(loadout_identity.id_of(key)))
	# DotNotice drops data holding a PackedStringArray (the offer's tags), so a client over a link got an empty answer and B opened nothing.
	loadout_command.set(&"notice_fn", _send_loadout_notice)


func _send_loadout_notice(ctx: Object, data: Dictionary) -> bool:
	var session: Variant = ctx.get(&"session") if ctx != null else null
	var server: Object = DotRegistry.get_service(&"dot_server")
	if not (session is Object) or server == null or not server.has_method(&"send_notice"):
		return false
	var topic: StringName = loadout_command.get_script().get_script_constant_map().get("TOPIC", &"loadout_menu")
	return bool(server.call(&"send_notice", session, DotNotice.make(&"", "", -1.0, topic, plain_data(data) as Dictionary)))


## [param value] with every PackedStringArray turned into an Array, which DotNotice carries.
static func plain_data(value: Variant) -> Variant:
	if value is PackedStringArray:
		return Array(value as PackedStringArray)
	if value is Array:
		return (value as Array).map(func(v: Variant) -> Variant: return plain_data(v))
	if value is Dictionary:
		var out := {}
		for k: Variant in value:
			out[k] = plain_data((value as Dictionary)[k])
		return out
	return value

## The loadout manager; and its B-menu command too unless [param with_command] is false (setup builds that a step later: its script load was a third of this step).
func _build_loadouts(with_command := true) -> DotResult:
	loadouts = DotLoadoutManager.new()
	loadouts.name = "Loadouts"
	loadouts.schema = ArenaContent.loadout_schema()
	loadouts.register_service = false

	var config := DotLoadoutConfig.new()
	config.backend = "local"
	config.allow_default_loadout = true
	config.conform_on_load = true
	loadouts.config = config
	loadouts.store = ArenaLoadoutIdentity.make_store()

	# Everything in this game is free except the launcher, and there is no entitlement
	# service to ask. A game with unlocks binds a real source here; leaving it unset means
	# only `free` items, which is dot-loadout's loud default.
	loadouts.entitlement_source = func(_key: String) -> DotLoadoutEntitlements:
		var owned: Array = [ArenaContent.PAID_WEAPON]
		if utility_grenades:
			owned.append_array(ArenaGrenades.utility_ids(ArenaContent.weapons()))
		return DotLoadoutEntitlements.of(owned)
	# Adds what the site store says the player owns (no-op without a backbone client).
	DotGameStoreEntitlements.attach(loadouts)

	add_child(loadouts)
	if with_command:
		_build_loadout_command()
	return DotResult.success(null)

## Statistics, achievements and boards, if this instance keeps any.
func _build_player_stack() -> DotResult:
	if player_stack != null:
		player_stack.queue_free()

	player_stack = ArenaPlayerStack.new()
	player_stack.name = "PlayerStack"
	# A client mirrors what the server decided; re-applying a physics profile there
	# would have it simulate at a rate the server does not.
	player_stack.apply_physics = is_authority
	player_stack.register_service = register_service
	add_child(player_stack)

	return player_stack.setup(self).wrap("The arena's player stack")

func _build_progress() -> DotResult:
	if not track_progress or not is_authority:
		return DotResult.success(null)

	progress = ArenaProgress.new()
	progress.name = "Progress"
	progress.progress_dir = progress_dir
	add_child(progress)

	var attached := progress.attach(self)

	if not attached.ok:
		# A game with no statistics is a game. A game that refuses to start because a
		# leaderboard definition was rejected is not, and this is the same call
		# `apply_loadout` makes about an unreachable store.
		DotLog.warn(CHANNEL, "progression is off", {"why": attached.error.message})
		remove_child(progress)
		progress.queue_free()
		progress = null

	return DotResult.success(null)

## The spectate layer, on every side. Idempotent.
func _build_spectate() -> void:
	if spectate != null:
		return

	spectate = ArenaSpectate.new()
	spectate.name = "Spectate"
	spectate.game = self
	add_child(spectate)

	var spectate_ready := spectate.setup()

	if not spectate_ready.ok:
		DotLog.warn(
			CHANNEL, "spectating is off", {"why": spectate_ready.error.message}
		)
		remove_child(spectate)
		spectate.queue_free()
		spectate = null

## A client mirrors the flag layer only: it draws the flags and applies the carrier's slowdown, and the server sends the state.
func _reconcile_client_objectives() -> void:
	# The mode the server says (RULES mode_index), not the client's own `mode`, which is never
	# replaced and read free-for-all on every dedicated server: no flag layer, no flags drawn.
	var played: ArenaMode = shown_mode if shown_mode != null else mode
	if played == null or played.objective_layout != &"ctf":
		if objectives != null:
			remove_child(objectives)
			objectives.queue_free()
			objectives = null
		return
	if objectives != null:
		return
	objectives = ArenaObjectives.new()
	objectives.name = "Objectives"
	objectives.game = self
	add_child(objectives)
	var res := objectives.setup()
	if not res.ok:
		DotLog.warn(CHANNEL, "the client flag layer is off", {"why": res.error.message})
		remove_child(objectives)
		objectives.queue_free()
		objectives = null


## Build whatever is missing. Idempotent, because [method _reconcile_world_layers] calls it on every
## map change as well as at setup.
func _build_world_layers() -> void:
	if not is_authority or mode == null:
		return

	# Effects first, and the order matters: ArenaObjectives asks the effects layer whether a player
	# may capture, and a layer that is not there yet answers "no layer", which is a legitimate
	# answer and would silently let an invulnerable player take a point.
	if effects == null:
		effects = ArenaEffects.new()
		effects.name = "Effects"
		effects.game = self
		add_child(effects)

		var effects_ready := effects.setup()

		if not effects_ready.ok:
			DotLog.warn(CHANNEL, "effects are off", {"why": effects_ready.error.message})
			remove_child(effects)
			effects.queue_free()
			effects = null

	_build_spectate()

	if mode.objective_layout != &"" and objectives == null:
		objectives = ArenaObjectives.new()
		objectives.name = "Objectives"
		objectives.game = self
		add_child(objectives)

		var objectives_ready := objectives.setup()

		if not objectives_ready.ok:
			DotLog.warn(
				CHANNEL, "objectives are off", {"why": objectives_ready.error.message}
			)
			remove_child(objectives)
			objectives.queue_free()
			objectives = null

	if (mode.player_props or mode.scatter_props > 0) and props == null:
		props = ArenaProps.new()
		props.name = "Props"
		props.game = self
		props.players_may_spawn = mode.player_props
		props.scatter_count = mode.scatter_props
		add_child(props)

		var props_ready := props.setup()

		if not props_ready.ok:
			DotLog.warn(CHANNEL, "props are off", {"why": props_ready.error.message})
			remove_child(props)
			props.queue_free()
			props = null

	if not mode.horde or horde != null:
		return

	horde = ArenaHorde.new()
	horde.name = "Horde"
	horde.game = self
	add_child(horde)

	var horde_ready := horde.setup()

	if not horde_ready.ok:
		DotLog.warn(CHANNEL, "the horde is off", {"why": horde_ready.error.message})
		remove_child(horde)
		horde.queue_free()
		horde = null
		return

	horde.enabled = true
