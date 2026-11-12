@tool
extends "arena_player_part2.gd"

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
		drawn.position += (drawn.position - controller.previous_position()) * minf(alpha - 1.0, 1.0)
	elif _position_two_back.is_finite():
		drawn.position = _position_two_back.lerp(drawn.position, maxf(alpha + 1.0, 0.0))
	return drawn

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
		var before := controller.previous_position()
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
	_view_fov_scale = 1.0
	if weapons == null or weapons.view_model() == null:
		return Vector2.ZERO

	var view_model := weapons.view_model()
	# Nothing in the hands of somebody who is dead, watching someone else, or seen from behind.
	view_model.visible = is_alive() and camera.current and not third_person

	weapons.drive_view(
		Vector2(drawn.yaw, drawn.pitch),
		drawn.horizontal_speed(),
		drawn.is_grounded(),
		drawn.is_crouched(),
		0.0 if drawn.is_wall_running() else NAN
	)

	# Aiming down: the hands come up, and the lens zooms by what the weapon's art says,
	# from the player's own field of view so a zoom never compounds. Dead or watching
	# somebody else, nobody is aiming.
	var hands := view_model as AwViewModel
	if hands != null:
		hands.aim(aim_held and is_alive() and camera.current)
		ArenaScopePrefs.apply(hands)
		_aim_fov_scale = hands.aim_fov_scale()
		_view_fov_scale = hands.view_fov_scale()

	if not weapons.has_method(&"view_punch"):
		return Vector2.ZERO

	var punch: Vector2 = weapons.call(&"view_punch")
	return punch if punch.is_finite() else Vector2.ZERO

## The process frame the last [DotSpawnBubble3D] was made on: [method _present_bubble] makes one a frame.
static var _bubble_made_frame := -1

## Draws [member protected_view] as a bubble round the body. Not on your own camera (inside it you would
## see nothing but its inner edge), and only while alive.
func _present_bubble(at: Vector3) -> void:
	var want := protected_view and is_alive() and not (camera != null and camera.current) and not beyond_figure
	if not want:
		if protection_bubble != null:
			protection_bubble.sync(false)
		return
	if protection_bubble == null:
		# A new bubble compiles its own shader, 26 ms on staging02: a map change respawning 31
		# bodies at once made 300-400 ms frames. One a frame; the rest show over the next few.
		if Engine.get_process_frames() == _bubble_made_frame:
			return
		_bubble_made_frame = Engine.get_process_frames()
		protection_bubble = DotSpawnBubble3D.new()
		protection_bubble.name = "SpawnBubble"
		protection_bubble.top_level = true
		add_child(protection_bubble)
	protection_bubble.global_position = at
	protection_bubble.sync(true)


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
