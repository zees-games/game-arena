extends DotGameCheckSuite
## A scoped weapon's see-through scope lens is a SubViewport and a second camera: headless (a server, a test run)
## none may exist, for any scoped weapon, whether held, aimed or lowered.
##   godot --headless --path . res://examples/headless_scopepip.tscn

const ArenaPresentation := preload("../game/arena_presentation.gd")
const SCOPED: Array[StringName] = [&"marksman", &"sniper", &"charge_rifle"]

var _client: Node = null
var _scratch_dir := ""


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_scratch_dir = ArenaPresentation.use_scratch_settings("headless_scopepip")
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("mouse_capture_override", true)
	add_child(_client)
	_run.call_deferred()


func _run() -> void:
	print("game-arena: no scope picture-in-picture is built headless")
	if not await _until(func() -> bool: return _client.get("player") != null and bool(_client.call(&"is_ready_to_show")), 90.0):
		_check(false, "the offline client is ready")
		_report_sections(0, 0, 1)
		return
	_check(DisplayServer.get_name() == "headless", "this run is headless")
	var me = _client.get("player")
	me.health.invulnerable = true
	var held := 0
	for id: StringName in SCOPED:
		var _given = me.arsenal.give(id)
		me.arsenal.equip(me.arsenal.catalogue.get_def(id).slot)
		if not await _until(func() -> bool: return me.arsenal.current() != null and me.arsenal.current().def.id == id, 3.0):
			continue
		held += 1
		await _seconds(0.6)
		_check(_client.find_children("*", "AwScopePip", true, false).is_empty(), "%s: no scope lens node" % id)
		_check(_lens_viewports() == 0, "%s: no SubViewport at the hip" % id)
		Input.action_press(&"arena_aim")
		await _seconds(0.5)
		_check(_lens_viewports() == 0, "%s: no SubViewport while aiming" % id)
		Input.action_release(&"arena_aim")
		await _seconds(0.3)
	_check(held == SCOPED.size(), "all %d scoped weapons were held (%d)" % [SCOPED.size(), held])
	var abs_dir := ProjectSettings.globalize_path(_scratch_dir)
	for f in DirAccess.get_files_at(abs_dir):
		var _gone := DirAccess.remove_absolute(abs_dir.path_join(f))
	var _removed := DirAccess.remove_absolute(abs_dir)
	_report_sections(SCOPED.size(), held, SCOPED.size())


func _seconds(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return bool(condition.call())


## SubViewports under any view model other than the pre-existing hands overlay.
func _lens_viewports() -> int:
	var n := 0
	for vm in _client.find_children("*", "AwViewModel", true, false):
		for sv in vm.find_children("*", "SubViewport", true, false):
			if sv.get_parent().name != &"ViewOverlay":  # the hands overlay is an older, unrelated viewport
				n += 1
	return n
