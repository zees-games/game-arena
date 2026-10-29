@tool
extends "arena_game_state.gd"

## The deathmatch itself: a match, a combat manager, a map, and some players.
##
## [b]This is the seam nothing else runs.[/b] dot-match knows nothing about damage,
## dot-combat knows nothing about scoring, dot-loadout knows nothing about weapons, and
## dot-player-controller knows about none of them. Six addons, each correct alone. This is
## the fifty lines where they meet, and the only place a mistake in the joins between
## them can show up.
##
## It is deliberately independent of dot-server: a listen server, a test and a
## dedicated server all run this, and only the last of them also runs
## [ArenaModule].

## The snapshot rate at [param rate] ticks a second: the nearest to [constant NET_SNAPSHOT_RATE]
## that is a whole number of ticks apart (64 and 128 give 32, 60 gives 30). dot-net divides
## with integers, so 32 at 60 Hz sent every tick, twice the bytes.
static func snapshot_rate_for(rate: int) -> int:
	return rate / maxi(1, roundi(float(rate) / float(NET_SNAPSHOT_RATE)))

## The sprint rules start from this game's own tunables, so loading them (for `sv_sprint_shoot` and `sv_sprint_barrel`) leaves the speeds as they were.
static func _make_combat_feel() -> DotGameCombatFeel:
	var feel := DotGameCombatFeel.new(true, true)
	feel.sprint_defaults(ArenaPlayer.arena_tunables())
	return feel


## The simulation tick the players are on, for what is drawn from it: a player's own state, since
## that is the tick the pits are asked about, and the game's own count before there is one.
func sim_tick() -> int:
	for id in _players:
		var p: ArenaPlayer = _players[id]
		if p != null and is_instance_valid(p) and p.controller != null:
			return p.controller.state.tick
	return _tick


## The kill view (dot-replay's `mp_killview*`): on in this game. Bound by the module (REPLICATED), followed by the client.
var killview_rules: DotKillViewRules = _make_killview_rules()

## `sv_falldamage*`: landing hard hurts, except on a surf map (ramps land fast by design).
## On here, off in dot-combat's default; the server applies it, a client never does.
var fall_rules: DotFallDamageRules = make_fall_rules()

## Landing on a head (`sv_stomp*`, the cfg `stomp_*` keys); the numbers are copied from [member config] each tick.
var stomp := DotStomp.new()
var _pre_vy: Dictionary = {}
## Where each player's saved loadouts are filed (a stable key when they have one).
var loadout_identity := ArenaLoadoutIdentity.new()

## Movement-dependent spread, recoil patterns and the spread crosshair (dot-game's opt-in; sv_spread_*, sv_recoil_*, on here).
var combat_feel: DotGameCombatFeel = _make_combat_feel()

func _exit_tree() -> void:
	if surf_rides != null:
		surf_rides.call(&"release")
		surf_rides = null
	if _registered_name != &"":
		DotRegistry.unregister_instance(_registered_name, self)
		_registered_name = &""


## Builds everything. Call after adding to the tree.
func setup(p_map: ArenaMap = null) -> DotResult:
	# The mode first: the map default, the damage rules and the match rules all come
	# out of it, so resolving it after any of them would build them from the old one.
	if mode == null:
		mode = ArenaModes.by_id_or_default(mode_id)

	var mode_res := mode.validate()

	if not mode_res.ok:
		return mode_res

	map = (
		p_map if p_map != null
		else (
			ArenaMap.by_id(mode.preferred_map) if mode.preferred_map != &""
			else null
		)
	)

	if map == null:
		map = ArenaMap.dm_box()

	if mode.is_team_mode() and Array(map.spawn_tags).count("") == map.spawns.size():
		# Not fatal: dot-match falls back to the shared pool and everyone still spawns.
		# It is worth a line anyway, because the symptom of playing a team mode on an
		# untagged map is "the sides keep spawning in each other's base", which reads
		# as a spawn-selection bug rather than as a map that was never tagged.
		DotLog.warn(
			CHANNEL,
			"a team mode on a map with no tagged spawns; both sides share one pool",
			{"mode": str(mode.id), "map": map.display_name}
		)

	# Before the combat manager and before any player: both bind to it.
	_build_world_collision()

	var combat_result := _build_combat()

	if not combat_result.ok:
		return combat_result

	var match_result := _build_match()

	if not match_result.ok:
		return match_result

	var loadout_result := _build_loadouts()

	if not loadout_result.ok:
		return loadout_result

	var progress_result := _build_progress()

	if not progress_result.ok:
		return progress_result

	# Last, and after the combat manager: a monster is a combat entity and a prop is a
	# rigid body that has to land on the map. Both read `mode`, which is why neither is
	# an export on this class — see `ArenaMode.horde`.
	_reconcile_world_layers()

	var stack_result := _build_player_stack()

	if not stack_result.ok:
		return stack_result

	# The stack is what knows the collision layout, and it is built last.
	_classify_world_collision()
	_build_toys()

	if register_service:
		_registered_name = (
			DotRegistry.scoped_name(SERVICE, service_scope)
			if service_scope != &""
			else SERVICE
		)
		DotRegistry.register(_registered_name, self)

	_announce_mode()

	return DotResult.success(null)


## Keeps this world's combat manager on the server's replicated cvars (dot-combat's
## `mp_teammate_passthrough`), as [param source] reports them: the client's `DotClientLink`.
## Remembered, because a map change builds a new manager. True when it is following.
##
## [b]Why a client needs it.[/b] This end traces its own shots for tracers and impacts, and
## on the default 1 against a server on 0 or 2 they ended in (or went through) a team-mate
## where the server's did the opposite. A family cvar, so it rides dot-server's replicated
## cvars rather than RULES: one path for every game. By name, like the module's bind: an older
## host's dot-combat or link cannot follow, and the manager keeps its default.
func follow_server_cvars(source: Object) -> bool:
	_cvar_source = source
	# The ragdoll rules are the game's, not the map's, so they follow once and keep following.
	var _bodies := ragdoll_rules.follow_cvars(source)
	var _toys := toy_rules.follow_cvars(source)
	var _weapon_drops := weapon_drop_rules.follow_cvars(source)
	var _view := view_rules.follow_cvars(source)
	var _killview := killview_rules.follow_cvars(source)
	var _ambient := ambient_rules.follow_cvars(source)
	var _spectate := spectate_rules.follow_cvars(source)
	var _solid := body_rules.follow_cvars(source)
	if noblock != null:
		noblock.follow(source)
	var _feel := feel_rules.follow_cvars(source)
	var _ads := ads_rules.follow_cvars(source)
	combat_feel.follow_cvars(source)
	return _follow_cvar_source()


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


