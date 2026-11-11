extends Node

## Fire, Tab and the console key reach their handlers through the real input path. They all come
## from the presentation; if it fails to compile (an addon class the published addon lacks), the
## client's InputMap.has_action guards drop every arena key, so the chain is load()ed, not preloaded.

const EXPECTED_CHECKS := 7

var _checks := 0
var _failed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _finish() -> void:
	var ok := _failed == 0 and _checks == EXPECTED_CHECKS
	print("%d checks, %d failed (expected %d)" % [_checks, _failed, EXPECTED_CHECKS])
	get_tree().quit(0 if ok else 1)


## Client-chain roots that fail to compile: a class missing anywhere in their graph fails the root.
## Only the roots: load()ing all of res://game keeps ~1300 scripts alive past exit (a leak in game.sh).
const CLIENT_ROOTS: Array[String] = [
	"res://game/arena_client.gd", "res://game/arena_presentation.gd",
	"res://game/arena_presentation_b1.gd", "res://game/arena_presentation_b2.gd",
	"res://game/arena_menus.gd", "res://game/arena_bindings.gd",
]


static func _uncompiled() -> PackedStringArray:
	var bad := PackedStringArray()
	for path in CLIENT_ROOTS:
		var script := load(path) as GDScript
		if script == null or not script.can_instantiate():
			bad.append(path.get_file())
	return bad


func _run() -> void:
	print("game-arena: fire, Tab and the console key reach their handlers")

	var bad := _uncompiled()
	_check(bad.is_empty(), "the client, the presentation and its halves, the menus and the bindings compile", ", ".join(bad))
	if not bad.is_empty():
		_finish()
		return

	var presentation_script := load("res://game/arena_presentation.gd") as GDScript
	var client_script := load("res://game/arena_client.gd") as GDScript
	var menus_script := load("res://game/arena_menus.gd") as GDScript
	var bindings_script := load("res://game/arena_bindings.gd") as GDScript

	var _scratch: Variant = presentation_script.call(&"use_scratch_settings", "headless_input_reach")
	var p: Node = presentation_script.new()
	p.name = "P"
	add_child(p)
	p.call(&"setup")

	# ArenaMenus.build builds the console over the menu (build_console(menu)), as the client
	# does; a second, menu-less build_console here would orphan one console and leak it.
	var client: Node = client_script.new()
	client.set(&"presentation", p)
	var menu: Node = menus_script.call(&"build", self, p)
	client.set(&"game_menu", menu)

	var fire: StringName = bindings_script.get(&"FIRE")
	var board: StringName = bindings_script.get(&"SCOREBOARD")
	var missing: Array[String] = []
	for action: StringName in [fire, board]:
		if not InputMap.has_action(action):
			missing.append(String(action))
	_check(missing.is_empty(), "the presentation puts fire and the scoreboard key in the InputMap", str(missing))

	# Fire: a left click through Input, read the way the client's command builder reads it.
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	Input.parse_input_event(click)
	Input.flush_buffered_events()
	_check(bool(client_script.call(&"_held", fire)), "a left click holds the fire action")
	var lift := click.duplicate() as InputEventMouseButton
	lift.pressed = false
	Input.parse_input_event(lift)
	Input.flush_buffered_events()

	# Tab: the menu's own key path opens the held scoreboard.
	var tab := InputEventKey.new()
	tab.keycode = KEY_TAB
	tab.physical_keycode = KEY_TAB
	tab.pressed = true
	var scoreboard: Variant = menu.get(&"scoreboard")
	_check(scoreboard != null, "the menu has a scoreboard")
	var _taken: Variant = menu.call(&"handle_event", tab)
	_check(scoreboard != null and bool(scoreboard.call(&"is_open")), "Tab opens the scoreboard")
	var tab_up := tab.duplicate() as InputEventKey
	tab_up.pressed = false
	_taken = menu.call(&"handle_event", tab_up)

	# The console key (the one under Escape), pushed through the viewport like a real press.
	var console: Variant = p.get(&"console")
	_check(console != null, "the presentation builds a console")
	var grave := InputEventKey.new()
	grave.keycode = KEY_QUOTELEFT
	grave.physical_keycode = KEY_QUOTELEFT
	grave.pressed = true
	get_viewport().push_input(grave)
	await get_tree().process_frame
	_check(console != null and bool(console.call(&"is_open")), "the console key opens the console")

	client.free()
	_finish()
