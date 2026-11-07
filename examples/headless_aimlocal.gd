extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaBindings := preload("../game/arena_bindings.gd")

## Local play (the offline ArenaClient) aim test. A scripted still bot at 5, 15 and 30 m, the real client firing
## a held burst from the hip and aimed down the sights, standing and crouched, the crosshair held on the bot's chest
## the way a player who does not fight the recoil holds it. Each shot reports the angle between the CAMERA ray (what
## the crosshair shows, view punch included) and the BULLET ray (the shot the arsenal made, recoil included) and the
## gap between camera and muzzle. The bullet must leave the camera ray with spread (plus the weapon's recoil offset)
## only: a view punch that the bullet does not share is a systematic miss.
##
## [codeblock]
## godot --headless --path . res://examples/headless_aimlocal.tscn
## [/codeblock]

const DISTANCES := [5.0, 15.0, 30.0]
const BURSTS := 4
## Tolerated gap between the camera and the bullet direction on a shot, degrees, past what spread allows.
const MAX_RAY_GAP_EXTRA := 0.25
## Tolerated camera-to-muzzle gap, metres.
const MAX_ORIGIN_GAP := 0.3

var _checks := 0
var _failed := 0
var _shots: Array = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _wait_live(client: Node) -> bool:
	for _i in 2400:
		await get_tree().process_frame
		var p: ArenaPlayer = client.get("player")
		var g: ArenaGame = client.get("game")
		if p != null and g != null and p.is_alive() and g.match_node != null and g.match_node.state == DotMatch.State.LIVE:
			for o in g.players():
				if o != p and o.is_alive():
					return true
	return false


static func angles_to(from: Vector3, to: Vector3) -> Vector2:
	var d := (to - from).normalized()
	return Vector2(rad_to_deg(atan2(-d.x, -d.z)), rad_to_deg(asin(d.y)))


## A spot [param dist] metres from [param at] with a clear line at foot, chest and eye height, or INF.
func _spot_at(space: PhysicsDirectSpaceState3D, at: Vector3, dist: float) -> Vector3:
	for k in 32:
		var dir := Vector3.RIGHT.rotated(Vector3.UP, TAU * float(k) / 32.0)
		var to := at + dir * dist
		var clear := true
		for h in [0.3, 1.0, 1.6]:
			var q := PhysicsRayQueryParameters3D.create(to + Vector3(0.0, h, 0.0), at + Vector3(0.0, h, 0.0), 1)
			if not space.intersect_ray(q).is_empty():
				clear = false
		var floor_q := PhysicsRayQueryParameters3D.create(to + Vector3(0.0, 0.5, 0.0), to - Vector3(0.0, 1.0, 0.0), 1)
		if clear and not space.intersect_ray(floor_q).is_empty():
			return to
	return Vector3.INF


func _stat(values: Array) -> String:
	if values.is_empty():
		return "n/a"
	var sum := 0.0
	var peak := 0.0
	for v in values:
		sum += float(v)
		peak = maxf(peak, absf(float(v)))
	return "mean %.3f max %.3f" % [sum / float(values.size()), peak]


