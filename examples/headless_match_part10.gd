extends "headless_match_part9.gd"

# --- Monsters --------------------------------------------------------------

## dot-npc, dot-npc-ai and dot-npc-ai-director, over this game's own geometry.
func _test_horde() -> void:
	_section("monsters")

	var catalogue := ArenaNpcs.catalogue()
	_check(catalogue.size() == 4, "four monsters are catalogued: three that close and one that shoots")

	var bad := PackedStringArray()

	for def in catalogue.npcs:
		var valid := def.validate()

		if not valid.ok:
			bad.append("%s: %s" % [String(def.id), valid.error.message])
		elif not ResourceLoader.exists(def.scene_path):
			bad.append("%s has no scene" % String(def.id))
		elif not ResourceLoader.exists(def.brain_script_path):
			bad.append("%s has no brain" % String(def.id))

	_check(bad.is_empty(), "and every one has a scene and a brain that exist", ", ".join(bad))

	# --- Navigation -------------------------------------------------------

	var nav := ArenaNpcs.nav_for(_game.map)
	var nav_ok := nav.validate()
	_check(nav_ok.ok, "navigation generates from the map's boxes", str(nav_ok.error))
	_check(nav.point_count() > 32, "with a usable number of points", "%d" % nav.point_count())
	_check(nav.edge_count() > 0, "and edges between them", "%d" % nav.edge_count())

	# The digest is what tells "a graph for this map" from "a graph for a map with the
	# same name". A graph that matched a map whose geometry moved is a graph whose
	# monsters walk through the walls somebody added since.
	_check(
		nav.matches(ArenaNpcs.digest_of(_game.map)),
		"and it matches the geometry it was built from"
	)

	var other := ArenaMap.by_id(&"dm_atrium" if _game.map.id == &"dm_box" else &"dm_box")
	_check(
		not nav.matches(ArenaNpcs.digest_of(other)),
		"and does not match a different map's"
	)

	# No graph point may have a monster standing in a solid. A generator that put them there would
	# produce paths straight through the pillars, and an NPC walking into a wall is
	# indistinguishable from an NPC with no path at all.
	var inside := 0

	for index in nav.point_count():
		var shins := nav.points[index] + Vector3(0.0, 0.5, 0.0)

		for box in _game.map.boxes:
			if box.has_point(shins):
				inside += 1
				break

	_check(inside == 0, "no navigation point stands inside the level", "%d do" % inside)

	# --- The horde itself -------------------------------------------------

	var horde := ArenaHorde.new()
	horde.name = "Horde"
	horde.game = _game
	# Not to disk: a suite's players must not train the next run's monsters.
	horde.persist_heat = false
	add_child(horde)

	var built := horde.setup()

	if not _check(built.ok, "the horde sets up", str(built.error)):
		horde.queue_free()
		remove_child(horde)
		return

	# Off by default. A deathmatch is a deathmatch; monsters are a mode.
	_check(not horde.enabled, "and spawns nothing until it is turned on")

	horde.tick(1.0 / float(TICK_RATE))
	_check(horde.count() == 0, "which is exactly what a tick with it off does")

	# --- Spawning by hand -------------------------------------------------

	var somewhere := nav.points[nav.point_count() / 2]
	var monster := horde.spawn_one(ArenaNpcs.GRUNT, somewhere)

	if not _check(monster != null, "a monster can be placed"):
		horde.queue_free()
		remove_child(horde)
		return

	_check(monster.brain != null, "and it got its brain from a path")
	_check(
		monster.brain is DotNpcAiBrain and (monster.brain as DotNpcAiBrain).tree != null,
		"which built a behaviour tree"
	)

	# The character is per NPC, seeded from the spawn. Twenty monsters sharing one preset's seed all
	# take the same shot with the same error at the same moment, which reads as a firing squad
	# rather than as a fight.
	var brain := monster.brain as DotNpcAiBrain
	_check(
		brain.character != null and monster.seed > 1 and brain.character.seed_value == monster.seed,
		"and a character seeded from its own spawn",
		"seed %d, character %d" % [monster.seed, brain.character.seed_value if brain.character != null else -1]
	)
	_check(
		monster.seed == horde.spawner.seed_for(1),
		"and that seed is the first spawn's, not the object id's",
		"seed %d, first spawn's %d, instance %d" % [monster.seed, horde.spawner.seed_for(1), monster.instance_id]
	)
	_check(
		brain.squad != null and brain.squad.squad_name == &"horde",
		"and it joins the horde's squad, so only three go at one player at a time"
	)

	# A shot is heard. Every player's fire becomes a COMBAT sound on the horde's board,
	# owned by the shooter, and a monster in earshot notices it on its next think.
	var shooter: ArenaPlayer = null
	for candidate in _game.players():
		if candidate.is_alive():
			shooter = candidate
			break

	if shooter != null:
		horde.note_fire(shooter.player_id, monster.position() + Vector3(6.0, 0.0, 0.0))
		horde.tick(1.0 / float(TICK_RATE))
		_check(
			brain.context.has_condition(DotNpcAiConditions.HEAR_COMBAT),
			"and it hears a player fire"
		)
	else:
		_check(false, "and it hears a player fire", "no living player to shoot")

	# The gunner: same brain, its ranged branch chosen by its definition, and a shot that dot-combat
	# resolves against a real player's hitboxes. A breath first, and a different spot: the horde's
	# limits space spawns a quarter of a second apart, and the grunt is standing on the first one.
	for step in range(TICK_RATE / 2):
		horde.tick(1.0 / float(TICK_RATE))
	var gunner := horde.spawn_one(ArenaNpcs.GUNNER, nav.points[nav.point_count() / 3])
	var gunner_brain := gunner.brain as DotNpcAiBrain if gunner != null else null
	# Per spawn, not per preset: the second monster gets a seed of its own.
	_check(
		gunner != null and gunner.seed > 1 and gunner.seed != monster.seed,
		"and the next monster is seeded differently",
		"grunt %d, gunner %d" % [monster.seed, gunner.seed if gunner != null else -1]
	)
	_check(
		gunner_brain != null and "\n".join(gunner_brain.tree.describe_lines()).contains("ranged"),
		"a gunner builds the ranged branch from its definition"
	)

	# Spawn protection off the target. The match above is over and cycling, so whoever is alive was
	# most likely respawned a moment ago, and a shot at a protected player is refused "invulnerable"
	# whatever it hit — which made this check pass or fail on where the deathmatch happened to end.
	if shooter != null and _game.effects != null:
		_game.effects.remove(ArenaEffects.PROTECTED, shooter.player_id)
		shooter.health.invulnerable_until_tick = -1
		# And the third record of it, dot-spawn's ledger.
		if _game.player_stack != null and _game.player_stack.spawns != null \
				and _game.player_stack.spawns.protection != null:
			_game.player_stack.spawns.protection.revoke(
				str(shooter.player_id), _game.current_tick()
			)

	if shooter != null and gunner != null:
		# From the gunner's own muzzle, four metres from the player toward the middle of the room.
		var body := shooter.controller.state.position
		var inward := Vector3(-body.x, 0.0, -body.z)
		inward = inward.normalized() if inward.length() > 0.1 else Vector3.RIGHT
		# Toward the middle first, then round the player until nothing is in between: where the
		# match left the player is wherever the bots' fight ended, and on dm_box "four metres toward
		# the middle" is sometimes the far side of a box.
		var placed := inward
		for turn in range(12):
			var way := inward.rotated(Vector3.UP, TAU * float(turn) / 12.0)
			if _game.combat.trace.line_of_sight(
				body + way * 4.0 + Vector3(0.0, 1.4, 0.0), body + Vector3(0.0, 1.0, 0.0)
			):
				placed = way
				break
		(gunner.node as Node3D).global_position = body + placed * 4.0
		var muzzle := gunner.position() + Vector3(0.0, 1.4, 0.0)
		_game.combat.set_authoritative_origin(horde.entity_id_for(gunner), muzzle)
		var shot: DotShot = horde.npc_shoot(gunner, muzzle, body + Vector3(0.0, 1.0, 0.0), 6.0)
		_check(shot != null and shot.hit_anyone(), "and its shot hits a player through dot-combat",
			("impact %s, player state %s, hitboxes %s, damages %s" % [
				str(shot.impacts), str(body), str(shooter.hitboxes.global_position),
				str(shot.damages.map(func(d: DotDamage) -> String: return d.refusal if d.refused else "landed"))
			]) if shot != null else "no shot")
	else:
		_check(false, "and its shot hits a player through dot-combat", "no gunner or no player")

	# --- The id space -----------------------------------------------------

	# A lookup now, not a static formula: the id comes out of the game's table, which
	# is what stopped two monsters a million instance ids apart from sharing one.
	var entity := horde.entity_id_for(monster)
	_check(
		ArenaHorde.is_npc_entity(entity),
		"a monster's combat entity id says it names a monster",
		DotEntity.describe_id(entity)
	)
	_check(
		DotEntity.is_kind(entity, DotEntity.KIND_NPC),
		"which is a kind carried in the id, not a range it falls in"
	)

	var clashes := PackedStringArray()

	for player in _game.players():
		if ArenaHorde.is_npc_entity(player.player_id):
			clashes.append(str(player.player_id))

	_check(
		clashes.is_empty(),
		"and no player id is in it",
		", ".join(clashes)
	)

	# The property the old scheme did not have.
	var ids := {}
	var duplicated := PackedStringArray()

	for alive_npc in horde.spawner.all_npcs():
		var other_entity := horde.entity_id_for(alive_npc)

		if other_entity == 0:
			continue

		if ids.has(other_entity):
			duplicated.append(DotEntity.describe_id(other_entity))

		ids[other_entity] = true

	_check(
		duplicated.is_empty(),
		"and every monster alive has an id of its own (%d)" % ids.size(),
		", ".join(duplicated)
	)

	_check(
		_game.combat.hitboxes_of(entity) != null
			and _game.combat.health_of(entity) != null,
		"a monster is both shootable and damageable"
	)

	# --- Killing one ------------------------------------------------------  Through dot-combat,
	# which is the only way a monster is supposed to die here: the resolver owns armour, the damage
	# type and spawn protection, and a hit that went straight to DotHealth would skip all three.
	var killed: Array[int] = []
	horde.npc_killed.connect(
		func(_npc: DotNpcInstance, killer: int) -> void: killed.append(killer)
	)

	var shooter_id := _game.players()[0].player_id if not _game.players().is_empty() else 0
	var before_npc_kills := (
		_game.progress.session_values(shooter_id).get_value(ArenaStats.NPC_KILLS, 0.0)
		if shooter_id > 0 else 0.0
	)

	# Twice the grunt's health, so one blow is fatal whatever the falloff does.
	_game.combat.apply_damage(DotDamage.make(
		shooter_id, entity, 500.0,
		_game.combat.damage_type(ArenaContent.DAMAGE_BULLET)
	))

	_check(killed.size() == 1, "shooting a monster kills it", "%d deaths" % killed.size())

	if not killed.is_empty():
		_check(killed[0] == shooter_id, "and credits whoever shot it")

	# The scoreboard must NOT have heard about it. A monster is not a player, and the
	# handler used to hand its entity id straight to `DotMatch.report_kill` — which
	# creates a record keyed on a number no player has ever had.
	_check(
		not _game.match_node.scoreboard.has(str(entity)),
		"and the scoreboard has no row for a monster"
	)

	if shooter_id > 0:
		var after_npc_kills := _game.progress.session_values(shooter_id).get_value(
			ArenaStats.NPC_KILLS, 0.0
		)
		_check(
			after_npc_kills == before_npc_kills + 1.0,
			"and the kill is counted as a monster kill rather than a player kill",
			"%d -> %d" % [int(before_npc_kills), int(after_npc_kills)]
		)

	# A tick, so the spawner actually frees what it reported dead.
	horde.tick(1.0 / float(TICK_RATE))
	await get_tree().process_frame

	_check(
		_game.combat.hitboxes_of(entity) == null,
		"and dot-combat forgot it when it went"
	)

	# --- The director -----------------------------------------------------

	horde.enabled = true

	var waves: Array[int] = []
	horde.wave_spawned.connect(
		func(_at: Vector3, count: int) -> void: waves.append(count)
	)

	# Two seconds of simulated time. The director's build-up phase spawns per player
	# and there are four bots reporting positions, so this is comfortably enough.
	for step in range(TICK_RATE * 2):
		horde.tick(1.0 / float(TICK_RATE))

	_check(
		horde.count() > 0,
		"the director populates the arena when it is on",
		"%d monsters, %d waves" % [horde.count(), waves.size()]
	)

	_check(
		horde.heat.heatmap.cell_count(DotNpcAiHeatmap.TRAFFIC) > 0,
		"and it learns where the players go while it runs"
	)

	_check(
		horde.count() <= ArenaNpcs.limits().world_budget,
		"and never past the world budget",
		"%d of %d" % [horde.count(), ArenaNpcs.limits().world_budget]
	)

	# Every monster must be somewhere a monster can be.
	var stray := 0

	for npc in horde.spawner.all_npcs():
		var at := npc.position()

		if absf(at.x) > _game.map.extent + 2.0 or absf(at.z) > _game.map.extent + 2.0:
			stray += 1

	_check(stray == 0, "and every one of them is inside the map", "%d outside" % stray)

	horde.clear()
	_check(horde.count() == 0, "and the whole horde can be cleared")

	horde.queue_free()
	remove_child(horde)
	_done()

