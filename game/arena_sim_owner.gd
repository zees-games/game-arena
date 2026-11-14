extends Node
## The solo server process obeying its owner: the one loopback player it was started for runs its
## console (bot_quota, bot_difficulty, sv_cheats, arena_mode and the rest) and two verbs of its own:
## `host_change <map|-> [mode]`, awaited so the answer is the real result, `host_pause 0|1`, and `host_local <id>`
## for a map dropped onto the client's window (its M menu lists this process's catalogue).

const ArenaModule := preload("arena_module.gd")
const ArenaMaps := preload("arena_maps.gd")
const CHANNEL := "arena.sim_owner"

var server: DotServer = null
var module: ArenaModule = null


func setup(with_server: DotServer, with_module: ArenaModule) -> void:
	server = with_server
	module = with_module
	module.bridge.host_line_fn = _on_line
	# Solo plays a map until its player changes it: no map clock, so no vote and no rotation.
	if module.maps != null and module.maps.session != null:
		module.maps.session.map_seconds = 0.0
		module.maps.session.time_limit.duration = 0.0
	# The packs a solo menu lists, so a pick of one can be changed to (fetched on the change).
	if module.maps != null and module.maps.session != null:
		var catalogue: DotMapCatalogue = module.maps.session.catalogue
		var _adopted := ArenaMaps.adopt_delivered(catalogue, ArenaMaps.standalone_keys(catalogue))


## `bot_quota N` means N players, the owner included, as solo counts it: the server's `fill`.
## Only once the owner is in; before that `fill` would add a bot in the owner's place.
func _process(_delta: float) -> void:
	if owner_peer() == 0:
		return
	set_process(false)
	var quota: DotBotQuota = module.get("_bot_quota")
	if quota != null and quota.mode_cvar != null:
		quota.quota_cvar.force_set(String.num_int64(quota.quota_cvar.get_int() + 1))
		quota.mode_cvar.force_set("fill")


## The first remote session: the client that started this process.
func owner_peer() -> int:
	for session: DotClientSession in server.sessions():
		if not session.local:
			return session.peer_id
	return 0


func _on_line(peer_id: int, seq: int, line: String) -> void:
	if peer_id != owner_peer():
		return
	var words := line.strip_edges().split(" ", false)
	var verb := words[0].to_lower() if not words.is_empty() else ""
	var answer := ""
	var result := DotResult.success(null)
	match verb:
		"host_change":
			result = await _change(words[1] if words.size() > 1 else "-", words[2] if words.size() > 2 else "-")
		"host_names":
			_send_names(peer_id, seq)
		"host_local":
			result = list_local(words[1] if words.size() > 1 else "")
			if result.ok:
				answer = str(result.value)
		"host_pause":
			if words.size() > 1:
				module.bridge.host_paused = words[1].to_int() != 0
			answer = "%s at tick %d" % ["paused" if module.bridge.host_paused else "running", module.game.current_tick()]
		_:
			var ctx := DotCmdContext.console("", PackedStringArray())
			ctx.address = "owner"
			ctx.reply_sink = func(text: String) -> void: module.bridge.send_host_reply(peer_id, seq, false, true, text)
			result = server.console.execute(line, ctx)
	if not result.ok:
		answer = result.error.message
	module.bridge.send_host_reply(peer_id, seq, true, result.ok, answer)


## The map first, then the mode on it: a mode the map cannot host is refused and the map stays changed.
func _change(map_id: String, mode_id: String) -> DotResult:
	var game: Object = module.game
	if map_id != "-" and map_id != "":
		# A map dropped onto the client's window after this process started is not in its catalogue yet.
		var listed: DotMapCatalogue = module.maps.session.catalogue if module.maps != null and module.maps.session != null else null
		if listed != null and not listed.has(StringName(map_id)):
			var _local := ArenaMaps.add_local(listed, StringName(map_id))
		var changed: DotResult = await module.maps.change_to(StringName(map_id))
		if not changed.ok:
			return changed
	if mode_id != "-" and mode_id != "" and String(game.mode.id) != mode_id:
		var _set: DotResult = server.console.execute("arena_mode %s" % mode_id)
		# The mode's map change runs at the top of the next tick (dot_tick_gate.gd); judge it after.
		await game.tick_gate.reached()
		if String(game.mode.id) != mode_id:
			return DotResult.fail(DotError.CODE_STATE, "This map cannot play %s." % mode_id)
	return DotResult.success(String(game.map.id))


## Lists the dropped map [param map_id] (found in user://maps, shared with the client) in this process's catalogue, so the
## owner's M menu offers it at once; a map dropped again replaces its row. Answers with its title.
func list_local(map_id: String) -> DotResult:
	var listed: DotMapCatalogue = module.maps.session.catalogue if module.maps != null and module.maps.session != null else null
	if listed == null:
		return DotResult.fail(DotError.CODE_STATE, "no map catalogue")
	if map_id == "" or not ArenaMaps.add_local(listed, StringName(map_id)):
		return DotResult.fail(DotError.CODE_INVALID, "%s is not a local map here" % map_id)
	return DotResult.success(listed.get_map(StringName(map_id)).name_or_id())


## Every command and cvar name, a line of them at a time: what the owner's Tab and launch lines know.
func _send_names(peer_id: int, seq: int) -> void:
	var line := ""
	for known: String in server.console.command_names() + server.console.cvar_names():
		if line.length() + known.length() > 100:
			module.bridge.send_host_reply(peer_id, seq, false, true, line)
			line = ""
		line += known + " "
	if line != "":
		module.bridge.send_host_reply(peer_id, seq, false, true, line)
