extends "arena_presentation_b2.gd"


# --- Settings ---------------------------------------------------------------


## Points every [ArenaPresentation] made after this at a fresh, empty settings directory named
## [param tag], and returns it.
static func use_scratch_settings(tag: String) -> String:
	# One directory per process: user:// is shared by every run on the machine, and a concurrent run wiping or rewriting
	# a shared directory re-binds keys and resets values under the other run. Directories of dead processes are swept.
	_sweep_dead_scratch()
	var dir := "user://scratch/%s_%d" % [tag, OS.get_process_id()]
	var abs_dir := ProjectSettings.globalize_path(dir)
	if DirAccess.dir_exists_absolute(abs_dir):
		for f in DirAccess.get_files_at(abs_dir):
			var _gone := DirAccess.remove_absolute(abs_dir.path_join(f))
	else:
		var _made := DirAccess.make_dir_recursive_absolute(abs_dir)
	settings_directory = dir
	return dir


## Removes the scratch settings directories (`<tag>_<pid>`) whose process has exited.
static func _sweep_dead_scratch() -> void:
	var root := ProjectSettings.globalize_path("user://scratch")
	for name in DirAccess.get_directories_at(root):
		var pid_text := name.get_slice("_", name.get_slice_count("_") - 1)
		if not pid_text.is_valid_int() or DirAccess.dir_exists_absolute("/proc/%s" % pid_text):
			continue
		var abs_dir := root.path_join(name)
		for f in DirAccess.get_files_at(abs_dir):
			var _gone := DirAccess.remove_absolute(abs_dir.path_join(f))
		var _removed := DirAccess.remove_absolute(abs_dir)


## Points the look settings at the tunables the client's sampler reads, and applies them.
func bind_look(tunables: DotFpsTunables) -> void:
	_look = tunables
	_apply_look()


# --- The events a deathmatch has -------------------------------------------


func on_server_clamps(request: Dictionary) -> PackedStringArray:
	return settings.apply_server_clamps(request)
