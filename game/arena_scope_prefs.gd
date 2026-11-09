class_name ArenaScopePrefs
extends RefCounted

## The player's scope settings, read by the player each frame and written by the cvars. A class of its own
## so the player script does not depend on the view arms (which depend on the player).

## cl_scope_mode: 1 shows the scope as a lens on a normal screen, 2 fills the screen with it; a server's `scope_mode` ADS rule overrides.
static var mode := 1
## cl_scope_walk_clear: how much of the scope's picture goes clear while moving (0 solid, 1 fully see-through).
static var walk_clear := 0.55


## Gives [param model] this machine's scope view and walking clear.
static func apply(model: AwViewModel) -> void:
	model.scope_walk_clear = walk_clear
	model.scope_mode = model.resolve_scope_mode(mode)
