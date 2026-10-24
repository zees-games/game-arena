class_name ArenaConfig
extends DotConfig

## Arena's server tunables for [DotGameConfigBinder]: `arena_<field>` cvars, a `config` profile at
## `cfg/server/game/game-arena/config/game.yml`, `ARENA_*` env and `--arena-*` argv.

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
