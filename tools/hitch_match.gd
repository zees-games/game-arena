extends Node

const ArenaPresentation := preload("../game/arena_presentation.gd")
const ClientBench := preload("client_bench.gd")

## A whole solo match on the real client with bots, every frame over a threshold logged with
## what changed in it (dot-core's DotHitchLog): respawns, the kill-cam, the match summary.
## Window it on a GPU, because software GL makes every frame a hitch:
##
## [codeblock]
## ./gpu.sh run game-arena res://tools/hitch_match.tscn -- --bots 3 --score 6 --seconds 150
## [/codeblock]
##
## `--score N` / `--time S` (default 6 kills, 45 s) end the match so MATCH_END and the kill-cam are reached;
## `--threshold MS` (default 33); `--tail S` seconds kept after the end (default 8);
## `--no-pilot` leaves the local player still; `--boom S` (default 10) calls the presentation's explosion 6 m ahead of the camera S seconds in, marked "explosion" in the report (-1 skips it).

var _bots := 3
var _score := 6
var _seconds := 150.0
var _threshold := 33.0
var _tail := 8.0
var _time := 45.0
var _pilot := true
var _boom := 10.0
var _boomed := false
var _hitch := DotHitchLog.new()
var _client: Node = null
var _state := -2
var _cam := false
var _t0 := 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--bots": _bots = int(args[i + 1])
			"--score": _score = int(args[i + 1])
			"--seconds": _seconds = float(args[i + 1])
			"--threshold": _threshold = float(args[i + 1])
			"--time": _time = float(args[i + 1])
			"--tail": _tail = float(args[i + 1])
			"--boom": _boom = float(args[i + 1])
	_pilot = not "--no-pilot" in args
	var _scratch := ArenaPresentation.use_scratch_settings("hitch_match")
	_run.call_deferred()


func _run() -> void:
	_hitch.threshold_ms = _threshold
	_hitch.start(get_tree())
	_t0 = Time.get_ticks_usec()
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("mouse_capture_override", true)
	_client.set("offline_bots", _bots)
	add_child(_client)
	var _c := get_tree().process_frame.connect(_watch)
	var g = _client.get("game")
	if g != null and g.match_node != null and g.match_node.rules != null:
		g.match_node.rules.score_limit = _score
		g.match_node.rules.time_limit_sec = _time
	var pilot_added := false
	var ended_at := -1.0
	while true:
		await get_tree().process_frame
		var t := (Time.get_ticks_usec() - _t0) / 1.0e6
		g = _client.get("game")
		if _pilot and not pilot_added and _client.get("player") != null:
			pilot_added = true
			var pilot := ClientBench.Pilot.new()
			pilot.process_priority = -999
			add_child(pilot)
		if _boom >= 0.0 and not _boomed and t >= _boom:
			_boom_now()
		if g != null and g.match_node != null:
			if g.match_node.rules != null and g.match_node.rules.time_limit_sec != _time:
				g.match_node.rules.score_limit = _score
				g.match_node.rules.time_limit_sec = _time
			if g.match_node.state == DotMatch.State.MATCH_END and ended_at < 0.0:
				ended_at = t
		if (ended_at >= 0.0 and t > ended_at + _tail) or t > _seconds:
			break
	print("hitch_match: %s after %.1f s" % ["match ended" if ended_at >= 0.0 else "NO MATCH END", (Time.get_ticks_usec() - _t0) / 1.0e6])
	for line in _hitch.report(25):
		print(line)
	_hitch.stop()
	get_tree().quit(0)


## Labels the frame a match phase or the kill-cam changes in, and prints it with the time.
func _watch() -> void:
	var g = _client.get("game")
	if g == null or g.match_node == null:
		return
	var st := int(g.match_node.state)
	var t := (Time.get_ticks_usec() - _t0) / 1.0e6
	if st != _state:
		_state = st
		_hitch.mark("match state %d round %d" % [st, int(g.match_node.round_number)])
		print("EVENT t=%.1fs match state %d round %d" % [t, st, int(g.match_node.round_number)])
	var kc = _client.get("killcam")
	var playing: bool = kc != null and kc.is_playing()
	if playing != _cam:
		_cam = playing
		_hitch.mark("killcam %s" % ("start" if playing else "end"))
		print("EVENT t=%.1fs killcam %s" % [t, "start" if playing else "end"])


## One explosion through the presentation, the way a rocket's hit draws it, to see what its first draw costs.
func _boom_now() -> void:
	var pres = _client.get("presentation")
	var body = _client.get("player")
	if pres == null or body == null or body.camera == null:
		return
	_boomed = true
	var cam: Transform3D = body.camera.global_transform
	var at: Vector3 = cam.origin - cam.basis.z * 6.0
	_hitch.mark("explosion")
	print("EVENT t=%.1fs explosion" % [(Time.get_ticks_usec() - _t0) / 1.0e6])
	pres.on_explosion(at, cam.origin)
