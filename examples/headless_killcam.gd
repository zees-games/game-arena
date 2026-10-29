extends DotGameCheckSuite

const ArenaContent := preload("../game/arena_content.gd")

const EXPECTED_CHECKS := 18

## The standalone game, as a player lives it: a bot kills the local player (the kill view of the
## killer plays), then a bot's kill ends the match (the final killcam plays its time, a skip key
## pressed at once is ignored, and the podium waits for it).
var _client: Node = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _until(cond: Callable, limit: float) -> bool:
	var t := 0.0
	while t < limit:
		if cond.call():
			return true
		await _wait(0.05)
		t += 0.05
	return cond.call()


func _lethal(game: Object, killer: Object, me: Object) -> DotDamage:
	var damage := DotDamage.make(killer.player_id, me.player_id, 1000.0, game.combat.damage_type(ArenaContent.DAMAGE_BULLET))
	damage.weapon_id = &"smg"
	damage.tick = game.current_tick()
	return damage


func _press(action: StringName) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	return e


func _run() -> void:
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("mouse_capture_override", true)
	add_child(_client)
	var gm: Object = null
	while gm == null or gm.match_node == null:
		await _wait(0.1)
		gm = _client.get("game")
	gm.match_node.rules.warmup_sec = 0.0
	gm.match_node.rules.countdown_sec = 0.0
	gm.match_node.rules.min_players = 1
	gm.match_node.rules.score_limit = 2
	var me: Object = null
	var live := false
	for i in 1200:
		await _wait(0.1)
		me = _client.get("player")
		if me != null and me.is_alive() and gm.match_node.state == DotMatch.State.LIVE:
			live = true
			break
	if not _check(live, "the offline match goes live"):
		_report(EXPECTED_CHECKS)
		return
	var bots: Dictionary = _client.get("_bots")
	for id in bots:
		bots[id].set_meta(&"bot_scripted", true)
	await _wait(4.0)
	var killer: Object = bots.values()[0]
	for i in 60:
		gm.combat.apply_damage(_lethal(gm, killer, me))
		if not me.is_alive():
			break
		await _wait(1.0)
	_check(not me.is_alive(), "a bot kills the local player")
	var kv: Node = _client.get("killview")
	_check(kv != null and await _until(func() -> bool: return kv.is_active(), 3.0),
		"the killer's view plays after the death, offline")
	var t0 := Time.get_ticks_msec()
	await _wait(1.2)
	await _check_killer_screen(kv, killer)
	_check(kv.is_active(), "and is still playing a second on")
	await _until(func() -> bool: return not kv.is_active(), 10.0)
	_check(float(Time.get_ticks_msec() - t0) > 1500.0, "it ran its time, not skipped at once")
	var screen: Node = _client.get_node_or_null("KillViewScreen")
	_check(screen != null and screen.hands == null, "the killer's viewmodel is gone when the replay ends")
	_check(await _until(func() -> bool: return me.is_alive(), 15.0), "then the player respawns")

	var host: Node = _client.get("killcam")
	_check(host != null, "the client has a final killcam")
	await _wait(1.0)
	for i in 30:
		gm.combat.apply_damage(_lethal(gm, killer, me))
		if not me.is_alive():
			break
		await _wait(0.5)
	_check(await _until(func() -> bool: return host.is_playing(), 8.0), "the match-ending kill starts the final killcam")
	var data: Dictionary = host.killcam.kill().get("data", {})
	_check(int(data.get("killer", 0)) == killer.player_id and int(data.get("victim", 0)) == me.player_id,
		"it shows the real last kill", str(data))
	host.killcam._unhandled_input(_press(&"arena_fire"))
	_check(host.is_playing(), "a fire press in its first second does not skip it")
	var shown := Time.get_ticks_msec()
	await _wait(1.5)
	var reveal: Node = _client.get("winner_reveal")
	_check(host.is_playing() and (reveal == null or not reveal.is_active()), "after 1.5 s it plays on and the podium waits")
	await _until(func() -> bool: return not host.is_playing(), 12.0)
	_check(float(Time.get_ticks_msec() - shown) > 2000.0, "it played several seconds before the summary")
	_report(EXPECTED_CHECKS)


## The kill view is the killer's own screen: camera at their eye, their viewmodel, a crosshair.
func _check_killer_screen(kv: Node, killer: Object) -> void:
	var screen: Node = _client.get_node_or_null("KillViewScreen")
	_check(screen != null and screen.hands != null and screen.hands.is_visible_in_tree(), "the replay shows the killer's viewmodel")
	_check(screen != null and screen.hands != null and screen.hands.get_parent() == kv.camera, "the viewmodel rides the replay camera")
	var held: StringName = killer.arsenal.current().def.id if killer.arsenal.current() != null else &""
	_check(screen != null and screen.hands != null and screen.hands.equipped() == held, "it holds the weapon the killer held", str(held))
	_check(screen != null and screen.crosshair != null and screen.crosshair.is_visible_in_tree() and not kv.crosshair.visible, "the killer's crosshair is drawn, the plain one is not")
	var eye: Vector3 = killer.controller.motor.eye_position(killer.controller.state)
	_check(kv.camera.global_position.distance_to(eye) < 0.6, "the camera is at the killer's eye", str(kv.camera.global_position.distance_to(eye)))
