extends DotModule

const ArenaGame := preload("arena_game.gd")
const ArenaPlayer := preload("arena_player.gd")
const ArenaNetAoi := preload("arena_net_aoi.gd")
const ArenaBots := preload("arena_bots.gd")
const ArenaBotLoadouts := preload("arena_bot_loadouts.gd")
const ArenaBotBrain := preload("arena_bot_brain.gd")
const ArenaBotThreads := preload("arena_bot_threads.gd")
const ArenaPlayerStack := preload("arena_player_stack.gd")
const ArenaHullGrid := preload("arena_hull_grid.gd")
const ArenaTickBudget := preload("arena_tick_budget.gd")
const TagRules := preload("arena_name_tag_rules.gd")
const ArenaFlagCarry := preload("arena_flag_carry.gd")

## Base of [ArenaModule]: the operator-facing cvars that map onto a rule table, so the module itself
## holds the lifecycle. Split out for the size gate; the state they read lives here too.
var game: ArenaGame = null
## The netcode. Owned here rather than by the game, because a headless match and a
## dedicated server are different deployments of the same game and only one replicates.
var net: DotNetManager = null
var _cv_maxrate: DotConVar = null
var _cv_snapshot_rate: DotConVar = null
## The most snapshot workers [method default_snapshot_workers] picks: 4 was the measured win (fc-snapshot-workers-1).
const SNAPSHOT_WORKERS_MAX := 4
## Relevance rings for a big room (sv_net_aoi_players and friends); see arena_net_aoi.gd.
var net_aoi: ArenaNetAoi = null
## The team menu server and its team layout cvars (arena_team_menu.gd).
var team_menu: RefCounted = null


## cvar -> the movement tunable it sets, with what it means. Each defaults to what
## `ArenaPlayer.arena_tunables()` already says, so a server that sets none of them plays
## exactly as before; a change reaches every player now and later and, through RULES,
## every client, so a client never predicts a slide the server does not make.
const _OTHER_MOVEMENT_CVARS := {
	"arena_speed_scale": ["speed_scale", "Multiplier on every ground speed, 1 as set (a server-wide slowdown or speed-up)"],
	"arena_run_speed": ["max_speed", "Running speed, m/s"],
	"arena_walk_scale": ["walk_speed_scale", "Walk speed as a fraction of run"],
	"arena_sprint_scale": ["sprint_speed_scale", "Sprint speed as a fraction of run"],
	"arena_crouch_scale": ["crouch_speed_scale", "Crouch speed as a fraction of run"],
	"sv_ads_speed_mult": ["aim_speed_scale", "Ground speed while aiming down the sights, as a fraction (1 for no slowdown)"],
	"arena_launch": ["launch_enabled", "E throws the player into the air (1) or does nothing (0, the default)"],
	"arena_launch_velocity": ["launch_velocity", "Upward speed of a launch, m/s"],
	"arena_launch_forward": ["launch_forward", "Forward speed a launch adds, m/s"],
	"arena_launch_cooldown": ["launch_cooldown", "Seconds between launches"],
	"arena_dash": ["dash_enabled", "Shift dashes along the way you steer (1) or does nothing (0, the default)"],
	"arena_dash_speed": ["dash_speed", "Speed of a dash, m/s"],
	"arena_dash_lift": ["dash_lift", "Upward speed a dash adds, m/s"],
	"arena_dash_cooldown": ["dash_cooldown", "Seconds between dashes"],
	"arena_wall_run": ["wall_run_enabled", "A fast jump along a wall runs on it (1) or falls past it (0)"],
	"arena_wall_run_min_speed": ["wall_run_min_speed", "Speed along a wall needed to run on it, m/s"],
	"arena_wall_run_time": ["wall_run_max_time", "Longest a wall run lasts, seconds (at most 1.9)"],
	"arena_wall_run_gravity": ["wall_run_gravity_scale", "Share of gravity felt while wall running, 0 to 1"],
	"arena_wall_jump": ["wall_jump_enabled", "Jump in the air beside a wall jumps off it (1) or does nothing (0)"],
	"arena_wall_jump_push": ["wall_jump_push_speed", "Speed a wall jump pushes away from the wall, m/s"],
	"arena_wall_jump_up": ["wall_jump_up_speed", "Upward speed a wall jump sets, m/s"],
	"arena_wall_jumps": ["wall_jump_max_per_air", "Wall jumps before landing again, off any walls (0 for no limit)"],
	"arena_wall_slide": ["wall_slide_speed", "Fastest fall while pressed against a wall, m/s (0 for no wall slide)"],
	"arena_wall_run_end_speed": ["wall_run_end_speed", "A run ends when the speed along the wall falls under this, m/s"],
	"arena_wall_run_damping": ["wall_run_vertical_damping", "How fast a run eases the vertical speed away, per second (higher holds you up harder)"],
	"arena_wall_run_max_fall": ["wall_run_max_fall_speed", "Fastest fall a run can still catch, m/s"],
	"arena_wall_run_angle": ["wall_run_max_approach_angle", "Widest angle off the wall's plane a run can start at, degrees (running head-on is no run)"],
	"arena_wall_jump_look": ["wall_jump_look_blend", "How far a wall jump leans from the wall's normal toward the view, 0 to 1"],
	"arena_wall_jumps_per_wall": ["wall_jump_max_per_wall", "Wall jumps off the same wall before landing again"],
	"arena_wall_run_body_roll": ["wall_run_body_roll", "Degrees a drawn body rolls (feet to the wall) while wall running"],
	"arena_wall_run_body_yaw": ["wall_run_body_yaw", "Degrees a drawn body turns toward the wall while wall running"],
	"arena_wall_run_auto": ["wall_run_auto", "Touching a wall in the air starts a run with no press, and a press wall-jumps (1) or the press starts it (0, with arena_wall_run_on_jump)"],
	"arena_wall_run_on_jump": ["wall_run_on_jump", "A jump press beside a wall starts a run and turns the heading along it (1) or only jumps off (0)"],
	"arena_wall_run_turn_view": ["wall_run_turn_view", "The view turns along the wall when a jump starts a run (1) or only the heading does (0)"],
	"arena_wall_run_jump_speed": ["wall_run_jump_min_speed", "Horizontal speed a jump-started wall run needs, m/s"],
	"arena_wall_run_jump_angle": ["wall_run_jump_max_angle", "Widest angle off the wall's plane a jump-started run accepts, degrees"],
	"arena_wall_run_cooldown": ["wall_run_cooldown", "Seconds after a wall run ends before another may start"],
	"arena_wall_run_min_height": ["wall_run_min_height", "Height a wall face must have around the contact for a run to start, m (0 for any face)"],
	"arena_wall_run_min_length": ["wall_run_min_length", "Length a wall must continue ahead for a run to start, m (0 for any face)"],
	"arena_wall_angle": ["wall_max_angle_from_vertical", "Steepest lean from vertical a wall may have and still be run on, degrees"],
	"arena_break": ["break_mode", "On a death the body: 0 stays whole, 1 loses limbs, 2 explodes"],
	"arena_break_limbs": ["break_limbs", "How many limbs come off when arena_break is 1"],
	"arena_break_criticals": ["break_criticals_only", "Only a critical (a headshot) breaks a body (1), or any kill (0)"],
	"arena_fp_body": ["fp_body", "Players see their own body when they look down (1)"],
	"arena_fp_arms": ["fp_arms", "First-person arms everybody sees, own and the killer's in a kill view: 0 each player's own look, N one stock arm set"],
	"arena_surf": ["surf", "A combat surf map plays with the genre's air control (1) or the arena's own (0)"],
	"arena_surf_airaccelerate": ["surf_air_accelerate", "Air acceleration on a combat surf map (the genre's sv_airaccelerate)"],
	"mp_killcam_time": ["killcam", "Seconds the final killcam plays at a match's end, added to the end's wait (0 for none)"],
	"arena_crit_scale": ["", "Extra damage multiplier on a critical hit (1 for none)"],
	"arena_crit_chance": ["", "Chance any hit is a critical, 0 to 1 (headshots always are)"],
}

