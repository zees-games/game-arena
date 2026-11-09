extends SceneTree

## A knife thrown into a bot, then one thrown at the floor: frames of it in flight, stuck in the
## falling body with its wound, the body at rest, and the miss lying where it bounced to.
##
##     tools/knife_shot.sh [map]       # frames in screenshots/knife_throw/

const ArenaPresentation := preload("../game/arena_presentation.gd")
const OUT_DIR := "res://screenshots/knife_throw"

var client: Node = null
var _map := "dm_atrium"
var _cam: Camera3D = null


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--map")
	if at >= 0 and at + 1 < args.size():
		_map = args[at + 1]
	var _scratch := ArenaPresentation.use_scratch_settings("knife_shot")
	client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	client.set("offline_bots", 1)
	root.add_child(client)
	_run.call_deferred()


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	return root.world_3d.direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, 0xFFFFFFFF))


func _spot(game) -> Dictionary:
	for spawn: Transform3D in game.map.spawns:
		var foot: Vector3 = spawn.origin
		for n in 16:
			var dir := Vector3(sin(n * TAU / 16.0), 0.0, cos(n * TAU / 16.0))
			if _ray(foot + Vector3.UP, foot + Vector3.UP + dir * 7.0).is_empty():
				return {"me": foot, "bot": foot + dir * 5.0, "dir": dir}
	return {}


func _grab(name: String) -> void:
	await process_frame
	await process_frame
	var path := ProjectSettings.globalize_path("%s/%s.png" % [OUT_DIR, name])
	root.get_texture().get_image().save_png(path)
	print("wrote %s" % path)


## The side camera [param back] metres off [param at], a little above it.
func _look(at: Vector3, side: Vector3, back: float) -> void:
	_cam.global_position = at + side * back + Vector3.UP * 0.7
	_cam.look_at(at, Vector3.UP)
	_cam.current = true


func _knife_out(me) -> void:
	for slot in range(1, 8):
		var def: DotWeaponDef = me.arsenal.current_def()
		if def != null and def.id == &"knife":
			break
		me.arsenal.bring_to_hand(slot)
	var _out: Dictionary = me.arsenal.drop_from_slot(me.arsenal.current_slot(), [])


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var game = client.get("game")
	for i in range(80):
		await _wait(0.25)
		if game != null and game.map != null and client.get("player") != null:
			break
	var _changed = game.change_map(load("res://maps/arena_map.gd").by_id(StringName(_map)))
	await _wait(3.0)
	var me = client.get("player")
	var bots: Dictionary = client.get("_bots")
	var bot_id := int(bots.keys()[0])
	var bot = game.player_for(bot_id)
	var spot := _spot(game)
	if spot.is_empty() or bot == null or game.knives == null:
		print("FAIL no spot, bot or knives layer")
		quit(1)
		return
	_cam = Camera3D.new()
	_cam.fov = 60.0
	root.add_child(_cam)
	var dir: Vector3 = spot["dir"]
	var side := dir.cross(Vector3.UP).normalized()
	var yaw := atan2(-dir.x, -dir.z)
	for _k in 2:
		me.controller.teleport(spot["me"], yaw, 0.0)
		bot.controller.teleport(spot["bot"], yaw + PI, 0.0)
		await _wait(0.4)
	bot.health.invulnerable = false
	bot.health.invulnerable_until_tick = -1

	# The throw, from the eye at the bot's chest.
	_knife_out(me)
	var eye: Vector3 = me.muzzle_position()
	var chest: Vector3 = bot.controller.state.position + Vector3.UP * 1.15
	var _id: int = game.knives.throw(me.player_id, eye, (chest - eye).normalized())
	_look(eye.lerp(chest, 0.5), side, 3.0)
	await _grab("%s_1_flight" % _map)
	var failures := 0
	for at_sec in [0.4, 1.2, 3.0]:
		await _wait(at_sec - (0.0 if at_sec == 0.4 else (0.4 if at_sec == 1.2 else 1.2)))
		var held: Array = game.knives.entries()
		var k = held[0] if not held.is_empty() else null
		var where: Vector3 = k.holder.global_position if k != null and k.holder != null else chest
		print("t=%.1f knives=%d phase=%s victim=%s alive=%s part=%s at=%s" % [at_sec, held.size(),
			k.phase if k != null else -1, k.victim if k != null else -1, game.combat.health_of(bot_id).alive,
			k.part.name if k != null and k.part != null else "none", where])
		if k == null or k.phase != 2:
			failures += 1
		_look(where, side, 1.6)
		await _grab("%s_2_stuck_%02d" % [_map, int(at_sec * 10.0)])

	# A miss: at the floor a few metres off to the side, and where it ends up.
	me.controller.teleport(spot["me"], yaw, 0.0)
	await _wait(0.2)
	var floor_at: Vector3 = spot["me"] + side * 3.0 - dir * 0.5
	if me.arsenal.carries(&"knife"):
		_knife_out(me)
	eye = me.muzzle_position()
	var miss_id: int = game.knives.throw(me.player_id, eye, (floor_at - eye).normalized())
	_look(floor_at, -dir, 4.0)
	for n in 3:
		await _wait(0.06)
		await _grab("%s_3_bounce_%d" % [_map, n])
	await _wait(2.0)
	var miss = game.knives.get_knife(miss_id)
	print("miss phase=%s bounces=%s at=%s" % [miss.phase if miss != null else -1, miss.bounces if miss != null else -1, miss.at if miss != null else Vector3.ZERO])
	if miss == null or miss.phase != 1:
		failures += 1
	_look(miss.at if miss != null else floor_at, side, 1.2)
	await _grab("%s_4_rest" % _map)
	quit(1 if failures > 0 else 0)
