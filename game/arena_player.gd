@tool
extends Node3D

const ArenaAvatars := preload("arena_avatars.gd")
const ArenaContent := preload("arena_content.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaLadderMode := preload("../maps/arena_ladder_mode.gd")
const ArenaMapMechanics := preload("../maps/arena_map_mechanics.gd")
const ArenaSolidBody := preload("arena_solid_body.gd")

## One player: movement, weapons, health and hitboxes, assembled.
##
## [b]This is the piece every one of the addons says belongs in the game.[/b]
## dot-player-controller does not know about dot-combat; dot-combat does not know about
## dot-match; none of them knows about the others' node layout. Something has to own
## the wiring, and it is deliberately here rather than in an addon — an addon that did
## it would be an addon that dictates a scene shape.
##
## Built in code rather than as a `.tscn` for the same reason [ArenaMap] is: the
## headless test and the played game must get the same player, and a scene that is
## instantiated in one and hand-built in the other is two players that drift.
##
## [codeblock]
## var player := ArenaPlayer.new()
## player.setup(ArenaPlayer.Mode.HEADLESS, map, session_id)
## add_child(player)
## player.give_loadout(loadout_entries)
## [/codeblock]

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
	## Analytic geometry from [ArenaMap]. A dedicated server, and every test.
	##
	## Not a degraded mode: it is exact, it needs no physics space, and — the part
	## that matters — it gives the same answer on a client replaying a tick and a
	## server that ran it. See dot-player-controller's `DotFpsFlatBody`.
	HEADLESS,
	## Godot physics. A client, and a listen server.
	PHYSICS,
}

@export_group("Identity")

## Stable id. A dot-server session id in a real deployment; an index in a test.
##
## The same value is the scoreboard key, the combat entity id and the damage
## attribution, which is what stops three id spaces having to be mapped onto each
## other at every seam.
@export var player_id: int = 0

@export var display_name: String = "Player"

@export var team: int = 0

var mode: Mode = Mode.HEADLESS

var controller: DotFpsController = null
var arsenal: DotWeaponArsenal = null

## zee-dot-weapons' rig over [member arsenal]: the bash, the view model, the shot effects
## and the replication counter. See [method _build_rig].
var weapons: ZeeWeaponRig = null

## Somebody else's gun, in their hand. Client side, on every player but the local one.
var held: ZeeWorldModel = null

## What a MIRROR knows of this player's weapon: written from the snapshot by
## `ArenaPlayerNet`, read by [method _present_held]. A simulated player — the authority's,
## an offline bot — is read off its own rig instead, and leaves these alone.
var mirrored: bool = false
var mirror_weapon: StringName = &""
var mirror_fire_seq: int = 0
var mirror_fire_kind: int = 0
var mirror_switching: bool = false
var health: DotHealth = null
var hitboxes: DotHitboxSet = null

## Where the eyes are, and where shots start.
var view: Node3D = null

## The local player's camera. Null on a server, on a remote player, and headless.
var camera: Camera3D = null

## The view to draw this frame, (yaw, pitch) in degrees, or null for the simulated
## state's. Set every frame by the client from `DotFpsSampler.look_now()`.
##
## [b]Because a frame with no tick in it would otherwise not turn.[/b] The state's angles
## change only when a tick runs, and this game ticks 64 times a second: a 144 Hz display
## has more frames with no tick than with one, and on each of them the view stood where the
## last frame left it while the mouse moved, then caught up double on the next. game-g2gfast
## measured it first at 128 ticks (one frame in nine at 144 Hz); `headless_view` here.
var view_now: Variant = null

## Added to where the local player is drawn this frame: what is left of the last
## prediction corrections, easing to zero (`DotNetPredictor.visual_offset`). Without it a
## correction moves the eye in one frame -- 30 cm in one frame for a 30 cm correction in
## game-g2gfast's `headless_feel` -- where the predictor has always computed the offset
## that eases it over a tenth of a second, and nothing read it.
var drawn_offset: Vector3 = Vector3.ZERO

## How far through the current tick this frame is drawn (usually 0..1, -1 to 2 just after a
## slip), or NAN for the engine's physics fraction. Set every frame by a connected client from
## dot-net's `DotNetClock.render_alpha`.
##
## [b]Because a connected client's ticks are the clock's, not the engine's.[/b] The clock
## stretches or shrinks its ticks while it settles on the server (drift), so now and then a
## physics frame runs no tick and a later one two. Drawn at the engine's fraction, the frame
## with none goes back over the stretch it just drew and the eye stands still, and the frame
## with two moves it double: `headless_feel` measured 8 frames in 5 s 10 to 15 cm off at a
## 60 Hz display, every one on a physics frame that ran 0 or 2 ticks. Offline every physics
## frame is one tick and the engine's fraction is exact.
var drawn_alpha: float = NAN

## Whether [method present] draws this body between its ticks: a player this machine
## simulates and somebody else watches -- an offline bot. Set by the client.
##
## [b]A bot offline was drawn where its last tick left it[/b], because the tick moves this
## node and nothing else moved the body: at 144 Hz against 64 ticks a bot stood still on
## more than half the frames and jumped on the rest, every frame 6 to 8 cm off its motion
## (`headless_feel`). A mirrored player is never this: dot-net's interpolator moves its node
## once a frame (`ArenaPlayerNet._net_interpolated`), and its controller is never ticked here,
## so the controller's last-tick state it would blend from is not its own.
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
var _health_tag: Node3D = null
var _health_fill: MeshInstance3D = null
var _last_health: float = -1.0
var _hurt_age: float = 999.0
const HEALTH_TAG_SEC := 3.0
const HEALTH_TAG_WIDTH := 0.9

## The meshes a body break hid, so a respawn can draw them again. Client side.
var _broken: Array[MeshInstance3D] = []
var _severed: bool = false

## This player's body went down as a ragdoll (or was hidden by the server's style), so a
## respawn has to draw it again. Client side.
var _fell: bool = false

## Draws this player's own body in first person when the server's `fp_body` rule says so.
var _first_person: DotPlayerFirstPersonBody = null

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
##
## [b]The shake is added here rather than applied to the camera by whoever computed
## it[/b], because this is the one place the camera's transform is written — the comment
## in [method present] below says why, and a second writer would fight it every frame for
## the same value. dot-fx computes a displacement and touches no camera, which is
## dot-spectate's rule and is what lets one implementation serve this rig, a spectator's
## and a headless suite.
var camera_offset: Vector3 = Vector3.ZERO
var camera_roll: float = 0.0

## The camera's motion cues: the landing dip, the strafe and slide roll, the wall-run lean
## and the widening with speed. dot-player-controller's `DotFpsViewMotion`, the arithmetic
## `DotFpsView` uses, without the view: this game writes its camera in [method present] and
## nowhere else, so it asks for the numbers and adds them there. Built by
## [method attach_camera] from [method camera_motion_picks], scaled by the player's camera
## motion settings ([method set_camera_motion_scales]). Null on a player with no camera.
var camera_motion: DotFpsViewMotion = null

## The aim's zoom this frame, from the view model: [method present] multiplies the lens by it.
var _aim_fov_scale: float = 1.0

## What a remote player is drawn as. Null on the local player, who sees their own eyes.
var body_mesh: Node3D = null

## The person drawn in [member body_mesh]: dot-player-char's people, the family's one style for
## players, bots and NPCs, coloured from [member avatar] by `ArenaAvatars.look_of`. Null on a
## server, and for the capsule a build without the people's art falls back to.
var figure: DotHumanoidFigure = null

## What this player looks like, as a dot-user-avatar document; null is the stock figure.
##
## Set on a server from the identity layer and carried to every client in JOIN, so a
## member who dressed on the site is that figure on every screen.
var avatar: DotAvatar = null

## An administrator's `blind`: this player's own screen is blacked out.
##
## [b]Set on the server and replicated to the OWNER ONLY[/b] (`ArenaPlayerNet.net_blind`).
## Nobody else's screen changes, so nobody else needs to know — and an opponent who could
## read it would know exactly when somebody could not see them coming. `ArenaHud` draws it.
var blinded: bool = false

## The achievement this player is nearest to, for the HUD's challenge bar: an index into
## `ArenaAwards.catalogue()` (-1: none), and how far along it they are. Set by ArenaProgress on
## the server, replicated to the owner alone.
var challenge: int = -1
var challenge_value: int = 0

## An administrator's `beacon`: a pulsing ring and a column over this player that every
## client draws, and a ping every client hears, until it is turned off.
##
## Set on the server and replicated to everybody (`ArenaPlayerNet.net_beacon`), who each
## draw it in [method present]. A beaconed player's entity is also made always-relevant,
## so the beacon reaches a client however far away they are — see `ArenaPlayerNet.pull`.
var beacon: bool = false

## The marker [member beacon] draws, while it does. Client side; built and freed by
## [method present].
var beacon_marker: DotFxBeacon = null

## The movement this player was built with, before any class scaled it.
##
## See [method apply_class_movement]. Captured on the first application rather than at
## build time, so a game that never uses classes never duplicates a tunables object.
var _class_base: DotFpsTunables = null

## Swimming, in an imported map's water. [b]Registered on every player on every map, the
## same on every machine[/b], because a mode's id travels on the wire in the state's flags:
## a client that registered it only on a map with water would read a swimming player's
## mode as whatever its own next mode was, or as nothing. With no water it is never
## entered, so a built-in map moves exactly as it did. game-g2gfast registers its two for
## the same reason.
var swim := DotFpsSwimMode.new()

## Climbing, on an imported map's ladders. Registered beside [member swim], after it, in
## that order everywhere: the order is the id.
var ladder := ArenaLadderMode.new()

var _map: ArenaMap = null
var _combat: DotCombatManager = null
var _hand: Node3D = null
var _seen_fire_seq: int = 0
var _command := DotWeaponCommand.new()
var _tick_rate: int = 64


## A [DotFpsController] that collides against analytic geometry rather than physics.
##
## `_make_body` is dot-player-controller's documented seam for exactly this, and using it
## is what lets the same [ArenaPlayer] run on a dedicated server with no physics space
## and in a client with one.
class HeadlessController extends DotFpsController:
	var flat_body: DotFpsBody = null

	func _make_body() -> DotFpsBody:
		return flat_body


## The other players' standing hulls this player's sweeps stop at (`Array[AABB]`, its own
## left out; empty while `mp_solidplayers` is 0). Set by the game that holds the player
## ([method ArenaGame.solid_hulls_for]); unset, nobody is solid to this player. Read through
## [method _solid_hulls] by the movement body ([code]arena_solid_body.gd[/code]), so a game
## that sets it after the body was built still reaches it.
var solid_hulls_fn: Callable = Callable()


func _solid_hulls() -> Array:
	return solid_hulls_fn.call(player_id) if solid_hulls_fn.is_valid() else []


## The map's movement body, wrapped so the other players' hulls stop its sweeps.
func _movement_body(of_map: ArenaMap) -> DotFpsBody:
	return ArenaSolidBody.new().wrap(of_map.movement_body(), _solid_hulls)


## Builds the whole player. Call before adding to the tree.
func setup(p_mode: Mode, map: ArenaMap, id: int, name_text: String = "") -> void:
	mode = p_mode
	_map = map
	player_id = id

	if name_text != "":
		display_name = name_text

	name = "Player%d" % id

	_build_view()
	_build_controller()
	_build_health()
	_build_arsenal()
	_build_hitboxes()


func _build_view() -> void:
	view = Node3D.new()
	view.name = "View"
	# Eye height for a 1.8 m capsule, which is what the tunables below describe.
	view.position = Vector3(0.0, 1.6, 0.0)
	add_child(view)


func _build_controller() -> void:
	var tunables := arena_tunables()

	if mode == Mode.HEADLESS:
		var headless := HeadlessController.new()
		# The map's own backend: its boxes for a built-in map, the physics space for an
		# imported one (see `ArenaMap.movement_body`).
		headless.flat_body = _movement_body(_map)
		controller = headless
	else:
		controller = DotFpsController.new()

	controller.name = "Movement"
	controller.drive = DotFpsController.Drive.EXTERNAL
	controller.tick_rate = _tick_rate
	controller.tunables = tunables
	controller.register_service = false
	controller.register_default_actions = false
	# On for every player on every machine, because a registration order is part of the
	# wire: an admin's noclip or freeze is a modifier the owning client has to predict,
	# and a client that had not registered it would read that index as something else.
	controller.admin_abilities = true
	controller.body_ref = DotNodeRef.of_path(NodePath(".."))
	# The genre's water, in the genre's numbers, because the maps were built for them: 200
	# u/s at most, and a player who presses nothing sinks at 60 u/s rather than floating,
	# so a pit full of water is climbed out of by holding jump. The waist and the float
	# depth are the genre's proportions of the ARENA's 1.8 m hull (half its height, and
	# 56/72 of it), not its 72-unit ones, because they are measured up from these feet.
	swim.swim_speed = 200.0 * GENRE_UNIT
	swim.idle_sink_speed = 60.0 * GENRE_UNIT
	swim.accelerate = 10.0
	swim.waist = tunables.stand_height * 0.5
	swim.float_depth = tunables.stand_height * 56.0 / 72.0
	swim.exit_speed = 300.0 * GENRE_UNIT
	swim.exit_reach = 24.0 * GENRE_UNIT
	controller.extra_modes = [swim, ladder]
	_use_map_volumes()
	add_child(controller)


## The collision layers this player's movement sweeps against.
##
## [b]Not left at `DotFpsTunables`' default of 1.[/b] One means bit 0, which is right
## only while every body in the game is on bit 0 — the state the layout exists to end.
## Once props moved to the prop layer a mask of 1 was a player who walks through every
## crate on the map, and nothing would have said so: a sweep that hits nothing is a
## sweep, not an error.
##
## Called by `ArenaGame` once the stack is up, because the layout is the stack's.
func use_collision_mask(mask: int) -> void:
	if controller == null or controller.tunables == null:
		return

	controller.tunables.collision_mask = mask


## Scales this player's movement by their class.
##
## [b]Against a kept base, not against whatever the tunables currently say.[/b] A class's
## `move_speed_scale` is a multiplier, so applying it to an object that already carries it
## compounds — four respawns as a 0.8-speed class is 0.41, arrived at silently. The base
## is the tunables this player was built with, captured once.
func apply_class_movement(def: DotPlayerClassDef) -> void:
	if controller == null or controller.tunables == null or def == null:
		return

	if _class_base == null:
		_class_base = controller.tunables.duplicate()

	var _n := DotPlayerClassApply.to_movement(def, controller.tunables, _class_base)


## Movement that feels like an arena shooter rather than a modern one.
##
## Fast, floaty, high air control, and no sprint — the speed is the speed, and the way
## to go faster is to move well. Every number here is a game's choice; none of it is
## dot-player-controller's default.
static func arena_tunables() -> DotFpsTunables:
	var tunables := DotFpsTunables.new()
	tunables.max_speed = 9.0
	tunables.accelerate = 12.0
	tunables.friction = 5.5
	tunables.stop_speed = 3.0
	# High air acceleration with a low wish-speed cap is the classic formula: it does
	# nothing when you hold forward and everything when you turn while strafing.
	tunables.air_accelerate = 140.0
	tunables.max_air_wish_speed = 1.2
	tunables.gravity = 22.0
	tunables.jump_height = 1.25
	tunables.auto_hop = true
	tunables.coyote_time = 0.08
	tunables.jump_buffer_time = 0.12
	tunables.sprint_speed_scale = 1.0
	tunables.crouch_speed_scale = 0.45
	# Crouch at a run slides: a burst and a long, low-friction carry, then a crouch. The
	# minimum is under the 9 m/s run so any real run slides and a crouch-walk never does.
	tunables.slide_enabled = true
	tunables.slide_min_speed = 6.5
	tunables.slide_boost = 3.5
	tunables.slide_max_speed = 14.0
	tunables.slide_friction = 0.9
	tunables.slide_duration = 0.9
	tunables.slide_cooldown = 0.6
	# E throws you upward to dodge or escape, on a cooldown. The command's first user bit,
	# which the arena's movement command leaves free: its weapon buttons ride in their own.
	tunables.launch_enabled = true
	tunables.launch_button = DotFpsCommand.BUTTON_USER_0
	tunables.launch_velocity = 12.0
	tunables.launch_cooldown = 8.0
	# Shift dashes: the sprint bit, which this game leaves free because it has no sprint
	# (sprint_speed_scale is 1). A press throws you along the way you steer.
	# Off by default: arena_dash 1 turns it on (a mode or an operator's choice).
	tunables.dash_enabled = false
	tunables.dash_button = DotFpsCommand.BUTTON_SPRINT
	tunables.dash_speed = 15.0
	tunables.dash_lift = 2.5
	tunables.dash_cooldown = 3.0
	# Walls: run a few steps along one, jump off it, ride it down. dot-player-controller's
	# defaults for everything but these four (docs/wall-movement.md there, docs/modes.md here).
	# The run needs MORE than the 9 m/s plain run along the wall, so a run is something a
	# player does on purpose (a slide, a dash or a strafe into it): at 9 or under, every jump
	# taken beside a wall would become a run and peak about 40% lower than the player meant.
	# The wall jump needs no speed at all, and the slide catches a fall against a wall.
	tunables.wall_run_enabled = true
	tunables.wall_run_min_speed = 9.5
	tunables.wall_jump_enabled = true
	tunables.wall_slide_speed = 2.5
	return tunables


## The movement keys a server owner may change on a running server (`arena_slide*`,
## `arena_launch*`), and that RULES carries to every client so prediction agrees.
const MOVEMENT_RULES: PackedStringArray = [
	"slide_enabled", "slide_min_speed", "slide_boost", "slide_max_speed",
	"slide_friction", "slide_duration", "slide_cooldown",
	"launch_enabled", "launch_velocity", "launch_forward", "launch_cooldown",
	"dash_enabled", "dash_speed", "dash_lift", "dash_cooldown",
	"wall_run_enabled", "wall_run_min_speed", "wall_run_max_time", "wall_run_gravity_scale",
	"wall_jump_enabled", "wall_jump_push_speed", "wall_jump_up_speed", "wall_jump_max_per_air",
	"wall_slide_speed",
	"wall_run_end_speed", "wall_run_vertical_damping", "wall_run_max_fall_speed",
	"wall_run_max_approach_angle", "wall_jump_look_blend", "wall_jump_max_per_wall",
	"wall_run_body_roll", "wall_run_body_yaw",
]

## The rules in [constant MOVEMENT_RULES] that pose a drawn body rather than move one: they
## are not tunables, they live on [member body_motion], and these are their defaults.
const BODY_RULES := {"wall_run_body_roll": 25.0, "wall_run_body_yaw": 12.0}


## What a combat surf map plays with, as overrides on [method arena_tunables].
##
## [b]The genre's air control, because the map was built for it.[/b] A surf ramp is ridden
## by strafing into it in the air, and how far that turns a player is `air_accelerate`
## against a wish speed capped at `max_air_wish_speed`: the arena's own pair (140 against
## a 1.2 m/s cap) is a floaty deathmatch, and on a ramp it is a player who cannot hold the
## line the mapper drew. The numbers are the genre's, converted at 0.01905 m a unit:
## `sv_airaccelerate 150` (what game-g2gfast runs these maps at, and `arena_surf_airaccelerate`
## changes it), a 30 u/s wish cap, 800 u/s² of gravity, a 57-unit jump and the 3500 u/s
## speed limit. Gravity and the jump travel together because the gaps between ramps were
## sized for that arc — at the arena's 22 m/s² a jump off a ramp lands 30% short.
##
## The ground is left alone: running speed, friction, slide, launch and dash are the
## arena's on every map, because the fights between the ramps are an arena fight.
const SURF_TUNABLES := {
	"air_accelerate": 150.0,
	"max_air_wish_speed": 30.0 * 0.01905,
	"gravity": 800.0 * 0.01905,
	"jump_height": 57.0 * 0.01905,
	"max_velocity": 3500.0 * 0.01905,
}


