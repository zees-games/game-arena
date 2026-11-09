extends DotAudioManager

## The arena's sound manager: dot-audio's, with the time it takes to start a sound and to drop the finished ones
## charged to `arena.audio`, so a recording says what sound costs on the game's thread. The mix itself runs on
## the engine's audio thread and is not in it; the report's `context.audio` names the driver and its latency.

const ArenaFrameProbe := preload("arena_frame_probe.gd")


func play(id: StringName, volume_scale: float = 1.0, pitch_scale: float = 1.0) -> int:
	var t := Time.get_ticks_usec()
	var handle := super(id, volume_scale, pitch_scale)
	ArenaFrameProbe.add(&"audio", t)
	return handle


func play_at(id: StringName, position: Vector3, volume_scale: float = 1.0, pitch_scale: float = 1.0) -> int:
	var t := Time.get_ticks_usec()
	var handle := super(id, position, volume_scale, pitch_scale)
	ArenaFrameProbe.add(&"audio", t)
	return handle


func play_at_2d(id: StringName, position: Vector2, volume_scale: float = 1.0, pitch_scale: float = 1.0) -> int:
	var t := Time.get_ticks_usec()
	var handle := super(id, position, volume_scale, pitch_scale)
	ArenaFrameProbe.add(&"audio", t)
	return handle


func _process(delta: float) -> void:
	var t := Time.get_ticks_usec()
	super(delta)
	ArenaFrameProbe.add(&"audio", t)
