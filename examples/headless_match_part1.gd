extends "headless_match_state.gd"

## An ERROR from the stats layer used to scroll past and leave progression off with every suite green.
func _on_log_record(rec: Dictionary) -> void:
	if int(rec.get("level", 0)) >= DotLog.Level.ERROR and String(rec.get("channel", "")).begins_with("stats"):
		_stats_errors.append(str(rec.get("message", rec)))

func _group(title: String) -> void:
	print("")
	print("%s" % title)

# --- Assertions ------------------------------------------------------------

func _section(title: String) -> void:
	_entered += 1
	_group(title)

## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1

# --- Modes -----------------------------------------------------------------

## The catalogue, and the one disagreement a mode can have with itself.
func _test_modes() -> void:
	_section("modes")

	var ids := ArenaModes.ids()
	_check(ids.size() >= 2, "the catalogue has modes", str(ids))

	for mode in ArenaModes.all():
		_check(mode.validate().ok, "%s validates" % mode.id, str(mode.validate().error))

	# Every call must build a fresh resource. A shared object would let a server that raised a score limit edit the mode every
	# later match reads (Resource aliasing, shipped four times; why ArenaGame duplicates the rules too).
	var first := ArenaModes.by_id(&"ffa")
	var second := ArenaModes.by_id(&"ffa")
	first.rules.score_limit = 999
	_check(
		second.rules.score_limit != 999,
		"two lookups are not the same object",
		"second read %d" % second.rules.score_limit
	)

	_check(ArenaModes.by_id(&"nonsense") == null, "an unknown id is null")
	_check(
		ArenaModes.by_id_or_default(&"nonsense").id == &"ffa",
		"and falls back rather than failing to boot"
	)

	# team_count and rules.team_based state one fact and validate() catches them disagreeing: a mode with two sides over
	# free-for-all rules scores everyone individually while calling itself Team Deathmatch, correct inside dot-match.
	var broken := ArenaMode.team_deathmatch()
	broken.rules.team_based = false
	_check(not broken.validate().ok, "a mode that disagrees with its rules is refused")
	_done()

## Another id on the same side as [param id], or 0.
func _first_team_mate(game: ArenaGame, id: int) -> int:
	var side := game.team_of(id)

	for index in range(6):
		var other := 200 + index

		if other != id and game.team_of(other) == side:
			return other

	return 0

## Two sides, tagged spawns, and a friendly-fire rule that protects somebody.
func _test_team_deathmatch() -> void:
	print("")
	_section("team deathmatch")

	var game := ArenaGame.new()
	game.name = "TeamGame"
	game.tick_rate = 64
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.team_deathmatch()
	add_child(game)

	var ready := game.setup(ArenaMap.dm_atrium())
	_check(ready.ok, "a team game sets up", str(ready.error))

	if not ready.ok:
		game.queue_free()
		remove_child(game)
		return

	game.start(0)

	_check(game.teams().size() == 2, "with two sides", str(game.teams().size()))

	# The tags send a side to its own end. Without them dot-match falls back to the shared pool and both sides spawn from one,
	# in the enemy base about half the time, which reads as a spawn-selection bug instead of an untagged map.
	var tagged := 0

	for point in game.match_node.spawn_points():
		if point.tags.size() > 0:
			tagged += 1

	_check(tagged > 0, "the map's spawns carry team tags", "%d tagged" % tagged)

	# Six players, and dot-match decides the sides.
	var counts := {}

	for index in range(6):
		var added := game.add_player(200 + index, "Team %d" % index)
		_check(added.ok, "player %d joins" % index, str(added.error))

		var side := game.team_of(200 + index)
		counts[side] = int(counts.get(side, 0)) + 1

	_check(not counts.has(0), "everybody got a side", str(counts))
	_check(counts.size() == 2, "spread across both", str(counts))

	var sizes: Array[int] = []

	for side in counts:
		sizes.append(int(counts[side]))

	_check(
		abs(sizes[0] - sizes[1]) <= 1,
		"and the sides are balanced",
		"%d vs %d" % [sizes[0], sizes[1]]
	)

	# ArenaPlayer.team was declared and assigned by NOTHING since the class was written, so the
	# scoreboard, the renderer and the friendly-fire check all read a zero.
	var mirrored := 0

	for index in range(6):
		var player := game.player_for(200 + index)

		if player != null and player.team == game.team_of(200 + index):
			mirrored += 1

	_check(mirrored == 6, "the player carries the side it was given", "%d of 6" % mirrored)

	# And the reason any of that matters: dot-combat asks a callable for two entity ids and compares
	# the answers.
	var resolver := game.combat.resolver
	_check(resolver.team_of.is_valid(), "combat can ask who is on whose side")

	if resolver.team_of.is_valid():
		var a := 200
		var b := _first_team_mate(game, a)
		_check(b > 0, "two players share a side", "%d and %d" % [a, b])

		if b > 0:
			_check(
				int(resolver.team_of.call(a)) == int(resolver.team_of.call(b)),
				"and combat agrees they do"
			)

	game.queue_free()
	remove_child(game)
	await get_tree().process_frame
	_done()