## [constant _OTHER_MOVEMENT_CVARS] plus the slide's, whose names and words dot-player-controller writes once.
static var MOVEMENT_CVARS: Dictionary = _OTHER_MOVEMENT_CVARS.merged(DotFpsSlidePreset.cvar_table("arena_slide"))


func _add_movement_cvars() -> void:
	var defaults := ArenaPlayer.arena_tunables()

	for cvar in MOVEMENT_CVARS:
		var key: String = MOVEMENT_CVARS[cvar][0]

		# The two critical cvars set dot-combat's rules on the server, not a rule a client
		# draws: a critical is judged where the damage is.
		if key == "":
			_add_critical_cvar(cvar, MOVEMENT_CVARS[cvar][1])
			continue

		var value: Variant = (
			defaults.get(key) if not ArenaGame.SHOW_DEFAULTS.has(key)
			else ArenaGame.SHOW_DEFAULTS[key]
		)
		if value == null:
			value = ArenaPlayer.BODY_RULES.get(key)
		var text := ("1" if value else "0") if value is bool else str(value)

		add_cvar(
			cvar, text, MOVEMENT_CVARS[cvar][1],
			DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
		).with_min(0.0).changed.connect(
			func(_old: String, new_value: String) -> void:
				game.set_movement_rules({key: new_value.to_float()})
				log_info("movement rule changed", {"rule": key, "value": new_value})
		)
	_add_hit_group_cvars()


## arena_head_mult, _neck_mult, _stomach_mult and _leg_mult: dot-combat's `DotHitGroup.bind_cvars` on the resolver's table (defaults are dot-combat's).
func _add_hit_group_cvars() -> void:
	var groups: DotHitGroup = game.combat.resolver.hit_groups if game.combat != null and game.combat.resolver != null else null
	if groups == null:
		return
	groups.bind_cvars(add_cvar, "arena", DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY)


## cvar -> the rule key whose value is a TagRules mask, and what it means.
const TAG_CVARS := {
	"mp_nametags": ["nametags", "Who gets a name tag over their head for players: always, team, hover (cursor on the body), hurt, off, or a list like team,hover. A player's own choice can only narrow it"],
	"mp_hpbars": ["hpbars", "Who gets a health bar over their head: always, team, hover, hurt, smart, off, or a list like team,hover. A player's own choice can only narrow it"],
}


func _add_tag_cvars() -> void:
	for cvar in TAG_CVARS:
		var key: String = TAG_CVARS[cvar][0]
		var start := int(ArenaGame.SHOW_DEFAULTS[key])
		add_cvar(
			cvar, TagRules.describe(start), TAG_CVARS[cvar][1],
			DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
		).changed.connect(
			func(old: String, new_value: String) -> void:
				var mask := TagRules.parse(new_value)
				if mask < 0:
					log_info("tag rule refused", {"rule": key, "value": new_value, "kept": old})
					return
				game.set_movement_rules({key: float(mask)})
				log_info("tag rule changed", {"rule": key, "value": TagRules.describe(mask)})
		)


## cvar -> the key in `ArenaGame.jail_rules` it sets, and what it means.
const JAIL_CVARS := {
	"arena_jail": ["enabled", "A fall on a map with a jail lands in it, and its gate works (1), or the map's volumes run as shipped (0)"],
	"arena_jail_open": ["open", "Seconds the jail's gate stays open after its button is pressed"],
	"arena_jail_cooldown": ["cooldown", "Seconds the gate then stays shut before the button works again"],
}


## cvar -> the key in `ArenaGame.drop_rules` it sets, and what it means.
const DROP_CVARS := {
	"arena_drop_points": ["points", "Points a critical kill drops (0 for none)"],
	"arena_drop_point_value": ["point_value", "What one point adds to its taker's count"],
	"arena_drop_health": ["health", "Health in the pack a critical kill drops (0 for none)"],
	"arena_drop_any_kill": ["any_kill", "Every kill drops (1), or only a critical one (0)"],
	"arena_drop_life": ["life", "Seconds a drop lies there before it goes"],
	"arena_packs": ["packs", "The map's health and ammo packs are out (1) or not (0)"],
	"arena_pack_health": ["pack_health", "Health in a map's health pack"],
	"arena_pack_ammo": ["pack_ammo", "Percent of each weapon's reserve an ammo pack refills"],
	"arena_pack_respawn": ["pack_respawn", "Seconds a taken pack takes to come back"],
}


## cvar -> the key in `ArenaPlayerStack.spawn_settings` it sets, and what it means.
const CTF_CVARS := {
	"arena_ctf_capturelimit": ["capture_limit", "Captures that win a capture-the-flag match (0 for none)"],
	"arena_ctf_timelimit": ["time_limit_sec", "Seconds a capture-the-flag match lasts, most captures wins (0, the default, for no time limit)"],
	"arena_ctf_return": ["return_sec", "Seconds a dropped flag waits before it goes home"],
	"arena_ctf_drop": ["drop_sec", "Seconds after a drop before the dropper may take the flag again"],
	"arena_ctf_carrier_speed": ["carrier_speed", "A flag carrier's speed as a fraction of normal"],
	"arena_ctf_friendly_return": ["friendly_return", "The flag's own team returns a dropped flag by touching it (1) or only the timer does (0)"],
	"arena_ctf_require_home": ["require_home", "A carrier scores only while their own flag is at home (1) or at any time (0)"],
	"arena_ctf_teams": ["team_count", "Teams in capture the flag, 2 to 8 (from the next map)"],
}

## cvar -> the [code]arena_flag_carry.gd[/code] setting it sets, and what it means.
const FLAG_CARRY_CVARS := {
	"arena_ctf_one_hand": ["one_hand", "A flag carrier holds only one-handed items: melee, sidearm, thrown (1, the default) or anything (0)"],
	"arena_ctf_drop_key": ["drop_key", "The drop key drops a carried flag ahead of the aim (1, the default) or the weapon as usual (0)"],
	"arena_ctf_drop_speed": ["drop_speed", "Metres a second a dropped flag leaves the hand at, on top of the carrier's speed (4 is the default)"],
	"arena_ctf_flag_physics": ["physics", "A dropped flag falls, slides and bounces upright (1, the default) or lies on the floor at once (0)"],
}

const SPAWN_CVARS := {
	"arena_spawn_mode": ["mode", "How a respawn picks its site: scatter (default: random across the whole map), avoid, weighted, furthest or random"],
	"arena_spawn_min_enemy": ["min_enemy", "In avoid mode, the nearest an enemy may be to a site, in metres"],
	"arena_spawn_sight_penalty": ["sight_penalty", "What an enemy being able to see a site costs it"],
	"arena_spawn_enemy_weight": ["enemy_weight", "What each metre from the nearest enemy is worth"],
}


## `arena_max_unlag_ms`: how far back a shot is judged, for a shooter's latency. See
## [member ArenaGame.max_unlag_ms]; 0 turns lag compensation off.
func _add_unlag_cvar() -> void:
	add_cvar("arena_max_unlag_ms", str(game.max_unlag_ms),
		"How far back lag compensation rewinds the other players for a shot, in ms (0 off)",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.max_unlag_ms = new_value.to_float()
			log_info("lag compensation limit changed", {"ms": game.max_unlag_ms}))


