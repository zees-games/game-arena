extends "headless_imported_b2.gd"

const ArenaContent := preload("../game/arena_content.gd")


## The map whose hurt volumes are checked: MAP has none.
const HURT_MAP := &"surf_xiv_v2a"


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


## `-- --shard rest` plays everything but the two per-map loops; `-- --shard mapsN` (N of MAP_SHARDS) plays those two over every
## MAP_SHARDS-th imported map; `-- --merge LOG...` only holds that every shard's log is there (each shard fails on its own).
const MAP_SHARDS := 4

var _shard := ""
var _merging := false

## What the two per-map loops add to the whole run's totals: two sections, and two fixed checks in the first beside one audit check per map.
const LOOP_SECTIONS := 2
const LOOP_FIXED_CHECKS := 2


func _expected_sections() -> int:
	if _merging:
		return 1
	if _shard == "rest":
		return SECTIONS - LOOP_SECTIONS
	return LOOP_SECTIONS if _shard.begins_with("maps") else SECTIONS


func _expected_checks() -> int:
	if _merging:
		return 1
	if _shard == "rest":
		return CHECKS_FIXED - LOOP_FIXED_CHECKS
	if _shard.begins_with("maps"):
		return LOOP_FIXED_CHECKS + _map_ids().size()
	return super()


## The imported maps this run covers: all of them, or this shard's every MAP_SHARDS-th.
func _map_ids() -> Array:
	var all: Array = ArenaMap.imported_ids()
	if not _shard.begins_with("maps"):
		return all
	var out := []
	for i in all.size():
		if i % MAP_SHARDS == int(_shard.trim_prefix("maps")):
			out.append(all[i])
	return out


func _run() -> void:
	_line("arena — imported combat surf maps")
	_line("")

	if DotGameShardArgs.is_merge():
		_merging = true
		_section("the shards' logs")
		var logs := DotGameShardArgs.merge_logs()
		var missing := DotGameShardArgs.missing(logs)
		_check(not logs.is_empty() and missing.is_empty(), "every shard's log is there (%d logs)" % logs.size(), "missing %s" % [missing])
		_done()
		_finish()
		return
	_shard = DotGameShardArgs.shard()

	if ArenaMap.imported_ids().is_empty():
		_line("no imported maps under %s — nothing to check" % ArenaImportedMaps.roots()[0])
		_line("  link arena-surf-dm-maps: dot-bootstrap/bootstrap.sh --links game-arena")
		get_tree().quit(0)
		return

	# The legacy meshes are what the probes below read; _test_worlds turns the worlds on for itself.
	ArenaMap.use_worlds = false
	if _shard.begins_with("maps"):
		await _test_every_map()
		await _test_collision_audit()
		_finish()
		return
	_test_catalogue()
	_test_lighting()
	_test_worlds()
	_test_prop_visuals()

	if not await _test_loads():
		_finish()
		return

	await _run_part2()


func _run_part2() -> void:
	# `-- --rides`: only the recorded rides, for working on them (the suite's own totals then do not hold);
	# `-- --record-edge=N` records surf_ski_2's edge N instead of RECORD_EDGES, `-- --ride-rate=N` rides at N Hz.
	if OS.get_cmdline_user_args().has("--rides"):
		var only: Array = RECORD_EDGES
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--record-edge="):
				only = [int(arg.trim_prefix("--record-edge="))]
		# `-- --prior=a,b`: those sections run first, to find which one leaves state behind for the rides.
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--prior="):
				for name in arg.trim_prefix("--prior=").split(","):
					await call("_test_" + name)
		for record_edge: int in only:
			await _test_recorded_rides(record_edge)
		get_tree().quit(1 if _failed > 0 else 0)
		return

	# `-- --fallout=<map id>`: only the faller walk-off check, on that map (the suite's own totals then do not hold).
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--fallout="):
			_fallout_only = arg.trim_prefix("--fallout=")
			await _test_fallout_all()
			get_tree().quit(1 if _failed > 0 else 0)
			return

	# `-- --band`: only the bots' band, for measuring it (the suite's own totals then do not hold).
	if OS.get_cmdline_user_args().has("--band"):
		await _test_bot_band()
		get_tree().quit(1 if _failed > 0 else 0)
		return

	# `-- --rotation [--rotation-seed=N]`: only the rotation's rides, their perturbed starts drawn from seed N
	# (ROTATION_RIDE_SEED by default), for measuring how often an edge lands (the suite's own totals then do not hold).
	if OS.get_cmdline_user_args().has("--rotation"):
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--rotation-seed="):
				_rotation_seed = int(arg.trim_prefix("--rotation-seed="))
		await _test_rotation_rides()
		get_tree().quit(1 if _failed > 0 else 0)
		return

	await _test_spawns_on_the_floor()
	await _test_deathmatch()
	await _test_bot_routes()
	_test_surf_movement()
	_test_ramp()
	_test_pits()
	_test_jail()
	_test_shots()
	_test_mechanics()
	await _test_hurt()
	await _test_surf_rides()
	await _test_fallout()
	await _test_fallout_all()
	await _test_rotation_rides()
	await _test_bot_band()
	for record_edge: int in RECORD_EDGES:
		await _test_recorded_rides(record_edge)
	if _shard == "":
		await _test_every_map()
		await _test_collision_audit()
	await _test_packs()
	await _test_server_named()

	_finish()


