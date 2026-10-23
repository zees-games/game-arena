@tool
class_name ArenaBoardsConfig
extends DotConfig

## Where this server's leaderboards live. Layered like every [DotConfig]: defaults, JSON
## file, environment (`ARENA_BOARDS_BACKEND`), command line (`--arena_boards_backend`).

## "memory" keeps boards in this process; "backbone" keeps them on the site (needs a registered backbone client).
@export_enum("memory", "backbone") var backend: String = "memory"


func env_prefix() -> String:
	return "ARENA_BOARDS_"


func cli_prefix() -> String:
	return "--arena_boards_"


func validate() -> DotResult:
	if backend != "memory" and backend != "backbone":
		return DotResult.fail(DotError.CODE_INVALID, "backend must be memory or backbone")
	return DotResult.success(null)
