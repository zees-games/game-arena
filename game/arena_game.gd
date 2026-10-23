@tool
extends Node

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

## The deathmatch itself: a match, a combat manager, a map, and some players.
##
## [b]This is the seam nothing else runs.[/b] dot-match knows nothing about damage,
## dot-combat knows nothing about scoring, dot-loadout knows nothing about weapons, and
## dot-player-controller knows about none of them. Six addons, each correct alone. This is
## the fifty lines where they meet, and the only place a mistake in the joins between
## them can show up.
##
## It is deliberately independent of dot-server: a listen server, a test and a
## dedicated server all run this, and only the last of them also runs
## [ArenaModule].

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


## The snapshot rate at [param rate] ticks a second: the nearest to [constant NET_SNAPSHOT_RATE]
## that is a whole number of ticks apart (64 and 128 give 32, 60 gives 30). dot-net divides
## with integers, so 32 at 60 Hz sent every tick, twice the bytes.
static func snapshot_rate_for(rate: int) -> int:
	return rate / maxi(1, roundi(float(rate) / float(NET_SNAPSHOT_RATE)))

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

## The simulation tick the players are on, for what is drawn from it: a player's own state, since
## that is the tick the pits are asked about, and the game's own count before there is one.
func sim_tick() -> int:
	for id in _players:
		var p: ArenaPlayer = _players[id]
		if p != null and is_instance_valid(p) and p.controller != null:
			return p.controller.state.tick
	return _tick


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

## Ticks of position history kept per player for a rewind: two seconds at 64 ticks.
const UNLAG_HISTORY := 128

## id -> [PackedVector3Array positions, PackedInt32Array ticks], a ring per player.
var _unlag: Dictionary = {}
## id -> the position a rewind moved a player from, until it is restored.
var _unlag_moved: Dictionary = {}
## The shooter, whom a rewind leaves where they are.
var _unlag_shooter: int = 0

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

## The view model's motion amounts: zee-dot-weapons' `mp_vm_*` cvars. Bound by the module
## (REPLICATED) and followed by the client, which is the end that draws the hands. The
## client's view model is handed this object, so one cvar change reaches the sway.
var feel_rules: ZeeViewFeel = ZeeViewFeel.new()

## The weapon definitions by id, for the death reaction a weapon asks for. Built on the first
## kill rather than per kill: the table is twenty-seven fresh resources.
var _weapon_defs: Dictionary = {}


func _exit_tree() -> void:
	if surf_rides != null:
		surf_rides.call(&"release")
		surf_rides = null
	if _registered_name != &"":
		DotRegistry.unregister_instance(_registered_name, self)
		_registered_name = &""


## Builds everything. Call after adding to the tree.
func setup(p_map: ArenaMap = null) -> DotResult:
	# The mode first: the map default, the damage rules and the match rules all come
	# out of it, so resolving it after any of them would build them from the old one.
	if mode == null:
		mode = ArenaModes.by_id_or_default(mode_id)

	var mode_res := mode.validate()

	if not mode_res.ok:
		return mode_res

	map = (
		p_map if p_map != null
		else (
			ArenaMap.by_id(mode.preferred_map) if mode.preferred_map != &""
			else null
		)
	)

	if map == null:
		map = ArenaMap.dm_box()

	if mode.is_team_mode() and Array(map.spawn_tags).count("") == map.spawns.size():
		# Not fatal: dot-match falls back to the shared pool and everyone still spawns.
		# It is worth a line anyway, because the symptom of playing a team mode on an
		# untagged map is "the sides keep spawning in each other's base", which reads
		# as a spawn-selection bug rather than as a map that was never tagged.
		DotLog.warn(
			CHANNEL,
			"a team mode on a map with no tagged spawns; both sides share one pool",
			{"mode": str(mode.id), "map": map.display_name}
		)

	# Before the combat manager and before any player: both bind to it.
	_build_world_collision()

	var combat_result := _build_combat()

	if not combat_result.ok:
		return combat_result

	var match_result := _build_match()

	if not match_result.ok:
		return match_result

	var loadout_result := _build_loadouts()

	if not loadout_result.ok:
		return loadout_result

	var progress_result := _build_progress()

	if not progress_result.ok:
		return progress_result

	# Last, and after the combat manager: a monster is a combat entity and a prop is a
	# rigid body that has to land on the map. Both read `mode`, which is why neither is
	# an export on this class — see `ArenaMode.horde`.
	_reconcile_world_layers()

	var stack_result := _build_player_stack()

	if not stack_result.ok:
		return stack_result

	# The stack is what knows the collision layout, and it is built last.
	_classify_world_collision()
	_build_toys()

	if register_service:
		_registered_name = (
			DotRegistry.scoped_name(SERVICE, service_scope)
			if service_scope != &""
			else SERVICE
		)
		DotRegistry.register(_registered_name, self)

	_announce_mode()

	return DotResult.success(null)


## Keeps this world's combat manager on the server's replicated cvars (dot-combat's
## `mp_teammate_passthrough`), as [param source] reports them: the client's `DotClientLink`.
## Remembered, because a map change builds a new manager. True when it is following.
##
## [b]Why a client needs it.[/b] This end traces its own shots for tracers and impacts, and
## on the default 1 against a server on 0 or 2 they ended in (or went through) a team-mate
## where the server's did the opposite. A family cvar, so it rides dot-server's replicated
## cvars rather than RULES: one path for every game. By name, like the module's bind: an older
## host's dot-combat or link cannot follow, and the manager keeps its default.
func follow_server_cvars(source: Object) -> bool:
	_cvar_source = source
	# The ragdoll rules are the game's, not the map's, so they follow once and keep following.
	var _bodies := ragdoll_rules.follow_cvars(source)
	var _toys := toy_rules.follow_cvars(source)
	var _view := view_rules.follow_cvars(source)
	var _spectate := spectate_rules.follow_cvars(source)
	var _solid := body_rules.follow_cvars(source)
	var _feel := feel_rules.follow_cvars(source)
	return _follow_cvar_source()


func _follow_cvar_source() -> bool:
	if _cvar_source == null or not is_instance_valid(_cvar_source) or combat == null:
		return false
	if not combat.has_method(&"follow_cvars"):
		return false
	return bool(combat.call(&"follow_cvars", _cvar_source))


func _build_combat() -> DotResult:
	combat = DotCombatManager.new()
	combat.name = "Combat"
	combat.is_authority = is_authority
	combat.register_service = false
	combat.trace = map.shot_trace()

	var rules := DotDamageRules.new()
	# Both from the mode. friendly_fire is meaningless without teams and harmless to
	# set either way; self damage is on in every mode this ships, because rocket
	# jumping is a movement option and taking it away removes the only reason the
	# rocket launcher is interesting to hold.
	rules.friendly_fire = mode.friendly_fire
	rules.self_damage = mode.self_damage
	rules.hit_groups = true
	rules.falloff = true
	rules.maximum = 400.0
	combat.rules = rules

	var config := DotCombatConfig.new()
	config.tick_rate = tick_rate
	config.lag_compensation = max_unlag_ms > 0.0
	config.max_rewind_ms = max_unlag_ms
	config.max_origin_error = 2.5
	combat.config = config
	combat.rewind_fn = _unlag_rewind
	combat.restore_fn = _unlag_restore

	add_child(combat)

	# AFTER add_child: `DotCombatManager.setup` runs from `_ready` and that is what
	# builds the resolver, so assigning this beforehand writes to nothing.
	#
	# This is the entire friendly-fire seam. dot-combat has no idea what a team is; it
	# asks this callable for two entity ids and compares the answers, and treats team 0
	# as "no team" so two unassigned players in a free-for-all can always hurt each
	# other. Without it `rules.friendly_fire = false` protects nobody, because every
	# pair looks like strangers.
	combat.resolver.team_of = func(entity_id: int) -> int:
		var player := player_for(entity_id)
		return player.team if player != null else 0

	for type in ArenaContent.damage_types():
		combat.register_damage_type(type)

	combat.entity_killed.connect(_on_entity_killed)
	combat.damage_applied.connect(_on_damage_applied)

	# A manager built for a new map starts on dot-combat's defaults; a client puts it back on
	# the server's cvars here (see follow_server_cvars).
	var _following := _follow_cvar_source()


	projectiles = ArenaProjectiles.new()
	# The same gravity the players fall under, so a grenade arc and a jump arc agree.
	# ArenaPlayer sets this on its tunables; the two must not drift apart.
	projectiles.setup(combat, 22.0)
	# Where a grenade's `sticks` is read from. The player's catalogue, not a second one.
	projectiles.catalogue = ArenaPlayer.weapon_catalogue()
	projectiles.origin_of = func(entity_id: int) -> Variant:
		var thrower := player_for(entity_id)
		return thrower.muzzle_position() if thrower != null else null

	drops = ArenaDrops.new()
	drops.name = "Drops"
	drops.is_authority = is_authority
	drops.draws = not headless
	add_child(drops)
	drops.setup(tick_rate)
	drops.position_of = func(entity_id: int) -> Variant:
		var who := player_for(entity_id)
		return who.global_position if who != null else null
	apply_drop_rules()
	apply_jail_rules()

	if not headless and map != null and map.jail != null:
		jail_view = ArenaJailView.new()
		add_child(jail_view)
		jail_view.build(map.jail, sim_tick)

	return DotResult.success(null)


## Gives [param player_id] what [param reward] names. Authority side.
func _reward_streak(player_id: int, streak: int, reward: String) -> void:
	var player := player_for(player_id)
	if player == null or not player.is_alive():
		return

	match reward:
		"heal":
			var _h := player.health.heal(player.health.max_health)
		"armour":
			player.health.add_armour(player.health.max_armour)
		"haste":
			if effects != null:
				var _r := effects.apply(ArenaEffects.HASTE, player_id)
		"empowered":
			if effects != null:
				var _r := effects.apply(ArenaEffects.EMPOWERED, player_id)
		_:
			return

	streak_reward.emit(player_id, streak, reward)


## "3:heal,5:haste" -> {3: "heal", 5: "haste"}. Unparseable pairs are skipped.
static func parse_streak_rewards(text: String) -> Dictionary:
	var out := {}
	for pair in text.split(",", false):
		var bits := pair.strip_edges().split(":")
		if bits.size() == 2 and bits[0].is_valid_int() and int(bits[0]) > 0:
			out[int(bits[0])] = bits[1].strip_edges()
	return out


## Puts [member jail_rules] on the map's jail, if it has one. Called when the drops layer is
## built (which is on every map) and when a rule changes. Authority side tells clients.
func apply_jail_rules() -> void:
	if map == null or map.jail == null:
		return
	var jail: RefCounted = map.jail
	jail.enabled = bool(jail_rules["enabled"])
	jail.open_ticks = maxi(int(round(float(jail_rules["open"]) * float(tick_rate))), 1)
	jail.cooldown_ticks = maxi(int(round(float(jail_rules["cooldown"]) * float(tick_rate))), 0)
	if is_authority:
		jail_changed.emit()


## The server's jail state, on a client: the rules in ticks and when the gate was last opened.
func apply_jail_state(told: Dictionary) -> void:
	if map == null or map.jail == null:
		return
	var jail: RefCounted = map.jail
	jail.enabled = bool(told["enabled"])
	jail.open_ticks = int(told["open_ticks"])
	jail.cooldown_ticks = int(told["cooldown_ticks"])
	jail.opened_at = int(told["opened_at"])


## Whoever stands in the jail's button presses it. Authority side, after everybody has moved.
func _sweep_jail_button() -> void:
	if not is_authority or map == null or map.jail == null:
		return
	var jail: RefCounted = map.jail
	if not jail.enabled:
		return
	var box: AABB = jail.button_box()
	for id in player_ids():
		var p: ArenaPlayer = _players[id]
		if p.is_alive() and box.has_point(p.controller.state.position):
			var at: int = p.controller.state.tick
			if jail.press(at):
				DotLog.info(CHANNEL, "the jail's gate opened", {"by": id, "tick": at})
				jail_changed.emit()
				return


## Puts [member drop_rules] on the drops layer. Called when it is built and when a rule
## changes.
func apply_drop_rules() -> void:
	if drops == null:
		return
	drops.coins_per_kill = int(drop_rules["coins"])
	drops.coin_value = int(drop_rules["coin_value"])
	drops.health_amount = float(drop_rules["health"])
	drops.any_kill = bool(drop_rules["any_kill"])
	drops.life_sec = float(drop_rules["life"])
	drops.packs_enabled = bool(drop_rules["packs"])
	drops.pack_health = float(drop_rules["pack_health"])
	drops.pack_ammo_share = clampf(float(drop_rules["pack_ammo"]) / 100.0, 0.0, 1.0)
	drops.pack_respawn_sec = float(drop_rules["pack_respawn"])
	var wanted: Array = [
		map, drops, drops.packs_enabled, drops.pack_health, drops.pack_ammo_share, drops.pack_respawn_sec,
	]
	if map != null and is_authority and (_packs_placed_with.size() != wanted.size() or wanted != _packs_placed_with):
		_packs_placed_with = wanted
		drops.set_packs(map.packs, _tick)


## Puts [member score_limit], [member time_limit_sec], [member warmup_sec] and
## [member min_players] on the match being played, from the next tick (dot-match reads its
## rules every tick). The authority's to call; a client is told the score limit and the clock
## by MATCH. A limit the match has already passed ends it on the next check, which is what a
## lowered frag limit does in the genre.
func apply_match_limits() -> void:
	if match_node == null or match_node.rules == null or mode == null:
		return
	# From the mode again, so setting an export back to zero restores the mode's number
	# rather than keeping the last override.
	var from_mode: DotMatchRules = mode.rules
	match_node.rules.score_limit = from_mode.score_limit
	match_node.rules.time_limit_sec = from_mode.time_limit_sec
	match_node.rules.warmup_sec = from_mode.warmup_sec
	match_node.rules.min_players = from_mode.min_players
	if freeze_sec >= 0.0 or _freeze_overridden:
		match_node.rules.countdown_sec = from_mode.countdown_sec
	_freeze_overridden = freeze_sec >= 0.0
	_override_rules(match_node.rules)


func _override_rules(rules: DotMatchRules) -> void:
	# The final killcam plays inside the match's end, so the end is that much longer.
	rules.match_end_sec = mode.rules.match_end_sec + rule("killcam")

	# Gun game's limit is the length of its list: a kill is a level, and a limit past the
	# last gun is kills with the knife nobody is counting ([ArenaMode]).
	if score_limit > 0 and mode.gun_game.is_empty():
		rules.score_limit = score_limit

	if time_limit_sec > 0.0:
		rules.time_limit_sec = time_limit_sec

	if warmup_sec >= 0.0:
		rules.warmup_sec = warmup_sec

	if min_players > 0:
		rules.min_players = min_players

	if freeze_sec >= 0.0:
		rules.countdown_sec = freeze_sec


func _build_match() -> DotResult:
	# DUPLICATED, not used directly. A Resource is a reference in GDScript, so handing
	# dot-match the catalogue's own rules would mean a server that raised a score limit
	# at runtime had edited the mode every later match reads.
	var rules: DotMatchRules = mode.rules.duplicate()

	# The exports override the mode when they are set, so a server can keep the mode
	# and change the numbers. Zero means "whatever the mode said".
	_override_rules(rules)

	match_node = DotMatch.new()
	match_node.name = "Match"
	match_node.rules = rules
	match_node.register_service = false

	# Built here rather than left to dot-match, which would otherwise make an untagged
	# `DotTeam.standard_pair()`. The tags are the whole point — see `ArenaMode.teams`.
	#
	# It has to be assigned AND parented before `add_child(match_node)`, because that
	# is what runs `DotMatch._ready` and therefore `setup`, and setup only creates a
	# manager when it finds none.
	if mode.is_team_mode():
		var manager := DotTeamManager.new()
		manager.name = "Teams"
		manager.teams = mode.teams()
		match_node.teams = manager
		match_node.add_child(manager)

	var config := DotMatchConfig.new()
	config.tick_rate = tick_rate
	config.auto_start = false
	config.balance_between_rounds = false
	match_node.config = config

	# **Collect spawn points from THIS game and nowhere else.**
	#
	# `DotMatch.setup` calls `refresh_spawns`, which with no `spawns_ref` walks
	# `get_tree().current_scene` — the whole tree. That is right for a game that is the
	# scene and wrong for every other arrangement, and this project has two of them:
	# a suite that builds several `ArenaGame`s in one process, and a `changelevel`,
	# where the outgoing map's points are still children for the rest of the frame
	# because `queue_free` is deferred.
	#
	# Measured: a second game in the tree contributed ten spawn points to this one's
	# match, so players spawned in a map they were not in. Nothing errored — a spawn
	# point is a spawn point, and dot-match had been handed exactly what it asked for.
	# PARENT rather than SELF: `DotMatch` resolves the ref against ITSELF, so SELF is
	# the match node, whose only child is the team manager. The spawn points are
	# children of the game, which is the match node's parent.
	var mine := DotNodeRef.new()
	mine.mode = DotNodeRef.Mode.PARENT
	match_node.spawns_ref = mine

	add_child(match_node)

	# Spawn points come from the map, not from the scene: a headless server never
	# instantiates the level's nodes, and a match with no spawn points is a match
	# nobody ever appears in.
	for index in range(map.spawns.size()):
		var point := DotSpawnPoint.new()
		point.name = "Spawn%02d" % match_node.spawn_points().size()
		point.transform = map.spawns[index]
		point.cooldown_ticks = int(2.0 * float(tick_rate))

		# The map's tag, which is what a team's `spawn_tag` matches against. An
		# untagged point stays available to everybody.
		var tag := map.spawn_tag(index)

		if tag != &"":
			point.tags.append(tag)

		add_child(point)
		match_node.add_spawn_point(point)
		_spawn_points.append(point)

	# Where everyone is, so the spawn selector can put a player away from the fight.
	# Without this it falls back to cooldowns alone and will happily spawn someone in
	# front of the player who just killed them.
	match_node.position_fn = func(key: String) -> Vector3:
		var player := player_for(int(key))
		return player.controller.state.position if player != null else Vector3.ZERO

	match_node.respawn_due.connect(_on_respawn_due)
	match_node.state_changed.connect(_on_match_state_changed)

	return DotResult.success(null)


func _build_loadouts() -> DotResult:
	loadouts = DotLoadoutManager.new()
	loadouts.name = "Loadouts"
	loadouts.schema = ArenaContent.loadout_schema()
	loadouts.register_service = false

	var config := DotLoadoutConfig.new()
	config.backend = "memory"
	config.allow_default_loadout = true
	config.conform_on_load = true
	loadouts.config = config
	loadouts.store = DotLoadoutStoreMemory.new()

	# Everything in this game is free except the launcher, and there is no entitlement
	# service to ask. A game with unlocks binds a real source here; leaving it unset means
	# only `free` items, which is dot-loadout's loud default.
	loadouts.entitlement_source = func(_key: String) -> DotLoadoutEntitlements:
		return DotLoadoutEntitlements.of([ArenaContent.PAID_WEAPON])

	add_child(loadouts)
	_build_loadout_command()
	return DotResult.success(null)


const LOADOUT_COMMAND_SCRIPT := "res://addons/dot_loadout/integrations/dot_loadout_command.gd"


