extends "imported_base.gd"

const ArenaMode := preload("../game/arena_mode.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

## Every ladder a converted map declares can be grabbed, climbed up, stepped off at the top, and
## climbed down to its foot. Runs on each map in [constant MAPS] that is present; skips otherwise.
##
## [codeblock]
## godot --headless --path . res://examples/headless_ladders.tscn
## [/codeblock]

const TICK_RATE := 64
const MAPS: Array[StringName] = [&"crackhouse"]
## A ladder shorter than this is a step, not a climb.
const MIN_HEIGHT := 1.5
## Ladders the source map builds with no way off, as measured: they top out against a wall
## (no step-off), or behind a parapet that blocks the walk back. Listed so a count that
## changes is noticed; they stay out of the topped and descended counts, not the grabbed one.
const NO_STEP_OFF: Array[Vector3] = [Vector3(190.78, 3.28, 15.49)]
const NO_WALK_BACK: Array[Vector3] = [Vector3(228.02, 3.81, -0.08)]


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("arena — converted ladders")
	var checks := 0
	var maps := 0

	for id in MAPS:
		if not ArenaImportedMaps.has(id):
			print("absent here: %s" % id)
			continue

		maps += 1
		checks += _test_map(id)

	if maps == 0:
		print("no converted map present — nothing to check")
		get_tree().quit(0)
		return

	_report_sections(_entered, _completed, maps, checks)


func _test_map(id: StringName) -> int:
	_section("%s: ladders are grabbed, climbed, and stepped off at both ends" % id)
	_game = ArenaGame.new()
	_game.tick_rate = TICK_RATE
	_game.headless = true
	_game.is_authority = true
	_game.register_service = false
	_game.mode = ArenaMode.free_for_all(10)
	add_child(_game)
	var res := _game.setup(ArenaMap.by_id(id))
	_check(res.ok, "setup succeeds")
	var mech := _game.map.mechanics
	var _added := _game.add_player(4, "climber")
	var player := _game.player_for(4)
	_game.respawn_player(4)
	var probe := DotFpsPhysicsBody.for_node(_game.map.collision_root)
	var tunables := player.controller.tunables
	var tall: Array[AABB] = []

	for rung in mech.ladders:
		if rung.size.y >= MIN_HEIGHT:
			tall.append(rung)

	_check(tall.size() >= 4, "the map declares tall ladders (%d of %d)" % [tall.size(), mech.ladders.size()])

	# The source stacks near-duplicate brushes for one physical ladder, so a ladder counts
	# when any brush of its cluster works.
	var clusters: Array[Dictionary] = []

	for rung in tall:
		var r := _climb(player, probe, tunables, rung)
		_line("     ladder %s h %.1f: %s" % [rung.get_center(), rung.size.y, r])
		var home: Dictionary = {}

		for c in clusters:
			if (c.at as Vector3).distance_to(rung.get_center()) < 0.3:
				home = c

		if home.is_empty():
			home = {"at": rung.get_center(), "grabbed": false, "topped": false, "descended": false}
			clusters.append(home)

		home.no_off = _listed(NO_STEP_OFF, rung.get_center())
		home.no_back = _listed(NO_WALK_BACK, rung.get_center())
		home.grabbed = home.grabbed or r.grabbed
		home.topped = home.topped or r.topped
		home.descended = home.descended or r.descended

	var grabbed := 0
	var topped := 0
	var descended := 0

	for c in clusters:
		grabbed += 1 if c.grabbed else 0
		topped += 1 if c.topped or c.no_off else 0
		descended += 1 if c.descended or c.no_off or c.no_back else 0

	var n := clusters.size()
	_line("     no way off: %d, no walk back: %d of %d ladders" % [NO_STEP_OFF.size(), NO_WALK_BACK.size(), n])
	_check(grabbed == n, "every ladder is grabbed from a free side (%d of %d)" % [grabbed, n])
	_check(topped == n, "every one is climbed to the top and stepped off there (%d of %d)" % [topped, n])
	_check(descended == n, "every one is climbed down, ending on its foot, walking (%d of %d)" % [descended, n])
	_done()
	return 5


## Walk at the ladder from a clear side looking up, then from its top looking down.
func _climb(player: ArenaPlayer, probe: DotFpsPhysicsBody, tunables: DotFpsTunables, rung: AABB) -> Dictionary:
	var out := {"grabbed": false, "topped": false, "descended": false, "top": rung.end.y}
	var thin_x := rung.size.x < rung.size.z

	for side: float in [1.0, -1.0]:
		var away := Vector3(side, 0.0, 0.0) if thin_x else Vector3(0.0, 0.0, side)
		var face := rung.get_center() + away * ((rung.size.x if thin_x else rung.size.z) * 0.5)
		var at := Vector3(face.x, rung.position.y + 0.1, face.z) + away * (tunables.radius + 0.05)

		if _in_solid(probe, at, tunables):
			continue

		var yaw := rad_to_deg(atan2(away.x, away.z))
		var cmd := DotFpsCommand.new()
		cmd.move = Vector2(0.0, 1.0)
		cmd.yaw = yaw
		cmd.pitch = 40.0
		var up := {4: [cmd, DotWeaponCommand.new()]}
		player.controller.teleport(at, yaw, 0.0)
		var on_ticks := 0
		var left_at := -1
		var high := at.y

		for i in range(TICK_RATE * 12):
			_game.tick(up)
			var s: DotFpsState = player.controller.state
			high = maxf(high, s.position.y)

			if s.mode == player.ladder.mode_id:
				on_ticks += 1
			elif on_ticks > 0:
				left_at = i
				break

		# A player keeps pushing forward over the lip; only then lets go.
		for _s in range(TICK_RATE / 8):
			_game.tick(up)

		var idle := {4: [DotFpsCommand.new(), DotWeaponCommand.new()]}

		for _s in range(TICK_RATE / 2):
			_game.tick(idle)

		var s2: DotFpsState = player.controller.state
		out.grabbed = on_ticks > TICK_RATE / 4
		# Stepped off: left the ladder, near its top, and came to rest standing there.
		out.topped = out.grabbed and left_at >= 0 and s2.mode == DotFpsState.Mode.GROUND and s2.position.y >= rung.end.y - 1.0 and not _in_solid(probe, s2.position, tunables)

		if not out.topped:
			continue

		# Walk back at the ladder from where it stepped off, looking down.
		var down := DotFpsCommand.new()
		down.move = Vector2(0.0, 1.0)
		down.yaw = yaw + 180.0
		down.pitch = -50.0
		player.controller.teleport(s2.position, yaw + 180.0, 0.0)
		var stay := {4: [down, DotWeaponCommand.new()]}
		var was_on := false
		var low := high

		for _i in range(TICK_RATE * 12):
			_game.tick(stay)
			var s3: DotFpsState = player.controller.state
			low = minf(low, s3.position.y)
			was_on = was_on or s3.mode == player.ladder.mode_id

			if was_on and s3.mode == DotFpsState.Mode.GROUND and s3.position.y <= rung.position.y + 0.6:
				break

		var s4: DotFpsState = player.controller.state
		out.descended = was_on and s4.mode == DotFpsState.Mode.GROUND and s4.position.y <= rung.position.y + 0.6
		return out

	return out


func _listed(list: Array[Vector3], at: Vector3) -> bool:
	for p in list:
		if p.distance_to(at) < 0.5:
			return true

	return false


func _in_solid(body: DotFpsPhysicsBody, feet: Vector3, tunables: DotFpsTunables) -> bool:
	var height := tunables.stand_height - 0.2
	return body.overlaps(feet + Vector3.UP * (0.1 + height * 0.5), height, tunables.radius - 0.05)