## One resolved hit, returning what actually landed.
func _hit(game: ArenaGame, attacker: int, victim: int, amount: float) -> float:
	var type := game.combat.damage_type(&"bullet")
	if type == null:
		type = DotDamageType.new()
		type.id = &"bullet"
	var damage := DotDamage.make(attacker, victim, amount, type)
	damage.tick = game.current_tick()
	var out := game.combat.resolver.resolve(damage)
	return 0.0 if out.refused else out.amount

func _go_live(game: ArenaGame) -> void:
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	game.match_node.rules.min_players = 1
	var guard := 0
	while not game.match_node.is_live() and guard < TICK_RATE * 20:
		game.tick({})
		guard += 1

# --- Effects ---------------------------------------------------------------

## dot-effects, and the one line that makes it count: the damage check.
func _test_effects() -> void:
	_section("effects")

	var game := ArenaGame.new()
	game.name = "EffectGame"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.free_for_all(50)
	add_child(game)

	var ready := game.setup(ArenaMap.dm_atrium())
	if not _check(ready.ok, "an effects game sets up", str(ready.error)):
		game.queue_free()
		remove_child(game)
		return

	game.start(0)
	_check(game.effects != null, "every mode gets an effects layer")

	var _a := game.add_player(700, "Att")
	var _b := game.add_player(701, "Vic")
	_go_live(game)

	_check(
		game.combat.resolver.adjust.is_valid(),
		"dot-combat's per-hit hook is filled, which nothing in this game had ever done"
	)

	# Out of the spawn window first: a freshly spawned player is protected (DotHealth's window, the
	# PROTECTED effect and dot-spawn's ledger, all off the mode's `spawn_protection_sec`).
	for _protect in range(game.match_node.spawn_protection_ticks() + 2):
		game.tick({})

	# The hit, with nothing on either end.
	var plain := _hit(game, 700, 701, 40.0)
	_check(
		is_equal_approx(plain, 40.0),
		"a plain hit lands unscaled", "%.1f" % plain
	)

	# The attacker empowered.
	var _e := game.effects.apply(ArenaEffects.EMPOWERED, 700, 700)
	var boosted := _hit(game, 700, 701, 40.0)
	_check(
		boosted > plain * 2.0,
		"an empowered attacker hits harder", "%.1f against %.1f" % [boosted, plain]
	)

	# The victim untouchable.
	var _p := game.effects.apply(ArenaEffects.PROTECTED, 701, 701)
	var refused := _hit(game, 700, 701, 40.0)
	_check(
		refused == 0.0,
		"and an invulnerable victim takes nothing at all", "%.1f" % refused
	)
	game.effects.remove(ArenaEffects.PROTECTED, 701)

	# A burn reports damage and the game applies it, which is the whole seam.
	var before: float = game.combat.health_of(701).health
	var _burn := game.effects.apply(ArenaEffects.BURNING, 701, 700)
	for t in range(TICK_RATE * 2):
		game.tick({})
	var after: float = game.combat.health_of(701).health
	_check(
		after < before,
		"a burn takes health through DotHealth rather than by touching a number",
		"%.1f -> %.1f" % [before, after]
	)

	# Movement, and the compounding trap.
	var player := game.player_for(701)
	var base := player.controller.tunables.max_speed
	var _slow := game.effects.apply(ArenaEffects.SLOWED, 701, 700)
	game.tick({})
	var slowed := player.controller.tunables.max_speed
	_check(slowed < base, "a slow slows", "%.2f from %.2f" % [slowed, base])

	for t in range(30):
		game.tick({})
	_check(
		is_equal_approx(player.controller.tunables.max_speed, slowed),
		"and stays at ONE slow rather than compounding — scaling the live value each "
		+ "tick reaches zero in a second and the player stops dead",
		"%.4f" % player.controller.tunables.max_speed
	)

	game.effects.remove(ArenaEffects.SLOWED, 701)
	game.tick({})
	_check(
		is_equal_approx(player.controller.tunables.max_speed, base),
		"and goes back to the map's own speed when it ends",
		"%.2f" % player.controller.tunables.max_speed
	)

	# Spawn protection, which is why PROTECTED exists as an effect rather than as
	# DotHealth's own flag: it has to stop a capture as well.
	game.effects.on_spawn(701)
	_check(
		game.effects.has(ArenaEffects.PROTECTED, 701),
		"respawning grants spawn protection"
	)
	_check(
		not game.effects.may_capture(701),
		"and an untouchable player captures nothing, which is the whole reason "
		+ "dot-objective asks a callable"
	)

	# And the seam a changelevel breaks.
	var changed := game.change_map(ArenaMap.dm_box())
	_check(changed.ok, "the map changes", str(changed.error))
	_check(
		game.combat.resolver.adjust.is_valid(),
		"and the per-hit hook is back on the NEW resolver — a map change builds a new "
		+ "combat manager, and without the rebind the effects layer keeps running and "
		+ "stops scaling a single hit"
	)

	game.queue_free()
	remove_child(game)
	await get_tree().process_frame
	_done()

func _test_pack_weapons_rest(game: ArenaGame, p: ArenaPlayer) -> void:
	_check(
		ArenaHud.weapon_line(p) == "Plasma Beamer",
		"and names it", ArenaHud.weapon_line(p)
	)
	_check(
		ArenaHud.cause_label(AwWeaponIds.MACHINE_PISTOL) == "Machine Pistol",
		"the kill feed says Machine Pistol, not machine_pistol"
	)

	game.queue_free()
	remove_child(game)
	await get_tree().process_frame
	_done()

## One tick of [param id] holding [param buttons], looking along [param pitch].
func _hold(game: ArenaGame, id: int, buttons: int, slot: int = 0, pitch: float = 0.0) -> void:
	var move := DotFpsCommand.new()
	move.pitch = pitch
	move.yaw = game.player_for(id).controller.state.yaw
	var fire := DotWeaponCommand.new()
	fire.buttons = buttons
	fire.slot = slot
	fire.yaw = move.yaw
	fire.pitch = move.pitch
	game.tick({id: [move, fire]})

## [param ticks] of [param id] doing nothing, so a deploy or a cooldown runs out.
func _settle(game: ArenaGame, id: int, ticks: int) -> void:
	for i in range(ticks):
		_hold(game, id, 0)

## Asks for [param slot] the way the number keys do, and waits for the switch.
func _switch_to(game: ArenaGame, id: int, slot: int) -> void:
	_hold(game, id, 0, slot)
	_settle(game, id, TICK_RATE)

# --- arena-weapons ---------------------------------------------------------

