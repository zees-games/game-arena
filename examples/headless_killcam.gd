extends DotGameCheckSuite

const ArenaContent := preload("../game/arena_content.gd")
const KillPov := preload("../game/arena_kill_pov.gd")
const Bodies := preload("../game/arena_killcam_bodies.gd")
const KillPovView := preload("../game/arena_kill_pov_view.gd")

const EXPECTED_CHECKS := 43

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
	var hurt := DotDamage.make(me.player_id, killer.player_id, 5.0, gm.combat.damage_type(ArenaContent.DAMAGE_BULLET))
	hurt.weapon_id = &"smg"
	hurt.tick = gm.current_tick()
	gm.combat.apply_damage(hurt)
	await _wait(0.4)
	_check(_tags_visible(bots, me) > 0, "control: a hurt bot's health bar shows on the live camera")
	await _check_lens(gm, me, killer)
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
	_check(KillPov.is_replay_camera(kv.camera), "the kill view's camera is flagged as a replay")
	_check(_tags_visible(bots, me) == 0, "no health bar shows over anybody during the kill view")
	await _check_killer_screen(kv, killer)
	_check(kv.is_active(), "and is still playing a second on")
	await _until(func() -> bool: return not kv.is_active(), 10.0)
	_check(float(Time.get_ticks_msec() - t0) > 1500.0, "it ran its time, not skipped at once")
	var screen: Node = _client.get_node_or_null("KillViewScreen")
	_check(screen != null and screen.hands == null, "the killer's viewmodel is gone when the replay ends")
	_check(not KillPov.is_replay_camera(kv.camera), "and the camera is no longer flagged")
	await _check_recoil(screen, killer)
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
	_check(_tags_visible(bots, me) == 0, "no health bar shows over anybody during the final killcam")
	await _check_poses(host, killer, me)
	await _check_events(killer, me)
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
	_check(screen != null and screen.hands != null and screen.hands.find_child("Arms", true, false) == null and screen.arms != null and screen.arms.get_parent() == kv.camera, "the view model's own sleeve is off and the shared arms ride the camera instead")
	_check(screen != null and screen.crosshair != null and screen.crosshair.is_visible_in_tree() and not kv.crosshair.visible, "the killer's crosshair is drawn, the plain one is not")
	var eye: Vector3 = killer.controller.motor.eye_position(killer.controller.state)
	_check(kv.camera.global_position.distance_to(eye) < 0.6, "the camera is at the killer's eye", str(kv.camera.global_position.distance_to(eye)))


## A replayed shot kicks the replay camera through the view model's own recoil, and flashes the muzzle.
func _check_recoil(screen: Node, killer: Object) -> void:
	var cam := Camera3D.new()
	add_child(cam)
	var base := Transform3D(Basis.IDENTITY, Vector3(0.0, 50.0, 0.0))
	var aux := KillPov.aux_of(killer)
	_check(aux.size() == DotKillViewRing.AUX and KillPov.SIZE == DotKillViewRing.AUX, "the aux layout is the twelve floats the ring records")
	_check(KillPov.aux_of(killer, 8).size() == 8 and KillPov.aux_of(null, 20).size() == 20, "a ring of another size gets that many slots, never an out-of-range write")
	var floor_json: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://requires.floor.json"))
	_check(int(floor_json["addons"]["dot_replay"]) >= 8, "the pack requires the dot-replay that records twelve aux floats and the event hook")
	aux[KillPov.KICK_PITCH] = 2.0
	aux[KillPov.FLAGS] = KillPov.GROUNDED
	var climb := 0.0
	var flashed := 0
	for i in 40:
		aux[2] = 1.0 if i < 10 else 2.0
		cam.global_transform = base
		screen.present({"camera": cam, "aux": aux, "fov": 75.0, "behind": false})
		climb = maxf(climb, rad_to_deg(asin(clampf(-cam.global_basis.z.y, -1.0, 1.0))))
		if screen.flashes != null:
			flashed = maxi(flashed, screen.flashes.live_count())
		await get_tree().process_frame
	_check(climb > 0.3, "a replayed shot kicks the killer's camera up (%.2f degrees)" % climb)
	_check(flashed > 0, "and flashes the muzzle", str(flashed))
	screen.present({})
	cam.queue_free()


## Every other body in the final killcam wears the pose it was drawn in at the replayed moment, not its rest pose.
func _check_poses(host: Node, killer: Object, me: Object) -> void:
	var at := [NAN]
	var mark := func(s: Dictionary) -> void: at[0] = s["time"]
	host.killcam.frame_drawn.connect(mark)
	await get_tree().process_frame
	await get_tree().process_frame
	host.killcam.frame_drawn.disconnect(mark)
	var drawn: Dictionary = host.poses.sample(at[0]) if not is_nan(at[0]) else {}
	var compared := 0
	var worst := 0.0
	var off_rest := INF
	for id: Variant in (drawn.get("b", {}) as Dictionary):
		var p: Object = _client.get("game").call(&"player_for", id)
		if p == null or p == killer or p == me or not (drawn["a"] as Dictionary).has(id):
			continue
		var a: PackedFloat32Array = drawn["a"][id]
		var b: PackedFloat32Array = drawn["b"][id]
		var sk: Skeleton3D = p.figure.skeleton()
		for i in sk.get_bone_count():
			var k := 13 + i * 4
			var want := Quaternion(a[k], a[k + 1], a[k + 2], a[k + 3]).normalized().slerp(Quaternion(b[k], b[k + 1], b[k + 2], b[k + 3]).normalized(), drawn["alpha"])
			worst = maxf(worst, sk.get_bone_pose_rotation(i).normalized().angle_to(want))
		var rest := 0.0
		for i in sk.get_bone_count():
			rest = maxf(rest, sk.get_bone_pose_rotation(i).normalized().angle_to(sk.get_bone_rest(i).basis.get_rotation_quaternion()))
		off_rest = minf(off_rest, rest)
		compared += 1
	_check(compared > 0 and worst < 0.02, "the final killcam draws each body in its recorded pose (%d bodies, worst %.3f rad)" % [compared, worst])
	_check(compared > 0 and off_rest > 0.3, "and none stands in its rest pose (least %.2f rad from it)" % off_rest)


## Another player's shot and death are replayed: a mirrored (remote) body records its fire count, a new count flashes
## its muzzle once, and the victim's row turning dead drops a ragdoll that the restore takes away again.
func _check_events(killer: Object, me: Object) -> void:
	var bot: Object = null
	for p: Object in _client.get("game").call(&"players"):
		if p != killer and p != me and p.get(&"body_mesh") != null and p.get(&"held") != null:
			bot = p
			break
	_check(bot != null, "a bot with a body and a held gun is there to replay")
	if bot == null:
		_check(false, "skipped: no bot", "a")
		_check(false, "skipped: no bot", "b")
		_check(false, "skipped: no bot", "c")
		_check(false, "skipped: no bot", "d")
		return
	var was: Array = [bot.mirrored, bot.mirror_fire_seq, bot.mirror_fire_kind]
	bot.mirrored = true
	bot.mirror_fire_seq = 7
	bot.mirror_fire_kind = ZeeWeaponNet.KIND_SHOT
	var aux := KillPov.aux_of(bot)
	bot.mirrored = was[0]
	bot.mirror_fire_seq = was[1]
	bot.mirror_fire_kind = was[2]
	_check(aux[2] == 7.0 and aux[3] == float(ZeeWeaponNet.KIND_SHOT), "a remote body records its fire count and kind", str(aux))
	var row := func(seq: float, alive: bool) -> Array:
		return [Vector3.ZERO, 0.0, 0.0, alive, 1.6] + [0.0, 0.0, seq, float(ZeeWeaponNet.KIND_SHOT)]
	var flashes := func() -> int:
		var n := 0
		for f: Node in get_tree().root.find_children("*", "ZeeShotFx", true, false):
			n += (f as ZeeShotFx).live_count()
		return n
	var yard: DotPlayerRagdolls = _client.get("ragdolls")
	var body: Node3D = bot.body_mesh
	var shown := body.visible
	body.visible = true
	Bodies.replay_events(bot, row.call(3.0, true), row.call(3.0, true), 0.0, false, yard)
	var before: int = flashes.call()
	Bodies.replay_events(bot, row.call(3.0, true), row.call(4.0, true), 1.0, false, yard)
	var after: int = flashes.call()
	_check(after > before, "a new fire count in the replay flashes the muzzle", "%d -> %d" % [before, after])
	Bodies.replay_events(bot, row.call(4.0, true), row.call(4.0, true), 0.0, false, yard)
	_check(flashes.call() == after, "the same count does not flash twice")
	var live := yard.live().size() if yard != null else 0
	Bodies.replay_events(bot, row.call(4.0, true), row.call(4.0, false), 1.0, true, yard)
	_check(yard != null and yard.live().size() == live + 1 and bot.has_meta(Bodies.FALL_META), "the victim's row turning dead drops a ragdoll")
	Bodies.restore_body(bot, [body.transform, shown])
	await get_tree().process_frame
	_check(not bot.has_meta(Bodies.FALL_META), "and the restore takes it away")


