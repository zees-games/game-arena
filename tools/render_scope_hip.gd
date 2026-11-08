extends SceneTree

## What a player sees of a scoped weapon when NOT aiming: every frame (at the render rate) of the raise, the steady hip,
## the aim-in, the release, and a sprint, for each scoped rifle, saved to screenshots/scope_hip/<role>_<phase>_NNN.png and
## the aim fraction, scope fraction and flags in <role>.csv. tools/render_scope_hip.sh joins them into sheets.
##
##   SCOPE_ROLES=sniper,marksman,charge_rifle tools/render_scope_hip.sh

const ArenaPresentation := preload("../game/arena_presentation.gd")
const OUT_DIR := "screenshots/scope_hip"

var client: Node = null
var _log := PackedStringArray()
var _n := 0


func _initialize() -> void:
	preload("../game/arena_weapon_roles.gd").ensure()
	var _scratch := ArenaPresentation.use_scratch_settings("render_scope_hip")
	var scene: PackedScene = load("res://game/arena.tscn")
	client = scene.instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	root.add_child(client)
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	await _wait(16.0)
	var gate: Variant = client.get("gate")
	for i in 240:
		if gate == null or (gate as Object).call(&"is_open"):
			break
		await _wait(0.5)
	# The warm-up match can be seconds from its end: let it roll over to a fresh round before filming.
	await _wait(14.0)
	var wanted := OS.get_environment("SCOPE_ROLES")
	var roles := wanted.split(",") if wanted != "" else PackedStringArray(["sniper", "marksman", "charge_rifle"])
	for role in roles:
		var id := StringName(role)
		var def: DotWeaponDef = AwWeaponCatalogue.table().get(id)
		if def == null:
			print("no def %s" % role)
			continue
		_log = PackedStringArray(["frame,phase,aim,scope_fraction,scoped,sprint,fov"])
		_n = 0
		var me = client.get("player")
		me.health.invulnerable = true
		var _g = me.arsenal.give(id)
		# Switch to another slot and back so the raise is recorded from its first frame.
		me.arsenal.equip(1 if def.slot != 1 else 2)
		await _wait(0.6)
		me.arsenal.equip(def.slot)
		print("scope_hip equipped ", role, " current=", me.arsenal.current().id() if me.arsenal.current() != null else "none")
		await _grab(role, "raise", 24, false)
		await _grab(role, "hip", 6, false)
		Input.action_press(&"arena_aim")
		await _grab(role, "aimin", 40, false)
		Input.action_release(&"arena_aim")
		await _grab(role, "release", 40, false)
		await _grab(role, "hip2", 4, false)
		await _grab(role, "sprint", 30, true)
		var f := FileAccess.open("%s/%s.csv" % [OUT_DIR, role], FileAccess.WRITE)
		f.store_string("\n".join(_log) + "\n")
		f.close()
	quit(0)


func _grab(role: String, phase: String, frames: int, sprint: bool) -> void:
	for i in frames:
		var vm := _vm()
		if vm != null and sprint:
			vm.set_sprinting(true)
		await process_frame
		await RenderingServer.frame_post_draw
		var cam := root.get_viewport().get_camera_3d()
		_log.append("%d,%s,%.3f,%.3f,%s,%.2f,%.1f" % [_n, phase, vm.aim_fraction() if vm else -1.0, vm.scope_fraction() if vm else -1.0,
			str(vm.is_scoped()) if vm else "-", vm.sprint_fraction() if vm else -1.0, cam.fov if cam else 0.0])
		var _s := root.get_viewport().get_texture().get_image().save_png("%s/%s_%s_%03d.png" % [OUT_DIR, role, phase, i])
		_n += 1
	if sprint and _vm() != null:
		_vm().set_sprinting(false)


func _vm() -> AwViewModel:
	var vms := client.find_children("*", "AwViewModel", true, false)
	return vms[0] as AwViewModel if not vms.is_empty() else null


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout
