extends SceneTree

## Plays every weapon's reload and fire in the offline client, one after the other, for tools/review_clips_run.sh to record
## with --write-movie. Prints "REVIEW_CLIP <id> <kind> <first frame> <frames>" per clip; the run script cuts the movie there.
##   xvfb-run -a godot --path . --fixed-fps 30 --write-movie x.avi --script tools/review_clips.gd -- [--only a,b] [--left 1]

const ArenaPresentation := preload("../game/arena_presentation.gd")
const LEAD := 0.25
const TAIL := 0.7
const MAX_RELOAD := 7.0
const HOLD_FIRE := 1.1

var client: Node = null
var _frame := 0


func _initialize() -> void:
	preload("../game/arena_weapon_roles.gd").ensure()
	var _scratch := ArenaPresentation.use_scratch_settings("review_clips")
	client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	root.add_child(client)
	_run.call_deferred()


func _process(_delta: float) -> bool:
	_frame += 1
	return false


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var left := int(_arg(args, "--left", "1"))
	await _wait(16.0)
	var gate: Variant = client.get("gate")
	for i in 240:
		if gate == null or (gate as Object).call(&"is_open"):
			break
		await _wait(0.5)
	var ids: Array = []
	for id: StringName in AwWeaponCatalogue.table():
		ids.append(str(id))
	var only := _arg(args, "--only", "")
	if only != "":
		ids = Array(only.split(","))
	var fps := int(_arg(args, "--fps", "30"))
	var done := 0
	for id_s in ids:
		var id := StringName(id_s)
		var def: DotWeaponDef = AwWeaponCatalogue.table().get(id)
		if def == null:
			print("%s: unknown weapon, skipped" % id)
			continue
		var me = client.get("player")
		me.health.invulnerable = true
		for _w in 120:
			if not me.arsenal.is_reloading():
				break
			await process_frame
		if me.arsenal.carry != null:
			me.arsenal.carry.enabled = false
		var given: DotResult = me.arsenal.give(id)
		if not given.ok:
			print("%s: give failed: %s" % [id, given.message])
		me.arsenal.equip(def.slot)
		await _wait(1.4)
		var slot: DotWeaponSlot = me.arsenal.current()
		if slot == null or slot.def.id != id:
			print("%s: not in hand, skipped" % id)
			continue
		if def.uses_magazine():
			slot.magazine = clampi(left, 0, def.magazine - 1)
			var first := _frame
			Input.action_press(&"arena_reload")
			await _wait(0.15)
			Input.action_release(&"arena_reload")
			var t := 0.0
			while me.arsenal.is_reloading() and t < MAX_RELOAD:
				await process_frame
				t += 1.0 / fps
			await _wait(TAIL)
			print("REVIEW_CLIP %s reload %d %d" % [id, maxi(first - int(LEAD * fps), 0), _frame - first + int(LEAD * fps)])
			await _wait(0.4)
		if def.uses_magazine():
			slot.magazine = def.magazine
		var shot_first := _frame
		Input.action_press(&"arena_fire")
		await _wait(HOLD_FIRE)
		Input.action_release(&"arena_fire")
		await _wait(TAIL + 0.3)
		print("REVIEW_CLIP %s fire %d %d" % [id, maxi(shot_first - int(LEAD * fps), 0), _frame - shot_first + int(LEAD * fps)])
		done += 1
		await _wait(0.5)
	print("review_clips: %d weapons recorded" % done)
	quit(0 if done > 0 else 1)


func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout
