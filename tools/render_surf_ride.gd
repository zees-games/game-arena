extends SceneTree

## Plays the offline client on a combat surf map and photographs a bot riding a ride edge (see
## `game/arena_surf.gd`), so a person can see whether it surfs like a player: on the face of the
## ramp, not in it or above it, holding its line, and still looking at what it is fighting.
##
##     tools/render_surf_ride.sh [map] [edge]
##
## The bot is put at the edge's start and handed the ride the way its route would hand it; from
## there everything is the game's: the brain aims and shoots, the pilot has the legs, the arena
## ticks it. Each frame logs where it is, how fast, whether it is on the ground, the ride's state
## and what the brain is doing.

const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaBots := preload("../game/arena_bots.gd")

const OUT_DIR := "res://screenshots"
const FRAMES := 48
const EVERY := 0.25

var client: Node = null
var _camera: Camera3D = null
var _subject: Node = null
var _map := "surf_10x_reloaded_fixed"
var _edge := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--map")
	if at >= 0 and at + 1 < args.size():
		_map = args[at + 1]
	at = args.find("--edge")
	if at >= 0 and at + 1 < args.size():
		_edge = int(args[at + 1])
	var _scratch := ArenaPresentation.use_scratch_settings("render_surf_ride")
	var scene: PackedScene = load("res://game/arena.tscn")
	client = scene.instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	root.add_child(client)
	RenderingServer.frame_pre_draw.connect(_follow)
	_run.call_deferred()


## Behind the bot along where it is going, and above: a surfer is read by its line, which a camera
## over the shoulder of a bot looking elsewhere would not show.
func _follow() -> void:
	if _camera == null or _subject == null or not is_instance_valid(_subject):
		return
	var state = _subject.controller.state
	var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)
	if flat.length() < 1.0:
		var y := deg_to_rad(state.yaw)
		flat = Vector3(-sin(y), 0.0, -cos(y))
	flat = flat.normalized()
	var body: Vector3 = state.position + Vector3.UP * 1.0
	_camera.make_current()
	_camera.global_position = body - flat * 7.0 + Vector3.UP * 3.0
	_camera.look_at(body + flat * 6.0, Vector3.UP)


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var game = client.get("game")
	# Warmup, countdown, everybody placed, and the bots' mesh baked.
	var surf: RefCounted = null
	for i in range(240):
		await _wait(0.25)
		if game != null and game.map != null and String(game.map.id) == _map:
			surf = ArenaBots.world_for(game).surf_for_map()
			if surf != null:
				break
	if surf == null:
		print("no ride edges on %s (is it the map? is there a cache in maps/surf/?)" % _map)
		quit(1)
		return
	await _wait(6.0)
	var edges: Array = surf.get(&"edges")
	if _edge >= edges.size():
		print("%s has %d ride edges" % [_map, edges.size()])
		quit(1)
		return
	var edge = edges[_edge]
	var me = client.get("player")
	me.health.invulnerable = true
	var bots: Dictionary = client.get("_bots")
	var minds: Dictionary = client.get("_bot_minds")
	for id in bots:
		_subject = bots[id]
		break
	_subject.health.invulnerable = true
	_subject.controller.teleport(edge.from, edge.course.reference_yaw(), 0.0)
	var mind = minds[_subject.player_id]
	var sim = surf.call(&"_sim_for", edge, _subject.controller)
	mind.ride = DotBotSurfRide.new().begin(edge.cache, edge.course, sim, int(game.get("_tick")), float(game.tick_rate))
	surf.set(&"begun", int(surf.get(&"begun")) + 1)

	_camera = Camera3D.new()
	_camera.fov = 75.0
	client.add_child(_camera)
	_camera.make_current()
	print("riding edge %d of %s: %s to %s" % [_edge, _map, str(edge.from.round()), str(edge.to.round())])
	for i in range(FRAMES):
		await _wait(EVERY)
		await process_frame
		var path := ProjectSettings.globalize_path("%s/surf_ride_%s_%02d.png" % [OUT_DIR, _map, i])
		root.get_texture().get_image().save_png(path)
		var state = _subject.controller.state
		var brain: DotBotBrain = mind.brain
		print("%02d at %s %.1f m/s %s ride=%s state=%s target=%d yaw=%.0f heading=%.0f" % [i, str(state.position.round()),
			state.velocity.length(), "ground" if state.is_grounded() else "air",
			"riding" if mind.ride != null else "done", brain.last.state if brain != null and brain.last != null else "-",
			brain.last.target_id if brain != null and brain.last != null else -1, state.yaw,
			rad_to_deg(atan2(-state.velocity.x, -state.velocity.z))])
	print(surf.call(&"describe"))
	quit(0)


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout
