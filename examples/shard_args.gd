## What a sharded suite reads from its command line (`game.sh test NAME.SHARD` runs `-- --shard SHARD`, and
## `test NAME.merge` runs `-- --merge LOG...`), and the merge's one check over the shards' logs.
## Each shard is a whole run of its own part (it fails on its own); the merge only holds that nothing went missing.
extends RefCounted


## The shard this run plays, "" for the whole suite.
static func shard() -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--shard")
	return args[at + 1] if at >= 0 and at + 1 < args.size() else ""


## The logs a merge run is given, empty when this is not a merge.
static func merge_logs() -> PackedStringArray:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--merge")
	return PackedStringArray(args.slice(at + 1)) if at >= 0 else PackedStringArray()


static func is_merge() -> bool:
	return OS.get_cmdline_user_args().has("--merge")


## Logs that are not on disk.
static func missing(logs: PackedStringArray) -> Array:
	return Array(logs).filter(func(path: String) -> bool: return not FileAccess.file_exists(path))


## The sum of "N sections entered" over the logs: the merge holds it against the whole suite's declared count.
static func sections_entered(logs: PackedStringArray) -> int:
	var total := 0
	var rx := RegEx.create_from_string("(?m)^(\\d+) sections entered")
	for path in logs:
		var m := rx.search(FileAccess.get_file_as_string(path))
		if m != null:
			total += int(m.get_string(1))
	return total