func _run() -> void:
	var client: Node = (load("res://game/arena.tscn") as PackedScene).instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	add_child(client)
	var live: bool = await _wait_live(client)
	_check(live, "the offline match goes live with a bot")
	if not live:
		get_tree().quit(1)
		return
	var g: ArenaGame = client.get("game")
	var me: ArenaPlayer = client.get("player")
	var bot: ArenaPlayer = null
	for o in g.players():
		if o != me and o.is_alive():
			bot = o
	var bots: Dictionary = client.get("_bots")
	for id in bots:
		var b: ArenaPlayer = bots[id]
		b.set_meta(&"bot_scripted", true)
		b.set_meta(&"bot_move", DotFpsCommand.new())
		b.set_meta(&"bot_fire", DotWeaponCommand.new())
	for act in [ArenaBindings.FIRE, ArenaBindings.AIM, ArenaBindings.DUCK]:
		if not InputMap.has_action(act):
			InputMap.add_action(act)
	var _fill := me.arsenal.give(AwWeaponIds.RIFLE)
	var _sel := me.arsenal.select(AwWeaponIds.big_gun_slot(), g.current_tick())
	var sampler = client.get("_sampler")
	var hits: Array = []
	g.hit_confirmed.connect(func(a: int, v: int, _amt: float, _pt: Vector3, _h: bool, _l: bool) -> void:
		if a == me.player_id and v == bot.player_id:
			hits.append(1))
	me.arsenal.used.connect(func(outcome: DotWeaponOutcome) -> void:
		if outcome.shots.is_empty():
			return
		var s: DotShot = outcome.shots[0]
		var cam := me.camera
		var cdir := -cam.global_transform.basis.z
		_shots.append({
			"gap": rad_to_deg(cdir.angle_to(s.direction)),
			"pitch_gap": rad_to_deg(asin(clampf(s.direction.y, -1.0, 1.0)) - asin(clampf(cdir.y, -1.0, 1.0))),
			"origin": cam.global_position.distance_to(s.origin),
			"spread": s.spread,
		}))
	print("weapon: %s" % str(me.arsenal.current_def().id))
	var all_origin: Array = []
	var all_extra: Array = []
	var fired_total := 0
	for d in DISTANCES:
		for crouch in [false, true]:
			for ads in [false, true]:
				var tag := "%.0f m %s %s" % [d, "crouched" if crouch else "standing", "ADS" if ads else "hip"]
				var fired := 0
				var landed := 0
				var gaps: Array = []
				var pitch_gaps: Array = []
				var origins: Array = []
				var extra: Array = []
				var skipped := false
				for burst in BURSTS:
					var space := me.get_world_3d().direct_space_state
					var spot := _spot_at(space, bot.global_position, d)
					if spot == Vector3.INF:
						skipped = true
						break
					me.spawn(Transform3D(Basis(), spot), g.current_tick())
					g.combat.health_of(bot.player_id).health = 100000.0
					if crouch:
						Input.action_press(ArenaBindings.DUCK)
					if ads:
						Input.action_press(ArenaBindings.AIM)
					var a := Vector2.ZERO
					for _i in 140:
						await get_tree().process_frame
						a = angles_to(me.muzzle_position(), bot.global_position + Vector3(0.0, bot.eye_height() * 0.8, 0.0))
						sampler.look_at_angles(a.x, a.y)
					_shots.clear()
					hits.clear()
					Input.action_press(ArenaBindings.FIRE)
					for _i in 24:
						await get_tree().process_frame
						sampler.look_at_angles(a.x, a.y)
					Input.action_release(ArenaBindings.FIRE)
					for _i in 20:
						await get_tree().process_frame
					fired += _shots.size()
					landed += hits.size()
					for s in _shots:
						gaps.append(s.gap)
						pitch_gaps.append(s.pitch_gap)
						origins.append(s.origin)
						extra.append(float(s.gap))
					Input.action_release(ArenaBindings.AIM)
					Input.action_release(ArenaBindings.DUCK)
					for _i in 100:
						await get_tree().process_frame
				if skipped:
					print("  %s: no clear line, skipped" % tag)
					continue
				fired_total += fired
				all_origin.append_array(origins)
				all_extra.append_array(extra)
				print("  %s: %d/%d hit | camera-vs-bullet deg %s | pitch gap (bullet-camera) %s | camera-muzzle m %s | raw gap %s" % [
					tag, landed, fired, _stat(gaps), _stat(pitch_gaps), _stat(origins), _stat(extra)])
	var worst := 0.0
	for e in all_extra:
		worst = maxf(worst, float(e))
	var worst_origin := 0.0
	for o in all_origin:
		worst_origin = maxf(worst_origin, float(o))
	_check(fired_total > 0, "shots were fired and measured", str(fired_total))
	_check(worst <= MAX_RAY_GAP_EXTRA, "the bullet leaves the camera ray (spread is added later, so the gap is recoil follow only: <= %.2f deg)" % MAX_RAY_GAP_EXTRA, "worst %.3f" % worst)
	_check(worst_origin <= MAX_ORIGIN_GAP, "the muzzle sits on the camera (+%.2f m)" % MAX_ORIGIN_GAP, "worst %.3f" % worst_origin)
	client.queue_free()
	var ok := _failed == 0
	print("%d checks, %d failed" % [_checks, _failed])
	get_tree().quit(0 if ok else 1)