## `stats_report` (dot-game's family cvar): 1 files the players' stats with the backbone. Off by default; `arena_stats_report` is its alias.
func _add_stats_report_cvar() -> void:
	var _cv := DotGameStatsReport.bind(self,
		func(on: bool) -> DotResult:
			if game.progress == null:
				return DotResult.fail(DotError.CODE_STATE, "No progress yet.")
			return game.progress.set_reporting(on),
		PackedStringArray(["arena_stats_report"]))


## `arena_rank`: "weighted", "elo", or "weighted:arena.kills=1,arena.deaths=-0.5" (dot-stats' DotStatsRank.apply_cvar).
func _add_rank_cvar() -> void:
	add_cvar("arena_rank", "weighted",
		"Skill rank formula: weighted, elo, or weighted:<stat>=<weight>,...",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY).changed.connect(
		func(_old: String, new_value: String) -> void:
			if game.progress == null or not game.progress.rank.apply_cvar(new_value):
				log_info("arena_rank refused", {"value": new_value}))


## `sv_fire_buffer`: seconds a semi-auto press during the cooldown stays queued. See [member ArenaGame.fire_buffer_seconds].
func _add_fire_buffer_cvar() -> void:
	add_cvar("sv_fire_buffer", str(game.fire_buffer_seconds),
		"Seconds a semi-auto press during the cooldown stays queued; 0 drops it, -1 keeps it until the cooldown ends",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.fire_buffer_seconds = new_value.to_float()
			log_info("fire buffer changed", {"seconds": game.fire_buffer_seconds}))


## `bot_think_every`, `bot_think_near`: bot think-rate staggering (see [member ArenaBots.think_every]); `bot_native`: dot-sim's sight scan; `bot_native_brain`: dot-bot's native mind (off); `motor_native`: dot-sim's movement collision queries and collide-and-slide; `motor_native_tick`: a plain ground or air tick's start and end in dot-sim; `motor_native_full`: the whole tick there; `ragdoll_native`: dot-sim's ragdoll bone pose.
func _add_bot_think_cvars() -> void:
	add_cvar("bot_think_every", str(ArenaBots.think_every),
		"A bot far from every enemy runs its brain one tick in this many (1 = every tick, 0 = 2 above 16 players)",
		DotConVar.FLAG_ARCHIVE).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			ArenaBots.think_every = maxi(0, int(new_value.to_float())))
	add_cvar("bot_personas", ArenaBots.personas_mode,
		"Bot characters (cfg/game/game-arena/bot/*.yml): empty deals every persona by its weight, 'id:weight,...' only those, 'off' one shared bot_difficulty",
		DotConVar.FLAG_ARCHIVE).changed.connect(
		func(_old: String, new_value: String) -> void:
			ArenaBots.personas_mode = new_value.strip_edges())
	add_cvar("sv_bot_loadouts", ArenaBotLoadouts.mode,
		"Kits bots draw at each spawn (cfg/game/game-arena/bot_loadout/*.yml): 'all' every enabled one by its weight, 'id[:weight],...' only those",
		DotConVar.FLAG_ARCHIVE).changed.connect(
		func(_old: String, new_value: String) -> void:
			ArenaBotLoadouts.mode = new_value.strip_edges())
	add_cvar("bot_think_near", str(ArenaBots.think_near),
		"Metres: a bot with an enemy closer than this thinks every tick",
		DotConVar.FLAG_ARCHIVE).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			ArenaBots.think_near = maxf(0.0, new_value.to_float()))
	add_cvar("bot_sight_far", str(ArenaBots.sight_far),
		"Metres: a body farther than this that a bot did not see is not traced again for bot_sight_far_reuse seconds (never its target; 0: off)",
		DotConVar.FLAG_ARCHIVE).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			ArenaBots.sight_far = maxf(0.0, new_value.to_float()))
	add_cvar("bot_sight_far_reuse", str(ArenaBots.sight_far_reuse),
		"Seconds a far, unseen body stays unseen before a bot traces it again (see bot_sight_far)",
		DotConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			ArenaBots.sight_far_reuse = clampf(new_value.to_float(), 0.0, 1.0))
	_add_bot_tier_cvar("bot_tier_above", "tiers.above", "Players above which bot think-rate tiers apply (-1: never); see bot_tier_*", -1.0)
	_add_bot_tier_cvar("bot_tier_every_near", "tiers.near_every", "Ticks between thinks of a bot no person fights, sees or is near, within bot_tier_range of one", 1.0)
	_add_bot_tier_cvar("bot_tier_every_far", "tiers.far_every", "Ticks between thinks of such a bot beyond bot_tier_range of every person", 1.0)
	_add_bot_tier_cvar("bot_tier_range", "tiers.far_range", "Metres: the near/far line of bot_tier_every_near and bot_tier_every_far", 0.0)
	_add_bot_tier_cvar("bot_tier_close", "tiers.close_range", "Metres: a bot this close to a person thinks every tick whatever the person faces", 0.0)
	_add_bot_tier_cvar("bot_tier_nearest", "tiers.nearest", "This many bots nearest each person think every tick", 0.0)
	_add_bot_tier_cvar("bot_tier_every_engaged", "tiers.engaged_far_every", "Ticks between thinks of a bot fighting a person beyond bot_tier_engaged_range and out of view (1: every tick)", 1.0)
	_add_bot_tier_cvar("bot_tier_every_idle_seen", "tiers.idle_view_every", "Ticks between thinks of a bot with no target (or dead) inside a person's view cone but not close or nearest (1: every tick)", 1.0)
	_add_bot_tier_cvar("bot_tier_engaged_range", "tiers.engaged_range", "Metres: a bot fighting a person this close thinks every tick", 0.0)
	_add_bot_tier_cvar("bot_tier_view", "tiers.view_range", "Metres: a bot inside a person's view cone within this thinks every tick", 0.0)
	_add_bot_tier_cvar("bot_tier_body_every_near", "tiers.body_near_every", "Ticks between motor ticks of a coasting bot no person fights, sees or is near, within bot_tier_range (1: every tick); it moves in steps nobody sees", 1.0)
	_add_bot_tier_cvar("bot_tier_body_every_far", "tiers.body_far_every", "Ticks between motor ticks of such a bot beyond bot_tier_range of every person (1: every tick)", 1.0)
	_add_bot_tier_cvar("bot_tier_body_above", "tiers.body_above", "Players above which bot_tier_body_every_near/far apply (-1: never); the body tiers' own threshold on top of bot_tier_above", -1.0)
	add_cvar("bot_tier_floor", str(ArenaBots.think_floor),
		"Fewest ticks between thinks of a bot while the tiers apply, whatever its tier (1: every tick); it coasts between",
		DotConVar.FLAG_ARCHIVE).with_min(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			ArenaBots.think_floor = maxi(1, int(new_value.to_float())))
	add_cvar("bot_tier_floor_engaged", str(ArenaBots.think_floor_engaged),
		"bot_tier_floor for a bot fighting a person",
		DotConVar.FLAG_ARCHIVE).with_min(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			ArenaBots.think_floor_engaged = maxi(1, int(new_value.to_float())))
	add_cvar("bot_recoil_control", str(ArenaBots.recoil_control),
		"Share of the recoil bots pull their aim back against, 0..1; -1 (default) by difficulty: easy .3, medium .55, hard .75, nightmare .9",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY).with_min(-1.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			ArenaBots.recoil_control = clampf(new_value.to_float(), -1.0, 1.0))
	_add_bot_engine_cvars()


## The native/threaded switches of the bot and motor engines, and the hull grid.
func _add_bot_engine_cvars() -> void:
	add_cvar("bot_fast_sense", "1" if ArenaBotBrain.fast_sense else "0",
		"1: bots scan candidates by squared distance and cone cosine (same result, cheaper); 0: dot-bot's stock scan",
		DotConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			ArenaBotBrain.fast_sense = new_value.to_float() >= 0.5)
	add_cvar("bot_threads", str(ArenaBotThreads.threads),
		"Threads that run the bots' brains in parallel (the main thread is one); 0 thinks one bot after another on the main thread",
		DotConVar.FLAG_ARCHIVE).with_min(0.0).with_max(64.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			ArenaBotThreads.threads = maxi(0, int(new_value.to_float())))
	add_cvar("bot_native", "1" if DotBotWorld.native_enabled else "0",
		"1: the bots' sight scan runs in dot-sim when its library is installed (same result, cheaper); 0: in script. Without the library it is script either way",
		DotConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			DotBotWorld.native_enabled = new_value.to_float() >= 0.5)
	# Off by default (ArenaPlayerStack._static_init): a windowed 31-bot A/B on staging02 showed no
	# frame gain (nightly arena-perf-leftovers-1), and a native brain thinks only on the main thread.
	add_cvar("bot_native_brain", "0",
		"1: the bots' aim, fight step and perception run in dot-sim when its library has the bot mind (no frame gain measured, and those bots leave bot_threads); 0: in script. Takes effect for bots added after the change",
		DotConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			ArenaPlayerStack.set_brain_native(new_value.to_float() >= 0.5))
	add_cvar("motor_native", "1" if DotFpsPhysicsBody.native_enabled else "0",
		"1: the players' movement collision queries (sweep, rest contact, overlap) run in dot-sim when its library is installed (bit-identical to the script, so web and native clients still agree; cheaper); 0: in script. Without the library it is script either way",
		DotConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			DotFpsPhysicsBody.native_enabled = new_value.to_float() >= 0.5)
	# By name: a no-op against a dot-player-char older than the switch.
	add_cvar("ragdoll_native", "0" if (DotPlayerRagdoll as Script).get(&"native_pose") == false else "1",
		"1: a skinned ragdoll's bones follow its parts in dot-sim when its library is installed (the same bone poses as the script, to the bit; cheaper); 0: in script. Client-side looks only; without the library it is script either way",
		DotConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			(DotPlayerRagdoll as Script).set(&"native_pose", new_value.to_float() >= 0.5))
	# On by default (ArenaPlayerStack._static_init); the arena suites run it against the script's bits.
	add_cvar("motor_native_tick", "1",
		"1: a plain ground or air tick's start and end (ground check, friction, acceleration, gravity, collide-and-slide) run in dot-sim as one call each when its library has the motor tick (bit-identical to the script); 0: in script. Needs motor_native; without the library it is script either way",
		DotConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			DotFpsMotor.native_tick = new_value.to_float() >= 0.5)
	add_cvar("motor_native_full", "1" if DotFpsMotor.native_full else "0",
		"1: with motor_native_tick, the whole tick (jumps, slides, launches, dashes, wall runs and wall jumps too) runs in dot-sim as one call when its library has it (bit-identical to the script); 0: only the start and end",
		DotConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			DotFpsMotor.native_full = new_value.to_float() >= 0.5)
	add_cvar("arena_hull_grid", "1" if ArenaHullGrid.enabled else "0",
		"1: players' standing hulls are found through a grid filed once per tick (same hulls, cheaper above 12 players); 0: scan the whole roster per bot",
		DotConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			ArenaHullGrid.enabled = new_value.to_float() >= 0.5)
	add_cvar("arena_hull_fast", "1" if ArenaHullGrid.fast else "0",
		"1: the hull gather tests the grid's candidates in one hoisted loop (same hulls); 0: one call per candidate",
		DotConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			ArenaHullGrid.fast = new_value.to_float() >= 0.5)
	add_cvar("arena_hull_native", "1" if ArenaHullGrid.native else "0",
		"1: with arena_hull_fast, a mover that is not lag-compensated gathers its hulls in dot-sim (same hulls, no script call per player); 0: by script",
		DotConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			ArenaHullGrid.native = new_value.to_float() >= 0.5)
	add_cvar("arena_motor_batch", "1" if ArenaHullGrid.batch else "0",
		"1: with arena_hull_native, dot-sim ticks the players' motors in runs of one call a game tick (same states); 0: one call per player",
		DotConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			ArenaHullGrid.batch = new_value.to_float() >= 0.5)
	add_cvar("arena_tick_max_steps", str(ArenaTickBudget.max_steps),
		"Solo: the most ticks a frame may run to catch up with wall-clock time. 8 (default) keeps real time while ticks are cheap; 1 draws more frames while the simulation runs slower",
		DotConVar.FLAG_ARCHIVE).with_min(1.0).with_max(float(ArenaTickBudget.MAX_STEPS)).changed.connect(
		func(_old: String, new_value: String) -> void:
			ArenaTickBudget.max_steps = clampi(int(new_value.to_float()), 1, ArenaTickBudget.MAX_STEPS))


## `sv_grenade_*` (arena_weapons' [AwGrenadeRules]) and `sv_grenade_utility`: 0 keeps flash, smoke and incendiary out of
## the loadout menu (the default), 1 entitles everyone to them.
func _add_grenade_cvars() -> void:
	if not game.ArenaGrenades.supported():
		return
	var _made := game.grenades_rules.bind_cvars(add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY)
	add_cvar("sv_grenade_utility", "1" if game.utility_grenades else "0",
		"1 lets players pick flash, smoke and incendiary grenades in the loadout menu",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.utility_grenades = new_value.to_float() != 0.0
			log_info("utility grenades changed", {"on": game.utility_grenades}))


## `sv_maxrate`: bytes a second each client may be sent, 0 for no cap (the default).
##
## [b]0, because a cap here can only ever hurt[/b] (2026-10-15, `tools/net_probe.gd`): the
## stream to one client is ~6 kB/s steady and ~16 kB/s at a join with up to 31 bots, and a
## snapshot is already bounded by `max_entities_per_snapshot` and the mtu. What a cap does
## when it bites is hold a snapshot back, which a player reads as a ping spike. It is here
## for an operator on a metered uplink, and it is dot-net's `per_client_budget`, read live.
func _add_rate_cvar() -> void:
	_cv_maxrate = add_cvar("sv_maxrate", "0",
		"Bytes a second each client may be sent; 0 is no cap (a cap that bites delays snapshots)",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY).with_min(0.0)
	_cv_maxrate.changed.connect(
		func(_old: String, new_value: String) -> void:
			if net != null and net.config != null:
				net.config.per_client_budget = new_value.to_int()
			log_info("rate cap changed", {"bytes_per_sec": new_value.to_int()}))


## `arena_loadout_roll_text`: see [member ArenaGame.loadout_roll_text]. Off by default.
func _add_loadout_roll_text_cvar() -> void:
	add_cvar("arena_loadout_roll_text", "1" if game.loadout_roll_text else "0",
		"Print \"Random loadout: ...\" on screen when a random loadout is rolled at spawn (1), or roll silently (0, default)",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.loadout_roll_text = new_value.to_float() != 0.0)


## `arena_team_spawn_split`: see [member ArenaGame.team_spawn_split]. Read when a map loads.
func _add_team_spawn_split_cvar() -> void:
	add_cvar("arena_team_spawn_split", "1" if game.team_spawn_split else "0",
		"A team mode on a map with no team spawns splits its spawns into two halves, one per team (1), or both teams share one pool (0); read when a map loads",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.team_spawn_split = new_value.to_float() != 0.0
			log_info("team spawn split changed", {"on": game.team_spawn_split}))


