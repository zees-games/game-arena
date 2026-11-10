extends DotAudioManager

## The arena's sound manager: dot-audio's, with the time it takes to start a sound and to drop the finished ones
## charged to `arena.audio`, so a recording says what sound costs on the game's thread. The mix itself runs on
## the engine's audio thread and is not in it; the report's `context.audio` names the driver and its latency.

const ArenaFrameProbe := preload("arena_frame_probe.gd")
const ArenaTickBudget := preload("arena_tick_budget.gd")

## While the solo game is behind wall-clock time (ArenaTickBudget.shed_now), positional one-shots further than [constant SHED_NEAR] from the listener are limited to [constant SHED_FAR_PER_FRAME] a drawn frame;
## the rest are refused the way dot-audio refuses a sound over its concurrency limit (handle 0, `played` with a reason). Sounds without a position (own weapon, interface, announcers) and near ones always play.
const SHED_NEAR := 12.0
const SHED_FAR_PER_FRAME := 2

var shed_count := 0
var _shed_frame := -1
var _far_this_frame := 0


func play(id: StringName, volume_scale: float = 1.0, pitch_scale: float = 1.0) -> int:
	var t := Time.get_ticks_usec()
	var handle := super(id, volume_scale, pitch_scale)
	ArenaFrameProbe.add(&"audio", t)
	return handle


func play_at(id: StringName, position: Vector3, volume_scale: float = 1.0, pitch_scale: float = 1.0) -> int:
	if _sheds(position):
		shed_count += 1
		played.emit(id, 0, &"shed")
		return 0
	var t := Time.get_ticks_usec()
	var handle := super(id, position, volume_scale, pitch_scale)
	ArenaFrameProbe.add(&"audio", t)
	return handle


## Whether a one-shot at [param position] is dropped this frame because the game is behind.
func _sheds(position: Vector3) -> bool:
	if ArenaTickBudget.shed_now < ArenaTickBudget.SHED_ON:
		return false
	if position.distance_squared_to(listener_position) <= SHED_NEAR * SHED_NEAR:
		return false
	var frame := Engine.get_process_frames()
	if frame != _shed_frame:
		_shed_frame = frame
		_far_this_frame = 0
	_far_this_frame += 1
	return _far_this_frame > SHED_FAR_PER_FRAME


func play_at_2d(id: StringName, position: Vector2, volume_scale: float = 1.0, pitch_scale: float = 1.0) -> int:
	var t := Time.get_ticks_usec()
	var handle := super(id, position, volume_scale, pitch_scale)
	ArenaFrameProbe.add(&"audio", t)
	return handle


func _process(delta: float) -> void:
	var t := Time.get_ticks_usec()
	super(delta)
	ArenaFrameProbe.add(&"audio", t)
