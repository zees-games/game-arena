extends DotConfig

## Arena's server tunables for [DotGameConfigBinder]: `arena_<field>` cvars, a `config` profile at
## `cfg/server/game/game-arena/config/game.yml`, `ARENA_*` env and `--arena-*` argv.

## `@export_group` -> the cfg file it lives in: `cfg/game/game-arena/config_<file>/game.yml`.
const CFG_FILES := {
	"Horde": "horde", "Players": "players", "Stomp": "players", "Match": "match", "Bots": "match", "Awards": "awards", "Surf": "surf",
}


## The binder every entry point uses: [param config] layered, one cfg file per [constant CFG_FILES] entry.
static func make_binder(config: DotConfig, json_path := "") -> DotGameConfigBinder:
	var b := DotGameConfigBinder.create(config, "game-arena", "arena", json_path)
	b.grouped = true
	b.group_files = CFG_FILES
	return b


func env_prefix() -> String:
	return "ARENA_"


func cli_prefix() -> String:
	return "--arena-"


@export_group("Horde")
## Horde monsters per player at the most intense moment.
@export_range(0.0, 40.0, 0.5) var horde_peak_per_player: float = 8.0

## Horde monsters per player while the pressure builds.
@export_range(0.0, 40.0, 0.5) var horde_build_up_per_player: float = 3.5

## Horde monsters per player in a lull.
@export_range(0.0, 40.0, 0.5) var horde_relax_per_player: float = 1.0

## Most horde monsters alive at once, whatever the player count.
@export_range(1, 200, 1) var horde_cap: int = 36

## Nearest metres from a player the horde spawns a monster.
@export_range(1.0, 100.0, 1.0) var horde_spawn_min_distance: float = 12.0

## Farthest metres from a player the horde spawns a monster.
@export_range(2.0, 200.0, 1.0) var horde_spawn_max_distance: float = 34.0

## Monsters spawned per burst.
@export_range(1, 20, 1) var horde_spawn_burst: int = 3

## Seconds between spawn bursts.
@export_range(0.1, 30.0, 0.1) var horde_spawn_interval: float = 0.6


func validate() -> DotResult:
	if horde_spawn_max_distance <= horde_spawn_min_distance:
		return DotResult.fail(DotError.CODE_INVALID, "horde_spawn_max_distance must exceed horde_spawn_min_distance")
	return DotResult.success(null)


@export_group("Players")
## Health a player spawns with and heals up to.
@export_range(1.0, 1000.0, 1.0) var player_health: float = 100.0

## Armour a player can carry.
@export_range(0.0, 1000.0, 1.0) var player_armour: float = 100.0

## Health regained per second; 0 keeps health a pickup.
@export_range(0.0, 100.0, 0.5) var player_regen: float = 0.0

## How far under an imported map's bounds a player is counted as out of it, metres.
@export_range(1.0, 200.0, 1.0) var fall_out_depth: float = 10.0

@export_group("Stomp")
## Landing on a player's head hurts them.
@export var stomp_enabled: bool = true

## Health a stomp takes; 0 kills outright.
@export_range(0.0, 1000.0, 1.0) var stomp_damage: float = 0.0

## Downward speed in m/s needed for a stomp.
@export_range(0.0, 100.0, 0.5) var stomp_min_speed: float = 4.0

## Metres the feet may be above or below the top of the head.
@export_range(0.0, 2.0, 0.05) var stomp_head_tolerance: float = 0.35

## Whether teammates can be stomped (ignores friendly fire).
@export var stomp_same_team: bool = false

## Upward speed in m/s the stomper bounces with.
@export_range(0.0, 50.0, 0.5) var stomp_bounce: float = 8.0

## Seconds before the same player can stomp again.
@export_range(0.0, 30.0, 0.1) var stomp_cooldown_sec: float = 0.5

## Sound id played on a stomp (a dot-audio id).
@export var stomp_sound: String = "stomp"

## Effect id spawned on a stomp (a dot-fx id).
@export var stomp_effect: String = "stomp_puff"

@export_group("Match")
## Seconds before a dead player respawns; -1 keeps each mode's own.
@export_range(-1.0, 60.0, 0.5) var respawn_delay_sec: float = -1.0

## Seconds of protection after a spawn; -1 keeps each mode's own.
@export_range(-1.0, 60.0, 0.5) var spawn_protection_sec: float = -1.0

## Friendly fire: -1 keeps each mode's own, 0 off, 1 on.
@export_range(-1, 1, 1) var friendly_fire: int = -1

@export_group("Awards")
## Points a kill is worth before its medals.
@export_range(0, 1000, 1) var award_kill_points: int = 100

## Kills by one player this close together (seconds) chain into a double, a triple, a multi kill.
@export_range(0.5, 30.0, 0.5) var award_multi_window_sec: float = 4.0

## Ending a streak at least this long is a shutdown.
@export_range(2, 50, 1) var award_shutdown_at: int = 5

## Kills closer than this (metres) are point blank.
@export_range(0.5, 50.0, 0.5) var award_point_blank_m: float = 3.0

## Kills from at least this far (metres) are long shots.
@export_range(5.0, 500.0, 1.0) var award_long_shot_m: float = 30.0

## Kills of one victim without being killed back that make you their nemesis.
@export_range(2, 20, 1) var award_nemesis_at: int = 3

@export_group("Bots")
## Players a server fills to with bots when nothing else sets bot_quota.
@export_range(0, 32, 1) var bot_quota: int = 4

@export_group("Surf")
## Whether surfing plays a quiet glide.
@export var surf_sounds: bool = true

## Surf glide level: 0 off, 1 stock level.
@export_range(0.0, 2.0, 0.05) var surf_volume: float = 0.6

## Speed in m/s under which the surf glide is silent.
@export_range(0.0, 60.0, 0.5) var surf_quiet_speed: float = 4.0

## Speed in m/s at which the surf glide is loudest and highest.
@export_range(1.0, 200.0, 0.5) var surf_full_speed: float = 22.0

## Surf glide pitch at the quiet speed.
@export_range(0.25, 2.0, 0.01) var surf_pitch_low: float = 0.75

## Surf glide pitch at the full speed.
@export_range(0.25, 3.0, 0.01) var surf_pitch_high: float = 1.35

## Whether footsteps and landings stop while surfing.
@export var surf_mute_steps: bool = true


## The surf fields as [method DotAudioSurfRules.apply_values] takes them.
func surf_values() -> Dictionary:
	return {
		"sounds": surf_sounds, "volume": surf_volume, "quiet_speed": surf_quiet_speed,
		"full_speed": surf_full_speed, "pitch_low": surf_pitch_low, "pitch_high": surf_pitch_high,
		"mute_steps": surf_mute_steps,
	}
