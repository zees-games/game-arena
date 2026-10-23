extends Node

## The final killcam. Client side: every frame drawn goes into dot-replay's [DotKillcamBuffer]
## (what the snapshots already brought, no new traffic), every kill is noted, and when the match
## ends on one, [DotKillcam] replays it from the killer's eye before the scoreboard.
## The length is the server's `mp_killcam_time` (RULES `killcam`); 0 skips straight to [signal over].

const CHANNEL := "arena.killcam"

## Skip keys: jump or fire, the keys a player's hands are already on.
const SKIP_ACTIONS: PackedStringArray = ["dot_fps_jump", "arena_fire", "ui_cancel"]

## The killcam is over (or never began); the end-of-match flow goes on from here.
signal over(skipped: bool)

## Every ArenaPlayer to record, this frame.
var players_fn: Callable = Callable()

## ArenaPlayer for a session id, or null.
var player_for_fn: Callable = Callable()

## The killcam's length in seconds; 0 disables.
var seconds_fn: Callable = func() -> float: return 7.0

## Seconds, monotonic. Injected by a test.
var now_fn: Callable = func() -> float: return Time.get_ticks_usec() / 1000000.0

## Shown as-is in the banner: the weapon id's words.
var weapon_name_fn: Callable = func(id: String) -> String: return id.capitalize()

## Nodes hidden while the replay runs (the HUD, the view model): anything with `visible`.
var hide_while_playing: Array = []

var buffer := DotKillcamBuffer.new()
var killcam: DotKillcam = null
var camera: Camera3D = null

var _previous_camera: Camera3D = null
var _touched: Dictionary = {}
var _hidden: Dictionary = {}


func _ready() -> void:
	killcam = DotKillcam.new()
	killcam.name = "Killcam"
	killcam.skip_actions = SKIP_ACTIONS
	add_child(killcam)
	killcam.started.connect(_on_started)
	killcam.frame_drawn.connect(_apply)
	killcam.finished.connect(_on_finished)
	camera = Camera3D.new()
	camera.name = "KillcamCamera"
	add_child(camera)


func is_playing() -> bool:
	return killcam != null and killcam.is_active()


## Records this frame. Called once a frame after every body is presented; while the replay runs
## it re-applies the replayed frame instead, over what presentation just drew.
func frame() -> void:
	if is_playing():
		if killcam.state == DotKillcam.State.WAITING:
			_record()
		return
	_record()


## A kill this client was told about.
func note_kill(killer_id: int, victim_id: int, weapon: String, headshot: bool = false) -> void:
	buffer.note_event(now_fn.call(), &"kill", {
		"killer": killer_id, "victim": victim_id, "weapon": weapon, "headshot": headshot,
	})


## The match ended: replay its last kill if there is one to show. False means [signal over] has
## already been emitted and nothing will play.
func match_ended() -> bool:
	if killcam == null or is_playing():
		return is_playing()
	killcam.max_seconds = maxf(float(seconds_fn.call()), 0.0)
	var kill := buffer.last_event(&"kill")
	var killer_id := int(kill["data"].get("killer", 0)) if not kill.is_empty() else 0
	var killer: Node = _player(killer_id)
	if not killcam.enabled() or killer == null:
		over.emit(false)
		return false
	var victim: Node = _player(int(kill["data"].get("victim", 0)))
	var played := killcam.play(buffer, kill, {
		"killer": String(killer.get(&"display_name")),
		"victim": String(victim.get(&"display_name")) if victim != null else "",
		"weapon": weapon_name_fn.call(String(kill["data"].get("weapon", ""))),
		"hint": "Jump or Fire to skip",
	})
	if not played.ok:
		DotLog.debug(CHANNEL, "no final killcam", {"why": played.error.message})
		over.emit(false)
		return false
	return true


func skip() -> void:
	if killcam != null:
		killcam.skip()


func _player(id: int) -> Node:
	if id == 0 or not player_for_fn.is_valid():
		return null
	var p: Variant = player_for_fn.call(id)
	return p as Node if p is Node and is_instance_valid(p) else null


func _record() -> void:
	if not players_fn.is_valid():
		return
	var shot := {}
	for p: Node in players_fn.call():
		var row := _state_of(p)
		if not row.is_empty():
			shot[int(p.get(&"player_id"))] = row
	var _kept := buffer.push_frame(now_fn.call(), shot)


