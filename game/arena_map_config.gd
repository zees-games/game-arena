extends RefCounted

## Arena's per-map settings: dot-map's [DotMapConfig] over the cvars a map may change.
##
## `cfg/game/game-arena/dot_map/map/<name>.yml` (a glob such as `surf_*.yml` covers a class of maps), overridable from `cfg/server/...`. Only the keys in [constant KEYS] are accepted; anything else a file says is logged and ignored.

const GAME_ID := "game-arena"

## cvar -> its constraint. Add a cvar here to let a map or an operator's per-map file set it.
const KEYS := {
	"arena_surf": {"type": "int", "min": 0, "max": 1},
	"arena_surf_airaccelerate": {"type": "float", "min": 0.0},
}


## The resolver and applier over [param console]'s cvars. Call `apply(map_id)` on every map load.
static func build(console: DotConsole) -> DotMapConfig:
	var cfg := DotMapConfig.new()
	cfg.game = GAME_ID
	for key: String in KEYS:
		cfg.allow(key, KEYS[key])
	cfg.get_fn = func(key: String) -> Variant:
		var cv := console.find_cvar(key)
		return cv.get_string() if cv != null else null
	cfg.set_fn = func(key: String, value: Variant) -> bool:
		return console.set_cvar(key, str(value)).ok
	return cfg
