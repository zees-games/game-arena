extends RefCounted

## The server half of the kill view: every player's and bot's eye is recorded each tick into
## dot-replay's [DotKillViewRing], a death cuts the killer's clip, and the victim's respawn is held
## until the clip has played (or the victim skips). The rules are [member ArenaGame.killview_rules].

const ArenaGame := preload("arena_game.gd")
const ArenaPlayer := preload("arena_player.gd")

const CHANNEL := "arena.killview"

## Vertical field of view of the recorded eye: the player camera's default (horizontal 100 at 4:3).
const FOV := 83.6

var game: ArenaGame = null
var ring: DotKillViewRing = null

## session id -> tick the victim's respawn is held to.
var _held: Dictionary = {}


func _init(p_game: ArenaGame) -> void:
	game = p_game
	ring = DotKillViewRing.new(game.killview_rules)


## Notes where every living player and bot looks at [param time] (seconds).
func record(time: float) -> void:
	for p: ArenaPlayer in game.players():
		if not p.is_alive() or p.controller == null or p.controller.state == null:
			continue
		var st: DotFpsState = p.controller.state
		var eye: Vector3 = p.controller.motor.eye_position(st) if p.controller.motor != null else st.position + Vector3(0.0, 1.6, 0.0)
		var basis := Basis.from_euler(Vector3(deg_to_rad(st.pitch), deg_to_rad(st.yaw), 0.0))
		var _noted := ring.record(p.player_id, time, Transform3D(basis, eye), FOV)


func note_kill(killer: int, victim: int, time: float, info: Dictionary) -> DotResult:
	return ring.note_kill(killer, victim, time, info)


## The clips ready at [param time]: [{victim, clip, info}]. Holds each victim's respawn to the end of the clip.
func collect(time: float, tick: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for c: Dictionary in ring.collect(time):
		var clip: Dictionary = c["clip"]
		var flat: PackedFloat32Array = clip.get("f", PackedFloat32Array())
		if flat.is_empty():
			continue
		var span := flat[flat.size() - DotKillViewRing.STRIDE] - flat[0]
		# One extra second: the slow motion around the kill adds that much to the wall time.
		var hold := minf(game.killview_rules.seconds, span + 1.0)
		var victim := int(c["victim"])
		_hold(victim, tick + int(ceil(hold * float(game.tick_rate))))
		out.append({"victim": victim, "clip": clip, "info": clip.get("info", {})})
	return out


## The victim skipped: respawn on this tick, if they are being held and still waiting.
func skip(session: int, tick: int) -> bool:
	if not game.killview_rules.skip_allowed or not _held.has(session) or tick >= int(_held[session]):
		return false
	var respawns: DotRespawnQueue = game.match_node.respawns if game.match_node != null else null
	if respawns == null or not respawns.is_waiting(str(session)):
		_held.erase(session)
		return false
	_held.erase(session)
	return game.respawn_player(session).ok


func forget(session: int) -> void:
	ring.forget(session)
	_held.erase(session)


func _hold(session: int, until: int) -> void:
	var respawns: DotRespawnQueue = game.match_node.respawns if game.match_node != null else null
	if respawns == null or not respawns.is_waiting(str(session)):
		return
	var target := maxi(respawns.ready_tick(str(session)), until)
	respawns.enqueue_at(str(session), target)
	_held[session] = target