# [feet, yaw, pitch, alive, eye height]: where the body was drawn, not where the tick put it.
func _state_of(p: Node) -> Array:
	var controller: DotFpsController = p.get(&"controller")
	if controller == null:
		return []
	var st := controller.state
	var eye_h := 1.6
	if controller.motor != null:
		eye_h = controller.motor.eye_position(st).y - st.position.y
	var yaw := st.yaw
	var pitch := st.pitch
	var feet := (p as Node3D).global_position
	var view: Node3D = p.get(&"view")
	var body: Node3D = p.get(&"body_mesh")
	if p.get(&"camera") != null and view != null:
		var look: Variant = p.get(&"view_now")
		if look is Vector2:
			yaw = (look as Vector2).x
			pitch = (look as Vector2).y
		feet = view.global_position - Vector3(0.0, eye_h, 0.0)
	elif body != null and bool(p.get(&"interpolate_body")):
		feet = body.global_position
	return [feet, yaw, pitch, bool(p.call(&"is_alive")), eye_h]


func _on_started(_kill: Dictionary) -> void:
	_previous_camera = get_viewport().get_camera_3d() if is_inside_tree() else null
	if _previous_camera != null and _previous_camera != camera:
		camera.fov = _previous_camera.fov
		camera.cull_mask = _previous_camera.cull_mask
	camera.make_current()
	for n: Variant in hide_while_playing:
		if n is Object and is_instance_valid(n) and (n as Object).get(&"visible") != null:
			_hidden[n] = bool((n as Object).get(&"visible"))
			(n as Object).set(&"visible", false)
	DotLog.info(CHANNEL, "final killcam", killcam.describe())


func _apply(s: Dictionary) -> void:
	var a: Dictionary = s["a"]
	var b: Dictionary = s["b"]
	var alpha: float = s["alpha"]
	var killer_id := int(killcam.kill()["data"].get("killer", 0))
	if not camera.current:
		camera.make_current()
	for id: Variant in b:
		var p := _player(int(id))
		if p == null:
			continue
		var rb: Array = b[id]
		var ra: Array = a.get(id, rb)
		var feet: Vector3 = (ra[0] as Vector3).lerp(rb[0], alpha)
		var yaw := rad_to_deg(lerp_angle(deg_to_rad(ra[1]), deg_to_rad(rb[1]), alpha))
		var pitch := lerpf(ra[2], rb[2], alpha)
		var alive: bool = rb[3] if alpha >= 0.5 else ra[3]
		if int(id) == killer_id:
			camera.global_position = feet + Vector3(0.0, float(rb[4]), 0.0)
			camera.global_rotation = Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0)
			_place_body(p, feet, yaw, false, 0.0, 0.0)
		else:
			var from: Vector3 = ra[0]
			var to: Vector3 = rb[0]
			var speed := from.distance_to(to) * 60.0
			_place_body(p, feet, yaw, alive, pitch, speed)


func _place_body(p: Node, feet: Vector3, yaw: float, shown: bool, pitch: float, speed: float) -> void:
	var body: Node3D = p.get(&"body_mesh")
	if body == null:
		if not shown:
			return
		p.call(&"attach_body_mesh", Color.WHITE, p.get(&"avatar"))
		body = p.get(&"body_mesh")
		if body == null:
			return
	if not _touched.has(p):
		_touched[p] = [body.transform, body.visible]
	body.visible = shown
	if not shown:
		return
	body.global_position = feet
	body.global_basis = Basis(Vector3.UP, deg_to_rad(yaw))
	var figure: Node3D = p.get(&"figure")
	if figure != null:
		figure.set(&"hide_head", false)
		figure.position = Vector3.ZERO
		figure.call(&"set_motion", {"on_floor": true, "alive": true, "aim": deg_to_rad(pitch)})
		figure.call(&"animate", speed, 0.0)


func _on_finished(skipped: bool) -> void:
	for p: Variant in _touched:
		if is_instance_valid(p):
			var body: Node3D = (p as Node).get(&"body_mesh")
			if body != null:
				body.transform = _touched[p][0]
				body.visible = _touched[p][1]
	_touched.clear()
	for n: Variant in _hidden:
		if is_instance_valid(n):
			(n as Object).set(&"visible", _hidden[n])
	_hidden.clear()
	if _previous_camera != null and is_instance_valid(_previous_camera):
		_previous_camera.make_current()
	_previous_camera = null
	over.emit(skipped)


func describe_lines() -> PackedStringArray:
	var out := buffer.describe_lines()
	if killcam != null:
		out.append_array(killcam.describe_lines())
	return out
