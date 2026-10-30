extends Node

const ArenaAvatars := preload("arena_avatars.gd")
const ArenaViewArms := preload("arena_view_arms.gd")
const ArenaBindings := preload("arena_bindings.gd")
const ArenaBots := preload("arena_bots.gd")
const ArenaBrowser := preload("arena_browser.gd")
const ArenaClientExtras := preload("arena_client_extras.gd")
const ArenaEvents := preload("arena_events.gd")
const ArenaWeaponSkins := preload("arena_weapon_skins.gd")
const ArenaFrameProbe := preload("arena_frame_probe.gd")
const ArenaGame := preload("arena_game.gd")
const ArenaHud := preload("arena_hud.gd")
const ArenaHudGlance := preload("arena_hud_glance.gd")
const ArenaKillcamBodies := preload("arena_killcam_bodies.gd")
const ArenaConfig := preload("arena_config.gd")
const ArenaContent := preload("arena_content.gd")
const ArenaMode := preload("arena_mode.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMapLighting := preload("../maps/arena_map_lighting.gd")
const ArenaMenus := preload("arena_menus.gd")
const ArenaMaps := preload("arena_maps.gd")
const ArenaModes := preload("arena_modes.gd")
const ArenaNetBridge := preload("arena_net_bridge.gd")
const ArenaPaths := preload("arena_paths.gd")
const ArenaProjectileView := preload("arena_projectile_view.gd")
const ArenaPlayer := preload("arena_player.gd")
const ArenaPresentation := preload("arena_presentation.gd")
const ArenaWeaponIcons := preload("arena_weapon_icons.gd")
const ArenaSpriteWeapon := preload("arena_sprite_weapon.gd")

## A playable game-arena: one local player, a camera, a HUD, menus and the keys.
##
## [b]Separate from [ArenaGame], which is the simulation and runs headless.[/b] A
## dedicated server never loads this. That split is the reason `headless_match` can play
## a whole deathmatch with no renderer and no window, and it is the reason this file is
## the only one in the project that mentions a `Camera3D` or an `InputEvent`.
##
## Until this existed, game-arena was the reference game with nothing to sit down at:
## `ArenaNetBridge` ran, `headless_net` drove it, and there was no camera rig, no input
## sampling, no renderer and no sound. Everything here is modelled on `G2GClient`,
## which is the one in this family proven over a real socket and in a browser.
##
## [codeblock]
## WASD          move                Space   jump (hold; auto-hop is on)
## Ctrl          crouch              Mouse1  fire
## R             reload              1..4    weapon slots  (wheel cycles)
## Tab (hold)    scoreboard          Esc     release the mouse, then the menu
## H             help
## [/codeblock]

const CHANNEL := "arena.client"

## The player pressed Leave on the Escape menu.
##
## [b]Announced, and acted on by dot-menu's stock Leave[/b] ([member DotMenu.leave_on_its_own],
## set in [ArenaMenus]): connected, it disconnects the client link, and the shell that loaded
## this client goes back to its own menu on the disconnect; solo on a desktop it quits. This
## signal is for an embedder that wants to know. Until 2026-10-11 nothing listened to it and
## the button did nothing.
signal leave_requested()

## The level and the local player's camera exist, so the frame shows the game and not an
## empty room. A shell that knows the contract (dot-server-deploy's `_watch_game_ready`)
## keeps its loading screen up until this, then draws every material once under it so the
## shaders compile there rather than at the first shot; see [method warm_up_items]. Emitted
## again after each map change. Nothing here depends on anyone listening.
signal ready_to_show()

## dot-game's platform layer: the load gate and its cover (held until the level, the local
## body and the camera exist, then the weapon materials drawn once under it), the browser
## filesystem flush, and [signal DotGameClient.input_blocked_changed] for the sampler. Not its
## settings, menu, console, pointer or board: arena's are [ArenaMenus] and
## [ArenaPresentation], see [method _build_platform]. The root keeps `ready_to_show` and
## `warm_up_items` only because it declares its own signal (the gate then leaves it alone) and
## because a shell older than the gate asks the root's methods, not the gate.
var platform: DotGameClient = null
var gate: DotLoadGate

## Field of view, horizontal at 4:3. An arena shooter's number, not Godot's.
const FIELD_OF_VIEW := 100.0

var game: ArenaGame = null
var player: ArenaPlayer = null
var hud: ArenaHud = null
## The Escape menu, its pages and the Tab board: dot-menu's ([ArenaMenus]).
var game_menu: DotMenu = null
## The Tab board's rows from dot-match. See [ArenaMenus.Board].
var board: ArenaMenus.Board = null
## The match summary opened the Tab board (rather than a held Tab), so the client closes it.
var _summary_board_open: bool = false
## The final killcam ([DotKillcamHost]): records every frame, plays before the summary.
var killcam: DotKillcamHost = null

## The kill view: the killer's replayed eye, in place of the death camera ([DotKillViewClient]).
var killview: DotKillViewClient = null

## Solo only: the server half of the kill view, run in this process (a connected game has the bridge's).
var solo_killview: DotKillViewServer = null
var winner_reveal: DotWinnerReveal = null
var _reveal_hid: Dictionary = {}
var _seen_match_state: int = -1
## Applies dot-menu's stock settings this game does not apply itself: the window, V-Sync,
## the frame cap and render scale.
var applier: DotMenuApplier = null
var net: DotNetManager = null
var bridge: ArenaNetBridge = null
var link: Node = null

## Chat, voice and map changes: the client halves of what [ArenaServices] and
## [ArenaMapDirector] run on the server.
##
## [b]Null offline, deliberately.[/b] All three are about a server that is telling this
## client something, and an offline game has nobody to be told by. Building them anyway
## would open a microphone in a single-player match.
var extras: ArenaClientExtras = null

## Play alone even when a link is available. `--offline`.
@export var force_offline: bool = false

## How many bots to add when playing offline. Zero is an empty arena. `bot_quota` at the
## console changes it while playing (people + bots, as on a server); `-- --bots N` at launch.
@export_range(0, 15, 1) var offline_bots: int = 3

var _offline := true
var _solo_binder: DotGameConfigBinder = null
var _workbench: Node = null
## Asks a server whether this player may edit it (sv_workbench_remote); null offline.
var _workbench_remote: DotGameWorkbenchRemoteClient = null
## The profile rows the server broadcasts (an admin's edit reaches every client); null offline.
var _profile_link: DotNetProfileLink = null
var _profile_runtime: DotProfileRuntime = null
var _workbench_open := false
var _sampler: DotFpsSampler = null
## Refuses the sights for a moment after the local player is hit (sv_unscope_hit).
var _aim_break := DotFpsAimBreak.new()
var _hit_wobble_applied := Vector2.ZERO
## Degrees of a wall-run attach turn not yet applied to the view.
var _view_turn_left := 0.0
const VIEW_TURN_RATE := 22.0
var _fire := DotWeaponCommand.new()

## A weapon slot the player asked for this tick, or 0 for "no change". Cleared once
## sent — see [method _read_fire].
var _wanted_slot: int = 0
## The light on the eye and the other players' beams (dot-flashlight); the server owns on/off.
var flash: DotFlashlight = null
var flash_crowd: DotFlashlightCrowd = null
var _flash_ticks := 0
var _flash_msec := -100000

## What the server last said was left on the clock, in seconds. Negative for "no
## limit", which is what `DotMatch.seconds_remaining` returns and what the HUD reads as
## "show the state name instead".
var _match_seconds_remaining: float = -1.0

## Seconds since the last position report. See `_process`.
var _report_timer: float = 0.0

## Whether the cursor is waiting for a click before it can be captured. Web only.
var _awaiting_click := false

## Who [member player] should be, whether or not that player exists yet.
##
## [b]HELLO names you and JOIN creates you, in that order.[/b] A client that resolved
## the player here and never tried again holds null for the whole session — and the
## list of what that breaks is the interesting part: the HUD binds by id and works, the
## camera follows the entity and works, movement works because `DotFpsSampler.sample`
## polls the `InputMap` rather than reading events, and *everything below the
## `player == null` guard in `_unhandled_input` does not*. A client that connects,
## draws, shows a live HUD and walks around, with a dead mouse and a dead keyboard.
## g2gfast shipped exactly that and a person had to report it.
var _watch_id: int = -1

## The spectator's free camera while roaming, and the mouse motion not yet turned into a look.
var _free_cam: DotSpectatorFreeCam = null
var _roam_look: Vector2 = Vector2.ZERO

## Bots this client drives, offline only. Session id -> the bot's body.
var _bots: Dictionary = {}

## Their minds (ArenaBots.Mind), by session id: the same brain a server's bots run.
var _bot_minds: Dictionary = {}

## Names offline bots from dot-bot's pool, and keeps their number.
var _bot_roster := DotBotRoster.new()

## The next offline bot's session id.
var _next_bot_id: int = 100

## The meshes of the map currently drawn. Replaced on a map change.
var _level: Node3D = null
var _level_busy := false

## The map's sun and environment (`ArenaMapLighting.build`), replaced with the level.
var _lighting: Node3D = null

## dot-browser's client half, and the screen over it.
var browser: ArenaBrowser = null

## Settings, audio, effects and the console. Everything that belongs to the person at the
## keyboard rather than to the match.
var presentation: ArenaPresentation = null

## State of the load-gate warm-up, see [method _prewarm_tick]; empty when idle.
var _warm := {}

## Whether this client believes it is holding a prop.
##
## [b]A belief, not a fact, and the distinction is the whole reason props are not
## predicted.[/b] The server decides whether a grab happened; this is only what the
## next press of the same key should ask for. A rigid body's contact solver is not
## reproducible across machines, so a client that tracked a held prop's position
## locally would be corrected on every snapshot.
var _holding: bool = false

## The last `ArenaEvents.PropAct` a key asked the prop tool for, or -1. Noted before the
## request goes anywhere, so a suite with no server can see which key did what.
var last_prop_asked: int = -1

## The local player's hands, under their camera. Built on adoption.
var view_model: ZeeViewModel = null
var view_arms: Node3D = null
var _sprite_view: ArenaSpriteWeapon = null

## Every rocket and grenade in the air, drawn.
var projectile_view: ArenaProjectileView = null

## Where the dead lie: dot-player-char's ragdolls, built from each KILL's death (the server's
## pick) under [member ArenaGame.ragdoll_rules]. Client side.
var ragdolls: DotPlayerRagdolls = null

## The projectile layer whose detonations are being heard, so a new one is noticed.
var _heard_projectiles: RefCounted = null

## The slot in hand and the one before it, for Q. Read off the arsenal each tick, because
## the server decides what is in hand and a client that kept its own idea would switch
## "back" to a weapon the server already took away.
var _held_slot: int = 0
var _last_slot: int = 0