## A bullet the server announced (BULLET): flies the same path here for a tracer. False when
## ballistics is off here, the weapon is unknown, or the mirror is full. Client side.
func mirror_bullet(server_id: int, weapon_id: StringName, origin: Vector3, velocity: Vector3, owner_id: int = 0) -> bool:
	var rules := combat_feel.ballistics as DotWeaponBallisticsRules
	var catalogue := ArenaPlayer.weapon_catalogue()
	if is_authority or rules == null or combat == null or not catalogue.has(weapon_id) or velocity.length() < 0.001:
		return false
	var tuning := catalogue.get_def(weapon_id).tuning as DotWeaponBallistics
	if tuning == null:
		return false
	if bullet_mirrors == null:
		bullet_mirrors = DotWeaponBullets.new()
		bullet_mirrors.name = "BulletMirrors"
		bullet_mirrors.tick_rate = tick_rate
		bullet_mirrors.cast_fn = _mirror_cast
		bullet_mirrors.expired.connect(func(id: int) -> void: _forget_mirror(id))
		bullet_mirrors.hit.connect(func(id: int, _o: int, _i: Dictionary, _d: float, _m: float, _t: DotWeaponBallistics) -> void:
			_forget_mirror(id))
		add_child(bullet_mirrors)
	bullet_mirrors.rules = rules
	if tracers == null:
		tracers = DotWeaponTracers.new()
		tracers.name = "Tracers"
		add_child(tracers)
		tracers.follow(bullet_mirrors)
	elif not bullet_mirrors.tracer.is_connected(tracers.add):
		tracers.follow(bullet_mirrors)
	var id := bullet_mirrors.spawn(owner_id, origin, velocity, tuning)
	if id > 0:
		_mirror_ids[server_id] = id
	return id > 0


## The server ended bullet [param server_id] (BULLET_END). Client side.
func end_bullet_mirror(server_id: int) -> void:
	if bullet_mirrors != null and _mirror_ids.has(server_id):
		bullet_mirrors.despawn(int(_mirror_ids[server_id]))
	_mirror_ids.erase(server_id)


## Advances the mirrored bullets one tick. Client side, from the bridge's client tick.
func step_bullet_mirrors(now_tick: float) -> void:
	if bullet_mirrors != null and bullet_mirrors.count() > 0:
		bullet_mirrors.step(now_tick)


func _forget_mirror(local_id: int) -> void:
	for sid in _mirror_ids.keys():
		if int(_mirror_ids[sid]) == local_id:
			_mirror_ids.erase(sid)


func _mirror_cast(from: Vector3, to: Vector3, owner_id: int) -> Dictionary:
	var offset := to - from
	var dist := offset.length()
	if dist <= 0.0 or combat == null:
		return {}
	var shooter := combat.hitboxes_of(owner_id)
	combat.trace.exclude = [shooter] if shooter != null else []
	var hit := combat.trace.ray(from, offset / dist, dist, combat.hitbox_sets())
	return {"position": hit.point} if hit.ok() else {}


func _resolve_shot(shot: DotShot, view_tick: float) -> void:
	if bullet_bridge == null:
		combat.resolve_shot(shot, view_tick)
		return
	var catalogue := ArenaPlayer.weapon_catalogue()
	var def: DotWeaponDef = catalogue.get_def(shot.weapon_id) if catalogue.has(shot.weapon_id) else null
	var _resolved := bullet_bridge.resolve_shot(shot, def.tuning as DotWeaponBallistics if def != null else null, view_tick)


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


## Flash, smoke and incendiary effects: server only, and only on an arena_weapons that has them.
func _build_grenades() -> void:
	grenades = null
	if is_authority and ArenaGrenades.supported():
		grenades = ArenaGrenades.new()
		grenades.rules = grenades_rules
		grenades.attach(self)
		grenades.effect.connect(grenade_effect.emit)


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


## The server's jail state, on a client: the rules in ticks and when the gate was last opened.
func apply_jail_state(told: Dictionary) -> void:
	if map == null or map.jail == null:
		return
	var jail: RefCounted = map.jail
	jail.enabled = bool(told["enabled"])
	jail.open_ticks = int(told["open_ticks"])
	jail.cooldown_ticks = int(told["cooldown_ticks"])
	jail.opened_at = int(told["opened_at"])


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


## Puts [member drop_rules] on the drops layer. Called when it is built and when a rule
## changes.
func apply_drop_rules() -> void:
	if drops == null:
		return
	drops.coins_per_kill = int(drop_rules["coins"])
	drops.coin_value = int(drop_rules["coin_value"])
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


## The medal thresholds from [member config], before each judgement so a workbench edit counts.
func _sync_award_config() -> void:
	medals.multi_window_sec = config.award_multi_window_sec
	medals.shutdown_at = config.award_shutdown_at
	medals.point_blank_m = config.award_point_blank_m
	medals.long_shot_m = config.award_long_shot_m
	medals.nemesis_at = config.award_nemesis_at


## Puts [member score_limit], [member time_limit_sec], [member warmup_sec] and
## [member min_players] on the match being played, from the next tick (dot-match reads its
## rules every tick). The authority's to call; a client is told the score limit and the clock
## by MATCH. A limit the match has already passed ends it on the next check, which is what a
## lowered frag limit does in the genre.
func apply_match_limits() -> void:
	if match_node == null or match_node.rules == null or mode == null:
		return
	# From the mode again, so setting an export back to zero restores the mode's number
	# rather than keeping the last override.
	var from_mode: DotMatchRules = mode.rules
	match_node.rules.score_limit = from_mode.score_limit
	match_node.rules.time_limit_sec = from_mode.time_limit_sec
	match_node.rules.warmup_sec = from_mode.warmup_sec
	match_node.rules.min_players = from_mode.min_players
	match_node.rules.respawn_delay_sec = from_mode.respawn_delay_sec
	match_node.rules.spawn_protection_sec = from_mode.spawn_protection_sec
	if freeze_sec >= 0.0 or _freeze_overridden:
		match_node.rules.countdown_sec = from_mode.countdown_sec
	_freeze_overridden = freeze_sec >= 0.0
	_override_rules(match_node.rules)


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
	#
	# It has to be assigned AND parented before `add_child(match_node)`, because that
	# is what runs `DotMatch._ready` and therefore `setup`, and setup only creates a
	# manager when it finds none.
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

	# **Collect spawn points from THIS game and nowhere else.**
	#
	# `DotMatch.setup` calls `refresh_spawns`, which with no `spawns_ref` walks
	# `get_tree().current_scene` — the whole tree. That is right for a game that is the
	# scene and wrong for every other arrangement, and this project has two of them:
	# a suite that builds several `ArenaGame`s in one process, and a `changelevel`,
	# where the outgoing map's points are still children for the rest of the frame
	# because `queue_free` is deferred.
	#
	# Measured: a second game in the tree contributed ten spawn points to this one's
	# match, so players spawned in a map they were not in. Nothing errored — a spawn
	# point is a spawn point, and dot-match had been handed exactly what it asked for.
	# PARENT rather than SELF: `DotMatch` resolves the ref against ITSELF, so SELF is
	# the match node, whose only child is the team manager. The spawn points are
	# children of the game, which is the match node's parent.
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

	add_child(loadouts)
	_build_loadout_command()
	return DotResult.success(null)


const LOADOUT_COMMAND_SCRIPT := "res://addons/dot_loadout/integrations/dot_loadout_command.gd"


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


## Why the B menu has nothing to choose right now, or "": a mode that decides what everybody
## carries (gun game, Only Snipers) makes a loadout pointless, and the menu says so rather than
## saving a choice the next spawn throws away.
func loadout_closed_reason() -> String:
	if mode != null and mode.arms_players():
		return "%s hands out the weapons. Your loadout is kept for the next mode." % mode.display_name
	return ""


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


## Puts [param id]'s saved loadout in their hands when [method loadout_now_allowed]. True when it
## did. Authority only: the arsenal replicates from here.
func rearm_if_allowed(id: int) -> bool:
	if not is_authority or not loadout_now_allowed(id):
		return false
	await apply_loadout(id)
	DotLog.debug(CHANNEL, "loadout handed over at once", {"player": id})
	return true


## Statistics, achievements and boards, if this instance keeps any.
##
## [b]Built last, and after the match node exists.[/b] [method ArenaProgress.attach]
## connects to the combat manager's shot and damage signals and to dot-match's round
## and match signals; every one of those is created by the three builders above, and
## attaching before them would connect to null with no error until the first kill.
## Stands up the player-facing addons and binds them to this game.
##
## After everything else, because it reads the match's team manager, the match's spawn
## points and this node's tick rate, and a stack built before any of those exists binds
## to nothing and reports success.
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


## The monsters and the props the mode asks for.
##
## [b]Neither is fatal and neither logs at warning level when it is simply off.[/b] A
## mode with no monsters is the ordinary case; a mode that wanted them and could not
## have them is worth a line, because the symptom is an empty arena in a game called
## Siege and nothing to say why.
## Build the layers a mode asks for, and take away the ones it does not.
##
## [b]Called from `change_map` as well as from `setup`, and that is the whole point.[/b]
## Before it was, the layers were built once and never reconsidered — so switching from
## free-for-all to `koth` produced a game whose mode said it had objectives and whose
## `objectives` was null, and switching to `siege` produced one with no monsters in it.
## Nothing errored: a null layer is a legitimate thing for a mode with no layer to have,
## and the only symptom was a mode that did not do what it says.
func _reconcile_world_layers() -> void:
	if not is_authority and mode != null:
		# A networked client builds one layer of the world's: the spectator camera, which
		# is drawn where it is computed. Until it did, a client had no spectate layer at
		# all and a dead player's camera stayed on the body for the whole of every death.
		_build_spectate()
		return

	if not is_authority or mode == null:
		return

	_build_world_layers()

	# And the other direction. A mode with no objectives must not keep the last one's,
	# because a HUD reads the layer rather than the mode and would draw a hill nobody
	# can capture.
	if objectives != null and mode.objective_layout == &"":
		remove_child(objectives)
		objectives.queue_free()
		objectives = null

	if horde != null and not mode.horde:
		remove_child(horde)
		horde.queue_free()
		horde = null

	if props != null and not mode.player_props and mode.scatter_props <= 0:
		remove_child(props)
		props.queue_free()
		props = null


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


## Build whatever is missing. Idempotent, because [method _reconcile_world_layers]
## calls it on every map change as well as at setup.
##
## Each layer is built once and then left alone: a rebuilt layer is a layer whose signal
## connections have to be remade, and a connection to a freed object is an error at the
## next emit rather than at the disconnect that was skipped. What a MODE change needs is
## the layer to exist or not exist, which the reconcile above does by taking it away.
func _build_world_layers() -> void:
	if not is_authority or mode == null:
		return

	# Effects first, and the order matters: ArenaObjectives asks the effects layer
	# whether a player may capture, and a layer that is not there yet answers "no
	# layer", which is a legitimate answer and would silently let an invulnerable
	# player take a point.
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


func start(tick: int = 0) -> void:
	_tick = tick
	match_node.start(tick)


# --- Changing the map ------------------------------------------------------

## Replaces the world under the players who are standing in it.
##
## [b]This is what `ArenaGame.setup` could never be asked to do twice.[/b] setup builds
## the combat trace, the match node and every spawn point as children in one pass and
## is not re-entrant: calling it again leaves two matches, two combat managers and two
## sets of spawns in one tree, all of them connected to the same signals, and the
## second of each quietly wins. So the teardown is the feature, and it is the half that
## has to be right — every one of the joins this game exists to test is a signal
## connection, and a connection to a freed object is an error at the next emit rather
## than at the disconnect that was skipped.
##
## What survives a change and what does not:
##
## - [b]The players do.[/b] Their nodes, their statistics and their loadouts are about
##   a person on this server, not about a room. They are re-bodied against the new
##   geometry and put back into the new match.
## - [b]The match does not.[/b] A new map is a new match; scores from the last one
##   belong to the last one. dot-stats' session totals are deliberately not reset,
##   because a session is a visit to the server.
## - [b]The combat manager does not[/b], because its trace is the map.
##
## [param new_mode] is optional; null keeps the mode that is running. A mode change is
## the one thing that must happen HERE rather than afterwards — the match rules, the
## team manager and the damage rules are all built from it, and assigning it after the
## rebuild would leave every one of them describing the previous mode.
func change_map(new_map: ArenaMap, new_mode: ArenaMode = null) -> DotResult:
	if new_map == null:
		return DotResult.fail(DotError.CODE_INVALID, "There is no map to change to.")

	if map == null or match_node == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The game has not been set up, so there is nothing to change."
		)

	if new_mode != null:
		var mode_res := new_mode.validate()

		if not mode_res.ok:
			return mode_res.wrap("The mode that map wanted is not usable")

	# Read before the teardown: `_players` survives it, but the team a player was on
	# belongs to the match that is about to be freed.
	var roster: Array = []

	for id in player_ids():
		var player: ArenaPlayer = _players[id]
		roster.append({"id": id, "name": player.display_name})

	_teardown_world()
	_hurt_due.clear()

	map = new_map

	if new_mode != null:
		mode = new_mode

	# Before the combat manager and before any player is re-bodied: both bind to it.
	_build_world_collision()
	_classify_world_collision()

	var combat_result := _build_combat()

	if not combat_result.ok:
		return combat_result.wrap("The new map's combat could not be built")

	var match_result := _build_match()

	if not match_result.ok:
		return match_result.wrap("The new map's match could not be built")

	for row in roster:
		var id := int(row["id"])
		var player := player_for(id)

		if player == null:
			continue

		# The body first. A player whose collision is still the old map's geometry is
		# one standing inside a wall that no longer exists, and the first tick after
		# the change would push them out of a room they are not in.
		# The movement first, so the motor `rebind_map` rebuilds (and logs) is the map's.
		player.ads_rules = ads_rules
		player.apply_map_movement(map_movement())
		player.rebind_map(map)
		player.join_combat(combat)
		_add_fall_damage(player)

		var added := match_node.add_player(str(id), String(row["name"]), _tick, 0)

		if not added.ok:
			DotLog.warn(CHANNEL, "a player could not rejoin after the map change", {
				"player": id, "why": added.error.message
			})
			continue

		player.team = team_of(id)

	if progress != null:
		progress.rebind_world()

	# The layers the NEW mode asks for, and only them: a changegame must not leave
	# a mode with objectives whose objectives are null, or a siege with no monsters.
	#
	# Before the announcement, because a HUD and a net bridge both read these off the
	# game inside their `map_changed` handlers.
	_reconcile_world_layers()

	# Before the announcement: the net bridge registers them inside its `map_changed`.
	_build_toys()

	# Whatever state the last match ended in, the new one starts from the beginning.
	match_node.start(_tick)

	DotLog.info(CHANNEL, "map changed", {
		"map": map.display_name, "mode": String(mode.id), "players": _players.size()
	})

	map_changed.emit(map)
	_announce_mode()

	# After the announcement, so every layer that rebinds on it — the player stack's
	# spawn sites and spawn rules, the effects' resolver hook — has done so before the
	# first spawn on the new map asks it anything.
	_respawn_for_new_map()

	return DotResult.success(map)


## Puts every player in the match at a spawn point of the map that was just built.
##
## [b]A position is a place in a room, and the room was replaced.[/b] Before this, a map
## change re-bodied each player against the new geometry and left them where they had
## been standing in the old one. Wherever the new map has a box, a player carried over
## into it is inside solid geometry, and the flat body resolves that by whichever face
## is nearest — which for a player standing on the floor inside a box is the floor.
## Found building `dm_atrium`'s keep: a box across its south door landed on a position
## a `dm_box` player had carried over, and headless_match found him under the floor.
##
## Through [method _on_respawn_due], which is the round start's path: the director's
## choice with its enemy distance and team sides, spawn protection, a cleared effect set
## and the loadout. A player who was dead is put back too, because the timer that would
## have revived them belonged to the match that was just freed and the new one's warmup
## does not drain a queue. Spectators stay out, exactly as the round start leaves them.
##
## [b]The authority only.[/b] A mirroring client runs `change_map` to rebuild its own
## geometry; where anybody stands is the server's decision, and the snapshot after the
## respawn carries it — the predictor adopts the server's state and replays on top.
func _respawn_for_new_map() -> void:
	if not is_authority or match_node == null:
		return

	for id in player_ids():
		var key := str(id)
		var record := match_node.scoreboard.find(key)

		if record == null or not record.present or record.spectating:
			continue

		_on_respawn_due(key, match_node.choose_spawn(key, _tick), _tick)


## Puts an imported map's solid in the tree, replacing the last one; nothing on a
## built-in map.
##
## [b]On every machine, the dedicated server included.[/b] A built-in map is analytic and a
## headless server never builds its level; an imported map's movement and shots are
## physics queries (`ArenaMap.movement_body`), so the brushes have to be in this process's
## physics space wherever anybody moves. [b]`free()`, not `queue_free()`[/b]: the next
## map's solid goes in on the next line, and two maps' brushes in one space for a frame
## is a player standing on the wrong one.
func _build_world_collision() -> void:
	if _world_collision != null and is_instance_valid(_world_collision):
		remove_child(_world_collision)
		_world_collision.free()

	_world_collision = null

	if map == null or not map.is_imported():
		return

	_world_collision = map.to_collision()
	_world_collision.name = "WorldCollision"
	add_child(_world_collision)
	map.collision_root = _world_collision

	# Before `_build_match` turns the spawns into spawn points: a mapper's spawn inside the
	# floor would otherwise be a player rising through it. See `ArenaMap.settle_spawns`.
	var lifted := map.settle_spawns(map.movement_body(), ArenaPlayer.arena_tunables())

	if lifted > 0:
		DotLog.debug(CHANNEL, "spawns lifted out of an imported map's solid", {
			"map": String(map.id), "lifted": lifted, "of": map.spawns.size()
		})


## The solid on the layout's `world` layer, once there is a layout to ask.
func _classify_world_collision() -> void:
	if _world_collision != null and player_stack != null:
		var _n := player_stack.classify_tree(_world_collision, &"world")


## Frees everything that belongs to the map, in the order the connections require.
##
## [b]Disconnect before free, and disconnect from the object that holds the
## connection.[/b] Godot cleans up connections when a node is freed, so most of this
## is belt and braces — but [ArenaProgress] outlives the teardown and is connected to
## both the combat manager and the match node, and a node that is still connected to a
## freed object when its own handler runs is the error that has no line number.
func _teardown_world() -> void:
	_clear_toys()

	if progress != null:
		progress.unbind_world()

	for id in player_ids():
		(_players[id] as ArenaPlayer).leave_combat()

	if match_node != null and is_instance_valid(match_node):
		if match_node.respawn_due.is_connected(_on_respawn_due):
			match_node.respawn_due.disconnect(_on_respawn_due)

		if match_node.state_changed.is_connected(_on_match_state_changed):
			match_node.state_changed.disconnect(_on_match_state_changed)

		# The position callable closes over this node and is read on every spawn
		# selection. Cleared rather than left to the free, because a Callable held by
		# a node being freed is exactly the sort of thing that runs once more.
		match_node.position_fn = Callable()

		remove_child(match_node)
		match_node.queue_free()

	match_node = null

	if combat != null and is_instance_valid(combat):
		if combat.entity_killed.is_connected(_on_entity_killed):
			combat.entity_killed.disconnect(_on_entity_killed)

		if combat.damage_applied.is_connected(_on_damage_applied):
			combat.damage_applied.disconnect(_on_damage_applied)

		remove_child(combat)
		combat.queue_free()

	combat = null
	projectiles = null
	grenades = null

	if jail_view != null:
		remove_child(jail_view)
		jail_view.queue_free()
		jail_view = null
	if drops != null:
		remove_child(drops)
		drops.queue_free()
		drops = null
	ArenaWeaponDropWiring.teardown(self)

	for point in _spawn_points:
		if is_instance_valid(point):
			remove_child(point)
			point.queue_free()

	_spawn_points.clear()


# --- Players ---------------------------------------------------------------

static func make_fall_rules() -> DotFallDamageRules:
	var rules := DotFallDamageRules.new()
	rules.enabled = true
	# Wall-runs and ramps make drops routine here: a higher threshold, a cap, and no lethal speed.
	rules.threshold = 16.0
	rules.scale = 3.0
	rules.max_damage = 50.0
	return rules


## One [DotFallDamage] per player, rebuilt when the combat manager is (a map change).
func _add_fall_damage(player: ArenaPlayer) -> void:
	var old := player.get_node_or_null("FallDamage")

	if old != null:
		player.remove_child(old)
		old.queue_free()

	if combat == null or player.controller == null:
		return

	var fall := DotFallDamage.new()
	fall.name = "FallDamage"
	fall.rules = fall_rules
	fall.victim = player.player_id
	fall.controller = DotNodeRef.of_path(player.controller.get_path())
	fall.controller.mode = DotNodeRef.Mode.ABSOLUTE
	fall.combat = DotNodeRef.of_path(combat.get_path())
	fall.combat.mode = DotNodeRef.Mode.ABSOLUTE
	fall.context_checks[&"protected"] = func() -> bool:
		if map != null and map.movement_profile == &"surf":
			return true
		return match_node != null and match_node.state != DotMatch.State.LIVE
	player.add_child(fall)


## Adds a player, builds their body, and puts them in the match.
func add_player(
	id: int, display_name: String, wanted_team: int = 0
) -> DotResult:
	if _players.has(id):
		return DotResult.fail(DotError.CODE_STATE, "Player %d is already here." % id)

	var player := ArenaPlayer.new()
	player.before_death = ArenaWeaponDropWiring.drop_for_death.bind(self, player)
	player.setup(
		ArenaPlayer.Mode.HEADLESS if headless else ArenaPlayer.Mode.PHYSICS,
		map,
		id,
		display_name
	)
	# Before it enters the tree, so the controller that readies (and logs) is the map's.
	player.apply_map_movement(map_movement())
	player.apply_vitals(config.player_health, config.player_armour, config.player_regen, config.fall_out_depth)
	add_child(player)

	# The layout's player mask, rather than `DotFpsTunables`' default of 1. See
	# `ArenaPlayer.use_collision_mask` — with props on their own layer, 1 is a player
	# who walks through crates.
	if player_stack != null:
		player.use_collision_mask(player_stack.player_collision_mask())

	player.join_combat(combat)
	_add_fall_damage(player)
	combat_feel.attach(player.arsenal)
	combat_feel.track_tunables(player.controller.tunables)
	player.apply_movement_rules(movement_rules)
	player.arsenal.fire_buffer_seconds = fire_buffer_seconds
	player.solid_hulls_fn = solid_hulls_for
	_players[id] = player

	var added := match_node.add_player(str(id), display_name, _tick, wanted_team)

	if not added.ok:
		remove_player(id)
		return added

	# The side dot-match actually put them on, which is not necessarily the one they
	# asked for: `DotTeamManager.assign` refuses a full team and balances an uneven one.
	# Reading it back rather than assuming is the difference between a scoreboard that
	# matches the game and one that matches the request.
	#
	# It is set on the player because that is what dot-combat's friendly-fire check and
	# the renderer's colour both read, and `ArenaPlayer.team` had been declared and
	# assigned by nothing since the class was written.
	player.team = team_of(id)

	if progress != null:
		# Not awaited. An achievement store may be remote and a join may not wait on
		# it; readings that arrive during the load are still counted, because
		# `DotAchievementStatsLink` holds its baseline until the tracker has the
		# player. See `ArenaProgress.begin`.
		progress.begin(id, display_name)

	# Last, and only once the player is fully in: a handler runs synchronously inside
	# this and the first thing a client's does is hang a camera off them.
	player_added.emit(player)

	return DotResult.success(player)


func remove_player(id: int) -> void:
	_unlag.erase(id)
	if block_rules != null:
		block_rules.forget(id)
	medals.forget(id)
	var player := player_for(id)

	if player == null:
		return

	if props != null:
		# Before anything else: it drops whatever they were carrying, and a physics
		# gun still holding a crate for a player who no longer exists holds it for
		# ever — the prop is frozen mid-air and nothing owns it.
		props.release_player(id)

	if progress != null:
		# Before the player leaves the match: `leave` files the session onto the
		# boards and reads the display name off the player to do it.
		progress.leave(id)

	if player_stack != null:
		# Before dot-match forgets them: the stack reads the scoreboard and the match's
		# team for the records it files, and after `match_node.remove_player` there is
		# nothing there to read. A method rather than a signal, because there is no
		# signal here and adding one for a single subscriber is worse than a call.
		player_stack.drop_player(id)

	player.leave_combat()
	match_node.remove_player(str(id))

	_players.erase(id)
	remove_child(player)
	player.queue_free()


## Which side a player is on, or 0 in a free-for-all.
func team_of(id: int) -> int:
	if match_node == null or match_node.teams == null:
		return 0

	return match_node.teams.team_of(str(id))


## The sides in play, empty in a free-for-all.
func teams() -> Array[DotTeam]:
	if match_node == null or match_node.teams == null:
		return []

	return match_node.teams.teams


## Sets movement rules (key -> number, see [constant ArenaPlayer.MOVEMENT_RULES]) for
## every player now and later. On a server, the bridge forwards them to clients; on a
## client, this is where RULES lands.
func set_movement_rules(rules: Dictionary) -> void:
	for key in rules:
		if ArenaPlayer.MOVEMENT_RULES.has(String(key)) or SHOW_RULES.has(String(key)):
			movement_rules[String(key)] = float(rules[key])

	for player in players():
		player.apply_movement_rules(movement_rules)

		if rules.has("surf") or rules.has("surf_air_accelerate"):
			player.apply_map_movement(map_movement())

	if not is_authority and rules.has("mode_index"):
		var all := ArenaModes.all()
		var index := int(rules["mode_index"])
		if index >= 0 and index < all.size() and (shown_mode == null or shown_mode.id != all[index].id):
			shown_mode = all[index]
			mode_shown.emit(shown_mode)

	if is_authority and rules.has("killcam"):
		apply_match_limits()

	if not is_authority and rules.has("fire_buffer"):
		fire_buffer_seconds = float(rules["fire_buffer"])

	if not is_authority and rules.has("max_unlag_ms"):
		max_unlag_ms = float(rules["max_unlag_ms"])

	movement_rules_changed.emit(movement_rules)


