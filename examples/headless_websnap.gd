extends DotGameCheckSuite

const ArenaNetLink := preload("../game/arena_net_link.gd")
const WebsnapBridge := preload("websnap_bridge.gd")

## `cl_snapshot_coalesce`, the browser client's snapshot skipping (ArenaNetLink): the snapshots one
## network poll brings are held, and at the end of the poll only the newest tick's parts are applied,
## in arrival order; older ticks count as lost (`snapshots_coalesced`), which the server's resend
## already repairs. A reliable event or a map message applies the held newest tick first, so state
## and events keep their order. Native clients decode every snapshot as it comes.
##
## The link is driven exactly as the RPC poll drives it (`_net_snapshot` / `_net_event` / `_net_map`
## called back to back within one frame); the frame's end is the deferred flush.

const SECTIONS := 5
const CHECKS := 16

var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	print("game-fatal-contact: a browser client applies only the newest snapshot of a poll")
	await _run()
	ArenaNetLink.coalesce = OS.has_feature("web")
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


## A snapshot payload as the server writes it: the 32-bit tick first; [param part] marks which one it was.
func _snap(tick: int, part: int = 0) -> PackedByteArray:
	var w := DotNetWriter.new()
	w.write_uint(tick, 32)
	w.write_uint(part, 8)
	return w.to_bytes()


## Whether the bridge saw exactly [param want], in that order.
func _is(seen: Array[String], want: Array) -> bool:
	if seen.size() != want.size():
		return false
	for i in seen.size():
		if seen[i] != str(want[i]):
			return false
	return true


func _link() -> Array:
	var bridge := WebsnapBridge.new()
	var link := ArenaNetLink.new()
	link.bridge = bridge
	add_child(bridge)
	add_child(link)
	return [link, bridge]


func _drop(pair: Array) -> void:
	(pair[0] as Node).queue_free()
	(pair[1] as Node).queue_free()


func _run() -> void:
	_section("on only in a browser; off, every snapshot is decoded as it comes")
	_check(ArenaNetLink.coalesce == OS.has_feature("web"), "coalescing is on by default only in a browser",
		"%s, web %s" % [ArenaNetLink.coalesce, OS.has_feature("web")])
	ArenaNetLink.coalesce = false
	var off := _link()
	var off_link: ArenaNetLink = off[0]
	var off_bridge: WebsnapBridge = off[1]
	off_link._net_snapshot(_snap(10))
	off_link._net_snapshot(_snap(11))
	off_link._net_snapshot(_snap(12))
	_check(_is(off_bridge.seen, ["snap 10:0", "snap 11:0", "snap 12:0"]), "off, three snapshots in one poll are all applied, at once and in order", str(off_bridge.seen))
	await get_tree().process_frame
	_check(off_bridge.seen.size() == 3 and off_link.snapshots_coalesced == 0, "and none is counted as lost", "%d lost" % off_link.snapshots_coalesced)
	_drop(off)
	_done()

	ArenaNetLink.coalesce = true
	_section("on, a poll's older ticks are dropped and the newest applied once")
	var on := _link()
	var link: ArenaNetLink = on[0]
	var bridge: WebsnapBridge = on[1]
	link._net_snapshot(_snap(20))
	link._net_snapshot(_snap(22))
	link._net_snapshot(_snap(21))
	_check(bridge.seen.is_empty(), "nothing is decoded while the poll is still delivering", str(bridge.seen))
	await get_tree().process_frame
	_check(_is(bridge.seen, ["snap 22:0"]), "at the end of the poll only the newest tick is applied, even if it did not come last", str(bridge.seen))
	_check(link.snapshots_received == 3 and link.snapshots_coalesced == 2 and int(link.describe()["coalesced"]) == 2,
		"the two older ones count as received and lost", "%d received, %d lost" % [link.snapshots_received, link.snapshots_coalesced])
	await get_tree().process_frame
	_check(bridge.seen.size() == 1, "and nothing is applied twice", str(bridge.seen))
	_done()

	_section("a tick sent in parts keeps every part")
	bridge.seen.clear()
	link._net_snapshot(_snap(30, 1))
	link._net_snapshot(_snap(31, 1))
	link._net_snapshot(_snap(31, 2))
	await get_tree().process_frame
	_check(_is(bridge.seen, ["snap 31:1", "snap 31:2"]), "both parts of the newest tick are applied, in arrival order", str(bridge.seen))
	_check(link.snapshots_coalesced == 3, "and the older tick's part is lost", "%d lost" % link.snapshots_coalesced)
	bridge.seen.clear()
	link._net_snapshot(_snap(32))
	await get_tree().process_frame
	_check(_is(bridge.seen, ["snap 32:0"]) and link.snapshots_coalesced == 3, "a poll with one snapshot applies it and loses nothing", str(bridge.seen))
	_done()

	_section("an event applies the held state first")
	bridge.seen.clear()
	link._net_snapshot(_snap(40))
	link._net_snapshot(_snap(41))
	link._net_event(PackedByteArray([1, 2, 3]))
	link._net_snapshot(_snap(42))
	_check(_is(bridge.seen, ["snap 41:0", "event"]), "the newest snapshot before the event is applied before it, the older one lost", str(bridge.seen))
	await get_tree().process_frame
	_check(_is(bridge.seen, ["snap 41:0", "event", "snap 42:0"]), "and a snapshot after the event waits for the end of the poll", str(bridge.seen))
	_check(link.snapshots_coalesced == 4 and link.events_received == 1, "one more lost, the event counted", "%d lost" % link.snapshots_coalesced)
	_done()

	_section("a map change applies the held state first")
	bridge.seen.clear()
	link._net_snapshot(_snap(50))
	link._net_map({"map": "dm_atrium"})
	_check(_is(bridge.seen, ["snap 50:0", "map"]), "the held snapshot is applied before the map message", str(bridge.seen))
	await get_tree().process_frame
	_check(bridge.seen.size() == 2 and link.map_received == 1, "and not again at the end of the poll", str(bridge.seen))
	link._net_event(PackedByteArray([9]))
	_check(_is(bridge.seen, ["snap 50:0", "map", "event"]), "an event with nothing held goes straight through", str(bridge.seen))
	_drop(on)
	_done()
