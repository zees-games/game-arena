extends SceneTree

## Photographs health bars and name tags: three bots in a row at full, half and nearly no health
## with both tags "always", then the cursor-only setting. tools/screenshot_tags.sh -> screenshots/tags_*.png

const ArenaPresentation := preload("../game/arena_presentation.gd")

const OUT_DIR := "res://screenshots"
const DISTANCE := 5.0
const SPREAD := 1.7
const CHEST := 1.1

var client: Node = null
var _bots: Array = []
var _seq := DotShotSeq.new()


func _initialize() -> void:
	var _scratch := ArenaPresentation.use_scratch_settings("screenshot_tags")
	var scene: PackedScene = load("res://game/arena.tscn")
	client = scene.instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	root.add_child(client)
	_run.call_deferred()


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout


static func _dir_of(yaw_deg: float) -> Vector3:
	var r := deg_to_rad(yaw_deg)
	return Vector3(-sin(r), 0.0, -cos(r))


func _clear(from: Vector3, dir: Vector3, limit: float) -> float:
	var hit = client.get("game").combat.trace.ray(from, dir, limit)
	return hit.distance if hit.ok() else limit


func _floor_under(at: Vector3, floor_y: float) -> bool:
	var hit = client.get("game").combat.trace.ray(at + Vector3.UP, Vector3.DOWN, 2.0)
	return hit.ok() and absf(hit.point.y - floor_y) < 0.4


## Stands three bots in a row across the view, facing the player; returns the yaw the player must face.
func _stage() -> float:
	var me = client.get("player")
	var bots: Dictionary = client.get("_bots")
	for id in bots:
		var bot = bots[id]
		bot.set_meta(&"bot_scripted", true)
		bot.set_meta(&"bot_move", DotFpsCommand.new())
		bot.set_meta(&"bot_fire", DotWeaponCommand.new())
		bot.health.invulnerable = true
		if _bots.size() < 3 and bot.is_alive():
			_bots.append(bot)
	me.health.invulnerable = true
	var feet: Vector3 = me.controller.state.position
	var chest := feet + Vector3.UP * CHEST
	var looking: float = me.controller.state.yaw
	for step in range(24):
		var yaw := looking + floorf(float(step + 1) / 2.0) * 15.0 * (1.0 if step % 2 == 0 else -1.0)
		var dir := _dir_of(yaw)
		var side := _dir_of(yaw + 90.0)
		var ok := true
		for i in 3:
			var spot := feet + dir * DISTANCE + side * (float(i - 1) * SPREAD)
			if _clear(chest, (spot + Vector3.UP * CHEST - chest).normalized(), DISTANCE + 1.0) < DISTANCE or not _floor_under(spot, feet.y):
				ok = false
		if not ok:
			continue
		for i in _bots.size():
			var spot := feet + dir * DISTANCE + side * (float(i - 1) * SPREAD)
			_bots[i].controller.teleport(spot + Vector3.UP * 0.05, yaw + 180.0, 0.0)
		return yaw
	push_error("screenshot_tags: no clear row ahead of the player")
	return looking


func _shot(name: String) -> void:
	await process_frame
	await process_frame
	var path := ProjectSettings.globalize_path("%s/tags_%s.png" % [OUT_DIR, name])
	root.get_texture().get_image().save_png(path)
	await _seq.record(self, path)
	print(path)


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	await _wait(32.0)
	var yaw := _stage()
	client.get("_sampler").look_at_angles(yaw, 0.0)
	var settings = client.get("presentation").settings
	var fractions := [1.0, 0.5, 0.12]
	for mode in ["always", "hover"]:
		var _a = settings.set_value(&"name_tags", mode)
		var _b = settings.set_value(&"health_bars", mode)
		for i in _bots.size():
			var bot = _bots[i]
			bot.health.health = bot.health.max_health * float(fractions[i])
		# Each bot's tag eases to its health: wait it out, and keep the bots in place.
		await _wait(2.5)
		await _shot(mode)
	quit()
