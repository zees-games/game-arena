extends RefCounted

## Arena's per-map settings: dot-game's [DotGameMapConfig] (dot-map's files) over the cvars a map may change.
##
## `cfg/game/game-arena/dot_map/map/<name>.yml` (a glob such as `surf_*.yml` covers a class of maps), overridable from `cfg/server/...`. Only the keys in [constant KEYS] are accepted; anything else a file says is logged and ignored.

const GAME_ID := "game-arena"

## cvar -> its constraint. Add a cvar here to let a map or an operator's per-map file set it.
const KEYS := {
	"arena_surf": {"type": "int", "min": 0, "max": 1},
	"arena_surf_airaccelerate": {"type": "float", "min": 0.0},
}


## The applier over [param console]'s cvars (dot-game's [DotGameMapConfig]). Call `apply(map_id)` on every map load.
static func build(console: DotConsole) -> DotGameMapConfig:
	return DotGameMapConfig.for_console(GAME_ID, console, KEYS)