## The B menu's server half, when the host's dot-loadout has one (API 2).
func _build_loadout_command() -> void:
	if DotAddonApi.build_level("dot_loadout") < 2 or not ResourceLoader.exists(LOADOUT_COMMAND_SCRIPT):
		return
	loadout_command = (load(LOADOUT_COMMAND_SCRIPT) as GDScript).new()
	loadout_command.set(&"manager", loadouts)
	# The player a command came from: the session's userid, which is this game's player id.
	loadout_command.set(&"key_fn", func(ctx: Object) -> String:
		var session: Variant = ctx.get(&"session") if ctx != null else null
		return storage_key(int((session as Object).get(&"userid"))) if session is Object else "")
	loadout_command.set(&"closed_fn", func(_key: String) -> String: return loadout_closed_reason())
	loadout_command.set(&"applied_fn", func(_ctx: Object, key: String) -> bool:
		return await rearm_if_allowed(player_id_of_key(key)))


## Why the B menu has nothing to choose right now, or "": a mode that decides what everybody
## carries (gun game, Only Snipers) makes a loadout pointless, and the menu says so rather than
## saving a choice the next spawn throws away.
func loadout_closed_reason() -> String:
	if mode != null and mode.arms_players():
		return "%s hands out the weapons. Your loadout is kept for the next mode." % mode.display_name
	return ""


## The player id a loadout key names (`arena-player-%08d`), or 0.
static func player_id_of_key(key: String) -> int:
	return key.trim_prefix("arena-player-").to_int() if key.begins_with("arena-player-") else 0


## Whether a new loadout goes into [param id]'s hands now rather than at the next spawn: in
## warmup, and while their spawn protection lasts (they have not been in a fight with what they
## spawned holding). Anything later would be a free reload and a weapon swap mid-fight.
func loadout_now_allowed(id: int) -> bool:
	var player := player_for(id)
	if player == null or not player.is_alive():
		return false
	if match_node != null and match_node.state == DotMatch.State.WARMUP:
		return true
	return player.health != null and player.health.is_protected(_tick)


## Puts [param id]'s saved loadout in their hands when [method loadout_now_allowed]. True when it
## did. Authority only: the arsenal replicates from here.
func rearm_if_allowed(id: int) -> bool:
	if not is_authority or not loadout_now_allowed(id):
		return false
	await apply_loadout(id)
	DotLog.debug(CHANNEL, "loadout handed over at once", {"player": id})
	return true


## Statistics, achievements and boards, if this instance keeps any.
##
## [b]Built last, and after the match node exists.[/b] [method ArenaProgress.attach]
## connects to the combat manager's shot and damage signals and to dot-match's round
## and match signals; every one of those is created by the three builders above, and
## attaching before them would connect to null with no error until the first kill.
## Stands up the player-facing addons and binds them to this game.
##
## After everything else, because it reads the match's team manager, the match's spawn
## points and this node's tick rate, and a stack built before any of those exists binds
## to nothing and reports success.
func _build_player_stack() -> DotResult:
	if player_stack != null:
		player_stack.queue_free()

	player_stack = ArenaPlayerStack.new()
	player_stack.name = "PlayerStack"
	# A client mirrors what the server decided; re-applying a physics profile there
	# would have it simulate at a rate the server does not.
	player_stack.apply_physics = is_authority
	player_stack.register_service = register_service
	add_child(player_stack)

	return player_stack.setup(self).wrap("The arena's player stack")


func _build_progress() -> DotResult:
	if not track_progress or not is_authority:
		return DotResult.success(null)

	progress = ArenaProgress.new()
	progress.name = "Progress"
	add_child(progress)

	var attached := progress.attach(self)

	if not attached.ok:
		# A game with no statistics is a game. A game that refuses to start because a
		# leaderboard definition was rejected is not, and this is the same call
		# `apply_loadout` makes about an unreachable store.
		DotLog.warn(CHANNEL, "progression is off", {"why": attached.error.message})
		remove_child(progress)
		progress.queue_free()
		progress = null

	return DotResult.success(null)


## The monsters and the props the mode asks for.
##
## [b]Neither is fatal and neither logs at warning level when it is simply off.[/b] A
## mode with no monsters is the ordinary case; a mode that wanted them and could not
## have them is worth a line, because the symptom is an empty arena in a game called
## Siege and nothing to say why.
## Build the layers a mode asks for, and take away the ones it does not.
##
## [b]Called from `change_map` as well as from `setup`, and that is the whole point.[/b]
## Before it was, the layers were built once and never reconsidered — so switching from
## free-for-all to `koth` produced a game whose mode said it had objectives and whose
## `objectives` was null, and switching to `siege` produced one with no monsters in it.
## Nothing errored: a null layer is a legitimate thing for a mode with no layer to have,
## and the only symptom was a mode that did not do what it says.
func _reconcile_world_layers() -> void:
	if not is_authority and mode != null:
		# A networked client builds one layer of the world's: the spectator camera, which
		# is drawn where it is computed. Until it did, a client had no spectate layer at
		# all and a dead player's camera stayed on the body for the whole of every death.
		_build_spectate()
		return

	if not is_authority or mode == null:
		return

	_build_world_layers()

	# And the other direction. A mode with no objectives must not keep the last one's,
	# because a HUD reads the layer rather than the mode and would draw a hill nobody
	# can capture.
	if objectives != null and mode.objective_layout == &"":
		remove_child(objectives)
		objectives.queue_free()
		objectives = null

	if horde != null and not mode.horde:
		remove_child(horde)
		horde.queue_free()
		horde = null

	if props != null and not mode.player_props and mode.scatter_props <= 0:
		remove_child(props)
		props.queue_free()
		props = null


## The spectate layer, on every side. Idempotent.
func _build_spectate() -> void:
	if spectate != null:
		return

	spectate = ArenaSpectate.new()
	spectate.name = "Spectate"
	spectate.game = self
	add_child(spectate)

	var spectate_ready := spectate.setup()

	if not spectate_ready.ok:
		DotLog.warn(
			CHANNEL, "spectating is off", {"why": spectate_ready.error.message}
		)
		remove_child(spectate)
		spectate.queue_free()
		spectate = null


## Build whatever is missing. Idempotent, because [method _reconcile_world_layers]
## calls it on every map change as well as at setup.
##
## Each layer is built once and then left alone: a rebuilt layer is a layer whose signal
## connections have to be remade, and a connection to a freed object is an error at the
## next emit rather than at the disconnect that was skipped. What a MODE change needs is
## the layer to exist or not exist, which the reconcile above does by taking it away.
func _build_world_layers() -> void:
	if not is_authority or mode == null:
		return

	# Effects first, and the order matters: ArenaObjectives asks the effects layer
	# whether a player may capture, and a layer that is not there yet answers "no
	# layer", which is a legitimate answer and would silently let an invulnerable
	# player take a point.
	if effects == null:
		effects = ArenaEffects.new()
		effects.name = "Effects"
		effects.game = self
		add_child(effects)

		var effects_ready := effects.setup()

		if not effects_ready.ok:
			DotLog.warn(CHANNEL, "effects are off", {"why": effects_ready.error.message})
			remove_child(effects)
			effects.queue_free()
			effects = null

	_build_spectate()

	if mode.objective_layout != &"" and objectives == null:
		objectives = ArenaObjectives.new()
		objectives.name = "Objectives"
		objectives.game = self
		add_child(objectives)

		var objectives_ready := objectives.setup()

		if not objectives_ready.ok:
			DotLog.warn(
				CHANNEL, "objectives are off", {"why": objectives_ready.error.message}
			)
			remove_child(objectives)
			objectives.queue_free()
			objectives = null

	if (mode.player_props or mode.scatter_props > 0) and props == null:
		props = ArenaProps.new()
		props.name = "Props"
		props.game = self
		props.players_may_spawn = mode.player_props
		props.scatter_count = mode.scatter_props
		add_child(props)

		var props_ready := props.setup()

		if not props_ready.ok:
			DotLog.warn(CHANNEL, "props are off", {"why": props_ready.error.message})
			remove_child(props)
			props.queue_free()
			props = null

	if not mode.horde or horde != null:
		return

	horde = ArenaHorde.new()
	horde.name = "Horde"
	horde.game = self
	add_child(horde)

	var horde_ready := horde.setup()

	if not horde_ready.ok:
		DotLog.warn(CHANNEL, "the horde is off", {"why": horde_ready.error.message})
		remove_child(horde)
		horde.queue_free()
		horde = null
		return

	horde.enabled = true


func start(tick: int = 0) -> void:
	_tick = tick
	match_node.start(tick)


# --- Changing the map ------------------------------------------------------

## Replaces the world under the players who are standing in it.
##
## [b]This is what `ArenaGame.setup` could never be asked to do twice.[/b] setup builds
## the combat trace, the match node and every spawn point as children in one pass and
## is not re-entrant: calling it again leaves two matches, two combat managers and two
## sets of spawns in one tree, all of them connected to the same signals, and the
## second of each quietly wins. So the teardown is the feature, and it is the half that
## has to be right — every one of the joins this game exists to test is a signal
## connection, and a connection to a freed object is an error at the next emit rather
## than at the disconnect that was skipped.
##
## What survives a change and what does not:
##
## - [b]The players do.[/b] Their nodes, their statistics and their loadouts are about
##   a person on this server, not about a room. They are re-bodied against the new
##   geometry and put back into the new match.
## - [b]The match does not.[/b] A new map is a new match; scores from the last one
##   belong to the last one. dot-stats' session totals are deliberately not reset,
##   because a session is a visit to the server.
## - [b]The combat manager does not[/b], because its trace is the map.
##
## [param new_mode] is optional; null keeps the mode that is running. A mode change is
## the one thing that must happen HERE rather than afterwards — the match rules, the
## team manager and the damage rules are all built from it, and assigning it after the
## rebuild would leave every one of them describing the previous mode.
func change_map(new_map: ArenaMap, new_mode: ArenaMode = null) -> DotResult:
	if new_map == null:
		return DotResult.fail(DotError.CODE_INVALID, "There is no map to change to.")

	if map == null or match_node == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The game has not been set up, so there is nothing to change."
		)

	if new_mode != null:
		var mode_res := new_mode.validate()

		if not mode_res.ok:
			return mode_res.wrap("The mode that map wanted is not usable")

	# Read before the teardown: `_players` survives it, but the team a player was on
	# belongs to the match that is about to be freed.
	var roster: Array = []

	for id in player_ids():
		var player: ArenaPlayer = _players[id]
		roster.append({"id": id, "name": player.display_name})

	_teardown_world()
	_hurt_due.clear()

	map = new_map

	if new_mode != null:
		mode = new_mode

	# Before the combat manager and before any player is re-bodied: both bind to it.
	_build_world_collision()
	_classify_world_collision()

	var combat_result := _build_combat()

	if not combat_result.ok:
		return combat_result.wrap("The new map's combat could not be built")

	var match_result := _build_match()

	if not match_result.ok:
		return match_result.wrap("The new map's match could not be built")

	for row in roster:
		var id := int(row["id"])
		var player := player_for(id)

		if player == null:
			continue

		# The body first. A player whose collision is still the old map's geometry is
		# one standing inside a wall that no longer exists, and the first tick after
		# the change would push them out of a room they are not in.
		# The movement first, so the motor `rebind_map` rebuilds (and logs) is the map's.
		player.apply_map_movement(map_movement())
		player.rebind_map(map)
		player.join_combat(combat)

		var added := match_node.add_player(str(id), String(row["name"]), _tick, 0)

		if not added.ok:
			DotLog.warn(CHANNEL, "a player could not rejoin after the map change", {
				"player": id, "why": added.error.message
			})
			continue

		player.team = team_of(id)

	if progress != null:
		progress.rebind_world()

	# The layers the NEW mode asks for, and only them. Before this existed a mode
	# change built nothing and took nothing away, so `changegame`-ing from a deathmatch
	# to `koth` produced a game whose mode said it had objectives and whose objectives
	# were null — and to `siege` produced one with no monsters in it.
	#
	# Before the announcement, because a HUD and a net bridge both read these off the
	# game inside their `map_changed` handlers.
	_reconcile_world_layers()

	# Before the announcement: the net bridge registers them inside its `map_changed`.
	_build_toys()

	# Whatever state the last match ended in, the new one starts from the beginning.
	match_node.start(_tick)

	DotLog.info(CHANNEL, "map changed", {
		"map": map.display_name, "mode": String(mode.id), "players": _players.size()
	})

	map_changed.emit(map)
	_announce_mode()

	# After the announcement, so every layer that rebinds on it — the player stack's
	# spawn sites and spawn rules, the effects' resolver hook — has done so before the
	# first spawn on the new map asks it anything.
	_respawn_for_new_map()

	return DotResult.success(map)


## Puts every player in the match at a spawn point of the map that was just built.
##
## [b]A position is a place in a room, and the room was replaced.[/b] Before this, a map
## change re-bodied each player against the new geometry and left them where they had
## been standing in the old one. Wherever the new map has a box, a player carried over
## into it is inside solid geometry, and the flat body resolves that by whichever face
## is nearest — which for a player standing on the floor inside a box is the floor.
## Found building `dm_atrium`'s keep: a box across its south door landed on a position
## a `dm_box` player had carried over, and headless_match found him under the floor.
##
## Through [method _on_respawn_due], which is the round start's path: the director's
## choice with its enemy distance and team sides, spawn protection, a cleared effect set
## and the loadout. A player who was dead is put back too, because the timer that would
## have revived them belonged to the match that was just freed and the new one's warmup
## does not drain a queue. Spectators stay out, exactly as the round start leaves them.
##
## [b]The authority only.[/b] A mirroring client runs `change_map` to rebuild its own
## geometry; where anybody stands is the server's decision, and the snapshot after the
## respawn carries it — the predictor adopts the server's state and replays on top.
func _respawn_for_new_map() -> void:
	if not is_authority or match_node == null:
		return

	for id in player_ids():
		var key := str(id)
		var record := match_node.scoreboard.find(key)

		if record == null or not record.present or record.spectating:
			continue

		_on_respawn_due(key, match_node.choose_spawn(key, _tick), _tick)


## Puts an imported map's solid in the tree, replacing the last one; nothing on a
## built-in map.
##
## [b]On every machine, the dedicated server included.[/b] A built-in map is analytic and a
## headless server never builds its level; an imported map's movement and shots are
## physics queries (`ArenaMap.movement_body`), so the brushes have to be in this process's
## physics space wherever anybody moves. [b]`free()`, not `queue_free()`[/b]: the next
## map's solid goes in on the next line, and two maps' brushes in one space for a frame
## is a player standing on the wrong one.
func _build_world_collision() -> void:
	if _world_collision != null and is_instance_valid(_world_collision):
		remove_child(_world_collision)
		_world_collision.free()

	_world_collision = null

	if map == null or not map.is_imported():
		return

	_world_collision = map.to_collision()
	_world_collision.name = "WorldCollision"
	add_child(_world_collision)
	map.collision_root = _world_collision

	# Before `_build_match` turns the spawns into spawn points: a mapper's spawn inside the
	# floor would otherwise be a player rising through it. See `ArenaMap.settle_spawns`.
	var lifted := map.settle_spawns(map.movement_body(), ArenaPlayer.arena_tunables())

	if lifted > 0:
		DotLog.debug(CHANNEL, "spawns lifted out of an imported map's solid", {
			"map": String(map.id), "lifted": lifted, "of": map.spawns.size()
		})


## The solid on the layout's `world` layer, once there is a layout to ask.
func _classify_world_collision() -> void:
	if _world_collision != null and player_stack != null:
		var _n := player_stack.classify_tree(_world_collision, &"world")


## Frees everything that belongs to the map, in the order the connections require.
##
## [b]Disconnect before free, and disconnect from the object that holds the
## connection.[/b] Godot cleans up connections when a node is freed, so most of this
## is belt and braces — but [ArenaProgress] outlives the teardown and is connected to
## both the combat manager and the match node, and a node that is still connected to a
## freed object when its own handler runs is the error that has no line number.
func _teardown_world() -> void:
	_clear_toys()

	if progress != null:
		progress.unbind_world()

	for id in player_ids():
		(_players[id] as ArenaPlayer).leave_combat()

	if match_node != null and is_instance_valid(match_node):
		if match_node.respawn_due.is_connected(_on_respawn_due):
			match_node.respawn_due.disconnect(_on_respawn_due)

		if match_node.state_changed.is_connected(_on_match_state_changed):
			match_node.state_changed.disconnect(_on_match_state_changed)

		# The position callable closes over this node and is read on every spawn
		# selection. Cleared rather than left to the free, because a Callable held by
		# a node being freed is exactly the sort of thing that runs once more.
		match_node.position_fn = Callable()

		remove_child(match_node)
		match_node.queue_free()

	match_node = null

	if combat != null and is_instance_valid(combat):
		if combat.entity_killed.is_connected(_on_entity_killed):
			combat.entity_killed.disconnect(_on_entity_killed)

		if combat.damage_applied.is_connected(_on_damage_applied):
			combat.damage_applied.disconnect(_on_damage_applied)

		remove_child(combat)
		combat.queue_free()

	combat = null
	projectiles = null

	if jail_view != null:
		remove_child(jail_view)
		jail_view.queue_free()
		jail_view = null
	if drops != null:
		remove_child(drops)
		drops.queue_free()
		drops = null

	for point in _spawn_points:
		if is_instance_valid(point):
			remove_child(point)
			point.queue_free()

	_spawn_points.clear()


# --- Players ---------------------------------------------------------------

## Adds a player, builds their body, and puts them in the match.
func add_player(
	id: int, display_name: String, wanted_team: int = 0
) -> DotResult:
	if _players.has(id):
		return DotResult.fail(DotError.CODE_STATE, "Player %d is already here." % id)

	var player := ArenaPlayer.new()
	player.setup(
		ArenaPlayer.Mode.HEADLESS if headless else ArenaPlayer.Mode.PHYSICS,
		map,
		id,
		display_name
	)
	# Before it enters the tree, so the controller that readies (and logs) is the map's.
	player.apply_map_movement(map_movement())
	add_child(player)

	# The layout's player mask, rather than `DotFpsTunables`' default of 1. See
	# `ArenaPlayer.use_collision_mask` — with props on their own layer, 1 is a player
	# who walks through crates.
	if player_stack != null:
		player.use_collision_mask(player_stack.player_collision_mask())

	player.join_combat(combat)
	player.apply_movement_rules(movement_rules)
	player.solid_hulls_fn = solid_hulls_for
	_players[id] = player

	var added := match_node.add_player(str(id), display_name, _tick, wanted_team)

	if not added.ok:
		remove_player(id)
		return added

	# The side dot-match actually put them on, which is not necessarily the one they
	# asked for: `DotTeamManager.assign` refuses a full team and balances an uneven one.
	# Reading it back rather than assuming is the difference between a scoreboard that
	# matches the game and one that matches the request.
	#
	# It is set on the player because that is what dot-combat's friendly-fire check and
	# the renderer's colour both read, and `ArenaPlayer.team` had been declared and
	# assigned by nothing since the class was written.
	player.team = team_of(id)

	if progress != null:
		# Not awaited. An achievement store may be remote and a join may not wait on
		# it; readings that arrive during the load are still counted, because
		# `DotAchievementStatsLink` holds its baseline until the tracker has the
		# player. See `ArenaProgress.begin`.
		progress.begin(id, display_name)

	# Last, and only once the player is fully in: a handler runs synchronously inside
	# this and the first thing a client's does is hang a camera off them.
	player_added.emit(player)

	return DotResult.success(player)


func remove_player(id: int) -> void:
	_unlag.erase(id)
	medals.forget(id)
	var player := player_for(id)

	if player == null:
		return

	if props != null:
		# Before anything else: it drops whatever they were carrying, and a physics
		# gun still holding a crate for a player who no longer exists holds it for
		# ever — the prop is frozen mid-air and nothing owns it.
		props.release_player(id)

	if progress != null:
		# Before the player leaves the match: `leave` files the session onto the
		# boards and reads the display name off the player to do it.
		progress.leave(id)

	if player_stack != null:
		# Before dot-match forgets them: the stack reads the scoreboard and the match's
		# team for the records it files, and after `match_node.remove_player` there is
		# nothing there to read. A method rather than a signal, because there is no
		# signal here and adding one for a single subscriber is worse than a call.
		player_stack.drop_player(id)

	player.leave_combat()
	match_node.remove_player(str(id))

	_players.erase(id)
	remove_child(player)
	player.queue_free()


## Which side a player is on, or 0 in a free-for-all.
func team_of(id: int) -> int:
	if match_node == null or match_node.teams == null:
		return 0

	return match_node.teams.team_of(str(id))


## The sides in play, empty in a free-for-all.
func teams() -> Array[DotTeam]:
	if match_node == null or match_node.teams == null:
		return []

	return match_node.teams.teams


## Sets movement rules (key -> number, see [constant ArenaPlayer.MOVEMENT_RULES]) for
## every player now and later. On a server, the bridge forwards them to clients; on a
## client, this is where RULES lands.
func set_movement_rules(rules: Dictionary) -> void:
	for key in rules:
		if ArenaPlayer.MOVEMENT_RULES.has(String(key)) or SHOW_RULES.has(String(key)):
			movement_rules[String(key)] = float(rules[key])

	for player in players():
		player.apply_movement_rules(movement_rules)

		if rules.has("surf") or rules.has("surf_air_accelerate"):
			player.apply_map_movement(map_movement())

	if not is_authority and rules.has("mode_index"):
		var all := ArenaModes.all()
		var index := int(rules["mode_index"])
		if index >= 0 and index < all.size() and (shown_mode == null or shown_mode.id != all[index].id):
			shown_mode = all[index]
			mode_shown.emit(shown_mode)

	if is_authority and rules.has("killcam"):
		apply_match_limits()

	movement_rules_changed.emit(movement_rules)


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
## `killcam` is the final killcam's seconds (`mp_killcam_time`, 0 off): clients play it, and the
## authority adds it to the match's end ([method _override_rules]).
const SHOW_RULES: PackedStringArray = ["break_mode", "break_limbs", "break_criticals_only", "fp_body", "mode_index", "surf", "surf_air_accelerate", "killcam"]
const SHOW_DEFAULTS := {"break_mode": 1.0, "break_limbs": 1.0, "break_criticals_only": 1.0, "fp_body": 0.0, "surf": 1.0, "surf_air_accelerate": 150.0, "killcam": 7.0}


## The movement overrides the current map asks for, after the server's rules.
##
## [b]Per map, and derived on both ends from the map itself[/b] — `ArenaMap.movement_profile`,
## which an imported map's manifest decides — so a client that loaded the map already knows,
## and only an operator's change has to travel (in RULES, as `surf` and
## `surf_air_accelerate`). Empty on the arena's own maps, which is what puts the arena's air
## control back after a surf map: `ArenaPlayer.apply_map_movement` resets every key it is
## not given.
func map_movement() -> Dictionary:
	if map == null or map.movement_profile != &"surf" or rule("surf") == 0.0:
		return {}

	var out: Dictionary = ArenaPlayer.SURF_TUNABLES.duplicate()
	out["air_accelerate"] = rule("surf_air_accelerate")
	return out


## The mode a client is told is being played, for its banner and its keys. A client's own
## [member mode] is whatever it was built with and is never replaced — logic reads it —
## so what it shows comes from here. On the authority it is the mode.
var shown_mode: ArenaMode = null


func displayed_mode() -> ArenaMode:
	return shown_mode if shown_mode != null else mode


## Tells clients which mode this is, by its index in the catalogue they share. Server side.
func _announce_mode() -> void:
	if is_authority and mode != null:
		var index := ArenaModes.ids().find(mode.id)
		if index >= 0:
			set_movement_rules({"mode_index": index})


## A presentation rule's current value: the server's, or the default.
func rule(key: String) -> float:
	return float(movement_rules.get(key, SHOW_DEFAULTS.get(key, 0.0)))


## The fall a death gets: dot-player-char's reaction rule over the server's weights, seeded from
## the victim and the tick. Server side; the bridge sends it on KILL and every client draws it.
##
## The direction is the shot's; a death with none (a fall, a slay) is pushed by nothing. The
## killing weapon's def is what lets the sniper and the launcher throw a body
## (zee-dot-weapons' `params.death_reaction`).
func decide_death(entity_id: int, damage: DotDamage) -> DotPlayerDeath:
	if _weapon_defs.is_empty():
		_weapon_defs = ArenaContent.weapon_table()
	var def: Object = _weapon_defs.get(damage.weapon_id)
	var direction := damage.direction
	if direction.length_squared() < 0.0001 and damage.attacker != 0 and damage.attacker != entity_id:
		var killer := player_for(damage.attacker)
		var victim := player_for(entity_id)
		if killer != null and victim != null:
			direction = victim.controller.state.position - killer.controller.state.position
	direction.y = clampf(direction.y, -0.4, 0.4)
	return DotPlayerDeath.decide(
		ragdoll_rules.reactions(), damage.is_headshot(), damage.amount, direction,
		DotPlayerDeath.seed_of(entity_id, _tick), def
	)


## How a body comes apart on death under the current rules.
func break_rules() -> DotPlayerBreakRules:
	var rules := DotPlayerBreakRules.new()
	rules.mode = clampi(int(rule("break_mode")), 0, 2) as DotPlayerBreakRules.Mode
	rules.limbs = maxi(int(rule("break_limbs")), 1)
	rules.criticals_only = rule("break_criticals_only") != 0.0
	return rules


func player_for(id: int) -> ArenaPlayer:
	return _players.get(id)


## The standing hulls player [param id] stops at: every other living player's, where they
## stand now; none while `mp_solidplayers` is 0. Asked per sweep by the movement body, so a
## player moved earlier in this tick is met where it moved to (the same on every machine:
## players tick in one order).
func solid_hulls_for(id: int) -> Array:
	var out: Array = []
	if not body_rules.solid:
		return out
	for key: Variant in _players.keys():
		if int(key) == id:
			continue
		var other: ArenaPlayer = _players[key]
		if other == null or not other.is_alive() or other.controller == null or other.controller.state == null:
			continue
		var tunables := other.controller.tunables
		out.append(ArenaSolidBody.hull_at(other.controller.state.position, tunables.stand_height, tunables.radius))
	return out


func players() -> Array[ArenaPlayer]:
	var out: Array[ArenaPlayer] = []
	for key in _players.keys():
		out.append(_players[key])
	return out


func player_ids() -> Array[int]:
	var out: Array[int] = []
	for key in _players.keys():
		out.append(int(key))
	out.sort()
	return out


## Applies a player's saved loadout. Falls back to the default on any failure.
##
## A failure here must never stop a player spawning: an unreachable loadout store is a
## reason to give them a rifle, not a reason to leave them watching.
func apply_loadout(id: int) -> void:
	var player := player_for(id)

	if player == null:
		return

	var res: DotResult = await loadouts.active_for(_loadout_key(id))

	if not res.ok:
		DotLog.debug(CHANNEL, "loadout unavailable, using the default", {
			"player": id, "error": str(res.error)
		})
		player.give_default_loadout()
		arm_for_mode(player)
		return

	player.give_loadout(ArenaContent.in_give_order(loadouts.resolve(res.value)))
	arm_for_mode(player)


## What the mode says a player carries, over whatever their loadout gave them: gun game's
## weapon at their score, or the mode's pool. Authority side; the arsenal replicates.
func arm_for_mode(player: ArenaPlayer) -> void:
	if player == null or mode == null or not mode.arms_players() or not player.is_alive():
		return

	var catalogue := player.arsenal.catalogue
	var give: Array[StringName] = []

	if not mode.gun_game.is_empty():
		var record := match_node.scoreboard.find(str(player.player_id)) if match_node != null else null
		var level := clampi(record.score if record != null else 0, 0, mode.gun_game.size() - 1)
		give.append(StringName(mode.gun_game[level]))
	else:
		var pool := mode.pool_ids(catalogue)
		if mode.pool_random and not pool.is_empty():
			var rng := RandomNumberGenerator.new()
			rng.seed = player.player_id * 7919 + _tick
			give.append(pool[rng.randi_range(0, pool.size() - 1)])
		else:
			give = pool

	player.arsenal.clear()
	var hand := 0
	for id in give:
		if catalogue.has(id) and player.arsenal.give(id).ok:
			# The heaviest gun, never the grenade: the loadout's own rule.
			hand = ArenaPlayer._better_hand(hand, catalogue.get_def(id).slot)
	if mode.pool_keeps_melee and not player.arsenal.has_slot(ZeeWeaponIds.SLOT_MELEE):
		var _knife := player.arsenal.give(ZeeWeaponIds.KNIFE)
	if hand > 0:
		player.arsenal.select(hand, player.controller.state.tick)


## A storage key that is usable as a filename.
##
## `DotLoadoutKey.is_usable` has a minimum length, so a bare session id of "7" is
## refused before any store sees it. Padding here rather than loosening the check: the
## check exists so a malformed key can never reach a filesystem path.
##
## [b]One key for every store, and that is deliberate.[/b] Loadouts, achievement
## progress and dot-stats' sessions are three subsystems that each want a durable
## per-player id, and three formats would be three chances for one of them to file
## under a name the others cannot find. It also refuses to be an account id: dot-stats'
## reporter rejects anything with a `backbone:` prefix before it leaves the server, and
## a key built from the session id can never carry one.
static func storage_key(id: int) -> String:
	return "arena-player-%08d" % id