## Rules about what a death and a body look like, carried in the same set as the
## movement ones (RULES) because a client draws them and the server owner sets them:
## `break_mode` 0 none / 1 limbs / 2 explode, `break_limbs`, `break_criticals_only`, and
## `fp_body` (your own body in first person). Defaults in [constant SHOW_DEFAULTS].
##
## `surf` and `surf_air_accelerate` ride the same set because a client PREDICTS with them:
## `surf` 1 plays a combat surf map with the genre's air control and 0 with the arena's own
## (`arena_surf`), `surf_air_accelerate` is that air control's `sv_airaccelerate`
## (`arena_surf_airaccelerate`). See [method map_movement].
##
## `killcam` is the final killcam's seconds (`mp_killcam_time`, 0 off): clients play it, and the
## authority adds it to the match's end ([method _override_rules]).
const SHOW_RULES: PackedStringArray = ["break_mode", "break_limbs", "break_criticals_only", "fp_body", "mode_index", "surf", "surf_air_accelerate", "killcam", "max_unlag_ms", "fire_buffer"]
const SHOW_DEFAULTS := {"break_mode": 1.0, "break_limbs": 1.0, "break_criticals_only": 1.0, "fp_body": 0.0, "surf": 1.0, "surf_air_accelerate": 150.0, "killcam": 7.0}


## The movement overrides the current map asks for, after the server's rules.
##
## [b]Per map, and derived on both ends from the map itself[/b] — `ArenaMap.movement_profile`,
## which an imported map's manifest decides — so a client that loaded the map already knows,
## and only an operator's change has to travel (in RULES, as `surf` and
## `surf_air_accelerate`). Empty on the arena's own maps, which is what puts the arena's air
## control back after a surf map: `ArenaPlayer.apply_map_movement` resets every key it is
## not given.
func map_movement() -> Dictionary:
	if map == null or map.movement_profile != &"surf" or rule("surf") == 0.0:
		return {}

	var out: Dictionary = ArenaPlayer.SURF_TUNABLES.duplicate()
	out["air_accelerate"] = rule("surf_air_accelerate")
	return out


## The mode a client is told is being played, for its banner and its keys. A client's own
## [member mode] is whatever it was built with and is never replaced — logic reads it —
## so what it shows comes from here. On the authority it is the mode.
var shown_mode: ArenaMode = null


func displayed_mode() -> ArenaMode:
	return shown_mode if shown_mode != null else mode


## Tells clients which mode this is, by its index in the catalogue they share. Server side.
func _announce_mode() -> void:
	if is_authority and mode != null:
		var index := ArenaModes.ids().find(mode.id)
		if index >= 0:
			set_movement_rules({"mode_index": index})


## A presentation rule's current value: the server's, or the default.
func rule(key: String) -> float:
	return float(movement_rules.get(key, SHOW_DEFAULTS.get(key, 0.0)))


## The fall a death gets: dot-player-char's reaction rule over the server's weights, seeded from
## the victim and the tick. Server side; the bridge sends it on KILL and every client draws it.
##
## The direction is the shot's; a death with none (a fall, a slay) is pushed by nothing. The
## killing weapon's def is what lets the sniper and the launcher throw a body
## (zee-dot-weapons' `params.death_reaction`).
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


## How a body comes apart on death under the current rules.
func break_rules() -> DotPlayerBreakRules:
	var rules := DotPlayerBreakRules.new()
	rules.mode = clampi(int(rule("break_mode")), 0, 2) as DotPlayerBreakRules.Mode
	rules.limbs = maxi(int(rule("break_limbs")), 1)
	rules.criticals_only = rule("break_criticals_only") != 0.0
	return rules


static func _make_killview_rules() -> DotKillViewRules:
	var rules := DotKillViewRules.new()
	rules.enabled = true
	return rules


## The kill view's server half over this game: every living eye, respawns held in dot-match's queue.
func make_killview_server() -> DotKillViewServer:
	var server := DotKillViewServer.new(killview_rules)
	server.tick_rate = tick_rate
	KillPov.watch_hits(self)
	server.eyes_fn = func() -> Array:
		var eyes: Array = []
		for p: ArenaPlayer in players():
			if not p.is_alive() or p.controller == null or p.controller.state == null:
				continue
			var st: DotFpsState = p.controller.state
			var eye: Vector3 = p.controller.motor.eye_position(st) if p.controller.motor != null else st.position + Vector3(0.0, 1.6, 0.0)
			var basis := Basis.from_euler(Vector3(deg_to_rad(st.pitch), deg_to_rad(st.yaw), 0.0))
			eyes.append({"id": p.player_id, "transform": Transform3D(basis, eye), "aux": KillPov.aux_of(p)})
		return eyes
	server.use_respawn_queue(func() -> Variant: return match_node.respawns if match_node != null else null,
		func(id: Variant) -> DotResult: return respawn_player(int(id)))
	return server


func player_for(id: int) -> ArenaPlayer:
	return _players.get(id)


## Builds [member noblock] over dot-team's rules (its cfg layers; strict fails the boot) for a server or a solo game.
func make_noblock(strict := DotGameConfigBinder.default_strict()) -> DotResult:
	var made := DotGameNoblock.create("game-arena", Callable(self, "block_side"), PackedStringArray(), strict)
	if not made.ok:
		return made
	noblock = made.value
	noblock_bound = false
	noblock.feed(body_rules)
	block_rules = noblock.rules
	return made


## The side a player blocks as: its team, or "" in a free-for-all (no teammates, so it stays solid).
func block_side(id: Variant) -> Variant:
	var team := team_of(int(id)) if not teams().is_empty() else 0
	return str(team) if team > 0 else ""


