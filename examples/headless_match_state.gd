extends DotGameCheckSuite

const ArenaAwards := preload("../game/arena_awards.gd")
const ArenaBoards := preload("../game/arena_boards.gd")
const ArenaContent := preload("../game/arena_content.gd")
const ArenaEffects := preload("../game/arena_effects.gd")
const ArenaEvents := preload("../game/arena_events.gd")
const ArenaFlashlight := preload("../game/arena_flashlight.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaHorde := preload("../game/arena_horde.gd")
const ArenaHud := preload("../game/arena_hud.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMapDirector := preload("../game/arena_map_director.gd")
const ArenaWeaponRoles := preload("../game/arena_weapon_roles.gd")
const ArenaMapLighting := preload("../maps/arena_map_lighting.gd")
const ArenaMapPaint := preload("../maps/arena_map_paint.gd")
const ArenaMaps := preload("../game/arena_maps.gd")
const ArenaMapSurvey := preload("../maps/arena_map_survey.gd")
const ArenaHudGlance := preload("../game/arena_hud_glance.gd")
const ArenaMenus := preload("../game/arena_menus.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaModes := preload("../game/arena_modes.gd")
const ArenaModule := preload("../game/arena_module.gd")
const ArenaNpcs := preload("../game/arena_npcs.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaProjectiles := preload("../game/arena_projectiles.gd")
const ArenaProps := preload("../game/arena_props.gd")
const ArenaStats := preload("../game/arena_stats.gd")
const ArenaVote := preload("../game/arena_vote.gd")
const WallRouteDriver := preload("wall_route_driver.gd")
const ArenaWeaponIcons := preload("res://game/arena_weapon_icons.gd")

## A whole deathmatch played out headlessly with nothing called by hand; exits non-zero on failure.

const TICK_RATE := 64
const BOTS := 4
var _stats_errors: PackedStringArray = []

const SCORE_LIMIT := 6

## Enough ticks for six kills at arena pace. Bounded rather than "until it ends", so a
## match that never ends fails the test instead of hanging the run.
const MAX_TICKS := 64 * 90

const CHECKS := 687

## Sections entered against sections that ran to their last line. A runtime error aborts a section silently, and a section that
## bailed out after a failed guard counts as unfinished on purpose. The CHECKS total is the other half (docs/testing.md).
const SECTIONS := 44

var _entered := 0
var _completed := 0

var _game: ArenaGame = null

## Observations gathered while the match runs. Arrays rather than counters: a lambda captures locals by value, so an int
## incremented in a signal handler stays zero outside it and the assertion blames a signal that fired.
var _kills: Array[DotKillFeed.Entry] = []

## The map vote riding along on the real match: what state the match was in, and what the
## leader had, each time a ballot opened. See [method _build_vote].
var _vote: ArenaVote = null
var _vote_seen: Array = []
var _spawns: Array[int] = []
var _states: Array[String] = []

var _toy_views: Array = []

var _lowest_y := INF
var _furthest := 0.0
var _grounded_ticks := 0
