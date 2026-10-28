@tool
extends Node

## State and signals of [ArenaGame], split out so the game file holds its behaviour.

const ArenaAmbience := preload("arena_ambience.gd")
const ArenaConfig := preload("arena_config.gd")
const ArenaContent := preload("arena_content.gd")
const ArenaEffects := preload("arena_effects.gd")
const ArenaHorde := preload("arena_horde.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaPaths := preload("arena_paths.gd")
const ArenaSolidBody := preload("arena_solid_body.gd")
const ArenaMode := preload("arena_mode.gd")
const ArenaModes := preload("arena_modes.gd")
const ArenaObjectives := preload("arena_objectives.gd")
const ArenaPlayer := preload("arena_player.gd")
const ArenaPlayerStack := preload("arena_player_stack.gd")
const ArenaProgress := preload("arena_progress.gd")
const ArenaProjectiles := preload("arena_projectiles.gd")
const ArenaDrops := preload("arena_drops.gd")
const ArenaJailView := preload("arena_jail_view.gd")
const ArenaProps := preload("arena_props.gd")
const ArenaSpectate := preload("arena_spectate.gd")
const ArenaAwards := preload("arena_awards.gd")


const CHANNEL := "arena"
const SERVICE := &"arena_game"

## How far from the origin the netcode quantises positions over, in metres.
##
## [b]Both ends must use the same number, and there is therefore exactly one.[/b] A
## quantised position is an integer over this range, so a server encoding against 128
## and a client decoding against 256 do not produce a rounding error — they produce a
## DIFFERENT POSITION, for every entity, on every snapshot. The symptom is a client
## that connects, adopts its player alive with full health, and then finds itself
## somewhere the world is not: sky in every direction, a HUD reading zero, and not one
## error anywhere.
##
## That is what happened here the first time the two were written separately, in two
## files, a hundred lines apart. This constant exists so there is nothing to keep in
## step.
##
## 512, since the imported combat surf maps: they reach 312 m from the origin
## (`surf_110b_austinpowers`), and a position past the extent is CLAMPED rather than
## wrapped, so at the old 128 every player on the far half of one was pinned to a wall of
## the quantiser in every snapshot — alive on the server, stuck on every client. Two more
## bits a position axis at 1 cm, for every map.
const NET_WORLD_EXTENT := 512.0

## Snapshots a second aimed at; the rate sent is [method snapshot_rate_for] the tick rate.
const NET_SNAPSHOT_RATE := 32


## A player was killed. After the scoreboard and the feed have seen it.
signal player_killed(entry: DotKillFeed.Entry)

## A player was put back into the world.
signal player_spawned(player: ArenaPlayer)

## A player exists. Fired by [method add_player], on every machine that has one.
##
## [b]Distinct from [signal player_spawned], and a client needs this one.[/b]
## `player_spawned` fires from `_on_respawn_due`, which is dot-match's, which runs on
## the AUTHORITY — so on a mirroring client it never fires at all. A client that waited
## for it to find its own player waited for ever: the HUD still bound by id and worked,
## the scoreboard worked, and there was no camera and no world, because both hang off
## the local player.
##
## That is this family's commonest shape with the ends swapped — a value consumed by a
## client and produced by nobody on the client's path — and it is the same bug
## game-g2gfast shipped, one signal over.
signal player_added(player: ArenaPlayer)

signal match_state_changed(from: DotMatch.State, to: DotMatch.State)

## A combat entity that is NOT a player was killed.
##
## [b]This exists because the scoreboard used to get a row for one.[/b] dot-combat
## knows only entity ids; anything a game layer registers with it — a monster, a
## breakable, a turret — arrives at `_on_entity_killed` looking exactly like a player.
## The old handler passed the id to `DotMatch.report_kill` regardless, which creates a
## scoreboard record keyed on a number no player has ever had, and it would have shown
## up as a phantom name at the bottom of the board with a death against it.
##
## [ArenaHorde] is the listener. A game with no monsters connects nothing and nothing
## is emitted.
signal non_player_killed(entity_id: int, damage: DotDamage)

## The world was replaced. After everything is rebuilt and every player is back in it.
##
## A client hangs its renderer off this: the meshes it was drawing belonged to the old
## map and the nodes they came from are gone by the time this fires.
signal map_changed(map: ArenaMap)

## The server owner changed how the arena moves (`arena_slide*`, `arena_launch*`). The
## bridge sends it to every client; see [member movement_rules].
signal movement_rules_changed(rules: Dictionary)

## The jail's gate was pressed, or its rules changed (the authority's; a client applying the
## server's state does not emit it). The bridge sends it to every client.
signal jail_changed

## A client learned which mode is being played. Client side; the HUD shows its banner.
signal mode_shown(shown: ArenaMode)

@export_group("Simulation")

@export_range(1, 240, 1) var tick_rate: int = 64

@export_group("Rules")

## Kills to win. Zero uses the ruleset's own. Gun game ignores it: its limit is its list.
##
## [b]These four are the server's say over the mode's numbers[/b], and they are read in two
## places: [method _build_match], for every match this game builds (each map change builds
## one), and [method apply_match_limits], for the match being played. The module's
## `arena_scorelimit`, `arena_timelimit`, `arena_warmup` and `arena_minplayers` cvars write
## them through the latter. Writing only the live match lost the value at the next map
## change; writing only these exports changed nothing until then, and `arena_scorelimit` did
## neither for as long as it existed.
@export_range(0, 200, 1) var score_limit: int = 25

## The match's length in seconds. Zero uses the ruleset's own.
@export_range(0.0, 3600.0, 30.0) var time_limit_sec: float = 600.0

## Warmup in seconds. Negative uses the ruleset's own; zero is no warmup.
@export_range(-1.0, 600.0, 1.0) var warmup_sec: float = -1.0

## Seconds everyone stands frozen at their spawn before a round goes live (`mp_freezetime`).
## Negative uses the ruleset's own; zero is no freeze.
@export_range(-1.0, 60.0, 0.5) var freeze_sec: float = -1.0

## Players needed before a round starts. Zero uses the ruleset's own.
@export_range(0, 64, 1) var min_players: int = 0

@export_group("Mode")

## What is being played. Null means [member mode_id] decides.
##
## [b]Assign before [method setup].[/b] It builds the match rules, the teams and the
## damage rules, and none of them is re-read afterwards.
@export var mode: ArenaMode = null

## Which mode to use when [member mode] is null. See [ArenaModes].
@export var mode_id: StringName = &"ffa"

## Whether this instance decides who dies.
##
## A client runs the same [ArenaGame] with this off: it simulates, it traces for
## effects, and it applies nothing.
@export var is_authority: bool = true

## Analytic geometry, or Godot physics. See [enum ArenaPlayer.Mode].
@export var headless: bool = true

@export_group("Progression")

## Count statistics, award achievements and keep leaderboards.
##
## [b]Authority only, and the guard is not a saving.[/b] A mirroring client runs the
## same [ArenaGame], sees the same kills replicated to it, and counting them there
## would credit every player on the server a second time in a place the server never
## reads — and, worse, would let a modified client award itself achievements. The
## numbers belong to whoever decides who died.
@export var track_progress: bool = true

@export_group("Service")

@export var register_service: bool = true

@export var service_scope: StringName = &""

var map: ArenaMap = null
var match_node: DotMatch = null
## Every world object this game has a combat entity id for. See [DotEntityTable].
##
## [b]Monsters only, today.[/b] A player's entity id in this game IS their dot-server
## session id, and seven things depend on that identity — dot-match's scoreboard keys,
## dot-effects' per-entity scales, dot-stats rows, dot-spectate, the player-stack
## roster, the kill feed on the wire, and the client that rebuilds one from two ints.
## [ArenaHorde] carries the full reasoning and what converting the other half would
## take; the short version is that dot-effects is keyed from both spaces at once, so
## the two halves cannot move separately.
##
## What the table already buys is the half that was wrong: monster ids used to be
## derived from engine instance ids and could collide with each other in silence.
var entities := DotEntityTable.new()

var combat: DotCombatManager = null

## Whether a player's client is still behind its loading cover: `func(player_id: int) -> bool`.
## The server module fills it from its [DotGameRoster]; unset (offline, a suite, a bot) nobody
## is loading. See [method can_be_harmed].
var loading_fn: Callable = Callable()
var loadouts: DotLoadoutManager = null

## The loadout menu's server half (dot-loadout's `DotLoadoutCommand`): the `/loadout` command
## the B menu sends, its `loadout_menu` notice, and the owner's `mp_loadout_*` cvars, which the
## module binds. Solo the client asks it directly. Untyped and loaded by path because a host with
## a dot-loadout older than API 2 has no such class, and this script must still parse there
## (`requires.floor.json`); null on such a host, and the B menu is then not offered.
var loadout_command: Object = null

## Rockets in flight. Built alongside the combat manager, because it traces against
## the same world and resolves through the same rules.
var projectiles: ArenaProjectiles = null

## What a critical kill drops: coins and a health pack. Rebuilt with the combat layer on a
## map change, like the projectiles; its rules live here in [member drop_rules] so a map
## change keeps what the server owner set.
var drops: ArenaDrops = null

## Kills since each player last died. Authority side; a client counts its own from KILL.
var streaks: Dictionary = {}

## Streak -> what reaching it gives: `heal` (full health), `armour`, `haste`,
## `empowered` (more damage, a while). Set by `arena_streak_rewards` as "3:heal,5:haste";
## empty gives nothing. Applied on the kill that reaches the streak, server side.
var streak_rewards: Dictionary = {3: "heal", 5: "haste", 7: "empowered"}

## Somebody reached a streak with a reward. Server side; the module announces it.
signal streak_reward(player_id: int, streak: int, reward: String)

## A player's damage landed on something: a player or a monster. Authority side, once per
## damage event (a shotgun's pellets are several); the bridge sums a tick's into one HIT
## for the attacker, and an offline client draws it straight from here. [param point] is
## where it landed, [param amount] what it took off health and armour together.
##
## [b]The hit marker is drawn from this and nothing else.[/b] A client that flashed on
## its own predicted shot drew hits the server then refused (a lag-compensated miss, a
## protected spawn); the marker would say "hit" about a shot that did nothing.
signal hit_confirmed(attacker: int, victim: int, amount: float, point: Vector3, headshot: bool, lethal: bool)

## What one kill earned: its medals ([enum ArenaAwards.Medal]), its points, and the
## killer's streak now. Authority side, after [signal player_killed] for the same kill.
signal medals_awarded(killer: int, victim: int, medals: Array, points: int, streak: int)

## The medal rules' memory. Authority side; reset at each round's start.
var medals := ArenaAwards.MedalBook.new()

## The server owner's drop rules (`arena_drop_*`), applied to every drops layer built.
var drop_rules := {
	"coins": 5, "coin_value": 1, "health": 25.0, "any_kill": false, "life": 10.0,
	"packs": true, "pack_health": 50.0, "pack_ammo": 50.0, "pack_respawn": 20.0,
}

## The jail's gate and button, drawn. Null on a headless end and on a map without a jail.
var jail_view: Node3D = null

## The server owner's jail rules (`arena_jail*`), applied to the map's jail when a map loads and
## when one changes: whether it is on, seconds the gate stays open and seconds it then stays shut.
var jail_rules := {"enabled": true, "open": 10.0, "cooldown": 20.0}

## What the packs were last placed with, so a rule change that is not about them does not put
## every pack back (which would restart its respawn timer). See [method apply_drop_rules].
var _packs_placed_with: Array = []

## Statistics, achievements and boards. Null when [member track_progress] is off or
## this instance is not the authority.
var progress: ArenaProgress = null

## Monsters. Null unless the mode asks for them and this instance is the authority.
##
## [b]Authority only, and unpredicted.[/b] A brain runs a behaviour tree against a
## blackboard with lifetimes on it, which is not something two machines reproduce from
## the same inputs — dot-npc says so and dot-props says the same thing about rigid
## bodies. A client sees monsters because they are replicated, never because it
## simulated them.
var horde: ArenaHorde = null

## The server's tunables; the server scene replaces it with the layered one.
var config := ArenaConfig.new()

## Binds [member config] to cvars and the workbench; set by the server scene.
var config_binder: DotGameConfigBinder = null
## The workbench the server scene built; [ArenaModule] starts it once the cvars it offers exist.
var workbench: DotGameWorkbench = null

## How good the monsters are, server-wide, on top of each kind's character.
##
## [b]On the game rather than on the horde, because the horde does not outlive a mode
## change[/b] and an operator who set `npc_skill hard` would otherwise get normal monsters
## back at the next map. The module binds it to `npc_skill`, `npc_reaction_scale` and
## `npc_reaction_min`; the horde attaches it to each spawner it builds.
var npc_skill: DotNpcAiSkill = DotNpcAiSkill.new()

## Records and harvests players' surf rides once [method start_ride_recording] has run.
var surf_rides: RefCounted = null

## Whether the monsters' learned map traffic is kept on disk across restarts.
##
## [b]Off unless a server turns it on[/b] — [ArenaModule] does, which only a real server
## loads. Every suite builds an ArenaGame, and one that saved would have each run's bots
## train the next run's monsters: a suite whose results depend on how often it has run.
var persist_npc_heat: bool = false

## Physics props. Null unless the mode asks for them and this instance is the authority.
var props: ArenaProps = null

## The map's toys (dot-props' [DotPropToyBox]): loose ones only here, beach balls, footballs,
## barrels and tyres, which a person walks through and pushes and a shot sends rolling but which
## stop no shot and hold nobody up, so they are never cover, a ledge or a launch in a
## deathmatch. Built from [member ArenaMap.toys] on both ends in the same order, simulated by
## the authority, posed from snapshots on a client (`arena_toy_net.gd`). Null before a map.
var toys: DotPropToyBox = null

## dot-props' `sv_toys*`, bound by the module REPLICATED and followed by a client.
var toy_rules: DotPropToyRules = DotPropToyRules.new()

## The map's toys are about to go (a map change), on both ends: what the bridge releases their
## entities on. And built, which is what a client's bridge pairs them on.
signal toys_clearing()
signal toys_built()

## A toy made a sound, on whichever end draws it: what the presentation plays.
signal toy_sound(id: StringName, at: Vector3, strength: float)

## A headless authority's copy of the level in the physics space, for the toys to land on:
## nothing else here asks the physics space about a built-in map (see [ArenaProps]).
var _toy_level: Node3D = null

## Status effects: burning, empowered, haste, spawn protection, slowed.
##
## Built in every mode, because spawn protection is one of them and every mode has
## that. dot-effects' whole integration is one line — `resolver.adjust` — which
## dot-combat has offered since it was written and nothing here had ever filled.
var effects: ArenaEffects = null

## What the round is about, in a mode that is about something. Null in a deathmatch.
var objectives: ArenaObjectives = null

## Where a dead player looks. Built in every mode, because every mode kills people.
var spectate: ArenaSpectate = null

## Who is in the session, which side, what class, where they enter, and the physics.
##
## [b]Built last and binds to everything else.[/b] It adds no authority: dot-match still
## decides the round and dot-combat still decides damage. What it does is keep one set
## of records in step with them, so a scoreboard, a spectator camera, a class screen and
## a spawn selector read the same thing rather than four dictionaries that agree until
## somebody reconnects. See [ArenaPlayerStack].
var player_stack: ArenaPlayerStack = null

## player id -> [ArenaPlayer].
var _players: Dictionary = {}
var _round_frozen_ids: Dictionary = {}
var _freeze_overridden := false

## Lag compensation: how far back the server will rewind the other players for a shot,
## in milliseconds (`arena_max_unlag_ms`; 0 judges every shot against the present).
##
## [b]It never rewound at all before 2026-10-09.[/b] `resolve_shot` was called with no
## view tick, so a player on a 120 ms round trip had to lead every target by the lead,
## the flight time and the interpolation delay together -- about 280 ms at 64 ticks --
## and a shot at somebody exactly under the crosshair missed. Now each command carries
## how far behind it the client drew everybody ([member ArenaNetCommand.view_lag_q]),
## and the shot is traced against where the other players were then. 1000 by default
## (it was 500, which covers a 250 ms round trip and clamped a player joining from
## another continent at 300-400 ms): every millisecond more is a millisecond a low-ping
## player can be shot around a corner they already left, but that only happens when the
## shooter really is that far behind, and refusing them is worse. UNLAG_HISTORY holds 2 s.
var max_unlag_ms: float = 1000.0:
	set(value):
		max_unlag_ms = maxf(value, 0.0)
		if combat != null and combat.config != null:
			combat.config.max_rewind_ms = max_unlag_ms
			combat.config.lag_compensation = max_unlag_ms > 0.0
		# A client collides with the same limit (collision_lag), so it travels in RULES.
		if is_authority and float(movement_rules.get("max_unlag_ms", -1.0)) != max_unlag_ms:
			call(&"set_movement_rules", {"max_unlag_ms": max_unlag_ms})  # defined in the derived ArenaGame

## Ticks of position history kept per player for a rewind: two seconds at 64 ticks.
const UNLAG_HISTORY := 128

## The most ticks back a mover collides with the others: inside both the server's ring and a
## client's interpolation buffer (32 snapshots), so both ends always find the same answer.
const COLLISION_LAG_MAX_TICKS := 32.0

## A jump this far in one tick (metres) is a teleport or respawn: nothing rewinds across it.
const TELEPORT_CUT := 10.0

## id -> [PackedVector3Array positions, PackedInt32Array ticks], a ring per player.
var _unlag: Dictionary = {}
## id -> the position a rewind moved a player from, until it is restored.
var _unlag_moved: Dictionary = {}
## The shooter, whom a rewind leaves where they are.
var _unlag_shooter: int = 0
## Flies simulated bullets when `sv_ballistics` is on; null without dot-weapon's ballistics rules.
var bullet_bridge: DotWeaponBulletBridge = null
## Draws their tracers (client side of a local or listen game).
var tracers: DotWeaponTracers = null
## Client side: flies the server's announced bullets for drawing only; nothing here decides a hit.
var bullet_mirrors: DotWeaponBullets = null
## Server bullet id -> the local id in [member bullet_mirrors].
var _mirror_ids: Dictionary = {}

## Movement keys changed from [method ArenaPlayer.arena_tunables]' defaults, key -> number.
##
## [b]Kept, and applied to every player who arrives later[/b], because a rule that only
## reached the players present when it was set is a rule the next joiner does not have —
## and a client and server that disagree about a slide mispredict every slide.
var movement_rules: Dictionary = {}

## The spawn points built from the map, so a map change can take them away again.
##
## Held rather than found by walking the children: this node's children are the match,
## the combat manager, the loadouts, the progress node, every player AND every spawn
## point, and a teardown that filtered them by type would free a spawn point a host
## project had added itself.
var _spawn_points: Array[DotSpawnPoint] = []

## An imported map's solid, in the tree on every machine (see `ArenaMap.movement_body`).
## Held so a map change can take it away again; null on a built-in map.
var _world_collision: Node3D = null

var _tick: int = 0
## Player id to the tick of their last spawn and last shot, for the instant loadout swap.
var _spawned_tick: Dictionary = {}
var _fired_tick: Dictionary = {}
var _registered_name: StringName = &""

## The tick each (player, hurt volume) pair is next hurt on, kept after the player leaves
## the volume until it passes. See
## [method _hurt_from_map].
var _hurt_due: Dictionary = {}

## What [method follow_server_cvars] follows; null on a server and offline.
var _cvar_source: Object = null

## What a dead body does, and which death reactions the server allows: dot-player-char's
## `sv_ragdoll*` cvars. Bound by the module on the server (REPLICATED) and followed through the
## client link on a client, which is the end that draws the bodies. One for the life of the
## game, not per map, so a map change keeps the server's setting.
var ragdoll_rules: DotPlayerRagdollRules = DotPlayerRagdollRules.new()

## Whether a player may switch to third person: dot-player-controller's `mp_forceview`. Bound
## by the module (REPLICATED) and followed by the client, which is the end with a camera.
var view_rules: DotPlayerViewRules = DotPlayerViewRules.new()

## The ambience cvars (`arena_ambient*`): bound by the module (REPLICATED), followed by a client through its link.
var ambient_rules: DotAmbienceRules = ArenaAmbience.make_rules()

## Who a spectator may watch and whether they may fly a free camera: dot-spectate's
## `mp_forcecamera`, `mp_freeroam` and `mp_freeroam_speed`. Bound by the module (REPLICATED) and
## followed by the client, which is the end that flies the camera. One object for the life of
## the game, shared with [ArenaSpectate]'s manager, so a cvar change reaches the rules in use
## and a map change keeps the operator's setting.
var spectate_rules: DotSpectatorRules = DotSpectatorRules.new()

## Whether players and bots are solid to each other: dot-player-controller's
## `mp_solidplayers` (1 by default). Bound by the module (REPLICATED) and followed by the
## client, because a client predicts its own player against the others' hulls. Arena's
## movement is analytic, so the hulls are boxes in each player's movement body
## ([method solid_hulls_for], `arena_solid_body.gd`), not the physics capsule the other
## games give a body.
var body_rules: DotPlayerBodyRules = DotPlayerBodyRules.new()

## `(other_id, mover_id, tick) -> Vector3 or null`: where [param other_id]'s hull stands when
## a networked player moves on [param tick]: where that player's client drew them, on both
## ends (`ArenaNetBridge.remote_feet`). Null, or unset, is where the other stands now.
var remote_feet_fn: Callable = Callable()

## Which pairs of players stop at each other (dot-team's `DotTeamBlockRules`: `mp_teamblock`,
## `mp_enemyblock`, `!block` / `!noblock`); null until [method make_noblock] or a client's
## `add_noblock` sets it. Feeds [member body_rules] `pair_fn`; the same answer on every machine,
## or the client rubber-bands.
var block_rules: Object = null

## dot-game's wiring of [member block_rules]: its cfg layers, cvars and chat commands.
var noblock: DotGameNoblock = null

## Whether a module has bound [member noblock]'s cvars and commands (they cannot be bound twice).
var noblock_bound := false

## The view model's motion amounts: zee-dot-weapons' `mp_vm_*` cvars. Bound by the module
## (REPLICATED) and followed by the client, which is the end that draws the hands. The
## client's view model is handed this object, so one cvar change reaches the sway.
var feel_rules: ZeeViewFeel = ZeeViewFeel.new()

## The weapon definitions by id, for the death reaction a weapon asks for. Built on the first
## kill rather than per kill: the table is twenty-seven fresh resources.
var _weapon_defs: Dictionary = {}
