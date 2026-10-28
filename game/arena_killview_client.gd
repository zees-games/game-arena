extends Node

## The client half of the kill view: plays the clip the server sent when this player died, from the
## killer's eye with the killer's crosshair, in place of the death camera. Space skips (the server
## then respawns the victim at once); the end hands the screen back to the normal flow.

const CHANNEL := "arena.killview.client"

## The replay is over; [param skipped] when the victim cut it short.
signal over(skipped: bool)

## The victim skipped: ask the server to respawn.
signal respawn_requested

var kv: DotKillViewPlayer = null
var camera: Camera3D = null

## Called when a replay starts: the nodes to hide while it runs (the HUD, the view model).
var hide_fn: Callable = Callable()

var _previous_camera: Camera3D = null
var _hidden: Dictionary = {}
var _cursor: _Cursor = null


func setup(rules: DotKillViewRules) -> void:
	kv = DotKillViewPlayer.new(rules)
	kv.name = "KillView"
	add_child(kv)
	kv.view.connect(_on_view)
	kv.finished.connect(_on_finished)
	kv.respawn_requested.connect(func() -> void: respawn_requested.emit())
	camera = Camera3D.new()
	camera.name = "KillViewCamera"
	add_child(camera)
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	_cursor = _Cursor.new()
	_cursor.set_anchors_preset(Control.PRESET_FULL_RECT)
	_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor.visible = false
	layer.add_child(_cursor)


func is_active() -> bool:
	return kv != null and kv.is_active()


## Starts the replay of a clip from the server. False when it did not start (off, running, bad clip).
func play(clip: Dictionary, info: Dictionary) -> bool:
	if kv == null:
		return false
	# Before play_clip: the first frame can already put the replay camera current.
	var before := get_viewport().get_camera_3d()
	var res := kv.play_clip(clip, info)
	if not res.ok:
		DotLog.debug(CHANNEL, "no kill view", {"why": res.error.message})
		return false
	_previous_camera = before if before != camera else null
	if _previous_camera != null:
		camera.cull_mask = _previous_camera.cull_mask
	camera.make_current()
	if hide_fn.is_valid():
		for n: Variant in hide_fn.call():
			if n is Object and is_instance_valid(n) and (n as Object).get(&"visible") != null:
				_hidden[n] = bool((n as Object).get(&"visible"))
				(n as Object).set(&"visible", false)
	return true


func _on_view(xform: Transform3D, fov: float, cursor: Vector2, has_cursor: bool) -> void:
	if not camera.current:
		camera.make_current()
	camera.global_transform = xform
	camera.fov = clampf(fov, 20.0, 150.0)
	_cursor.visible = has_cursor
	_cursor.at = cursor


func _on_finished(skipped: bool) -> void:
	_cursor.visible = false
	for n: Variant in _hidden:
		if is_instance_valid(n):
			(n as Object).set(&"visible", _hidden[n])
	_hidden.clear()
	if _previous_camera != null and is_instance_valid(_previous_camera):
		_previous_camera.make_current()
	_previous_camera = null
	over.emit(skipped)


## The killer's crosshair: four ticks round a gap, at the recorded point of the screen.
class _Cursor extends Control:
	var at := Vector2(0.5, 0.5):
		set(v):
			at = v
			queue_redraw()

	func _draw() -> void:
		var c := Vector2(size.x * at.x, size.y * at.y)
		var col := Color(1.0, 0.25, 0.2)
		for d: Vector2 in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
			draw_line(c + d * 4.0, c + d * 11.0, col, 2.0)