## Puts this player's movement on what the map asks for: [param overrides] (keys from
## [constant SURF_TUNABLES]) on top of [method arena_tunables], and every key it does not
## name back to the arena's own.
##
## [b]Back as well as on, and that is the half that matters.[/b] A rule written only when a
## surf map loads is a rule still in force on the next map, where the arena's 1.2 m/s air
## cap is a quarter of what the player now has. Into the class base too, for
## [method apply_movement_rules]' reason.
func apply_map_movement(overrides: Dictionary) -> void:
	if controller == null or controller.tunables == null:
		return

	var base := arena_tunables()

	for key: String in SURF_TUNABLES:
		var value := float(overrides.get(key, base.get(key)))
		controller.tunables.set(key, value)

		if _class_base != null:
			_class_base.set(key, value)


## Sends this player through a teleport volume of an imported map, or back to a spawn when
## they have fallen out of the bottom of it.
##
## [b]Inside the simulated tick, on every machine that simulates it[/b] — the server and the
## owning client's prediction — because it reads only the simulated state and the map both
## ends loaded. Done by the server alone, the client would predict a fall the server ended
## a tick ago and be corrected across the map on every pit.
##
## The fall-out floor is ten metres under the map's own bounds, for a map whose pits leave
## gaps (a teleport aimed at nothing is dropped at import): without it a player who fell
## past every volume falls for ever, alive, and the round cannot end on him.
func _follow_map_volumes() -> void:
	if _map == null or not _map.is_imported():
		return

	var feet := controller.state.position

	var pit := _map.pit_at(feet, controller.state.tick)
	if not pit.is_empty():
		controller.teleport(pit["to"], float(pit["yaw"]), 0.0)
		_forget_drawn()
		return

	if feet.y < _map.bounds.position.y - FALL_OUT_DEPTH and not _map.spawns.is_empty():
		var at: Transform3D = _map.spawns[0]
		controller.teleport(at.origin, rad_to_deg(at.basis.get_euler().y), 0.0)
		_forget_drawn()


## Drops what the drawing carries from tick to tick: the stair easing, the frame two ticks
## back, the camera's motion. After a spawn or a teleport, which the eye jumps with.
##
## [b]These lines sat at the end of [method _follow_map_volumes] from 2026-10-11[/b], which
## runs every tick on an imported map: the stair easing never saw a step there and the
## frame two ticks back was always forgotten (`arena-camera-feel-1` found it).
func _forget_drawn() -> void:
	_yaw_before_tick = controller.state.yaw
	_position_two_back = Vector3(NAN, NAN, NAN)
	_step_offset = 0.0
	_step_rise = 0.0
	_step_drawn = 0.0
	_step_tick = controller.state.tick
	_landing_impact = 0.0
	if camera_motion != null:
		camera_motion.snap()
	if body_motion != null:
		body_motion.snap()


## How far under an imported map's bounds a player is counted as out of it, metres.
const FALL_OUT_DEPTH := 10.0

## One unit of the engine the combat surf maps come from, in metres.
const GENRE_UNIT := 0.01905


## What the map's brush entities do to this player this tick: its pushes, gravity and
## conveyors, then into the water or onto a ladder.
##
## [b]Inside the simulated tick, for [method _follow_map_volumes]' reason[/b], and from
## the same data on both ends: the server and the owning client's prediction each run it
## from the map they loaded and the state the tick started from ([param start], which a
## rewind restores), so a booster throws the predicted player exactly as it throws the
## server's and nothing has to be sent. A ladder is asked before the water, as the engine
## these maps come from asks its ladder move first: a climb out of a pit is ladder walls
## over water, and with the water asked last a climber was put back to swimming every tick
## (g2gfast's finding).
##
## Hurt is not here: it is health, which is the server's, so `ArenaGame` deals it.
func _run_map_mechanics(start: Vector3, delta: float) -> void:
	if _map == null or _map.mechanics == null or controller.motor == null:
		return

	var state := controller.state
	_map.mechanics.simulate(controller.motor, state, start, delta)

	if not ladder.volumes.is_empty():
		ladder.update(controller.motor, state)

	if not swim.volumes.is_empty() and state.mode != ladder.mode_id:
		swim.update(controller.motor, state)

	# A push moved the state after the controller wrote it out; the node follows, as the
	# controller's own publish does, so the muzzle and the hitboxes are where the player is.
	global_position = state.position


## Hands the swim and ladder modes the map's water and ladders, or nothing. A player left
## swimming or climbing on a map with none is put in the air, which the motor resolves.
func _use_map_volumes() -> void:
	var mechanics: ArenaMapMechanics = _map.mechanics if _map != null else null
	swim.volumes = mechanics.water if mechanics != null else ([] as Array[AABB])
	ladder.volumes = mechanics.ladders if mechanics != null else ([] as Array[AABB])

	if controller == null or controller.state == null or controller.motor == null:
		return

	var mode_now := controller.state.mode

	if (mode_now == swim.mode_id and swim.volumes.is_empty()) \
			or (mode_now == ladder.mode_id and ladder.volumes.is_empty()):
		controller.motor.set_mode(controller.state, DotFpsState.Mode.AIR)


## Writes [param rules] (key -> number, from [constant MOVEMENT_RULES]) into this player's
## movement, and into the class base it is re-derived from, or the next class change would
## put the old value back. A key not in the list is ignored: RULES came over the wire.
func apply_movement_rules(rules: Dictionary) -> void:
	if controller == null or controller.tunables == null:
		return

	for key in rules:
		if not MOVEMENT_RULES.has(String(key)):
			continue
		if BODY_RULES.has(String(key)):
			_body_rules[String(key)] = float(rules[key])
			_apply_body_rules()
			continue
		_set_rule(controller.tunables, String(key), rules[key])
		if _class_base != null:
			_set_rule(_class_base, String(key), rules[key])


## What a server set for the body pose, kept so a body made later wears it.
var _body_rules: Dictionary = {}

## Poses every drawn body (the person's own in third person, and everyone else's) while it wall
## runs: a [DotFpsViewMotion] used only for [method DotFpsViewMotion.body_roll] and `body_yaw`.
var body_motion: DotFpsViewMotion = null


func _apply_body_rules() -> void:
	if body_motion == null:
		return
	for key in _body_rules:
		body_motion.set(key, _body_rules[key])


## Poses [member body_mesh] from [param drawn]: its yaw, then the wall-run roll and turn.
## A body not on a wall has exactly the yaw it had, so this is every body's placement.
func _pose_body(drawn: DotFpsState, yaw: float, delta: float) -> void:
	if body_mesh == null:
		return
	if body_motion == null:
		body_motion = DotFpsViewMotion.new()
		body_motion.wall_run_body_roll = BODY_RULES.wall_run_body_roll
		body_motion.wall_run_body_yaw = BODY_RULES.wall_run_body_yaw
		_apply_body_rules()
	body_motion.advance(drawn, delta)
	body_mesh.global_basis = (
		Basis(Vector3.UP, deg_to_rad(yaw + body_motion.body_yaw()))
		* Basis(Vector3.BACK, deg_to_rad(body_motion.body_roll()))
	)


static func _set_rule(tunables: DotFpsTunables, key: String, value: Variant) -> void:
	if key.ends_with("_enabled"):
		tunables.set(key, float(value) != 0.0)
	elif typeof(tunables.get(key)) == TYPE_INT:
		# RULES carries every value as a float32; a count (wall_jump_max_per_air) is an int.
		tunables.set(key, roundi(float(value)))
	else:
		tunables.set(key, float(value))


func _build_health() -> void:
	health = DotHealth.new()
	health.name = "Health"
	health.max_health = 100.0
	health.max_armour = 100.0
	# No regeneration. An arena shooter's health is a resource you pick up, and
	# regeneration turns every fight into a question of who disengages first.
	health.regen_per_second = 0.0
	health.set_tick_rate(_tick_rate)
	add_child(health)

	health.died.connect(_on_died)


func _build_arsenal() -> void:
	arsenal = DotWeaponArsenal.new()
	arsenal.name = "Arsenal"
	arsenal.tick_rate = _tick_rate
	# One per pack slot: melee, sidearm, primary, heavy, thrown. `ArenaNetCommand`
	# bounds a slot request to the same number.
	arsenal.max_slots = MAX_SLOTS
	# Every player shares one catalogue: definitions are read-only and a per-player
	# copy would be twenty-seven resources per player for nothing. Behaviour instances
	# are per-player, which is the half that actually holds state.
	arsenal.catalogue = _catalogue()
	add_child(arsenal)

	var res := arsenal.setup()
	if not res.ok:
		push_error(res.error.message)

	_build_rig(ZeeWeaponRig.Role.SERVER, false, null)


## How many arsenal slots a player has: the pack's five.
const MAX_SLOTS := ZeeWeaponIds.SLOT_THROWN


## Puts a [ZeeWeaponRig] over [member arsenal], replacing any rig that was there.
##
## [b]The rig is handed THIS player's arsenal rather than building its own[/b]
## (`arsenal_ref`), and that is what lets it be rebuilt. A rig's role decides what it
## draws and is fixed at `setup()`; a player is built before anybody knows whether it is
## the one at this keyboard, so the client rebuilds the rig as LOCAL when it adopts its
## player ([method arm_first_person]) — and everything carried, every magazine and the
## slot in hand survive, because they live in the arsenal and not in the rig. Every
## reader of `player.arsenal` (the HUD, the netcode, the mod tools, the loadout) keeps
## reading the same node.
##
## [b]SERVER on a server and for every player a client merely mirrors.[/b] A server draws
## nothing; a mirrored player is drawn by [member held] from the snapshot, not by a rig.
func _build_rig(role: ZeeWeaponRig.Role, authority: bool, view_model: Node3D) -> void:
	if weapons != null:
		remove_child(weapons)
		# free(), not queue_free(): the old rig is connected to the arsenal's signals, and
		# one left alive until the end of the frame would count this tick's reload twice.
		weapons.free()
		weapons = null

	weapons = ZeeWeaponRig.new()
	weapons.name = "Weapons"
	weapons.role = role
	weapons.authority = authority
	weapons.tick_rate = _tick_rate
	weapons.catalogue = _catalogue()
	weapons.arsenal_ref = DotNodeRef.of_path(^"../Arsenal")
	weapons.player_ref = DotNodeRef.of_path(^"..")

	if view_model != null:
		# In the tree by now: it hangs under this player's camera.
		weapons.view_model_ref = DotNodeRef.of_path(view_model.get_path())

	add_child(weapons)

	var res := weapons.setup()
	if not res.ok:
		push_error(res.error.message)

	# The rig's signal rather than the arsenal's: it carries the bash too, and it is
	# silent during a reconciliation replay, so a corrected client does not hear the
	# same shot once per replayed tick.
	weapons.used.connect(_on_used)


## Makes this the player at this keyboard: the hands under [param view_model] and a rig
## that draws them, its tracers and its reports. Client side, once, on adoption.
##
## [param authority] is whether this machine decides — offline, yes; connected, no: the
## server's rig is the one whose shots land and this one is the gun that moves.
func arm_first_person(view_model: Node3D, authority: bool) -> void:
	_build_rig(ZeeWeaponRig.Role.LOCAL, authority, view_model)


## Whether any carried weapon's reserve is below its cap: what an ammo pack asks before it
## is taken, so one is left for someone who needs it.
func needs_ammo() -> bool:
	if arsenal == null:
		return false
	for slot_id in arsenal.slots():
		var def: DotWeaponDef = arsenal.slot_at(slot_id).def
		if def != null and def.uses_ammo() and def.ammo_type != &"" and not def.infinite_reserve \
				and arsenal.ammo().count(def.ammo_type) < def.reserve_cap():
			return true
	return false


## Adds [param share] (0 to 1) of every carried weapon's reserve cap to its pool: an ammo pack.
func refill_ammo(share: float) -> void:
	if arsenal == null:
		return
	for slot_id in arsenal.slots():
		var def: DotWeaponDef = arsenal.slot_at(slot_id).def
		if def != null and def.uses_ammo() and def.ammo_type != &"" and not def.infinite_reserve:
			var _added := arsenal.add_ammo(def.ammo_type, int(ceil(float(def.reserve_cap()) * share)))


## The shared weapon table, built once for the whole process.
##
## Validated on first use rather than per player, and loudly: a catalogue with a
## duplicate id hands somebody the wrong weapon and nothing reports it.
static var _shared_catalogue: DotWeaponCatalogue = null


## The shared weapon table, for anything else in the game that reads a definition.
static func weapon_catalogue() -> DotWeaponCatalogue:
	return _catalogue()


static func _catalogue() -> DotWeaponCatalogue:
	if _shared_catalogue == null:
		_shared_catalogue = ArenaContent.weapon_catalogue()
		var res := _shared_catalogue.validate()
		if not res.ok:
			push_error(res.error.message)
	return _shared_catalogue


func _build_hitboxes() -> void:
	hitboxes = DotHitboxSet.new()
	hitboxes.name = "Hitboxes"
	hitboxes.bounds_offset = Vector3(0.0, 0.9, 0.0)
	hitboxes.bounds_radius = 1.6

	var head := DotHitbox.new()
	head.name = "Head"
	head.group = DotHitGroup.HEAD
	head.shape = DotHitbox.Shape.SPHERE
	head.radius = 0.15
	head.position = Vector3(0.0, 1.62, 0.0)
	# Higher than the torso's, so the shared surface between a head sphere and a chest
	# capsule resolves to the head every time rather than about half the time.
	head.precedence = 10
	hitboxes.add_child(head)

	var chest := DotHitbox.new()
	chest.name = "Chest"
	chest.group = DotHitGroup.CHEST
	chest.shape = DotHitbox.Shape.CAPSULE
	chest.radius = 0.30
	chest.height = 1.05
	chest.position = Vector3(0.0, 0.98, 0.0)
	hitboxes.add_child(chest)

	var legs := DotHitbox.new()
	legs.name = "Legs"
	legs.group = DotHitGroup.LEG
	legs.shape = DotHitbox.Shape.CAPSULE
	legs.radius = 0.24
	legs.height = 0.9
	legs.position = Vector3(0.0, 0.45, 0.0)
	hitboxes.add_child(legs)

	add_child(hitboxes)
	hitboxes.refresh()


## The map this player's collision was built against, which [method rebind_map] replaces.
func map_in_hand() -> ArenaMap:
	return _map


## Rebuilds this player's collision against a different map.
##
## [b]Assigning the body is not enough, and that is the whole reason this is a
## method.[/b] `DotFpsMotor` holds a reference to the body it was built with — the same
## trap `DotFpsController.set_style` documents for the tunables — so a player handed
## new geometry without a rebuilt motor keeps colliding against the level they are no
## longer standing in. The symptom is a player wedged in mid-air where a wall used to
## be, with every property reading correctly.
##
## Only the analytic backend is rebuilt. Under [constant Mode.PHYSICS] the collision
## comes from Godot's physics space, which the host project has already repopulated by
## the time this runs, and there is nothing here that knows about it.
func rebind_map(new_map: ArenaMap) -> void:
	_map = new_map

	if new_map == null or controller == null:
		return

	if controller is HeadlessController:
		(controller as HeadlessController).flat_body = _movement_body(new_map)

	_use_map_volumes()

	# `setup()` is what builds the body and the motor, and it is the documented way to
	# rebuild both. Re-running it also re-resolves the node references, which is
	# harmless: they name this player's own children and have not moved.
	var rebuilt := controller.setup()

	if not rebuilt.ok:
		DotLog.warn(CHANNEL, "a player could not be re-bodied for the new map", {
			"player": player_id, "why": rebuilt.error.message
		})


# --- Registration ----------------------------------------------------------

## Registers with the combat manager so this player can shoot and be shot.
##
## Both halves matter and they are separate calls in dot-combat: hitboxes make you
## hittable, health makes you damageable. A player with one and not the other is a
## player shots pass through, or one who takes hits and never dies.
func join_combat(combat: DotCombatManager) -> void:
	_combat = combat
	hitboxes.register_with(combat, player_id)
	combat.register_health(player_id, health)
	combat.set_authoritative_origin(player_id, muzzle_position())


func leave_combat() -> void:
	if _combat != null and is_instance_valid(_combat):
		_combat.forget(player_id)
	_combat = null


# --- Loadout ---------------------------------------------------------------

## Gives the weapons a resolved loadout names.
##
## [param entries] is what [method DotLoadoutManager.resolve] returns: dictionaries of
## `slot`, `arsenal_slot`, `item` and `count`.
##
## [b]Not [DotWeaponLoadoutBridge], deliberately.[/b] The bridge does the weapon half
## and would do it correctly, but this game's loadout also carries armour, which is not
## a weapon and which the bridge is right to skip. Doing both here keeps the one place
## that knows about both id spaces down to one loop.
func give_loadout(entries: Array[Dictionary]) -> void:
	arsenal.clear()

	var catalogue := arsenal.catalogue
	var hand := 0

	for entry in entries:
		var item: DotItem = entry["item"]

		if not catalogue.has(item.id):
			# An equipment item with no weapon behind it. Armour goes through here.
			if item.id == &"armour":
				health.add_armour(100.0)
			continue

		var res := arsenal.give(item.id)

		if not res.ok:
			# [b]`DotLog`, not `push_warning`.[/b] A loadout entry the arsenal refused is
			# a RUNTIME condition an operator would want to see -- somebody spawned
			# without the weapon they picked -- so it belongs in the log file, on a
			# channel, with the item that caused it. `push_warning` reaches only the
			# editor's Errors dock, and the engine staples an unsuppressible backtrace to
			# it, which on a dedicated server is eight lines of stderr that read like a
			# crash and never reach the log at all.
			DotLog.warn(
				CHANNEL,
				"a loadout item could not be given",
				{
					"item": String(item.id),
					"player": player_id,
					"detail": res.error.message,
				}
			)
			continue

		hand = _better_hand(hand, catalogue.get_def(item.id).slot)

	# Something under the 1 key whatever the document said. A loadout from before the
	# melee slot names none, and a player whose last magazine runs dry should still have
	# something to swing.
	if not arsenal.has_slot(ZeeWeaponIds.SLOT_MELEE):
		var _knife := arsenal.give(ZeeWeaponIds.KNIFE)

	if hand > 0:
		arsenal.select(hand, controller.state.tick)


## Which of two slots to spawn holding: the heaviest GUN, never the grenade.
##
## [b]"The highest slot" was the rule while the highest slot was a rocket launcher.[/b]
## In the pack's layout it is the throwable, and a spawn holding a grenade with the pin
## out is a spawn that walks into a fight unable to shoot.
static func _better_hand(have: int, slot: int) -> int:
	if slot >= ZeeWeaponIds.SLOT_THROWN:
		return have if have > 0 else slot
	if have == 0 or have >= ZeeWeaponIds.SLOT_THROWN or slot > have:
		return slot
	return have