## `sv_snapshot_rate`: snapshots a second to aim at, 0 for the derived default ([constant ArenaGame.NET_SNAPSHOT_RATE]).
## Independent of the tick rate: the rate sent is the nearest whole-tick divisor ([method ArenaGame.snapshot_rate_for]),
## HELLO carries it to each client, so it applies to the map being built and to clients that join after.
func _add_snapshot_rate_cvar() -> void:
	_cv_snapshot_rate = add_cvar("sv_snapshot_rate", "0",
		"Snapshots a second to aim at; 0 is the default (32). Applies when the game is built; clients learn it at join.",
		DotConVar.FLAG_ARCHIVE).with_range(0.0, 128.0)


## `sv_snapshot_workers`: [member DotNetConfig.snapshot_workers], live. The same bytes on the wire either way (dot-net builds each peer's snapshot from one frozen instant);
## net_probe, 31 bots + 31 fake peers on PH: send 4.31 -> 2.86 ms/tick with 4 (nightly fc-snapshot-workers-1). Launch `+sv_snapshot_workers N` or env ARENA_SNAPSHOT_WORKERS.
func _add_snapshot_workers_cvar() -> void:
	add_cvar("sv_snapshot_workers", str(net.config.snapshot_workers if net != null and net.config != null else 0),
		"Worker threads that build the per-peer snapshots; 0 builds them on the tick thread, -1 is the processor count less one. Same bytes either way",
		DotConVar.FLAG_ARCHIVE).with_range(-1.0, 64.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			if net != null and net.config != null:
				net.config.snapshot_workers = clampi(int(new_value.to_float()), -1, 64))


## The snapshot workers a server starts with: env ARENA_SNAPSHOT_WORKERS when set, else a quarter of the machine's threads, at most
## [constant SNAPSHOT_WORKERS_MAX], and 0 (inline) under 8 threads, where the bots' threads and the tick already want the cores.
static func default_snapshot_workers() -> int:
	var env := OS.get_environment("ARENA_SNAPSHOT_WORKERS")
	if env.is_valid_int():
		return clampi(env.to_int(), -1, 64)
	var n := mini(floori(OS.get_processor_count() / 4.0), SNAPSHOT_WORKERS_MAX)
	return n if n >= 2 else 0


## The arena's own limits on `sv_tickrate` (dot-server's range is wider; [constant ArenaGame.MIN_TICK_RATE] to
## [constant ArenaGame.MAX_TICK_RATE]), and `bot_think_hz`: the bots' think rate in Hertz, so 33 means a think every 2nd
## tick at 66 and every 4th at 128 (`bot_think_every` counts ticks; the last one set wins; 0 leaves it to `bot_think_every`).
func _add_tick_rate_cvars() -> void:
	var tickrate := console.find_cvar("sv_tickrate")
	if tickrate != null:
		var _ranged := tickrate.with_range(float(ArenaGame.MIN_TICK_RATE), float(ArenaGame.MAX_TICK_RATE))
	add_cvar("bot_think_hz", "0",
		"Bot brain runs this many times a second whatever the tick rate (a far bot's cadence for bot_think_every); 0 uses bot_think_every ticks",
		DotConVar.FLAG_ARCHIVE).with_range(0.0, 128.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			var hz := new_value.to_float()
			if hz > 0.0:
				ArenaBots.think_every = ArenaBots.every_for_hz(hz, game.tick_rate))


## The target `sv_snapshot_rate` names, or the game's default when it is 0 or unset.
func snapshot_target() -> int:
	var asked := _cv_snapshot_rate.get_int() if _cv_snapshot_rate != null else 0
	return asked if asked > 0 else ArenaGame.NET_SNAPSHOT_RATE


func _add_spawn_cvars() -> void:
	var stack: Object = game.get("player_stack")

	if stack == null:
		return

	for cvar in SPAWN_CVARS:
		var key: String = SPAWN_CVARS[cvar][0]
		add_cvar(cvar, str(stack.spawn_settings[key]), SPAWN_CVARS[cvar][1], DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY).changed.connect(
			func(_old: String, new_value: String) -> void:
				if key == "mode":
					if not stack.SPAWN_MODES.has(new_value):
						log_info("unknown spawn mode, kept the old one", {"asked": new_value, "modes": stack.SPAWN_MODES})
						return

					stack.spawn_settings[key] = new_value
				else:
					stack.spawn_settings[key] = maxf(new_value.to_float(), 0.0)

				stack.refresh_spawn_rules()
				log_info("spawn rule changed", {"rule": key, "value": new_value}))


## How the flags are shown, not how they are played: kept out of [constant CTF_CVARS], whose every key names a [DotObjectiveCtfRules] rule. Sent to clients with the flag state.
const CTF_VIEW_CVARS := {
	"arena_ctf_indicator": ["indicator", "A small team-coloured flag icon with its distance (\"19.4m\") over each flag (1, default) or none (0)"],
	"arena_ctf_indicator_seethrough": ["see_through", "The flag indicator shows through walls (1, default) or only in plain sight (0)"],
}


