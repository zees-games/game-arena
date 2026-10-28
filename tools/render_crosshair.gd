extends SceneTree

const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMapLighting := preload("../maps/arena_map_lighting.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

## The spread crosshair through DotGameCombatFeel.drive, standing and then running, as two frames to look at:
## screenshots/crosshair/{still,moving,air}.png, each with the cone it was drawn at in its name's log line.
## Run through tools/render_crosshair.sh (needs a display; --headless saves empty frames).

const OUT_DIR := "screenshots/crosshair"
const NAMES := ["still", "moving", "air"]
const FILES := ["still.png", "moving.png", "air.png"]
const SETTLE := [90, 50, 8]
const TICK_RATE := 64

var _player: ArenaPlayer = null
var _cross: DotCrosshair = null
var _feel: DotGameCombatFeel = null
var _tick := 1
var _phase := 0
var _frames := 0
var _move := Vector2.ZERO
var _buttons := 0


func _initialize() -> void:
	Engine.physics_ticks_per_second = TICK_RATE
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var map := ArenaMap.dm_box()
	root.add_child(map.to_scene())
	root.add_child(ArenaMapLighting.build(map))
	_feel = DotGameCombatFeel.new(true, false)
	_player = ArenaPlayer.new()
	_player.setup(ArenaPlayer.Mode.HEADLESS, map, 7, "You")
	root.add_child(_player)
	_player.spawn(Transform3D(Basis(), Vector3(-16.0, 0.05, 6.0)), 0)
	_player.attach_camera(100.0)
	_player.camera.current = true
	_player.give_default_loadout()
	_feel.attach(_player.arsenal)
	var layer := CanvasLayer.new()
	root.add_child(layer)
	_cross = DotCrosshair.new()
	_cross.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_cross.base_gap = 6.0
	layer.add_child(_cross)


func _physics_process(_delta: float) -> bool:
	var cmd := DotFpsCommand.new()
	cmd.move = _move
	cmd.yaw = -90.0
	cmd.buttons = _buttons
	var _out := _player.simulate_tick(_tick, 1.0 / float(TICK_RATE), cmd, DotWeaponCommand.new())
	_tick += 1
	return false


func _process(delta: float) -> bool:
	_player.present(delta)
	_feel.drive(_cross, _player.arsenal, _player.camera.fov)
	_frames += 1
	if _frames < SETTLE[_phase]:
		return false
	var spread: float = _player.arsenal.spread_now()
	root.get_texture().get_image().save_png(OUT_DIR.path_join(FILES[_phase]))
	print(NAMES[_phase], ": cone ", snappedf(spread, 0.01), " degrees, crosshair spread ", snappedf(float(_cross.get("_spread_degrees")), 0.01))
	_phase += 1
	_frames = 0
	if _phase == 1:
		_move = Vector2(0.0, 1.0)
	elif _phase == 2:
		_buttons = DotFpsCommand.BUTTON_JUMP
		_move = Vector2(0.0, 1.0)
	return _phase >= NAMES.size()