# --- Shots ---------------------------------------------------------------------

func _test_shots() -> void:
	_section("shots stop at the map's walls")

	var trace := _game.combat.trace
	var spawn: Transform3D = _game.map.spawns[0]
	var eye := spawn.origin + Vector3.UP * 1.6
	var blocked := 0
	var nearest := INF

	# Eight directions out of a spawn room: a room has walls, and a trace that hit none of
	# them would be one passing through the map.
	for i in range(8):
		var angle := TAU * float(i) / 8.0
		var hit := trace.ray(eye, Vector3(sin(angle), 0.0, cos(angle)), 200.0)

		if hit.blocked:
			blocked += 1
			nearest = minf(nearest, hit.distance)

	_check(blocked >= 6, "a shot out of the spawn room hits a wall in %d of 8 directions" % blocked)
	_check(trace.ray(eye, Vector3.DOWN, 5.0).blocked, "and the floor under the spawn")
	_check_sight_ray(trace, eye)

	_done()


## The bots' sight ray (one ray query: no Hit, no material lookup) answers as the trace's own line_of_sight,
## on 200 seeded rays around the spawn.
func _check_sight_ray(trace: DotTrace, eye: Vector3) -> void:
	var world := ArenaBots.world_for(_game)
	var fast := trace is DotTracePhysics and ArenaBots.World._plain_sight_trace(trace)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5197
	var same := 0
	var blocked := 0
	for i in 200:
		var from := eye + Vector3(rng.randf_range(-12.0, 12.0), rng.randf_range(-1.0, 2.0), rng.randf_range(-12.0, 12.0))
		var to := eye + Vector3(rng.randf_range(-30.0, 30.0), rng.randf_range(-1.0, 3.0), rng.randf_range(-30.0, 30.0))
		var want := trace.line_of_sight(from, to)
		if fast and world._sight_ray(trace as DotTracePhysics, from, to) == want:
			same += 1
		if not want:
			blocked += 1
	_check(fast and same == 200 and blocked > 0 and blocked < 200, "the bots' sight ray answers as the trace's line_of_sight",
		"fast %s, %d of 200 the same, %d blocked" % [fast, same, blocked])


# --- The map's mechanics ------------------------------------------------------------

func _test_mechanics() -> void:
	_section("the map's own mechanics run: a booster, water, a ladder")

	var mech := _game.map.mechanics
	_check(mech != null and not mech.pushes.is_empty() and not mech.water.is_empty()
		and not mech.ladders.is_empty(),
		"the manifest's mechanics are read (%s)" % (mech.describe_lines()[0] if mech != null else "none"))

	if mech == null:
		for _i in range(5):
			_check(false, "so nothing could run")
		_done()
		return

	var player := _fresh(4)
	var probe := DotFpsPhysicsBody.for_node(_game.map.collision_root)
	var tunables := player.controller.tunables
	var idle := {4: [DotFpsCommand.new(), DotWeaponCommand.new()]}

	# A booster: the strongest sideways push lying on a floor. Stood on, it carries the
	# player along it and, on leaving, throws them on at its speed.
	var booster := {}
	for p: Dictionary in mech.pushes:
		var push: Vector3 = p["push"]
		var flat := Vector2(push.x, push.z).length()
		if not p["once"] and (p["box"] as AABB).size.y < 0.5 \
				and flat > Vector2(booster.get("push", Vector3.ZERO).x, booster.get("push", Vector3.ZERO).z).length():
			booster = p
	var box: AABB = booster["box"]
	var speed := (booster["push"] as Vector3).length()
	player.controller.teleport(Vector3(box.get_center().x, box.end.y + 0.02, box.get_center().z), 0.0, 0.0)
	var fastest := 0.0
	for _i in range(TICK_RATE):
		_game.tick(idle)
		fastest = maxf(fastest, player.controller.state.horizontal_speed())
	_line("     booster %.1f m/s at %s: fastest %.1f m/s" % [speed, box.get_center(), fastest])
	_check(fastest > speed * 0.9 and fastest < speed * 1.3,
		"a booster throws a player at its speed (%.1f m/s against %.1f)" % [fastest, speed])

	# Water: the deepest pool with clear water at its middle. A player put in it to the
	# chest swims; pressing nothing they sink, slowly; holding jump they come out of it.
	var pool := AABB()
	var feet := Vector3.ZERO
	var depth := player.swim.waist + 0.3
	# Most of these maps' water is a sheet a few centimetres deep over a pit; the pool is
	# the deepest one a player can be in to the waist, at a spot in it clear of solid.
	for w in mech.water:
		if w.size.x < 3.0 or w.size.z < 3.0 or w.size.y < 1.5 or w.size.y <= pool.size.y:
			continue
		for i in range(1, 8):
			for j in range(1, 8):
				var at := Vector3(w.position.x + w.size.x * i / 8.0, w.end.y - depth,
					w.position.z + w.size.z * j / 8.0)
				if not _in_solid(probe, at, tunables):
					pool = w
					feet = at
					break
			if pool == w:
				break
	player.controller.teleport(feet, 0.0, 0.0)
	_game.tick(idle)
	var swimming := player.controller.state.mode == player.swim.mode_id
	var top := player.controller.state.position.y
	for _i in range(TICK_RATE / 2):
		_game.tick(idle)
	var sunk := top - player.controller.state.position.y
	var sink_speed := -player.controller.state.velocity.y
	_check(swimming and player.controller.state.mode == player.swim.mode_id,
		"put in water to the chest, the player swims (mode %s)" % player.controller.motor.mode_name(player.controller.state.mode))
	_check(sunk > 0.2 and sunk < 0.9 and sink_speed < 2.0,
		"and pressing nothing sinks, slowly: %.2f m in half a second, %.2f m/s" % [sunk, sink_speed])
	var jump := DotFpsCommand.new()
	jump.set_button(DotFpsCommand.BUTTON_JUMP, true)
	var held := {4: [jump, DotWeaponCommand.new()]}
	var out_at := -1
	for i in range(TICK_RATE * 2):
		_game.tick(held)
		var s := player.controller.state
		if s.mode != player.swim.mode_id and s.position.y + player.swim.waist > pool.end.y:
			out_at = i
			break
	_check(out_at >= 0, "and holding jump comes up out of it (%s)" % (
		"%.2f s" % (float(out_at) / TICK_RATE) if out_at >= 0 else "still in after 2 s"))

	# A ladder: walked into from whichever side is clear, facing it, looking up.
	var climbed := 0.0
	var on_ladder := 0
	var tried := 0
	var best_at := Vector3.ZERO
	var best_climb: Dictionary = {}
	for rung in mech.ladders:
		if rung.size.y < 2.5:
			continue
		var thin_x := rung.size.x < rung.size.z
		for side: float in [1.0, -1.0]:
			var away := Vector3(side, 0.0, 0.0) if thin_x else Vector3(0.0, 0.0, side)
			var face := rung.get_center() + away * ((rung.size.x if thin_x else rung.size.z) * 0.5)
			var at := Vector3(face.x, rung.position.y + 0.3, face.z) + away * (tunables.radius + 0.05)
			if _in_solid(probe, at, tunables):
				continue
			tried += 1
			player.controller.teleport(at, rad_to_deg(atan2(away.x, away.z)), 0.0)
			var climb := DotFpsCommand.new()
			climb.move = Vector2(0.0, 1.0)
			climb.yaw = rad_to_deg(atan2(away.x, away.z))
			climb.pitch = 40.0
			var up := {4: [climb, DotWeaponCommand.new()]}
			var from := at.y
			var on := 0
			var high := from
			for _i in range(TICK_RATE):
				_game.tick(up)
				if player.controller.state.mode == player.ladder.mode_id:
					on += 1
				high = maxf(high, player.controller.state.position.y)
			if high - from > climbed:
				climbed = high - from
				on_ladder = on
				best_at = at
				best_climb = up
		if climbed > 2.0:
			break
	_line("     ladders tried from %d sides: climbed %.2f m, %d ticks on" % [tried, climbed, on_ladder])
	_check(on_ladder > TICK_RATE / 2 and climbed > 2.0,
		"a ladder is climbed: %.2f m up it in a second, %d ticks on it" % [climbed, on_ladder])

	# A replay of the ticks before a jump-off: the mode's jump-off tick is still the later
	# one, and a prediction replaying an earlier tick must take the ladder as the server
	# did then. Armed by counting the gap without the `since >= 0`.
	var grabbed := false
	if not best_climb.is_empty():
		player.controller.teleport(best_at, 0.0, 0.0)
		player.controller.state.mode = DotFpsState.Mode.AIR
		player.ladder._jumped_off_tick = player.ladder.now + 6
		for _i in range(4):
			_game.tick(best_climb)
			grabbed = grabbed or player.controller.state.mode == player.ladder.mode_id
		player.ladder._jumped_off_tick = -1000
	_check(grabbed, "a replayed tick before a jump-off still takes the ladder")

	_done()


func _test_hurt() -> void:
	_section("a hurt volume hurts through dot-combat, kills as the world, and heals")

	var changed := _game.change_map(ArenaMap.by_id(HURT_MAP))
	var mech := _game.map.mechanics if changed.ok else null

	var picked := _pick_hurt_volumes(mech)
	var hurts: Dictionary = picked[0]
	var heals: Dictionary = picked[1]

	_check(not hurts.is_empty() and not heals.is_empty(),
		"on %s, a hurt volume and a healing one clear of its teleports (%d volumes)" % [
			HURT_MAP, mech.hurt.size() if mech != null else 0])

	if hurts.is_empty() or heals.is_empty():
		for _i in range(5):
			_check(false, "so nothing could hurt")
		_done()
		return

	_game.match_node.rules.warmup_sec = 0.0
	_game.freeze_sec = 0.0
	_game.match_node.rules.countdown_sec = 0.0
	var player := _fresh(5)
	var idle := {5: [DotFpsCommand.new(), DotWeaponCommand.new()]}
	# Past the spawn protection the map change gave everybody: this is about the hurt.
	await _ticks(_game.match_node.spawn_protection_ticks() + 2)

	var dealt: Array[DotDamage] = []
	var on_damage := func(d: DotDamage) -> void:
		if d.victim == 5:
			dealt.append(d)
	_game.combat.damage_applied.connect(on_damage)
	var feed: Array[DotKillFeed.Entry] = []
	var on_kill := func(e: DotKillFeed.Entry) -> void:
		if e.victim_key == "5":
			feed.append(e)
	_game.player_killed.connect(on_kill)

	var per_second := float(hurts["damage"])
	var pulse := per_second * ArenaMap.ArenaMapMechanics.HURT_INTERVAL
	var before := player.health.health
	_stand_in(player, hurts["box"])
	_game.tick(idle)
	var first := before - player.health.health
	_check(player.is_alive() and is_equal_approx(first, pulse),
		"stepping into a %.0f-a-second volume takes %.0f at once (%.1f, %.0f left)" % [
			per_second, pulse, first, player.health.health])
	_check(dealt.size() == 1 and dealt[0].attacker == 0 and dealt[0].type != null
		and dealt[0].type.id == ArenaContent.DAMAGE_WORLD,
		"through dot-combat, as world damage (%d events, attacker %d, type %s)" % [
			dealt.size(), dealt[0].attacker if not dealt.is_empty() else -1,
			dealt[0].type.id if not dealt.is_empty() and dealt[0].type != null else &"?"])

	# Out of it for a tick and straight back in takes nothing new: the half second is the
	# volume's, not restarted by leaving it (a hop or a bob across a thin sheet's edge was a
	# full pulse every re-entry). Armed by erasing the due tick on leaving.
	player.controller.teleport(_game.map.spawns[0].origin, 0.0, 0.0)
	_game.tick(idle)
	_stand_in(player, hurts["box"])
	_game.tick(idle)
	_check(is_equal_approx(before - player.health.health, pulse),
		"stepping out and back in a tick later takes no second pulse (%.0f off in all)" % [
			before - player.health.health])

	# The next pulse is half a second on, and not a tick sooner: then a second one, which
	# from a full 100 at 50 a pulse is the death.
	var interval := roundi(ArenaMap.ArenaMapMechanics.HURT_INTERVAL * TICK_RATE)
	for _i in range(interval - 3):
		_game.tick(idle)
	var held := player.health.health
	_game.tick(idle)
	_line("     %.0f/s: %.0f off at once, %.0f left half a second less a tick later, then %s" % [
		per_second, first, held, "dead" if not player.is_alive() else "%.0f" % player.health.health])
	_check(is_equal_approx(held, before - pulse) and (
			not player.is_alive() or is_equal_approx(player.health.health, before - pulse * 2.0)),
		"the next pulse lands half a second later and not a tick sooner (%.0f, then %.0f)" % [
			held, player.health.health])
	_check(feed.size() == (0 if player.is_alive() else 1) and (feed.is_empty() or feed[0].killer_key == ""),
		"and a death in it is the world's in the kill feed (%d entries, killer \"%s\")" % [
			feed.size(), feed[0].killer_key if not feed.is_empty() else "-"])

	# A negative amount heals: hurt once, out of it for a tick, into the healing volume.
	_game.respawn_player(5)
	await _ticks(_game.match_node.spawn_protection_ticks() + 2)
	player = _fresh(5)
	_stand_in(player, hurts["box"])
	_game.tick(idle)
	var hurt_to := player.health.health
	player.controller.teleport(_game.map.spawns[0].origin, 0.0, 0.0)
	_game.tick(idle)
	_stand_in(player, heals["box"])
	_game.tick(idle)
	var healed := player.health.health - hurt_to
	_check(is_equal_approx(healed, -float(heals["damage"]) * ArenaMap.ArenaMapMechanics.HURT_INTERVAL),
		"a volume of %.0f a second heals %.1f a pulse (%.1f)" % [
			float(heals["damage"]), -float(heals["damage"]) * 0.5, healed])

	_game.combat.damage_applied.disconnect(on_damage)
	_game.player_killed.disconnect(on_kill)
	_done()


## Puts [param player] standing on the top of [param box], in the middle of it.
func _stand_in(player: ArenaPlayer, box: AABB) -> void:
	player.controller.teleport(Vector3(box.get_center().x, box.end.y + 0.02, box.get_center().z), 0.0, 0.0)


# --- Every map -------------------------------------------------------------------

func _test_every_map() -> void:
	_section("every combat surf map builds and puts its spawns on a floor")

	var built := 0
	var bad: Array[String] = []
	var report: Array[String] = []

	for id in _map_ids():
		var map := ArenaMap.by_id(id)
		var solid := map.to_collision()
		add_child(solid)
		map.collision_root = solid
		await get_tree().physics_frame

		if solid.get_child_count() > 0:
			built += 1

		var body := map.movement_body() as DotFpsPhysicsBody
		# Its own collision layer, and the body asks only that one. The game from the
		# earlier sections still has its map loaded in this same physics world, and a
		# spawn of the map under test standing where that map has a wall was counted
		# stuck: surf_akai_final, 24 of 32, and none when checked on its own (2026-10-09).
		if solid is CollisionObject3D:
			(solid as CollisionObject3D).collision_layer = ISOLATED_LAYER
		# Glass the importer split onto its own layers is still a floor to this map's rays.
		for hull in solid.find_children("*", "StaticBody3D", true, false):
			if String((hull as Node).get_meta(&"hull_kind", "")).begins_with("glass"):
				(hull as StaticBody3D).collision_layer |= ISOLATED_LAYER
		body.collision_mask = ISOLATED_LAYER
		var trace := map.shot_trace()
		if "collision_mask" in trace:
			trace.set("collision_mask", ISOLATED_LAYER)
		var tunables := ArenaPlayer.arena_tunables()
		var floored := 0
		var stuck := 0
		# What the game does at load, so what is checked is what a player is put on.
		var lifted := map.settle_spawns(body, tunables)

		for at in map.spawns:
			if trace.ray(at.origin + Vector3.UP * 0.5, Vector3.DOWN, 3.0).blocked:
				floored += 1

			if _in_solid(body, at.origin, tunables):
				stuck += 1

		report.append("%s %d/%d spawns floored, %d spawns and destinations lifted out of solid, %d still in it" % [
			id, floored, map.spawns.size(), lifted, stuck
		])

		# Most, not all: a mapper's spawn can be a few units off the floor or in a wall, and
		# dot-spawn's director only ever needs enough good ones. Half bad is a broken import.
		if map.spawns.size() < 8 or floored * 4 < map.spawns.size() * 3 or stuck * 4 > map.spawns.size():
			bad.append(String(id))

		remove_child(solid)
		solid.free()

	for line in report:
		_line("     " + line)

	_check(built == _map_ids().size(),
		"every one builds a solid (%d of %d)" % [built, _map_ids().size()])
	_check(bad.is_empty(), "and three in four of its spawns stand on a floor, clear of solid (%s fail)" % [bad])

	_done()


## dot-core's [DotCollisionAudit] over every imported map as a client draws it (the drawn brushes
## beside the collision the game builds): geometry with no shape near it is a wall a player
## walks into. Fails on any finding; what is meant to be walked through is opted out in
## `arena_bsp_map.gd` with the reason.
func _test_collision_audit() -> void:
	_section("every imported map: nothing drawn is walked through")

	for id in _map_ids():
		var map := ArenaMap.by_id(id)
		var world := Node3D.new()
		world.add_child(map.to_scene())
		world.add_child(map.to_collision())
		add_child(world)

		var res := DotCollisionAudit.audit(world, true)
		var found := 0
		var examined := 0

		if res.ok:
			var report: DotCollisionAudit = res.value
			found = report.count()
			examined = report.examined
			_line("     %s: %d findings of %d examined" % [id, found, examined])

			for line in report.describe_lines().slice(1, 12):
				_line("       %s" % line)

		_check(res.ok and found == 0 and examined > 0, "%s: nothing drawn is walked through%s" % [id, "" if res.ok else " (" + res.error.message + ")"])
		world.queue_free()
		await get_tree().physics_frame

	_done()


# --- Plumbing ------------------------------------------------------------------

## Whether a standing hull with its feet at [param feet] is inside solid.
##
## The query's capsule is placed by its CENTRE, so it is lifted half a height; and it is
## a little shorter and thinner than the player's, because a hull resting on a floor or
## against a wall touches it, and "touching" is not "inside".
## The physics layer [method _test_every_map] puts each map on, which nothing else uses.
const ISOLATED_LAYER := 1 << 19


## The largest hurting volume and a healing one, clear of the map's teleports: a hurt sheet
## over a pit sends the player away before a second pulse can land.
func _pick_hurt_volumes(mech: Variant) -> Array[Dictionary]:
	var hurts: Dictionary = {}
	var heals: Dictionary = {}
	if mech != null:
		for h: Dictionary in mech.hurt:
			var box: AABB = h["box"]
			var amount := float(h["damage"])
			var over_pit := false
			for pit in _game.map.pits:
				if (pit["box"] as AABB).intersects(box):
					over_pit = true
			if over_pit:
				continue
			var area := box.size.x * box.size.z
			if amount > 0.0 and amount <= 200.0 and (hurts.is_empty() or area > float(hurts["area"])):
				h["area"] = area
				hurts = h
			if amount < 0.0:
				heals = h
	return [hurts, heals]
