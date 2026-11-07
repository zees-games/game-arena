@tool
extends "arena_game_part1.gd"

## Deals an imported map's hurt volumes (`trigger_hurt`) to everybody standing in one, as
## world damage through dot-combat.
##
## [b]Real damage, where game-g2gfast's is "100 or more is a death, the rest ignored"[/b],
## because a timer run has no health and this game does. The engine these maps come from
## reads the volume's `damage` as per second and deals it every half second, the first
## pulse on entering; this does the same, through [method DotCombatManager.apply_damage]
## with attacker 0, so the resolver, armour (the world type ignores it), spawn protection,
## the kill feed, the scoreboard and the statistics all hear it as they hear a fall. A
## negative amount heals, as it does there (surf_forbidden_ways_reloaded has one).
##
## On the authority only: health is the server's and replicates, so a client predicting a
## hurt would only be corrected. Its movement half (where the player is) is already
## predicted, which is all this reads.
func _hurt_from_map() -> void:
	if map == null or map.mechanics == null or map.mechanics.hurt.is_empty():
		return

	var interval := maxi(1, roundi(ArenaMap.ArenaMapMechanics.HURT_INTERVAL * float(tick_rate)))

	# Due ticks are per player AND per volume, and kept when the player steps out: the
	# half second belongs to the volume, so a hull bobbing across a thin sheet's edge (a
	# hop, water) takes one pulse per interval rather than one per re-entry. An entry whose
	# tick has passed means the same as none, so those go, and the table stays small.
	for key: Vector2i in _hurt_due.keys():
		if int(_hurt_due[key]) <= _tick:
			var _gone: bool = _hurt_due.erase(key)

	for id in player_ids():
		var player: ArenaPlayer = _players[id]
		var state := player.controller.state
		if not player.is_alive() or state.mode == DotFpsState.Mode.NOCLIP:
			continue

		for i in map.mechanics.hurts_at(state.position, player.controller.tunables, state.crouch_fraction):
			var key := Vector2i(id, i)
			if _hurt_due.has(key):
				continue
			_hurt_due[key] = _tick + interval

			var amount := float(map.mechanics.hurt[i]["damage"]) * ArenaMap.ArenaMapMechanics.HURT_INTERVAL
			if amount < 0.0:
				var _healed := player.health.heal(-amount)
				continue
			if amount == 0.0 or not player.is_alive():
				continue

			var damage := DotDamage.make(0, id, amount, combat.damage_type(ArenaContent.DAMAGE_WORLD))
			damage.tick = _tick
			var _dealt := combat.apply_damage(damage)

## Whether the round is waiting to go live with everyone held still. The client reads the
## state MATCH told it; a countdown only exists when its length is above zero.
func round_frozen() -> bool:
	return match_node != null and match_node.state == DotMatch.State.COUNTDOWN \
			and match_node.rules != null and match_node.rules.freeze_during_countdown

func _freeze_for_round(id: int, player: ArenaPlayer) -> void:
	if _round_frozen_ids.has(id) or DotFpsAdminModifiers.is_frozen(player.controller):
		return
	var held := {"god": player.health.invulnerable}
	_round_frozen_ids[id] = held
	player.health.invulnerable = true
	player.arsenal.disabled = true
	var _r := DotFpsAdminModifiers.set_frozen(player.controller, true)

func _release_from_round(id: int, player: ArenaPlayer) -> void:
	var held: Dictionary = _round_frozen_ids[id]
	_round_frozen_ids.erase(id)
	player.health.invulnerable = bool(held["god"])
	player.arsenal.disabled = false
	var _r := DotFpsAdminModifiers.set_frozen(player.controller, false)

## Holds every living player still, unarmed and unhurtable while [method round_frozen], and
## lets exactly those go afterwards; an admin's own freeze or god mode is left alone.
func _sync_round_freeze() -> void:
	var want := round_frozen()
	for id in player_ids():
		var player: ArenaPlayer = _players[id]
		if want and player.is_alive():
			_freeze_for_round(id, player)
		elif _round_frozen_ids.has(id):
			_release_from_round(id, player)

