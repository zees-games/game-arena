extends RefCounted

## Every key this game lets a player move, as one dot-menu [DotMenuBindings] table: the
## action, the setting that stores it, the words on the Controls page, the default and the
## card it goes on.
##
## [b]A table, because four things read it and they must never disagree:[/b] the InputMap,
## the settings document (one binding setting per row, declared by
## [method DotMenuBindings.add_to_schema]), the menu's Controls page and its help screen.
## Before dot-menu this game had dot-ui's rebinder, which filtered the InputMap on two
## prefixes and saved to a file of its own beside the settings document.
##
## [b]Only actions.[/b] Fire, aim, reload, the slots, the launch, the bash, the prop tool and
## push to talk are matched on a mouse button or keycode in `ArenaClient` and are not
## InputMap actions, so a row for one would be a key that moves on the page and nowhere
## else. They are listed as fixed keys on the Controls page ([constant FIXED_KEYS]) until
## they are actions.

## The two chat keys keep the settings they were stored under before this table existed,
## per ACCOUNT: changing a stored setting's key or scope resets somebody's binding.
const CHAT := &"arena_chat"
const CHAT_TEAM := &"arena_chat_team"
const SCOREBOARD := &"arena_scoreboard"

## The keys the client reads directly, as the Controls page and the help screen show them.
const FIXED_KEYS: Array = [
	["Mouse 1", "Fire"],
	["Mouse 2", "Aim (or bash; see Right mouse aims)"],
	["R", "Reload"],
	["1-5, wheel", "Weapon slots"],
	["Q", "Last weapon"],
	["E", "Launch (X in a props mode, where E is the prop tool)"],
	["F", "Bash (freeze in a props mode)"],
	["G", "Punt a prop"],
	["V", "Push to talk"],
]


static func make() -> DotMenuBindings:
	var keys := DotMenuBindings.new()
	# Duck is also the slide: a slide IS a duck at a run. C is added beside it while the row
	# is on its default ([method ArenaClient._add_slide_key]).
	keys.add_movement("Movement", "Ctrl", "Duck / slide")
	# The sprint bit, which this game spends on the dash (it has no sprint).
	keys.add(&"dot_fps_sprint", &"bind_dash", "Dash", "Shift", "Movement")
	keys.add(CHAT, &"chat_open_key", "Chat", "Y", "Chat", DotSettingsDef.Scope.ACCOUNT)
	keys.add(CHAT_TEAM, &"chat_team_key", "Team chat", "U", "Chat", DotSettingsDef.Scope.ACCOUNT)
	keys.add(SCOREBOARD, &"bind_scoreboard", "Scoreboard (hold)", "Tab", "Interface")
	return keys
