extends RefCounted
## Carrying a flag: the drop key, a thrown flag's flight, the one-handed rule, and where the flag is held.
## The server runs the rules; a client learns them from the ctf wire ("fc") and only draws.

## A carrier holds only one-handed items: the melee weapon, the sidearm and the thrown slot (arena_ctf_one_hand).
static var one_hand := true
## The drop key drops a carried flag ahead of the aim (arena_ctf_drop_key).
static var drop_key := true
## Metres a second a dropped flag leaves the hand at, along the aim, on top of the carrier's own speed (arena_ctf_drop_speed).
static var drop_speed := 4.0
## A dropped flag falls, slides and bounces (arena_ctf_flag_physics); off, it is put on the floor at once.
static var physics := true
## This client holds its own flag in the right hand (cl_lefthand); in first person only, as others are not told.
static var left_handed := false

const GRAVITY := 20.0
## Metres a second lost each second sliding on the floor.
const FRICTION := 7.0
## Share of the speed kept off a wall or a hard landing.
const BOUNCE := 0.35
## The flag's foot is a ball this wide; probes start this far above it.
const RADIUS := 0.2
const BODY_UP := 0.3
## How far ahead of the eye the flag leaves the hand.
const REACH := 0.9
## Falling this fast it left the world: it goes home.
const LOST_SPEED := 60.0

## Third person: where the hand holds the pole, from the feet (side, up, forward).
const BODY_GRIP := Vector3(0.3, 1.0, 0.12)
## First person: from the eye, low at the shoulder side, so it shows looking down or that way.
const EYE_GRIP := Vector3(0.34, -0.72, 0.1)
## How far up the carried (scaled) pole the hand holds it.
const GRIP_ALONG := 0.7


## A server setting by its name, for the cvars.
static func setting(key: String) -> Variant:
	match key:
		"one_hand": return one_hand
		"drop_key": return drop_key
		"drop_speed": return drop_speed
		"physics": return physics
	return null


static func set_setting(key: String, text: String) -> void:
	match key:
		"one_hand": one_hand = text.to_float() != 0.0
		"drop_key": drop_key = text.to_float() != 0.0
		"drop_speed": drop_speed = maxf(text.to_float(), 0.0)
		"physics": physics = text.to_float() != 0.0


## The flag [param id] carries, or null.
static func carried(game, id: int) -> DotObjectiveFlag:
	var objectives = game.objectives if game != null else null
	if objectives == null or objectives.ctf == null:
		return null
	return objectives.ctf.carried_by(str(id))


## The slots a carrier may hold, in the order a forced switch tries them.
static func allowed_slots() -> Array[int]:
	return [AwWeaponIds.SLOT_SIDEARM, AwWeaponIds.SLOT_MELEE, AwWeaponIds.thrown_slot()]


## Both ends, before the arsenal runs: a carrier's slot keys only reach one-handed items, and a two-handed one in hand is put away.
static func filter_command(player, cmd: DotWeaponCommand) -> void:
	if not player.flag_one_hand or player.arsenal == null:
		return
	var arsenal: DotWeaponArsenal = player.arsenal
	var owned: Array[int] = []
	for s in allowed_slots():
		if arsenal.has_slot(s):
			owned.append(s)
	if cmd.slot > 0 and not owned.has(cmd.slot):
		cmd.slot = 0
	var cur := arsenal.current_slot()
	var step := 1 if cmd.is_pressed(DotWeaponCommand.BUTTON_NEXT) else (-1 if cmd.is_pressed(DotWeaponCommand.BUTTON_PREVIOUS) else 0)
	cmd.set_button(DotWeaponCommand.BUTTON_NEXT, false)
	cmd.set_button(DotWeaponCommand.BUTTON_PREVIOUS, false)
	cmd.set_button(DotWeaponCommand.BUTTON_LAST, false)
	if owned.is_empty():
		cmd.slot = 0
		return
	if step != 0 and cmd.slot == 0:
		var ring := owned.duplicate()
		ring.sort()
		var at := ring.find(cur)
		cmd.slot = ring[0] if at < 0 else ring[(at + step + ring.size()) % ring.size()]
	if cmd.slot == 0 and not owned.has(cur):
		cmd.slot = owned[0]


## Both ends, each tick: who carries, for [method filter_command] (the server's rule; a client has it from the wire).
static func mark_carriers(objectives) -> void:
	var game = objectives.game
	var ctf: DotObjectiveCtf = objectives.ctf
	# One flags() pass a tick instead of one carried_by (a new flags() array) per player.
	var carriers := {}
	if one_hand and ctf != null:
		for f in ctf.flags():
			if f.state == DotObjectiveFlag.State.CARRIED:
				carriers[f.carrier] = true
	for id in game.player_ids():
		var player = game.player_for(id)
		if player != null:
			player.flag_one_hand = carriers.has(str(id))


## Server: the drop key while carrying drops the flag ahead of the aim. True when it did (the weapon stays in hand).
static func try_drop(game, id: int, player) -> bool:
	if not drop_key or not game.is_authority:
		return false
	var flag := carried(game, id)
	if flag == null:
		return false
	var eye: Vector3 = player.muzzle_position()
	var aim: Vector3 = player.aim_direction()
	var at := eye + aim * REACH
	var trace = _trace(game)
	if trace != null:
		var hit: DotHitbox.Hit = trace._world_ray(eye, aim, REACH + RADIUS)
		if hit.ok():
			at = eye + aim * maxf(hit.distance - RADIUS, 0.0)
	at += Vector3.DOWN * BODY_UP
	if not physics:
		at = _floor_below(trace, at)
	if not flag.drop(at).ok:
		return false
	var motion: Dictionary = game.objectives.flag_motion
	motion[flag.home_team()] = aim * drop_speed + player.controller.state.velocity if physics else Vector3.INF
	return true


## Server, each tick after the flags advance: a dropped flag in flight falls, slides to a stop and bounces off walls.
## Only its foot moves, so it stays upright. A death drop starts with half the carrier's speed.
static func step(objectives, delta: float) -> void:
	var motion: Dictionary = objectives.flag_motion
	var game = objectives.game
	var trace = _trace(game)
	for flag: DotObjectiveFlag in objectives.ctf.flags():
		var team: int = flag.home_team()
		if flag.state != DotObjectiveFlag.State.DROPPED:
			motion.erase(team)
			continue
		if not motion.has(team):
			var v := Vector3.ZERO
			var by = game.player_for(int(flag.dropper)) if flag.dropper.is_valid_int() else null
			if by != null and by.controller != null:
				v = by.controller.state.velocity * 0.5
			motion[team] = v if physics else Vector3.INF
		var vel: Vector3 = motion[team]
		if vel == Vector3.INF or trace == null:
			continue
		var out := fly(trace, flag.at, vel, delta)
		flag.at = out[0]
		motion[team] = Vector3.INF if out[2] else out[1]
		if (out[1] as Vector3).y < -LOST_SPEED:
			var _home: DotResult = flag.send_home("")
			motion.erase(team)


## One step of a flag's foot at [param at] with [param vel]: [new at, new velocity, at rest].
static func fly(trace, at: Vector3, vel: Vector3, delta: float) -> Array:
	vel.y -= GRAVITY * delta
	var flat := Vector3(vel.x, 0.0, vel.z) * delta
	if flat.length() > 0.0001:
		var dir := flat.normalized()
		var wall: DotHitbox.Hit = trace._world_ray(at + Vector3.UP * BODY_UP, dir, flat.length() + RADIUS)
		if wall.ok():
			var n := Vector3(wall.normal.x, 0.0, wall.normal.z)
			var side := Vector3(vel.x, 0.0, vel.z)
			side = side.bounce(n.normalized()) * BOUNCE if n.length() > 0.01 else Vector3.ZERO
			vel.x = side.x
			vel.z = side.z
			at += dir * maxf(wall.distance - RADIUS, 0.0)
		else:
			at += flat
	var grounded := false
	var fall := vel.y * delta
	if fall <= 0.0:
		var floor_hit: DotHitbox.Hit = trace._world_ray(at + Vector3.UP * BODY_UP, Vector3.DOWN, BODY_UP - fall + 0.02)
		if floor_hit.ok():
			at.y = floor_hit.point.y
			grounded = true
			vel.y = -vel.y * BOUNCE if vel.y < -6.0 else 0.0
		else:
			at.y += fall
	else:
		var roof: DotHitbox.Hit = trace._world_ray(at + Vector3.UP * BODY_UP, Vector3.UP, fall + 0.2)
		if roof.ok():
			vel.y = 0.0
		else:
			at.y += fall
	var rest := false
	if grounded and vel.y == 0.0:
		var side := Vector3(vel.x, 0.0, vel.z)
		var speed := side.length()
		var left := maxf(speed - FRICTION * delta, 0.0)
		side = side * (left / speed) if speed > 0.0 else Vector3.ZERO
		vel.x = side.x
		vel.z = side.z
		rest = left < 0.05
		if rest:
			vel = Vector3.ZERO
	return [at, vel, rest]


## The server's carry rule and which flags fly, into the ctf wire.
static func write_wire(objectives, wire: Dictionary) -> void:
	var moving := []
	for team: int in objectives.flag_motion:
		if objectives.flag_motion[team] != Vector3.INF:
			moving.append(team)
	wire["fc"] = {"oh": 1 if one_hand else 0, "mv": moving}


