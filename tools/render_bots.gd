extends SceneTree

## Plays the offline client with its bots at a difficulty and photographs one of them from over
## its shoulder, so a person can see whether the bots look human: turning onto somebody rather
## than snapping, missing a little first, never tracking anybody through a wall.
##
##     tools/render_bots.sh                 # medium, into screenshots/bots_medium_*.png
##     tools/render_bots.sh hard            # any preset
##
## The local player is made invulnerable and left standing, so the bots fight each other and
## the player without the run ending. Every frame logs what the followed bot is doing (its
## state, its target, whether it can see that target, whether its trigger is down), because a
## picture of a wall cannot say whether the bot behind the camera was aiming at it.

const ArenaPresentation := preload("../game/arena_presentation.gd")

const OUT_DIR := "res://screenshots"
const FRAMES := 40
const EVERY := 0.4

var client: Node = null
var _camera: Camera3D = null
var _subject: Node = null
var _difficulty := "medium"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		_difficulty = args[0]
	var _scratch := ArenaPresentation.use_scratch_settings("render_bots")
	var scene: PackedScene = load("res://game/arena.tscn")
	client = scene.instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	root.add_child(client)
	# After every node has processed, right before drawing: the client writes its own camera
	# every frame, and a camera placed earlier than that is overruled.
	RenderingServer.frame_pre_draw.connect(_follow)
	_run.call_deferred()


func _follow() -> void:
	if _camera == null or _subject == null or not is_instance_valid(_subject):
		return
	var state = _subject.controller.state
	var y := deg_to_rad(state.yaw)
	var p := deg_to_rad(state.pitch)
	var forward := Vector3(-sin(y) * cos(p), sin(p), -cos(y) * cos(p))
	var flat := Vector3(-sin(y), 0.0, -cos(y))
	var eye: Vector3 = _subject.muzzle_position()
	_camera.make_current()
	_camera.global_position = eye - flat * 2.6 + Vector3.UP * 0.7 + Vector3(cos(y), 0.0, -sin(y)) * 0.6
	_camera.look_at(eye + forward * 20.0, Vector3.UP)


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	DotBotSettings.of(client.get("game")).set_difficulty(_difficulty)

	# Warmup, countdown and everybody placed.
	await _wait(32.0)

	var me = client.get("player")
	me.health.invulnerable = true
	var bots: Dictionary = client.get("_bots")
	for id in bots:
		_subject = bots[id]
		break

	_camera = Camera3D.new()
	_camera.fov = 75.0
	client.add_child(_camera)
	_camera.make_current()

	var game = client.get("game")
	var minds: Dictionary = client.get("_bot_minds")
	for i in range(FRAMES):
		await _wait(EVERY)
		await process_frame
		var path := ProjectSettings.globalize_path("%s/bots_%s_%02d.png" % [OUT_DIR, _difficulty, i])
		root.get_texture().get_image().save_png(path)
		var brain: DotBotBrain = minds[_subject.player_id].brain if minds.has(_subject.player_id) else null
		var line := "%02d %s alive=%s" % [i, _subject.display_name, _subject.is_alive()]
		if brain != null and brain.last != null:
			var t = game.player_for(brain.last.target_id) if brain.last.target_id >= 0 else null
			var sees := false
			if t != null:
				sees = game.combat.trace.line_of_sight(_subject.muzzle_position(), t.global_position + Vector3.UP * 1.25)
			line += " state=%s target=%s dist=%.1f sees=%s fire=%s err=%.2f" % [
				brain.last.state, t.display_name if t != null else "-",
				_subject.global_position.distance_to(t.global_position) if t != null else 0.0,
				sees, brain.last.fire, float(brain.engagement()["aim_error_deg"])]
		print(line)
		if OS.get_environment("BOTS_DEBUG") != "":
			for other in game.players():
				if other == _subject or not other.is_alive():
					continue
				var eye: Vector3 = _subject.muzzle_position()
				var to: Vector3 = other.global_position + Vector3.UP * 1.25 - eye
				var fwd := Vector3(-sin(deg_to_rad(_subject.controller.state.yaw)), 0.0, -cos(deg_to_rad(_subject.controller.state.yaw)))
				print("     %s at %.1f m, %.0f deg off, chest LOS %s, eye LOS %s, dy %.1f" % [other.display_name, to.length(), rad_to_deg(fwd.angle_to(Vector3(to.x, 0, to.z))),
					game.combat.trace.line_of_sight(eye, other.global_position + Vector3.UP * 1.25), game.combat.trace.line_of_sight(eye, other.muzzle_position()), to.y])
	quit(0)


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout
