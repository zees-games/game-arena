extends RefCounted

## Drives the local player for dot-audio's loudness capture (addons/dot_audio/tools/loudness.sh
## finds this file by name), so a recording of this game is a player's and not the bots'.
##
## [b]Why the stand-in is not enough here.[/b] It holds W and turns a little every six
## seconds, blind: on every built-in map the player walks into the first wall in under two
## seconds and pushes against it for the rest of the cycle, so the recording was the bots'
## steps, their guns and the bed, and the trim set from it was set against the wrong mix.
##
## Everything goes through the capture's [code]key[/code], [code]turn[/code] and
## [code]click[/code], which are input events: the client's own bindings and its
## [DotFpsSampler] read them, exactly as they read a player. Nothing here moves the body.

var _client: Node = null
var _steps: DotAudioFootsteps = null
var _last := Vector3.INF
var _check_ms := 0
var _walked := 0.0
## Degrees still to turn; positive is to the left (the sampler's yaw grows).
var _turn_to := 0.0
var _turns := 0
var _shots := 0
var _own_steps := 0
var _all_steps := 0
var _cycle_ms := 0


func drive(capture: SceneTree, ms: int) -> bool:
	if _client == null or not is_instance_valid(_client):
		_client = _find(capture.root)
		if _client == null:
			return false

	var player: Node3D = _client.get("player")
	var sampler: DotFpsSampler = (
		_client.call(&"active_sampler") if _client.has_method(&"active_sampler") else _client.get("_sampler")
	)
	if player == null or sampler == null:
		return true

	_hook_steps(capture.root, player)

	# Only a click captures the pointer, and only a captured pointer turns the view.
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		capture.call(&"click", true)
		capture.call(&"click", false)
		return true

	var pos := player.global_position
	if _last == Vector3.INF:
		_last = pos
		_check_ms = ms
		_cycle_ms = ms

	# A turn in progress, at most twelve degrees a frame through the sampler's own
	# sensitivity: the feet keep going, so it reads as a player's turn, not a turret's.
	if absf(_turn_to) > 1.0:
		var step := signf(_turn_to) * minf(absf(_turn_to), 12.0)
		var per_px := sampler.tunables.mouse_sensitivity * sampler.tunables.mouse_sensitivity_x
		if per_px > 0.0:
			capture.call(&"turn", -step / per_px)
		_turn_to -= step

	if ms - _check_ms >= 600:
		var moved := Vector2(pos.x - _last.x, pos.z - _last.z).length()
		_walked += moved
		_last = pos
		_check_ms = ms
		# Pushing against something: turn away, a random amount so two walls in a corner
		# do not send it back and forth between them.
		if moved < 0.8 and absf(_turn_to) <= 1.0:
			_turn_to = randf_range(100.0, 170.0) * (1.0 if randf() < 0.5 else -1.0)
			_turns += 1

	var t := float((ms - _cycle_ms) % 7000) / 1000.0
	var cycle := (ms - _cycle_ms) / 7000
	capture.call(&"key", KEY_W, true)
	capture.call(&"key", KEY_SHIFT, cycle % 3 != 1 and t < 5.0)
	capture.call(&"key", KEY_SPACE, t >= 5.0 and t < 5.1)
	if t >= 6.0 and t < 6.05 and absf(_turn_to) <= 1.0:
		_turn_to = randf_range(-60.0, 60.0)

	# Bursts, as a player fires them: a few shots, then a gap.
	var down := bool(capture.get(&"_fire")) and fmod(t, 1.75) < 0.12 and t < 4.5
	if down and not bool(capture.get(&"_held").get(MOUSE_BUTTON_LEFT, false)):
		_shots += 1
	capture.call(&"click", down)
	return true


func describe() -> String:
	return "local player walked %.0f m, %d own steps of %d heard, %d turns, %d shots" % [
		_walked, _own_steps, _all_steps, _turns, _shots,
	]


func _hook_steps(root: Node, player: Node3D) -> void:
	if _steps != null:
		return
	_steps = _find_steps(root)
	if _steps != null:
		_steps.stepped.connect(func(body: Node3D, _surface: StringName, _loudness: float) -> void:
			_all_steps += 1
			if body == player or player.is_ancestor_of(body) or body.is_ancestor_of(player):
				_own_steps += 1)


func _find(n: Node) -> Node:
	if n.get(&"player") != null and (n.has_method(&"active_sampler") or n.get(&"_sampler") != null):
		return n
	for child in n.get_children():
		var hit := _find(child)
		if hit != null:
			return hit
	return null


func _find_steps(n: Node) -> DotAudioFootsteps:
	if n is DotAudioFootsteps:
		return n
	for child in n.get_children():
		var hit := _find_steps(child)
		if hit != null:
			return hit
	return null
