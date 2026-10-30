extends SceneTree

## A bot shot dead in front of the player: frames of the body and the gun it held at set times,
## and the gun's pose read back from the dropped prop. The look no assertion gives: does the
## body collapse and does the gun lie down, visible, rather than stand on end?
##
##     tools/render_death_gun.sh [map]       # frames in screenshots/death_gun/

const ArenaPresentation := preload("../game/arena_presentation.gd")
const OUT_DIR := "res://screenshots/death_gun"

var client: Node = null
var _map := "dm_atrium"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--map")
	if at >= 0 and at + 1 < args.size():
		_map = args[at + 1]
	var _scratch := ArenaPresentation.use_scratch_settings("render_death_gun")
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
			if _ray(foot + Vector3.UP, foot + Vector3.UP + dir * 4.5).is_empty():
				return {"me": foot, "bot": foot + dir * 3.5, "dir": dir}
	return {}


## Every mesh under [param node] that is visible in the tree, for "the gun can be seen".
static func visible_meshes(node: Node) -> int:
	var n := 0
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur is MeshInstance3D and (cur as MeshInstance3D).is_visible_in_tree():
			n += 1
		stack.append_array(cur.get_children())
	return n


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
	if spot.is_empty() or bot == null:
		print("FAIL no spot")
		quit(1)
		return
	var yaw := atan2(-spot["dir"].x, -spot["dir"].z)
	me.controller.teleport(spot["me"], yaw, 0.0)
	bot.controller.teleport(spot["bot"], yaw + PI, 0.0)
	await _wait(0.6)
	me.controller.teleport(spot["me"], yaw, 0.0)
	bot.controller.teleport(spot["bot"], yaw + PI, 0.0)
	await _wait(0.2)
	print("bot held visible=%s id=%s" % [bot.held.visible if bot.held != null else "none", bot.held.equipped() if bot.held != null else ""])
	bot.health.invulnerable = false
	bot.health.invulnerable_until_tick = -1
	var damage := DotDamage.make(me.player_id, bot_id, bot.health.health + bot.health.armour + 50.0, game.combat.damage_type(&""))
	damage.tick = game.current_tick()
	var applied = bot.health.apply(damage)
	game.combat.entity_killed.emit(bot_id, applied)
	var last := 0.0
	var failures := 0
	for at_sec in [0.15, 0.4, 0.8, 1.2, 2.0, 3.0]:
		await _wait(at_sec - last)
		last = at_sec
		await process_frame
		await process_frame
		var up := _report(game, bot, at_sec)
		if at_sec >= 2.0 and up:
			failures += 1
		root.get_texture().get_image().save_png(ProjectSettings.globalize_path("%s/%s_%03d.png" % [OUT_DIR, _map, int(at_sec * 100.0)]))
	quit(1 if failures > 0 else 0)


## Prints what stands where; true when a gun stands on end or none can be seen.
func _report(game, bot, at_sec: float) -> bool:
	var bad := false
	var drops: Node = game.weapon_drops
	var yard: Node = client.get("ragdolls")
	var line := "t=%.2f held_vis=%s" % [at_sec, bot.held.visible if bot.held != null else "none"]
	var props: Array = yard.get("_props") if yard != null else []
	for p in props:
		if is_instance_valid(p):
			var fwd: Vector3 = -(p as Node3D).global_basis.z
			line += " prop(y=%.2f fwd.y=%.2f meshes=%d)" % [(p as Node3D).global_position.y, fwd.y, visible_meshes(p)]
	if drops != null:
		var entries: Dictionary = drops.get("_entries")
		for id in entries:
			var b: Node3D = entries[id]["body"]
			var fwd: Vector3 = -b.global_basis.z
			line += " drop%d(pos=%s fwd.y=%.2f rest=%s meshes=%d)" % [id, str(b.global_position.snapped(Vector3.ONE * 0.01)), fwd.y, str(entries[id]["rest"]), visible_meshes(b)]
			if at_sec >= 2.0 and (absf(fwd.y) > 0.8 or visible_meshes(b) == 0):
				bad = true
	print(line)
	if at_sec == 1.2:
		_dump(root, bot.global_position)
		if drops != null:
			for id in drops.get("_entries"):
				print((drops.get("_entries")[id]["body"] as Node).get_children().map(func(x): return "%s:%s:%s" % [x.name, x.get_class(), str(x.get("visible"))]))
	return bad


func _dump(node: Node, near: Vector3) -> void:
	for c in node.get_children():
		if c is GeometryInstance3D and (c as GeometryInstance3D).is_visible_in_tree() and (c as GeometryInstance3D).global_position.distance_to(near) < 2.5 and not str(c.get_path()).contains("Camera"):
			var m := c as GeometryInstance3D
			print("  %s %s  up.y=%.2f fwd.y=%.2f aabb=%s" % [c.get_class(), str(m.get_path()).right(90), m.global_basis.y.y, -m.global_basis.z.y, str(m.get_aabb().size.snapped(Vector3.ONE * 0.01))])
		_dump(c, near)
