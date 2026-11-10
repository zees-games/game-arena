extends RefCounted

## The dedicated server the play and bench tools each stand up on a loopback port: the real
## [DotServer] with [ArenaModule] loaded by path, its files in a run directory of the tool's
## own.


## A config for a loopback server whose admin, ban and audit files live in [param data].
static func config(hostname: String, port: int, data: String, log_level: String,
		max_players := 0) -> DotServerConfig:
	var config := DotServerConfig.new()
	config.hostname = hostname
	config.port = port
	if max_players > 0:
		config.max_players = max_players
	config.bind_address = "127.0.0.1"
	config.transport_mode = "dual"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % data
	config.bans_path = "%s/bans.json" % data
	config.audit_log_path = "%s/audit.jsonl" % data
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""
	config.query_enabled = false
	config.enet_share_udp_port = false
	config.stdin_console_enabled = false
	config.log_level = log_level
	return config


## Boots a server on [param config] under [param parent] and loads the arena module. Null
## (after printing [param tag] and why) when either step fails.
static func boot(parent: Node, config: DotServerConfig, tag: String) -> DotServer:
	var server := DotServer.new()
	server.name = "Server"
	server.config = config
	server.config_file = ""
	server.auto_boot = false
	parent.add_child(server)
	var booted: DotResult = await server.boot()
	if not booted.ok:
		printerr(tag, ": ", booted.error)
		return null
	var loaded: DotResult = await server.modules.load_module("res://game/arena_module.gd")
	if not loaded.ok:
		printerr(tag, ": ", loaded.error)
		return null
	return server
