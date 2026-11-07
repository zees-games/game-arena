extends Node

const ArenaPresentation := preload("../game/arena_presentation.gd")

## How many materials, meshes and (by feature signature) shader variants the weapon part of the
## loading cover's warm-up draws, and how many rounds [ArenaCoverWarm] spreads them over. Headless
## draws nothing, so this counts what a browser would compile on a cold GPU cache; it does not time
## it. Timing needs a real browser: docs/client.md ("A cold GPU cache").
##
## [codeblock]
## godot --headless --path . res://tools/cover_warm_count.tscn
## [/codeblock]
## Prints one `cover_warm_count:` line per figure; `-- --budget N` exits 1 when the signatures exceed N.


func _ready() -> void:
	var _scratch := ArenaPresentation.use_scratch_settings("cover_warm_count")
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	var client: Node = (load("res://game/arena.tscn") as PackedScene).instantiate()
	client.set("force_offline", true)
	add_child(client)
	await get_tree().process_frame
	var out := {}
	# Same lists the client hands the cover: the spawn models' meshes and materials, the prepared view
	# materials, the shot effects' set.
	var items: Array = client.call(&"_weapon_warm_items")
	out["first_items"] = items.size()
	var spare := AwViewModel.new()
	add_child(spare)
	for art: Variant in AwWeaponArtTable.table().values():
		spare.prewarm(art as AwWeaponVisual)
	var view: Array = AwViewModel.prepared_materials()
	var fx: Array = AwShotFx.warm()
	var all: Array = items.duplicate()
	for extra: Array in [view, fx]:
		for item: Variant in extra:
			if item != null and not all.has(item):
				all.append(item)
	var meshes := 0
	var surfaces := 0
	var materials := 0
	var sigs := {}
	var classes := {}
	for item: Variant in all:
		if item is Mesh:
			meshes += 1
			surfaces += (item as Mesh).get_surface_count()
		elif item is Material:
			materials += 1
			var key := ArenaCoverWarm.signature_of(item)
			sigs[key] = int(sigs.get(key, 0)) + 1
			classes[item.get_class()] = int(classes.get(item.get_class(), 0)) + 1
	print("cover_warm_count: items=%d (first spawn %d, view materials %d, shot fx %d)" % [all.size(), items.size(), view.size(), fx.size()])
	print("cover_warm_count: meshes=%d surfaces=%d materials=%d classes=%s" % [meshes, surfaces, materials, classes])
	print("cover_warm_count: distinct material signatures=%d (a lower bound on shader programs; each lighting setup compiles its own)" % sigs.size())
	var rounds := ceili(float(all.size()) / float(ArenaCoverWarm.DEFAULT_BATCH))
	print("cover_warm_count: gate warm-up rounds=%d (one frame draws all); ArenaCoverWarm batch %d rounds=%d (2 frames each)" % [ceili(float(all.size()) / 1000.0), ArenaCoverWarm.DEFAULT_BATCH, rounds])
	var budget := 0
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		if args[i] == "--budget":
			budget = int(args[i + 1])
	get_tree().quit(1 if budget > 0 and sigs.size() > budget else 0)
