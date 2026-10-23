extends RefCounted

## Every key this game reads, as one dot-menu [DotMenuBindings] table: the action, the
## setting that stores it, the words on the Controls page, the default and the card it
## goes on.
##
## [b]A table, because four things read it and they must never disagree:[/b] the InputMap,
## the settings document (one binding setting per row, declared by
## [method DotMenuBindings.add_to_schema]), the menu's Controls page and its help screen.
## Before dot-menu this game had dot-ui's rebinder, which filtered the InputMap on two
## prefixes and saved to a file of its own beside the settings document.
##
## [b]Every key the client reads is a row, and is read through its action[/b]
## (`Input.is_action_pressed`, `event.is_action`), never a keycode. Until 2026-10-11 fire,
## aim, reload, the slots, the launch, the bash, the prop keys and push to talk were
## keycodes in `ArenaClient`, and the Controls page could only list them as fixed.
##
## [b]The props-mode keys are the launch's and the bash's.[/b] In a mode where players use
## props (`ArenaClient.props_on_e`) the Launch key grabs and drops a prop, the Bash key
## freezes it, and the launch moves to its own row ([constant LAUNCH_PROPS], X). Not two
## more rows on E and F: two rows on one default are a conflict the table's swap cannot
## finish (binding a third action to E would move only one of them off it).
##
## [b]No noclip key.[/b] dot-player-controller registers `dot_fps_noclip` on V, which is
## push to talk here. Arena's noclip is an administrator's modifier (`noclip` at the
## console or in chat) and the motor ignores the bit unless the server granted it, so the
## client takes the role off its sampler (`ArenaClient.make_sampler`) and V
## is push to talk alone.

## The two chat keys keep the settings they were stored under before this table existed,
## per ACCOUNT: changing a stored setting's key or scope resets somebody's binding.
const CHAT := &"arena_chat"
const CHAT_TEAM := &"arena_chat_team"
const SCOREBOARD := &"arena_scoreboard"

const DUCK := &"dot_fps_crouch"
const WALK := &"dot_fps_walk"
## The sprint bit, which this game spends on the dash (it has no sprint).
const DASH := &"dot_fps_sprint"
const LAUNCH := &"arena_launch"
const LAUNCH_PROPS := &"arena_launch_props"
const FIRE := &"arena_fire"
const AIM := &"arena_aim"
const BASH := &"arena_bash"
const RELOAD := &"arena_reload"
## Slots 1 to 5: melee, sidearm, primary, heavy, throwable (the pack's five).
const SLOTS: Array[StringName] = [
	&"arena_slot_1", &"arena_slot_2", &"arena_slot_3", &"arena_slot_4", &"arena_slot_5",
]
const SLOT_NAMES: Array[String] = ["melee", "sidearm", "primary", "heavy", "throwable"]
## The wheel. Godot numbers its two directions as mouse buttons 4 (up) and 5 (down).
const WEAPON_PREVIOUS := &"arena_weapon_previous"
const WEAPON_NEXT := &"arena_weapon_next"
const WEAPON_LAST := &"arena_weapon_last"
const PUNT := &"arena_punt"
## First or third person, where the server allows it (`mp_forceview`).
const VIEW := &"arena_view"
## The spectator's free camera, on and off (`mp_freeroam`). Its flying keys are the movement keys.
const ROAM := &"arena_roam"
## dot-voice's action (DotVoiceManager.TALK_ACTION), so the talk key is one setting with every
## other game's; still stored as bind_voice.
const VOICE := &"dot_voice_talk"
const VOICE_GAG := &"voice_gag"
const VOICE_MUTE := &"voice_mute"


## The key table. The wheel rows are written by name ("Wheel up" / "Wheel down"): a pack
## asks for dot-ui 4 (requires.floor.json), and dot-ui names the wheel from level 2.
static func make() -> DotMenuBindings:
	var keys := DotMenuBindings.new()
	# Duck is also the slide: a slide IS a duck at a run. C is added beside it while the row
	# is on its default and no other row has C ([method ArenaClient._add_slide_key]).
	keys.add_movement("Movement", "Ctrl", "Duck / slide")
	keys.add(WALK, &"bind_walk", "Walk", "Alt", "Movement")
	keys.add(DASH, &"bind_dash", "Dash", "Shift", "Movement")
	keys.add(LAUNCH, &"bind_launch", "Launch (grab a prop in a props mode)", "E", "Movement")
	keys.add(LAUNCH_PROPS, &"bind_launch_props", "Launch, in a props mode", "X", "Movement")

	keys.add(FIRE, &"bind_fire", "Fire", "Mouse 1", "Weapons")
	keys.add(AIM, &"bind_aim", "Aim (bashes with Right mouse aims off)", "Mouse 2", "Weapons")
	keys.add(BASH, &"bind_bash", "Bash (freeze a prop in a props mode)", "F", "Weapons")
	keys.add(RELOAD, &"bind_reload", "Reload", "R", "Weapons")
	for i in range(SLOTS.size()):
		keys.add(SLOTS[i], StringName("bind_slot_%d" % (i + 1)),
			"Slot %d: %s" % [i + 1, SLOT_NAMES[i]], str(i + 1), "Weapons")
	keys.add(WEAPON_PREVIOUS, &"bind_weapon_previous", "Previous weapon", "Wheel up", "Weapons")
	keys.add(WEAPON_NEXT, &"bind_weapon_next", "Next weapon", "Wheel down", "Weapons")
	keys.add(WEAPON_LAST, &"bind_weapon_last", "Last weapon", "Q", "Weapons")
	keys.add(PUNT, &"bind_punt", "Punt a prop", "G", "Weapons")

	keys.add(CHAT, &"chat_open_key", "Chat", "Y", "Chat", DotSettingsDef.Scope.ACCOUNT)
	keys.add(CHAT_TEAM, &"chat_team_key", "Team chat", "U", "Chat", DotSettingsDef.Scope.ACCOUNT)
	keys.add(VOICE, &"bind_voice", "Push to talk", "V", "Chat")
	# Look at a player and press (dot-game's DotGameClient): G is the punt and H is help here.
	keys.add(VOICE_GAG, &"bind_voice_gag", "Look at a player: stop (or resume) hearing them", "J", "Chat")
	keys.add(VOICE_MUTE, &"bind_voice_mute", "Look at a player: mute (or unmute) their voice and chat", "K", "Chat")
	keys.add(SCOREBOARD, &"bind_scoreboard", "Scoreboard (hold)", "Tab", "Interface")
	keys.add(VIEW, &"bind_view", "First or third person, where the server allows it", "F5", "Interface")
	keys.add(ROAM, &"bind_roam", "Free camera while spectating (move keys fly, Dash fast, Walk slow)", "T", "Interface")
	# H opens help, in every game of the family (dot-menu's `dot_menu_help`).
	keys.add_help("Interface")
	# M is the map menu, in every game of the family (dot-menu's `dot_menu_maps`).
	var _m := keys.add_maps("Interface")
	# B is the loadout menu (dot-menu's `dot_menu_loadout`), where the host has it (API 6).
	if DotAddonApi.build_level("dot_menu") >= 6 and keys.has_method(&"add_loadout"):
		var _l: Variant = keys.call(&"add_loadout", "Weapons")
	return keys
