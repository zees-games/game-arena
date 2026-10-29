extends Node

## The client half of the kill view: plays the clip the server sent when this player died, from behind
## the killer (or the killer's eye and crosshair, `mp_killview_camera` 0), in place of the death camera. Space skips (the server
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

## The final killcam's recorder ([code]arena_killcam.gd[/code]): its frames pose the bodies around the
## kill, since the clip is only the killer's eye. Null leaves the world as it is now.
var stage: Node = null

var _framing: DotKillcamFraming = null
var _kill_at: float = NAN
var _killer: int = 0
var _victim: int = 0
var _posed: Dictionary = {}

var _previous_camera: Camera3D = null
var _hidden: Dictionary = {}
var _cursor: _Cursor = null


func setup(rules: DotKillViewRules) -> void:
	kv = DotKillViewPlayer.new(rules)
	kv.name = "KillView"
	add_child(kv)
	kv.moment.connect(_on_moment)
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
	_killer = int(clip.get("killer", 0))
	_victim = int(info.get("victim_id", 0))
	_kill_at = _kill_time(_killer, _victim)
	_posed = {}
	if _framing != null:
		_framing.reset()
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


## When this client saw [param killer] kill [param victim], on the stage's clock; NAN if it did not.
func _kill_time(killer: int, victim: int) -> float:
	if stage == null or killer == 0:
		return NAN
	var kills: Array[Dictionary] = (stage.get(&"buffer") as DotKillcamBuffer).events_between(-INF, INF, &"kill")
	for i in range(kills.size() - 1, -1, -1):
		var d: Dictionary = kills[i]["data"]
		if int(d.get("killer", 0)) == killer and (victim == 0 or int(d.get("victim", 0)) == victim):
			return float(kills[i]["time"])
	return NAN


func _on_moment(seconds_from_kill: float) -> void:
	_posed = {}
	if stage != null and not is_nan(_kill_at):
		_posed = stage.call(&"pose_at", _kill_at + seconds_from_kill, _killer, _victim)


func _on_view(xform: Transform3D, fov: float, cursor: Vector2, has_cursor: bool) -> void:
	if not camera.current:
		camera.make_current()
	var behind := kv.rules.camera == DotKillViewRules.Camera.BEHIND
	if behind:
		if _framing == null:
			_framing = DotKillcamFraming.new(camera.get_world_3d(), int(stage.get(&"world_mask")) if stage != null else 1)
		var v := _framing.place(DotKillViewRules.Camera.BEHIND, xform, fov, _posed.get("target"), get_process_delta_time())
		xform = v["transform"]
		fov = v["fov"]
	camera.global_transform = xform
	camera.fov = clampf(fov, 20.0, 150.0)
	# The killer's crosshair belongs to the killer's screen, not one behind them.
	_cursor.visible = has_cursor and not behind
	_cursor.at = cursor


func _on_finished(skipped: bool) -> void:
	_cursor.visible = false
	if stage != null:
		stage.call(&"restore_bodies")
	_posed = {}
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
