extends "arena_net_weapon_drops.gd"
## The thrown-knife events between server and clients, carried as the KNIFE sub-kind of MORE.

const ArenaKnifeEvents := preload("arena_knife_events.gd")

## The knives layer this bridge last connected to.
var _watched_knives: Node = null


## Follows the knives layer; server side, every tick, because a map change builds a new one.
func _watch_knives() -> void:
	if net == null or not net.is_server or game == null:
		return
	var layer: Node = game.knives
	if layer == _watched_knives:
		return
	_watched_knives = layer
	if layer != null:
		layer.changed.connect(_on_knife_changed)


## Tells a joiner of every knife flying, lying or stuck now.
func _send_knives_signon(peer_id: int) -> void:
	if game == null or game.knives == null:
		return
	for k in game.knives.entries():
		var motion: Vector3 = k.velocity if k.phase == 0 else k.facing
		_send_event(peer_id, ArenaEvents.Kind.MORE, ArenaKnifeEvents.write_knife(k.id, k.owner, k.phase, k.victim, k.at, motion))


func _on_knife_changed(id: int, owner: int, phase: int, victim: int, at: Vector3, motion: Vector3) -> void:
	_send_event(0, ArenaEvents.Kind.MORE, ArenaKnifeEvents.write_knife(id, owner, phase, victim, at, motion))


## Client side: one MORE event; a sub-kind this build does not know is skipped.
func _apply_more_event(reader: DotNetReader) -> void:
	match ArenaKnifeEvents.read_more(reader):
		ArenaKnifeEvents.More.KNIFE:
			var k := ArenaKnifeEvents.read_knife(reader)
			if bool(k["ok"]) and game != null and game.knives != null:
				game.knives.mirror(int(k["id"]), int(k["owner"]), int(k["phase"]), int(k["victim"]), k["at"], k["motion"])
