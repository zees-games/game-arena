extends SceneTree

## The solo client's death camera for a death against a wall, killer on the open side, with the
## body on the floor: ArenaClient driving dot-spectate's stand-back death camera (6087cbf), not a
## standalone DotSpectatorManager. Frames at 0.3, 1.2 and 3 s after the kill, the eye's distance
## from the body, and whether the camera is inside the level, printed and saved to
## screenshots/deathcam/. The look no assertion gives: is the camera held against the wall, and
## is the body in frame.
##
##     tools/render_deathcam.sh [map]          # dm_atrium by default
##
## The wall is found with rays from each spawn: the first spot with a wall 0.6 to 1.6 m away in
## some direction and 5 m of clear floor on the opposite side, where the killer is put.

const ArenaPresentation := preload("../game/arena_presentation.gd")

const OUT_DIR := "res://screenshots/deathcam"

var client: Node = null
var _map := "dm_atrium"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--map")
	if at >= 0 and at + 1 < args.size():
		_map = args[at + 1]
	var _scratch := ArenaPresentation.use_scratch_settings("render_deathcam")
	var scene: PackedScene = load("res://game/arena.tscn")
	client = scene.instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	client.set("offline_bots", 1)
	root.add_child(client)
	_run.call_deferred()


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, 0xFFFFFFFF)
	return root.world_3d.direct_space_state.intersect_ray(query)


## A spot against a wall, the direction to the wall, and the killer's spot on the open side.
func _find_spot(game) -> Dictionary:
	var probe := _ray(Vector3(22, 3, -25), Vector3(22, -3, -25))
	print("probe down hit: %s; spawns %d" % [str(probe.get("position", "none")), game.map.spawns.size()])
	for spawn: Transform3D in game.map.spawns:
		var foot: Vector3 = spawn.origin
		for n in 16:
			var dir := Vector3(sin(n * TAU / 16.0), 0.0, cos(n * TAU / 16.0))
			var chest := foot + Vector3.UP * 1.0
			var hit := _ray(chest, chest + dir * 3.0)
			if hit.is_empty():
				continue
			var gap: float = chest.distance_to(hit["position"])
			if gap < 1.4:
				continue
			var body: Vector3 = hit["position"] - dir * 0.7
			body.y = foot.y
			var open := _ray(body + Vector3.UP, body + Vector3.UP - dir * 5.0)
			if not open.is_empty():
				continue
			return {"body": body, "dir": dir, "killer": body - dir * 5.0, "wall": hit["position"]}
	return {}


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var game = client.get("game")
	for i in range(80):
		await _wait(0.25)
		if game != null and game.map != null and client.get("player") != null:
			break
	var changed = game.change_map(load("res://maps/arena_map.gd").by_id(StringName(_map)))
	print("map %s: %s" % [_map, "ok" if changed.ok else "failed"])
	await _wait(3.0)
	var me = client.get("player")
	var bots: Dictionary = client.get("_bots")
	var killer_id := -1
	for id in bots:
		killer_id = int(id)
		break
	var killer = game.player_for(killer_id)
	var spot := _find_spot(game)
	if spot.is_empty() or killer == null:
		print("FAIL no wall spot (spot=%s killer=%s)" % [str(spot), str(killer)])
		quit(1)
		return
	game.match_node.rules.respawn_delay_sec = 60.0
	var yaw := atan2(-spot["dir"].x, -spot["dir"].z)
	me.controller.teleport(spot["body"], yaw, 0.0)
	killer.controller.teleport(spot["killer"], yaw + PI, 0.0)
	await _wait(0.5)
	me.controller.teleport(spot["body"], yaw, 0.0)
	await _wait(0.2)
	print("victim at %s, wall at %s (%.2f m), killer at %s" % [str(spot["body"].snapped(Vector3.ONE * 0.01)),
		str(spot["wall"].snapped(Vector3.ONE * 0.01)), spot["body"].distance_to(spot["wall"]), str(spot["killer"].snapped(Vector3.ONE * 0.01))])
	me.health.invulnerable = false
	me.health.invulnerable_until_tick = -1
	var type = game.combat.damage_type(&"")
	var damage := DotDamage.make(killer_id, me.player_id, me.health.health + me.health.armour + 50.0, type)
	damage.tick = game.current_tick()
	var applied = me.health.apply(damage)
	game.combat.entity_killed.emit(me.player_id, applied)
	var fell: Vector3 = me.controller.state.position
	var failures := 0
	var last := 0.0
	for at_sec in [0.3, 1.2, 3.0]:
		await _wait(at_sec - last)
		last = at_sec
		var watching: bool = game.spectate != null and game.spectate.is_spectating(me.player_id)
		var eye: Vector3 = me.camera.global_position
		var body: Vector3 = me.controller.state.position
		var wall_gap := _ray(body + Vector3.UP, eye)
		print("t=%.1f watching=%s eye=%s body=%s eye-to-body=%.2f m  eye-to-killer=%.2f m  wall between body and eye=%s" % [
			at_sec, watching, str(eye.snapped(Vector3.ONE * 0.01)), str(body.snapped(Vector3.ONE * 0.01)), eye.distance_to(body),
			eye.distance_to(killer.controller.state.position), str(not wall_gap.is_empty())])
		if not watching:
			failures += 1
		await process_frame
		await process_frame
		var path := ProjectSettings.globalize_path("%s/%s_deathcam_%02d.png" % [OUT_DIR, _map, int(at_sec * 10.0)])
		root.get_texture().get_image().save_png(path)
	var yard: Object = client.get("ragdolls")
	print("ragdolls live: %d" % (yard.call("live").size() if yard != null else -1))
	print("fell at %s" % str(fell.snapped(Vector3.ONE * 0.01)))
	quit(1 if failures > 0 else 0)
