extends SceneTree

## The standalone flow: the real arena scene offline, a bot kills the local player, frames saved at
## death + 1 s, +3 s (kill view) and at match end (final killcam). Run: tools/solo_killview.sh [outdir]
## Exit 1 when the kill view never started.

const ArenaContent := preload("res://game/arena_content.gd")

var _out := "res://screenshots/solo_killview"
var _client: Node = null
var _final := false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	_final = args.size() > 1 and args[1] == "final"
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
	var _e := image.save_png("%s/%s.png" % [_out, name])
	print("saved ", name)


func _run() -> void:
	var live := false
	var gm: Object = _client.get("game")
	while gm == null or gm.match_node == null:
		await _wait(0.1)
		gm = _client.get("game")
	gm.match_node.rules.warmup_sec = 0.0
	gm.match_node.rules.countdown_sec = 0.0
	gm.match_node.rules.min_players = 1
	gm.match_node.rules.score_limit = 1 if _final else 2
	for i in 1200:
		await _wait(0.1)
		var p: Object = _client.get("player")
		var g: Object = _client.get("game")
		if p != null and g != null and p.is_alive() and g.match_node != null and g.match_node.state == DotMatch.State.LIVE:
			live = true
			break
	if not live:
		push_error("the match never went live")
		quit(1)
		return
	var game = _client.get("game")
	var me = _client.get("player")
	var bots: Dictionary = _client.get("_bots")
	for id in bots:
		bots[id].set_meta(&"bot_scripted", true)
	await _wait(4.0)
	if _final:
		await _run_final(gm, me, bots)
		return
	var killer = null
	for id in bots:
		killer = bots[id]
		break
	var type = game.combat.damage_type(&"bullet")
	if type == null:
		type = game.combat.damage_type(ArenaContent.DAMAGE_BULLET)
	var damage := DotDamage.make(killer.player_id, me.player_id, 1000.0, type)
	damage.weapon_id = &"smg"
	damage.tick = game.current_tick()
	# Harmless behind the loading cover (ArenaGame.can_be_harmed), so keep trying until it lifts.
	for i in 60:
		game.combat.apply_damage(_lethal(game, killer, me))
		if not me.is_alive():
			break
		await _wait(1.0)
	print("killed: alive=", me.is_alive())
	await _wait(1.0)
	_shot("death_plus_1")
	await _wait(2.0)
	_shot("death_plus_3")
	var kv = _client.get("killview")
	print("killview active=", kv.is_active() if kv != null else "none")
	var started: bool = kv != null and kv.is_active()
	for i in 100:
		await _wait(0.1)
		if me.is_alive():
			break
	print("respawned alive=", me.is_alive())
	game.combat.apply_damage(_lethal(game, killer, me))
	print("second kill: alive=", me.is_alive())
	await _wait(2.0)
	_shot("end_plus_2")
	await _wait(2.0)
	_shot("end_plus_4")
	print("match state ", game.match_node.state)
	quit(0 if started else 1)


func _lethal(game: Object, killer: Object, me: Object) -> DotDamage:
	var damage := DotDamage.make(killer.player_id, me.player_id, 1000.0, game.combat.damage_type(ArenaContent.DAMAGE_BULLET))
	damage.weapon_id = &"smg"
	damage.tick = game.current_tick()
	return damage


## The last kill is the local player's, with fire held: the final killcam must play its full time
## (the held button is no new press) and only then the winner reveal comes.
func _run_final(game: Object, me: Object, bots: Dictionary) -> void:
	var victim: Object = bots[bots.keys()[0]]
	Input.action_press(&"arena_fire")
	game.combat.apply_damage(_lethal(game, me, victim))
	print("final kill: victim alive=", victim.is_alive(), " state=", game.match_node.state)
	var kc = _client.get("killcam")
	var t := 0.0
	var started_at := -1.0
	var ended_at := -1.0
	var marks := {0.5: "final_0_5", 1.5: "final_1_5", 3.0: "final_3", 5.0: "final_5", 7.5: "final_7_5", 9.0: "final_9", 12.0: "final_12"}
	while t < 14.0:
		await _wait(0.1)
		t += 0.1
		if kc.is_playing() and started_at < 0.0:
			started_at = t
		if started_at >= 0.0 and ended_at < 0.0 and not kc.is_playing():
			ended_at = t
		for m: float in marks:
			if absf(t - m) < 0.05:
				_shot(marks[m])
				print("t=%.1f playing=%s" % [t, kc.is_playing()])
	Input.action_release(&"arena_fire")
	print("killcam started at %.1f, ended at %.1f (seconds after the kill)" % [started_at, ended_at])
	quit(0 if started_at >= 0.0 and ended_at - started_at > 5.0 else 1)
