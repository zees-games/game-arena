extends SceneTree

## The offline client's first-person hands for every role an installed weapon pack skins: a frame at the hip and one aimed,
## written to screenshots/weapons/<role>_{hip,aim}.png (tools/render_weapons.sh joins them into a sheet).
## `--arena-no-weapon-skins` renders zee's own art for the comparison.
##
##   xvfb-run -a godot --path . --resolution 1280x720 --script tools/render_weapons.gd [-- --arena-no-weapon-skins]

const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaWeaponSkins := preload("../game/arena_weapon_skins.gd")

const OUT_DIR := "screenshots/weapons"

var client: Node = null


func _initialize() -> void:
	var _scratch := ArenaPresentation.use_scratch_settings("render_weapons")
	var scene: PackedScene = load("res://game/arena.tscn")
	client = scene.instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	root.add_child(client)
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	await _wait(16.0)
	# The loading cover holds until every weapon's view is warmed; a frame under it shows the cover.
	var gate: Variant = client.get("gate")
	for i in 240:
		if gate == null or (gate as Object).call(&"is_open"):
			break
		await _wait(0.5)
	var me = client.get("player")
	me.health.invulnerable = true
	print("skin packs: %s" % [ArenaWeaponSkins.applied])
	var roles: Array = []

	for pack in DirAccess.get_directories_at("res://addons"):
		var path := "res://addons/%s/spawn_provider.gd" % pack
		if ResourceLoader.exists(path) and (load(path) as GDScript).has_method(&"role_art"):
			for role in (load(path) as GDScript).call(&"role_art"):
				roles.append(str(role))

	# A game whose own pack holds the plain ids skins nothing by role: every weapon in the catalogue is its art.
	if roles.is_empty():
		for id: StringName in ZeeWeaponPack.table():
			roles.append(str(id))

	var only := OS.get_environment("RENDER_ONLY")
	if only != "":
		roles = Array(only.split(","))

	for role in roles:
		var id := StringName(role)
		var def: DotWeaponDef = ZeeWeaponPack.table().get(id)
		if def == null:
			continue
		# A warmup ending respawns the player with the default loadout: hand the weapon over again until both frames hold it.
		for attempt in 4:
			me = client.get("player")
			me.health.invulnerable = true
			var _g = me.arsenal.give(id)
			me.arsenal.equip(def.slot)
			await _wait(1.4)
			var vms := client.find_children("*", "ZeeViewModel", true, false)
			if not vms.is_empty():
				print("%s wall=%.3f" % [role, (vms[0] as ZeeViewModel).wall_amount()])
			await _shot("%s_hip" % role)
			Input.action_press(&"arena_aim")
			await _wait(0.9)
			await _shot("%s_aim" % role)
			Input.action_release(&"arena_aim")
			await _wait(0.3)
			if me == client.get("player") and me.arsenal.current() != null and me.arsenal.current().id() == id:
				break

	quit(0)


func _shot(file: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var _saved := root.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [OUT_DIR, file])
	print("wrote %s/%s.png" % [OUT_DIR, file])


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout
