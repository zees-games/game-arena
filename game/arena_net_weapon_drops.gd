extends "arena_net_toys.gd"
## The pickup and dropped-weapon events between server and clients: follows each layer, sends, and mirrors.

const ArenaContent := preload("arena_content.gd")
const ArenaWeaponDropEvents := preload("arena_weapon_drop_events.gd")

## The drops layer this bridge last connected to. See [method _watch_drops].
var _watched_drops: Node = null

## The dropped-weapon layer this bridge last connected to.
var _watched_weapon_drops: DotWeaponDrops = null


## Follows the dropped weapons (thrown or left by the dead); server side, every tick, because a map change builds a new layer.
func _watch_weapon_drops() -> void:
	if net == null or not net.is_server or game == null:
		return
	var layer: DotWeaponDrops = game.weapon_drops
	if layer == _watched_weapon_drops:
		return
	_watched_weapon_drops = layer
	if layer != null:
		layer.dropped.connect(_on_weapon_dropped)
		layer.settled.connect(_on_weapon_settled)
		layer.removed.connect(_on_weapon_gone)


## Tells a joiner of the weapons lying about now, at rest where they lie.
func _send_weapon_drops_signon(peer_id: int) -> void:
	if game == null or game.weapon_drops == null:
		return
	for entry in game.weapon_drops.snapshot():
		_send_event(peer_id, ArenaEvents.Kind.WEAPON_DROP, _weapon_drop_body(
			int(entry["id"]), entry["state"], entry["at"], Vector3.ZERO, float(entry["life"]), bool(entry["rest"]), int(entry["team"])))


func _send_event(peer_id: int, kind: int, body: PackedByteArray) -> void:
	call(&"send_event", peer_id, kind, body)


func _on_weapon_dropped(id: int, state: Dictionary, at: Transform3D, velocity: Vector3, _owner: int) -> void:
	_send_event(0, ArenaEvents.Kind.WEAPON_DROP, _weapon_drop_body(id, state, at, velocity, game.weapon_drops.rules.lifetime, false, game.weapon_drops.drop_team(id)))


func _weapon_drop_body(id: int, state: Dictionary, at: Transform3D, velocity: Vector3, seconds: float, rest: bool, team: int = 0) -> PackedByteArray:
	return ArenaWeaponDropEvents.write_weapon_drop(id, ArenaContent.weapon_index(StringName(state["id"])),
		int(state.get("magazine", 0)), int(state.get("reserve", 0)), at, velocity, seconds, rest, team)


func _on_weapon_settled(id: int, at: Transform3D) -> void:
	_send_event(0, ArenaEvents.Kind.WEAPON_SETTLED, ArenaWeaponDropEvents.write_weapon_settled(id, at))


func _on_weapon_gone(id: int, taker: int) -> void:
	_send_event(0, ArenaEvents.Kind.WEAPON_GONE, ArenaEvents.write_taken(id, taker))


## Client side: applies one WEAPON_DROP, WEAPON_SETTLED or WEAPON_GONE event to the mirror.
func _apply_weapon_drop_event(kind: int, reader: DotNetReader) -> void:
	var layer: DotWeaponDrops = game.weapon_drops
	match kind:
		ArenaEvents.Kind.WEAPON_DROP:
			var wd := ArenaWeaponDropEvents.read_weapon_drop(reader)
			if bool(wd["ok"]) and layer != null:
				layer.mirror_drop(int(wd["id"]), {
					"id": ArenaContent.weapon_at(int(wd["weapon"])), "magazine": int(wd["magazine"]), "reserve": int(wd["reserve"]),
				}, wd["at"], wd["velocity"], float(wd["seconds"]), bool(wd["rest"]), int(wd["team"]))
		ArenaEvents.Kind.WEAPON_SETTLED:
			var ws := ArenaWeaponDropEvents.read_weapon_settled(reader)
			if bool(ws["ok"]) and layer != null:
				layer.mirror_settled(int(ws["id"]), ws["at"])
		ArenaEvents.Kind.WEAPON_GONE:
			var wg := ArenaEvents.read_taken(reader)
			if bool(wg["ok"]) and layer != null:
				layer.mirror_removed(int(wg["id"]))


## Follows whichever drops layer the game has and tells every client about each drop and
## each take. Server side, every tick, because a map change builds a new one.
func _watch_drops() -> void:
	if net == null or not net.is_server or game == null:
		return

	var layer: Node = game.drops

	if layer == _watched_drops:
		return

	_watched_drops = layer

	if layer != null:
		layer.dropped.connect(_on_dropped)
		layer.taken.connect(_on_taken)


func _on_dropped(id: int, kind: int, at: Vector3, from: Vector3, value: int) -> void:
	_send_event(0, ArenaEvents.Kind.DROP, ArenaEvents.write_drop(id, kind, value, from, at))


func _on_taken(id: int, taker: int) -> void:
	_send_event(0, ArenaEvents.Kind.TAKEN, ArenaEvents.write_taken(id, taker))