## Everybody against the toys this tick, after they moved: a walk into a ball pushes it, then
## the box's own tick (the awake cap, the lost sent home). Authority only.
func _advance_toys(delta: float) -> void:
	if toys == null or toys.count() == 0:
		return
	for id in player_ids():
		var player: ArenaPlayer = _players[id]
		if not player.is_alive():
			continue
		var state := player.controller.state
		var tunables := player.controller.tunables
		var radius := tunables.radius if tunables != null else 0.35
		var height := lerpf(tunables.stand_height, tunables.crouch_height, state.crouch_fraction) if tunables != null else ArenaPlayer.stand_height()
		var _pushed := toys.push_from(state.position, state.velocity, radius, height)
	toys.advance(delta)

## Every shot this tick against the toys: the first toy along each pellet, nearer than any wall,
## is pushed by dot-props' `shot`. [b]The shot goes on[/b]: the combat resolves it against the
## level and the players as if the toy were not there, so a ball is never cover and never eats
## a bullet meant for somebody behind it. Authority only.
func _shoot_toys(shots: Array[DotShot]) -> void:
	# shot_along arrived at dot-props level 6; an older checkout has no such method.
	if toys == null or toys.count() == 0 or shots.is_empty() or DotAddonApi.build_level("dot_props") < 6:
		return
	var layout: DotPhysicsLayout = player_stack.physics.layout if player_stack != null and player_stack.physics != null else null
	var level := layout.layer_mask(&"world") if layout != null else 1
	for shot in shots:
		var directions: Array = shot.pellets if not shot.pellets.is_empty() else [shot.direction]
		# Each pellet carries the shot's damage, as dot-combat resolves them.
		for raw: Variant in directions:
			var _pushed := toys.shot_along(shot.origin, raw as Vector3, maxf(shot.max_range, 1.0), shot.damage, level)

func tick(commands: Dictionary = {}) -> void:
	_tick += 1
	_sync_round_freeze()

	var shots: Array[DotShot] = []
	var delta := 1.0 / float(tick_rate)

	_pre_vy.clear()
	var t_sim := Time.get_ticks_usec()
	for id in player_ids():
		var player: ArenaPlayer = _players[id]

		if not player.is_alive():
			continue

		var pair: Array = commands.get(id, [])
		_pre_vy[id] = player.controller.state.velocity.y
		ArenaWeaponDropWiring.input(self, id, player, pair)
		var move: DotFpsCommand = pair[0] if pair.size() > 0 else DotFpsCommand.new()
		var fire: DotWeaponCommand = pair[1] if pair.size() > 1 else DotWeaponCommand.new()

		if move != null and fire != null:
			match_node.note_activity(str(id), _tick)
			if surf_rides != null:
				surf_rides.call(&"before", id, player)
			var outcome := player.simulate_tick(_tick, delta, move, fire)
			if surf_rides != null:
				surf_rides.call(&"after", id, player, move, _tick)
			if demo_stats != null:
				demo_stats.call(&"after", id, player, move, fire, _tick)
			shots.append_array(outcome.shots)
			_note_protected_action(id, player, move, not outcome.shots.is_empty())

			# Before the horde ticks, so the monsters hear it this tick.
			if horde != null and (not outcome.shots.is_empty() or not outcome.spawns.is_empty()):
				horde.note_fire(id, player.controller.state.position)
			# A rocket is launched and flown, not resolved as a shot (ArenaProjectiles).
			if projectiles != null:
				projectiles.accept(outcome)

	ArenaFrameProbe.add(&"tick_players", t_sim)

	# The toys after everybody moved: a walk into a ball sends it on. Then every shot that
	# passes one pushes it, before the combat resolves the shot, which a toy never stops.
	if is_authority:
		_advance_toys(delta)
		_shoot_toys(shots)

	if is_authority:
		_unlag_record()
		for shot in shots:
			# Traced where the shooter saw the others: the command carries how far behind
			# the client was drawing (-1 for a local player or bot: nothing is rewound).
			_fired_tick[shot.attacker] = _tick
			var pair: Array = commands.get(shot.attacker, [])
			var lag: float = float(pair[2]) if pair.size() > 2 else -1.0
			_unlag_shooter = shot.attacker
			_resolve_shot(shot, float(_tick) - lag if lag >= 0.0 else -1.0)
		if bullet_bridge != null:
			bullet_bridge.tick(float(_tick))

	if map_io != null:
		map_io.tick()

	# After the shots, before everything that can end the round: a hurt volume that kills
	if is_authority:
		_resolve_stomps()

	# somebody is a death the win check below has to count this tick.
	if is_authority:
		_hurt_from_map()

	# After the shots, before the match: a kill from a rocket or a monster must be counted
	# before the win check, or the round is decided a tick late.
	if projectiles != null:
		projectiles.tick(delta)

	if grenades != null:
		grenades.tick(delta)

	if props != null:
		props.tick(delta)

	if horde != null:
		horde.tick(delta)

	if effects != null:
		effects.tick(delta)

	if objectives != null:
		objectives.tick(delta)

	if spectate != null:
		spectate.tick(delta)

	# Expires spawn protection, so a player whose protection ran out is killable this tick.
	if player_stack != null:
		player_stack.tick(_tick)

	# After everybody moved: a point is taken where its taker ended the tick.
	if drops != null and is_authority:
		drops.tick(_tick, _drop_sweepers())

	_sweep_jail_button()

	_tick_rest(delta)

func _loadout_key(id: int) -> String:
	return loadout_identity.key_of(id)

## Applies a player's saved loadout. Falls back to the default on any failure.
##
## A failure here must never stop a player spawning: an unreachable loadout store is a
## reason to give them a rifle, not a reason to leave them watching.
func apply_loadout(id: int, at_spawn := false) -> void:
	var player := player_for(id)

	if player == null:
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

## Loadouts come from a store, which may be slow. A respawn may not be.
##
## The player is already in the world with whatever they had; the loadout arrives a
## frame or two later. Awaiting it inside the respawn handler would make every spawn
## wait on a disk or a network round trip.
func _apply_loadout_deferred(id: int) -> void:
	var player := player_for(id)

	if player == null:
		return

	if player.arsenal.slots().is_empty():
		# The class's loadout first: `DotPlayerClassDef.loadout_id` is the field a mode
		# changes to change what everybody spawns holding, and it reached nothing until
		# this line. The hardcoded pair below is the fallback for a game with no
		# catalogue, which is what `give_default_loadout` always was.
		var from_class := (
			player_stack != null and player_stack.give_class_loadout(player)
		)

		if from_class:
			player.hold(ArenaContent.DEFAULT_SLOT)
		else:
			player.give_default_loadout()

	apply_loadout(id, true)

## `spawn_protection_break` (config): a player still protected who shoots (bit 1) or moves or jumps (bit 2)
## loses the protection now, in all three records. Zero, the default, never calls [method end_spawn_protection].
func _note_protected_action(id: int, player: ArenaPlayer, move: DotFpsCommand, fired: bool) -> void:
	var breaks := config.spawn_protection_break
	if breaks == 0 or not player.health.is_protected(_tick):
		return
	var moved: bool = move.move != Vector2.ZERO or move.is_pressed(DotFpsCommand.BUTTON_JUMP)
	if (fired and breaks & 1 != 0) or (moved and breaks & 2 != 0):
		end_spawn_protection(id)

## Ends spawn protection for [param id] now: the health window, the `PROTECTED` effect and dot-spawn's ledger.
func end_spawn_protection(id: int) -> void:
	var player := player_for(id)
	if player == null:
		return
	player.health.invulnerable_until_tick = -1
	if effects != null:
		effects.remove(ArenaEffects.PROTECTED, id)
	if player_stack != null and player_stack.spawns != null and player_stack.spawns.protection != null:
		player_stack.spawns.protection.revoke(str(id), _tick)

func _on_respawn_due(key: String, spawn: DotSpawnPoint, tick: int) -> void:
	var id := int(key)
	var player := player_for(id)

	if player == null:
		return

	# [b]The director chooses; dot-match's point is the fallback.[/b] Both read the same
	# markers — `ArenaPlayerStack.refresh_spawns` copies dot-match's own `DotSpawnPoint`s
	# into the director — so this is not a second set of spawns, it is a better choice
	# among one set: enemy distance, line of sight, occupancy and a per-site cooldown,
	# none of which dot-match models.
	#
	# It is also where spawn protection is granted, which is the half that has to go
	# through here. `DotSpawnProtection.grant` is called inside `choose` and nowhere
	# else, so a game that took dot-match's point and skipped this has an empty ledger
	# and a `protection.advance()` that does nothing — which is what this one had.
	var at := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))

	if spawn != null:
		at = spawn.spawn_transform()

	if player_stack != null:
		var chosen := player_stack.choose_spawn(id)

		if chosen.ok:
			at = (chosen.value as DotSpawnChoice).transform
		elif spawn == null:
			# No point from either. Worth a line: the fallback below is the origin, and
			# a player standing at (0, 1, 0) on every respawn is a map with no usable
			# spawns rather than a player who found a strange corner.
			DotLog.warn(CHANNEL, "nothing chose a spawn", {
				"key": key, "why": chosen.error.message
			})

	player.hitboxes.enabled = true
	player.spawn(at, tick, match_node.spawn_protection_ticks())
	_spawned_tick[id] = _tick
	_fired_tick.erase(id)
	if _round_frozen_ids.has(id):
		_release_from_round(id, player)
	_sync_round_freeze()

	# [b]`ArenaEffects.on_spawn` was written, documented, and called by nothing.[/b] It
	# clears what survived the last life, stands the player up, and applies `PROTECTED` —
	# so until this line the arena's own spawn-protection effect had never been applied
	# to anybody, and a player who died burning respawned still burning. The family's
	# "a value produced correctly and consumed by nothing", for the third time in this
	# one respawn path.
	if effects != null:
		effects.on_spawn(id)

	_apply_loadout_deferred(id)

	player_spawned.emit(player)

func _on_match_state_changed(from: DotMatch.State, to: DotMatch.State) -> void:
	# A new round has its own first blood, and nobody's revenge carries over from warmup.
	if to == DotMatch.State.LIVE:
		medals.reset_round()
		# And every toy home: a ball parked in a doorway during warmup is not a round's
		# head start for anybody.
		if toys != null and is_authority:
			toys.reset()
	match_state_changed.emit(from, to)

func _build_match() -> DotResult:
	# DUPLICATED, not used directly. A Resource is a reference in GDScript, so handing
	# dot-match the catalogue's own rules would mean a server that raised a score limit
	# at runtime had edited the mode every later match reads.
	var rules: DotMatchRules = mode.rules.duplicate()

	# The exports override the mode when they are set, so a server can keep the mode
	# and change the numbers. Zero means "whatever the mode said".
	_override_rules(rules)

	match_node = DotMatch.new()
	match_node.name = "Match"
	match_node.rules = rules
	match_node.register_service = false

	# Built here rather than left to dot-match, which would otherwise make an untagged
	# `DotTeam.standard_pair()`. The tags are the whole point — see `ArenaMode.teams`.
	if mode.is_team_mode():
		var manager := DotTeamManager.new()
		manager.name = "Teams"
		manager.teams = mode.teams()
		match_node.teams = manager
		match_node.add_child(manager)

	var config := DotMatchConfig.new()
	config.tick_rate = tick_rate
	config.auto_start = false
	config.balance_between_rounds = false
	match_node.config = config

	# **Collect spawn points from THIS game and nowhere else.**  `DotMatch.setup` calls
	# `refresh_spawns`, which with no `spawns_ref` walks `get_tree().current_scene` — the whole
	# tree.
	var mine := DotNodeRef.new()
	mine.mode = DotNodeRef.Mode.PARENT
	match_node.spawns_ref = mine

	add_child(match_node)

	# Spawn points come from the map, not from the scene: a headless server never
	# instantiates the level's nodes, and a match with no spawn points is a match
	# nobody ever appears in.
	for index in range(map.spawns.size()):
		var point := DotSpawnPoint.new()
		point.name = "Spawn%02d" % match_node.spawn_points().size()
		point.transform = map.spawns[index]
		point.cooldown_ticks = int(2.0 * float(tick_rate))

		# The map's tag, which is what a team's `spawn_tag` matches against. An
		# untagged point stays available to everybody.
		var tag := map.spawn_tag(index)

		if tag != &"":
			point.tags.append(tag)

		add_child(point)
		match_node.add_spawn_point(point)
		_spawn_points.append(point)

	# Where everyone is, so the spawn selector can put a player away from the fight.
	# Without this it falls back to cooldowns alone and will happily spawn someone in
	# front of the player who just killed them.
	match_node.position_fn = func(key: String) -> Vector3:
		var player := player_for(int(key))
		return player.controller.state.position if player != null else Vector3.ZERO

	match_node.respawn_due.connect(_on_respawn_due)
	match_node.state_changed.connect(_on_match_state_changed)

	return DotResult.success(null)

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

func _build_loadouts() -> DotResult:
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
	if mode.objective_layout != &"ctf":
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
