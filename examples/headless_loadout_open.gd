extends Node

const ArenaPresentation := preload("../game/arena_presentation.gd")

## Pressing B costs no allocation worth a hitch. The owner's web build stalled hard on the first B: the loadout
## menu asked AwWeaponPreview for the picture of each of 27 weapons, which made 27 MSAA viewports (543 nodes, 144 MB of
## render targets) in that one press. The load cover now has the previews render through one shared viewport, so:
##   - the first open after the prewarm makes no viewport and no preview,
##   - the second and later opens create no viewport, no preview and no node at all (dot-menu's screen draws nothing
##     over the state it already drew).
## Run: [code]godot --headless --path . res://examples/headless_loadout_open.tscn[/code]
## (Headless draws nothing to read back, so the prewarm makes each id's own viewport a frame at a time there; the checks
## are the same. `tools/loadout_open_cost.tscn` on a display measures the milliseconds.)

const OPENS := 4

var _checks := 0
var _failed := 0
var _client: Node = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	var _scratch := ArenaPresentation.use_scratch_settings("headless_loadout_open")
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("mouse_capture_override", true)
	add_child(_client)
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	if not condition or OS.get_environment("VERBOSE") != "":
		print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return bool(condition.call())


func _viewports(n: Node) -> int:
	var c := 1 if n is SubViewport else 0
	for k in n.get_children():
		c += _viewports(k)
	return c


## The ids the menu offers that have a model to draw.
func _art_ids() -> Array:
	var out: Array = []
	for id: Variant in AwWeaponArtTable.table().keys():
		var art := AwWeaponArtTable.get_art(StringName(id))
		if art != null and art.model_path != "":
			out.append(StringName(id))
	return out


func _run() -> void:
	print("game-arena: B costs no allocation after the prewarm")
	if not await _until(func() -> bool: return _client.get("player") != null and _client.get("loadout_menu") != null, 30.0):
		_check(false, "the offline client has its player and loadout menu")
		get_tree().quit(1)
		return
	if not await _until(func() -> bool: return bool(_client.call(&"is_ready_to_show")), 60.0):
		_check(false, "the loading cover lifts")
		get_tree().quit(1)
		return
	var menu: Object = _client.get("loadout_menu")
	var gm: DotMenu = _client.get("game_menu")
	var previews: AwWeaponPreview = _client.call(&"weapon_previews")
	var ids := _art_ids()
	_check(ids.size() >= 20, "the arsenal has weapons with art to draw", str(ids.size()))

	# What the load cover does: every picture, one viewport, a frame each.
	var ports0 := previews.ports_made()
	previews.warm()
	_check(previews.is_warming(), "the warm-up is spread over frames, not done in the call")
	var done := [false]
	var _c := previews.warmed.connect(func() -> void: done[0] = true)
	_check(await _until(func() -> bool: return done[0], 120.0), "the warm-up finishes")
	await _frames(2)
	_check(not previews.is_warming(), "and is no longer ticking")
	_check(previews.cached_count() >= ids.size(), "every weapon with art has its picture cached", "%d of %d" % [previews.cached_count(), ids.size()])
	# Headless has no pixels to read back, so it falls back to a viewport per id; a display uses one for all.
	var ports_for_warm := previews.ports_made() - ports0
	_check(ports_for_warm <= (ids.size() if DisplayServer.get_name() == "headless" else 1), "the warm-up made %d viewports" % ports_for_warm)
	print("  warm-up made %d viewports for %d weapons" % [ports_for_warm, ids.size()])

	# And the screen drawn hidden on the offer, as the cover's last step.
	if menu.has_method(&"prepare"):
		await menu.call(&"prepare")
	var views_before := _viewports(get_tree().root)
	var ports_before := previews.ports_made()
	var first_added := [0]
	var count_first := func(_node: Node) -> void: first_added[0] += 1
	get_tree().node_added.connect(count_first)
	await menu.call(&"open")
	await _frames(2)
	get_tree().node_added.disconnect(count_first)
	var screen: DotMenuLoadoutScreen = gm.loadout_screen
	_check(screen != null and screen.is_open(), "B opens the loadout screen")
	_check(previews.ports_made() == ports_before, "the first open renders no weapon", "%d new" % (previews.ports_made() - ports_before))
	_check(_viewports(get_tree().root) == views_before, "the first open makes no viewport", "%d -> %d" % [views_before, _viewports(get_tree().root)])
	_check(first_added[0] == 0 or not menu.has_method(&"prepare"), "the first open puts no node into the tree", "%d entered" % first_added[0])
	screen.close()
	await _frames(3)

	# Every slot's pictures too: a click on another tab renders nothing either.
	var slot_count := screen.slots().size()
	for s in slot_count:
		screen.show_slot(s)
	_check(previews.ports_made() == ports_before and _viewports(get_tree().root) == views_before, "paging every slot (%d) renders nothing" % slot_count)
	screen.show_slot(0)

	# Second and later opens: the same nodes, nothing new.
	var settled_nodes := -1
	for n in OPENS:
		var added := [0]
		var count := func(_node: Node) -> void: added[0] += 1
		get_tree().node_added.connect(count)
		await menu.call(&"open")
		await _frames(3)
		get_tree().node_added.disconnect(count)
		var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		_check(previews.ports_made() == ports_before, "open %d makes no preview viewport" % (n + 2))
		_check(_viewports(get_tree().root) == views_before, "open %d makes no viewport" % (n + 2))
		if settled_nodes >= 0:
			_check(nodes == settled_nodes, "open %d leaves the node count where it was" % (n + 2), "%d -> %d" % [settled_nodes, nodes])
		settled_nodes = nodes
		_check(added[0] == 0, "open %d puts no node into the tree" % (n + 2), "%d entered" % added[0])
		print("  open %d: %d nodes entered the tree, tree holds %d" % [n + 2, added[0], nodes])
		screen.close()
		await _frames(3)
	print("headless_loadout_open: %d checks, %d failed" % [_checks, _failed])
	get_tree().quit(1 if _failed > 0 else 0)