## The weapons pack in a real game: the rig drives the arsenal, a spawn holds the right thing, a
## shot leaves the eye, the bash works, and projectiles behave as defined.
func _test_pack_weapons() -> void:
	_section("arena-weapons in the arena")

	var game := ArenaGame.new()
	game.name = "AwGame"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.free_for_all(50)
	add_child(game)

	var ready := game.setup(ArenaMap.dm_box())
	if not _check(ready.ok, "a weapons game sets up", str(ready.error)):
		game.queue_free()
		remove_child(game)
		return

	game.start(0)
	var _a := game.add_player(900, "Pack")
	var _b := game.add_player(901, "Far")
	_go_live(game)

	for _protect in range(game.match_node.spawn_protection_ticks() + 2):
		game.tick({})

	var p := game.player_for(900)

	_check(
		p.weapons is AwWeaponRig and p.weapons.arsenal == p.arsenal,
		"the rig drives the player's own arsenal, so every reader of it keeps working"
	)
	_check(p.arsenal.max_slots == AwWeaponIds.SLOT_THROWN, "with the pack's five slots")

	# The default: something in every slot that matters, and the GUN in hand.
	p.give_default_loadout()
	var carried := PackedStringArray()
	for id in ArenaContent.default_loadout():
		if p.arsenal.carries(id):
			carried.append(String(id))
	_check(
		carried.size() == ArenaContent.default_loadout().size(),
		"the default loadout is carried", ", ".join(carried)
	)
	_settle(game, 900, TICK_RATE)
	_check(
		p.arsenal.current_def() != null and p.arsenal.current_def().id == ArenaWeaponRoles.resolve(&"primary"),
		"and a spawn holds the rifle, not the grenade in the highest slot",
		str(p.arsenal.current_def().id if p.arsenal.current_def() != null else &"")
	)
	_check(
		ArenaWeaponRoles.own_pack == "" or AwWeaponSound.class_for(&"lmg", &"") == &"lmg",
		"the arena pack's lmg has the lmg sound class, not the rifle's", str(AwWeaponSound.class_for(&"lmg", &""))
	)

	# A loadout saved before the melee slot existed still gives something under 1.
	var old := DotLoadout.empty(&"arena")
	old.set_item(&"primary", AwWeaponIds.SMG)
	old.set_item(&"secondary", AwWeaponIds.REVOLVER)
	p.give_loadout(game.loadouts.resolve(old))
	_check(
		p.arsenal.carries(AwWeaponIds.KNIFE) and p.arsenal.carries(AwWeaponIds.SMG),
		"a primary-and-sidearm loadout from before the melee slot still gets a knife"
	)
	_check(
		p.arsenal.current_slot() == AwWeaponIds.SLOT_PRIMARY,
		"and spawns holding its primary", str(p.arsenal.current_slot())
	)
	_settle(game, 900, TICK_RATE)

	# A shot, from the eye along the aim.
	var used: Array[DotWeaponOutcome] = []
	p.used.connect(func(o: DotWeaponOutcome) -> void: used.append(o))

	for i in range(TICK_RATE / 2):
		_hold(game, 900, DotWeaponCommand.BUTTON_ATTACK, 0, -5.0)

	var shots: Array[DotShot] = []
	for o in used:
		shots.append_array(o.shots)
	_check(shots.size() > 3, "held fire shoots the SMG", str(shots.size()))

	if not shots.is_empty():
		var eye := p.muzzle_position()
		_check(
			shots[-1].origin.distance_to(eye) < 0.05,
			"from the eye", "%.3f m away" % shots[-1].origin.distance_to(eye)
		)
		_check(
			shots[-1].direction.dot(p.aim_direction()) > 0.98,
			"along the aim", "dot %.3f" % shots[-1].direction.dot(p.aim_direction())
		)

	# The bash on the alt-fire: the pack's own second state machine, through the rig.
	var bashes: Array[DotWeaponOutcome] = []
	p.weapons.bashed.connect(func(o: DotWeaponOutcome) -> void: bashes.append(o))
	_settle(game, 900, TICK_RATE / 2)
	_hold(game, 900, DotWeaponCommand.BUTTON_ALT)
	_settle(game, 900, 4)
	_check(bashes.size() == 1, "the alt-fire bashes, once per press", str(bashes.size()))

	# The flashlight: one press of its button is one switch, and holding it is not another.
	var lit_before: bool = p.flashlight
	for i in range(ArenaFlashlight.hold_ticks(game.tick_rate)):
		_hold(game, 900, ArenaFlashlight.BUTTON)
	_settle(game, 900, 2)
	var lit_after: bool = p.flashlight
	_check(lit_before != lit_after, "the flashlight button switches the light once", "%s -> %s" % [lit_before, lit_after])

	# A frag: thrown, bounced, and gone off on its fuse rather than on the first wall.
	var gone: Array = []
	game.projectiles.detonated.connect(func(at: Vector3, s: DotWeaponSpawn) -> void:
		gone.append([at, s, game.current_tick()])
	)

	p.arsenal.give(AwWeaponIds.FRAG)
	_switch_to(game, 900, AwWeaponIds.thrown_slot())
	_check(
		p.arsenal.current_def().id == AwWeaponIds.FRAG,
		"the 5 key's slot holds the frag", str(p.arsenal.current_def().id)
	)

	for i in range(6):
		_hold(game, 900, DotWeaponCommand.BUTTON_ATTACK, 0, -25.0)
	var thrown_at := game.current_tick()
	_settle(game, 900, 1)

	var flying := game.projectiles.flying()
	_check(flying.size() == 1, "letting go throws it", str(flying.size()))

	var frag: ArenaProjectiles.Flying = flying[0] if flying.size() == 1 else null
	var fuse := frag.spawn.fuse_ticks if frag != null else 0
	_check(fuse > TICK_RATE, "with most of its fuse left", "%d ticks" % fuse)

	var most_bounces := 0
	for i in range(TICK_RATE * 4):
		if frag != null:
			most_bounces = maxi(most_bounces, frag.bounces)
		if not gone.is_empty():
			break
		game.tick({})

	_check(most_bounces > 0, "it bounced", str(most_bounces))
	_check(gone.size() == 1, "and went off", str(gone.size()))

	if gone.size() == 1:
		var after := int(gone[0][2]) - thrown_at
		_check(
			absi(after - fuse) <= 2,
			"on its fuse, not on the first thing it touched",
			"%d ticks after the throw, fuse %d" % [after, fuse]
		)

	# A sticky stops on what it lands on.
	gone.clear()
	p.arsenal.give(AwWeaponIds.STICKY)
	p.arsenal.add_ammo(AwWeaponIds.AMMO_GRENADE, 4)
	_settle(game, 900, TICK_RATE)
	# Down at the floor a few metres out: at the thrower's own feet its splash would kill
	# them, the respawn would hand back a rifle, and the cook-off below would be a rifle.
	for i in range(4):
		_hold(game, 900, DotWeaponCommand.BUTTON_ATTACK, 0, -20.0)
	_settle(game, 900, TICK_RATE / 2)

	var sticky: ArenaProjectiles.Flying = (
		game.projectiles.flying()[0] if game.projectiles.live_count() == 1 else null
	)
	_check(
		sticky != null and sticky.sticks and sticky.resting and sticky.bounces == 0,
		"a sticky stops dead where it lands",
		str(game.projectiles.describe())
	)
	var stuck_at := sticky.position if sticky != null else Vector3.ZERO
	_settle(game, 900, TICK_RATE / 4)
	_check(
		sticky != null and sticky.position.distance_to(stuck_at) < 0.001,
		"and stays there"
	)
	for i in range(TICK_RATE * 3):
		if not gone.is_empty():
			break
		game.tick({})
	_check(gone.size() == 1, "then goes off", str(gone.size()))

	# Cooked past its fuse: in the hand, at once, and it hurts.
	_check(p.is_alive(), "the thrower survived their own sticky at range")
	gone.clear()
	p.arsenal.give(AwWeaponIds.FRAG)
	p.arsenal.add_ammo(AwWeaponIds.AMMO_GRENADE, 4)
	p.health.invulnerable = false
	p.health.spawn_protection_ticks = 0
	var before := p.health.health + p.health.armour
	_settle(game, 900, TICK_RATE)
	for i in range(TICK_RATE * 3 + 16):
		_hold(game, 900, DotWeaponCommand.BUTTON_ATTACK)
	var released := game.current_tick()
	_settle(game, 900, 3)
	_check(gone.size() == 1, "a grenade cooked past its fuse goes off", str(gone.size()))

	if gone.size() == 1:
		_check(
			int(gone[0][2]) - released <= 2,
			"at once, not twelve seconds later",
			"%d ticks after letting go" % (int(gone[0][2]) - released)
		)
		_check(
			(gone[0][0] as Vector3).distance_to(p.muzzle_position()) < 1.0,
			"in the hand"
		)
	_check(
		p.health.health + p.health.armour < before or not p.is_alive(),
		"and the thrower pays for it"
	)

	# The counter on a weapon with no magazine reads its pool, not zero.
	if not p.is_alive():
		var _again := game.respawn_player(900)
	p.arsenal.give(AwWeaponIds.BEAMER)
	_switch_to(game, 900, AwWeaponIds.SLOT_PRIMARY)
	var cells := p.arsenal.ammo().count(AwWeaponIds.AMMO_CELL)
	_check(
		ArenaHud.rounds_in_hand(p) == cells and cells > 0,
		"the HUD counts a beamer's cells, where a magazine count read 0",
		"%d against %d" % [ArenaHud.rounds_in_hand(p), cells]
	)
	await _test_pack_weapons_rest(game, p)

