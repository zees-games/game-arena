extends SceneTree

## Plays the offline client and photographs the weapons doing what no suite can see.
##
## Waits out warmup, then stages one bot: it is teleported a few metres in front of the
## player, where the map's trace says there is floor and nothing in between, and turned
## three-quarter on so its world model is in profile. The client's own bot driver leaves a
## bot alone while it carries the `bot_scripted` meta, so this tool writes that bot's
## commands itself: stand still, face across the frame, and pull the trigger, with the
## clock slowed so the tracer leaving its muzzle outlives a software frame. Then the
## player switches to the throwable with the 5 key, throws, follows the grenade with the
## camera, and photographs it going off. The player's steps go through the client's own
## input path — its sampler and real mouse and key events — so what is drawn is what a
## player gets.
##
##     tools/screenshot_weapons.sh            # into screenshots/weapons_*.png
##
## Staging rather than "turn toward the nearest bot": the nearest bot is usually behind a
## wall, and two runs photographed a crate face instead of a gun.
##
## Each frame logs where the player is and what the projectile layer holds, because a
## picture of an empty floor cannot tell "nothing was thrown" from "it is off screen".

const ArenaPresentation := preload("../game/arena_presentation.gd")

const OUT_DIR := "res://screenshots"

## How far in front of the player the bot stands, and how much clear line the staging
## asks for: the bot's distance plus room behind it, so it is not pressed to a wall.
const STAGE_DISTANCE := 4.0
const STAGE_CLEAR := 7.0
## How far either side of the line to the bot the view must also be open, for
## [constant SIDE_CLEAR]: the edges of the frame, near the player.
const SIDE_DEG := 40.0
const SIDE_CLEAR := 3.5
## How far the bot turns away from facing the player. 90 is side-on; less shows a little
## of its front, which reads better as somebody holding a gun.
const STAGE_TURN_DEG := 65.0
## How much open line the bot's own shot wants, so its tracer is long enough to see.
const FIRE_CLEAR := 5.0
## How much open line the throw wants.
const THROW_CLEAR := 10.0
## Chest height above the feet, where the clear lines are measured.
const CHEST := 1.1

var client: Node = null
var _subject: Node = null
var _aiming := false
var _follow_grenade := false


func _initialize() -> void:
	# A scratch settings document, never this machine's real one (see
	# `ArenaPresentation.use_scratch_settings`): a render must not save into a player's file,
	# and must draw from the defaults rather than whatever the last run left there.
	var _scratch := ArenaPresentation.use_scratch_settings("screenshot_weapons")
	var scene: PackedScene = load("res://game/arena.tscn")
	client = scene.instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	root.add_child(client)
	process_frame.connect(_aim)
	_run.call_deferred()


func _aim() -> void:
	var me = client.get("player")
	if me == null:
		return

	var target := Vector3.INF

	if _follow_grenade:
		var flying: Array = client.get("game").projectiles.flying()
		if not flying.is_empty():
			target = flying[0].position
	elif _aiming and _subject != null:
		target = _subject.global_position + Vector3(0.0, 1.0, 0.0)

	if target == Vector3.INF:
		return

	var to: Vector3 = target - me.muzzle_position()
	client.get("_sampler").look_at_angles(
		rad_to_deg(atan2(-to.x, -to.z)), rad_to_deg(atan2(to.y, Vector2(to.x, to.z).length()))
	)


## The yaw (degrees) that faces along a flat direction, the way every command spells it.
static func _yaw_of(dir: Vector3) -> float:
	return rad_to_deg(atan2(-dir.x, -dir.z))


static func _dir_of(yaw_deg: float) -> Vector3:
	var r := deg_to_rad(yaw_deg)
	return Vector3(-sin(r), 0.0, -cos(r))


## How far a flat line runs from [param from] before the world stops it.
func _clear(from: Vector3, dir: Vector3, limit: float) -> float:
	var hit = client.get("game").combat.trace.ray(from, dir, limit)
	return hit.distance if hit.ok() else limit


## Whether there is floor under [param at] within a step of [param floor_y].
func _floor_under(at: Vector3, floor_y: float) -> bool:
	var hit = client.get("game").combat.trace.ray(at + Vector3.UP, Vector3.DOWN, 2.0)
	return hit.ok() and absf(hit.point.y - floor_y) < 0.4


