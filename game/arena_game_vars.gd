@tool
extends "arena_game_state.gd"

const ArenaFlashlight := preload("arena_flashlight.gd")
const ArenaFrameProbe := preload("arena_frame_probe.gd")
const ArenaHullGrid := preload("arena_hull_grid.gd")
const ArenaShotStats := preload("arena_shot_stats.gd")
const HULL_NEAR_SQ := 144.0

## Beyond this a hull cannot touch one tick's sweep (top speed times a tick, plus both radii, with room to spare).
const HULL_REACH_SQ := 16.0

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

## Shots fired against damage applied, per shooter (bots and players): the counter behind `arena_shot_stats`.
var shot_stats := ArenaShotStats.new()

## Ammo profiles (`cfg/game/game-arena/ammo`): what each gun's round can penetrate, read by the hitscan behaviour.
var ammo_types: DotWeaponAmmoTypes = _load_ammo_types()

const LOADOUT_COMMAND_SCRIPT := "res://addons/dot_loadout/integrations/dot_loadout_command.gd"

## A client behind a loading cover sets this and calls [method build_map_io_async], so the movers are not one long frame.
var defer_map_io := false

## Server bot session ids start here; stats and progress never count them.
const BOT_SESSION_BASE := 900_000_000

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
## `nametags` and `hpbars` are the server's ceilings on when those tags draw (`mp_nametags`, `mp_hpbars`;
## masks of `arena_name_tag_rules.gd`, 1 = no limit).
##
## `fp_arms` is the arm set every first-person view draws (`arena_fp_arms`): 0 each player's own look, N one stock set.
##
## `killcam` is the final killcam's seconds (`mp_killcam_time`, 0 off): clients play it, and the
## authority adds it to the match's end ([method _override_rules]).
const SHOW_RULES: PackedStringArray = ["break_mode", "break_limbs", "break_criticals_only", "fp_body", "mode_index", "surf", "surf_air_accelerate", "killcam", "max_unlag_ms", "fire_buffer", "nametags", "hpbars", "fp_arms"]
const SHOW_DEFAULTS := {"break_mode": 1.0, "break_limbs": 1.0, "break_criticals_only": 1.0, "fp_body": 0.0, "surf": 1.0, "surf_air_accelerate": 150.0, "killcam": 7.0, "nametags": 1.0, "hpbars": 1.0, "fp_arms": 0.0}

## The mode a client is told is being played, for its banner and its keys. A client's own
## [member mode] is whatever it was built with and is never replaced — logic reads it —
## so what it shows comes from here. On the authority it is the mode.
var shown_mode: ArenaMode = null

var _roster: Array[ArenaPlayer] = []
var _roster_ids := PackedInt64Array()
var _roster_dirty := true
## Roster index by player id, rebuilt with [member _roster].
var _roster_at: Dictionary = {}
## [method _add_hulls_local]'s pair answers this tick, row-major by roster index: 0 unasked, 1 blocks, 2 passes.
var _pair_memo := PackedByteArray()
var _pair_memo_tick: int = -1
var _pair_memo_fn: Callable = Callable()
## Where the players stand, for [method solid_hulls_for] while the players' loop runs ([ArenaHullGrid]).
var _hull_grid := ArenaHullGrid.new()
## dot-sim's `DotSimHullWorld` for the players' loop ([method _begin_hull_world]), and its per-slot data.
var _hull_world: Object = null
var _hull_world_data := PackedFloat64Array()
## The players' motors ticked in runs of one native call ([method _tick_players_batched]), and each roster slot's row and commands.
var _motor_batch: DotFpsMotorBatch = null
var _batch_rows := PackedInt32Array()
var _batch_pairs: Array = []


## Rebuilds [member _roster] (the players in join order, and their ids) after a join or a leave.
func _ensure_roster() -> void:
	if not _roster_dirty:
		return
	_roster.clear()
	_roster_ids.resize(0)
	_roster_at.clear()
	for key: Variant in _players.keys():
		_roster_at[int(key)] = _roster.size()
		_roster.append(_players[key])
		_roster_ids.append(int(key))
	_roster_dirty = false
	_pair_memo_tick = -1
	_hull_grid.live = false
## The sorted ids of [member _players], rebuilt when somebody joins or leaves ([method player_ids]); empty means stale.
var _ids_cache: Array[int] = []

# --- Toys --------------------------------------------------------------------

## A toy's blast at its centre, m/s to a toy of up to 3 kg (dot-props' `blast`).
const TOY_BLAST_SPEED := 12.0

## The sprint rules start from this game's own tunables, so loading them (for `sv_sprint_shoot` and `sv_sprint_barrel`) leaves the speeds as they were.
static func _make_combat_feel() -> DotGameCombatFeel:
	var feel := DotGameCombatFeel.new(true, true)
	feel.sprint_defaults(ArenaPlayer.arena_tunables())
	return feel

static func _load_ammo_types() -> DotWeaponAmmoTypes:
	var types := DotWeaponAmmoTypes.new()
	var _n := types.load_set(DotWeaponAmmoTypes.make_set("", "game-arena"))
	return types

# --- Players ---------------------------------------------------------------

static func make_fall_rules() -> DotFallDamageRules:
	var rules := DotFallDamageRules.new()
	rules.enabled = true
	# Wall-runs and ramps make drops routine here: a higher threshold, a cap, and no lethal speed.
	rules.threshold = 16.0
	rules.scale = 3.0
	rules.max_damage = 50.0
	return rules

static func _make_killview_rules() -> DotKillViewRules:
	var rules := DotKillViewRules.new()
	rules.enabled = true
	return rules
