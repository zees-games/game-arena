extends Node

## Solo play with the simulation off the render thread (on for the launched game; `-- --sim_host 0` turns it off): starts the solo game as a loopback server process ([code]arena_sim_server.gd[/code]) and joins it,
## so this process only predicts its own player, interpolates the rest from snapshots and draws. See docs/sim-thread.md. A failure at any step leaves [member up] false and the client plays the stock in-process solo game.

const CHANNEL := "arena.sim_host"
const SERVER_SCENE := "res://scenes/arena_sim_server.tscn"
## The user arg that makes a started game the server: the child runs the main scene, which hands over to
## [constant SERVER_SCENE]. A release export refuses a scene path (and `--path`) on its command line.
const SERVER_FLAG := "--sim_server"
## The child's own log, so a boot failure can say why; its default log is the parent's file.
const SERVER_LOG := "user://logs/sim_server.log"
const ANCHOR := "ArenaSimServer"
const BOOT_LIMIT_SEC := 60.0
const JOIN_LIMIT_SEC := 30.0
## How often the boot and the join are looked at: a coarser step is the average of half of it added to the load, twice.
const POLL_SEC := 0.02

## Set by a tool before the client loads: 1 on, 0 off, -1 the command line decides.
static var forced := -1
## The map and mode a tool asks for; "" reads `--map` and `--mode` from the command line.
static var ask_map := ""
static var ask_mode := ""

## The host that is up, for a profile's or a bench's header (ArenaNetContext); null while none is.
static var live: Node = null

## True once the link is playing on the local server.
var up := false
var link: DotClientLink = null
var _pid := -1
var _anchor: Node = null
var _ready_path := ""


## Whether this process is the server a hosted game started ([constant SERVER_FLAG]).
static func is_server_child() -> bool:
	return _arg(SERVER_FLAG) == "1"


## Whether this session is hosted: a second process needs a desktop build. [param launched] is true for the game started as itself, which is hosted unless `--sim_host 0`, `--offline` included (the launchers pass it); a suite or tool that instances the client in its own scene keeps the in-process game it reads, unless it sets [member forced].
static func wanted(launched: bool = false) -> bool:
	return wanted_for(OS.get_cmdline_user_args(), launched)


## [method wanted] for the given user args.
static func wanted_for(args: PackedStringArray, launched: bool) -> bool:
	if DotPlatform.is_web() or not DotPlatform.has_threads():
		return false
	if DotRegistry.get_service(&"dot_client_link") != null:
		return false
	if forced >= 0:
		return forced == 1
	var index := args.find("--sim_host")
	if index >= 0 and index + 1 < args.size():
		return args[index + 1].to_int() == 1
	return launched


func start(bots: int) -> DotResult:
	if not ResourceLoader.exists(SERVER_SCENE):
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "the server scene is not in this build")
	var port := _free_port()
	if port <= 0:
		return DotResult.fail(DotError.CODE_INVALID, "no free loopback port")
	_ready_path = ProjectSettings.globalize_path("user://sim_host_%d.ready" % port)
	if FileAccess.file_exists(_ready_path):
		var _gone := DirAccess.remove_absolute(_ready_path)
	var log_path := ProjectSettings.globalize_path(SERVER_LOG)
	var args := PackedStringArray(["--headless", "--log-file", log_path])
	# An editor binary runs whatever project it is pointed at; an export carries its own and refuses `--path`.
	var project := ProjectSettings.globalize_path("res://")
	if project != "" and not OS.has_feature("template"):
		args.append_array(["--path", project])
	args.append_array(["--", SERVER_FLAG, "1", "--port", str(port), "--bots", str(bots),
		"--ready", _ready_path])
	var map := asked_map_id()
	var mode := ask_mode if ask_mode != "" else _arg("--mode")
	if map != "":
		args.append_array(["--map", map])
	if mode != "":
		args.append_array(["--mode", mode])
	var bot_threads := _arg("--bot_threads")
	if bot_threads != "":
		args.append_array(["--bot_threads", bot_threads])
	var load_us := _arg("--sim_load_us")
	if load_us != "":
		args.append_array(["--sim_load_us", load_us])
	var sim_sections := _arg("--sim_sections")
	if sim_sections != "":
		args.append_array(["--sim_sections", sim_sections])
	_pid = OS.create_process(OS.get_executable_path(), args)
	if _pid <= 0:
		return DotResult.fail(DotError.CODE_INVALID, "the server process did not start")

	var t := 0.0
	while not FileAccess.file_exists(_ready_path) and t < BOOT_LIMIT_SEC:
		if not OS.is_process_running(_pid):
			var why := _exit_reason(log_path)
			_pid = -1
			return DotResult.fail(DotError.CODE_INVALID, "the server process exited while booting (%s)" % why)
		await get_tree().create_timer(POLL_SEC).timeout
		t += POLL_SEC
	if not FileAccess.file_exists(_ready_path):
		stop()
		return DotResult.fail(DotError.CODE_INVALID, "the server did not come up in time")

	link = DotClientLink.new()
	link.name = "Server"
	link.transport_preference = "udp"
	# RPCs address a node by path: the link sits where the server's own node does, `/root/ArenaSimServer/Server`.
	_anchor = Node.new()
	_anchor.name = ANCHOR
	get_tree().root.add_child(_anchor)
	_anchor.add_child(link)
	var asked: DotResult = await link.connect_to_server("127.0.0.1:%d" % port)
	if not asked.ok:
		stop()
		return asked
	t = 0.0
	while not link.is_playing() and t < JOIN_LIMIT_SEC:
		await get_tree().create_timer(POLL_SEC).timeout
		t += POLL_SEC
	if not link.is_playing():
		stop()
		return DotResult.fail(DotError.CODE_INVALID, "never joined the local server")
	up = true
	live = self
	return DotResult.success({"port": port, "pid": _pid, "boot_sec": t})


## Ends the server process and drops the link; safe to call twice.
func stop() -> void:
	up = false
	if live == self:
		live = null
	if link != null and is_instance_valid(link):
		# On quit this runs from _exit_tree after the link has left the tree, where its `multiplayer` is null and
		# disconnect_from_server raised a script error; the server process is killed below either way.
		if link.is_inside_tree() and link.is_playing():
			link.disconnect_from_server("done")
	link = null
	if _anchor != null and is_instance_valid(_anchor):
		_anchor.queue_free()
	_anchor = null
	if _pid > 0:
		var _killed := OS.kill(_pid)
		_pid = -1
	if _ready_path != "" and FileAccess.file_exists(_ready_path):
		var _gone := DirAccess.remove_absolute(_ready_path)


func _exit_tree() -> void:
	stop()


## Why the child ended: its exit code and the last error lines of its log.
func _exit_reason(log_path: String) -> String:
	var parts := PackedStringArray(["exit %d" % OS.get_process_exit_code(_pid)])
	var text := FileAccess.get_file_as_string(log_path)
	if text == "":
		parts.append("no log at %s" % log_path)
		return "; ".join(parts)
	var errors := PackedStringArray()
	for line in text.split("\n", false):
		if line.begins_with("ERROR") or line.begins_with("SCRIPT ERROR") or line.contains("Parse Error"):
			errors.append(line.strip_edges())
	if errors.is_empty():
		var lines := text.strip_edges().split("\n", false)
		errors = lines.slice(maxi(lines.size() - 3, 0))
	parts.append_array(errors.slice(maxi(errors.size() - 3, 0)))
	parts.append("log %s" % log_path)
	return "; ".join(parts)


## A port free for both of the server's sockets (TCP and UDP): asked of the OS, then released for the child.
static func _free_port() -> int:
	for attempt in 8:
		var tcp := TCPServer.new()
		if tcp.listen(0, "127.0.0.1") != OK:
			continue
		var port := tcp.get_local_port()
		tcp.stop()
		var udp := PacketPeerUDP.new()
		var bound := udp.bind(port, "127.0.0.1") == OK
		udp.close()
		if bound:
			return port
	return 0


## The map the server child is started on: the tool's ask, else `--map`; "" leaves it to the server.
static func asked_map_id() -> String:
	return ask_map if ask_map != "" else _arg("--map")


static func _arg(flag: String) -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find(flag)
	return args[index + 1] if index >= 0 and index + 1 < args.size() else ""
