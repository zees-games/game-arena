@tool
extends "arena_player_part1.gd"

const ArenaFlagCarry := preload("arena_flag_carry.gd")

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

## This player's body falls: a ragdoll copied from what is drawn, built in [param yard] as [param death] says.
## Client side, drawing only; the figure stays hidden until [method _mend_body] draws it on respawn. Null when the
## style hides bodies or there is no body to copy. [param gun_prop] false leaves the gun to a real dropped weapon.
func fall_body(yard: DotPlayerRagdolls, death: DotPlayerDeath, gun_prop: bool = true) -> DotPlayerRagdoll:
	if yard == null or body_mesh == null or not body_mesh.is_inside_tree():
		return null
	# Your own body in first person has no head; the one that falls has.
	if figure != null:
		figure.hide_head = false
	# The gun leaves the body first: copied into the ragdoll it stays on end in the raised hand.
	var gun_shown := held != null and held.visible
	if gun_shown and gun_prop:
		var _dropped := yard.drop_prop(held, controller.state.velocity)
	if gun_shown:
		held.visible = false
	var made := yard.spawn(body_mesh, death, controller.state.velocity)
	_fell = made != null or not body_mesh.visible
	if held != null and not _fell:
		held.visible = gun_shown
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

## The node a held weapon hangs from, by the name [AwWorldModel] asks for.
##
## [b]Duck-typed, which is the whole contract.[/b] `AwWorldModel.attach_to` takes any
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

## Somebody else's gun: the one they are holding, kicking when they use it.
##
## [b]Two sources, one picture.[/b] A mirrored player is read from what the snapshot said
## ([member mirror_weapon], the counter); a player this machine simulates — an offline
## bot, or everybody on a listen server — from its own rig. Drawing the second from a
## counter as well is what keeps both on one code path.
## The optional flat held sprite (`cl_weapon_sprites 1`), on the hand the model hangs from.
func _present_held_sprite(id: StringName) -> void:
	if not ArenaWeaponIcons.shared.sprites:
		if _held_sprite != null:
			_held_sprite.queue_free()
			_held_sprite = null
		return
	if _held_sprite == null:
		var hand := attachment(&"right_hand")
		if hand == null:
			return
		_held_sprite = ArenaSpriteWeapon.make(ArenaSpriteWeapon.Mode.HELD)
		hand.add_child(_held_sprite)
	_held_sprite.show_weapon(id)
	_held_sprite.visible = _held_sprite.visible and is_alive()

## [param remote]: a body this client only draws, whose gun build may wait for [method held_equip_allowed].
func _present_held(remote: bool = false) -> void:
	if held == null:
		return

	var id := mirror_weapon
	var seq := mirror_fire_seq
	var kind := mirror_fire_kind
	var switching := mirror_switching
	var reloading := mirror_reloading

	if not mirrored and weapons != null and arsenal != null:
		var def := arsenal.current_def()
		id = def.id if def != null else &""
		seq = weapons.fire_seq % AwWeaponNet.FIRE_SEQ_WRAP
		kind = weapons.fire_kind
		switching = arsenal.is_switching()
		reloading = arsenal.is_reloading()

	held.visible = is_alive() and not ArenaWeaponIcons.shared.sprites
	var t_sprite := Time.get_ticks_usec()
	_present_held_sprite(id)
	ArenaFrameProbe.add(&"r_held_sprite", t_sprite)

	# A remote body over this frame's budget keeps its old gun and tries again next frame.
	if id != held.equipped() and (not remote or id == &"" or held_equip_allowed()):
		var t_equip := Time.get_ticks_usec()
		var art: Variant = AwWeaponArtTable.table().get(id)
		if art is AwWeaponVisual:
			var _drawn := held.equip(art as AwWeaponVisual)
		else:
			held.clear()
		ArenaFrameProbe.add(&"r_held_equip", t_equip)

	var t_hooks := Time.get_ticks_usec()
	held.on_switching(switching)
	if held.has_method(&"on_reloading"):
		held.call(&"on_reloading", reloading and is_alive())

	if held.has_method(&"on_charge"):
		held.call(&"on_charge", mirror_charge if mirrored else 0.0)
	ArenaFrameProbe.add(&"r_held_hooks", t_hooks)

	var fired := AwWeaponNet.uses_between(_seen_fire_seq, seq)
	_seen_fire_seq = seq

	# One kick however many uses the snapshot covered, the way `AwWeaponNet.apply` does:
	# a burst's worth of recoil in one frame reads as the gun jumping.
	if fired > 0 and is_alive():
		var t_fired := Time.get_ticks_usec()
		held.on_fired(WATCHED_RECOIL.get(kind, Vector2(0.6, 0.1)), kind)
		ArenaFrameProbe.add(&"r_held_fired", t_fired)

## Hangs a [AwWorldModel] on [method attachment]'s hand. Client side, with the body.
func _hold_weapon() -> void:
	if held != null:
		return

	held = AwWorldModel.new()
	held.name = "Held"

	if not held.attach_to(self):
		held.free()
		held = null

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
	var height := controller.tunables.stand_height if controller != null and controller.tunables != null else ArenaPlayerTunables.stand_height_m()
	figure.build(ArenaAvatars.look_of(avatar, StringName("arena-player-%08d" % player_id)), height)
	# own_body_back already trails the body as the view tips down; the figure own trail would double it.
	figure.own_look_down_back = 0.0
	if controller != null and controller.tunables != null:
		# This game walks at about the stock run threshold: switch halfway between its walk and run.
		var t := controller.tunables
		var mid := t.max_speed * (1.0 + t.walk_speed_scale) * 0.5
		figure.set_run_speeds(mid, mid - 0.8)
		# This game's full run is a sprint: the run clip raced past 4x and popped a foot at full speed.
		figure.sprint_speed = 6.0

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
	capsule.radius = ArenaPlayerTunables.radius_m()
	capsule.height = ArenaPlayerTunables.stand_height_m()
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

## Your own body in first person: [param mode] is DotPlayerViewRules' BODY_OFF, BODY_LEGS or
## BODY_FULL. Client side, for the player at this keyboard; placed each frame by [method present]
## at the drawn feet, so it moves with the interpolated eye. The held gun's world model stays hidden.
func present_own_body(mode: int, _yaw: float = 0.0) -> void:
	own_body_mode = mode
	if third_person and is_alive() and camera != null and camera.current:
		# Seen from behind: the whole body and the gun in its hands. Placed by `present`.
		if body_mesh == null:
			attach_body_mesh(Color.WHITE, avatar)
		if _first_person != null:
			_first_person.restore()
		if figure != null:
			figure.first_person = DotHumanoidOwnView.THIRD
			figure.position = Vector3.ZERO
		body_mesh.visible = true
		_present_held()
		return

	if mode <= 0 or not is_alive() or camera == null or not camera.current:
		if _first_person != null:
			_first_person.restore()
		if figure != null:
			figure.first_person = DotHumanoidOwnView.THIRD
		if body_mesh != null:
			body_mesh.visible = false
		if held != null:
			held.visible = false
		return

	if body_mesh == null:
		attach_body_mesh(Color.WHITE, avatar)
	if held != null:
		held.visible = false
	body_mesh.visible = true
	if figure != null:
		figure.first_person = DotHumanoidOwnView.BODY if mode >= 2 else DotHumanoidOwnView.LEGS
		return
	if _first_person == null:
		_first_person = DotPlayerFirstPersonBody.new()
		_first_person.back_offset = 0.0
		# What to keep, by name: the box avatars' parts are not named what a hide list would guess.
		_first_person.shown_names = PackedStringArray(["leg", "foot", "shoe", "boot"])
	_first_person.apply(body_mesh)

## Where your own body stands behind the eye for a view pitch in degrees (negative is down).
func own_body_back(pitch: float) -> float:
	var base := FIRST_PERSON_BACK if own_body_mode >= 2 else FIRST_PERSON_BACK_LEGS
	var down := clampf(-pitch, 0.0, 90.0)
	var extra := first_person_look_down_back if look_down_back_override < 0.0 else look_down_back_override
	return base + extra * clampf((down - 60.0) / 25.0, 0.0, 1.0)

