@tool
extends "arena_player_part2.gd"

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
		# Written globally, not by moving this node: it is the controller's body, and
		# reconciliation would read the move back as what the client is showing.
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

		var shift := camera_motion.eye_shift() if camera_motion != null else Vector3.ZERO
		camera.global_position = view.global_position + camera_offset + Vector3(0.0, dip, 0.0) + shift
		camera.global_rotation = Vector3(
			deg_to_rad(drawn.pitch + punch.x + nod), deg_to_rad(drawn.yaw + punch.y),
			camera_roll + deg_to_rad(lean)
		)
		if third_person and camera.current:
			_place_third_person(drawn, delta)
		else:
			_place_own_body(drawn, delta)
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

## [method present] for a remote body, one frame in [constant LOD_EVERY] while it is behind or
## beside the viewer. Only the drawing is thinned: the tick and the hitboxes are untouched.
func present_lod(delta: float, eye: Vector3, forward: Vector3) -> void:
	if camera == null and present_lod_enabled:
		var to := global_position - eye
		var d2 := to.length_squared()
		if d2 > LOD_NEAR * LOD_NEAR and to.dot(forward) < LOD_CONE * sqrt(d2):
			_lod_frames += 1
			_lod_delta += delta
			if _lod_frames < LOD_EVERY:
				return
			delta = _lod_delta
	_lod_frames = 0
	_lod_delta = 0.0
	present(delta)

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
## - **Strafe roll**: 1 degree at a 5.74 m/s strafe (the run), easing in and out at 8 a second;
##   1.5 more while sliding.
## - **Wall-run lean**: 3.5 degrees toward the wall (negative wall_run_roll) at 6 a second.
## - **Bound**: the three together never past 7 degrees.
## - **Widening**: none at or under the 5.74 m/s run, 4 degrees (vertical; about 5 at 4:3)
##   by 15 m/s, 2 more while sliding, 1 more on a wall; easing at 4 a second.
static func camera_motion_picks() -> DotFpsViewMotion:
	var m := DotFpsViewMotion.new()
	m.landing_dip = 0.06
	m.landing_reference_speed = 16.0
	m.landing_min_speed = 8.0
	m.landing_recovery = 0.25
	m.landing_pitch = 1.0
	m.strafe_roll = 1.0
	m.strafe_roll_reference = 5.74
	m.strafe_roll_response = 8.0
	m.slide_roll = 1.5
	m.wall_run_roll = -3.5
	m.wall_run_eye_shift = 0.3
	m.wall_run_roll_response = 6.0
	m.roll_limit = 5.0
	m.fov_speed_gain = 4.0
	m.fov_speed_floor = 5.74
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
	camera_motion.wall_run_eye_shift = picks.wall_run_eye_shift * clampf(wall, 0.0, 1.0)
	camera_motion.roll_limit = picks.roll_limit * maxf(maxf(strafe, wall), 0.0)
	camera_motion.fov_speed_gain = picks.fov_speed_gain * maxf(widen, 0.0)
	camera_motion.slide_fov_gain = picks.slide_fov_gain * maxf(widen, 0.0)
	camera_motion.wall_run_fov_gain = picks.wall_run_fov_gain * maxf(widen, 0.0)

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

## The field-of-view fraction the sights give now (1 unaimed); the mouse look scales by it.
func aim_zoom() -> float:
	return _aim_fov_scale

## A remote player's selector switch, heard from their hand.
func mirror_mode_click() -> void:
	if not is_inside_tree() or mirror_weapon == &"":
		return
	if _mode_click_audio == null:
		_mode_click_audio = AudioStreamPlayer3D.new()
		_mode_click_audio.unit_size = 4.0
		_mode_click_audio.max_distance = 30.0
		add_child(_mode_click_audio)
	_mode_click_audio.stream = AwWeaponSound.stream(AwWeaponSound.mode_click_for(mirror_weapon))
	_mode_click_audio.play()

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
	_held_sprite = null
	figure = null
	attach_body_mesh(Color.WHITE, next)

func aim_direction() -> Vector3:
	return _command.aim_direction()

## The current cone half-angle, for a crosshair.
##
## Asks the tuning rather than the behaviour, because a crosshair is drawn every frame
## and a behaviour is only stepped on a tick. A weapon whose tuning is not ballistic
## has no cone to draw and gets zero.
func spread_degrees() -> float:
	var rules: Variant = arsenal.spread_rules
	if rules != null and rules.enabled:
		return arsenal.spread_now()

	var slot := arsenal.current()

	if slot == null or not (slot.def.tuning is DotWeaponBallistics):
		return 0.0

	var state := controller.state
	var b: DotWeaponBallistics = slot.def.tuning

	return b.spread_for(
		state.horizontal_speed(), not state.is_grounded(), state.is_crouched()
	)

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
