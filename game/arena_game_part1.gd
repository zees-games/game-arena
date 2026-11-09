@tool
extends "arena_game_vars.gd"

## The deathmatch itself: a match, a combat manager, a map, and some players.

## The snapshot rate at [param rate] ticks a second: the rate nearest [param target] (default
## [constant NET_SNAPSHOT_RATE], or `sv_snapshot_rate` on a server) that is an EXACT divisor of the tick rate,
## so a snapshot lands on every n-th tick (64 and 128 give 32, 60 gives 30, 66 gives 33, 33 gives 33, 22 gives 22).
## A target above the tick rate is the tick rate. A rate that does not divide the tick rate (16 at 33 Hz) made the
## client's death-camera chain stall in `headless_net`, so it is never returned.
static func snapshot_rate_for(rate: int, target: int = NET_SNAPSHOT_RATE) -> int:
	var want := target if target > 0 else NET_SNAPSHOT_RATE
	var total := maxi(rate, 1)
	var best := total
	for every in range(2, total + 1):
		if total % every != 0:
			continue
		var candidate := total / every
		var gap := absi(candidate - want)
		var best_gap := absi(best - want)
		if gap < best_gap or (gap == best_gap and candidate > best):
			best = candidate
	return best

## Snapshots of interpolation delay for a client receiving [param snapshot_rate] a second: `cl_interp` seconds
## (launch option, 0 = unset) wins over `cl_interp_ratio` snapshots (default 2, dot-net's own). The delay in TIME is then
## the same at any tick rate, as CS2's cl_interp is; never under one snapshot.
static func interp_buffer_for(snapshot_rate: int, interp_sec: float, ratio: float) -> float:
	var buffer := interp_sec * float(maxi(snapshot_rate, 1)) if interp_sec > 0.0 else ratio
	return clampf(buffer, 1.0, 10.0)

## The two launch options (`--cl_interp S`, `--cl_interp_ratio N`, or the same query parameters in a browser) as a buffer.
static func client_interp_buffer(snapshot_rate: int) -> float:
	var sec := ArenaFrameProbe.launch_value("cl_interp")
	var ratio := ArenaFrameProbe.launch_value("cl_interp_ratio")
	return interp_buffer_for(snapshot_rate, sec.to_float() if sec != "" else 0.0, ratio.to_float() if ratio != "" else 2.0)

## The simulation tick the players are on, for what is drawn from it: a player's own state, since
## that is the tick the pits are asked about, and the game's own count before there is one.
func sim_tick() -> int:
	for id in _players:
		var p: ArenaPlayer = _players[id]
		if p != null and is_instance_valid(p) and p.controller != null:
			return p.controller.state.tick
	return _tick

func _exit_tree() -> void:
	if surf_rides != null:
		surf_rides.call(&"release")
		surf_rides = null
	if demo_stats != null:
		demo_stats.call(&"release")
		demo_stats = null
	if _registered_name != &"":
		DotRegistry.unregister_instance(_registered_name, self)
		_registered_name = &""

func _follow_cvar_source() -> bool:
	if _cvar_source == null or not is_instance_valid(_cvar_source) or combat == null:
		return false
	if not combat.has_method(&"follow_cvars"):
		return false
	return bool(combat.call(&"follow_cvars", _cvar_source))

## One bridge per combat manager, so a new map's manager gets its own. Inert while sv_ballistics is 0.
func _build_bullets() -> void:
	if bullet_bridge != null:
		bullet_bridge.queue_free()
		bullet_bridge = null
	var rules := combat_feel.ballistics as DotWeaponBallisticsRules
	if rules == null:
		return
	bullet_bridge = DotWeaponBulletBridge.new()
	bullet_bridge.name = "Bullets"
	add_child(bullet_bridge)
	bullet_bridge.setup(combat, rules, tick_rate)
	bullet_bridge.rewinding.connect(func(owner_id: int) -> void: _unlag_shooter = owner_id)
	if tracers == null:
		tracers = DotWeaponTracers.new()
		tracers.name = "Tracers"
		add_child(tracers)
	tracers.follow(bullet_bridge.bullets)

## Flash, smoke and incendiary effects: server only, and only on an arena_weapons that has them.
func _build_grenades() -> void:
	grenades = null
	if is_authority and ArenaGrenades.supported():
		grenades = ArenaGrenades.new()
		grenades.rules = grenades_rules
		grenades.attach(self)
		grenades.effect.connect(grenade_effect.emit)

## Puts [member jail_rules] on the map's jail, if it has one. Called when the drops layer is
## built (which is on every map) and when a rule changes. Authority side tells clients.
func apply_jail_rules() -> void:
	if map == null or map.jail == null:
		return
	var jail: RefCounted = map.jail
	jail.enabled = bool(jail_rules["enabled"])
	jail.open_ticks = maxi(int(round(float(jail_rules["open"]) * float(tick_rate))), 1)
	jail.cooldown_ticks = maxi(int(round(float(jail_rules["cooldown"]) * float(tick_rate))), 0)
	if is_authority:
		jail_changed.emit()

## Puts [member drop_rules] on the drops layer. Called when it is built and when a rule
## changes.
func apply_drop_rules() -> void:
	if drops == null:
		return
	drops.points_per_kill = int(drop_rules["points"])
	drops.point_value = int(drop_rules["point_value"])
	drops.health_amount = float(drop_rules["health"])
	drops.any_kill = bool(drop_rules["any_kill"])
	drops.life_sec = float(drop_rules["life"])
	drops.packs_enabled = bool(drop_rules["packs"])
	drops.pack_health = float(drop_rules["pack_health"])
	drops.pack_ammo_share = clampf(float(drop_rules["pack_ammo"]) / 100.0, 0.0, 1.0)
	drops.pack_respawn_sec = float(drop_rules["pack_respawn"])
	var wanted: Array = [
		map, drops, drops.packs_enabled, drops.pack_health, drops.pack_ammo_share, drops.pack_respawn_sec,
	]
	if map != null and is_authority and (_packs_placed_with.size() != wanted.size() or wanted != _packs_placed_with):
		_packs_placed_with = wanted
		drops.set_packs(map.packs, _tick)

func player_for(id: int) -> ArenaPlayer:
	return _players.get(id)

## Where player [param id] was at [param at] (a fractional tick), between the two
## recorded ticks either side; null when the history does not reach that far.
func unlag_position_at(id: int, at: float) -> Variant:
	var ring: Array = _unlag.get(id, [])
	# Below tick 0, -1 % 128 indexes the last slot, whose unfilled tag is -1 too.
	if ring.is_empty() or at < 0.0:
		return null
	var positions: PackedVector3Array = ring[0]
	var ticks: PackedInt32Array = ring[1]
	var lo := floori(at)
	var size := positions.size()
	var a := lo % size
	var b := (lo + 1) % size
	if ticks[a] != lo:
		return null
	if ticks[b] != lo + 1:
		return positions[a]
	return positions[a].lerp(positions[b], at - float(lo))

## dot-combat's rewind: every other living player, put where they were at [param view_tick].
func _unlag_rewind(view_tick: float) -> void:
	for id in _players:
		if id == _unlag_shooter:
			continue
		var player: ArenaPlayer = _players[id]
		if not player.is_alive():
			continue
		var then: Variant = unlag_position_at(id, view_tick)
		if then == null:
			continue
		_unlag_moved[id] = player.global_position
		player.global_position = then

## And back, after the trace.
func _unlag_restore() -> void:
	for id in _unlag_moved:
		var player: ArenaPlayer = _players.get(id)
		if player != null:
			player.global_position = _unlag_moved[id]
	_unlag_moved.clear()

## Gives [param player_id] what [param reward] names. Authority side.
func _reward_streak(player_id: int, streak: int, reward: String) -> void:
	var player := player_for(player_id)
	if player == null or not player.is_alive():
		return

	match reward:
		"heal":
			var _h := player.health.heal(player.health.max_health)
		"armour":
			player.health.add_armour(player.health.max_armour)
		"haste":
			if effects != null:
				var _r := effects.apply(ArenaEffects.HASTE, player_id)
		"empowered":
			if effects != null:
				var _r := effects.apply(ArenaEffects.EMPOWERED, player_id)
		_:
			return

	streak_reward.emit(player_id, streak, reward)

## The medal thresholds from [member config], before each judgement so a workbench edit counts.
func _sync_award_config() -> void:
	medals.multi_window_sec = config.award_multi_window_sec
	medals.shutdown_at = config.award_shutdown_at
	medals.point_blank_m = config.award_point_blank_m
	medals.long_shot_m = config.award_long_shot_m
	medals.nemesis_at = config.award_nemesis_at

## The fall a death gets: dot-player-char's reaction rule over the server's weights, seeded from
## the victim and the tick. Server side; the bridge sends it on KILL and every client draws it.
##
## The direction is the shot's; a death with none (a fall, a slay) is pushed by nothing. The
## killing weapon's def is what lets the sniper and the launcher throw a body
## (arena-weapons' `params.death_reaction`).
func decide_death(entity_id: int, damage: DotDamage) -> DotPlayerDeath:
	if _weapon_defs.is_empty():
		_weapon_defs = ArenaContent.weapon_table()
	var def: Object = _weapon_defs.get(damage.weapon_id)
	var direction := damage.direction
	if direction.length_squared() < 0.0001 and damage.attacker != 0 and damage.attacker != entity_id:
		var killer := player_for(damage.attacker)
		var victim := player_for(entity_id)
		if killer != null and victim != null:
			direction = victim.controller.state.position - killer.controller.state.position
	direction.y = clampf(direction.y, -0.4, 0.4)
	return DotPlayerDeath.decide(
		ragdoll_rules.reactions(), damage.is_headshot(), damage.amount, direction,
		DotPlayerDeath.seed_of(entity_id, _tick), def
	)

## What the mode says a player carries, over whatever their loadout gave them: gun game's
## weapon at their score, or the mode's pool. Authority side; the arsenal replicates.
func arm_for_mode(player: ArenaPlayer) -> void:
	if player == null or mode == null or not mode.arms_players() or not player.is_alive():
		return

	var catalogue := player.arsenal.catalogue
	var give: Array[StringName] = []

	if not mode.gun_game.is_empty():
		var record := match_node.scoreboard.find(str(player.player_id)) if match_node != null else null
		var level := clampi(record.score if record != null else 0, 0, mode.gun_game.size() - 1)
		give.append(StringName(mode.gun_game[level]))
	else:
		var pool := mode.pool_ids(catalogue)
		if mode.pool_random and not pool.is_empty():
			var rng := RandomNumberGenerator.new()
			rng.seed = player.player_id * 7919 + _tick
			give.append(pool[rng.randi_range(0, pool.size() - 1)])
		else:
			give = pool

	player.arsenal.clear()
	var hand := 0
	for id in give:
		if catalogue.has(id) and player.arsenal.give(id).ok:
			# The heaviest gun, never the grenade: the loadout's own rule.
			hand = ArenaPlayer._better_hand(hand, catalogue.get_def(id).slot)
	if mode.pool_keeps_melee and not player.arsenal.has_slot(AwWeaponIds.SLOT_MELEE):
		var _knife := player.arsenal.give(ArenaContent.melee_id())
	if hand > 0:
		player.hold(hand)

## What the medal rules are told about a kill: all of it read off the simulation.
func _kill_facts(damage: DotDamage, victim: ArenaPlayer, entry: DotKillFeed.Entry) -> ArenaAwards.KillFacts:
	var killer := player_for(damage.attacker)
	var k := ArenaAwards.KillFacts.new()
	k.killer = damage.attacker
	k.victim = victim.player_id
	k.tick = _tick
	k.tick_rate = tick_rate
	k.headshot = damage.is_headshot()
	k.victim_streak = int(streaks.get(victim.player_id, 0))
	k.team_kill = entry.team_kill
	# Eye to eye from the simulated states, never `damage.distance`: a detonation pins the
	# attacker's origin to the blast, so a rocket's distance is the blast's, not the throw's.
	k.distance = killer.controller.state.position.distance_to(victim.controller.state.position)
	k.aiming = killer.aiming
	var weapon := damage.weapon_id
	var def := ArenaPlayer.weapon_catalogue().get_def(weapon) if weapon != &"" else null
	if def != null:
		k.tags = Array(def.tags)
	elif weapon == &"":
		# Not a weapon at all (a world hazard pushed by somebody): no range medals.
		k.tags = [AwWeaponIds.TAG_THROWN]
	return k

## Gun game: a melee kill costs the victim a gun ([member ArenaMode.gun_game_melee_demotes]).
##
## The level IS the score, so this is a point off the victim's record and nothing else:
## [method arm_for_mode] reads the score at their respawn and hands them the gun before.
## Never below zero, because a negative score would be a level the list has no gun for
## and a scoreboard showing a player behind where they started.
func _demote_for_melee(damage: DotDamage, killer: ArenaPlayer) -> void:
	if not mode.gun_game_melee_demotes or killer.arsenal == null:
		return

	var weapon_id := damage.weapon_id
	if weapon_id == &"":
		return
	var def := killer.arsenal.catalogue.get_def(weapon_id)
	if def == null or not def.tags.has(AwWeaponIds.TAG_MELEE):
		return

	var record := match_node.scoreboard.find(str(damage.victim))
	if record == null or record.score <= 0:
		return

	record.score -= 1
	match_node.scoreboard.score_changed.emit(record)

func _on_entity_killed(entity_id: int, damage: DotDamage) -> void:
	var victim := player_for(entity_id)

	if victim == null:
		# Not a player. Something else registered with the combat manager, and the
		# match must not hear about it — see `non_player_killed`.
		non_player_killed.emit(entity_id, damage)
		return

	victim.make_dead()

	# An attacker of 0 is world damage — a fall, the void — and dot-match reads an
	# empty killer key as exactly that. Passing "0" instead would create a scoreboard
	# record for a player who does not exist.
	var killer_key := "" if damage.attacker == 0 else str(damage.attacker)

	var entry := match_node.report_kill(
		killer_key,
		str(entity_id),
		damage.weapon_id if damage.weapon_id != &"" else damage.type.id,
		_tick,
		damage.is_headshot()
	)
	# dot-match's entry has no field for it; the bridge reads it to tell every client a
	# lethal critical happened, which is what breaks a body and what a reward hangs on.
	entry.set_meta(&"critical", damage.critical)
	# How the body falls, picked once, here, and sent with the kill (see `decide_death`).
	if is_authority:
		entry.set_meta(&"death", decide_death(entity_id, damage))

	# The medals, before the streaks move: a shutdown is judged on the streak the victim
	# died with. Emitted after `player_killed`, so a client hears the kill first.
	var awarded: Array[int] = []
	var judged := false
	if is_authority:
		judged = true
		if damage.attacker == 0 or damage.attacker == entity_id or player_for(damage.attacker) == null:
			medals.note_death(entity_id)
		else:
			_sync_award_config()
			awarded = medals.judge(_kill_facts(damage, victim, entry))

	# The streaks: the victim's ends, the killer's grows, and a reward lands on the kill
	# that reaches it.
	streaks[entity_id] = 0
	if is_authority and damage.attacker != 0 and damage.attacker != entity_id:
		var streak := int(streaks.get(damage.attacker, 0)) + 1
		streaks[damage.attacker] = streak
		if streak_rewards.has(streak):
			_reward_streak(damage.attacker, streak, String(streak_rewards[streak]))

	# Gun game: the killer's score just went up, so their weapon moves along the list.
	if is_authority and mode != null and not mode.gun_game.is_empty() and damage.attacker != 0:
		var killer_player := player_for(damage.attacker)
		if killer_player != null and killer_player != victim:
			arm_for_mode(killer_player)
			_demote_for_melee(damage, killer_player)

	# Points out of the body, if the rules say this kill drops any.
	if drops != null and is_authority:
		var _n := drops.on_kill(
			victim.controller.state.position, damage.critical, _tick, entity_id * 7919 + _tick
		)

	player_killed.emit(entry)

	if judged and damage.attacker != 0 and damage.attacker != entity_id and player_for(damage.attacker) != null:
		medals_awarded.emit(
			damage.attacker, entity_id, awarded, ArenaAwards.points_for(awarded, config.award_kill_points),
			int(streaks.get(damage.attacker, 0))
		)

func _on_damage_applied(damage: DotDamage) -> void:
	# The hit marker's source, for anything a player hurt that is not themselves. Before
	# the scoreboard's filter, because a monster hit is a hit too.
	if (
		is_authority and damage.attacker != 0 and damage.attacker != damage.victim
		and player_for(damage.attacker) != null
	):
		var taken := damage.health_lost + damage.armour_absorbed
		if taken > 0.0:
			# Damage applied without a trace (a blast, a hazard) has no point; a player's
			# chest is where its number rises from then.
			var at := damage.point
			var hurt := player_for(damage.victim)
			if at == Vector3.ZERO and hurt != null:
				at = hurt.controller.state.position + Vector3(0.0, 1.3, 0.0)
			hit_confirmed.emit(
				damage.attacker, damage.victim, taken, at, damage.is_headshot(), damage.lethal
			)

	# Only players are on the scoreboard. Damage to or from anything else a game
	# layer registered with dot-combat — a monster, a breakable — would otherwise
	# create a record keyed on an id no player has, for the same reason
	# `non_player_killed` exists.
	if player_for(damage.victim) == null:
		return

	var attacker := (
		str(damage.attacker) if player_for(damage.attacker) != null else ""
	)

	match_node.report_damage(attacker, str(damage.victim), damage.health_lost)

func _build_combat() -> DotResult:
	combat = DotCombatManager.new()
	combat.name = "Combat"
	combat.is_authority = is_authority
	combat.register_service = false
	combat.trace = map.shot_trace()

	var rules := DotDamageRules.new()
	# Self damage stays on in every mode: rocket jumping is a movement option.
	rules.friendly_fire = mode.friendly_fire if config.friendly_fire < 0 else config.friendly_fire == 1
	rules.self_damage = mode.self_damage
	rules.hit_groups = true
	rules.falloff = true
	rules.maximum = 400.0
	combat.rules = rules

	var config := DotCombatConfig.new()
	config.tick_rate = tick_rate
	config.lag_compensation = max_unlag_ms > 0.0
	config.max_rewind_ms = max_unlag_ms
	config.max_origin_error = 2.5
	combat.config = config
	combat.rewind_fn = _unlag_rewind
	combat.restore_fn = _unlag_restore

	add_child(combat)

	# AFTER add_child: the resolver is built in `_ready`. This is the whole friendly-fire seam:
	# team 0 means "no team", so unassigned players in a free-for-all can always hurt each other.
	combat.resolver.team_of = func(entity_id: int) -> int:
		var player := player_for(entity_id)
		return player.team if player != null else 0

	for type in ArenaContent.damage_types():
		combat.register_damage_type(type)

	combat.entity_killed.connect(_on_entity_killed)
	combat.damage_applied.connect(_on_damage_applied)
	shot_stats.attach(self)

	_build_bullets()

	# A new manager starts on dot-combat's defaults; a client re-follows the server's cvars here.
	var _following := _follow_cvar_source()

	projectiles = ArenaProjectiles.new()
	# The same gravity the players fall under (ArenaPlayer's tunables); the two must not drift.
	projectiles.setup(combat, 22.0)
	projectiles.catalogue = ArenaPlayer.weapon_catalogue()
	projectiles.origin_of = func(entity_id: int) -> Variant:
		var thrower := player_for(entity_id)
		return thrower.muzzle_position() if thrower != null else null

	_build_grenades()

	drops = ArenaDrops.new()
	drops.name = "Drops"
	drops.is_authority = is_authority
	drops.draws = not headless
	add_child(drops)
	drops.setup(tick_rate)
	drops.position_of = func(entity_id: int) -> Variant:
		var who := player_for(entity_id)
		return who.global_position if who != null else null
	apply_drop_rules()
	ArenaWeaponDropWiring.build(self)
	apply_jail_rules()

	if not headless and map != null and map.jail != null:
		jail_view = ArenaJailView.new()
		add_child(jail_view)
		jail_view.build(map.jail, sim_tick)

	return DotResult.success(null)

