extends "render_base.gd"

## Capture the flag through the real offline client, picked from the M menu, on a full map: flags drawn, pickup, carrier view,
## drop, return, capture. Frames in screenshots/ctf/; exit 1 on a failed check. Run:
##   xvfb-run -a godot --path . --resolution 1280x720 --script tools/render_ctf.gd -- --map cp-orange-x3


var _events: Array[String] = []
var _seen: Array[String] = []
var _game: Node
var _me: Node
var _ctf: DotObjectiveCtf
var _f_mine: DotObjectiveFlag
var _f_enemy: DotObjectiveFlag
var _view: Node
var _mine := 0
var _enemy := 0
var _camera: Camera3D
var _plate := Vector3.ZERO
var _enemy_spot := Vector3.ZERO


func _setup() -> void:
	_map_id = "cp-orange-x3"
	_out_dir = "res://screenshots/ctf"
	_scratch_name = "render_ctf"


## A spot on the ground [param back] metres from [param flag_at] toward [param toward].
func _stand_near(game: Node, flag_at: Vector3, toward: Vector3, back: float) -> Vector3:
	var dir := toward - flag_at
	dir.y = 0.0
	dir = dir.normalized()
	var spot := flag_at + dir * back
	var hit = game.combat.trace.ray(spot + Vector3.UP * 3.0, Vector3.DOWN, 8.0)
	if hit.ok():
		spot.y = hit.point.y
	return spot


static func _near_home(drawn: Vector3, at: Vector3) -> bool:
	return Vector2(drawn.x, drawn.z).distance_to(Vector2(at.x, at.z)) < 0.3 and drawn.y <= at.y + 0.05 and drawn.y > at.y - 2.0


func _hud_line() -> String:
	return str(client.get("hud").call("_objective_line"))


func _hud_carry() -> String:
	var hud = client.get("hud")
	return str(hud.call("carrying_flag_text")) if hud.has_method("carrying_flag_text") else ""


func _run() -> void:
	if not await _bring_up():
		return
	_freeze_bots()
	await _stage_flags_in_view()
	await _stage_plate()
	await _stage_pickup()
	await _stage_capture()
	await _stage_drop()
	print("render_ctf: %d failed" % _failed)
	quit(1 if _failed > 0 else 0)


## Menu to the capture-the-flag map, a live match and the flag view checks; false (after quit) when the layer is missing.
func _bring_up() -> bool:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir))
	print("render_ctf: %s" % _map_id)
	await _wait_gate(60.0)
	await _wait(4.0)
	var picked: DotResult = await client.call("change_from_menu", &"map:%s" % _map_id, &"mode:ctf")
	_check(picked.ok, "the M menu changes to %s in capture the flag (%s)" % [_map_id, str(picked.error) if not picked.ok else "ok"])
	await _wait_gate(60.0)
	await _wait(3.0)
	var game = client.get("game")
	var me = client.get("player")
	_game = game
	_me = me
	_check(game.mode.objective_layout == &"ctf", "the mode is capture the flag")
	var objs = game.objectives
	_check(objs != null and objs.ctf != null, "the game has the ctf layer")
	if objs == null or objs.ctf == null:
		quit(1)
		return false
	var ctf: DotObjectiveCtf = objs.ctf
	_ctf = ctf
	game.ctf_seen.connect(func(what: StringName, team: int, by: int) -> void: _seen.append("%d:%s:%d" % [team, what, by]))
	ctf.flag_event.connect(func(team: int, what: StringName, data: Dictionary) -> void:
		_events.append("%d:%s" % [team, what])
		print("  EVENT team=%d %s %s" % [team, what, data]))

	game.match_node.rules.warmup_sec = 0.0
	game.freeze_sec = 0.0
	for i in 100:
		if game.match_node.state == DotMatch.State.LIVE:
			break
		await _wait(0.1)
	var mine: int = game.team_of(me.player_id)
	print("  match state %s, my team %d, id %d" % [game.match_node.state, mine, me.player_id])
	var ids: Array[int] = []
	for f in ctf.flags():
		ids.append(f.home_team())
	_check(ids.size() == 2 and mine in ids, "two flags and I am on one of the teams (teams %s, me %d)" % [ids, mine])
	var enemy: int = ids[0] if ids[1] == mine else ids[1]
	_mine = mine
	_enemy = enemy
	var f_mine: DotObjectiveFlag = ctf.flag_of(mine)
	var f_enemy: DotObjectiveFlag = ctf.flag_of(enemy)
	_f_mine = f_mine
	_f_enemy = f_enemy
	print("  flags: mine at %s, enemy at %s" % [f_mine.at, f_enemy.at])

	var view = objs.flag_view
	_view = view
	_check(view != null, "the client builds the flag view")
	if view == null:
		quit(1)
		return false
	_check(view.drawn_count() == 2, "both flags are drawn")
	_check(_near_home(view.view_position(mine), f_mine.at) and _near_home(view.view_position(enemy), f_enemy.at),
		"each flag is drawn at its home, on the floor")
	var camera := root.get_viewport().get_camera_3d()
	_check(camera != null, "there is a camera")
	_camera = camera
	return true


func _freeze_bots() -> void:
	var game: Node = _game
	var me: Node = _me
	me.health.invulnerable = true
	for id in game.player_ids():
		if id != me.player_id:
			var bot = game.player_for(id)
			if bot != null:
				bot.set_meta(&"bot_scripted", true)
				bot.health.invulnerable = true


## Each flag from a short way off, then the far marker.
func _stage_flags_in_view() -> void:
	var game: Node = _game
	var f_mine: DotObjectiveFlag = _f_mine
	var f_enemy: DotObjectiveFlag = _f_enemy
	var view = _view
	var enemy: int = _enemy
	var camera: Camera3D = _camera
	# 1. Each flag from a short way off, looking at it.
	for pair in [["own", f_mine, f_enemy], ["enemy", f_enemy, f_mine]]:
		var flag: DotObjectiveFlag = pair[1]
		var spot := _stand_near(game, flag.at, pair[2].at, 6.0)
		_put(spot, flag.at + Vector3.UP * 1.5)
		await _wait(0.6)
		_check(camera.is_position_in_frustum(flag.at + Vector3.UP * 1.5), "the %s flag is in view from 6 m" % pair[0])
		await _shot("%s_flag_6m" % pair[0])

	# 1b. The enemy flag from my own base, across the map: the marker (team-coloured flag icon and its distance, through walls) and no beam.
	_put(_stand_near(game, f_mine.at, f_enemy.at, 2.0), f_enemy.at + Vector3.UP * 3.0, -2.0)
	await _wait(0.8)
	var far_view: Node3D = view._views.get(enemy)
	var far_dist := far_view.get_node_or_null("Dist") as Label3D if far_view != null else null
	print("  enemy marker from my base: '%s'" % [far_dist.text if far_dist != null else "<none>"])
	_check(far_view != null and far_view.get_node_or_null("Beam") == null and far_view.get_node_or_null("Icon") != null, "the enemy flag has an icon marker and no beam")
	_check(far_dist != null and far_dist.text.ends_with("m") and far_dist.text.to_float() > 5.0, "the marker reads the distance in metres")
	await _shot("enemy_marker_far")


## Standing on my own flag's plate, nothing carried.
func _stage_plate() -> void:
	var game: Node = _game
	var f_mine: DotObjectiveFlag = _f_mine
	var f_enemy: DotObjectiveFlag = _f_enemy
	# 2. Standing on my own flag's plate, nothing carried.
	_plate = _stand_near(game, f_mine.at, f_enemy.at, 0.3)
	_put(_plate, f_enemy.at, -15.0)
	await _wait(0.6)
	print("  HUD line on the plate: '%s'" % _hud_line())
	_check(_hud_carry() == "", "no carry indicator while carrying nothing")
	await _shot("plate_nothing_carried")


## Walk onto the enemy flag and look at the carry.
func _stage_pickup() -> void:
	var game: Node = _game
	var me: Node = _me
	var f_mine: DotObjectiveFlag = _f_mine
	var f_enemy: DotObjectiveFlag = _f_enemy
	var view = _view
	var enemy: int = _enemy
	# 3. Walk onto the enemy flag.
	_enemy_spot = _stand_near(game, f_enemy.at, f_mine.at, 0.2)
	_put(_enemy_spot, f_enemy.at + Vector3.UP * 1.5)
	for i in 80:
		await _wait(0.05)
		if f_enemy.state == DotObjectiveFlag.State.CARRIED:
			break
	_check(f_enemy.state == DotObjectiveFlag.State.CARRIED and f_enemy.carrier == str(me.player_id),
		"walking onto the enemy flag picks it up (state %s carrier %s)" % [f_enemy.state, f_enemy.carrier])
	await _wait(0.5)
	_check(view.view_position(enemy).distance_to(me.global_position) < 1.5, "the carried flag is drawn on me")
	print("  HUD line carrying: '%s'  carry text: '%s'" % [_hud_line(), _hud_carry()])
	_check(_hud_carry() != "", "the HUD says I have the flag")
	await _shot("carrying_first_person")
	client.get("_sampler").look_at_angles(_yaw_to(me.global_position, f_mine.at), -5.0)
	await _wait(0.4)
	await _shot("carrying_heading_home")


## Carry it home and capture on my own plate.
func _stage_capture() -> void:
	var game: Node = _game
	var ctf: DotObjectiveCtf = _ctf
	var f_mine: DotObjectiveFlag = _f_mine
	var f_enemy: DotObjectiveFlag = _f_enemy
	var mine: int = _mine
	# 4. Carry it home and capture on my own plate.
	_put(_plate, f_enemy.at, -15.0)
	for i in 100:
		await _wait(0.05)
		if f_enemy.state != DotObjectiveFlag.State.CARRIED:
			break
	_check(int(ctf.scores.get(mine, 0)) >= 1, "standing on my plate with their flag captures it (scores %s)" % [ctf.scores])
	_check(f_enemy.state == DotObjectiveFlag.State.HOME, "their flag is back at its stand after the capture")
	_check(_hud_carry() == "", "the carry indicator is gone after the capture")
	print("  HUD line after capture: '%s'" % _hud_line())
	await _shot("after_capture")


## Drop the flag and check the events.
func _stage_drop() -> void:
	var game: Node = _game
	var me: Node = _me
	var f_mine: DotObjectiveFlag = _f_mine
	var f_enemy: DotObjectiveFlag = _f_enemy
	var view = _view
	var enemy: int = _enemy
	# 5. Drop.
	_put(_enemy_spot, f_enemy.at + Vector3.UP * 1.5)
	for i in 60:
		await _wait(0.05)
		if f_enemy.state == DotObjectiveFlag.State.CARRIED:
			break
	var drop_at: Vector3 = _stand_near(game, f_enemy.at, f_mine.at, 8.0)
	var dropped := f_enemy.drop(drop_at)
	_check(dropped.ok, "the flag can be dropped")
	_put(_stand_near(game, drop_at, f_mine.at, 7.0), drop_at + Vector3.UP, -5.0)
	await _wait(0.5)
	_check(f_enemy.state == DotObjectiveFlag.State.DROPPED and _near_home(view.view_position(enemy), drop_at), "a dropped flag is drawn where it fell")
	await _shot("dropped_flag")
	print("  events: %s" % [_events])
	_check(_events.has("%d:taken" % enemy) and _events.has("%d:captured" % enemy) and _events.has("%d:dropped" % enemy), "taken, captured and dropped were all raised")
	print("  seen by the view: %s" % [_seen])
	_check(_seen.has("%d:taken:%d" % [enemy, me.player_id]) and _seen.has("%d:captured:%d" % [enemy, me.player_id]) and _seen.has("%d:dropped:%d" % [enemy, me.player_id]),
		"the client raised taken, captured and dropped for the flag (sounds hang off these)")