func _loadout_key(id: int) -> String:
	return storage_key(id)


# --- Simulation ------------------------------------------------------------

## Advances the whole game one tick.
##
## [b]The order is the point of this method.[/b] Players simulate and produce shots;
## the shots are resolved against the world as it is *after* everyone has moved; the
## match's clock and win check run last, so a kill scored on this tick can end the
## round on this tick rather than the next one.
##
## [param commands] is `{player id: [DotFpsCommand, DotWeaponCommand]}`. A player with
## no entry repeats their last command, which is what a dropped input packet should
## look like.
## Records every player's position for this tick, for [method _unlag_rewind].
func _unlag_record() -> void:
	for id in _players:
		var player: ArenaPlayer = _players[id]
		var ring: Array = _unlag.get(id, [])
		if ring.is_empty():
			var positions := PackedVector3Array()
			positions.resize(UNLAG_HISTORY)
			var ticks := PackedInt32Array()
			ticks.resize(UNLAG_HISTORY)
			ticks.fill(-1)
			ring = [positions, ticks]
			_unlag[id] = ring
		# Packed arrays are values: taken out, written, and put back, or the write lands
		# on a copy and the history stays empty (it did, the first time).
		var positions: PackedVector3Array = ring[0]
		var ticks: PackedInt32Array = ring[1]
		var slot := _tick % UNLAG_HISTORY
		var before := (_tick - 1) % UNLAG_HISTORY
		# A respawn or a teleport: ten metres in one tick is 640 m/s at 64 ticks, which
		# nothing moves at. Rewinding across it would stand a player's hitboxes where they
		# died, or at the far end of a pit, so the history starts again from here.
		if ticks[before] == _tick - 1 and positions[before].distance_to(player.global_position) > 10.0:
			ticks.fill(-1)
		positions[slot] = player.global_position
		ticks[slot] = _tick
		ring[0] = positions
		ring[1] = ticks
		_unlag[id] = ring


## Where player [param id] was at [param at] (a fractional tick), between the two
## recorded ticks either side; null when the history does not reach that far.
func unlag_position_at(id: int, at: float) -> Variant:
	var ring: Array = _unlag.get(id, [])
	if ring.is_empty():
		return null
	var positions: PackedVector3Array = ring[0]
	var ticks: PackedInt32Array = ring[1]
	var lo := floori(at)
	var a := lo % UNLAG_HISTORY
	var b := (lo + 1) % UNLAG_HISTORY
	if ticks[a] != lo:
		return null
	if ticks[b] != lo + 1:
		return positions[a]
	return positions[a].lerp(positions[b], at - float(lo))


## dot-combat's rewind: every other living player, put where they were at [param view_tick].
func _unlag_rewind(view_tick: float) -> void:
	for id in _players:
		if id == _unlag_shooter:
			continue
		var player: ArenaPlayer = _players[id]
		if not player.is_alive():
			continue
		var then: Variant = unlag_position_at(id, view_tick)
		if then == null:
			continue
		_unlag_moved[id] = player.global_position
		player.global_position = then


## And back, after the trace.
func _unlag_restore() -> void:
	for id in _unlag_moved:
		var player: ArenaPlayer = _players.get(id)
		if player != null:
			player.global_position = _unlag_moved[id]
	_unlag_moved.clear()


func tick(commands: Dictionary = {}) -> void:
	_tick += 1
	_sync_round_freeze()

	var shots: Array[DotShot] = []
	var delta := 1.0 / float(tick_rate)

	for id in player_ids():
		var player: ArenaPlayer = _players[id]

		if not player.is_alive():
			continue

		var pair: Array = commands.get(id, [])
		var move: DotFpsCommand = pair[0] if pair.size() > 0 else DotFpsCommand.new()
		var fire: DotWeaponCommand = pair[1] if pair.size() > 1 else DotWeaponCommand.new()

		if move != null and fire != null:
			match_node.note_activity(str(id), _tick)
			if surf_rides != null:
				surf_rides.call(&"before", id, player)
			var outcome := player.simulate_tick(_tick, delta, move, fire)
			if surf_rides != null:
				surf_rides.call(&"after", id, player, move, _tick)
			shots.append_array(outcome.shots)

			# Heard by the monsters. Before the horde ticks, so they hear it this tick.
			if horde != null and (not outcome.shots.is_empty() or not outcome.spawns.is_empty()):
				horde.note_fire(id, player.controller.state.position)
			# A rocket is not a shot and is not resolved here; it is launched and
			# flown. See ArenaProjectiles for why that is a new file.
			if projectiles != null:
				projectiles.accept(outcome)

	# The toys after everybody moved: a walk into a ball sends it on. Then every shot that
	# passes one pushes it, before the combat resolves the shot, which a toy never stops.
	if is_authority:
		_advance_toys(delta)
		_shoot_toys(shots)

	if is_authority:
		_unlag_record()
		for shot in shots:
			# Traced against the other players where the shooter saw them: the command
			# that fired carries how far behind its tick the client was drawing (-1 from
			# a local player or a bot, who see the present, and nothing is rewound).
			var pair: Array = commands.get(shot.attacker, [])
			var lag: float = float(pair[2]) if pair.size() > 2 else -1.0
			_unlag_shooter = shot.attacker
			combat.resolve_shot(shot, float(_tick) - lag if lag >= 0.0 else -1.0)

	# After the shots, before everything that can end the round: a hurt volume that kills
	# somebody is a death the win check below has to count this tick.
	if is_authority:
		_hurt_from_map()

	# After the shots and before the match, and the position in the order is the
	# reason this is not two lines somewhere else. A monster has to perceive where the
	# players ended the tick, and a monster killed by a shot resolved above has to be
	# reported dead before the match's win check runs — otherwise its death is counted
	# on the following tick, which at a score limit is one round decided late.
	# Before the props and after the shots: a rocket that arrives this tick has to kill
	# before the match's win check runs, for the same reason everything below is
	# ordered the way it is.
	if projectiles != null:
		projectiles.tick(delta)

	if props != null:
		props.tick(delta)

	if horde != null:
		horde.tick(delta)

	# After the shots and before the match, for the same reason the two above are:
	# a burn that kills somebody has to be reported dead before the win check runs, and
	# an objective completed this tick has to be scored before it. An objective layer
	# ticked after the match is one round decided late, every time.
	if effects != null:
		effects.tick(delta)

	if objectives != null:
		objectives.tick(delta)

	if spectate != null:
		spectate.tick(delta)

	# Before the match, like everything above it, and for a different reason: the stack
	# expires spawn protection, and a player whose protection ran out on this tick has
	# to be killable by a shot the match is about to count.
	if player_stack != null:
		player_stack.tick(_tick)

	# After everybody has moved and before the match: a coin is taken where its taker
	# ended the tick, and a heal from a pack lands before a shot next tick can be fatal.
	if drops != null and is_authority:
		var sweepers := {}
		for id in player_ids():
			var p: ArenaPlayer = _players[id]
			if p.is_alive():
				sweepers[id] = {
					"position": p.controller.state.position,
					"hurt": p.health.health < p.health.max_health,
					"heal": func(amount: float) -> void: var _h := p.health.heal(amount),
					"needs_ammo": p.needs_ammo(),
					"ammo": func(share: float) -> void: p.refill_ammo(share),
				}
		drops.tick(_tick, sweepers)

	_sweep_jail_button()

	match_node.tick(_tick)

	if surf_rides != null:
		surf_rides.call(&"process", delta)


func current_tick() -> int:
	return _tick


## Records the surf rides real players take (`arena_surf_rides.gd`), off unless `bot_record` is on in the config, environment, command line or console; a no-op on a shell without dot-bot's recorder.
func start_ride_recording(add_cvar: Callable = Callable(), config_file: String = "user://bot_record.json") -> DotResult:
	if surf_rides != null:
		return DotResult.success(surf_rides)
	if DotAddonApi.build_level("dot_bot") < 5 or DotAddonApi.build_level("dot_player_controller") < 3 \
			or not ResourceLoader.exists("res://addons/dot_bot/runtime/surf/dot_bot_ride_harvest.gd"):
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "This shell has no ride recorder.")
	var config := DotBotDemoConfig.new()
	config.record = false
	var layered := config.load_layered(config_file if FileAccess.file_exists(config_file) else "")
	if not layered.ok:
		return layered
	if add_cvar.is_valid():
		var _cvars := config.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY)
	var made := DotBotDemoStore.from_config(config, null)
	if not made.ok or made.value == null:
		return made if not made.ok else DotResult.fail(DotError.CODE_STATE, "bot_record_store is off.")
	var store: DotBotDemoStore = made.value
	var opened := store.open()
	if not opened.ok:
		return opened
	var rides: RefCounted = (load(ArenaPaths.rebase("res://game/arena_surf_rides.gd")) as GDScript).new()
	var ready: DotResult = rides.call(&"setup", self, config, store, float(tick_rate))
	if not ready.ok:
		return ready
	surf_rides = rides
	return DotResult.success(rides)


