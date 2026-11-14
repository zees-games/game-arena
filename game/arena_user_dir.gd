extends RefCounted

## Fatal Contact's user folder. It was Godot's default, named after `config/name` (`godot/app_userdata/game-arena`);
## project.godot now names it itself (`use_custom_user_dir`, `game-fatal-contact`), so it is one predictable folder
## on every platform: `~/.local/share/game-fatal-contact` on Linux, `%APPDATA%\game-fatal-contact` on Windows,
## `~/Library/Application Support/game-fatal-contact` on macOS.
##
## `migrate()` copies the old folder into the new one once (settings, `maps/`, stats, loadouts, profiles), never
## over a file the new folder already has, and leaves the old folder as it was. Engine caches are not copied.
## Nothing happens on the web (`/userfs`) or when another project runs the game (a pack in the shell): the
## setting it checks is this project's alone.

const DIR_NAME := "game-fatal-contact"
const OLD_NAME := "game-arena"
## Written into the new folder once the copy ran (or found nothing to copy), so it runs once per machine.
const MARKER := "user://.migrated_from_game_arena"
## Rebuilt by the engine; the shader cache alone was 80 MB of an 84 MB folder.
const SKIP := ["shader_cache", "vulkan", "logs"]


## True when this process's `user://` is the folder above.
static func is_ours() -> bool:
	return not OS.has_feature("web") \
		and bool(ProjectSettings.get_setting("application/config/use_custom_user_dir", false)) \
		and str(ProjectSettings.get_setting("application/config/custom_user_dir_name", "")) == DIR_NAME


## The folder Godot gave the game while `config/name` was "game-arena".
static func old_dir() -> String:
	var godot := "godot" if OS.get_name() in ["Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD"] else "Godot"
	return OS.get_data_dir().path_join(godot).path_join("app_userdata").path_join(OLD_NAME)


## Copies the old folder in on the first run under the new one. Returns the number of files copied, -1 when
## there was nothing to do (already done, not this project's folder, or no old folder).
static func migrate() -> int:
	if not is_ours() or FileAccess.file_exists(MARKER):
		return -1
	var from := old_dir()
	var to := OS.get_user_data_dir()
	var copied := -1
	if DirAccess.dir_exists_absolute(from) and from.simplify_path() != to.simplify_path():
		copied = copy_tree(from, to)
		print("Fatal Contact: copied %d files from %s into %s (the old folder is kept)" % [copied, from, to])
	var f := FileAccess.open(MARKER, FileAccess.WRITE)
	if f != null:
		f.store_string("%s\n%d\n" % [from, copied])
	return copied


## Copies `from` into `to` file by file, skipping `SKIP` at the top, links, and any file `to` already has.
static func copy_tree(from: String, to: String, top: bool = true) -> int:
	var dir := DirAccess.open(from)
	if dir == null:
		return 0
	dir.include_hidden = true
	DirAccess.make_dir_recursive_absolute(to)
	var count := 0
	for n in dir.get_files():
		var src := from.path_join(n)
		var dst := to.path_join(n)
		if dir.is_link(n) or FileAccess.file_exists(dst):
			continue
		if DirAccess.copy_absolute(src, dst) == OK:
			count += 1
		else:
			push_warning("Fatal Contact: could not copy %s into the new user folder" % src)
	for d in dir.get_directories():
		if (top and SKIP.has(d)) or dir.is_link(d):
			continue
		count += copy_tree(from.path_join(d), to.path_join(d), false)
	return count