## In first person: places your own body, when one is drawn, at the drawn feet behind the eye, with the wall-run roll.
func _place_own_body(drawn: DotFpsState, delta: float) -> void:
	if _tp_probe != null:
		_tp_probe.reset()
	if own_body_mode <= 0 or body_mesh == null or not body_mesh.visible:
		return
	_pose_body(drawn, drawn.yaw, delta)
	var back := own_body_back(drawn.pitch)
	body_mesh.global_position = drawn.position + Basis(Vector3.UP, deg_to_rad(drawn.yaw)) * Vector3(0.0, 0.0, back)

## What the body is doing now as [enum DotFpsState.Move] bits; remote players too (from the replicated state).
func move_flags() -> int:
	return controller.state.move_flags() if controller != null and controller.state != null else 0

## The light follows the rising edge of the switch bit, on the machine that decides (offline or the server).
func _flashlight_hands(pressed: bool, delta: float) -> void:
	var edge := pressed and not _flashlight_held
	_flashlight_held = pressed
	if flashlight_cfg == null:
		return
	if not flashlight_ready:
		flashlight_ready = true
		flashlight = ArenaFlashlight.starts_on(flashlight_cfg, flashlight_map)
	if edge and is_alive() and flashlight_cfg.enabled and DotFlashlightRules.allowed_on(flashlight_cfg, flashlight_map):
		flashlight = not flashlight and DotFlashlightRules.can_light(flashlight_cfg, flashlight_charge)
	if flashlight_cfg.battery:
		flashlight_charge = DotFlashlightRules.step_charge(flashlight_cfg, flashlight_charge, flashlight, delta)
		if flashlight and flashlight_charge <= 0.0:
			flashlight = false

# --- Simulation ------------------------------------------------------------

## Advances the player one tick. [b]The order is not arbitrary.[/b] Movement runs first so the shot
## leaves from where the player ends the tick rather than where they started it — half a tick of
## movement at arena speeds is fifteen centimetres, which at range is a miss.
## Squeezes the hit zones down with the body. The zones are authored for a standing player; a crouched one is drawn
## about a quarter lower, so without this the head zone floated above the crouched head and a shot at the drawn head
## landed on the chest. Heights (and capsule lengths) scale, widths do not, and the feet stay on the ground.
func fit_hitboxes_to_stance() -> void:
	if hitboxes == null or controller == null or controller.tunables == null:
		return
	var t := controller.tunables
	var k := lerpf(1.0, t.crouch_height / maxf(t.stand_height, 0.01), clampf(controller.state.crouch_fraction, 0.0, 1.0))
	if ArenaHullGrid.enabled and k == _fit_k:
		return
	_fit_k = k
	for box in hitboxes.hitboxes():
		if not box.has_meta(&"stand_y"):
			box.set_meta(&"stand_y", box.position.y)
			box.set_meta(&"stand_h", box.height)
		var y: float = box.get_meta(&"stand_y")
		var h: float = box.get_meta(&"stand_h")
		box.position.y = y * k
		if box.shape == DotHitbox.Shape.CAPSULE:
			box.height = maxf(h * k, box.radius * 2.0 + 0.02)


## Sideways speed across the aim (positive right) that bends the wall-shot barrel; zero while wall-running, as the drawn view does.
static func wall_shot_strafe(state: DotFpsState) -> float:
	if state.is_wall_running():
		return 0.0
	return state.velocity.dot(Basis(Vector3.UP, deg_to_rad(state.yaw)).x)


## Set by the objectives each tick while this player carries a flag under the one-handed rule.
var flag_one_hand := false

func simulate_tick(
	tick: int,
	delta: float,
	movement_command: DotFpsCommand,
	combat_command: DotWeaponCommand
) -> DotWeaponOutcome:
	if not health.alive:
		return DotWeaponOutcome.nothing("Dead.")
	tick_pre(tick, movement_command)
	var t_ctl := Time.get_ticks_usec()
	controller.simulate_tick(tick, delta)
	ArenaFrameProbe.add(&"p_controller", t_ctl)
	return tick_post(tick, delta, combat_command)


## Where this tick started ([method tick_pre]) and what its controller cost before the motor (the batched loop's).
var _tick_start := Vector3.ZERO
var ctl_usec := 0


## [method simulate_tick] up to the controller's tick; the game's batched loop runs the controller's two halves itself.
func tick_pre(tick: int, movement_command: DotFpsCommand) -> void:
	var fine := ArenaFrameProbe.fine
	var t_fine := Time.get_ticks_usec() if fine else 0
	# Where the tick starts, for the pushes: "was this player in a booster last tick" is
	# asked of this position rather than remembered. See `arena_map_mechanics.gd`.
	_tick_start = controller.state.position
	_yaw_before_tick = controller.state.yaw
	# The previous state's position before this tick replaces it: two ticks back after it.
	_position_two_back = controller.render_state(0.0).position
	ladder.now = tick
	var view := DotFpsMotor._view_basis(controller.state.yaw, 0.0)
	var intent: Vector3 = view.right * movement_command.move.x + view.forward * movement_command.move.y
	ladder.wish = Vector3(intent.x, 0.0, intent.z).normalized()
	_hull_tick = tick
	controller.apply_command(movement_command)
	if fine:
		ArenaFrameProbe.add(&"p_pre", t_fine)


## [method simulate_tick] after the controller's tick: the map's mechanics, the health and the weapons.
func tick_post(tick: int, delta: float, combat_command: DotWeaponCommand) -> DotWeaponOutcome:
	var fine := ArenaFrameProbe.fine
	var t_fine := Time.get_ticks_usec() if fine else 0
	fit_hitboxes_to_stance()
	if fine:
		ArenaFrameProbe.add(&"p_hitbox", t_fine)
	var t_mech := Time.get_ticks_usec()
	_run_map_mechanics(_tick_start, delta)
	_follow_map_volumes()
	ArenaFrameProbe.add(&"p_mechanics", t_mech)
	if fine:
		t_fine = Time.get_ticks_usec()

	var state := controller.state

	# The aim comes from the movement command, not from a second sample. Sampling the
	# mouse twice gives a shot that leaves at a different angle than the one the
	# player was looking along.
	_command = combat_command.duplicate_command()
	_command.yaw = state.yaw
	_command.pitch = state.pitch
	ArenaFlagCarry.filter_command(self, _command)
	aiming = _command.is_pressed(BUTTON_AIM)
	_flashlight_hands(_command.is_pressed(ArenaFlashlight.BUTTON), delta)

	health.tick(tick, delta)

	# Read once: it walks the view's global transform, and the combat origin and the weapon context want the same point.
	var muzzle := muzzle_position()
	if _combat != null:
		_combat.set_authoritative_origin(player_id, muzzle)

	# A shooter with nothing pressed and nothing under way ticks the weapon in hand and no more: the rig
	# builds its own posture then, so the context below (a dozen writes and an extra dictionary) is skipped.
	var t_wp := Time.get_ticks_usec()
	var out: DotWeaponOutcome
	# (Proper home: AwWeaponRig.would_idle(command) in arena-weapons; until it exists, ask the arsenal directly.)
	# The posture feeds the spread (running, air, slide and crouch change the cone): the arsenal asks
	# [method _idle_posture] for the same fields the context below gets, so a moving player takes this path too.
	_posture_tick = tick
	if weapons.arsenal.is_idle_for(_command, weapons.get(&"_previous_command")):
		out = weapons.simulate_tick(_command, tick, null)
		ArenaFrameProbe.add(&"p_weapons", t_wp)
		return out
	t_wp = Time.get_ticks_usec()
	# Pushed in from the simulated state, never read out of a rendered one: an
	# interpolated position differs between client and server by design, and feeding it
	# to the spread makes the spread differ too.
	var ctx := DotWeaponContext.make(
		player_id, tick, muzzle, _command.aim_direction()
	)
	ctx.speed = state.horizontal_speed()
	ctx.airborne = not state.is_grounded()
	ctx.crouched = state.is_crouched()
	ctx.sliding = state.is_sliding()
	ctx.sprinting = state.sprinting
	ctx.wall_running = state.is_wall_running()
	ctx.hurt_tick = health.last_damage_tick if health.last_damage_tick >= 0 else -1
	ctx.sprint_blocks_fire = not controller.tunables.sprint_can_shoot
	ctx.sprint_shot_follows_barrel = controller.tunables.sprint_shot_follows_barrel
	ctx.authority = arsenal.authority
	# Sideways speed across the aim, positive right: the client's gun tilts with it, so the wall shot must too.
	ctx.extra[&"strafe"] = wall_shot_strafe(state)
	if fine:
		ArenaFrameProbe.add(&"p_wctx", t_fine)

	# Through the rig, which runs the arsenal and then the bash. It keeps the previous
	# command itself, for the same edge triggers the arsenal used to be handed it for.
	out = weapons.simulate_tick(_command, tick, ctx)
	ArenaFrameProbe.add(&"p_weapons", t_wp)
	return out