## Deals an imported map's hurt volumes (`trigger_hurt`) to everybody standing in one, as
## world damage through dot-combat.
##
## [b]Real damage, where game-g2gfast's is "100 or more is a death, the rest ignored"[/b],
## because a timer run has no health and this game does. The engine these maps come from
## reads the volume's `damage` as per second and deals it every half second, the first
## pulse on entering; this does the same, through [method DotCombatManager.apply_damage]
## with attacker 0, so the resolver, armour (the world type ignores it), spawn protection,
## the kill feed, the scoreboard and the statistics all hear it as they hear a fall. A
## negative amount heals, as it does there (surf_forbidden_ways_reloaded has one).
##
## On the authority only: health is the server's and replicates, so a client predicting a
## hurt would only be corrected. Its movement half (where the player is) is already
## predicted, which is all this reads.
func _hurt_from_map() -> void:
	if map == null or map.mechanics == null or map.mechanics.hurt.is_empty():
		return

	var interval := maxi(1, roundi(ArenaMap.ArenaMapMechanics.HURT_INTERVAL * float(tick_rate)))

	# Due ticks are per player AND per volume, and kept when the player steps out: the
	# half second belongs to the volume, so a hull bobbing across a thin sheet's edge (a
	# hop, water) takes one pulse per interval rather than one per re-entry. An entry whose
	# tick has passed means the same as none, so those go, and the table stays small.
	for key: Vector2i in _hurt_due.keys():
		if int(_hurt_due[key]) <= _tick:
			var _gone: bool = _hurt_due.erase(key)

	for id in player_ids():
		var player: ArenaPlayer = _players[id]
		var state := player.controller.state
		if not player.is_alive() or state.mode == DotFpsState.Mode.NOCLIP:
			continue

		for i in map.mechanics.hurts_at(state.position, player.controller.tunables, state.crouch_fraction):
			var key := Vector2i(id, i)
			if _hurt_due.has(key):
				continue
			_hurt_due[key] = _tick + interval

			var amount := float(map.mechanics.hurt[i]["damage"]) * ArenaMap.ArenaMapMechanics.HURT_INTERVAL
			if amount < 0.0:
				var _healed := player.health.heal(-amount)
				continue
			if amount == 0.0 or not player.is_alive():
				continue

			var damage := DotDamage.make(0, id, amount, combat.damage_type(ArenaContent.DAMAGE_WORLD))
			damage.tick = _tick
			var _dealt := combat.apply_damage(damage)


# --- Events ----------------------------------------------------------------

## Whether [param entity_id] may be hurt now. False only for a player whose client is behind
## its loading cover (frozen by its own client, unable to see); a monster, a bot or a game
## with no [member loading_fn] is always harmable, so every offline suite is unchanged.
func can_be_harmed(entity_id: int) -> bool:
	if not loading_fn.is_valid():
		return true
	return not bool(loading_fn.call(entity_id))


func _on_entity_killed(entity_id: int, damage: DotDamage) -> void:
	var victim := player_for(entity_id)

	if victim == null:
		# Not a player. Something else registered with the combat manager, and the
		# match must not hear about it — see `non_player_killed`.
		non_player_killed.emit(entity_id, damage)
		return

	victim.make_dead()

	# An attacker of 0 is world damage — a fall, the void — and dot-match reads an
	# empty killer key as exactly that. Passing "0" instead would create a scoreboard
	# record for a player who does not exist.
	var killer_key := "" if damage.attacker == 0 else str(damage.attacker)

	var entry := match_node.report_kill(
		killer_key,
		str(entity_id),
		damage.weapon_id if damage.weapon_id != &"" else damage.type.id,
		_tick,
		damage.is_headshot()
	)
	# dot-match's entry has no field for it; the bridge reads it to tell every client a
	# lethal critical happened, which is what breaks a body and what a reward hangs on.
	entry.set_meta(&"critical", damage.critical)
	# How the body falls, picked once, here, and sent with the kill (see `decide_death`).
	if is_authority:
		entry.set_meta(&"death", decide_death(entity_id, damage))

	# The medals, before the streaks move: a shutdown is judged on the streak the victim
	# died with. Emitted after `player_killed`, so a client hears the kill first.
	var awarded: Array[int] = []
	var judged := false
	if is_authority:
		judged = true
		if damage.attacker == 0 or damage.attacker == entity_id or player_for(damage.attacker) == null:
			medals.note_death(entity_id)
		else:
			awarded = medals.judge(_kill_facts(damage, victim, entry))

	# The streaks: the victim's ends, the killer's grows, and a reward lands on the kill
	# that reaches it.
	streaks[entity_id] = 0
	if is_authority and damage.attacker != 0 and damage.attacker != entity_id:
		var streak := int(streaks.get(damage.attacker, 0)) + 1
		streaks[damage.attacker] = streak
		if streak_rewards.has(streak):
			_reward_streak(damage.attacker, streak, String(streak_rewards[streak]))

	# Gun game: the killer's score just went up, so their weapon moves along the list.
	if is_authority and mode != null and not mode.gun_game.is_empty() and damage.attacker != 0:
		var killer_player := player_for(damage.attacker)
		if killer_player != null and killer_player != victim:
			arm_for_mode(killer_player)
			_demote_for_melee(damage, killer_player)

	# Coins out of the body, if the rules say this kill drops any.
	if drops != null and is_authority:
		var _n := drops.on_kill(
			victim.controller.state.position, damage.critical, _tick, entity_id * 7919 + _tick
		)

	player_killed.emit(entry)

	if judged and damage.attacker != 0 and damage.attacker != entity_id and player_for(damage.attacker) != null:
		medals_awarded.emit(
			damage.attacker, entity_id, awarded, ArenaAwards.points_for(awarded),
			int(streaks.get(damage.attacker, 0))
		)


## What the medal rules are told about a kill: all of it read off the simulation.
func _kill_facts(damage: DotDamage, victim: ArenaPlayer, entry: DotKillFeed.Entry) -> ArenaAwards.KillFacts:
	var killer := player_for(damage.attacker)
	var k := ArenaAwards.KillFacts.new()
	k.killer = damage.attacker
	k.victim = victim.player_id
	k.tick = _tick
	k.tick_rate = tick_rate
	k.headshot = damage.is_headshot()
	k.victim_streak = int(streaks.get(victim.player_id, 0))
	k.team_kill = entry.team_kill
	# Eye to eye from the simulated states, never `damage.distance`: a detonation pins the
	# attacker's origin to the blast, so a rocket's distance is the blast's, not the throw's.
	k.distance = killer.controller.state.position.distance_to(victim.controller.state.position)
	k.aiming = killer.aiming
	var weapon := damage.weapon_id
	var def := ArenaPlayer.weapon_catalogue().get_def(weapon) if weapon != &"" else null
	if def != null:
		k.tags = Array(def.tags)
	elif weapon == &"":
		# Not a weapon at all (a world hazard pushed by somebody): no range medals.
		k.tags = [ZeeWeaponIds.TAG_THROWN]
	return k


## Gun game: a melee kill costs the victim a gun ([member ArenaMode.gun_game_melee_demotes]).
##
## The level IS the score, so this is a point off the victim's record and nothing else:
## [method arm_for_mode] reads the score at their respawn and hands them the gun before.
## Never below zero, because a negative score would be a level the list has no gun for
## and a scoreboard showing a player behind where they started.
func _demote_for_melee(damage: DotDamage, killer: ArenaPlayer) -> void:
	if not mode.gun_game_melee_demotes or killer.arsenal == null:
		return

	var weapon_id := damage.weapon_id
	if weapon_id == &"":
		return
	var def := killer.arsenal.catalogue.get_def(weapon_id)
	if def == null or not def.tags.has(ZeeWeaponIds.TAG_MELEE):
		return

	var record := match_node.scoreboard.find(str(damage.victim))
	if record == null or record.score <= 0:
		return

	record.score -= 1
	match_node.scoreboard.score_changed.emit(record)


func _on_damage_applied(damage: DotDamage) -> void:
	# The hit marker's source, for anything a player hurt that is not themselves. Before
	# the scoreboard's filter, because a monster hit is a hit too.
	if (
		is_authority and damage.attacker != 0 and damage.attacker != damage.victim
		and player_for(damage.attacker) != null
	):
		var taken := damage.health_lost + damage.armour_absorbed
		if taken > 0.0:
			# Damage applied without a trace (a blast, a hazard) has no point; a player's
			# chest is where its number rises from then.
			var at := damage.point
			var hurt := player_for(damage.victim)
			if at == Vector3.ZERO and hurt != null:
				at = hurt.controller.state.position + Vector3(0.0, 1.3, 0.0)
			hit_confirmed.emit(
				damage.attacker, damage.victim, taken, at, damage.is_headshot(), damage.lethal
			)

	# Only players are on the scoreboard. Damage to or from anything else a game
	# layer registered with dot-combat — a monster, a breakable — would otherwise
	# create a record keyed on an id no player has, for the same reason
	# `non_player_killed` exists.
	if player_for(damage.victim) == null:
		return

	var attacker := (
		str(damage.attacker) if player_for(damage.attacker) != null else ""
	)

	match_node.report_damage(attacker, str(damage.victim), damage.health_lost)


## Whether the round is waiting to go live with everyone held still. The client reads the
## state MATCH told it; a countdown only exists when its length is above zero.
func round_frozen() -> bool:
	return match_node != null and match_node.state == DotMatch.State.COUNTDOWN \
			and match_node.rules != null and match_node.rules.freeze_during_countdown


## Holds every living player still, unarmed and unhurtable while [method round_frozen], and
## lets exactly those go afterwards; an admin's own freeze or god mode is left alone.
func _sync_round_freeze() -> void:
	var want := round_frozen()
	for id in player_ids():
		var player: ArenaPlayer = _players[id]
		if want and player.is_alive():
			_freeze_for_round(id, player)
		elif _round_frozen_ids.has(id):
			_release_from_round(id, player)


func _freeze_for_round(id: int, player: ArenaPlayer) -> void:
	if _round_frozen_ids.has(id) or DotFpsAdminModifiers.is_frozen(player.controller):
		return
	var held := {"god": player.health.invulnerable}
	_round_frozen_ids[id] = held
	player.health.invulnerable = true
	player.arsenal.disabled = true
	var _r := DotFpsAdminModifiers.set_frozen(player.controller, true)


func _release_from_round(id: int, player: ArenaPlayer) -> void:
	var held: Dictionary = _round_frozen_ids[id]
	_round_frozen_ids.erase(id)
	player.health.invulnerable = bool(held["god"])
	player.arsenal.disabled = false
	var _r := DotFpsAdminModifiers.set_frozen(player.controller, false)


func _on_respawn_due(key: String, spawn: DotSpawnPoint, tick: int) -> void:
	var id := int(key)
	var player := player_for(id)

	if player == null:
		return

	# [b]The director chooses; dot-match's point is the fallback.[/b] Both read the same
	# markers — `ArenaPlayerStack.refresh_spawns` copies dot-match's own `DotSpawnPoint`s
	# into the director — so this is not a second set of spawns, it is a better choice
	# among one set: enemy distance, line of sight, occupancy and a per-site cooldown,
	# none of which dot-match models.
	#
	# It is also where spawn protection is granted, which is the half that has to go
	# through here. `DotSpawnProtection.grant` is called inside `choose` and nowhere
	# else, so a game that took dot-match's point and skipped this has an empty ledger
	# and a `protection.advance()` that does nothing — which is what this one had.
	var at := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))

	if spawn != null:
		at = spawn.spawn_transform()

	if player_stack != null:
		var chosen := player_stack.choose_spawn(id)

		if chosen.ok:
			at = (chosen.value as DotSpawnChoice).transform
		elif spawn == null:
			# No point from either. Worth a line: the fallback below is the origin, and
			# a player standing at (0, 1, 0) on every respawn is a map with no usable
			# spawns rather than a player who found a strange corner.
			DotLog.warn(CHANNEL, "nothing chose a spawn", {
				"key": key, "why": chosen.error.message
			})

	player.hitboxes.enabled = true
	player.spawn(at, tick, match_node.spawn_protection_ticks())
	if _round_frozen_ids.has(id):
		_release_from_round(id, player)
	_sync_round_freeze()

	# [b]`ArenaEffects.on_spawn` was written, documented, and called by nothing.[/b] It
	# clears what survived the last life, stands the player up, and applies `PROTECTED` —
	# so until this line the arena's own spawn-protection effect had never been applied
	# to anybody, and a player who died burning respawned still burning. The family's
	# "a value produced correctly and consumed by nothing", for the third time in this
	# one respawn path.
	if effects != null:
		effects.on_spawn(id)

	_apply_loadout_deferred(id)

	player_spawned.emit(player)


## Puts a player back into the world now, alive, at a spawn the director chooses.
##
## An administrator's respawn, and the same path a queued respawn takes — so a player an
## admin put back gets the director's spawn choice, spawn protection, a cleared effect
## set and their loadout, exactly like one the match put back. Anything still queued for
## them is cancelled first, or the queue would respawn them a second time moments later.
func respawn_player(id: int) -> DotResult:
	var player := player_for(id)

	if player == null:
		return DotResult.fail(DotError.CODE_INVALID, "Player %d is not in the match." % id)

	var key := str(id)

	if match_node.respawns != null:
		match_node.respawns.cancel(key)

	_on_respawn_due(key, match_node.choose_spawn(key, _tick), _tick)
	return DotResult.success(player)


## Loadouts come from a store, which may be slow. A respawn may not be.
##
## The player is already in the world with whatever they had; the loadout arrives a
## frame or two later. Awaiting it inside the respawn handler would make every spawn
## wait on a disk or a network round trip.
func _apply_loadout_deferred(id: int) -> void:
	var player := player_for(id)

	if player == null:
		return

	if player.arsenal.slots().is_empty():
		# The class's loadout first: `DotPlayerClassDef.loadout_id` is the field a mode
		# changes to change what everybody spawns holding, and it reached nothing until
		# this line. The hardcoded pair below is the fallback for a game with no
		# catalogue, which is what `give_default_loadout` always was.
		var from_class := (
			player_stack != null and player_stack.give_class_loadout(player)
		)

		if from_class:
			player.arsenal.select(ArenaContent.DEFAULT_SLOT, player.controller.state.tick)
		else:
			player.give_default_loadout()

	apply_loadout(id)


func _on_match_state_changed(from: DotMatch.State, to: DotMatch.State) -> void:
	# A new round has its own first blood, and nobody's revenge carries over from warmup.
	if to == DotMatch.State.LIVE:
		medals.reset_round()
		# And every toy home: a ball parked in a doorway during warmup is not a round's
		# head start for anybody.
		if toys != null and is_authority:
			toys.reset()
	match_state_changed.emit(from, to)


# --- Toys --------------------------------------------------------------------

## A toy's blast at its centre, m/s to a toy of up to 3 kg (dot-props' `blast`).
const TOY_BLAST_SPEED := 12.0


## The map's toys from [member ArenaMap.toys], on both ends, in the order the map lists them:
## that order is how a client pairs each with the server's entity. A headless authority gets
## a collision copy of a built-in level for them to land on; an imported map's solid is in the
## physics space already, and a drawing end's level is its scene.
func _build_toys() -> void:
	_clear_toys()
	if map == null:
		return
	var layout: DotPhysicsLayout = player_stack.physics.layout if player_stack != null and player_stack.physics != null else null

	if is_authority and headless and not map.is_imported() and not map.toys.is_empty():
		_toy_level = map.to_collision()
		_toy_level.name = "ToyLevel"
		add_child(_toy_level)
		if player_stack != null:
			var _n := player_stack.classify_tree(_toy_level, &"world")

	toys = DotPropToyBox.new()
	toys.name = "Toys"
	toys.authoritative = is_authority
	toys.draw = not headless
	toys.rules = toy_rules
	toys.gravity = 20.0
	toys.kill_y = map.floor_y - 40.0
	if layout != null:
		toys.loose_layer = layout.layer_mask(&"toy")
		toys.loose_mask = layout.collision_mask(&"toy")
		toys.solid_layer = layout.layer_mask(&"prop")
		toys.solid_mask = layout.collision_mask(&"prop")
		toys.footprint_layer = layout.layer_mask(&"footprint")
		toys.aim_mask = layout.mask_of([&"world", &"toy"] as Array[StringName])
	add_child(toys)
	var built := toys.build(map.toys)
	if not built.ok:
		DotLog.warn(CHANNEL, "a map's toys would not build", {"map": String(map.id), "why": built.error.message})
	var _sounds := toys.sound.connect(func(id: StringName, at: Vector3, strength: float) -> void: toy_sound.emit(id, at, strength))

	if projectiles != null and is_authority and not projectiles.detonated.is_connected(_on_detonated_near_toys):
		projectiles.detonated.connect(_on_detonated_near_toys)

	toys_built.emit()


func _clear_toys() -> void:
	if toys != null:
		toys_clearing.emit()
		remove_child(toys)
		toys.queue_free()
		toys = null
	if _toy_level != null and is_instance_valid(_toy_level):
		remove_child(_toy_level)
		_toy_level.queue_free()
	_toy_level = null


## Everybody against the toys this tick, after they moved: a walk into a ball pushes it, then
## the box's own tick (the awake cap, the lost sent home). Authority only.
func _advance_toys(delta: float) -> void:
	if toys == null or toys.count() == 0:
		return
	for id in player_ids():
		var player: ArenaPlayer = _players[id]
		if not player.is_alive():
			continue
		var state := player.controller.state
		var tunables := player.controller.tunables
		var radius := tunables.radius if tunables != null else 0.35
		var height := lerpf(tunables.stand_height, tunables.crouch_height, state.crouch_fraction) if tunables != null else 1.8
		var _pushed := toys.push_from(state.position, state.velocity, radius, height)
	toys.advance(delta)


## Every shot this tick against the toys: the first toy along each pellet, nearer than any wall,
## is pushed by dot-props' `shot`. [b]The shot goes on[/b]: the combat resolves it against the
## level and the players as if the toy were not there, so a ball is never cover and never eats
## a bullet meant for somebody behind it. Authority only.
func _shoot_toys(shots: Array[DotShot]) -> void:
	# shot_along arrived at dot-props level 6; an older checkout has no such method.
	if toys == null or toys.count() == 0 or shots.is_empty() or DotAddonApi.build_level("dot_props") < 6:
		return
	var layout: DotPhysicsLayout = player_stack.physics.layout if player_stack != null and player_stack.physics != null else null
	var level := layout.layer_mask(&"world") if layout != null else 1
	for shot in shots:
		var directions: Array = shot.pellets if not shot.pellets.is_empty() else [shot.direction]
		# Each pellet carries the shot's damage, as dot-combat resolves them.
		for raw: Variant in directions:
			var _pushed := toys.shot_along(shot.origin, raw as Vector3, maxf(shot.max_range, 1.0), shot.damage, level)


func _on_detonated_near_toys(at: Vector3, spawn: DotWeaponSpawn) -> void:
	if toys != null and is_authority and spawn != null:
		var _thrown := toys.blast(at, maxf(spawn.splash_radius, 2.0), TOY_BLAST_SPEED)


# --- Diagnostics -----------------------------------------------------------

func describe() -> Dictionary:
	return {
		"tick": _tick,
		"map": map.describe() if map != null else {},
		"players": _players.size(),
		"match": match_node.describe() if match_node != null else {},
		"combat": combat.describe() if combat != null else {},
		"progress": progress.describe() if progress != null else {},
		"horde": horde.describe() if horde != null else {},
		"props": props.describe() if props != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("arena    %s  tick %d" % [map.display_name if map != null else "?", _tick])
	out.append_array(match_node.describe_lines())
	out.append_array(combat.describe_lines())

	if progress != null:
		out.append_array(progress.describe_lines())

	if horde != null:
		out.append_array(horde.describe_lines())

	if props != null:
		out.append_array(props.describe_lines())

	return out