## The standing hulls player [param id] stops at: every other living player's, where they
## stand now; none while `mp_solidplayers` is 0. Asked per sweep by the movement body, so a
## player moved earlier in this tick is met where it moved to (the same on every machine:
## players tick in one order).
func solid_hulls_for(id: int, tick: int = -1) -> Array:
	var out: Array = []
	if not body_rules.solid:
		return out
	for key: Variant in _players.keys():
		if int(key) == id or not body_rules.blocks(id, int(key)):
			continue
		var other: ArenaPlayer = _players[key]
		if other == null or not other.is_alive() or other.controller == null or other.controller.state == null:
			continue
		var feet := other.controller.state.position
		if remote_feet_fn.is_valid() and tick >= 0:
			var at: Variant = remote_feet_fn.call(int(key), id, tick)
			if at is Vector3:
				feet = at
		var tunables := other.controller.tunables
		out.append(ArenaSolidBody.hull_at(feet, tunables.stand_height, tunables.radius))
	return out


func players() -> Array[ArenaPlayer]:
	var out: Array[ArenaPlayer] = []
	for key in _players.keys():
		out.append(_players[key])
	return out


func player_ids() -> Array[int]:
	var out: Array[int] = []
	for key in _players.keys():
		out.append(int(key))
	out.sort()
	return out


## Applies a player's saved loadout. Falls back to the default on any failure.
##
## A failure here must never stop a player spawning: an unreachable loadout store is a
## reason to give them a rifle, not a reason to leave them watching.
func apply_loadout(id: int) -> void:
	var player := player_for(id)

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
	if mode.pool_keeps_melee and not player.arsenal.has_slot(ZeeWeaponIds.SLOT_MELEE):
		var _knife := player.arsenal.give(ArenaContent.melee_id())
	if hand > 0:
		player.hold(hand)


## A storage key that is usable as a filename.
##
## `DotLoadoutKey.is_usable` has a minimum length, so a bare session id of "7" is
## refused before any store sees it. Padding here rather than loosening the check: the
## check exists so a malformed key can never reach a filesystem path.
##
## [b]One key for every store, and that is deliberate.[/b] Loadouts, achievement
## progress and dot-stats' sessions are three subsystems that each want a durable
## per-player id, and three formats would be three chances for one of them to file
## under a name the others cannot find. It also refuses to be an account id: dot-stats'
## reporter rejects anything with a `backbone:` prefix before it leaves the server, and
## a key built from the session id can never carry one.
static func storage_key(id: int) -> String:
	return ArenaLoadoutIdentity.seat_key(id)


func _loadout_key(id: int) -> String:
	return loadout_identity.key_of(id)


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
## Records every player's position for this tick, for [method _unlag_rewind].
func _unlag_record() -> void:
	for id in _players:
		var player: ArenaPlayer = _players[id]
		var ring: Array = _unlag.get(id, [])
		if ring.is_empty():
			var positions := PackedVector3Array()
			positions.resize(UNLAG_HISTORY)
			var ticks := PackedInt32Array()
			ticks.resize(UNLAG_HISTORY)
			ticks.fill(-1)
			ring = [positions, ticks]
			_unlag[id] = ring
		# Packed arrays are values: taken out, written, and put back, or the write lands
		# on a copy and the history stays empty (it did, the first time).
		var positions: PackedVector3Array = ring[0]
		var ticks: PackedInt32Array = ring[1]
		var slot := _tick % UNLAG_HISTORY
		var before := (_tick - 1) % UNLAG_HISTORY
		# A respawn or a teleport: rewinding across it would stand hitboxes where they died.
		if ticks[before] == _tick - 1 and positions[before].distance_to(player.global_position) > TELEPORT_CUT:
			ticks.fill(-1)
		positions[slot] = player.global_position
		ticks[slot] = _tick
		ring[0] = positions
		ring[1] = ticks
		_unlag[id] = ring


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
	var a := lo % UNLAG_HISTORY
	var b := (lo + 1) % UNLAG_HISTORY
	if ticks[a] != lo:
		return null
	if ticks[b] != lo + 1:
		return positions[a]
	return positions[a].lerp(positions[b], at - float(lo))


## Where player [param id] was at [param at], blended between the recorded ticks [param older]
## and [param newer] (the snapshots the client drew between); null when either is not recorded.
func unlag_position_between(id: int, older: int, newer: int, at: float, snap := Callable()) -> Variant:
	var a: Variant = unlag_position_at(id, float(older))
	var b: Variant = unlag_position_at(id, float(newer))
	if a == null or b == null:
		return null
	if snap.is_valid():
		a = snap.call(a)
		b = snap.call(b)
	if newer <= older:
		return a
	return (a as Vector3).lerp(b, clampf((at - float(older)) / float(newer - older), 0.0, 1.0))


## A mover's view lag in ticks as both ends collide with it: -1 (the present) when none was sent
## or compensation is off, else at most `max_unlag_ms` and [constant COLLISION_LAG_MAX_TICKS].
func collision_lag(view_lag: float) -> float:
	if view_lag < 0.0 or max_unlag_ms <= 0.0:
		return -1.0
	return minf(view_lag, minf(max_unlag_ms * 0.001 * float(tick_rate), COLLISION_LAG_MAX_TICKS))


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


func tick(commands: Dictionary = {}) -> void:
	_tick += 1
	_sync_round_freeze()

	var shots: Array[DotShot] = []
	var delta := 1.0 / float(tick_rate)

	_pre_vy.clear()
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
			shots.append_array(outcome.shots)

			# Before the horde ticks, so the monsters hear it this tick.
			if horde != null and (not outcome.shots.is_empty() or not outcome.spawns.is_empty()):
				horde.note_fire(id, player.controller.state.position)
			# A rocket is launched and flown, not resolved as a shot (ArenaProjectiles).
			if projectiles != null:
				projectiles.accept(outcome)

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

	# After everybody moved: a coin is taken where its taker ended the tick.
	if drops != null and is_authority:
		drops.tick(_tick, _drop_sweepers())

	_sweep_jail_button()

	match_node.tick(_tick)

	if surf_rides != null:
		surf_rides.call(&"process", delta)


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


func current_tick() -> int:
	return _tick


## Records the surf rides real players take (`arena_surf_rides.gd`), off unless `bot_record` is on in the config, environment, command line or console; a no-op on a shell without dot-bot's recorder.
func start_ride_recording(add_cvar: Callable = Callable(), config_file: String = "user://bot_record.json") -> DotResult:
	if surf_rides != null:
		return DotResult.success(surf_rides)
	if DotAddonApi.build_level("dot_bot") < 5 or DotAddonApi.build_level("dot_player_controller") < 3 \
			or not ResourceLoader.exists("res://addons/dot_bot/runtime/surf/dot_bot_ride_harvest.gd"):
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "This shell has no ride recorder.")
	var config := DotBotDemoConfig.new()
	config.record = false
	var layered := config.load_layered(config_file if FileAccess.file_exists(config_file) else "")
	if not layered.ok:
		return layered
	if add_cvar.is_valid():
		var _cvars := config.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY)
	var made := DotBotDemoStore.from_config(config, null)
	if not made.ok or made.value == null:
		return made if not made.ok else DotResult.fail(DotError.CODE_STATE, "bot_record_store is off.")
	var store: DotBotDemoStore = made.value
	var opened := store.open()
	if not opened.ok:
		return opened
	var rides: RefCounted = (load(ArenaPaths.rebase("res://game/arena_surf_rides.gd")) as GDScript).new()
	var ready: DotResult = rides.call(&"setup", self, config, store, float(tick_rate))
	if not ready.ok:
		return ready
	surf_rides = rides
	return DotResult.success(rides)


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