## Health bars that draw on this frame over the bots and the local player.
func _tags_visible(bots: Dictionary, me: Object) -> int:
	var n := 0
	var all: Array = bots.values()
	all.append(me)
	for p: Node in all:
		var tag := p.get_node_or_null("HealthTag") as Node3D
		if tag != null and tag.is_visible_in_tree():
			n += 1
	return n


## The replay lens stays out of solids for eyes recorded at, beside and inside walls, and the killer's gun
## meets the same wall response from a replayed eye as from a live one.
func _check_lens(gm: Object, me: Object, killer: Object) -> void:
	var layers: Array[StringName] = [&"world", &"prop"]
	var mask: int = gm.player_stack.physics.layout.mask_of(layers)
	var space: PhysicsDirectSpaceState3D = me.get_world_3d().direct_space_state
	var origin: Vector3 = me.global_position + Vector3.UP * 1.2
	var swept := 0
	var inside := 0
	var wall_eye := Vector3.ZERO
	var wall_dir := Vector3.ZERO
	for i in 24:
		var dir := Vector3.FORWARD.rotated(Vector3.UP, TAU * i / 24.0)
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(origin, origin + dir * 12.0, mask))
		if hit.is_empty():
			continue
		for d in [0.0, 0.03, 0.08, 0.2]:
			var eye: Vector3 = (hit["position"] as Vector3) - dir * d
			var placed := KillPov.clear_eye(space, eye, dir, mask)
			swept += 1
			if DotCameraProbe.is_inside(space, placed, 0.05, mask):
				inside += 1
		if wall_dir == Vector3.ZERO:
			wall_eye = (hit["position"] as Vector3) - dir * 0.3
			wall_dir = dir
	_check(swept >= 20, "the sweep found walls to test the lens against", str(swept))
	_check(inside == 0, "no replay lens ends inside a solid, over eyes at, beside and in walls", "%d of %d" % [inside, swept])
	var cam := Camera3D.new()
	add_child(cam)
	cam.look_at_from_position(wall_eye, wall_eye + wall_dir)
	var view := KillPovView.new()
	view.world_mask = mask
	view.feel_rules = gm.get(&"feel_rules") as ZeeViewFeel
	view.ads_rules = gm.get(&"ads_rules") as ZeeAdsRules
	add_child(view)
	var aux := KillPov.aux_of(killer)
	var peak := 0.0
	for i in 40:
		cam.look_at_from_position(wall_eye, wall_eye + wall_dir)
		view.present({"camera": cam, "aux": aux, "fov": 75.0, "behind": false})
		await get_tree().physics_frame
		if view.hands != null:
			peak = maxf(peak, view.hands.wall_amount())
	_check(view.hands != null and KillPov.is_replay_camera(cam), "the stand-in replay shows the killer's gun and is flagged")
	_check(peak > 0.0, "the replayed gun pulls back from a wall just ahead of the replayed eye", str(peak))
	var free := cam.global_position - wall_dir * 2.0
	var after := 0.0
	for i in 60:
		cam.look_at_from_position(free, free + wall_dir)
		view.present({"camera": cam, "aux": aux, "fov": 75.0, "behind": false})
		await get_tree().physics_frame
		after = view.hands.wall_amount()
	_check(after < peak * 0.5, "and lowers it again in the open", "%s of %s" % [after, peak])
	view.present({})
	_check(not KillPov.is_replay_camera(cam), "ending the replay unflags the camera")
	cam.queue_free()
	view.queue_free()
