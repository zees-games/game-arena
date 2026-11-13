extends SceneTree

## Other players' guns as the carry draws them: the offline client with its bots, a few bots each followed from the side
## and from the front for a while (running, shooting, and a reload forced part way), every frame logged with what the
## carry was doing. Written to screenshots/carry/<bot>_{side,front}_NN.png (tools/render_carry.sh joins them into strips).
##
##   xvfb-run -a godot --path . --resolution 1280x720 --script tools/render_carry.gd [-- --bots 3 --frames 24 --carry 0]
##
## `--carry 0` turns AwWorldModel.person_carry off: the held gun's own kick and reload dip, for the comparison.

const ArenaPresentation := preload("../game/arena_presentation.gd")
const OUT_DIR := "screenshots/carry"
const EVERY := 0.15
const SIZE := Vector2i(480, 480)

var client: Node = null
var _bots := 3
var _frames := 24


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size() - 1:
		match args[i]:
			"--bots":
				_bots = int(args[i + 1])
			"--frames":
				_frames = int(args[i + 1])
			"--carry":
				(AwWorldModel as Script).set(&"person_carry", int(args[i + 1]) != 0)
	preload("../game/arena_weapon_roles.gd").ensure()
	var _scratch := ArenaPresentation.use_scratch_settings("render_carry")
	client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	root.add_child(client)
	_run.call_deferred()


func _wait(sec: float) -> void:
	await create_timer(sec).timeout


func _view() -> Camera3D:
	var vp := SubViewport.new()
	vp.size = SIZE
	vp.world_3d = root.world_3d
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var cam := Camera3D.new()
	cam.fov = 45.0
	vp.add_child(cam)
	cam.current = true
	return cam


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	for i in 600:
		await _wait(0.1)
		var p: Object = client.get("player")
		var g: Object = client.get("game")
		if p != null and g != null and p.is_alive() and g.match_node != null and g.match_node.state == DotMatch.State.LIVE:
			break
	await _wait(4.0)
	var me = client.get("player")
	me.health.invulnerable = true
	var side := _view()
	var front := _view()
	var done := 0
	for bot in client.get("game").players():
		if done >= _bots:
			break
		if bot == me or bot.held == null or bot.held.equipped() == &"" or bot.get(&"figure") == null:
			continue
		done += 1
		for n in _frames:
			if not is_instance_valid(bot) or not bot.is_alive() or bot.figure == null:
				print("CARRY ", bot.name, " frame ", n, " gone")
				break
			await _wait(EVERY)
			if not is_instance_valid(bot) or bot.figure == null:
				break
			if n == _frames / 2:
				print("CARRY ", bot.name, " reload forced: ", bot.arsenal.begin_reload(Engine.get_physics_frames()))
			var figure: Node3D = bot.figure
			var facing := -figure.global_basis.z
			facing.y = 0.0
			facing = facing.normalized() if facing.length() > 0.01 else Vector3.FORWARD
			var right := facing.cross(Vector3.UP)
			var at := figure.global_position + Vector3.UP * 0.8
			side.global_position = at + right * 2.4 + Vector3.UP * 0.2
			side.look_at(at, Vector3.UP)
			front.global_position = at + facing * 2.4 + Vector3.UP * 0.2
			front.look_at(at, Vector3.UP)
			# Placed just before the draw, so a running bot is still in frame.
			await process_frame
			await RenderingServer.frame_post_draw
			var tag := "%s/%s_%%s_%02d.png" % [OUT_DIR, String(bot.name).to_snake_case(), n]
			side.get_viewport().get_texture().get_image().save_png(tag % "side")
			front.get_viewport().get_texture().get_image().save_png(tag % "front")
			var carry: Variant = figure.get(&"carry")
			print("CARRY %s %02d held=%s speed=%.1f reloading=%s carry=%s" % [bot.name, n, bot.held.equipped(),
				bot.controller.state.horizontal_speed(), bot.arsenal.is_reloading(), carry.describe() if carry != null else {}])
	print("CARRY bots=", done, " person_carry=", (AwWorldModel as Script).get(&"person_carry"))
	quit()