## The default loadout, for a player who has not chosen one.
func give_default_loadout() -> void:
	arsenal.clear()

	for id in ArenaContent.DEFAULT_LOADOUT:
		var _given := arsenal.give(id)

	arsenal.select(ArenaContent.DEFAULT_SLOT, controller.state.tick)


# --- Lifecycle -------------------------------------------------------------

## Puts the player into the world alive and whole.
func spawn(at: Transform3D, tick: int, protection_ticks: int = 0) -> void:
	# teleport() takes the look angles, not a velocity: it zeroes the velocity itself
	# and setting yaw afterwards would miss the sampler and the view, which it also
	# snaps.
	controller.teleport(at.origin, rad_to_deg(at.basis.get_euler().y), 0.0)
	_forget_drawn()

	health.spawn_protection_ticks = protection_ticks
	health.reset(tick)

	arsenal.disabled = false
	global_transform = at

	# The view model back to rest, so a respawn does not inherit the last life's sway.
	if weapons != null:
		weapons.on_reset()

	if _combat != null:
		_combat.set_authoritative_origin(player_id, muzzle_position())

	spawned.emit(at)


## Takes the player out of play without removing them.
## The bar over a remote player's head: shown for [constant HEALTH_TAG_SEC] after their
## health drops, facing the camera, red over dark.
func _present_health_tag(delta: float) -> void:
	if health == null:
		return

	var now := health.health
	if _last_health >= 0.0 and now < _last_health - 0.01:
		_hurt_age = 0.0
	_last_health = now
	_hurt_age += delta

	var show := is_alive() and _hurt_age < HEALTH_TAG_SEC and health.max_health > 0.0
	if not show:
		if _health_tag != null:
			_health_tag.visible = false
		return

	if _health_tag == null:
		_health_tag = Node3D.new()
		_health_tag.name = "HealthTag"
		add_child(_health_tag)
		var back := _tag_quad(Color(0.05, 0.05, 0.05, 0.75), 0.0)
		_health_tag.add_child(back)
		_health_fill = _tag_quad(Color(0.9, 0.15, 0.12), 0.001)
		# Two transparent quads 1 mm apart sort by centre, and the fill drew under the backing:
		# a full bar read as a dark, nearly empty one. Priority sorts it last, always.
		(_health_fill.material_override as StandardMaterial3D).render_priority = 1
		_health_tag.add_child(_health_fill)

	_health_tag.visible = true
	# Over the body as drawn, which an offline bot's is between ticks (`interpolate_body`).
	var over := body_mesh.global_position if body_mesh != null else global_position
	_health_tag.global_position = over + Vector3(0.0, 2.25, 0.0)
	var eye := get_viewport().get_camera_3d()
	if eye != null:
		# The whole tag turns to the camera, so the fill stays on its background.
		_health_tag.look_at(eye.global_position, Vector3.UP, true)
	var fraction := clampf(now / health.max_health, 0.0, 1.0)
	_health_fill.scale = Vector3(maxf(fraction, 0.001), 1.0, 1.0)
	_health_fill.position.x = -HEALTH_TAG_WIDTH * (1.0 - fraction) * 0.5


static func _tag_quad(colour: Color, forward: float) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = Vector2(HEALTH_TAG_WIDTH, 0.09)
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mesh := MeshInstance3D.new()
	mesh.mesh = quad
	mesh.material_override = material
	mesh.position.z = forward
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mesh


## Breaks this player's body apart on a death: [param rules] decides how much. Client
## side, drawing only. [param direction] is the way the killing hit travelled; the seed
## is the victim and the tick, so every client breaks the same body the same way.
func break_body(
	rules: DotPlayerBreakRules, direction: Vector3, p_seed: int, critical: bool
) -> DotPlayerBodyBreak:
	if body_mesh == null or rules == null:
		return null

	var before := DotPlayerBodyBreak.visible_meshes(body_mesh)
	var made := DotPlayerBodyBreak.break_apart(
		body_mesh, get_parent(), rules, global_position, direction, p_seed, true, critical
	)

	if made != null:
		# A person's limbs are baked off its skin and its bones shrunk; the respawn mends them.
		_severed = figure != null
		for mesh in before:
			if not mesh.visible:
				_broken.append(mesh)
		if held != null and not body_mesh.visible:
			held.visible = false

	return made


## This player's body falls: a ragdoll copied from what is drawn, built in [param yard] as
## [param death] says (the server's pick, off the KILL). Client side, drawing only; the
## figure is hidden until [method _mend_body] draws it again on respawn. Null when the
## server's style hides bodies or there is no body to copy.
##
## [b]After any body break[/b]: the limbs a critical took off are hidden by then, so the
## ragdoll is what is left of the body, and the pieces fly on their own.
func fall_body(yard: DotPlayerRagdolls, death: DotPlayerDeath) -> DotPlayerRagdoll:
	if yard == null or body_mesh == null or not body_mesh.is_inside_tree():
		return null
	# Your own body in first person has no head; the one that falls has.
	if figure != null:
		figure.hide_head = false
	# The gun goes down with the hand that held it rather than hanging in the air.
	var made := yard.spawn(body_mesh, death, controller.state.velocity)
	_fell = made != null or not body_mesh.visible
	if _fell and held != null:
		held.visible = false
	return made


## Puts a broken or fallen body back together once the player is alive again.
func _mend_body() -> void:
	if _severed and is_alive() and figure != null:
		_severed = false
		figure.mend()

	if _fell and is_alive() and body_mesh != null:
		_fell = false
		body_mesh.visible = true
		if held != null:
			held.visible = true

	if _broken.is_empty() or not is_alive() or body_mesh == null:
		return

	for mesh in _broken:
		if is_instance_valid(mesh):
			mesh.visible = true

	_broken.clear()
	body_mesh.visible = true

	if held != null:
		held.visible = true


## How far behind the eye your own body is drawn in first person, in metres. Behind, with
## only the legs drawn (see [method present_own_body]): measured 2026-10-06 against the stock
## blocky avatar, legs drawn under or in front of the eye show their cut tops as a flat skin-
## coloured square in the middle of the screen, which reads worse than no body at all. A body
## worth looking down at needs a legs model, not a box character's.
const FIRST_PERSON_BACK := 0.18


## Your own body in first person, or not: the server's `fp_body` rule. Client side, for
## the player at this keyboard. The head is shadow-only and the body sits behind the eye
## (see [DotPlayerFirstPersonBody]); the held weapon's world model stays hidden, because
## the view model is already the gun in your hands.
func present_own_body(show: bool, yaw: float) -> void:
	if third_person and is_alive() and camera != null and camera.current:
		# Seen from behind: the whole body and the gun in its hands. Placed by `present`.
		if body_mesh == null:
			attach_body_mesh(Color.WHITE, avatar)
		if _first_person != null:
			_first_person.restore()
		if figure != null:
			figure.hide_head = false
			figure.position = Vector3.ZERO
		body_mesh.visible = true
		_present_held()
		return

	if not show or not is_alive() or camera == null or not camera.current:
		if _first_person != null:
			_first_person.restore()
		if figure != null:
			figure.hide_head = false
		if body_mesh != null:
			body_mesh.visible = false
		if held != null:
			held.visible = false
		return

	if body_mesh == null:
		attach_body_mesh(Color.WHITE, avatar)
		if held != null:
			held.visible = false

	if _first_person == null:
		_first_person = DotPlayerFirstPersonBody.new()
		# The head-hiding is the helper's; the offset is done here, every frame, because
		# it has to follow the yaw and the helper's is applied once.
		_first_person.back_offset = 0.0
		# Only the legs, by name, and everything else shadow-only. A list of what to HIDE
		# (head, chest, arms...) was the first version, and the render still showed a grey
		# slab across half the screen: the avatar's parts are not named what the list
		# guessed. What to KEEP is two words every avatar here uses.
		_first_person.shown_names = PackedStringArray(["leg", "foot", "shoe", "boot"])

	if held != null:
		held.visible = false
	body_mesh.visible = true
	body_mesh.rotation = Vector3(0.0, deg_to_rad(yaw), 0.0)
	body_mesh.position = body_mesh.basis * Vector3(0.0, 0.0, FIRST_PERSON_BACK)
	if figure != null:
		# A skinned person is one mesh, so the helper's hide-by-name has nothing to choose
		# from: the head bone is shrunk instead, and the body stands behind the eye.
		figure.hide_head = true
		return
	_first_person.apply(body_mesh)


func make_dead() -> void:
	arsenal.disabled = true
	health.alive = false
	hitboxes.enabled = false


func is_alive() -> bool:
	return health.alive


# --- Simulation ------------------------------------------------------------

