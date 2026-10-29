extends RefCounted
## The arena's movement tunables, held apart from the player so that file stays readable.

static func make() -> DotFpsTunables:
	var tunables := DotFpsTunables.with_profile("classic")
	tunables.walk_speed_scale = 0.45
	tunables.max_velocity = 400.0
	tunables.max_wish_speed = 0.0
	tunables.step_height = 0.4
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
	tunables.launch_velocity = 15.5
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
	# Touching a wall in the air starts a run (the heading turns along it); a press jumps off.
	tunables.wall_run_auto = true
	tunables.wall_run_on_jump = false
	tunables.wall_run_turn_view = true
	tunables.wall_run_cooldown = 0.4
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
	"wall_run_auto", "wall_run_on_jump", "wall_run_turn_view", "wall_run_jump_min_speed", "wall_run_jump_max_angle", "wall_run_cooldown",
	"wall_max_angle_from_vertical",
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
