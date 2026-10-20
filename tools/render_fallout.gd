extends SceneTree

## Puts the offline client's player where a fall into a combat surf map's teleport volume lands
## (the volumes sorted biggest first; rank 0 is the floor catch-all) and photographs the six
## directions from its eye, so a person can see whether the destination is a place to stand in
## the fight or a cell with no way out. headless_imported's fall-out sections are the assertion;
## this is the look no assertion gives (is the door gone, is the doorway where the walk went).
##
##     tools/render_fallout.sh <map>[,<map>...] [rank[,rank...]]

const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaMap := preload("../maps/arena_map.gd")

const OUT_DIR := "res://screenshots"

var client: Node = null
var _map := "surf_ski_2"
var _ranks := "0"
var _camera: Camera3D = null
var _eye := Vector3.ZERO
var _yaw := 0.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--map")
	if at >= 0 and at + 1 < args.size():
		_map = args[at + 1]
	at = args.find("--rank")
	if at >= 0 and at + 1 < args.size():
		_ranks = args[at + 1]
	var _scratch := ArenaPresentation.use_scratch_settings("render_fallout")
	var scene: PackedScene = load("res://game/arena.tscn")
	client = scene.instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	root.add_child(client)
	RenderingServer.frame_pre_draw.connect(_look)
	_run.call_deferred()


## The client makes its own camera current every frame, so this one is made current just before
## each draw, or the frame is the player's view with its HUD.
func _look() -> void:
	if _camera == null:
		return
	_camera.make_current()
	_camera.global_position = _eye
	_camera.rotation = Vector3(deg_to_rad(-8.0), deg_to_rad(_yaw), 0.0)


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var game = client.get("game")
	for i in range(80):
		await _wait(0.25)
		if game != null and game.map != null:
			break
	_camera = Camera3D.new()
	_camera.fov = 100.0
	client.add_child(_camera)
	var me = client.get("player")
	me.health.invulnerable = true
	for id in _map.split(","):
		for rank in _ranks.split(","):
			await _photograph(game, me, id, int(rank))
	quit(0)


func _photograph(game, me, id: String, rank: int) -> void:
	var changed = game.change_map(ArenaMap.by_id(StringName(id)))
	if not changed.ok:
		print("map %s does not load" % id)
		return
	await _wait(3.0)
	me = client.get("player")
	me.health.invulnerable = true

	var order: Array[int] = []
	for index in range(game.map.pits.size()):
		order.append(index)
	order.sort_custom(func(a: int, b: int) -> bool:
		return (game.map.pits[a]["box"] as AABB).get_volume() > (game.map.pits[b]["box"] as AABB).get_volume())
	# Distinct destinations, as headless_imported's fall-out section counts them.
	var cells: Array[Vector3] = []
	for index in order:
		var to: Vector3 = game.map.pits[index]["to"]
		var seen := false
		for other in cells:
			seen = seen or other.distance_to(to) < 1.0
		if not seen:
			cells.append(to)
	var cell: Vector3 = cells[mini(rank, cells.size() - 1)]
	print("%s rank %d: destination %s" % [id, rank, str(cell.round())])
	for n in range(6):
		var yaw := n * 60.0
		me.controller.teleport(cell, yaw, 0.0)
		await _wait(0.4)
		var here: Vector3 = me.controller.state.position
		_eye = here + Vector3.UP * 1.6
		_yaw = yaw
		await process_frame
		await process_frame
		var path := ProjectSettings.globalize_path("%s/fallout_%s_%d_%d.png" % [OUT_DIR, id, rank, n])
		root.get_texture().get_image().save_png(path)


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout
