extends RefCounted

## Shots fired against damage applied, per shooter: the debug counter behind "the bots shoot at me and I
## take nothing". Every shot the combat resolves (or refuses) is filed under its attacker:
##
## [codeblock]
## fired        shots handed to the combat (resolved + refused)
## damaged      shots that took health or armour from somebody
## refused      shots the combat turned away before tracing (rate limit, shooter dead)
## prevented    shots that struck a body whose damage was refused (spawn protection, friendly fire, ...)
## miss_aim     shots that hit nothing and passed more than BODY_RADIUS from every other player
## miss_blocked shots that stopped on the level short of a player the ray was on line with
## miss_on_line shots that hit nothing yet were on line with a player and nothing stood between: the bug class
## [/codeblock]
##
## Read with [method report] (one line per shooter). Costs one signal call per shot; bots and players alike.

## Metres from a player's body axis that still counts as "on line" for the miss classes (the hull is about 0.4).
const BODY_RADIUS := 0.3

## Chest height above the feet used for the on-line test, metres.
const BODY_HEIGHT := 1.0

const KEEP := 32

## Reason -> count, for refused shots and prevented damage.
var refusals: Dictionary = {}

## attacker id -> {fired, damaged, refused, prevented, miss_aim, miss_blocked, miss_on_line}
var by_shooter: Dictionary = {}

## The last KEEP shots that were on line and still hit nothing.
var on_line_log: Array[Dictionary] = []

var _game: Object = null


## Starts counting what [param game]'s combat resolves. Call after the combat is built.
func attach(game: Object) -> void:
	_game = game
	var combat: Object = game.get("combat")
	if combat == null:
		return
	if not combat.is_connected(&"shot_resolved", _on_resolved):
		combat.connect(&"shot_resolved", _on_resolved)
		combat.connect(&"shot_refused", _on_refused)


func reset() -> void:
	by_shooter.clear()
	refusals.clear()
	on_line_log.clear()


func row(attacker: int) -> Dictionary:
	if not by_shooter.has(attacker):
		by_shooter[attacker] = {
			"fired": 0, "damaged": 0, "refused": 0, "prevented": 0,
			"miss_aim": 0, "miss_blocked": 0, "miss_on_line": 0,
		}
	return by_shooter[attacker]


func _on_refused(shot: DotShot, reason: String) -> void:
	var r := row(shot.attacker)
	r["fired"] += 1
	r["refused"] += 1
	refusals["shot: " + reason] = int(refusals.get("shot: " + reason, 0)) + 1


func _on_resolved(shot: DotShot) -> void:
	var r := row(shot.attacker)
	r["fired"] += 1
	var applied := false
	var prevented := false
	for damage: DotDamage in shot.damages:
		if damage.refused:
			prevented = true
			var key := "damage: " + str(damage.refusal)
			refusals[key] = int(refusals.get(key, 0)) + 1
		elif damage.health_lost + damage.armour_absorbed > 0.0:
			applied = true
	if applied:
		r["damaged"] += 1
	elif prevented:
		r["prevented"] += 1
	else:
		_classify_miss(shot, r)


## Why a shot that touched nobody touched nobody: aimed off, stopped by the level, or (the bug class) on line.
func _classify_miss(shot: DotShot, r: Dictionary) -> void:
	var dir: Vector3 = shot.direction
	var impact_t := INF
	if not shot.impacts.is_empty():
		impact_t = shot.origin.distance_to(shot.impacts[0])
	var best_lateral := INF
	var best_t := 0.0
	var best_id := 0
	if _game != null and is_instance_valid(_game):
		for id in _game.player_ids():
			if id == shot.attacker:
				continue
			var p: Node3D = _game.player_for(id)
			if p == null or not p.is_alive():
				continue
			var v: Vector3 = p.global_position + Vector3.UP * BODY_HEIGHT - shot.origin
			var t := v.dot(dir)
			if t <= 0.0:
				continue
			var lateral := (v - dir * t).length()
			if lateral < best_lateral:
				best_lateral = lateral
				best_t = t
				best_id = id
	if best_lateral > BODY_RADIUS:
		r["miss_aim"] += 1
	elif impact_t < best_t - BODY_RADIUS:
		r["miss_blocked"] += 1
	else:
		r["miss_on_line"] += 1
		on_line_log.append({"attacker": shot.attacker, "tick": shot.tick, "victim": best_id,
			"lateral": best_lateral, "distance": best_t, "impact": impact_t})
		if on_line_log.size() > KEEP:
			on_line_log.pop_front()


## Totals over every shooter (or only [param ids] when given).
func total(ids: Array = []) -> Dictionary:
	var out := {"fired": 0, "damaged": 0, "refused": 0, "prevented": 0, "miss_aim": 0, "miss_blocked": 0, "miss_on_line": 0}
	for id in by_shooter:
		if not ids.is_empty() and not ids.has(id):
			continue
		for k in out:
			out[k] += int(by_shooter[id][k])
	return out


## One line per shooter that fired, busiest first, then the refusal reasons and the last on-line misses.
func report(limit: int = 40) -> String:
	var ids: Array = by_shooter.keys()
	ids.sort_custom(func(a: int, b: int) -> bool: return by_shooter[a]["fired"] > by_shooter[b]["fired"])
	var lines: PackedStringArray = []
	var t := total()
	lines.append("shots: fired %d damaged %d (%.0f%%) prevented %d refused %d | misses: aim %d blocked %d on_line %d" % [
		t["fired"], t["damaged"], 100.0 * float(t["damaged"]) / maxf(float(t["fired"]), 1.0),
		t["prevented"], t["refused"], t["miss_aim"], t["miss_blocked"], t["miss_on_line"]])
	for id: int in ids.slice(0, limit):
		var r: Dictionary = by_shooter[id]
		lines.append("  #%d: fired %d damaged %d prevented %d refused %d aim %d blocked %d on_line %d" % [
			id, r["fired"], r["damaged"], r["prevented"], r["refused"], r["miss_aim"], r["miss_blocked"], r["miss_on_line"]])
	for reason: String in refusals:
		lines.append("  reason %s x%d" % [reason, refusals[reason]])
	for entry in on_line_log.slice(maxi(on_line_log.size() - 5, 0)):
		lines.append("  on-line miss: %s" % str(entry))
	return "\n".join(lines)