## A client takes the carry rule and the flying flags from the wire.
static func read_wire(objectives, wire: Dictionary) -> void:
	var fc: Dictionary = wire.get("fc", {})
	if fc.has("oh"):
		one_hand = int(fc["oh"]) != 0
	objectives.flag_motion.clear()
	for team: Variant in fc.get("mv", []):
		objectives.flag_motion[int(team)] = Vector3.ZERO


## Whether [param team]'s dropped flag is in flight (both ends).
static func flying(game, team: int) -> bool:
	var objectives = game.objectives if game != null else null
	return objectives != null and objectives.flag_motion.has(team) and objectives.flag_motion[team] != Vector3.INF


## Client, every frame: puts a carried flag's [param view] in its carrier's hand. From the carrier's own
## eye it hangs low at the shoulder side (the right one with cl_lefthand); for everyone else it is held
## upright against the body in the free left hand, the left arm reaching for it.
static func pose_view(view: Node3D, carrier: Node3D, cam: Camera3D, scale: float) -> void:
	var eye := carrier.global_position + Vector3.UP * 1.4
	var first := cam != null and cam.global_position.distance_to(eye) <= 1.2
	var yaw_from: Basis = cam.global_basis if first else carrier.global_basis
	var fwd := -yaw_from.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var right := fwd.cross(Vector3.UP).normalized()
	var side := right if (first and left_handed) else -right
	var grip: Vector3
	var up: Vector3
	if first:
		grip = cam.global_position + side * EYE_GRIP.x + Vector3.UP * EYE_GRIP.y + fwd * EYE_GRIP.z
		up = (Vector3.UP + side * 0.18 - fwd * 0.12).normalized()
	else:
		var crouch := 0.0
		var controller = carrier.get(&"controller")
		if controller != null and controller.state != null and controller.state.is_crouched():
			crouch = 0.35
		grip = carrier.global_position + side * BODY_GRIP.x + Vector3.UP * (BODY_GRIP.y - crouch) + fwd * BODY_GRIP.z
		up = (Vector3.UP - fwd * 0.22 + side * 0.08).normalized()
	# The banner trails behind the pole.
	var back := -fwd
	var x := (back - up * back.dot(up)).normalized()
	var z := x.cross(up).normalized()
	view.global_transform = Transform3D(Basis(x, up, z).scaled_local(Vector3.ONE * scale), grip - up * GRIP_ALONG)
	_hold_with_arm(carrier, grip, not first)
	for part: StringName in [&"Beam", &"Tag"]:
		var node := view.get_node_or_null(NodePath(part)) as Node3D
		if node == null:
			continue
		if first:
			node.visible = false
			node.set_meta(&"carry_hid", true)
		elif node.has_meta(&"carry_hid"):
			node.remove_meta(&"carry_hid")
			node.visible = true


## The left arm reaches for the pole (the figure's two-hand reach, aimed at the flag), or lets go.
static func _hold_with_arm(carrier: Node3D, grip: Vector3, on: bool) -> void:
	if carrier == null or not is_instance_valid(carrier):
		return
	var figure = carrier.get(&"figure")
	if figure == null or not is_instance_valid(figure) or not figure.has_method(&"set_support_grip"):
		return
	if on:
		figure.set_support_grip(grip)
		figure.set_meta(&"flag_grip", true)
	elif figure.has_meta(&"flag_grip"):
		figure.remove_meta(&"flag_grip")
		figure.set_support_grip(Vector3.INF)


## Lets go of the flag's grip once the carrier no longer carries.
static func release_arm(carrier: Node3D) -> void:
	_hold_with_arm(carrier, Vector3.INF, false)


## Client console: cl_lefthand, kept in the client settings.
static func bind_console(local: DotConsoleLocal, settings) -> void:
	if settings != null:
		left_handed = settings.get_bool(&"lefthand", false)
	local.add_var(&"cl_lefthand", "1 holds your carried flag in the right hand, 0 in the left (the default).",
		func() -> Variant: return 1 if left_handed else 0,
		func(v: Variant) -> Variant:
			left_handed = str(v).strip_edges() != "0"
			if settings != null:
				var _set: Variant = settings.set_value(&"lefthand", left_handed)
			return DotResult.success(1 if left_handed else 0)
	)


static func _trace(game):
	if game == null or game.combat == null or game.combat.trace == null:
		return null
	return game.combat.trace


static func _floor_below(trace, at: Vector3) -> Vector3:
	if trace == null:
		return at
	var hit: DotHitbox.Hit = trace._world_ray(at + Vector3.UP * BODY_UP, Vector3.DOWN, 50.0)
	return Vector3(at.x, hit.point.y, at.z) if hit.ok() else at
