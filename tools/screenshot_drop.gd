extends RefCounted
## `--drop`: a dropped weapon in the local player's view with its panel, the hold circle filling, and a shot drop tumbling.


static func stage(game, local, _hud) -> Array[Dictionary]:
	var drops = game.weapon_drops
	if drops == null:
		return []
	var eye: Vector3 = local.camera.global_position
	var dir := Vector3(0.0, -0.45, -1.0).normalized()
	var aim_cam := func() -> void:
		local.camera.global_position = eye
		local.camera.look_at(eye + dir * 2.0, Vector3.UP)
		local.camera.current = true
	var held := &""
	for n: int in local.arsenal.slots():
		if local.arsenal.slot_at(n).def.slot == ZeeWeaponIds.SLOT_PRIMARY:
			held = local.arsenal.slot_at(n).def.id
	var other := &"rifle" if held != &"rifle" else &"smg"
	var state := {"id": other, "magazine": 17, "reserve": 40}
	var view := DotWeaponPickupView.new()
	view.name_of = func(id: StringName) -> String:
		var def: Variant = local.arsenal.catalogue.get_def(id)
		return def.name_or_id() if def != null else String(id)
	game.add_child(view)
	var info := {}
	var spawn := func() -> void:
		aim_cam.call()
		drops.clear()
		drops.rules.pickup_delay = 0.0
		var _id: int = drops.spawn(state, eye + dir * 2.0, Vector3.ZERO, 0)
		for _t in 64 * 2:
			game.tick({})
		aim_cam.call()
		info = drops.prompt_for(local.arsenal, eye, dir, game.weapon_drop_class_of(local.player_id))
		view.show_prompt(info, 0.0)
	var circle := func() -> void:
		aim_cam.call()
		view.show_prompt(info, 0.62)
	var shoot := func() -> void:
		aim_cam.call()
		view.show_prompt({}, 0.0)
		var tr: DotTrace = game.combat.trace
		var _r := tr.ray(eye, dir, 6.0)
		if _hud != null:
			_hud.use_hint = ""
	return [
		{"name": "drop_panel", "local": true, "arm": spawn, "wait": 10},
		{"name": "drop_hold", "local": true, "arm": circle, "wait": 6},
		{"name": "drop_shot_1", "local": true, "arm": shoot, "wait": 5},
		{"name": "drop_shot_2", "local": true, "wait": 14},
		{"name": "drop_shot_3", "local": true, "wait": 24},
	]
