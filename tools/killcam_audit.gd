extends SceneTree

## The kill view across its edge cases, offline, with frames at the first drawn frame, mid, last and after the hand-over
## to the respawn. Run: tools/killcam_audit.sh <outdir> <scenario>
## Scenarios: bot (a bot shoots the player), world (no attacker), fall (fall damage), killer_dead (the killer dies
## while the replay plays), killer_left (the killer leaves before the clip arrives), round (the match ends mid-view).
## Prints one "T" line per 0.1 s and "RESULT" lines; exit 1 on a failed check.

const ArenaContent := preload("res://game/arena_content.gd")

var _out := "res://screenshots/killcam_audit"
var _scenario := "bot"
var _client: Node = null
var _fails := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	if args.size() > 1:
		_scenario = args[1]
	DirAccess.make_dir_recursive_absolute(_out)
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("mouse_capture_override", true)
	root.add_child(_client)
	_run.call_deferred()


func _wait(sec: float) -> void:
	await create_timer(sec).timeout


func _shot(name: String) -> void:
	var image := root.get_texture().get_image()
	var _e := image.save_png("%s/%s_%s.png" % [_out, _scenario, name])
	print("saved ", name)


func _check(ok: bool, what: String) -> void:
	print("RESULT ", "ok   " if ok else "FAIL ", what)
	if not ok:
		_fails += 1


func _hit(game: Object, attacker: int, me: Object, type: StringName) -> void:
	var damage := DotDamage.make(attacker, me.player_id, 1000.0, game.combat.damage_type(type))
	damage.weapon_id = &"smg" if attacker != 0 else &""
	damage.tick = game.current_tick()
	game.combat.apply_damage(damage)


func _aim_at(who: Object, target: Object) -> void:
	var d: Vector3 = (target as Node3D).global_position - (who as Node3D).global_position
	var yaw := rad_to_deg(atan2(-d.x, -d.z))
	who.controller.state.yaw = yaw
	who.controller.state.pitch = 0.0
	var hold := DotFpsCommand.new()
	hold.yaw = yaw
	who.set_meta(&"bot_move", hold)


## Visible bodies within [param radius] of the replay lens: a torso at the lens is a slab across the screen.
func _near_bodies(cam: Camera3D, radius: float) -> Array:
	var out := []
	for p: Object in _client.get("game").call(&"players"):
		var body: Node3D = p.get(&"body_mesh")
		if body == null or not body.is_visible_in_tree():
			continue
		var d := cam.global_position.distance_to(body.global_position + Vector3(0.0, 0.9, 0.0))
		print("BODY id=%d d=%.2f feet=%s vis=%s" % [p.player_id, d, body.global_position, body.visible])
		if d < radius:
			out.append(p.player_id)
	return out


func _run() -> void:
	var gm: Object = _client.get("game")
	while gm == null or gm.match_node == null:
		await _wait(0.1)
		gm = _client.get("game")
	gm.match_node.rules.warmup_sec = 0.0
	gm.match_node.rules.countdown_sec = 0.0
	gm.match_node.rules.min_players = 1
	gm.match_node.rules.score_limit = 5
	var me: Object = null
	for i in 1200:
		await _wait(0.1)
		me = _client.get("player")
		if me != null and me.is_alive() and gm.match_node.state == DotMatch.State.LIVE:
			break
	var bots: Dictionary = _client.get("_bots")
	for id in bots:
		bots[id].set_meta(&"bot_scripted", true)
		bots[id].set_meta(&"bot_move", DotFpsCommand.new())
	await _wait(8.0)
	var killer: Object = bots.values()[0]
	var kv: Node = _client.get("killview")
	var kh: Node = _client.get("killcam")
	_aim_at(killer, me)
	var t_death := 0.0
	var attacker: int = killer.player_id
	var type: StringName = ArenaContent.DAMAGE_BULLET
	if _scenario == "world":
		attacker = 0
		type = ArenaContent.DAMAGE_WORLD
	elif _scenario == "fall":
		attacker = 0
		type = ArenaContent.DAMAGE_FALL
	elif _scenario == "killer_left":
		_client.call("_remove_offline_bot", killer.player_id)
	for i in 60:
		_hit(gm, attacker, me, type)
		if not me.is_alive():
			break
		await _wait(1.0)
	_check(not me.is_alive(), "the player died")
	var first_active := -1.0
	var first_play := -1.0
	var done := -1.0
	var respawn := -1.0
	var shots := {}
	var t := 0.0
	var killed_killer := false
	var round_done := false
	var cam_in_view := false
	while t < 16.0:
		await _wait(0.1)
		t += 0.1
		var kc: DotKillcam = kv.kv.killcam if kv != null and kv.kv != null else null
		var active: bool = kv != null and kv.is_active()
		var playing: bool = kc != null and kc.state == DotKillcam.State.PLAYING
		var prog: float = kc.progress() if kc != null and playing else -1.0
		print("T %.1f alive=%s active=%s state=%s prog=%.2f hud=%s kcam=%s match=%d" % [t, me.is_alive(), active, kc.state if kc != null else -1, prog, _client.get("hud").visible, kh.is_playing() if kh != null else "n/a", int(gm.match_node.state)])
		if active and first_active < 0.0:
			first_active = t
			_shot("a_active")
		if playing and first_play < 0.0:
			first_play = t
			_shot("b_first")
			print("CAM ", kv.camera.global_position, " killer ", killer.player_id, " me ", me.player_id)
			var near := _near_bodies(kv.camera, 1.2)
			_check(near.is_empty(), "no body fills the lens in the first frame %s" % str(near))
		if playing and prog >= 0.5 and not shots.has("mid"):
			shots["mid"] = true
			_shot("c_mid")
			_check(_near_bodies(kv.camera, 1.2).is_empty(), "no body fills the lens mid-replay")
			if _scenario == "killer_dead" and not killed_killer:
				killed_killer = true
				_hit(gm, me.player_id, killer, ArenaContent.DAMAGE_BULLET)
			if _scenario == "round" and not round_done:
				round_done = true
				gm.match_node.rules.score_limit = 1
				_hit(gm, killer.player_id, killer, ArenaContent.DAMAGE_WORLD)
		if playing and prog >= 0.95 and not shots.has("last"):
			shots["last"] = true
			_shot("d_last")
		if playing and kc != null and kc.state == DotKillcam.State.PLAYING:
			cam_in_view = cam_in_view or kv.camera.current
		if first_play >= 0.0 and not active and done < 0.0:
			done = t
			_shot("e_ended")
		if me.is_alive() and respawn < 0.0:
			respawn = t
			await _wait(0.3)
			_shot("f_respawned")
			break
	print("TIMES active=%.1f first_frame=%.1f ended=%.1f respawn=%.1f" % [first_active, first_play, done, respawn])
	if _scenario in ["world", "fall", "killer_left"]:
		_check(first_play < 0.0, "no killer replay plays for a death with no live killer")
	else:
		_check(first_play >= 0.0, "the kill view played")
		_check(first_play - first_active <= 0.3, "its first frame is drawn at once (%.1f s)" % (first_play - first_active))
		_check(cam_in_view, "its camera is current while it plays")
	_check(respawn > 0.0, "the player respawned")
	_check(_client.get("hud").visible, "the HUD is back")
	_check(not (kv.camera != null and kv.camera.current) or not kv.is_active(), "the replay camera is not left current")
	print("FAILS ", _fails)
	quit(1 if _fails > 0 else 0)
