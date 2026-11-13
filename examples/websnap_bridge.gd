extends "../game/arena_net_bridge.gd"

## headless_websnap's bridge: records what [code]ArenaNetLink[/code] hands it, in order, and decodes
## nothing. A snapshot is logged as [code]"snap <tick>:<part>"[/code] (the 32-bit tick every snapshot
## starts with, then the byte the suite put after it), an event as [code]"event"[/code], a map
## message as [code]"map"[/code].

var seen: Array[String] = []


func receive_snapshot(payload: PackedByteArray) -> DotResult:
	var reader := DotNetReader.new(payload)
	var tick := reader.read_uint(32)
	var part := reader.read_uint(8)
	seen.append("snap %d:%d" % [tick, part])
	return DotResult.success(payload.size())


func receive_event(payload: PackedByteArray) -> DotResult:
	seen.append("event")
	return DotResult.success(payload.size())


func receive_map(payload: Dictionary) -> DotResult:
	seen.append("map")
	return DotResult.success(payload.size())
