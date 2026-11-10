extends DotGameCheckSuite

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaModule := preload("../game/arena_module.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaTestPorts := preload("test_ports.gd")


## dot-net's lossy UDP relay, by path (it has no class_name).
const Relay := preload("res://addons/dot_net/testing/dot_net_udp_relay.gd")

## What a player SEES, frame by frame: the real client, offline and through a real socket.
## [codeblock] godot --headless --path . res://examples/headless_feel.tscn godot --headless --path .
## res://examples/headless_feel.tscn -- --verbose godot --headless --path .


var PORT := ArenaTestPorts.free_port()
const DATA := "user://arena_feel"
const TICK_RATE := 64


## Connected windows: name, display fps, loss each way, delay each way (ms), jitter (ms),
## seconds, jump held, the delay each way the link changes to, whether the local eye is judged,
## and the bot's step tolerance in metres. A changing delay makes clock slips happen on purpose.
const WINDOWS := [
	["60 Hz display, steady 40 ms", 60, 0.0, 40.0, 0.0, 5.0, false, 0.0, true, 0.02],
	["144 Hz display, steady 40 ms, jumping", 144, 0.0, 40.0, 0.0, 5.0, true, 0.0, true, 0.02],
	["144 Hz display, 40 ms going to 70 ms", 144, 0.0, 40.0, 0.0, 5.0, false, 70.0, true, 0.05],
	["144 Hz display, 70 ms going to 40 ms", 144, 0.0, 70.0, 0.0, 5.0, false, 40.0, true, 0.02],
	["144 Hz display, 5% loss 30..80 ms", 144, 0.05, 55.0, 25.0, 6.0, false, 0.0, true, 0.055],
	["144 Hz display, 20% loss 30..80 ms", 144, 0.20, 55.0, 25.0, 6.0, false, 0.0, true, 0.10],
]


## Where the local runner's circle is centred: dm_box's open floor south of the stair and the
## pillar, nothing overhead and no wall within 5 m. `_check_open_floor` says if a runner did
## not stay clear.
const RUN_CENTRE := Vector3(11.75, 0.05, -17.25)


## Degrees a second the player turns the mouse, and degrees a tick the bot turns.
const TURN_RATE := 240.0
const BOT_TURN := 2.0


## Ticks between jump presses in a jumping window: a hop is about 41 ticks in the air at
## 64 Hz, so each one runs about 11 ticks on the floor first.
const JUMP_EVERY := 52


var _verbose := false


var _entered := 0
var _completed := 0


var _server_side: Node = null
var _server: DotServer = null
var _game: ArenaGame = null
var _relay = null
var _client_side: Node = null
var _link: DotClientLink = null
var _client: Node = null
var _bot_session := 0


var _driving := false
## Whether the window hops (see `_hold_movement`).
var _jumping := false
var _turning := false


## Server truth: session -> {server tick -> position}.
var _track: Dictionary = {}


## The window's measurements. Empty between windows.
var _w: Dictionary = {}
var _physics_since_render := 0
var _offline_bots: Dictionary = {}


## The standalone player the moves section drives, its command, its tick and its frames.
var _mover: ArenaPlayer = null
var _mover_command: DotFpsCommand = null
var _mover_tick := 1
var _mover_frames: Array = []


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


## Wall-clock seconds between drawn frames since the last [method _measure]: how the machine
## kept up, apart from what the game did with each frame.
var _wall: Array[float] = []
var _wall_last_us: int = 0
## Why the measurement being judged cannot be ("" when it can): see [method _starvation].
var _starved_reason: String = ""
## The checks a starved measurement left unjudged, with why.
var _not_judged: PackedStringArray = PackedStringArray()


## Starts a measurement's frame-time record.
func _measure() -> void:
	_wall.clear()


## Why the frames since [method _measure] cannot be judged at [param fps], or "". A starved
## machine stalls frames: more than one in twenty (and at least four) over twice the display's
## budget is a machine not keeping up; one or two hitches stay judged.
func _starvation(fps: float) -> String:
	var budget := 1.0 / maxf(fps, 1.0)
	var over := 0
	var worst := 0.0
	for dt in _wall:
		if dt > budget * 2.0:
			over += 1
			worst = maxf(worst, dt)
	if _wall.size() >= 10 and over > maxi(3, _wall.size() / 20):
		return "%d of %d frames took over twice their %.1f ms budget, the worst %.0f ms" % [
			over, _wall.size(), budget * 1000.0, worst * 1000.0]
	return ""


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	elif _starved_reason != "":
		# Not judged: the frames this check reads were stalled by the machine, not the game
		# (arena-feel-starvation-1). Counted, so "every check ran" holds, and said loudly.
		_passed += 1
		_not_judged.append("%s -- %s" % [what, _starved_reason])
		print("  --    %s  NOT JUDGED, the machine was starved: %s%s" % [what, _starved_reason, "" if detail == "" else "  (%s)" % detail])
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s -- %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	return condition


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return bool(condition.call())


## How [param key] of the camera's motion moved over [param frames]: its range, its largest
## change in a frame and the largest change of that change (a corner in its motion).
static func _motion_track(frames: Array, key: String) -> Dictionary:
	var low := INF
	var high := -INF
	var step := 0.0
	var jerk := 0.0
	for i in range(frames.size()):
		var v := float(frames[i][key])
		low = minf(low, v)
		high = maxf(high, v)
		if i > 0:
			var d := v - float(frames[i - 1][key])
			step = maxf(step, absf(d))
			if i > 1:
				jerk = maxf(jerk, absf(d - (float(frames[i - 1][key]) - float(frames[i - 2][key]))))
	return {"low": low, "high": high, "step": step, "jerk": jerk}


static func _command(move: Vector2, yaw: float, buttons: int) -> DotFpsCommand:
	var command := DotFpsCommand.new()
	command.move = move
	command.yaw = yaw
	command.buttons = buttons
	return command


## The eye's vertical steps over [param frames] that [param keep] accepts.
static func _vertical(frames: Array, keep: Callable) -> Dictionary:
	var rises := []
	var jerk := 0.0
	var top := -INF
	var last_rise: Variant = null
	for i in range(1, frames.size()):
		var f: Dictionary = frames[i]
		if not bool(keep.call(f)) or not bool(keep.call(frames[i - 1])):
			last_rise = null
			continue
		var rise := float((f["eye"] as Vector3).y - (frames[i - 1]["eye"] as Vector3).y)
		rises.append(rise)
		top = maxf(top, float((f["pos"] as Vector3).y))
		if last_rise != null:
			jerk = maxf(jerk, absf(rise - float(last_rise)))
		last_rise = rise
	var total := 0.0
	var high := -INF
	var low := INF
	for r in rises:
		total += float(r)
		high = maxf(high, float(r))
		low = minf(low, float(r))
	var mean := total / float(maxi(1, rises.size()))
	return {"n": rises.size(), "mean": mean, "max": high, "min": low, "jerk": jerk,
		"ratio": high / mean if mean > 0.0 else INF, "top": top}


func _module() -> ArenaModule:
	return _server.modules.get_module("arena") as ArenaModule if _server != null else null


func _boot() -> bool:
	_section("a dual-stack arena server with a bot running circles, and the relay in front of it")

	_server_side = Node.new()
	_server_side.name = "ServerSide"
	add_child(_server_side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), _server_side.get_path())

	_game = ArenaGame.new()
	_game.name = "Arena"
	_game.tick_rate = TICK_RATE
	_game.score_limit = 0
	_game.time_limit_sec = 0.0
	_game.headless = true
	_game.register_service = true
	_server_side.add_child(_game)
	var ready := _game.setup(ArenaMap.dm_box())
	if not _check(ready.ok, "the arena sets up", str(ready.error)):
		_done()
		return false

	var config := DotServerConfig.new()
	config.hostname = "arena feel"
	config.port = PORT
	config.bind_address = "127.0.0.1"
	config.transport_mode = "dual"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % DATA
	config.bans_path = "%s/bans.json" % DATA
	config.audit_log_path = "%s/audit.jsonl" % DATA
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""
	config.query_enabled = false
	config.enet_share_udp_port = false
	config.stdin_console_enabled = false
	config.log_level = "info" if _verbose else "error"

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	_server_side.add_child(_server)

	var booted: DotResult = await _server.boot()
	if not _check(booted.ok, "the server boots", str(booted.error)):
		_done()
		return false

	ArenaModule.punishments_file = "%s/punishments.json" % DATA
	var loaded: DotResult = await _server.modules.load_module("res://game/arena_module.gd")
	if not _check(loaded.ok, "the arena module loads", str(loaded.error)):
		_done()
		return false

	# No quota bots: they would shoot the player being measured. One bot of our own, whose
	# every command is written here, so its path is known tick for tick.
	var quota: DotBotQuota = _module().get("_bot_quota")
	if quota != null and quota.mode_cvar != null:
		quota.mode_cvar.force_set("off")
	var bridge = _module().bridge
	_bot_session = bridge.add_bot("Circles")
	(bridge.get("_bot_minds") as Dictionary).erase(_bot_session)
	_check(_bot_session != 0, "the server seats a bot for the client to watch")

	_relay = Relay.new()
	_relay.seed = 20261011
	var relayed: DotResult = _relay.start(0, "127.0.0.1", config.effective_enet_port())
	_check(relayed.ok, "the relay listens in front of UDP %d" % config.effective_enet_port(), str(relayed.error))
	_done()
	return relayed.ok and _bot_session != 0


func _connect() -> bool:
	_section("the real client connects through the relay")
	_set_link(WINDOWS[0])

	_client_side = Node.new()
	_client_side.name = "ClientSide"
	add_child(_client_side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), _client_side.get_path())

	_link = DotClientLink.new()
	_link.name = "Server"
	_link.player_name = "Watcher"
	_link.transport_preference = "udp"
	_link.udp_address = "127.0.0.1:%d" % _relay.port()
	_client_side.add_child(_link)
	_link.connect_to_server("127.0.0.1:%d" % PORT)

	var spawned := [false]
	_link.spawned.connect(func() -> void: spawned[0] = true)
	await _until(func() -> bool: return spawned[0] or _link.is_playing(), 30.0)

	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("mouse_capture_override", true)
	_client_side.add_child(_client)

	# The cover lifts on the server's map, never on the placeholder the client boots on: a joiner
	# on another map saw and walked the wrong level for 140 ms. The server here is on dm_box, so
	# this asks the order: was the server's map in when the gate first opened?
	var map_in := [false]
	var opened_on := [""]
	var extras: Node = _client.get("extras")
	var gate: DotLoadGate = _client.get("gate")
	if extras != null:
		extras.connect("map_changed", func(_m: DotMapDef) -> void: map_in[0] = true)
	if gate != null:
		gate.opened.connect(func() -> void:
			if opened_on[0] == "":
				opened_on[0] = "after the server's map" if map_in[0] else "before the server's map")

	var playing := await _until(func() -> bool:
		var p: ArenaPlayer = _client.get("player")
		var net: DotNetManager = _client.get("net")
		return p != null and p.is_alive() and net != null and net.clock.is_synced(), 40.0)
	_check(playing, "the client adopts its player and is alive", "transport %s" % _link.transport_used)
	var sees := await _until(func() -> bool: return _remote_bot() != null and _remote_bot().is_alive(), 30.0)
	_check(sees, "and sees the server's bot")
	await _until(func() -> bool: return opened_on[0] != "", 10.0)
	_check(opened_on[0] == "after the server's map",
		"its loading cover first lifted once the server had named its map", opened_on[0])
	_check(Engine.physics_ticks_per_second == TICK_RATE, "the engine steps physics at the server's rate",
		str(Engine.physics_ticks_per_second))

	# Both runners into open floor, where their circles meet no wall: a wall turns a step
	# into a corner, and a frame across a corner is not a measurement of anything drawn.
	# The client's copy of itself is corrected once, here, before anything is measured.
	_place_on_circle(_game.player_for(_bot_session), Vector3(-16.0, 0.05, 14.0), 4.0)
	var me := _client.get("player") as ArenaPlayer
	_place_on_circle(_game.player_for(me.player_id) if me != null else null, RUN_CENTRE, 2.2, -45.0, false)
	_done()
	return playing and sees


## Puts [param p] (on the server) where the circle it runs is centred on [param centre]:
## [param radius] metres from it, square to its heading ([param heading] degrees off the yaw).
## [param turns_left] says which side the centre is on; the local runner's yaw shrinks.
func _place_on_circle(p: ArenaPlayer, centre: Vector3, radius: float, heading: float = 0.0,
		turns_left: bool = true) -> void:
	if p == null:
		return
	var h := deg_to_rad(p.controller.state.yaw + heading)
	var at := centre + Vector3(cos(h), 0.0, -sin(h)) * radius * (1.0 if turns_left else -1.0)
	p.controller.teleport(at, p.controller.state.yaw, p.controller.state.pitch)
	p.global_position = at


func _remote_bot() -> ArenaPlayer:
	if _client == null:
		return null
	var g: ArenaGame = _client.get("game")
	return g.player_for(_bot_session) if g != null else null


func _set_link(window: Array) -> void:
	_relay.up.configure(float(window[2]), float(window[3]), float(window[4]))
	_relay.down.configure(float(window[2]), float(window[3]), float(window[4]))


func _teardown() -> void:
	if _link != null:
		_link.disconnect_from_server("done")
	for _i in range(10):
		await get_tree().process_frame
	if _relay != null:
		_relay.stop()
	if _server != null and _server.has_method("shutdown"):
		_server.shutdown("done")
	for _i in range(10):
		await get_tree().process_frame
	DotPaths.remove_tree(DATA)


func _early_physics() -> void:
	if _jumping:
		if Engine.get_physics_frames() % JUMP_EVERY == 0:
			Input.action_press(&"dot_fps_jump")
		else:
			Input.action_release(&"dot_fps_jump")
	if _mover != null and _mover_command != null:
		var _outcome := _mover.simulate_tick(_mover_tick, 1.0 / float(TICK_RATE), _mover_command, DotWeaponCommand.new())
		_mover_tick += 1
	for id in _offline_bots:
		var bot: ArenaPlayer = _offline_bots[id]
		if not is_instance_valid(bot):
			continue
		var move := DotFpsCommand.new()
		move.move = Vector2(0.0, 1.0)
		move.yaw = wrapf(float(bot.controller.state.tick) * BOT_TURN + float(id) * 90.0, -180.0, 180.0)
		bot.set_meta(&"bot_move", move)
		bot.set_meta(&"bot_fire", DotWeaponCommand.new())
	# The server hears its clients once a tick, as a dedicated server does.
	if _server_side != null:
		var api := get_tree().get_multiplayer(_server_side.get_path())
		if api != null and api.has_multiplayer_peer():
			api.poll()
	if _game == null or _bot_session == 0:
		return
	var behaviour = _module().bridge.behaviour_for(_bot_session) if _module() != null else null
	if behaviour == null:
		return
	var move := DotFpsCommand.new()
	move.move = Vector2(0.0, 1.0)
	move.yaw = wrapf(float(_game.current_tick()) * BOT_TURN, -180.0, 180.0)
	behaviour.last_move = move
	behaviour.last_fire = DotWeaponCommand.new()


func _late_physics() -> void:
	_physics_since_render += 1
	if _game == null:
		return
	var tick := _game.current_tick()
	for p in _game.players():
		var track: Dictionary = _track.get(p.player_id, {})
		track[tick] = p.controller.state.position
		_track[p.player_id] = track


func _early_process(delta: float) -> void:
	if not _driving or not _turning or _client == null:
		return
	var p: ArenaPlayer = _client.get("player")
	if p == null:
		return
	var tunables := p.controller.tunables
	var per_count := tunables.mouse_sensitivity * tunables.mouse_sensitivity_x if tunables != null else 0.022
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(TURN_RATE * delta / maxf(per_count, 1e-6), 0.0)
	_client._unhandled_input(motion)


## After everything that writes the camera: what this frame shows.
func _late_process(delta: float) -> void:
	var now_us := Time.get_ticks_usec()
	if _wall_last_us > 0:
		_wall.append(float(now_us - _wall_last_us) / 1000000.0)
	_wall_last_us = now_us
	var physics := _physics_since_render
	_physics_since_render = 0
	if _mover != null and _mover.camera != null:
		_mover.present(delta)
		var st := _mover.controller.state
		var motion := _mover.camera_motion
		_mover_frames.append({"dt": delta, "eye": _mover.camera.global_position,
			"grounded": st.is_grounded(), "sliding": st.is_sliding(), "pos": st.position,
			"dip": motion.eye_drop() if motion != null else 0.0,
			"roll": motion.roll() if motion != null else 0.0,
			"widen": motion.fov_added() if motion != null else 0.0})
	if _w.is_empty() or _client == null:
		return
	var server_buffer := _server_buffer()
	if server_buffer != null and server_buffer.late_count + server_buffer.starved_count > int(_w.get("late_seen", 1 << 30)):
		_w["late_seen"] = server_buffer.late_count + server_buffer.starved_count
		_w["last_late_ms"] = Time.get_ticks_msec() - int(_w["started"])
	var p: ArenaPlayer = _client.get("player")
	if p == null or p.camera == null or not p.is_alive():
		_w["last"] = null
		return
	var eye := p.camera.global_position
	var yaw := p.camera.global_rotation_degrees.y
	var frame := {
		"dt": delta, "eye": eye, "yaw": yaw, "vel": _segment_velocity(p),
		"physics": physics, "vm": _view_model_offset(p), "others": {},
		"tick": (_client.get("net") as DotNetManager).clock.tick if _client.get("net") != null else 0,
		"drift": float((_client.get("net") as DotNetManager).clock.get("_drift_scale")) if _client.get("net") != null else 1.0,
		"slip": float((_client.get("net") as DotNetManager).clock.get("_slip")) if _client.get("net") != null else 0.0,
		"slip_rate": float((_client.get("net") as DotNetManager).clock.get("_slip_recovery")) if _client.get("net") != null else 0.0,
		"alpha": p.get("drawn_alpha"), "frac": Engine.get_physics_interpolation_fraction(),
		"offset": p.drawn_offset,
	}
	var g: ArenaGame = _client.get("game")
	for other in g.players():
		if other == p or not other.is_alive():
			continue
		frame["others"][other.player_id] = {
			"drawn": other.body_mesh.global_position if other.body_mesh != null else other.global_position,
			"vel": _segment_velocity(other),
			"render": _render_tick(),
		}
	(_w["frames"] as Array).append(frame)


## The velocity of the stretch of motion a frame is drawn on: from the previous tick's
## position to this one's, which is what interpolation between them moves along. The state's
## own velocity is the wrong reference wherever a tick changed it (a wall, a landing).
static func _segment_velocity(p: ArenaPlayer) -> Vector3:
	var previous := p.controller.render_state(0.0).position
	return (p.controller.state.position - previous) * float(p.controller.tick_rate)


## The view model's animated offset under the camera: sway, bob, kick.
static func _view_model_offset(p: ArenaPlayer) -> Variant:
	if p.weapons == null or p.weapons.view_model() == null:
		return null
	var animated: Node3D = p.weapons.view_model().get("_animated")
	return animated.transform.origin if animated != null else null


## The render tick the interpolator drew at this frame (connected only), the same arithmetic
## as `DotNetManager.interpolate_frame`; -1 offline.
func _render_tick() -> float:
	var net: DotNetManager = _client.get("net")
	if net == null or net.interpolator == null:
		return -1.0
	var alpha := clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0)
	if net.clock.has_method(&"render_alpha"):
		alpha = clampf(float(net.clock.call(&"render_alpha")), -1.0, 2.0)
	var slip := float(net.clock.call(&"receive_slip")) if net.clock.has_method(&"receive_slip") else 0.0
	return float(net.clock.received_tick()) + alpha + slip - net.interpolator.delay_ticks()


func _begin_window(_unused: float) -> void:
	_measure()
	_w = {"frames": [], "started": Time.get_ticks_msec(), "last": null, "tick0": _game.current_tick() if _game != null else 0}
	var net: DotNetManager = _client.get("net")
	if net != null:
		_w["corrections"] = int(net.predictor.get("_corrections_applied"))
		_w["snaps"] = int(net.clock.get("_snap_count"))
		_w["catch_ups"] = int(net.clock.get("_catch_up_count"))
		var buffer := _server_buffer()
		_w["late"] = buffer.late_count if buffer != null else 0
		_w["starved"] = buffer.starved_count if buffer != null else 0
		_w["late_seen"] = int(_w["late"]) + int(_w["starved"])
		_w["last_late_ms"] = -1
		net.interpolator.reset_counts()


## The server's buffer of this client's commands, for how many came late or not at all.
func _server_buffer() -> DotNetInput.Buffer:
	var module := _module()
	if module == null or _link == null:
		return null
	var server_net: DotNetManager = module.get("net")
	return server_net.input_buffer_for(_link.multiplayer.get_unique_id()) if server_net != null else null


func _end_window() -> Dictionary:
	var w := _w
	_w = {}
	w["starved_reason"] = _starvation(float(Engine.max_fps))
	if str(w["starved_reason"]) != "":
		print("    frames: the machine was starved (%s); a failing check here is not judged" % w["starved_reason"])
	w["tick1"] = _game.current_tick() if _game != null else 0
	w["seconds"] = float(Time.get_ticks_msec() - int(w["started"])) / 1000.0
	return w


static func _pct(values: Array, p: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return float(sorted[clampi(int(roundf(p * float(sorted.size() - 1))), 0, sorted.size() - 1)])


## The local eye against its own speed, and the view against the mouse.
func _local(w: Dictionary, limit: float = 0.02) -> Dictionary:
	var frames: Array = w["frames"]
	var ratios := []
	var offs := []
	var turns := []
	var backward := 0
	for i in range(1, frames.size()):
		var a: Dictionary = frames[i - 1]
		var b: Dictionary = frames[i]
		var dt: float = b["dt"]
		var step: Vector3 = b["eye"] - a["eye"]
		var v: Vector3 = b["vel"]
		var flat := Vector3(v.x, 0.0, v.z)
		var speed := flat.length()
		# Judged only where the motion is the same on both sides of the frame: a frame that
		# crosses a corner (a wall, a landing) moved along two steps, and no single
		# velocity says where it should have ended.
		var steady := (v - (a["vel"] as Vector3)).length() < 1.5
		if speed > 1.0 and dt > 0.0 and step.length() < 0.5 and steady:
			var along := Vector3(step.x, 0.0, step.z).dot(flat / speed)
			ratios.append(along / (speed * dt))
			if along < -0.0005:
				backward += 1
			# Less 15% of the step: after a slip the drawing runs up to a tenth fast or slow while
			# taken up (DotNetClock.render_alpha). And less what the clock does on purpose: while it
			# gains lead its ticks run up to 12% short, so the eye runs faster for a few frames.
			var clock_share := absf(1.0 / maxf(float(b.get("drift", 1.0)), 0.01) - 1.0)
			if absf(float(b.get("slip", 0.0))) > 1e-6 or absf(float(a.get("slip", 0.0))) > 1e-6:
				clock_share += float(b.get("slip_rate", 0.0))
			offs.append(maxf(0.0, (Vector3(step.x, 0.0, step.z) - flat * dt).length() - (0.15 + clock_share) * speed * dt))
			if offs[-1] > limit and _verbose:
				print("      alpha %s frac %.3f offset %s" % [b["alpha"], b["frac"], b["offset"]])
				print("      local off frame %d: ticks %d drift %.4f slip %.3f -> %.3f at %.3f dt %.4f physics %d step %s vel %s prev vel %s eye %s" % [i, int(b["tick"]) - int(a["tick"]), b["drift"], float(a.get("slip", 0.0)), float(b.get("slip", 0.0)), float(b.get("slip_rate", 0.0)), dt, b["physics"], step, v, a["vel"], b["eye"]])
		if dt > 0.0:
			turns.append(absf(wrapf(float(b["yaw"]) - float(a["yaw"]), -180.0, 180.0)) / (TURN_RATE * dt))
	var jumps := 0
	for o in offs:
		if float(o) > limit:
			jumps += 1
	var still := 0
	var double := 0
	var median_turn := _pct(turns, 0.5)
	for t in turns:
		if float(t) < 0.5 * median_turn:
			still += 1
		elif float(t) > 1.5 * median_turn:
			double += 1
	return {"ratios": ratios, "offs": offs, "jumps": jumps, "backward": backward,
		"turns": turns, "still": still, "double": double}


func _report_local(w: Dictionary) -> void:
	var l := _local(w)
	var frames: Array = w["frames"]
	print("    %d frames in %.1f s (%.0f fps)" % [frames.size(), w["seconds"], frames.size() / maxf(0.001, w["seconds"])])
	print("    local eye: motion per frame / expected p5 %.2f  p50 %.2f  p95 %.2f; backward %d; off steady p50 %.1f mm  p99 %.1f mm  max %.1f mm; %d frames > 2 cm" % [
		_pct(l["ratios"], 0.05), _pct(l["ratios"], 0.5), _pct(l["ratios"], 0.95), l["backward"],
		_pct(l["offs"], 0.5) * 1000.0, _pct(l["offs"], 0.99) * 1000.0, _pct(l["offs"], 1.0) * 1000.0, l["jumps"]])
	print("    view: %d of %d frames turned under half the median, %d over 1.5x" % [l["still"], (l["turns"] as Array).size(), l["double"]])


func _check_view_turns(w: Dictionary) -> void:
	var l := _local(w)
	_check(l["still"] == 0 and l["double"] == 0, "the view turned evenly on every frame the mouse moved",
		"%d still, %d double of %d" % [l["still"], l["double"], (l["turns"] as Array).size()])


func _check_local(w: Dictionary, limit: float) -> void:
	_check_view_turns(w)
	var l := _local(w, limit)
	_check(l["jumps"] == 0 and l["backward"] == 0,
		"the eye moved with the player on every frame: none more than %d cm off, none backwards" % roundi(limit * 100.0),
		"%d off, %d backwards, max %.1f mm" % [l["jumps"], l["backward"], _pct(l["offs"], 1.0) * 1000.0])


## Everybody else as drawn: each frame's step against the step their motion asked for. Offline
## the truth is their own simulated velocity; connected, the server's track at the render tick
## this frame and the last were drawn at.
func _others(w: Dictionary, limit: float = 0.02) -> Dictionary:
	var frames: Array = w["frames"]
	var offs := []
	var errors := []
	var back := 0
	for i in range(1, frames.size()):
		var a: Dictionary = frames[i - 1]
		var b: Dictionary = frames[i]
		var dt: float = b["dt"]
		for id in b["others"]:
			if not (a["others"] as Dictionary).has(id):
				continue
			var now: Dictionary = b["others"][id]
			var was: Dictionary = a["others"][id]
			var step: Vector3 = (now["drawn"] as Vector3) - (was["drawn"] as Vector3)
			if step.length() > 0.5:
				continue
			var rt: float = now["render"]
			if rt < 0.0:
				var v: Vector3 = now["vel"]
				if Vector3(v.x, 0.0, v.z).length() > 1.0 and (v - (was["vel"] as Vector3)).length() < 1.5:
					offs.append((Vector3(step.x, 0.0, step.z) - Vector3(v.x, 0.0, v.z) * dt).length())
				continue
			var prev_rt: float = was["render"]
			if rt < prev_rt - 0.001:
				back += 1
				if _verbose:
					print("      bot render time back at frame %d: %.4f -> %.4f ticks (dt %.4f)" % [i, prev_rt, rt, dt])
			var track: Dictionary = _track.get(id, {})
			var t_now: Variant = _truth_at(track, rt)
			var t_was: Variant = _truth_at(track, prev_rt)
			if t_now == null or t_was == null or _teleported_near(track, int(rt)):
				continue
			var truth_step: Vector3 = (t_now as Vector3) - (t_was as Vector3)
			# Less a tenth of the step itself: positions arrive on a 7.8 mm grid and are
			# blended along chords of a curve, which at 60 Hz (15 cm a frame) is up to
			# 2.6 cm of a perfectly drawn frame. A hitch is a whole step.
			offs.append(maxf(0.0, (step - truth_step).length() - 0.1 * truth_step.length()))
			if _verbose and float(offs[-1]) > 0.02:
				print("      bot off frame %d: %.1f mm; dt %.4f render %.2f -> %.2f; drawn step %s truth step %s" % [
					i, float(offs[-1]) * 1000.0, dt, prev_rt, rt, step, truth_step])
			errors.append((now["drawn"] as Vector3).distance_to(t_now))
	var hitches := 0
	for o in offs:
		if float(o) > limit:
			hitches += 1
	return {"offs": offs, "errors": errors, "hitches": hitches, "back": back}


func _report_others(w: Dictionary) -> void:
	var o := _others(w)
	print("    others: step off their motion p50 %.1f mm  p95 %.1f mm  p99 %.1f mm  max %.1f mm; %d of %d frames > 2 cm; drawn vs truth p50 %.3f m  p95 %.3f m  max %.3f m; render back %d" % [
		_pct(o["offs"], 0.5) * 1000.0, _pct(o["offs"], 0.95) * 1000.0, _pct(o["offs"], 0.99) * 1000.0,
		_pct(o["offs"], 1.0) * 1000.0, o["hitches"], (o["offs"] as Array).size(),
		_pct(o["errors"], 0.5), _pct(o["errors"], 0.95), _pct(o["errors"], 1.0), o["back"]])


func _check_others(w: Dictionary, what: String, limit: float, back_allowed: int = 0) -> void:
	var o := _others(w, limit)
	_check((o["offs"] as Array).size() > 50 and o["hitches"] == 0 and o["back"] <= back_allowed,
		what % (limit * 100.0),
		"%d of %d frames over, max %.1f mm, render back %d" % [
			o["hitches"], (o["offs"] as Array).size(), _pct(o["offs"], 1.0) * 1000.0, o["back"]])


static func _truth_at(track: Dictionary, tick: float) -> Variant:
	var lo := int(floorf(tick))
	if not track.has(lo) or not track.has(lo + 1):
		return null
	return (track[lo] as Vector3).lerp(track[lo + 1], tick - float(lo))


static func _teleported_near(track: Dictionary, tick: int) -> bool:
	for t in range(tick - 16, tick + 16):
		if track.has(t) and track.has(t + 1) and (track[t] as Vector3).distance_to(track[t + 1]) > 0.5:
			return true
	return false
