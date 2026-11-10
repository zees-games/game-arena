extends RefCounted

## The shots a killcam replays: where each body's gun stood and pointed the frame its fire count moved,
## kept for the recording window only and capped, so a kill's data is a few kilobytes at most.

## Most shots kept at once (about 72 bytes each, so well under 10 KB), oldest dropped first.
const MAX_SHOTS := 96
## How far from a replayed row's time a recorded shot may sit and still be that row's shot, in seconds.
const MATCH_WINDOW := 0.3
const SEQ_RANGE := 4096

## Where the replay's flash, tracer and spark are drawn from; the client sets it.
var parent: Node = null
## Seconds of shots kept (the recording buffer's window plus a second).
var keep_seconds: float = 9.0
## Newest last: {t, id, origin, dir, serial}.
var shots: Array[Dictionary] = []
var fx: AwShotFx = null
## A body's [feet, yaw, pitch, alive, eye height] row, for a shooter whose gun is not drawn (set by the bodies' hooks).
var state_fn: Callable = Callable()

var _seen: Dictionary = {}
var _serial: int = 0
var _played: Dictionary = {}
var _last_t: float = -INF


## Notes a shot for every body whose fire count moved since the last call. Cheap while nobody fires: two reads a body.
func record(now: float, players: Array) -> void:
	for p: Variant in players:
		if not (p is Node) or not is_instance_valid(p):
			continue
		var seq := _fire_count(p)
		var id: int = int(p.get(&"player_id"))
		var before: int = _seen.get(id, seq)
		_seen[id] = seq
		var fresh := posmod(seq - before, SEQ_RANGE)
		if fresh > 0 and fresh < SEQ_RANGE / 2:
			_note(now, id, p)
	while shots.size() > MAX_SHOTS or (not shots.is_empty() and now - float(shots[0]["t"]) > keep_seconds):
		shots.pop_front()


func _fire_count(p: Node) -> int:
	if bool(p.get(&"mirrored")):
		return int(p.get(&"mirror_fire_seq")) % SEQ_RANGE
	var weapons: Variant = p.get(&"weapons")
	return int(weapons.fire_seq) % SEQ_RANGE if weapons != null else 0


func _note(now: float, id: int, p: Node) -> void:
	var held: Node3D = p.get(&"held")
	var origin := Vector3.ZERO
	var dir := Vector3.ZERO
	var body: Node3D = p.get(&"body_mesh")
	if held != null and held.is_inside_tree() and body != null and body.visible and held.has_method(&"muzzle_transform"):
		origin = (held.call(&"muzzle_transform") as Transform3D).origin
		dir = held.call(&"muzzle_direction")
	else:
		var row: Array = state_fn.call(p) if state_fn.is_valid() else []
		if row.size() < 5:
			return
		var look := Basis.from_euler(Vector3(deg_to_rad(float(row[2])), deg_to_rad(float(row[1])), 0.0))
		origin = (row[0] as Vector3) + Vector3(0.0, float(row[4]), 0.0)
		dir = -look.z
	if not origin.is_finite() or not dir.is_finite() or dir.is_zero_approx():
		return
	_serial += 1
	shots.append({"t": now, "id": id, "origin": origin, "dir": dir.normalized(), "serial": _serial})


## The recorded shot of [param id] nearest [param at] that has not been replayed yet; {} when none was recorded.
func take(id: int, at: float) -> Dictionary:
	if at < _last_t - 0.001:
		_played.clear()
	_last_t = at
	var best := {}
	var best_gap := MATCH_WINDOW
	for s: Dictionary in shots:
		if int(s["id"]) != id or _played.has(s["serial"]):
			continue
		var gap := absf(float(s["t"]) - at)
		if gap <= best_gap:
			best_gap = gap
			best = s
	if not best.is_empty():
		_played[best["serial"]] = true
	return best


## Draws [param shot] as a live shot: the muzzle flash, a tracer to what it hit and a spark there.
func play(shot: Dictionary, p: Node, kind: int) -> void:
	if parent == null or not is_instance_valid(parent) or not parent.is_inside_tree():
		return
	_build_fx()
	fx.exclude_carrier(p)
	var held: Object = p.get(&"held")
	if held != null:
		fx.set(&"sounds", held.get(&"sounds"))
	var dir: Vector3 = shot["dir"]
	var weapon: StringName = held.call(&"equipped") if held != null and held.has_method(&"equipped") else &"rifle"
	fx.play_remote(kind, Transform3D(Basis.looking_at(dir, Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT), shot["origin"]), dir, weapon)


func _build_fx() -> void:
	if fx == null or not is_instance_valid(fx):
		fx = AwShotFx.new()
		fx.name = "KillcamShotFx"
		parent.add_child(fx)


## Builds the replay's flash, tracer and spark pools now (under a loading cover) instead of on the first replayed
## shot, which made them in the middle of a kill view; returns their meshes and materials for the cover to draw.
func warm() -> Array:
	if parent == null or not is_instance_valid(parent) or not parent.is_inside_tree():
		return []
	_build_fx()
	return DotRenderWarmup.collect(fx)


## Forgets everything, for a new match.
func clear() -> void:
	shots.clear()
	_seen.clear()
	_played.clear()
	_last_t = -INF
