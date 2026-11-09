extends "arena_presentation_b2.gd"


# --- Settings ---------------------------------------------------------------


## Points every [ArenaPresentation] made after this at a fresh, empty settings directory named
## [param tag], and returns it.
static func use_scratch_settings(tag: String) -> String:
	# One directory per process (dot-settings' DotSettingsScratch): user:// is shared by every run on the machine.
	var dir := DotSettingsScratch.use(tag)
	settings_directory = dir
	return dir


## Points the look settings at the tunables the client's sampler reads, and applies them.
func bind_look(tunables: DotFpsTunables) -> void:
	_look = tunables
	_apply_look()


# --- The events a deathmatch has -------------------------------------------


func on_server_clamps(request: Dictionary) -> PackedStringArray:
	return settings.apply_server_clamps(request)