## A presentation rule's current value: the server's, or the default.
func rule(key: String) -> float:
	return float(movement_rules.get(key, SHOW_DEFAULTS.get(key, 0.0)))

func _override_rules(rules: DotMatchRules) -> void:
	# The final killcam plays inside the match's end, so the end is that much longer.
	rules.match_end_sec = mode.rules.match_end_sec + rule("killcam")

	# Gun game's limit is the length of its list: a kill is a level, and a limit past the
	# last gun is kills with the knife nobody is counting ([ArenaMode]).
	if score_limit > 0 and mode.gun_game.is_empty():
		rules.score_limit = score_limit

	if time_limit_sec > 0.0:
		rules.time_limit_sec = time_limit_sec

	if config.respawn_delay_sec >= 0.0:
		rules.respawn_delay_sec = config.respawn_delay_sec
	if config.spawn_protection_sec >= 0.0:
		rules.spawn_protection_sec = config.spawn_protection_sec

	if warmup_sec >= 0.0:
		rules.warmup_sec = warmup_sec

	if min_players > 0:
		rules.min_players = min_players

	if freeze_sec >= 0.0:
		rules.countdown_sec = freeze_sec

	_override_ctf_rules(rules)

## After the generic limits, on the first build of the match and on every change: capture the flag is limited by captures (`arena_ctf_capturelimit`) and by seconds only when `arena_ctf_timelimit` says so (0, the default, is no clock; the generic `arena_timelimit` and its 600 s do not apply). Its score is captures only: a kill is still a kill on the scoreboard, worth no points.
func _override_ctf_rules(rules: DotMatchRules) -> void:
	if mode == null or mode.objective_layout != &"ctf":
		return
	rules.score_limit = ctf_rules.capture_limit
	rules.time_limit_sec = float(maxi(ctf_rules.time_limit_sec, 0))
	rules.kill_points = 0
	rules.suicide_points = 0
	rules.friendly_points = 0
	rules.assist_points = 0

func _resolve_shot(shot: DotShot, view_tick: float) -> void:
	if bullet_bridge == null:
		combat.resolve_shot(shot, view_tick)
		return
	var catalogue := ArenaPlayer.weapon_catalogue()
	var def: DotWeaponDef = catalogue.get_def(shot.weapon_id) if catalogue.has(shot.weapon_id) else null
	var _resolved := bullet_bridge.resolve_shot(shot, def.tuning as DotWeaponBallistics if def != null else null, view_tick)

func player_ids() -> Array[int]:
	# Asked for by a dozen steps of every tick, and the roster changes a few times a match: sorted once per change.
	# Callers only read it, and a change replaces the array rather than editing it, so a loop over it is safe.
	if _ids_cache.size() == _players.size():
		return _ids_cache
	var out: Array[int] = []
	for key in _players.keys():
		out.append(int(key))
	out.sort()
	_ids_cache = out
	return out

## Whoever stands in the jail's button presses it. Authority side, after everybody has moved.
func _sweep_jail_button() -> void:
	if not is_authority or map == null or map.jail == null:
		return
	var jail: RefCounted = map.jail
	if not jail.enabled:
		return
	var box: AABB = jail.button_box()
	for id in player_ids():
		var p: ArenaPlayer = _players[id]
		if p.is_alive() and box.has_point(p.controller.state.position):
			var at: int = p.controller.state.tick
			if jail.press(at):
				DotLog.info(CHANNEL, "the jail's gate opened", {"by": id, "tick": at})
				jail_changed.emit()
				return

## Copies the cfg's stomp numbers onto [member stomp]'s rules. Rules the cfg does not own (sound ids) too.
func _sync_stomp_config() -> void:
	var r := stomp.rules
	r.enabled = config.stomp_enabled
	r.damage = config.stomp_damage
	r.min_speed = config.stomp_min_speed
	r.head_tolerance = config.stomp_head_tolerance
	r.same_team = config.stomp_same_team
	r.bounce = config.stomp_bounce
	r.cooldown_sec = config.stomp_cooldown_sec
	r.sound = StringName(config.stomp_sound)
	r.effect = StringName(config.stomp_effect)

## Which side a player is on, or 0 in a free-for-all.
func team_of(id: int) -> int:
	if not is_authority and replicated_teams.has(id):
		return int(replicated_teams[id])

	if match_node == null or match_node.teams == null:
		return 0

	return match_node.teams.team_of(str(id))

## A client takes the server's sides (`ArenaEvents.Kind.TEAM` text, `id:team;...`; empty for none).
func apply_teams_text(text: String) -> void:
	replicated_teams.clear()
	for part in text.split(";", false):
		var pair := part.split(":")
		if pair.size() == 2 and pair[0].is_valid_int() and pair[1].is_valid_int():
			replicated_teams[int(pair[0])] = int(pair[1])
	for id in player_ids():
		var player := player_for(id)
		if player != null:
			player.team = team_of(id)

## The sides in play, empty in a free-for-all.
func teams() -> Array[DotTeam]:
	# A client's own match is the mode it started in (free-for-all), not the one the server plays:
	# the sides come from the mode it is shown, which is what the server announced.
	if not is_authority:
		var shown := _mode_shown()
		if shown != null and shown.is_team_mode():
			if _shown_sides_for != shown:
				_shown_sides_for = shown
				_shown_sides = shown.teams()
			return _shown_sides

	if match_node != null and match_node.teams != null:
		return match_node.teams.teams

	return []

## The mode on show (the top layer answers; null here).
func _mode_shown() -> ArenaMode:
	return null

var _shown_sides_for: ArenaMode = null
var _shown_sides: Array[DotTeam] = []

## The side with [param team_id], or null (a free-for-all, nobody).
func team_def(team_id: int) -> DotTeam:
	for side in teams():
		if side.id == team_id:
			return side
	return null

