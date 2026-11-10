extends RefCounted

## Space that closed a kill view or killcam, or was held through a death, must not become a jump on the respawn. While [param away] (dead, or a kill view or killcam playing) the gate is armed;
## once the player is back it strips Jump from every command until one arrives with Jump up, then opens. `cl_respawn_jump_gate` (client, default 1) turns it off; off, [method filter] never touches a command.

var armed := false


## Call once per sampled command. [param away]: the local player is dead or a kill view/killcam plays.
func filter(command: DotFpsCommand, away: bool, enabled: bool = true) -> void:
	if not enabled:
		armed = false
		return
	if away:
		armed = true
	if not armed:
		return
	if command.is_pressed(DotFpsCommand.BUTTON_JUMP):
		command.set_button(DotFpsCommand.BUTTON_JUMP, false)
	elif not away:
		armed = false
