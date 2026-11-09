@tool
extends Node3D

const Roles := preload("arena_weapon_roles.gd")
const ArenaFrameProbe := preload("arena_frame_probe.gd")
const ArenaHullGrid := preload("arena_hull_grid.gd")
const ArenaFlashlight := preload("arena_flashlight.gd")
const ArenaPlayerTunables := preload("arena_player_tunables.gd")
const ArenaAvatars := preload("arena_avatars.gd")
const ArenaContent := preload("arena_content.gd")
const ArenaKillPov := preload("arena_kill_pov.gd")
const TagRules := preload("arena_name_tag_rules.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaLadderMode := preload("../maps/arena_ladder_mode.gd")
const ArenaMapMechanics := preload("../maps/arena_map_mechanics.gd")
const ArenaSolidBody := preload("arena_solid_body.gd")
const ArenaWeaponIcons := preload("arena_weapon_icons.gd")
const ArenaSpriteWeapon := preload("arena_sprite_weapon.gd")
const ArenaRecoilView := preload("arena_recoil_view.gd")

## One player: movement, weapons, health and hitboxes, assembled. [b]This is the piece every one of
## the addons says belongs in the game.[/b] dot-player-controller does not know about dot-combat;
## dot-combat does not know about dot-match; none of them knows about the others' node layout.

const CHANNEL := "arena.player"

## Died. Carries the damage, so a caller has the killer and the weapon.
signal died(damage: DotDamage)

## Fired a shot. Before it is resolved, so a client can draw a tracer immediately.
signal used(outcome: DotWeaponOutcome)

## A beacon on this player sent out a ripple: once a second while it is on, and once the
## moment it comes on. Client side, from [method present]; the client plays the ping here.
signal beacon_pulsed(at: Vector3)

## Spawned or respawned.
signal spawned(at: Transform3D)

## How the collision and tracing backends are chosen.
enum Mode {
	## Analytic geometry from [ArenaMap]. A dedicated server, and every test. Not a degraded mode:
	## it is exact, it needs no physics space, and — the part that matters — it gives the same
	## answer on a client replaying a tick and a server that ran it.
	HEADLESS,
	## Godot physics. A client, and a listen server.
	PHYSICS,
}

@export_group("Identity")

## Stable id. A dot-server session id in a real deployment; an index in a test. The same value is
## the scoreboard key, the combat entity id and the damage attribution, which is what stops three id
## spaces having to be mapped onto each other at every seam.
@export var player_id: int = 0

@export var display_name: String = "Player"

@export var team: int = 0

var mode: Mode = Mode.HEADLESS

var controller: DotFpsController = null
var arsenal: DotWeaponArsenal = null
## Run as the player dies, while the arsenal still gives up its weapon; the game sets it.
var before_death: Callable = Callable()

## arena-weapons' rig over [member arsenal]: the bash, the view model, the shot effects
## and the replication counter. See [method _build_rig].
var weapons: AwWeaponRig = null

## The game's aim and hip-size numbers, handed to every rig built here; null keeps the addon's own.
var ads_rules: AwAdsRules = null

## Somebody else's gun, in their hand. Client side, on every player but the local one.
var held: AwWorldModel = null
var _held_sprite: ArenaSpriteWeapon = null

## What a MIRROR knows of this player's weapon: written from the snapshot by
## `ArenaPlayerNet`, read by [method _present_held]. A simulated player — the authority's,
## an offline bot — is read off its own rig instead, and leaves these alone.
var mirrored: bool = false
var mirror_weapon: StringName = &""
var mirror_fire_seq: int = 0
var mirror_fire_kind: int = 0
var mirror_switching: bool = false
var mirror_charge: float = 0.0
var mirror_reloading: bool = false
var _mode_click_audio: AudioStreamPlayer3D = null
var health: DotHealth = null
var hitboxes: DotHitboxSet = null

## Where the eyes are, and where shots start.
var view: Node3D = null

## The local player's camera. Null on a server, on a remote player, and headless.
var camera: Camera3D = null

## The view kick of the local player's shots, added to the camera only (see [ArenaRecoilView]).
var recoil_view := ArenaRecoilView.new()

## The view to draw this frame, (yaw, pitch) in degrees, or null for the simulated state's. Set
## every frame by the client from `DotFpsSampler.look_now()`. A frame with no tick in it would not
## turn: at 144 Hz against 64 ticks most frames have none (`headless_view`).
var view_now: Variant = null

## Added to where the local player is drawn this frame: what is left of the last
## prediction corrections, easing to zero (`DotNetPredictor.visual_offset`). Without it a
## correction moves the eye in one frame.
var drawn_offset: Vector3 = Vector3.ZERO

## How far through the current tick this frame is drawn (usually 0..1, -1 to 2 just after a slip),
## or NAN for the engine's physics fraction. Set every frame by a connected client from dot-net's
## `DotNetClock.render_alpha`.
var drawn_alpha: float = NAN

## Whether [method present] draws this body between its ticks: a player this machine simulates and
## somebody else watches -- an offline bot. Set by the client. An offline bot was drawn where its
## last tick left it and stood still on most frames at 144 Hz (`headless_feel`).
var interpolate_body: bool = false

## The yaw this player started its last tick with, for [member interpolate_body]: the
## controller's render state blends the position and leaves the angles at the tick's.
var _yaw_before_tick: float = 0.0

## Where this player was two ticks back, for a frame drawn before the controller's previous
## tick (a [member drawn_alpha] below 0, after a physics frame that ran two ticks). The
## controller keeps only its last two states. NAN until a tick has run since the last spawn.
var _position_two_back: Vector3 = Vector3(NAN, NAN, NAN)

## Whether this player is holding the aim (right mouse). Client side, presentation only:
## the view model eases the weapon up and the camera zooms; nothing the server simulates.
var aim_held: bool = false

## The aim, as the weapon command carries it to the server: [constant DotWeaponCommand.BUTTON_USER_0],
## which no addon reads. The client sets it beside [member aim_held]; it changes nothing
## the simulation does and exists for one medal, No Scope ([member aiming]).
const BUTTON_AIM := DotWeaponCommand.BUTTON_USER_0

## Whether the command this player last simulated held the aim. Both ends; the server's
## is what [code]ArenaAwards[/code] reads. A claim, like every button: a client can say
## it was not aiming when it was, which earns a medal and nothing else (docs/client.md).
var aiming: bool = false

## A bar over somebody else's head for a few seconds after they are hurt, the way the
## genre shows that a shot landed. Client side; built on first need.
var _health_tag: DotHealthTag = null
var _last_health: float = -1.0
var _hurt_age: float = 999.0
const HEALTH_TAG_SEC := 3.0

## The meshes a body break hid, so a respawn can draw them again. Client side.
var _broken: Array[MeshInstance3D] = []
var _severed: bool = false

## This player's body went down as a ragdoll (or was hidden by the server's style), so a
## respawn has to draw it again. Client side.
var _fell: bool = false

## Draws a box avatar's own body in first person ([method present_own_body]).
var _first_person: DotPlayerFirstPersonBody = null
## How much of your own body shows in first person (DotPlayerViewRules.BODY_*), from the client.
var own_body_mode: int = 0

## Third person: the camera behind and over the shoulder of the eye, kept out of the level by
## dot-core's probe, and the whole body drawn. The client sets it from the view key under the
## server's `mp_forceview`; presentation only, the simulation does not know.
var third_person: bool = false

## Layers the third-person camera stops against (the level and props). Set by the client.
var third_person_mask: int = 1

var _tp_probe: DotCameraProbe = null

## The third-person camera's place behind the eye, in the view's own axes: right, up, back.
const THIRD_PERSON_OFFSET := Vector3(0.45, 0.35, 2.6)

## The camera's own field of view, before an aim zooms it. Written by
## [method set_field_of_view] so a zoom always scales the player's setting, never itself.
var _base_fov: float = 75.0

## A displacement added to the camera this frame, and a roll. Written by the client.
var camera_offset: Vector3 = Vector3.ZERO
var camera_roll: float = 0.0

## The camera's motion cues: the landing dip, the strafe and slide roll, the wall-run lean and the
## widening with speed.
var camera_motion: DotFpsViewMotion = null

## The aim's zoom this frame, from the view model: [method present] multiplies the lens by it.
var _aim_fov_scale: float = 1.0
## What the camera takes of the aim zoom: all of it with the full-screen scope, none with the scope lens, which zooms in its own camera.
var _view_fov_scale: float = 1.0

## What a remote player is drawn as. Null on the local player, who sees their own eyes.
var body_mesh: Node3D = null

## The person drawn in [member body_mesh]: dot-player-char's people, the family's one style for
## players, bots and NPCs, coloured from [member avatar] by `ArenaAvatars.look_of`. Null on a
## server, and for the capsule a build without the people's art falls back to.
var figure: DotHumanoidFigure = null

## What this player looks like, as a dot-user-avatar document; null is the stock figure. Set on a
## server from the identity layer and carried to every client in JOIN, so a member who dressed on
## the site is that figure on every screen.
var avatar: DotAvatar = null

## An administrator's `blind`: this player's own screen is blacked out. [b]Set on the server and
## replicated to the OWNER ONLY[/b] (`ArenaPlayerNet.net_blind`).
var blinded: bool = false

## The achievement this player is nearest to, for the HUD's challenge bar: an index into
## `ArenaAwards.catalogue()` (-1: none), and how far along it they are. Set by ArenaProgress on
## the server, replicated to the owner alone.
var challenge: int = -1
var challenge_value: int = 0

## An administrator's `beacon`: a pulsing ring and a column over this player that every client
## draws, and a ping every client hears, until it is turned off. Set on the server and replicated to
## everybody (`ArenaPlayerNet.net_beacon`), who each draw it in [method present].
var beacon: bool = false

## Whether to draw the spawn-protection bubble round this player. The server decides it (protected and
## `spawn_protection_bubble`) and replicates it (`ArenaPlayerNet.net_protected`).
var protected_view: bool = false

## The bubble node while one is drawn. See [method _present_bubble].
var protection_bubble: DotSpawnBubble3D = null

## The marker [member beacon] draws, while it does. Client side; built and freed by
## [method present].
var beacon_marker: DotFxBeacon = null

## Whether this player's flashlight is on. The server decides it ([method switch_flashlight]) and
## replicates it ([member ArenaPlayerNet.net_flashlight]); everyone draws the beam from it.
var flashlight: bool = false
## Whether the map's starting state has been applied to [member flashlight] yet.
var flashlight_ready: bool = false
var flashlight_charge: float = 1.0
var _flashlight_held: bool = false
## The flashlight config the switch obeys; set only where the game decides (offline, the server).
var flashlight_cfg: DotFlashlightConfig = null
var flashlight_map: String = ""

## The movement this player was built with, before any class scaled it. See [method
## apply_class_movement]. Captured on the first application rather than at build time, so a game
## that never uses classes never duplicates a tunables object.
var _class_base: DotFpsTunables = null

## Swimming, in an imported map's water.
var swim := DotFpsSwimMode.new()

## Climbing, on an imported map's ladders. Registered beside [member swim], after it, in
## that order everywhere: the order is the id.
var ladder := ArenaLadderMode.new()

var _map: ArenaMap = null
## The crouch scale the hitboxes were last fitted to (-1: refit); the fit is a pure function of it.
var _fit_k := -1.0
var _combat: DotCombatManager = null
var _hand: Node3D = null
var _seen_fire_seq: int = 0
var _command := DotWeaponCommand.new()
var _tick_rate: int = ArenaContent.TICK_RATE

## A [DotFpsController] that collides against analytic geometry rather than physics. `_make_body` is
## dot-player-controller's documented seam for exactly this, and using it is what lets the same
## [ArenaPlayer] run on a dedicated server with no physics space and in a client with one.
class HeadlessController extends DotFpsController:
	var flat_body: DotFpsBody = null

	func _make_body() -> DotFpsBody:
		return flat_body

## The other players' standing hulls this player's sweeps stop at (`Array[AABB]`, its own left out;
## empty while `mp_solidplayers` is 0). Set by the game that holds the player ([method
## ArenaGame.solid_hulls_for]); unset, nobody is solid to this player.
var solid_hulls_fn: Callable = Callable()

## The tick [method simulate_tick] is running, replays included: where a predicting client
## places the remotes it collides with ([method ArenaGame.solid_hulls_for]).
var _hull_tick: int = -1

const MOVEMENT_RULES: PackedStringArray = ArenaPlayerTunables.MOVEMENT_RULES
const BODY_RULES := ArenaPlayerTunables.BODY_RULES
const SURF_TUNABLES := ArenaPlayerTunables.SURF_TUNABLES

## How far under an imported map's bounds a player is counted as out of it, metres.
const FALL_OUT_DEPTH := 10.0

var _max_health := 100.0
var _max_armour := 100.0
var _regen := 0.0
var _fall_out_depth := FALL_OUT_DEPTH

## One unit of the engine the combat surf maps come from, in metres.
const GENRE_UNIT := 0.01905

## What a server set for the body pose, kept so a body made later wears it.
var _body_rules: Dictionary = {}

## Poses every drawn body (the person's own in third person, and everyone else's) while it wall
## runs: a [DotFpsViewMotion] used only for [method DotFpsViewMotion.body_roll] and `body_yaw`.
var body_motion: DotFpsViewMotion = null

## How many arsenal slots a player has: the pack's five.
const MAX_SLOTS := AwWeaponIds.SLOT_THROWN ## the highest slot either layout uses

## The shared weapon table, built once for the whole process. Validated on first use rather than per
## player, and loudly: a catalogue with a duplicate id hands somebody the wrong weapon and nothing
## reports it.
static var _shared_catalogue: DotWeaponCatalogue = null
static var _shared_generation := -1

## How far behind the eye your own body is drawn in first person, in metres: far enough that the
## chest under a hidden neck stays out of the near plane.
const FIRST_PERSON_BACK := 0.18
## The same with only the legs drawn: nothing above the belly reaches the near plane, and further back the feet leave the view.
const FIRST_PERSON_BACK_LEGS := 0.0

## Extra metres the body trails behind as the view tips past 60 degrees down, full at 85:
## straight down, the open hips (the cut where the belly bone is gone) would fill the screen.
@export var first_person_look_down_back: float = 0.45
## cl_fp_look_down_back: a value of 0 or more replaces the export for every player on this client.
static var look_down_back_override: float = -1.0

## Whether [method present_lod] may thin out the bodies nobody is looking at.
static var present_lod_enabled: bool = true

## Probe only (`tools/client_cost.gd`): when true a remote body is not presented at all, to measure what presenting them costs.
static var present_remote_paused: bool = false

## Probe only: parts of a remote body's presentation switched off to find what each costs (bit 1 the figure's animation, 2 the held
## gun's update, 4 the held gun's own per-frame process, 8 the pose/tag/beacon rest). 0 in the game.
static var present_ablate: int = 0

## `cl_held_equips`: most remote bodies that build a new held gun in one frame (0: no limit). A
## respawn wave changes a dozen bodies' guns at once, and each build instances a model, so the
## rest wait a frame or two holding the old one instead of one frame taking all of them.
static var held_equips_per_frame: int = 2
static var _held_equip_frame: int = -1
static var _held_equips_used: int = 0

## Whether one more remote body may build its held gun this frame, and counts it.
static func held_equip_allowed() -> bool:
	if held_equips_per_frame <= 0:
		return true
	var frame := Engine.get_process_frames()
	if frame != _held_equip_frame:
		_held_equip_frame = frame
		_held_equips_used = 0
	if _held_equips_used >= held_equips_per_frame:
		return false
	_held_equips_used += 1
	return true

## `cl_remote_lod_frustum`: judge "out of sight" by the camera's real frustum instead of the cone below.
static var lod_frustum: bool = true

## `cl_remote_lod_every`: frames between presents of a body out of sight (1 turns the off-screen thinning off).
static var lod_off_every: int = 4

## A remote body nearer than this (metres) is always drawn in full.
const LOD_NEAR := 6.0
## A body further than this cosine off the view axis is out of sight (about 78 degrees).
const LOD_CONE := 0.2
## Frames between presents of a body out of sight.
const LOD_EVERY := 4
## Metres round a body's chest that count as it for the frustum test (a body, its gun, the swing of an arm).
const LOD_RADIUS := 1.6

## Past these distances (metres) a body is drawn every second / fourth frame even in plain view:
## at 45 m a player is a few dozen pixels and 5 fps of animation is not seen.
const LOD_FAR := 45.0
const LOD_FARTHEST := 90.0

var _figure_motion: Dictionary = {}
var _held_thin: bool = false
var _lod_frames: int = 0
var _lod_delta: float = 0.0

var _figure_fire_seq: int = 0
## The weapon the figure's hold was last set for, and that hold (-1 until set).
var _figure_hold_id: StringName = &""
var _figure_hold_kind: int = -1

## How a stair tread's rise reaches the eye: the time constant of an exponential, seconds.
## The step is the simulation's at once; only the view eases.
##
## [b]The camera stepped up each tread in one tick.[/b] A grounded tick that climbs a 0.36 m
## tread moves the player 0.36 m up, and the eye between that tick and the last rose with it,
## 16 cm in one frame at 144 Hz, ten times a second up dm_box's stair at a run, where a ramp
## of the same height is a steady 2.5 cm a frame. dot-player-controller's own camera
## (`DotFpsView.smooth_step_up`) has always eased it; this game writes its camera itself
## (`present`) and had none of it. `headless_feel` measures a run up the stair.
var step_smooth_time: float = 0.05

## The part of recent stair steps not yet shown, metres: subtracted from the eye, easing to 0.
var _step_offset: float = 0.0
## The tick whose step is being drawn, its rise if it was a stair step (else 0), and how much
## of that rise this frame's interpolation has already drawn.
var _step_tick: int = -1
var _step_rise: float = 0.0
var _step_drawn: float = 0.0

## A landing the eye has not reached yet: its impact (0 for none) and the tick it came on.
var _landing_impact: float = 0.0
var _landing_tick: int = -1

## How far a watched gun kicks per kind of use. The real recoil is on an outcome that does
## not travel, so a watcher's is approximate on purpose — the same numbers the pack gives
## its own watchers, kept here because the pack's copy is private to it.
const WATCHED_RECOIL := {
	AwWeaponNet.KIND_SWING: Vector2(1.2, 0.0),
	AwWeaponNet.KIND_SPAWN: Vector2(2.0, 0.0),
	AwWeaponNet.KIND_THROW: Vector2(2.0, 0.0),
	AwWeaponNet.KIND_BEAM: Vector2(0.05, 0.0),
}

## Where [method attachment]'s hand is, in the body's frame. -Z is the way they face.
const HAND_POSITION := Vector3(0.26, 1.12, -0.34)
