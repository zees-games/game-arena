extends Node

## Fire, Tab and the console key reach their handlers, through the real input pipeline.
##
## [b]Why this suite exists.[/b] On 2026-11-10 a player could run but not shoot, Tab showed no
## scoreboard, the console key did nothing and the settings pages were empty. Movement and
## the Escape and map menus register their own actions (dot-player-controller's sampler,
## dot-menu, the built-in `ui_cancel`); fire, the scoreboard key and the console all come
## from the presentation layer ([code]ArenaPresentation[/code], its bindings table and its
## console). The presentation did not compile: it named an addon class
## ([code]DotVoiceQueue[/code]) that the published addon did not have yet. With no
## presentation the client's `_is`/`_held` guards ([code]InputMap.has_action[/code]) quietly
## dropped every arena key.
##
## So the client chain is loaded here with [code]load()[/code], not [code]preload[/code]: a
## presentation that does not compile is a FAIL line in this suite, not a suite that never
## starts. The other suites preload the client and simply do not run when it breaks, which
## a suite list read on a machine with newer, unpushed addons never shows.
##
## [codeblock]
## godot --headless --path . res://examples/headless_input_reach.tscn
## [/codeblock]

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


## The client chain's roots that do not compile. The client extends the client state, which
## preloads the presentation, which extends its two halves: one class missing anywhere in that
## graph fails the root, and the game still starts, with half its keys dead. Only the roots are
## loaded: loading every script in res://game at once keeps ~1300 scripts alive past exit
## (graphs the game never loads together), which game.sh rightly fails as a leak.
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
