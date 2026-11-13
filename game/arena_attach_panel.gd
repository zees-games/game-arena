extends CanvasLayer
## The attachments menu over the game (docs/client.md, the Attachments key): it lists what fits the gun in hand.
## A pick goes to the server as Ask.ATTACH through [member send_fn]; offline, with no server, it is served here
## by the same `ArenaAttach.serve`. The rows follow the arsenal, which takes the server's fitting from the snapshot.

const ArenaAttach := preload("arena_attach.gd")

signal open_changed(open: bool)

## The arsenal whose gun in hand the menu fits; `func() -> DotWeaponArsenal`.
var arsenal_fn: Callable = Callable()
## Sends a request body to the server; left empty offline, where the pick is served at once.
var send_fn: Callable = Callable()

var menu: DotWeaponAttachMenu = null
var _slot := -1
var _code := -1


func _ready() -> void:
	layer = 20
	menu = DotWeaponAttachMenu.new()
	menu.name = "AttachMenu"
	menu.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT, Control.PRESET_MODE_MINSIZE, 24)
	menu.hide()
	add_child(menu)
	menu.requested.connect(_on_requested)
	menu.closed.connect(close)
	set_process(false)


func is_open() -> bool:
	return menu != null and menu.visible


## Opens the menu on the gun in hand; false (and nothing shown) when it has no mounts or there is no gun.
func open() -> bool:
	var arsenal := _arsenal()
	if arsenal == null or arsenal.attachments == null or arsenal.current() == null:
		return false
	var base := arsenal.catalogue.get_def(arsenal.current().id())
	if base == null or base.mounts.is_empty():
		return false
	_slot = arsenal.current_slot()
	_code = ArenaAttach.held_code(arsenal)
	menu.open(arsenal.attachments, base, arsenal.fitting_at(_slot))
	set_process(true)
	open_changed.emit(true)
	return true


func close() -> void:
	if not is_open():
		return
	menu.hide()
	set_process(false)
	open_changed.emit(false)


func _process(_delta: float) -> void:
	var arsenal := _arsenal()
	# A switch, a drop or a death takes the gun the rows were for.
	if arsenal == null or arsenal.current() == null or arsenal.current_slot() != _slot:
		close()
		return
	var code := ArenaAttach.held_code(arsenal)
	if code != _code:
		_code = code
		menu.show_fitting(arsenal.fitting_at(_slot))


func _on_requested(mount: StringName, id: StringName) -> void:
	var body := ArenaAttach.write_request(_slot, mount, id)
	if send_fn.is_valid():
		send_fn.call(body)
		return
	var arsenal := _arsenal()
	if arsenal != null:
		var _fitted := ArenaAttach.serve(arsenal, DotNetReader.new(body))


func _arsenal() -> DotWeaponArsenal:
	return arsenal_fn.call() as DotWeaponArsenal if arsenal_fn.is_valid() else null
