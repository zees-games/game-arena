extends DotModule

const ArenaGame := preload("arena_game.gd")
const ArenaPlayer := preload("arena_player.gd")

## Base of [ArenaModule]: the operator-facing cvars that map onto a rule table, so the module itself
## holds the lifecycle. Split out for the size gate; the state they read lives here too.
var game: ArenaGame = null
## The netcode. Owned here rather than by the game, because a headless match and a
## dedicated server are different deployments of the same game and only one replicates.
var net: DotNetManager = null
var _cv_maxrate: DotConVar = null
## The team menu server and its team layout cvars (arena_team_menu.gd).
var team_menu: RefCounted = null


## cvar -> the movement tunable it sets, with what it means. Each defaults to what
## `ArenaPlayer.arena_tunables()` already says, so a server that sets none of them plays
## exactly as before; a change reaches every player now and later and, through RULES,
## every client, so a client never predicts a slide the server does not make.
const MOVEMENT_CVARS := {
	"arena_speed_scale": ["speed_scale", "Multiplier on every ground speed, 1 as set (a server-wide slowdown or speed-up)"],
	"arena_run_speed": ["max_speed", "Running speed, m/s"],
	"arena_walk_scale": ["walk_speed_scale", "Walk speed as a fraction of run"],
	"arena_sprint_scale": ["sprint_speed_scale", "Sprint speed as a fraction of run"],
	"arena_crouch_scale": ["crouch_speed_scale", "Crouch speed as a fraction of run"],
	"arena_slide": ["slide_enabled", "Crouch at a run slides (1) or only crouches (0)"],
	"arena_slide_boost": ["slide_boost", "Speed a slide adds when it starts, m/s (0 for none)"],
	"arena_slide_min_speed": ["slide_min_speed", "Speed needed to slide, m/s"],
	"arena_slide_duration": ["slide_duration", "Longest a slide lasts, seconds"],
	"arena_slide_friction": ["slide_friction", "Friction while sliding (lower carries further)"],
	"arena_slide_cooldown": ["slide_cooldown", "Seconds between slides"],
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
	"arena_surf": ["surf", "A combat surf map plays with the genre's air control (1) or the arena's own (0)"],
	"arena_surf_airaccelerate": ["surf_air_accelerate", "Air acceleration on a combat surf map (the genre's sv_airaccelerate)"],
	"mp_killcam_time": ["killcam", "Seconds the final killcam plays at a match's end, added to the end's wait (0 for none)"],
	"arena_crit_scale": ["", "Extra damage multiplier on a critical hit (1 for none)"],
	"arena_crit_chance": ["", "Chance any hit is a critical, 0 to 1 (headshots always are)"],
}


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
const SPAWN_CVARS := {
	"arena_spawn_mode": ["mode", "How a respawn picks its site: avoid, weighted, furthest or random"],
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


## `sv_fire_buffer`: seconds a semi-auto press during the cooldown stays queued. See [member ArenaGame.fire_buffer_seconds].
func _add_fire_buffer_cvar() -> void:
	add_cvar("sv_fire_buffer", str(game.fire_buffer_seconds),
		"Seconds a semi-auto press during the cooldown stays queued; 0 drops it, -1 keeps it until the cooldown ends",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.fire_buffer_seconds = new_value.to_float()
			log_info("fire buffer changed", {"seconds": game.fire_buffer_seconds}))


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