func _add_ctf_cvars() -> void:
	for cvar in CTF_VIEW_CVARS:
		var view_key: String = CTF_VIEW_CVARS[cvar][0]
		add_cvar(
			cvar, "1" if game.ctf_view[view_key] else "0", CTF_VIEW_CVARS[cvar][1], DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
		).with_min(0.0).changed.connect(
			func(_old: String, new_value: String) -> void:
				game.ctf_view[view_key] = new_value.to_float() != 0.0
				log_info("ctf view changed", {"rule": view_key, "value": new_value})
		)
	for cvar in CTF_CVARS:
		var key: String = CTF_CVARS[cvar][0]
		var value: Variant = game.ctf_rules[key]
		var text := ("1" if value else "0") if value is bool else str(value)
		add_cvar(
			cvar, text, CTF_CVARS[cvar][1], DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
		).with_min(0.0).changed.connect(
			func(_old: String, new_value: String) -> void:
				var was: Variant = game.ctf_rules[key]
				game.ctf_rules[key] = (
					new_value.to_float() != 0.0 if was is bool
					else (new_value.to_int() if was is int else new_value.to_float())
				)
				game.ctf_rules.team_count = clampi(game.ctf_rules.team_count, 2, 8)
				game.ctf_rules.carrier_speed = clampf(game.ctf_rules.carrier_speed, 0.1, 2.0)
				game.apply_match_limits()
				log_info("ctf rule changed", {"rule": key, "value": new_value})
		)


func _add_flag_carry_cvars() -> void:
	for cvar in FLAG_CARRY_CVARS:
		var key: String = FLAG_CARRY_CVARS[cvar][0]
		var value: Variant = ArenaFlagCarry.setting(key)
		var text := ("1" if value else "0") if value is bool else str(value)
		add_cvar(
			cvar, text, FLAG_CARRY_CVARS[cvar][1], DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
		).with_min(0.0).changed.connect(
			func(_old: String, new_value: String) -> void:
				ArenaFlagCarry.set_setting(key, new_value)
				log_info("flag carry rule changed", {"rule": key, "value": new_value})
		)


## The knife rules as cvars (`arena_knife_throw`, `_speed`, `_pickup`, `_damage`): dot-weapon's table.
func _add_knife_cvars() -> void:
	var _made := DotWeaponKnives.bind_cvars(
		game.knife_rules, add_cvar, "arena_knife", DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	)


func _add_drop_cvars() -> void:
	for cvar in DROP_CVARS:
		var key: String = DROP_CVARS[cvar][0]
		var value: Variant = game.drop_rules[key]
		var text := ("1" if value else "0") if value is bool else str(value)
		add_cvar(
			cvar, text, DROP_CVARS[cvar][1], DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
		).with_min(0.0).changed.connect(
			func(_old: String, new_value: String) -> void:
				var was: Variant = game.drop_rules[key]
				game.drop_rules[key] = (
					new_value.to_float() != 0.0 if was is bool
					else (new_value.to_int() if was is int else new_value.to_float())
				)
				game.apply_drop_rules()
				log_info("drop rule changed", {"rule": key, "value": new_value})
		)


func _add_jail_cvars() -> void:
	for cvar in JAIL_CVARS:
		var key: String = JAIL_CVARS[cvar][0]
		var value: Variant = game.jail_rules[key]
		add_cvar(
			cvar, ("1" if value else "0") if value is bool else str(value),
			JAIL_CVARS[cvar][1], DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
		).with_min(0.0).changed.connect(
			func(_old: String, new_value: String) -> void:
				game.jail_rules[key] = (
					new_value.to_float() != 0.0 if game.jail_rules[key] is bool else new_value.to_float()
				)
				game.apply_jail_rules()
				log_info("jail rule changed", {"rule": key, "value": new_value})
		)


func _add_critical_cvar(cvar: String, help: String) -> void:
	var rules: DotDamageRules = game.combat.resolver.rules if game.combat != null else null
	if rules == null:
		return

	var scale := cvar == "arena_crit_scale"
	add_cvar(
		cvar, str(rules.critical_scale if scale else rules.critical_chance), help,
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			if scale:
				rules.critical_scale = maxf(new_value.to_float(), 0.0)
			else:
				rules.critical_chance = clampf(new_value.to_float(), 0.0, 1.0)
			log_info("critical rule changed", {"cvar": cvar, "value": new_value})
	)


## `sv_net_*`: relevance rings, on only above `sv_net_aoi_players` players (default 32, so a 16v16 is untouched).
func _add_aoi_cvars() -> void:
	net_aoi = ArenaNetAoi.new()
	net_aoi.bind_cvars(add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY)


## Once a second from the module: turns the rings on or off for the current player count.
func _refresh_aoi() -> void:
	if net_aoi != null and net != null and game != null and net.interest != null:
		if net_aoi.refresh(net.interest, game.players().size()):
			log_info("net relevance rings", {"on": net_aoi.active, "players": game.players().size()})


## A `bot_tier_*` cvar onto a field of [member ArenaBots.tiers] ([param field] is `tiers.<name>`).
func _add_bot_tier_cvar(cvar: String, field: String, help: String, min_value: float) -> void:
	var tiers := ArenaBots.tiers
	var name := StringName(field.trim_prefix("tiers."))
	add_cvar(cvar, str(tiers.get(name)), help, DotConVar.FLAG_ARCHIVE).with_min(min_value).changed.connect(
		func(_old: String, new_value: String) -> void:
			tiers.set(name, int(new_value.to_float()) if typeof(tiers.get(name)) == TYPE_INT else new_value.to_float()))
