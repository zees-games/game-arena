extends Control
## Stands in for dot-ui's ballot: in the pointer-modal group, with a switch for pointer mode.

var on := false


func _init() -> void:
	add_to_group(&"dot_pointer_modal")


func is_pointer_mode() -> bool:
	return on
