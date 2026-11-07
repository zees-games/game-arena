@tool
extends "arena_game_part3.gd"

## The standing hulls player [param id] stops at: every other living player's, where they
## stand now; none while `mp_solidplayers` is 0. Asked per sweep by the movement body, so a
## player moved earlier in this tick is met where it moved to (the same on every machine:
## players tick in one order).
func solid_hulls_for(id: int, tick: int = -1) -> Array:
	var out: Array = []
	if not body_rules.solid:
		return out
	var me: ArenaPlayer = _players.get(id)
	var me_at := me.controller.state.position if me != null and me.controller != null and me.controller.state != null else Vector3.INF
	if _roster_dirty:
		_roster.clear()
		_roster_ids.resize(0)
		for key: Variant in _players.keys():
			_roster.append(_players[key])
			_roster_ids.append(int(key))
		_roster_dirty = false
	var remote := remote_feet_fn.is_valid() and tick >= 0
	var near := me_at != Vector3.INF
	# Position first: most of a crowd is out of reach, and the pair and alive tests cost more than the read.
	var coarse := HULL_NEAR_SQ if remote else HULL_REACH_SQ
	for i in range(_roster.size()):
		var other_id := _roster_ids[i]
		if other_id == id:
			continue
		var other := _roster[i]
		if other == null:
			continue
		var ctl := other.controller
		if ctl == null or ctl.state == null:
			continue
		var feet := ctl.state.position
		if near and feet.distance_squared_to(me_at) > coarse:
			continue
		if not body_rules.blocks(id, other_id) or not other.is_alive():
			continue
		if remote:
			var at: Variant = remote_feet_fn.call(other_id, id, tick)
			if at is Vector3:
				feet = at
			if near and feet.distance_squared_to(me_at) > HULL_REACH_SQ:
				continue
		var tunables := ctl.tunables
		out.append(ArenaSolidBody.hull_at(feet, tunables.stand_height, tunables.radius))
	return out

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
	ArenaPlayer.configure_body(config.avatar_height_units, config.avatar_crouch_units, config.avatar_radius_units, config.avatar_unit_metres)
	player.apply_map_movement(map_movement())
	player.apply_vitals(config.player_health, config.player_armour, config.player_regen, config.fall_out_depth)
	add_child(player)

	# The layout's player mask, rather than `DotFpsTunables`' default of 1. See
	# `ArenaPlayer.use_collision_mask` — with props on their own layer, 1 is a player
	# who walks through crates.
	if player_stack != null:
		player.use_collision_mask(player_stack.player_collision_mask())

	if is_authority:
		player.flashlight_cfg = flashlight_conf()
		player.flashlight_map = String(map.id) if map != null else ""
	player.join_combat(combat)
	_add_fall_damage(player)
	combat_feel.attach(player.arsenal)
	player.arsenal.ammo_types = ammo_types
	combat_feel.track_tunables(player.controller.tunables)
	player.apply_movement_rules(movement_rules)
	player.arsenal.fire_buffer_seconds = fire_buffer_seconds
	player.solid_hulls_fn = solid_hulls_for
	_players[id] = player
	_roster_dirty = true
	_ids_cache = []

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

func displayed_mode() -> ArenaMode:
	return shown_mode if shown_mode != null else mode

## How a body comes apart on death under the current rules.
func break_rules() -> DotPlayerBreakRules:
	var rules := DotPlayerBreakRules.new()
	rules.mode = clampi(int(rule("break_mode")), 0, 2) as DotPlayerBreakRules.Mode
	rules.limbs = maxi(int(rule("break_limbs")), 1)
	rules.criticals_only = rule("break_criticals_only") != 0.0
	return rules

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
			var eye: Vector3 = p.controller.motor.eye_position(st) if p.controller.motor != null else st.position + Vector3(0.0, ArenaPlayer.eye_height(), 0.0)
			var basis := Basis.from_euler(Vector3(deg_to_rad(st.pitch), deg_to_rad(st.yaw), 0.0))
			eyes.append({"id": p.player_id, "transform": Transform3D(basis, eye), "fov": KillPov.fov_of(p), "aux": KillPov.aux_of(p)})
		return eyes
	server.use_respawn_queue(func() -> Variant: return match_node.respawns if match_node != null else null,
		func(id: Variant) -> DotResult: return respawn_player(int(id)))
	return server

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
	var _stats := start_demo_stats(config, store)
	return DotResult.success(rides)

## Records `place` and `engage` episodes into [param store] and lets the bots roam where people stand; a no-op on a shell without dot-bot's heatmap and aim statistics.
func start_demo_stats(config: DotBotDemoConfig, store: DotBotDemoStore) -> DotResult:
	if demo_stats != null:
		return DotResult.success(demo_stats)
	if not ResourceLoader.exists("res://addons/dot_bot/runtime/dot_bot_demo_heatmap.gd") or not ResourceLoader.exists("res://addons/dot_bot/runtime/dot_bot_aim_stats.gd"):
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "This shell has no heatmap or aim statistics.")
	var stats: RefCounted = (load(ArenaPaths.rebase("res://game/arena_demo_stats.gd")) as GDScript).new()
	var ready: DotResult = stats.call(&"setup", self, config, store, float(tick_rate))
	if not ready.ok:
		return ready
	demo_stats = stats
	return DotResult.success(stats)

# --- Events ----------------------------------------------------------------

## Whether [param entity_id] may be hurt now. False only for a player whose client is behind
## its loading cover (frozen by its own client, unable to see); a monster, a bot or a game
## with no [member loading_fn] is always harmable, so every offline suite is unchanged.
func can_be_harmed(entity_id: int) -> bool:
	if not loading_fn.is_valid():
		return true
	return not bool(loading_fn.call(entity_id))

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