## Put a player somewhere, without simulating a walk there.
func _stand(game: ArenaGame, id: int, at: Vector3) -> void:
	var player := game.player_for(id)
	if player == null or player.controller == null:
		return
	player.controller.state.position = at

# --- Drops -------------------------------------------------------------------

## Points and a health pack out of a critical kill, taken by walking through them.
func _test_drops() -> void:
	_section("a critical kill drops points and a health pack")

	var game := ArenaGame.new()
	game.name = "DropsGame"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	add_child(game)

	var ready := game.setup(ArenaMap.dm_box())
	if not _check(ready.ok, "a drops game sets up", str(ready.error)):
		remove_child(game)
		game.queue_free()
		return

	game.start(0)
	for id in [900, 901, 902]:
		var _added := game.add_player(id, "Dropper %d" % id)
	game.match_node.rules.respawn_delay_sec = 120.0
	_go_live(game)

	var kill := func(killer: int, victim: int, critical: bool) -> void:
		var health := game.combat.health_of(victim)
		health.invulnerable_until_tick = -1
		var damage := DotDamage.make(killer, victim, 500.0, game.combat.damage_type(&"bullet"))
		damage.tick = game.current_tick()
		damage.critical = critical
		var applied := health.apply(damage)
		if applied != null and applied.lethal:
			applied.critical = critical
			game.combat.entity_killed.emit(victim, applied)

	kill.call(900, 902, false)
	_check(game.drops.live_count() == 0, "an ordinary kill drops nothing by default")

	_stand(game, 901, Vector3(0.0, 0.05, 18.0))
	kill.call(900, 901, true)
	var dropped := game.drops.live_count()
	_check(dropped == int(game.drop_rules["points"]) + 1,
		"a lethal critical drops %d points and a pack (%d)" % [game.drop_rules["points"], dropped])

	# Walk the killer over every point, and the pack, at full health.
	var killer := game.player_for(900)
	var points_at: Array[Vector3] = []
	var pack_at := Vector3.ZERO
	for pickup in game.drops.field.pickups():
		if pickup.item_id == &"point":
			points_at.append(pickup.global_position)
		else:
			pack_at = pickup.global_position
	for at in points_at:
		_stand(game, 900, at)
		game.tick({})
	_check(int(game.drops.points.get(900, 0)) == points_at.size(),
		"walking through the points collects every one (%d)" % int(game.drops.points.get(900, 0)))

	_stand(game, 900, pack_at)
	game.tick({})
	_check(game.drops.live_count() == 1, "the pack is left for somebody who needs it at full health")

	killer.health.health = 40.0
	game.tick({})
	_check(game.drops.live_count() == 0 and killer.health.health > 60.0,
		"and taken by a hurt player, who is healed (%.0f)" % killer.health.health)

	# Drops that nobody takes go after their life.
	game.drop_rules["any_kill"] = true
	game.apply_drop_rules()
	game.player_for(902).health.alive = true
	game.player_for(902).hitboxes.enabled = true
	_stand(game, 902, Vector3(10.0, 0.05, -18.0))
	game.combat.health_of(902).health = 100.0
	kill.call(901 if game.player_for(901).is_alive() else 900, 902, false)
	_check(game.drops.live_count() > 0, "with any_kill on, an ordinary kill drops too")
	for _i in range(int(float(game.drop_rules["life"]) * TICK_RATE) + 2):
		game.tick({})
	_check(game.drops.live_count() == 0, "and what nobody takes is gone after its life")

	# The wire: a drop and a take round-trip.
	var wire := ArenaEvents.read_drop(DotNetReader.new(
		ArenaEvents.write_drop(7, 1, 25, Vector3(1, 2, 3), Vector3(4, 0, 6))
	))
	_check(bool(wire["ok"]) and int(wire["id"]) == 7 and int(wire["kind"]) == 1
		and int(wire["value"]) == 25 and (wire["at"] as Vector3).is_equal_approx(Vector3(4, 0, 6)),
		"DROP round-trips")

	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
	_done()
