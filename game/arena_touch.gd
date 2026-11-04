extends RefCounted

## The on-screen buttons of a phone: dot-ui's [DotTouchButtons] over the HUD, wired to the client's own
## command bits. The sampler's stick and look drag are dot-player-controller's; this is only the buttons.

## Offsets are from the bottom-right corner (see [DotTouchButtons]). Small radii and the whole cluster
## above the ammunition plate, which sits in the corner on a phone-size frame.
const LAYOUT: Array[Dictionary] = [
	{"id": &"fire", "label": "FIRE", "offset": Vector2(80, 150), "radius": 46.0},
	{"id": &"jump", "label": "JUMP", "offset": Vector2(180, 130), "radius": 36.0},
	{"id": &"crouch", "label": "DUCK", "offset": Vector2(60, 250), "radius": 30.0},
	{"id": &"reload", "label": "R", "offset": Vector2(160, 220), "radius": 28.0},
	{"id": &"next", "label": "NEXT", "offset": Vector2(250, 190), "radius": 28.0},
]

var buttons: DotTouchButtons = null
var _client: Node = null
var _sampler: DotFpsTouchSampler = null


## Builds the buttons under [param host] (the HUD) when the device has touch; null otherwise.
static func build(client: Node, host: Control, sampler: DotFpsSampler, menu_button: Button = null) -> RefCounted:
	if not DotPlatform.has_touch() or not sampler is DotFpsTouchSampler:
		return null
	var made: RefCounted = (load("res://game/arena_touch.gd") as GDScript).new()
	made.call(&"_setup", client, host, sampler, menu_button)
	return made


func _setup(client: Node, host: Control, sampler: DotFpsTouchSampler, menu_button: Button) -> void:
	_client = client
	_sampler = sampler
	buttons = DotTouchButtons.new()
	buttons.name = "TouchButtons"
	buttons.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	buttons.set_buttons(LAYOUT.duplicate())
	buttons.button_down.connect(_pressed.bind(true))
	buttons.button_up.connect(_pressed.bind(false))
	host.add_child(buttons)
	sampler.ignore_fn = func(at: Vector2) -> bool:
		return buttons.contains_point(at) or menu_button != null and menu_button.visible \
			and menu_button.get_global_rect().has_point(at)
	sampler.set_screen_width(host.get_viewport().get_visible_rect().size.x)


func is_held(id: StringName) -> bool:
	return buttons != null and buttons.is_held(id)


func _pressed(id: StringName, down: bool) -> void:
	if id == &"jump":
		_sampler.hold(DotFpsCommand.BUTTON_JUMP, down)
	elif id == &"crouch":
		_sampler.hold(DotFpsCommand.BUTTON_CROUCH, down)
	elif id == &"next" and down:
		_client.call(&"touch_next_weapon")