## Bot commands for an arbitrary game. The same aim-and-hold as `_commands_for_tick`,
## which is bound to `_game`.
func _commands_for(game: ArenaGame, tick: int) -> Dictionary:
	var commands := {}

	for player in game.players():
		if not player.is_alive():
			continue

		var move := DotFpsCommand.new()
		move.move = Vector2(
			sin(float(tick) * 0.07 + float(player.player_id)),
			cos(float(tick) * 0.05)
		)
		move.yaw = fmod(float(tick) * 1.7 + float(player.player_id) * 90.0, 360.0)
		move.pitch = 0.0

		var fire := DotWeaponCommand.new()
		fire.set_button(DotWeaponCommand.BUTTON_ATTACK, true)
		fire.yaw = move.yaw
		fire.pitch = move.pitch

		move.sanitise()
		fire.sanitise()
		commands[player.player_id] = [move, fire]

	return commands

# --- Siege -----------------------------------------------------------------

## The mode where every addon in this game is live at once.
func _test_siege() -> void:
	_section("siege")

	var mode := ArenaModes.by_id(&"siege")

	if not _check(mode != null, "there is a siege mode"):
		return

	var valid := mode.validate()
	_check(valid.ok, "and it validates", str(valid.error))
	_check(mode.horde and mode.player_props, "and it asks for monsters and props")

	var game := ArenaGame.new()
	game.name = "Siege"
	game.tick_rate = TICK_RATE
	game.score_limit = 3
	game.time_limit_sec = 0.0
	game.headless = true
	game.is_authority = true
	game.register_service = false
	game.mode_id = &"siege"
	add_child(game)

	var ready := game.setup(ArenaMap.dm_box())

	if not _check(ready.ok, "a siege game sets up", str(ready.error)):
		game.queue_free()
		remove_child(game)
		return

	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	game.match_node.rules.respawn_delay_sec = 1.0

	_check(game.horde != null and game.horde.enabled, "the horde is live")
	_check(game.props != null, "and so are the props")

	# The map's own furniture, owned by nobody. It is placed at setup, so it is there
	# before a single player joins — which is the point of the distinction between it
	# and what a player spawns.
	if game.props != null:
		_check(
			game.props.count() == mode.scatter_props,
			"the map scattered its cover",
			"%d of %d" % [game.props.count(), mode.scatter_props]
		)

	for index in range(2):
		var added := game.add_player(index + 1, "Siege %d" % (index + 1))
		_check(added.ok, "siege player %d joins" % (index + 1), str(added.error))

	game.start(0)
	game.tick({})
	await get_tree().process_frame

	# --- Playing it ------------------------------------------------------

	var monsters_seen := 0

	for tick in range(TICK_RATE * 6):
		game.tick(_commands_for(game, tick))
		monsters_seen = maxi(monsters_seen, game.horde.count())

		if tick % 64 == 0:
			await get_tree().process_frame

	_check(
		monsters_seen > 0,
		"monsters arrive while the match is played",
		"%d at most" % monsters_seen
	)

	# The one thing a mode with both halves can get wrong that neither half can: a
	# monster is a combat entity, and if it were on the scoreboard the score limit
	# would be reached by something nobody killed.
	var rows := game.match_node.scoreboard.players().size()
	_check(
		rows <= 2,
		"and none of them is on the scoreboard",
		"%d rows for 2 players" % rows
	)

	# --- Props a player spawns -------------------------------------------

	var before := game.props.count()
	var made := game.props.spawn_for(
		1, ArenaProps.CRATE, Vector3(0.0, game.map.floor_y + 2.0, 4.0)
	)

	_check(made != null, "a player can spawn a prop in this mode")
	_check(game.props.count() == before + 1, "and it is in the world")

	if made != null:
		# The catalogue's mass, on the body.
		var body := made.body()
		_check(
			body != null and absf(body.mass - ArenaProps.catalogue().get_prop(
				ArenaProps.CRATE
			).mass) < 0.01,
			"with the catalogue's mass rather than the scene's",
			"%.1f kg" % (body.mass if body != null else -1.0)
		)

	# The budget. Twelve is the per-player limit and the interval is three quarters of a second, so
	# this asks for far more than either allows and checks that neither gave way — a budget nothing
	# enforces is the shape this family's own sweep for "settings nothing reads" was built to find.
	for attempt in range(40):
		game.props.tick(1.0)
		game.props.spawn_for(1, ArenaProps.CRATE, Vector3(2.0, 3.0, 2.0))

	var mine := game.props.spawner.player_count(&"1")
	_check(
		mine <= 12,
		"and the per-player budget holds",
		"%d props for one player" % mine
	)

	_check(game.props.undo(1), "undo takes one back")

	# --- The tools, which is what makes dot-props reachable ---------------  [b]A physics gun
	# nothing can call is a physics gun that does not exist.[/b] `phys_gun()` and `grav_gun()` were
	# built, documented and called by nobody until the family's own detector.
	var eye := game.map.floor_y + 2.5

	var target := game.props.spawn_for(1, ArenaProps.CRATE, Vector3(0.0, eye, -3.0))

	if target != null:
		# A frame, so the body is in the physics space and can be raycast at.
		await get_tree().physics_frame

		var space: Variant = game.props._space()
		_check(space != null, "the props layer has a physics space to trace in")

		var aimed := game.props.phys_gun(1).grab(
			space, Vector3(0.0, eye, 0.0), Vector3(0.0, 0.0, -1.0), Basis.IDENTITY
		)

		var reaching := aimed.ok
		_check(reaching, "a player can grab a prop they are looking at", str(aimed.error))

		if reaching:
			_check(
				game.props.phys_gun(1).held != null,
				"and the gun is holding it"
			)

			# Held props move every tick, and a layer that only called `grab` would
			# give a player a prop that stayed exactly where it was picked up — which
			# reads as the physics gun not working rather than as a missing call.
			var was_at := target.position()

			for _step in range(8):
				game.props.tick(1.0 / float(TICK_RATE))
				await get_tree().physics_frame

			_check(
				target.position().distance_to(was_at) > 0.0,
				"and carrying it moves it",
				"%.3f m" % target.position().distance_to(was_at)
			)

			# Off the wire it is queued (`queue_act`, what the bridge calls): a request handler runs in
			# the idle frame, and a grab there would query the physics space outside the physics step.
			game.props.queue_act(1, ArenaEvents.PropAct.RELEASE, Vector3.FORWARD)
			_check(game.props.phys_gun(1).held != null, "a let-go off the wire waits for the tick")
			game.props.tick(1.0 / float(TICK_RATE))
			_check(game.props.phys_gun(1).held == null, "and the tick lets it go, leaving nothing held")
			_check(game.props._queued_acts.is_empty(), "and the queue is empty after it")

	# A grab needs somewhere to trace. A client mirroring this layer has no physics
	# space, and a tool with nothing to trace against would act on whatever was last
	# returned — so `act` refuses rather than guessing.
	_check(
		not game.props.act(
			99, ArenaEvents.PropAct.GRAB, Vector3.ZERO, Vector3.FORWARD
		),
		"and a player with nothing in front of them grabs nothing"
	)

	_check_space_query_audit()
	_check_tick_gate()

	# --- Leaving ---------------------------------------------------------

	game.remove_player(1)
	_check(
		game.props.spawner.player_count(&"1") == 0,
		"and a player who leaves takes their props with them"
	)

	game.queue_free()
	remove_child(game)
	_done()