# --- Events ----------------------------------------------------------------

## Whether [param entity_id] may be hurt now. False only for a player whose client is behind
## its loading cover (frozen by its own client, unable to see); a monster, a bot or a game
## with no [member loading_fn] is always harmable, so every offline suite is unchanged.
func can_be_harmed(entity_id: int) -> bool:
	if not loading_fn.is_valid():
		return true
	return not bool(loading_fn.call(entity_id))


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

	# Coins out of the body, if the rules say this kill drops any.
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
		k.tags = [ZeeWeaponIds.TAG_THROWN]
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
	if def == null or not def.tags.has(ZeeWeaponIds.TAG_MELEE):
		return

	var record := match_node.scoreboard.find(str(damage.victim))
	if record == null or record.score <= 0:
		return

	record.score -= 1
	match_node.scoreboard.score_changed.emit(record)


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


## Whether the round is waiting to go live with everyone held still. The client reads the
## state MATCH told it; a countdown only exists when its length is above zero.
func round_frozen() -> bool:
	return match_node != null and match_node.state == DotMatch.State.COUNTDOWN \
			and match_node.rules != null and match_node.rules.freeze_during_countdown


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


## Puts a player back into the world now, alive, at a spawn the director chooses.
##
## An administrator's respawn, and the same path a queued respawn takes — so a player an
## admin put back gets the director's spawn choice, spawn protection, a cleared effect
## set and their loadout, exactly like one the match put back. Anything still queued for
## them is cancelled first, or the queue would respawn them a second time moments later.
func respawn_player(id: int) -> DotResult:
	var player := player_for(id)

	if player == null:
		return DotResult.fail(DotError.CODE_INVALID, "Player %d is not in the match." % id)

	var key := str(id)

	if match_node.respawns != null:
		match_node.respawns.cancel(key)

	_on_respawn_due(key, match_node.choose_spawn(key, _tick), _tick)
	return DotResult.success(player)


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

	apply_loadout(id)


func _on_match_state_changed(from: DotMatch.State, to: DotMatch.State) -> void:
	# A new round has its own first blood, and nobody's revenge carries over from warmup.
	if to == DotMatch.State.LIVE:
		medals.reset_round()
		# And every toy home: a ball parked in a doorway during warmup is not a round's
		# head start for anybody.
		if toys != null and is_authority:
			toys.reset()
	match_state_changed.emit(from, to)


# --- Toys --------------------------------------------------------------------

## A toy's blast at its centre, m/s to a toy of up to 3 kg (dot-props' `blast`).
const TOY_BLAST_SPEED := 12.0


## The map's toys from [member ArenaMap.toys], on both ends, in the order the map lists them:
## that order is how a client pairs each with the server's entity. A headless authority gets
## a collision copy of a built-in level for them to land on; an imported map's solid is in the
## physics space already, and a drawing end's level is its scene.
func _build_toys() -> void:
	_clear_toys()
	if map == null:
		return
	var layout: DotPhysicsLayout = player_stack.physics.layout if player_stack != null and player_stack.physics != null else null

	if is_authority and headless and not map.is_imported() and not map.toys.is_empty():
		_toy_level = map.to_collision()
		_toy_level.name = "ToyLevel"
		add_child(_toy_level)
		if player_stack != null:
			var _n := player_stack.classify_tree(_toy_level, &"world")

	toys = DotPropToyBox.new()
	toys.name = "Toys"
	toys.authoritative = is_authority
	toys.draw = not headless
	toys.rules = toy_rules
	toys.gravity = 20.0
	toys.kill_y = map.floor_y - 40.0
	if layout != null:
		toys.loose_layer = layout.layer_mask(&"toy")
		toys.loose_mask = layout.collision_mask(&"toy")
		toys.solid_layer = layout.layer_mask(&"prop")
		toys.solid_mask = layout.collision_mask(&"prop")
		toys.footprint_layer = layout.layer_mask(&"footprint")
		toys.aim_mask = layout.mask_of([&"world", &"toy"] as Array[StringName])
	add_child(toys)
	var built := toys.build(map.toys)
	if not built.ok:
		DotLog.warn(CHANNEL, "a map's toys would not build", {"map": String(map.id), "why": built.error.message})
	var _sounds := toys.sound.connect(func(id: StringName, at: Vector3, strength: float) -> void: toy_sound.emit(id, at, strength))

	if projectiles != null and is_authority and not projectiles.detonated.is_connected(_on_detonated_near_toys):
		projectiles.detonated.connect(_on_detonated_near_toys)

	toys_built.emit()


func _clear_toys() -> void:
	if toys != null:
		toys_clearing.emit()
		remove_child(toys)
		toys.queue_free()
		toys = null
	if _toy_level != null and is_instance_valid(_toy_level):
		remove_child(_toy_level)
		_toy_level.queue_free()
	_toy_level = null


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
		var height := lerpf(tunables.stand_height, tunables.crouch_height, state.crouch_fraction) if tunables != null else 1.8
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


func _on_detonated_near_toys(at: Vector3, spawn: DotWeaponSpawn) -> void:
	if toys != null and is_authority and spawn != null:
		var _thrown := toys.blast(at, maxf(spawn.splash_radius, 2.0), TOY_BLAST_SPEED)


# --- Diagnostics -----------------------------------------------------------

func describe() -> Dictionary:
	return {
		"tick": _tick,
		"map": map.describe() if map != null else {},
		"players": _players.size(),
		"match": match_node.describe() if match_node != null else {},
		"combat": combat.describe() if combat != null else {},
		"progress": progress.describe() if progress != null else {},
		"horde": horde.describe() if horde != null else {},
		"props": props.describe() if props != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("arena    %s  tick %d" % [map.display_name if map != null else "?", _tick])
	out.append_array(match_node.describe_lines())
	out.append_array(combat.describe_lines())

	if progress != null:
		out.append_array(progress.describe_lines())

	if horde != null:
		out.append_array(horde.describe_lines())

	if props != null:
		out.append_array(props.describe_lines())

	return out