## Puts one bot in front of the player, three-quarter on, and takes over its commands.
## Every other bot is told to stand still and hold fire, so nothing walks into the frame
## or kills the subject. Returns whether a spot was found.
func _stage() -> bool:
	var me = client.get("player")
	var bots: Dictionary = client.get("_bots")

	for id in bots:
		var bot = bots[id]
		bot.set_meta(&"bot_scripted", true)
		bot.set_meta(&"bot_move", DotFpsCommand.new())
		bot.set_meta(&"bot_fire", DotWeaponCommand.new())
		if _subject == null and bot.is_alive():
			_subject = bot

	if _subject == null:
		push_error("screenshot_weapons: no live bot to stage")
		return false

	me.health.invulnerable = true
	_subject.health.invulnerable = true

	var feet: Vector3 = me.controller.state.position
	var chest := feet + Vector3.UP * CHEST
	var looking: float = me.controller.state.yaw

	# Directions nearest the way the player already faces first, so the picture keeps the
	# spawn's view behind the bot where it can.
	for step in range(24):
		var offset := floorf(float(step + 1) / 2.0) * 15.0 * (1.0 if step % 2 == 0 else -1.0)
		var dir := _dir_of(looking + offset)
		if _clear(chest, dir, STAGE_CLEAR) < STAGE_CLEAR:
			continue
		# And open either side of that line, so a wall beside the player does not fill
		# half the frame with the bot squeezed against its edge.
		if _clear(chest, _dir_of(looking + offset + SIDE_DEG), SIDE_CLEAR) < SIDE_CLEAR:
			continue
		if _clear(chest, _dir_of(looking + offset - SIDE_DEG), SIDE_CLEAR) < SIDE_CLEAR:
			continue

		var spot := feet + dir * STAGE_DISTANCE
		if not _floor_under(spot, feet.y):
			continue

		var toward_me := _yaw_of(-dir)
		for turn in [STAGE_TURN_DEG, -STAGE_TURN_DEG]:
			var facing := toward_me + float(turn)
			if _clear(spot + Vector3.UP * CHEST, _dir_of(facing), FIRE_CLEAR) < FIRE_CLEAR:
				continue

			_subject.controller.teleport(spot + Vector3.UP * 0.05, facing, 0.0)
			_command(facing, false)
			print("staged %s at %s facing %.0f (player at %s facing %.0f)" % [
				_subject.display_name, spot, facing, feet, _yaw_of(dir)
			])
			return true

	push_error("screenshot_weapons: no clear spot in front of the player at %s" % feet)
	return false


## Where to throw: off to one side of the staged bot, so it does not stand in front of
## the bounce and the blast, along a line with room for the grenade to land.
func _throw_yaw() -> float:
	var me = client.get("player")
	var looking: float = me.controller.state.yaw
	var chest: Vector3 = me.controller.state.position + Vector3.UP * CHEST

	for turn in [35.0, -35.0, 55.0, -55.0]:
		if _clear(chest, _dir_of(looking + float(turn)), THROW_CLEAR) >= THROW_CLEAR:
			return looking + float(turn)

	return looking


func _command(facing: float, trigger: bool) -> void:
	var move := DotFpsCommand.new()
	move.yaw = facing
	move.pitch = 0.0
	var fire := DotWeaponCommand.new()
	fire.yaw = facing
	fire.pitch = 0.0
	fire.set_button(DotWeaponCommand.BUTTON_ATTACK, trigger)
	_subject.set_meta(&"bot_move", move)
	_subject.set_meta(&"bot_fire", fire)


func _shot(name: String) -> void:
	await process_frame
	await process_frame
	var path := ProjectSettings.globalize_path("%s/weapons_%s.png" % [OUT_DIR, name])
	root.get_texture().get_image().save_png(path)
	var flying := []
	for f in client.get("game").projectiles.flying():
		flying.append("%s bounces %d%s" % [f.position, f.bounces, " resting" if f.resting else ""])
	print("%s  player %s  projectiles %s" % [path, client.get("player").controller.state.position, flying])


func _mouse(down: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = down
	Input.parse_input_event(e)


func _key(code: Key) -> void:
	for down in [true, false]:
		var e := InputEventKey.new()
		e.physical_keycode = code
		e.keycode = code
		e.pressed = down
		Input.parse_input_event(e)


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	# Warmup, countdown, and the respawn queue placing everybody: about 13 s at 64 ticks.
	await _wait(32.0)

	if not _stage():
		quit(1)
		return

	_aiming = true
	# Long enough for the teleport to land and the body and its gun to settle.
	await _wait(1.0)
	await _shot("1_facing_a_bot")

	# The trigger at full speed until the rig counts a use, THEN the clock slowed: a
	# tick at a tenth of the speed is 0.16 s of real time, so pressing and photographing
	# at once photographs a frame from before anything fired.
	var facing: float = _subject.controller.state.yaw
	var before: int = _subject.weapons.fire_seq
	_command(facing, true)
	for i in range(120):
		if _subject.weapons.fire_seq != before:
			break
		await process_frame
	Engine.time_scale = 0.1
	await _shot("2_firing")
	await _wait(0.04)
	await _shot("3_firing")
	_command(facing, false)
	Engine.time_scale = 1.0

	await _wait(1.0)
	_aiming = false
	_key(KEY_5)
	await _wait(1.5)
	await _shot("4_grenade_in_hand")

	client.get("_sampler").look_at_angles(_throw_yaw(), 12.0)
	await _wait(0.3)
	_mouse(true)
	await _wait(0.3)
	_mouse(false)
	_follow_grenade = true
	await _wait(0.25)
	await _shot("5_grenade_flying")
	await _wait(0.5)
	await _shot("6_grenade_bouncing")
	await _wait(1.75)
	for i in range(3):
		await _shot("7_explosion_%d" % i)
		await _wait(0.15)

	quit()