func _test_geometry_held() -> void:
	_section("the world held")

	# The failure dot-player-controller documents at length: a player who ends a tick
	# exactly touching the floor is never grounded again and sinks through the world.
	# Four bots for ninety seconds is enough for it to happen if it can.
	_check(
		_lowest_y > -1.0,
		"nobody fell through the floor",
		"lowest y was %.3f" % _lowest_y
	)

	_check(
		_furthest <= _game.map.extent + 1.0,
		"and nobody left the room",
		"furthest was %.1f of %.1f" % [_furthest, _game.map.extent]
	)

	_check(
		_grounded_ticks > 0,
		"and they were on the ground rather than falling for ever",
		"%d grounded ticks" % _grounded_ticks
	)

	# The map is actually in the shot path. If the trace ignored the geometry, every
	# shot would reach its target and this would be zero — which would make the whole
	# suite pass while proving nothing about the map.
	var blocked := 0
	var origin := Vector3(0.0, 1.6, -20.0)

	for step in range(64):
		var angle := TAU * float(step) / 64.0
		var hit := _game.combat.trace.ray(
			origin, Vector3(cos(angle), 0.0, sin(angle)).normalized(), 100.0
		)
		if hit.ok() and hit.blocked:
			blocked += 1

	_check(
		blocked > 0,
		"and the level geometry blocks shots",
		"%d of 64 directions" % blocked
	)
	_done()


## Every file under game/ and maps/ that queries a physics space, and where it runs. docs/sim-thread.md
## "Physics space queries". [b]A server query outside the physics step races the step[/b] once physics runs on its own
## thread (`physics/3d/run_on_separate_thread`, Jolt's); a new file here is placed in that table first.
const SPACE_QUERY_FILES := {
	"game/arena_bots_world.gd": "tick",
	"game/arena_bots_world_nav.gd": "tick",
	"game/arena_map_io.gd": "tick",
	"game/arena_props.gd": "tick",
	"game/arena_surf.gd": "tick",
	"game/arena_client.gd": "client",
	"game/arena_kill_pov_view.gd": "client",
	"game/arena_player_part1.gd": "client",
	"game/arena_presentation_b1.gd": "client",
	"game/arena_touch.gd": "client",
	"maps/arena_bsp_map.gd": "client",
}
const SPACE_QUERY_CALLS := ["direct_space_state", "intersect_ray", "intersect_shape", "intersect_point", "cast_motion", "collide_shape", "get_rest_info", "body_test_motion"]


## The space-query audit: the files that query a physics space are exactly [constant SPACE_QUERY_FILES].
func _check_space_query_audit() -> void:
	var found: Array[String] = []

	for dir: String in ["game", "maps"]:
		for file: String in DirAccess.get_files_at("res://" + dir):
			if not file.ends_with(".gd"):
				continue

			var text := FileAccess.get_file_as_string("res://%s/%s" % [dir, file])

			for token: String in SPACE_QUERY_CALLS:
				if text.contains(token):
					found.append("%s/%s" % [dir, file])
					break

	var want: Array[String] = []

	for key: String in SPACE_QUERY_FILES:
		want.append(key)

	found.sort()
	want.sort()
	var extra := found.filter(func(f: String) -> bool: return not want.has(f))
	var gone := want.filter(func(f: String) -> bool: return not found.has(f))
	_check(found == want, "every physics space query in game/ and maps/ is in the audit table (tick or client)", "new %s, gone %s" % [extra, gone])


## The server's ways in from the idle frame that respawn somebody or swap the map, each through `game.tick_gate`
## (arena_tick_gate.gd; docs/sim-thread.md "Physics space queries"). A file that stops using it fails here.
const TICK_GATED_FILES := {
	"game/arena_module.gd": "arena_restart",
	"game/arena_module_b2.gd": "arena_mode",
	"game/arena_net_bridge_b1.gd": "the gate opened at the top of server_tick",
	"game/arena_map_session.gd": "every map change: arena_map, the vote, the rotation, host_change",
	"game/arena_mod_tools.gd": "an admin respawn",
	"game/arena_team_menu.gd": "a team menu choice that brings a player back",
}


## The tick gate: unarmed it runs at once; armed, outside the step it holds work for [method open]; disarmed it lets go.
func _check_tick_gate() -> void:
	var ungated: Array[String] = []

	for file: String in TICK_GATED_FILES:
		if not FileAccess.get_file_as_string("res://" + file).contains("tick_gate."):
			ungated.append(file)

	_check(ungated.is_empty(), "the server's off-tick respawns and map swaps go through the tick gate", str(ungated))

	var gate := ArenaGame.ArenaTickGate.new()
	var ran: Array[int] = []
	gate.run(func() -> void: ran.append(1))
	_check(ran == [1] and gate.pending() == 0, "an unarmed tick gate (solo, a client) runs at once", str(ran))

	gate.armed = true
	gate.in_step = func() -> bool: return false
	gate.run(func() -> void: ran.append(2))
	gate.run(func() -> void: ran.append(3))
	_check(ran == [1] and gate.pending() == 2, "an armed one holds what it hears between ticks", str(ran))
	gate.open()
	_check(ran == [1, 2, 3] and gate.pending() == 0, "and runs it at the top of the tick, in order", str(ran))
	gate.run(func() -> void: ran.append(4))
	gate.disarm()
	_check(ran == [1, 2, 3] and not gate.waits(), "and a server going away drops it", str(ran))
