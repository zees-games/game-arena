extends Node

const ArenaPaths := preload("../game/arena_paths.gd")
const ArenaWeaponSkins := preload("../game/arena_weapon_skins.gd")

func _ready() -> void:
	AwModelCache.set_asset_root(ArenaPaths.root())
	ArenaWeaponSkins.apply()
	var cam := Camera3D.new()
	add_child(cam)
	var vm := AwViewModel.new()
	cam.add_child(vm)
	await get_tree().process_frame
	var t_all := Time.get_ticks_usec()
	var tot_load := 0
	var tot_pre := 0
	for id in AwWeaponArtTable.table():
		var art: AwWeaponVisual = AwWeaponArtTable.table()[id]
		var t0 := Time.get_ticks_usec()
		if art.has_model():
			AwModelCache.warm([art.model_path])
		var t1 := Time.get_ticks_usec()
		vm.prewarm(art)
		var t2 := Time.get_ticks_usec()
		vm.prewarm(art)
		var t3 := Time.get_ticks_usec()
		tot_load += t1 - t0
		tot_pre += t2 - t1
		print("PC %s load %.1f ms prewarm %.1f ms, again (spans cached) %.1f ms path=%s" % [id, (t1 - t0) / 1000.0, (t2 - t1) / 1000.0, (t3 - t2) / 1000.0, art.model_path if art.has_model() else "-"])
	print("PC total load %.0f ms prewarm(after load) %.0f ms" % [tot_load / 1000.0, tot_pre / 1000.0])
	get_tree().quit()
