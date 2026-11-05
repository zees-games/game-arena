extends "headless_net_base.gd"

## 5002df3 / 10daeef: both ends of a predicted player go on from the float32 copy of the state, a bot does not.
## EXPECTED_CHECKS is this suite's own total (the base class's CHECKS belongs to headless_net).
const EXPECTED_CHECKS := 55
const EXPECTED_SECTIONS := 3


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var errors := EngineErrors.new()
	OS.add_logger(errors)
	print("game-arena — float32 rounding of a pulled player")

	_build_server()
	_build_client(2, 11)
	_build_client(3, 12)
	_join_everyone()
	_run_ticks()
	var bot_session := _server_bridge.add_bot("Rounder")
	_check(bot_session != 0, "the server seats a bot")
	_test_bot_stays_unrounded(bot_session)
	_test_peer_owned_rounds_identically()
	_test_replay_stays_consistent()

	OS.remove_logger(errors)
	var seen := errors.seen()
	_check(seen.is_empty(), "the engine reported no error over the whole run",
		"%d: %s" % [seen.size(), ", ".join(seen.slice(0, 3))])
	_report_sections(_entered, _completed, EXPECTED_SECTIONS, EXPECTED_CHECKS)


## A value float32 cannot hold, so rounding is observable.
func _awkward() -> Vector3:
	return Vector3(1.1 + 1e-9, 2.2 + 1e-9, 3.3 + 1e-9)


func _f32(v: float) -> float:
	return PackedFloat32Array([v])[0]


func _load_state(state: DotFpsState) -> void:
	state.position = _awkward()
	state.velocity = Vector3(4.4 + 1e-9, 0.0, -5.5 - 1e-9)
	state.stamina = 77.7 + 1e-9
	state.time_since_grounded = 0.123456789


func _test_bot_stays_unrounded(bot_session: int) -> void:
	print("")
	_section("[a bot (owner 0) keeps its unrounded state after a pull]")
	var behaviour: ArenaPlayerNet = _server_bridge.behaviour_for(bot_session)
	_check(behaviour != null and behaviour.identity != null, "the bot has a net behaviour")
	_check(behaviour.identity.owner_peer_id == 0 and behaviour.identity.is_authoritative,
		"owned by the server, which is authoritative")
	_check(not behaviour.identity.is_predicted(), "and predicted by nobody")
	var state := behaviour.player.controller.state
	_load_state(state)
	behaviour.pull()
	_check(behaviour.net_exact.size() == ArenaPlayerNet.EXACT_FLOATS, "the pull still fills the exact copy")
	_check(state.position.x == _awkward().x and state.position.y == _awkward().y and state.position.z == _awkward().z,
		"position is untouched by the pull", str(state.position))
	_check(state.stamina == 77.7 + 1e-9 and state.time_since_grounded == 0.123456789,
		"and so are stamina and the jump timer")
	_check(behaviour.net_exact[0] == _f32(_awkward().x), "while the exact copy is the float32 one")
	_done()


func _test_peer_owned_rounds_identically() -> void:
	print("")
	_section("[a peer-owned player is rounded on the server and on its owning client alike]")
	var session := int(_clients[2]["session"])
	var on_server: ArenaPlayerNet = _server_bridge.behaviour_for(session)
	var on_client: ArenaPlayerNet = (_clients[2]["bridge"] as ArenaNetBridge).behaviour_for(session)
	_check(on_server.identity.owner_peer_id == 2 and on_server.identity.is_authoritative, "the server holds peer 2's player as authority")
	_check(on_client.identity.is_predicted(), "and the owning client predicts it")
	var server_state := on_server.player.controller.state
	var client_state := on_client.player.controller.state
	_load_state(server_state)
	_load_state(client_state)
	on_server.pull()
	on_client.pull()
	var want := Vector3(_f32(_awkward().x), _f32(_awkward().y), _f32(_awkward().z))
	_check(server_state.position == want, "the server's state is the float32 copy", str(server_state.position))
	_check(client_state.position == want, "and so is the client's", str(client_state.position))
	_check(server_state.velocity == client_state.velocity, "velocity is identical on both")
	_check(server_state.stamina == client_state.stamina and server_state.stamina == _f32(77.7 + 1e-9),
		"stamina is identical on both, and rounded")
	_check(server_state.time_since_grounded == client_state.time_since_grounded,
		"and the jump timer")
	_check(on_server.net_exact == on_client.net_exact, "the exact copies match bit for bit")
	_done()


func _test_replay_stays_consistent() -> void:
	print("")
	_section("[a snapshot replay on the owning client lands on the server's state]")
	var session := int(_clients[2]["session"])
	var on_server: ArenaPlayerNet = _server_bridge.behaviour_for(session)
	var on_client: ArenaPlayerNet = (_clients[2]["bridge"] as ArenaNetBridge).behaviour_for(session)
	var server_state := on_server.player.controller.state
	var client_state := on_client.player.controller.state
	_load_state(server_state)
	on_server.pull()
	# What a snapshot carries: the exact copy. The client rewinds to it, then pulls again for the next tick.
	on_client.net_exact = on_server.net_exact
	on_client._push_exact(client_state)
	_check(client_state.position == server_state.position, "the rewound client position equals the server's")
	_check(client_state.velocity == server_state.velocity, "and velocity")
	_check(client_state.stamina == server_state.stamina, "and stamina")
	on_client.pull()
	_check(client_state.position == server_state.position, "a second pull on the client moves nothing")
	_check(on_client.net_exact == on_server.net_exact, "and the copy it would send is unchanged")
	on_server.pull()
	_check(server_state.position == client_state.position and on_server.net_exact == on_client.net_exact,
		"nor does a second pull on the server")
	_done()

## Counts the engine's own errors while installed (mg-smash-copter's dedicated suite has the
## same class): they go to stderr and change no exit code, so only this makes one fail a run.
class EngineErrors extends Logger:
	var _lock := Mutex.new()
	var _seen := PackedStringArray()

	func _log_error(
		function: String, _file: String, _line: int, code: String, _rationale: String,
		_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]
	) -> void:
		_lock.lock()
		_seen.append("%s (%s)" % [code, function])
		_lock.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func seen() -> PackedStringArray:
		_lock.lock()
		var out := _seen.duplicate()
		_lock.unlock()
		return out

