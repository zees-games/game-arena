extends SceneTree

## The offline client's B menu and its crosshair down the sights: a frame of each, and a line
## saying what the client did. The check behind the loadout menu (dot-menu's
## `DotMenuLoadoutScreen`, dot-loadout's offer) and the crosshair's fade (dot-ui's
## `DotCrosshair.aim_source`), which no headless suite can look at.
##
##   xvfb-run -a godot --path . --resolution 1280x720 --script tools/render_loadout.gd

const ArenaPresentation := preload("../game/arena_presentation.gd")

const OUT_DIR := "screenshots/loadout"

var client: Node = null
var _failed := 0


func _initialize() -> void:
	var _scratch := ArenaPresentation.use_scratch_settings("render_loadout")
	var scene: PackedScene = load("res://game/arena.tscn")
	client = scene.instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	root.add_child(client)
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	await _wait(6.0)
	var me = client.get("player")
	var menu: DotMenu = client.get("game_menu")
	me.health.invulnerable = true

	# The menu, on B as a player presses it.
	var b := InputEventKey.new()
	b.physical_keycode = KEY_B
	b.keycode = KEY_B
	b.pressed = true
	Input.parse_input_event(b)
	await _wait(0.5)
	var screen := menu.loadout_screen
	_check(screen != null and screen.is_open(), "B opens the loadout screen")
	await _shot("arena_loadout_primary")
	# The heaviest gun with armour on: over the budget, said on the card.
	screen.show_slot(4)
	var _armour := screen.pick(0)
	screen.show_slot(0)
	for i in screen.choices().size():
		if str((screen.choices()[i] as Dictionary)["id"]) == "minigun":
			var _over := screen.pick(i)
	await _shot("arena_loadout_over_budget")
	screen.revert()
	screen.show_slot(3)
	await _shot("arena_loadout_grenades")
	screen.show_slot(0)
	for i in screen.choices().size():
		if str((screen.choices()[i] as Dictionary)["id"]) == "battle_rifle":
			var _p := screen.pick(i)
	screen.close()
	await _wait(0.6)
	_check(me.arsenal.carries(&"battle_rifle"), "closing sends it, and in warmup it is in the player's hands")
	await _shot("arena_loadout_equipped")

	# The crosshair: at the hip, then down the sights with the aim key held.
	me.arsenal.select(ZeeWeaponIds.SLOT_PRIMARY, client.get("game").current_tick())
	await _wait(1.0)
	await _shot("arena_ads_hip")
	var hud = client.get("hud")
	var hip: float = hud.crosshair.aim_opacity
	Input.action_press(&"arena_aim")
	await _wait(0.12)
	await _shot("arena_ads_raising")
	await _wait(0.8)
	var aimed: float = hud.crosshair.aim_opacity
	await _shot("arena_ads_aimed")
	Input.action_release(&"arena_aim")
	await _wait(0.8)
	_check(hip > 0.99 and aimed < 0.01 and hud.crosshair.aim_opacity > 0.99,
		"the crosshair is there at the hip (%.2f), gone aimed (%.2f), back after (%.2f)" % [hip, aimed, hud.crosshair.aim_opacity])

	# A scoped gun: its own reticle, the crosshair hidden as it always was.
	var _given = me.arsenal.give(&"marksman")
	me.arsenal.select(ZeeWeaponIds.SLOT_PRIMARY, client.get("game").current_tick())
	await _wait(1.0)
	Input.action_press(&"arena_aim")
	await _wait(1.0)
	await _shot("arena_ads_scoped")
	Input.action_release(&"arena_aim")

	print("%d failed" % _failed)
	quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String) -> void:
	print("  %s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failed += 1


func _shot(file: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var path := "%s/%s.png" % [OUT_DIR, file]
	var _saved := root.get_viewport().get_texture().get_image().save_png(path)
	print("  wrote %s" % path)


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout
