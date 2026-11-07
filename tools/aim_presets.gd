extends SceneTree

## Prints the bot presets that the recorded fights of real players suggest, for a person to review; it changes nothing.
## `godot --headless --path . --script res://tools/aim_presets.gd -- <store dir> [<map id> <map version> [min episodes]]`
## With only the store dir it lists the map versions the store holds.

const USAGE := "usage: aim_presets.gd -- <store dir> [<map id> <map version> [min episodes]]"


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty() or args.size() == 2:
		print(USAGE)
		quit(2)
		return
	if args.size() == 1:
		var dir := DirAccess.open(args[0])
		if dir == null:
			print("no store at %s" % args[0])
			quit(1)
			return
		for sub in dir.get_directories():
			print(sub)
		quit(0)
		return
	var store := DotBotDemoStoreJson.new(args[0])
	var stats_script: GDScript = load("res://game/arena_demo_stats.gd")
	var lines: PackedStringArray = await stats_script.call("preset_lines", store, args[1], args[2], int(args[3]) if args.size() > 3 else 0)
	for line in lines:
		print(line)
	quit(0)
