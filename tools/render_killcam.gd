extends SceneTree

## Renders the end of a solo match: one bot kills another for the last point, then frames of the
## final killcam, the winner reveal and the scoreboard go to screenshots/killcam/. Run by
## render_killcam.sh under xvfb.

const ArenaPresentation := preload("../game/arena_presentation.gd")

const OUT_DIR := "res://screenshots/killcam"
## Seconds after the kill each frame is taken.
const SHOTS := [1.6, 4.6, 8.3, 12.8, 13.6, 14.6, 16.0, 18.0, 22.0]

var client: Node = null
var _map := "dm_atrium"
var _calm := false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--map")
	if at >= 0 and at + 1 < args.size():
		_map = args[at + 1]
	_calm = "--reduce-motion" in args
	var _scratch := ArenaPresentation.use_scratch_settings("render_killcam")
	var scene: PackedScene = load("res://game/arena.tscn")
	client = scene.instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	client.set("offline_bots", 2)
	root.add_child(client)
	_run.call_deferred()


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var game = client.get("game")
	for i in range(80):
		await _wait(0.25)
		if game != null and game.map != null and client.get("player") != null:
			break
	var changed = game.change_map(load("res://maps/arena_map.gd").by_id(StringName(_map)))
	print("map %s: %s" % [_map, "ok" if changed.ok else "failed"])
	var presentation: Object = client.get("presentation")
	if _calm and presentation != null:
		presentation.get("settings").set_value(&"reduce_motion", true)
	await _wait(2.0)
	var _began: bool = game.match_node.begin_round_now()
	for i in range(60):
		if game.match_node.state == DotMatch.State.LIVE:
			break
		await _wait(0.25)
	print("match state %d" % int(game.match_node.state))
	await _wait(1.0)
	var ids: Array = (client.get("_bots") as Dictionary).keys()
	if ids.size() < 2:
		print("FAIL two bots wanted, have %d" % ids.size())
		quit(1)
		return
	var killer = game.player_for(int(ids[0]))
	var victim = game.player_for(int(ids[1]))
	var me = client.get("player")
	var spawn: Transform3D = game.map.spawns[0]
	var yaw := spawn.basis.get_euler().y
	var ahead := -spawn.basis.z
	killer.controller.teleport(spawn.origin, yaw, 0.0)
	victim.controller.teleport(spawn.origin + ahead * 5.0, yaw + PI, 0.0)
	me.controller.teleport(spawn.origin - ahead * 3.0 + spawn.basis.x * 2.0, yaw, 0.0)
	await _wait(3.6)

	var mine: DotPlayerScore = game.match_node.scoreboard.find(str(killer.player_id))
	game.match_node.rules.score_limit = (mine.score if mine != null else 0) + 1
	victim.health.invulnerable = false
	victim.health.invulnerable_until_tick = -1
	var type = game.combat.damage_type(&"")
	var damage := DotDamage.make(killer.player_id, victim.player_id, victim.health.health + victim.health.armour + 50.0, type)
	damage.tick = game.current_tick()
	var applied = victim.health.apply(damage)
	game.combat.entity_killed.emit(victim.player_id, applied)
	print("kill: %s (%d) -> %s (%d), me %d, state %d" % [killer.display_name, killer.player_id, victim.display_name,
		victim.player_id, me.player_id, int(game.match_node.state)])
	var noted: Object = client.get("killcam")
	if noted != null:
		print("kills noted: %s" % str(noted.get("buffer").call(&"events_between", 0.0, 1.0e9, &"kill")))

	var last := 0.0
	for at_sec: float in SHOTS:
		await _wait(at_sec - last)
		last = at_sec
		await process_frame
		var kc: Object = client.get("killcam")
		var reveal: Object = client.get("winner_reveal")
		print("t=%.1f state=%d killcam=%s reveal=%s fps=%d paused=%s" % [at_sec, int(game.match_node.state),
			str(kc.call(&"is_playing")) if kc != null else "-", str(reveal.call(&"is_active")) if reveal != null else "-",
			Engine.get_frames_per_second(), paused])
		if kc != null:
			print("   %s" % "; ".join(kc.call(&"describe_lines")))
		var path := ProjectSettings.globalize_path("%s/%s%s_%03d.png" % [OUT_DIR, _map, "_calm" if _calm else "", int(at_sec * 10.0)])
		root.get_texture().get_image().save_png(path)
	quit(0)