## Advances the player one tick.
##
## [b]The order is not arbitrary.[/b] Movement runs first so the shot leaves from
## where the player ends the tick rather than where they started it — half a tick of
## movement at arena speeds is fifteen centimetres, which at range is a miss. The
## arsenal's spread inputs are taken from the movement state afterwards, and the shots
## come out last.
##
## Returns the shots produced, unresolved. The caller decides whether it is
## authoritative enough to resolve them.
func simulate_tick(
	tick: int,
	delta: float,
	movement_command: DotFpsCommand,
	combat_command: DotWeaponCommand
) -> DotWeaponOutcome:
	if not health.alive:
		return DotWeaponOutcome.nothing("Dead.")

	# Where the tick starts, for the pushes: "was this player in a booster last tick" is
	# asked of this position rather than remembered. See `arena_map_mechanics.gd`.
	var start := controller.state.position
	_yaw_before_tick = controller.state.yaw
	# The previous state's position before this tick replaces it: two ticks back after it.
	_position_two_back = controller.render_state(0.0).position
	ladder.now = tick
	controller.apply_command(movement_command)
	controller.simulate_tick(tick, delta)
	_run_map_mechanics(start, delta)
	_follow_map_volumes()

	var state := controller.state

	# The aim comes from the movement command, not from a second sample. Sampling the
	# mouse twice gives a shot that leaves at a different angle than the one the
	# player was looking along.
	_command = combat_command.duplicate_command()
	_command.yaw = state.yaw
	_command.pitch = state.pitch
	aiming = _command.is_pressed(BUTTON_AIM)

	health.tick(tick, delta)

	if _combat != null:
		_combat.set_authoritative_origin(player_id, muzzle_position())

	# Pushed in from the simulated state, never read out of a rendered one: an
	# interpolated position differs between client and server by design, and feeding it
	# to the spread makes the spread differ too.
	var ctx := DotWeaponContext.make(
		player_id, tick, muzzle_position(), _command.aim_direction()
	)
	ctx.speed = state.horizontal_speed()
	ctx.airborne = not state.is_grounded()
	ctx.crouched = state.is_crouched()
	ctx.authority = arsenal.authority

	# Through the rig, which runs the arsenal and then the bash. It keeps the previous
	# command itself, for the same edge triggers the arsenal used to be handed it for.
	return weapons.simulate_tick(_command, tick, ctx)


## Draws this player at where they are BETWEEN ticks. Called once per rendered frame.
##
## [b]Nothing in this family rendered between ticks until it was measured.[/b]
## `DotFpsController.render_state` has interpolated between the last two ticks since the
## controller was written and is documented as the cure for exactly this stutter; its
## guard was `if drive != Drive.LOCAL: return state`, and `LOCAL` is the drive no
## networked game uses. Measured at 60 frames against a 128-tick server, drawing at the
## last tick instead: the camera advanced 74 mm on six frames out of seven and 112 mm on
## the seventh — **a 47% change in apparent speed, eight times a second**.
##
## The other half is that the engine must run at the SERVER's tick rate. The fraction a
## renderer interpolates at is a fraction through a physics frame, which is a fraction
## through a tick only while the two rates agree, so either fix alone measures as no
## better than doing nothing. `ArenaNetBridge._adopt_tick_rate` is the other half.
##
## View angles are deliberately NOT interpolated, and they never juddered: mouse motion
## is delivered once per frame and the sampler consumes everything pending, so whichever
## tick runs next absorbs exactly that frame's motion. Blending it would add a tick of
## latency to aiming to fix nothing.
func present(delta: float) -> void:
	if controller == null:
		return

	var drawn := (
		_render_state(drawn_alpha) if camera != null or interpolate_body
		else controller.state
	)

	if camera != null:
		# This frame's view and what is left of the last corrections, from the client. A
		# copy rather than the state: render_state duplicates, and the state is the tick's.
		if view_now != null or drawn_offset != Vector3.ZERO:
			drawn = drawn.duplicate_state() if drawn == controller.state else drawn
			drawn.position += drawn_offset
			if view_now != null:
				drawn.yaw = (view_now as Vector2).x
				drawn.pitch = (view_now as Vector2).y
		# Written globally rather than by moving this node: this node is the
		# controller's body, and the tick writes it. Moving it here would fight the
		# simulation and, on the predicted local player, would be read back by
		# reconciliation as "what the client is showing".
		if view != null:
			view.global_position = (
				controller.motor.eye_position(drawn)
				if controller.motor != null
				else drawn.position + Vector3(0.0, 1.6, 0.0)
			) - Vector3(0.0, _absorb_step(drawn_alpha, delta), 0.0)

		var punch := _present_view_model(drawn)

		# The landing dip, the roll and the widening, once a frame from the drawn state.
		var dip := 0.0
		var nod := 0.0
		var lean := 0.0
		var widen := 0.0
		if camera_motion != null:
			_kick_landing(drawn)
			camera_motion.advance(drawn, delta)
			dip = camera_motion.eye_drop()
			nod = camera_motion.pitch()
			lean = camera_motion.roll()
			widen = camera_motion.fov_added()

		camera.global_position = view.global_position + camera_offset + Vector3(0.0, dip, 0.0)
		camera.global_rotation = Vector3(
			deg_to_rad(drawn.pitch + punch.x + nod), deg_to_rad(drawn.yaw + punch.y),
			camera_roll + deg_to_rad(lean)
		)
		if third_person and camera.current:
			_place_third_person(drawn, delta)
		elif _tp_probe != null:
			_tp_probe.reset()
		# Widened from the player's own field of view, then zoomed by the aim: a scope at a run
		# is the scope's zoom of a slightly wider lens, and nothing compounds frame to frame.
		camera.fov = (_base_fov + widen) * _aim_fov_scale
	elif body_mesh != null:
		# A remote player. Its node is moved by `_net_interpolated`, so all that is
		# left is to face it the way its yaw says -- unless this machine ticks it, when
		# the body is drawn between ticks here (see `interpolate_body`). The node stays
		# where the tick put it: the hitboxes hang off it and are the simulation's.
		var yaw := drawn.yaw
		if interpolate_body:
			body_mesh.global_position = drawn.position
			var alpha := clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0)
			yaw = rad_to_deg(lerp_angle(deg_to_rad(_yaw_before_tick), deg_to_rad(drawn.yaw), alpha))
		_pose_body(drawn, yaw, delta)
		_present_held()
		_present_health_tag(delta)

	_animate_figure(drawn, delta)
	_present_beacon(delta, drawn.position)
	_mend_body()


## Tells the person how this player moves, and advances its clip. Client side.
##
## [b]From the drawn state[/b], the same one the body is placed from, so the stride matches the
## ground the body covers this frame. The weapon kind picks the arms: a gun, a melee weapon
## (a swing plays the slash over the legs), or empty hands.
func _animate_figure(drawn: DotFpsState, delta: float) -> void:
	if figure == null or body_mesh == null or not body_mesh.visible:
		return

	var v := drawn.velocity
	figure.set_motion({
		"on_floor": drawn.mode == DotFpsState.Mode.GROUND,
		"vertical": v.y,
		"crouched": drawn.crouch_fraction > 0.5,
		"swimming": drawn.mode == swim.mode_id,
		"climbing": drawn.mode == ladder.mode_id,
		"alive": is_alive(),
		# The view's pitch: the upper body, the arms and the gun follow it, so anybody watching
		# reads where this player is aiming.
		"aim": deg_to_rad(drawn.pitch),
	})

	var id := mirror_weapon if mirrored else (arsenal.current_def().id if arsenal != null and arsenal.current_def() != null else &"")
	var def := weapon_catalogue().get_def(id) if id != &"" else null
	var kind := DotHumanoidFigure.Hold.NONE
	if def != null:
		kind = DotHumanoidFigure.Hold.MELEE if def.slot == ZeeWeaponIds.SLOT_MELEE else (
			DotHumanoidFigure.Hold.NONE if def.slot == ZeeWeaponIds.SLOT_THROWN else DotHumanoidFigure.Hold.GUN)
	figure.set_hold(kind)

	var seq := mirror_fire_seq if mirrored else (weapons.fire_seq % ZeeWeaponNet.FIRE_SEQ_WRAP if weapons != null else 0)
	if ZeeWeaponNet.uses_between(_figure_fire_seq, seq) > 0 and kind == DotHumanoidFigure.Hold.MELEE:
		figure.swing()
	_figure_fire_seq = seq

	figure.animate(Vector2(v.x, v.z).length(), delta)


var _figure_fire_seq: int = 0


## Moves the camera from the eye to behind it, and draws the body where the eye is.
##
## [b]Swept from the eye, not set.[/b] dot-core's [DotCameraProbe] pulls the camera in ahead
## of a wall it is swinging toward and eases it back out; a camera simply placed 2.6 m back
## spends every corner inside the corner (the play test's death camera was exactly that).
## The body is placed on the drawn feet every frame, not left on this node: this node is
## moved by the tick, and a body drawn at the tick under a camera drawn per frame shakes.
func _place_third_person(drawn: DotFpsState, delta: float) -> void:
	if _tp_probe == null:
		_tp_probe = DotCameraProbe.new(camera.get_world_3d(), third_person_mask)
	_tp_probe.collision_mask = third_person_mask
	var pivot := view.global_position
	var wanted := pivot + camera.global_basis * THIRD_PERSON_OFFSET
	camera.global_position = _tp_probe.resolve(pivot, wanted, delta)

	if body_mesh != null:
		body_mesh.global_position = drawn.position
		_pose_body(drawn, drawn.yaw, delta)


## The controller's state as drawn at [param alpha] through its last tick, from -1 to 2.
##
## `DotFpsController.render_state` blends the last two ticks, 0 to 1. A connected client's
## alpha leaves that range for a fifth of a second after a physics frame that ran no tick or
## two (`DotNetClock.render_alpha` keeps the drawing where it was and takes the slip up
## slowly), and clamped there the eye stood still or jumped a tick, which is what the slip
## handling is for. Past 1 it goes on along the last tick's step; below 0 it is between the
## two ticks before, from [member _position_two_back].
func _render_state(alpha: float) -> DotFpsState:
	if is_nan(alpha):
		return controller.render_state()
	if alpha >= 0.0 and alpha <= 1.0:
		return controller.render_state(alpha)
	var drawn := controller.render_state(1.0 if alpha > 1.0 else 0.0)
	if drawn == controller.state:
		# A controller that does not blend hands back its state itself; never move that.
		return drawn
	if alpha > 1.0:
		var before := controller.render_state(0.0)
		drawn.position += (drawn.position - before.position) * minf(alpha - 1.0, 1.0)
	elif _position_two_back.is_finite():
		drawn.position = _position_two_back.lerp(drawn.position, maxf(alpha + 1.0, 0.0))
	return drawn


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


