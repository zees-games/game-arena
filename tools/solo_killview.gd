extends SceneTree

## The standalone flow: the real arena scene offline, a bot kills the local player, frames saved at
## death + 1 s, +3 s (kill view) and at match end (final killcam). Run: tools/solo_killview.sh [outdir]
## Exit 1 when the kill view never started.

const ArenaContent := preload("res://game/arena_content.gd")

var _out := "res://screenshots/solo_killview"
var _client: Node = null


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
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
	gm.match_node.rules.score_limit = 2
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
