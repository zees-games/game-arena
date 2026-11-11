extends "render_base.gd"

## Carrying a flag through the real offline client: a bot carrier from the front and side, the carrier's own view, and a flag
## thrown with the drop key, in flight and at rest. Frames in screenshots/ctf_carry/; exit 1 on a failed check. Run:
##   xvfb-run -a godot --path . --resolution 1280x720 --script tools/render_ctf_carry.gd -- --map dm_atrium

const ArenaFlagCarry := preload("../game/arena_flag_carry.gd")



func _setup() -> void:
	_map_id = "dm_atrium"
	_out_dir = "res://screenshots/ctf_carry"
	_scratch_name = "render_ctf_carry"


func _ground(game: Node, spot: Vector3) -> Vector3:
	var hit = game.combat.trace.ray(spot + Vector3.UP * 3.0, Vector3.DOWN, 8.0)
	return Vector3(spot.x, hit.point.y, spot.z) if hit.ok() else spot


## A spot on the ground [param back] metres from [param from] toward [param toward].
func _toward(game: Node, from: Vector3, toward: Vector3, back: float) -> Vector3:
	var dir := toward - from
	dir.y = 0.0
	return _ground(game, from + dir.normalized() * back)


func _view_node(view: Node, team: int) -> Node3D:
	return (view.get("_views") as Dictionary).get(team)


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir))
	print("render_ctf_carry: %s" % _map_id)
	await _wait_gate(60.0)
	await _wait(4.0)
	var picked: DotResult = await client.call("change_from_menu", &"map:%s" % _map_id, &"mode:ctf")
	_check(picked.ok, "the M menu changes to %s in capture the flag" % _map_id)
	await _wait_gate(60.0)
	await _wait(3.0)
	var game = client.get("game")
	var me = client.get("player")
	var objs = game.objectives
	if objs == null or objs.ctf == null or objs.flag_view == null:
		_check(false, "the game has the ctf layer and draws flags")
		quit(1)
		return
	var ctf: DotObjectiveCtf = objs.ctf
	var view = objs.flag_view
	game.match_node.rules.warmup_sec = 0.0
	game.freeze_sec = 0.0
	for i in 100:
		if game.match_node.state == DotMatch.State.LIVE:
			break
		await _wait(0.1)
	var mine: int = game.team_of(me.player_id)
	var enemy := 0
	for f in ctf.flags():
		if f.home_team() != mine:
			enemy = f.home_team()
	var f_mine: DotObjectiveFlag = ctf.flag_of(mine)
	var f_enemy: DotObjectiveFlag = ctf.flag_of(enemy)
	me.health.invulnerable = true
	var carrier = null
	for id in game.player_ids():
		if id == me.player_id:
			continue
		var bot = game.player_for(id)
		if bot == null:
			continue
		bot.set_meta(&"bot_scripted", true)
		bot.health.invulnerable = true
		if carrier == null and game.team_of(id) == enemy:
			carrier = bot
		else:
			bot.controller.teleport(_ground(game, f_mine.at.lerp(f_enemy.at, 0.5)) + Vector3(0, 0.05, 30), 0.0, 0.0)
	_check(carrier != null, "an enemy bot to carry my flag")
	if carrier == null:
		quit(1)
		return

	await _run_part2(game, me, view, mine, enemy, f_mine, f_enemy, carrier)


func _run_part2(game, me, view, mine: int, enemy, f_mine: DotObjectiveFlag, f_enemy: DotObjectiveFlag, carrier) -> void:
	# 1. A bot carrier, seen by somebody else: its gun in the right hand, my flag in its left, against the body.
	var take := _toward(game, f_mine.at, f_enemy.at, 0.2)
	for i in 60:
		carrier.controller.teleport(take + Vector3.UP * 0.05, 0.0, 0.0)
		await _wait(0.05)
		if f_mine.state == DotObjectiveFlag.State.CARRIED:
			break
	_check(f_mine.carrier == str(carrier.player_id), "the bot takes my flag")
	var stand := _toward(game, f_mine.at, f_enemy.at, 5.0)
	var watch := _toward(game, stand, f_enemy.at, 3.2)
	carrier.controller.teleport(stand + Vector3.UP * 0.05, _yaw_to(stand, watch), 0.0)
	_put(watch, stand + Vector3.UP * 1.0, -6.0)
	await _wait(1.2)
	_check(ArenaFlagCarry.allowed_slots().has(carrier.arsenal.current_slot()), "the bot carrier holds a one-handed item (slot %d)" % carrier.arsenal.current_slot())
	var pole := _view_node(view, mine)
	var right: Vector3 = carrier.global_basis.x
	_check(pole != null and (pole.global_position - carrier.global_position).dot(right) < -0.05,
		"the flag is on the carrier's left")
	_check(pole != null and pole.global_basis.y.normalized().dot(Vector3.UP) > 0.85, "held upright")
	await _shot("carrier_front")
	var side: Vector3 = carrier.global_position - right * 3.0
	_put(_ground(game, side), carrier.global_position + Vector3.UP * 1.0, -6.0)
	await _wait(0.6)
	await _shot("carrier_left_side")
	var side_r: Vector3 = carrier.global_position + right * 3.0
	_put(_ground(game, side_r), carrier.global_position + Vector3.UP * 1.0, -6.0)
	await _wait(0.6)
	await _shot("carrier_right_side")
	var _home := f_mine.send_home("")

	await _run_part3(game, me, view, enemy, f_mine, f_enemy, carrier, take, right)


func _run_part3(game, me, view, enemy, f_mine: DotObjectiveFlag, f_enemy: DotObjectiveFlag, carrier, take, right: Vector3) -> void:
	# 2. Me carrying: the flag at my left shoulder looking that way, then the right one with cl_lefthand.
	carrier.controller.teleport(_ground(game, f_mine.at.lerp(f_enemy.at, 0.5)) + Vector3(0, 0.05, 30), 0.0, 0.0)
	var enemy_spot := _toward(game, f_enemy.at, f_mine.at, 0.2)
	_put(enemy_spot, f_enemy.at + Vector3.UP * 1.5)
	for i in 80:
		await _wait(0.05)
		if f_enemy.state == DotObjectiveFlag.State.CARRIED:
			break
	_check(f_enemy.carrier == str(me.player_id), "I take the enemy flag")
	var out := _toward(game, f_enemy.at, f_mine.at, 4.0)
	var yaw := _yaw_to(out, f_mine.at)
	me.controller.teleport(out + Vector3.UP * 0.05, yaw, 0.0)
	client.get("_sampler").look_at_angles(yaw, -5.0)
	await _wait(1.2)
	_check(ArenaFlagCarry.allowed_slots().has(me.arsenal.current_slot()), "I hold a one-handed item (slot %d)" % me.arsenal.current_slot())
	await _shot("first_person_ahead")
	client.get("_sampler").look_at_angles(yaw + 55.0, -40.0)
	await _wait(0.5)
	await _shot("first_person_left_shoulder")
	ArenaFlagCarry.left_handed = true
	client.get("_sampler").look_at_angles(yaw - 55.0, -40.0)
	await _wait(0.5)
	await _shot("first_person_right_shoulder_lefthand")
	ArenaFlagCarry.left_handed = false

	# 3. The drop key: the flag leaves ahead of the aim, flies, and rests upright.
	client.get("_sampler").look_at_angles(yaw, 10.0)
	await _wait(0.3)
	var dropped := ArenaFlagCarry.try_drop(game, me.player_id, me)
	_check(dropped and f_enemy.state == DotObjectiveFlag.State.DROPPED, "the drop key drops the flag")
	await _wait(0.12)
	_check(ArenaFlagCarry.flying(game, enemy), "it flies")
	await _shot("drop_in_flight")
	for i in 60:
		await _wait(0.05)
		if not ArenaFlagCarry.flying(game, enemy):
			break
	_check(not ArenaFlagCarry.flying(game, enemy), "and comes to rest")
	var flag_node := _view_node(view, enemy)
	_check(flag_node != null and flag_node.global_basis.y.normalized().dot(Vector3.UP) > 0.99, "upright")
	_check(flag_node != null and (flag_node.get_node("Beam") as Node3D).visible, "its indicator beam shows")
	var rest := f_enemy.at
	var look_from := rest + (out - rest).normalized().cross(Vector3.UP) * 4.0
	_put(_ground(game, look_from), rest + Vector3.UP * 0.8, -8.0)
	await _wait(0.6)
	await _shot("drop_at_rest")
	print("render_ctf_carry: %d failed" % _failed)
	quit(1 if _failed > 0 else 0)