## After everybody moved: a player who came down onto another's head kills them, and bounces.
## Server-authoritative; a client's prediction of the bounce is corrected by the next snapshot.
func _resolve_stomps() -> void:
	_sync_stomp_config()
	if not stomp.rules.enabled or combat == null:
		return
	var hulls: Array = []
	for id in player_ids():
		var other: ArenaPlayer = _players[id]
		if not other.is_alive() or other.controller == null:
			continue
		hulls.append({
			"id": id, "feet": other.controller.state.position, "team": team_of(id) if not teams().is_empty() else -1,
			"height": other.controller.tunables.stand_height, "radius": other.controller.tunables.radius,
		})
	for id in player_ids():
		var player: ArenaPlayer = _players[id]
		if not _pre_vy.has(id) or not player.is_alive():
			continue
		var state: DotFpsState = player.controller.state
		var victim := stomp.find(
			id, state.position, player.controller.tunables.radius, -float(_pre_vy[id]),
			team_of(id) if not teams().is_empty() else -1, hulls, _tick, tick_rate
		)
		if victim == 0:
			continue
		var hit := DotDamage.make(id, victim, stomp.amount(), combat.damage_type(ArenaContent.DAMAGE_STOMP))
		hit.tick = _tick
		hit.point = state.position
		hit.weapon_id = ArenaContent.DAMAGE_STOMP
		hit.context = {"why": &"stomp", "ignores_teams": stomp.rules.same_team}
		var _applied := combat.apply_damage(hit)
		if hit.refused:
			continue
		if stomp.rules.bounce > 0.0:
			state.velocity.y = stomp.rules.bounce
		stomped.emit(id, victim, -float(_pre_vy[id]), state.position, stomp.rules.sound, stomp.rules.effect)
		if progress != null:
			progress.record(id, ArenaStats.STOMPS)

# --- Simulation ------------------------------------------------------------

## Advances the whole game one tick.
##
## [b]The order is the point of this method.[/b] Players simulate and produce shots;
## the shots are resolved against the world as it is *after* everyone has moved; the
## match's clock and win check run last, so a kill scored on this tick can end the
## round on this tick rather than the next one.
##
## [param commands] is `{player id: [DotFpsCommand, DotWeaponCommand]}`. A player with
## no entry repeats their last command, which is what a dropped input packet should
## look like.
## Slots in a position ring: [constant UNLAG_SECONDS] of ticks at this game's rate (never under [constant UNLAG_HISTORY]).
func unlag_history() -> int:
	return maxi(UNLAG_HISTORY, ceili(UNLAG_SECONDS * float(tick_rate)) + 2)

## Records every player's position for this tick, for [method _unlag_rewind].
func _unlag_record() -> void:
	for id in _players:
		var player: ArenaPlayer = _players[id]
		var ring: Array = _unlag.get(id, [])
		if ring.is_empty():
			var positions := PackedVector3Array()
			positions.resize(unlag_history())
			var ticks := PackedInt32Array()
			ticks.resize(unlag_history())
			ticks.fill(-1)
			ring = [positions, ticks]
			_unlag[id] = ring
		# Packed arrays are values: taken out, written, and put back, or the write lands
		# on a copy and the history stays empty (it did, the first time).
		var positions: PackedVector3Array = ring[0]
		var ticks: PackedInt32Array = ring[1]
		var slot := _tick % ticks.size()
		var before := (_tick - 1) % ticks.size()
		# A respawn or a teleport: rewinding across it would stand hitboxes where they died.
		if ticks[before] == _tick - 1 and positions[before].distance_to(player.global_position) > TELEPORT_CUT:
			ticks.fill(-1)
		positions[slot] = player.global_position
		ticks[slot] = _tick
		ring[0] = positions
		ring[1] = ticks
		_unlag[id] = ring

func _tick_rest(delta: float) -> void:
	match_node.tick(_tick)

	if surf_rides != null:
		surf_rides.call(&"process", delta)
	if demo_stats != null:
		demo_stats.call(&"process", delta)

## Who can pick up a drop this tick, keyed by player id.
func _drop_sweepers() -> Dictionary:
	var sweepers := {}
	for id in player_ids():
		var p: ArenaPlayer = _players[id]
		if p.is_alive():
			sweepers[id] = {
				"position": p.controller.state.position,
				"hurt": p.health.health < p.health.max_health,
				"heal": func(amount: float) -> void: var _h := p.health.heal(amount),
				"needs_ammo": p.needs_ammo(),
				"ammo": func(share: float) -> void: p.refill_ammo(share),
			}
	return sweepers