## What to take off the drawn eye this frame for stair steps: the step's share of the
## interpolated rise is moved into [member _step_offset], which eases out. A tick is a step
## when it is grounded and rose more than the steepest walkable floor allows for the ground it
## crossed, and no more than a step: a ramp's rise is steady and is drawn as it is.
func _absorb_step(alpha: float, delta: float) -> float:
	if step_smooth_time <= 0.0 or controller.tunables == null:
		return 0.0
	var state := controller.state
	if state.tick != _step_tick:
		# Moving on to a new tick drew whatever of the last tick's step was left.
		_step_offset += _step_rise - _step_drawn
		_step_tick = state.tick
		_step_rise = 0.0
		_step_drawn = 0.0
		var before := controller.render_state(0.0).position
		var rise := state.position.y - before.y
		var across := Vector2(state.position.x - before.x, state.position.z - before.z).length()
		var tunables := controller.tunables
		if (
			state.is_grounded()
			and rise > across * tan(tunables.max_slope_radians()) + 0.01
			and rise <= tunables.step_height + 0.01
		):
			_step_rise = rise
	var through := clampf(
		alpha if not is_nan(alpha) else Engine.get_physics_interpolation_fraction(), 0.0, 1.0
	)
	_step_offset += through * _step_rise - _step_drawn
	_step_drawn = through * _step_rise
	_step_offset *= exp(-delta / step_smooth_time)
	if absf(_step_offset) < 0.0005:
		_step_offset = 0.0
	return _step_offset


## The wall-run lean as drawn this frame, in degrees (positive leans left). For a check
## and for the frame-sequence render.
func wall_roll() -> float:
	return camera_motion.wall_roll() if camera_motion != null else 0.0


## This game's camera motion, at a setting of 1 (100%). Christian's pick, judged on rendered
## frame sequences (`tools/render_feel.sh landing strafe slide`, `render_wall_moves.sh`) and
## measured by `headless_feel`; docs/client.md has the reasoning for each number.
##
## - **Landing dip**: 6 cm at the deepest for a 16 m/s landing (a 5.8 m fall), nothing under
##   8 m/s, so a plain hop on flat ground (7.4 m/s) and a run of bunny hops dip nothing and a
##   drop off a ledge or a launch does. A 0.25 s recovery; a nod of 1 degree at the deepest.
## - **Strafe roll**: 1 degree at a 9 m/s strafe (the run), easing in and out at 8 a second;
##   1.5 more while sliding.
## - **Wall-run lean**: 6 degrees away from the wall at 6 a second, as before.
## - **Bound**: the three together never past 7 degrees.
## - **Widening**: none at or under the 9 m/s run, 4 degrees (vertical; about 5 at 4:3)
##   by 15 m/s, 2 more while sliding, 1 more on a wall; easing at 4 a second.
static func camera_motion_picks() -> DotFpsViewMotion:
	var m := DotFpsViewMotion.new()
	m.landing_dip = 0.06
	m.landing_reference_speed = 16.0
	m.landing_min_speed = 8.0
	m.landing_recovery = 0.25
	m.landing_pitch = 1.0
	m.strafe_roll = 1.0
	m.strafe_roll_reference = 9.0
	m.strafe_roll_response = 8.0
	m.slide_roll = 1.5
	m.wall_run_roll = 6.0
	m.wall_run_roll_response = 6.0
	m.roll_limit = 7.0
	m.fov_speed_gain = 4.0
	m.fov_speed_floor = 9.0
	m.fov_speed_reference = 15.0
	m.fov_response = 4.0
	m.slide_fov_gain = 2.0
	m.wall_run_fov_gain = 1.0
	return m


## Scales the camera motion from [method camera_motion_picks]: each argument 0 (off) to 2,
## 1 the pick. The player's `camera_*` settings, through `ArenaPresentation`; motion
## sickness is why each one goes to 0 on its own.
func set_camera_motion_scales(landing: float, strafe: float, wall: float, widen: float) -> void:
	if camera_motion == null:
		return
	var picks := camera_motion_picks()
	camera_motion.landing_dip = picks.landing_dip * maxf(landing, 0.0)
	camera_motion.landing_pitch = picks.landing_pitch * maxf(landing, 0.0)
	camera_motion.strafe_roll = picks.strafe_roll * maxf(strafe, 0.0)
	camera_motion.slide_roll = picks.slide_roll * maxf(strafe, 0.0)
	camera_motion.wall_run_roll = picks.wall_run_roll * maxf(wall, 0.0)
	camera_motion.roll_limit = picks.roll_limit * maxf(maxf(strafe, wall), 0.0)
	camera_motion.fov_speed_gain = picks.fov_speed_gain * maxf(widen, 0.0)
	camera_motion.slide_fov_gain = picks.slide_fov_gain * maxf(widen, 0.0)
	camera_motion.wall_run_fov_gain = picks.wall_run_fov_gain * maxf(widen, 0.0)


## A landing the eye has not reached yet: its impact (0 for none) and the tick it came on.
var _landing_impact: float = 0.0
var _landing_tick: int = -1


## Holds a landing until the drawn eye reaches the floor ([method _kick_landing]).
##
## [b]The signal comes a tick early for the eye.[/b] It is emitted by the tick that lands, and
## the frames after it still draw between the tick before (in the air) and that one; kicked
## there, the dip added to the last of the fall and the eye dropped 21 cm in two frames at
## 144 Hz instead of 20, then stopped. Kicked when the drawn eye is down, the dip starts where
## the fall ends.
func _on_landed(impact: float) -> void:
	if camera_motion == null:
		return
	_landing_impact = maxf(_landing_impact, impact)
	_landing_tick = controller.state.tick


## Kicks a held landing once [param drawn] is on the floor the landing tick left the player
## on, or a tick later at the latest.
func _kick_landing(drawn: DotFpsState) -> void:
	if _landing_impact <= 0.0:
		return
	if drawn.position.y > controller.state.position.y + 0.005 and controller.state.tick <= _landing_tick + 1:
		return
	camera_motion.note_landing(_landing_impact)
	_landing_impact = 0.0


## Sway, bob and the recoil's camera half, for the hands under the camera. Returns the
## punch in degrees (x pitch up, y yaw), which [method present] adds to the camera.
##
## [b]Added where the camera is written, never to the command.[/b] The shot already went
## where the command pointed; this is the view jolting as it does. And through
## `has_method`, because `view_punch` is newer than the client shell a pack may be running
## on, and a call by name to a method the shell's copy lacks fails to compile the script.
func _present_view_model(drawn: DotFpsState) -> Vector2:
	_aim_fov_scale = 1.0
	if weapons == null or weapons.view_model() == null:
		return Vector2.ZERO

	var view_model := weapons.view_model()
	# Nothing in the hands of somebody who is dead, watching someone else, or seen from behind.
	view_model.visible = is_alive() and camera.current and not third_person

	weapons.drive_view(
		Vector2(drawn.yaw, drawn.pitch),
		drawn.horizontal_speed(),
		drawn.is_grounded(),
		drawn.is_crouched()
	)

	# Aiming down: the hands come up, and the lens zooms by what the weapon's art says,
	# from the player's own field of view so a zoom never compounds. Dead or watching
	# somebody else, nobody is aiming.
	var hands := view_model as ZeeViewModel
	if hands != null:
		hands.aim(aim_held and is_alive() and camera.current)
		_aim_fov_scale = hands.aim_fov_scale()

	if not weapons.has_method(&"view_punch"):
		return Vector2.ZERO

	var punch: Vector2 = weapons.call(&"view_punch")
	return punch if punch.is_finite() else Vector2.ZERO


## Somebody else's gun: the one they are holding, kicking when they use it.
##
## [b]Two sources, one picture.[/b] A mirrored player is read from what the snapshot said
## ([member mirror_weapon], the counter); a player this machine simulates — an offline
## bot, or everybody on a listen server — from its own rig. Drawing the second from a
## counter as well is what keeps both on one code path.
func _present_held() -> void:
	if held == null:
		return

	var id := mirror_weapon
	var seq := mirror_fire_seq
	var kind := mirror_fire_kind
	var switching := mirror_switching

	if not mirrored and weapons != null and arsenal != null:
		var def := arsenal.current_def()
		id = def.id if def != null else &""
		seq = weapons.fire_seq % ZeeWeaponNet.FIRE_SEQ_WRAP
		kind = weapons.fire_kind
		switching = arsenal.is_switching()

	held.visible = is_alive()

	if id != held.equipped():
		var art: Variant = ZeeWeaponArtTable.table().get(id)
		if art is ZeeWeaponArt:
			var _drawn := held.equip(art as ZeeWeaponArt)
		else:
			held.clear()

	held.on_switching(switching)

	var fired := ZeeWeaponNet.uses_between(_seen_fire_seq, seq)
	_seen_fire_seq = seq

	# One kick however many uses the snapshot covered, the way `ZeeWeaponNet.apply` does:
	# a burst's worth of recoil in one frame reads as the gun jumping.
	if fired > 0 and is_alive():
		held.on_fired(WATCHED_RECOIL.get(kind, Vector2(0.6, 0.1)), kind)


## How far a watched gun kicks per kind of use. The real recoil is on an outcome that does
## not travel, so a watcher's is approximate on purpose — the same numbers the pack gives
## its own watchers, kept here because the pack's copy is private to it.
const WATCHED_RECOIL := {
	ZeeWeaponNet.KIND_SWING: Vector2(1.2, 0.0),
	ZeeWeaponNet.KIND_SPAWN: Vector2(2.0, 0.0),
	ZeeWeaponNet.KIND_THROW: Vector2(2.0, 0.0),
	ZeeWeaponNet.KIND_BEAM: Vector2(0.05, 0.0),
}


## The node a held weapon hangs from, by the name [ZeeWorldModel] asks for.
##
## [b]Duck-typed, which is the whole contract.[/b] `ZeeWorldModel.attach_to` takes any
## object answering `attachment(point)`, and the arena's avatar rig has a body, a head and
## a crest and no hand — so the player answers for it, with a hand placed where a figure
## this size holds a gun: chest high, right of centre, in front.
func attachment(point: StringName) -> Node3D:
	if figure != null:
		# The person's own hand, which moves with its clips.
		return figure.attachment(point)

	if point != &"right_hand" or body_mesh == null:
		return null

	if _hand == null:
		_hand = Node3D.new()
		_hand.name = "RightHand"
		_hand.position = HAND_POSITION
		body_mesh.add_child(_hand)

	return _hand


## Where [method attachment]'s hand is, in the body's frame. -Z is the way they face.
const HAND_POSITION := Vector3(0.26, 1.12, -0.34)


## Draws [member beacon], and says when it pings.
##
## [b]Only while alive.[/b] The flag outlives a death — dot-moderation re-applies it on the
## respawn — but a ring round a corpse that is about to vanish marks nothing, and a column
## over a spectating player's last position points everybody at an empty floor.
##
## Placed at the DRAWN position, which is the render state on the local player and the
## interpolated one on a remote player, for the reason [DotFxBeacon] is top level.
func _present_beacon(delta: float, at: Vector3) -> void:
	if not beacon or not is_alive():
		if beacon_marker != null:
			beacon_marker.queue_free()
			beacon_marker = null
		return

	if beacon_marker == null:
		beacon_marker = DotFxBeacon.new()
		beacon_marker.name = "Beacon"
		# Red-orange, the colour nothing else in a dev-textured arena is. Ping off: the game
		# plays its own catalogue ping (BEACON_SOUND) from advance()'s return, so the node's
		# would be heard twice.
		beacon_marker.colour = Color(1.0, 0.28, 0.18)
		beacon_marker.ring_radius = 0.78
		beacon_marker.column_height = 14.0
		beacon_marker.column_base = 2.1
		beacon_marker.ping_enabled = false
		add_child(beacon_marker)

	beacon_marker.local_view = camera != null
	beacon_marker.global_position = at

	if beacon_marker.advance(delta):
		beacon_pulsed.emit(at)


## Gives this player a camera and something to look at it with. Client side, local
## player only.
##
## [b]The field of view is horizontal-at-4:3, converted.[/b] Godot's `Camera3D.fov` is
## vertical and fixed; an arena shooter's 100 is horizontal on a 4:3 frame and widens
## on a wider screen. Handing 100 straight to Godot gives about 133 at 16:9 and a
## player who cannot aim and cannot say why.
func attach_camera(horizontal_fov_at_4_3: float = 100.0) -> Camera3D:
	if camera != null:
		# Already attached, so the only thing that can have changed is the field of view --
		# and a player who moves that slider and sees nothing happen has a setting that is
		# stored and read by nobody, which is this family's most repeated bug.
		set_field_of_view(horizontal_fov_at_4_3)
		return camera

	camera = Camera3D.new()
	camera.name = "Camera"
	camera.current = true
	camera.near = 0.05
	camera.far = 512.0

	# Only a player with a camera has the motion cues; the landing reaches them from the
	# controller's signal, which is not emitted during a prediction replay.
	camera_motion = camera_motion_picks()
	if controller != null and not controller.landed.is_connected(_on_landed):
		controller.landed.connect(_on_landed)

	set_field_of_view(horizontal_fov_at_4_3)

	# Parented to the game rather than to this player, and positioned globally every
	# frame. A camera hanging off the body inherits the body's per-tick position, which
	# is the stepping `present` exists to remove.
	add_child(camera)

	return camera


## Sets the horizontal field of view, converting to the vertical one Godot wants.
##
## The conversion is against 4:3 rather than against the window, which is the convention
## every game in this genre uses: a player who types 100 gets the same horizontal view on
## a 16:9 monitor and on an ultrawide, rather than a number that means something different
## on every screen.
func set_field_of_view(horizontal_fov_at_4_3: float) -> void:
	if camera == null:
		return
	var half := deg_to_rad(clampf(horizontal_fov_at_4_3, 40.0, 160.0) * 0.5)
	_base_fov = rad_to_deg(2.0 * atan(tan(half) * 3.0 / 4.0))
	camera.fov = _base_fov


## Something to see a remote player as.
##
## [b]An avatar when one is given, a capsule and a nose when one is not.[/b] The
## fallback is not a lesser case: a server with no dot-platform hands out nothing, a
## client that has not been told yet has nothing, and a player has to be visible in
## both. [ArenaAvatars.stock_avatar] closes most of that gap — it is a real document
## over the same schema, deterministic in the player id — so the capsule is what is
## left when even the schema is absent.
##
## [b]The avatar is what makes dot-user-avatar do anything here.[/b] Before this,
## `ArenaAvatars` built documents, `ArenaIdentity` resolved them and
## `ArenaPlayer` drew a coloured capsule — a value produced correctly and consumed by
## nobody, which is this family's most repeated shape and which the "a method whose
## name occurs once" detector is what caught.
func attach_body_mesh(colour: Color, avatar: DotAvatar = null) -> void:
	if body_mesh != null:
		return

	body_mesh = Node3D.new()
	body_mesh.name = "Body"
	add_child(body_mesh)

	if _wear(avatar):
		_hold_weapon()
		return

	_hold_weapon()

	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.85

	var trunk := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	trunk.mesh = capsule
	trunk.material_override = material
	trunk.position = Vector3(0.0, 0.9, 0.0)
	body_mesh.add_child(trunk)

	# A nose, so which way somebody is facing is visible from across the arena. Two
	# overlapping shapes need the smaller one OUTSIDE the larger or the silhouette is
	# one blob — game-playground drew every NPC icon as a coloured bar that way.
	var nose := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.16, 0.16, 0.35)
	nose.mesh = box
	nose.material_override = material
	nose.position = Vector3(0.0, 1.5, -0.45)
	body_mesh.add_child(nose)


## Hangs a [ZeeWorldModel] on [method attachment]'s hand. Client side, with the body.
func _hold_weapon() -> void:
	if held != null:
		return

	held = ZeeWorldModel.new()
	held.name = "Held"

	if not held.attach_to(self):
		held.free()
		held = null


## Draws [param next] in place of whatever this player is wearing. Client side.
##
## For a JOIN that re-describes somebody: the profile arrived after they were seated, or
## they changed. Nothing is rebuilt for the same document, a player whose body has not
## been built yet keeps the document for when it is, and null keeps what is drawn — the
## stock figure for anybody who never had one.
func rewear(next: DotAvatar) -> void:
	var before := avatar.digest() if avatar != null else ""
	avatar = next

	if next == null or body_mesh == null or before == next.digest():
		return

	remove_child(body_mesh)
	body_mesh.queue_free()
	body_mesh = null
	# The hand and the gun in it hung off the old body and went with it.
	_hand = null
	held = null
	figure = null
	attach_body_mesh(Color.WHITE, next)


## Builds the avatar's rig under [member body_mesh]. Returns whether anything drew.
##
## [b]A failure here falls back to the capsule rather than leaving nothing.[/b] A
## player who is invisible because their crest is from a newer build is worse than one
## drawn as a capsule — and `conform` already drops a part it does not have, so
## reaching this at all means the schema itself would not build.
func _wear(avatar: DotAvatar) -> bool:
	figure = DotHumanoidFigure.new()
	figure.name = "Person"
	body_mesh.add_child(figure)
	var height := controller.tunables.stand_height if controller != null and controller.tunables != null else 1.8
	figure.build(ArenaAvatars.look_of(avatar, StringName("arena-player-%08d" % player_id)), height)

	if not figure.from_art:
		DotLog.debug(CHANNEL, "the people's art is missing; using the capsule", {"player": player_id})
		body_mesh.remove_child(figure)
		figure.queue_free()
		figure = null
		return false

	var crest := ArenaAvatars.crest_of(avatar)
	var crown := figure.attachment(&"crest") if crest != null else null
	if crown != null:
		crown.add_child(crest)
	elif crest != null:
		crest.free()

	return true


## Where shots start: the eyes, not the feet.
##
## Read off the View node when there is one, because that is what the arsenal is handed to
## place a shot — computing it a second way here would let the server's idea of the
## muzzle drift from the one the shots actually came out of, and `_correct_origin`
## would then relocate every legitimate shot.
func muzzle_position() -> Vector3:
	if view != null and view.is_inside_tree():
		return view.global_position

	return controller.state.position + Vector3(0.0, 1.6, 0.0)


func aim_direction() -> Vector3:
	return _command.aim_direction()


## The current cone half-angle, for a crosshair.
##
## Asks the tuning rather than the behaviour, because a crosshair is drawn every frame
## and a behaviour is only stepped on a tick. A weapon whose tuning is not ballistic
## has no cone to draw and gets zero.
func spread_degrees() -> float:
	var slot := arsenal.current()

	if slot == null or not (slot.def.tuning is DotWeaponBallistics):
		return 0.0

	var state := controller.state
	var b: DotWeaponBallistics = slot.def.tuning

	return b.spread_for(
		state.horizontal_speed(), not state.is_grounded(), state.is_crouched()
	)


func _on_died(damage: DotDamage) -> void:
	make_dead()
	died.emit(damage)


func _on_used(outcome: DotWeaponOutcome) -> void:
	used.emit(outcome)


func describe() -> Dictionary:
	return {
		"id": player_id,
		"name": display_name,
		"team": team,
		"mode": Mode.keys()[mode],
		"position": controller.state.position,
		"health": health.describe(),
		"arsenal": arsenal.describe(),
		"weapons": weapons.describe() if weapons != null else {},
		"blinded": blinded,
		"beacon": beacon,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("%s (%d)  %s" % [display_name, player_id, "alive" if is_alive() else "dead"])
	out.append_array(health.describe_lines())
	out.append_array(arsenal.describe_lines())
	return out