## Whether the body is drawn sliding: the replicated slide timer (net_flags), for bots, humans and remote copies alike.
func _drawn_sliding(drawn: DotFpsState) -> bool:
	return (drawn.move_flags() & DotFpsState.Move.SLIDE) != 0 and drawn.mode == DotFpsState.Mode.GROUND

## Tells the person how this player moves, and advances its clip. Client side.
##
## [b]From the drawn state[/b], the same one the body is placed from, so the stride matches the
## ground the body covers this frame. The weapon kind picks the arms: a gun, a melee weapon
## (a swing plays the slash over the legs), or empty hands.
func _animate_figure(drawn: DotFpsState, delta: float) -> void:
	if figure == null or body_mesh == null or not body_mesh.visible:
		return

	var v := drawn.velocity
	# One dictionary per player, rewritten in place: a fresh one per body per frame was 32 dictionaries a frame.
	var motion := _figure_motion
	motion["on_floor"] = drawn.mode == DotFpsState.Mode.GROUND
	motion["vertical"] = v.y
	motion["crouched"] = drawn.crouch_fraction > 0.5
	motion["sliding"] = _drawn_sliding(drawn)
	motion["swimming"] = drawn.mode == swim.mode_id
	motion["climbing"] = drawn.mode == ladder.mode_id
	motion["alive"] = is_alive()
	motion["wall_running"] = drawn.is_wall_running()
	motion["velocity"] = v
	motion["wall"] = Plane(drawn.wall_normal, drawn.position - drawn.wall_normal * (controller.tunables.radius if controller != null else 0.35)) if drawn.wall_normal != Vector3.ZERO else Plane()
	# The view's pitch: the upper body, the arms and the gun follow it, so anybody watching
	# reads where this player is aiming.
	motion["aim"] = deg_to_rad(drawn.pitch)
	figure.set_motion(motion)

	var held_def: DotWeaponDef = arsenal.current_def() if arsenal != null else null
	var id := mirror_weapon if mirrored else (held_def.id if held_def != null else &"")
	# The hold follows the weapon: looked up (catalogue, slot tests) and set only when the weapon changes.
	if id != _figure_hold_id or _figure_hold_kind < 0:
		var def := weapon_catalogue().get_def(id) if id != &"" else null
		var picked := DotHumanoidFigure.Hold.NONE
		if def != null:
			picked = DotHumanoidFigure.Hold.MELEE if def.slot == AwWeaponIds.SLOT_MELEE else (
				DotHumanoidFigure.Hold.NONE if def.slot == AwWeaponIds.thrown_slot() else DotHumanoidFigure.Hold.GUN)
		_figure_hold_id = id
		_figure_hold_kind = picked
	var kind: int = _figure_hold_kind
	figure.set_hold(kind)

	var seq := mirror_fire_seq if mirrored else (weapons.fire_seq % AwWeaponNet.FIRE_SEQ_WRAP if weapons != null else 0)
	if AwWeaponNet.uses_between(_figure_fire_seq, seq) > 0 and kind == DotHumanoidFigure.Hold.MELEE:
		figure.swing()
	_figure_fire_seq = seq

	figure.animate(Vector2(v.x, v.z).length(), delta)

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

## Draws [member protected_view] as a bubble round the body. Not on your own camera (inside it you would
## see nothing but its inner edge), and only while alive.
func _present_bubble(at: Vector3) -> void:
	var want := protected_view and is_alive() and not (camera != null and camera.current)
	if not want:
		if protection_bubble != null:
			protection_bubble.sync(false)
		return
	if protection_bubble == null:
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
