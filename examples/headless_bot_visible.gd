extends DotGameCheckSuite

const ArenaContent := preload("../game/arena_content.gd")
const KillcamBodies := preload("../game/arena_killcam_bodies.gd")

const EXPECTED_CHECKS := 9

## The standalone game with its bots: every living bot's body draws (visible meshes with a person's
## height), at spawn, after a kill and respawn, and after a killcam that began while the bot was
## down has put it back (it must not restore the hidden state of a body that has since respawned).
var _client: Node = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


## [count of visible, drawn meshes, union of their bounds] under a bot's body.
static func drawn(bot: Node) -> Array:
	var body: Node3D = bot.get("body_mesh")
	if body == null or not body.is_visible_in_tree():
		return [0, AABB()]
	var count := 0
	var box := AABB()
	var stack: Array[Node] = [body]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var m := n as MeshInstance3D
			if m.mesh != null and m.is_visible_in_tree() and m.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
				var b := m.global_transform * m.get_aabb()
				box = b if count == 0 else box.merge(b)
				count += 1
		stack.append_array(n.get_children())
	return [count, box]


func _draws(bot: Node) -> bool:
	var d := drawn(bot)
	return d[0] > 0 and (d[1] as AABB).size.y > 0.5


func _run() -> void:
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("mouse_capture_override", true)
	add_child(_client)
	var gm: Object = null
	while gm == null or gm.match_node == null:
		await _wait(0.1)
		gm = _client.get("game")
	gm.match_node.rules.min_players = 1
	var live := false
	for i in 1200:
		await _wait(0.1)
		var me: Object = _client.get("player")
		if me != null and me.is_alive() and gm.match_node.state == DotMatch.State.LIVE:
			live = true
			break
	if not _check(live, "the offline match goes live"):
		_report(EXPECTED_CHECKS)
		return
	var bots: Dictionary = _client.get("_bots")
	for id in bots:
		bots[id].set_meta(&"bot_scripted", true)
	await _wait(2.0)
	_check(bots.size() == 3, "three bots are in the match", str(bots.size()))
	var all_draw := true
	for id in bots:
		all_draw = all_draw and _draws(bots[id])
	_check(all_draw, "every bot's body draws at spawn")

	# A killcam that starts while a bot is down saves the body hidden, and puts that back at its end.
	var touched := {}
	for id in bots:
		var hit := DotDamage.make(_client.get("player").player_id, id, 1000.0, gm.combat.damage_type(ArenaContent.DAMAGE_BULLET))
		hit.weapon_id = &"smg"
		hit.tick = gm.current_tick()
		var _d = gm.combat.apply_damage(hit)
	await _wait(0.5)
	var down := true
	for id in bots:
		down = down and not bots[id].is_alive()
	_check(down, "the bots are down")
	for id in bots:
		KillcamBodies.place_body(bots[id], bots[id].global_position, 0.0, true, 0.0, 0.0, touched)
	var back := false
	for i in 200:
		await _wait(0.1)
		back = true
		for id in bots:
			back = back and bots[id].is_alive()
		if back:
			break
	_check(back, "the bots respawn")
	await _wait(0.5)
	var after_respawn := true
	for id in bots:
		after_respawn = after_respawn and _draws(bots[id])
	_check(after_respawn, "every respawned bot's body draws")
	for id in bots:
		KillcamBodies.restore_body(bots[id], touched[bots[id]])
	await _wait(0.5)
	for id in bots:
		_check(_draws(bots[id]), "bot %d still draws once the killcam has restored it" % id)
	_report(EXPECTED_CHECKS)
