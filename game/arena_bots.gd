extends "arena_bots_world.gd"

## What a bot does with a tick, as the same two commands a client sends: dot-bot's brain,
## fed from this game. One brain for every bot arena has, solo and on a server.
##
## [b]Commands, not a second simulation.[/b] A bot is an [ArenaPlayer] like anybody else and
## moves through the same controller, shoots through the same arsenal and is hit by the same
## lag-compensated trace; all this decides is what it would have pressed. That keeps a bot
## from ever doing something a player could not -- no walking through walls, no shot the
## arsenal would refuse -- and keeps the tick order exactly what it is for people.
##
## [b]Solo used to be a test fixture.[/b] The offline client drove its bots with the
## `headless_match` aimbot: face the nearest player through any wall, hold the trigger under
## 40 m, no reaction and no aim error. A first play test on Windows died twelve times in ninety
## seconds to it, killed from 30 to 40 m within a second, while the brain a server ran (sight,
## reaction, aim error, range, strafing) was never met by anybody playing solo. Both now ask
## [DotBotBrain], so `bot_difficulty` means the same thing in both.
##
## [b]What the brain is told[/b] ([World], a [DotBotWorld]): every player as a
## [DotBotContact], the combat trace's line of sight, the map's spawns as places to roam, a
## route between them over the horde's navigation graph (built-in maps; an imported map has
## none, and is walked straight), how fast the held weapon's projectile flies (so a rocket
## is led), a sound for every shot fired (from [signal ArenaPlayer.used]) and who hit whom
## (from [signal ArenaGame.hit_confirmed]). Nothing else, so it cannot see through a wall.
##
## [b]A grenade is four commands, not a button.[/b] Arena has no throw key: a frag is slot 5,
## drawn, held to cook and released. When the brain says [member DotBotIntent.throw], [Mind]
## switches to the throwable, holds the trigger for [constant COOK_SEC], lets go along the
## view the brain chose, and switches back to what it held -- the same presses a person makes.
##
## [b]Deterministic per bot[/b]: the brain's randomness is seeded from the bot's id, and its
## clock is the game's tick, so two runs of the same inputs play the same bots. Not on an
## imported map, whose routes start when its background bake lands ([method World._nav_for_map]).
##
## [b]Ramps are ridden.[/b] On a combat surf map with a surf cache the routes cross ride edges
## between the platforms and walk through the map's teleports, and a bot whose route reaches a
## ride hands its legs to the surf pilot until it lands, aiming and shooting as before
## ([code]arena_surf.gd[/code], loaded only on a shell with dot-bot 4 and
## dot-player-controller 3).


## The world on [param game], made the first time a bot asks.
static func world_for(game: Object) -> World:
	if game.has_meta(WORLD_META):
		var held: Variant = game.get_meta(WORLD_META)
		if held is World:
			return held
	var made := World.new(game)
	game.set_meta(WORLD_META, made)
	return made


## [move, fire] for [param bot] this tick.
static func think(game: Object, bot: ArenaPlayer, mind: Mind, tick: int, tick_rate: float) -> Array:
	var early := think_begin(game, bot, mind, tick, tick_rate)
	if not early.is_empty():
		return early
	var t_brain := Time.get_ticks_usec()
	mind.t_intent = mind.brain.think(mind.t_me, mind.t_world, mind.t_world.now())
	ArenaFrameProbe.add(&"bot_brain", t_brain)
	return think_finish(game, bot, mind, tick, tick_rate)


## The part of [method think] before the brain runs, on the main thread: the commands of a tick the bot coasts (or
## of no game), else an empty array with [member Mind.t_me] and [member Mind.t_world] set for the brain.
static func think_begin(game: Object, bot: ArenaPlayer, mind: Mind, tick: int, tick_rate: float) -> Array:
	if game == null or bot == null:
		return [DotFpsCommand.new(), DotWeaponCommand.new()]

	var players: int = game.player_ids().size()
	_every = think_every if think_every > 0 else (2 if players > AUTO_STAGGER_ABOVE else 1)
	_tier_on = tiers.applies(players)
	var world := world_for(game)
	if (_every > 1 or _tier_on) and _coasts(mind, tick, world, bot.player_id):
		return _recoil_comp(bot, mind, _coast(mind, tick), tick, tick_rate)

	var t_refresh := Time.get_ticks_usec()
	world.near_reach = think_near
	world.tiers = tiers
	world.refresh(tick, tick_rate)
	ArenaFrameProbe.add(&"bot_refresh", t_refresh)

	if mind.brain == null:
		mind.brain = ArenaBotBrain.new(mind.seed if mind.seed != 0 else bot.player_id, DotBotSettings.of(game))
		# The bot's trick gates follow the motor: 1.18 times the minimum, as the old 6.5 was of 5.5.
		var body_tunables: Variant = bot.controller.get("tunables") if bot.controller != null else null
		if body_tunables is DotFpsTunables:
			mind.brain.tricks.slide_speed = body_tunables.slide_min_speed * 1.18
			mind.brain.tricks.wall_run_speed = body_tunables.wall_run_min_speed * 1.17
	world.brains[bot.player_id] = mind.brain

	var me := world.contact(bot.player_id)
	# The body's view carries last tick's recoil correction; the brain steers from the view it meant, or it would walk
	# the correction back out (smoothing and the turn limit) and the bullets drift off again.
	if mind.recoil_comp != Vector2.ZERO and bot.controller != null:
		me.view_yaw = bot.controller.state.yaw + mind.recoil_comp.x
		me.view_pitch = bot.controller.state.pitch + mind.recoil_comp.y
	# A teleport carries the bot further in a tick than anything walks or flies, and its route was
	# laid from where it stood: walked on, the old corners lead it off the pad it landed on. The
	# brain is told as it is when a ride ends, and plans from here (a ride the pilot has is not cut).
	if mind.ride == null and mind.last_position != Vector3.INF and me.position.distance_to(mind.last_position) > TELEPORT_JUMP:
		mind.brain.ride_ended(true)
	mind.last_position = me.position
	mind.t_me = me
	mind.t_world = world
	return []


## The part of [method think] after the brain ran, on the main thread: the bot's commands from [member Mind.t_intent].
static func think_finish(_game: Object, bot: ArenaPlayer, mind: Mind, tick: int, tick_rate: float) -> Array:
	var move := DotFpsCommand.new()
	var fire := DotWeaponCommand.new()
	var world: World = mind.t_world
	var me: DotBotContact = mind.t_me
	var intent: DotBotIntent = mind.t_intent
	mind.t_me = null
	mind.t_world = null
	mind.t_intent = null
	var t_after := Time.get_ticks_usec()
	var surf := world.surf_for_map()
	if surf != null:
		surf.call(&"steer", bot, mind, intent, tick, tick_rate)
	elif mind.ride != null:
		mind.ride = null
	intent.write_move(move, "BUTTON_USER_0")
	intent.write_fire(fire)
	_throw(bot, mind, intent, move, fire, tick, tick_rate)
	move.sanitise()
	fire.sanitise()
	ArenaFrameProbe.add(&"bot_after", t_after)
	world.woken.erase(bot.player_id)
	if _tier_on and tiers.is_on():
		mind.far = false
		var engaged := intent.target_id >= 0 and not world.brains.has(intent.target_id)
		# every here is the coast's length: to the bot's next beat at its tier's period.
		mind.every = DotBotThinkTier.until_beat(tick, mind.seed, tiers.period(bot.player_id, me.position, engaged))
		mind.coasting = mind.every > 1 and _tier_coastable(mind, intent)
	else:
		mind.far = _every > 1 and _nobody_near(me, world)
		mind.every = _every if mind.far else 1
		# Only a think on the bot's own beat starts a coast, so the coast's steps count from it.
		mind.coasting = mind.far and (tick + mind.seed) % _every == 0 and _coastable(mind, intent, move, fire)
	if mind.coasting:
		# The brain turned for `every` ticks at once; spread over them, so no tick turns faster than bot_turn_rate.
		mind.view_to = Vector2(move.yaw, move.pitch)
		# From the view the body has, which a respawn or a teleport may have turned since the last command.
		var from := Vector2(me.view_yaw, me.view_pitch)
		mind.view_from = from
		move.yaw = from.x + _turn(from.x, mind.view_to.x) / float(mind.every)
		move.pitch = from.y + (mind.view_to.y - from.y) / float(mind.every)
	elif (_every > 1 or _tier_on) and mind.throw_stage == 0 and mind.last_think_tick >= 0 and tick - mind.last_think_tick > 1:
		# A think after coasted ticks: the brain's turn limit is bot_turn_rate times the time since its last
		# think, so it turned for the whole gap at once (twice bot_turn_rate in one tick, the headless_bots
		# turn-rate failure). Held to one tick's turn from the body's view; the aim closes over the next ticks.
		var rate := mind.brain.settings.profile.turn_rate / tick_rate
		var body := Vector2(me.view_yaw, me.view_pitch)
		move.yaw = body.x + clampf(_turn(body.x, move.yaw), -rate, rate)
		move.pitch = body.y + clampf(move.pitch - body.y, -rate, rate)
	mind.last_think_tick = tick
	mind.last_move = move.duplicate_command()
	mind.last_fire = fire.duplicate_command()
	if mind.coasting and _tier_on:
		# A tiered coast repeats only held buttons: a jump or a weapon switch is pressed on the think tick, then let go.
		mind.last_move.buttons &= _COAST_MOVE if intent.state != &"dead" else 0
		mind.last_fire.buttons &= _COAST_FIRE if intent.state != &"dead" else 0
	return _recoil_comp(bot, mind, [move, fire], tick, tick_rate)


## Off only for tests that measure the bots without the correction (headless_bot_hitreg).
static var recoil_compensation := true

## bot_recoil_control: the share of the recoil a bot pulls its aim back against, 0..1; below 0 (the default, -1)
## by difficulty from [constant RECOIL_CONTROL]. A whole share made every bot's burst a laser no person matches.
static var recoil_control := -1.0
const RECOIL_CONTROL := {"easy": 0.3, "medium": 0.55, "hard": 0.75, "nightmare": 0.9}


## The share of the recoil [param mind]'s bot pulls back against.
static func recoil_share(mind: Mind) -> float:
	if recoil_control >= 0.0:
		return clampf(recoil_control, 0.0, 1.0)
	var preset := DotBotProfile.DEFAULT_PRESET
	if mind != null and mind.brain != null and mind.brain.settings != null and mind.brain.settings.profile != null:
		preset = mind.brain.settings.profile.preset_name
	return float(RECOIL_CONTROL.get(preset, RECOIL_CONTROL[DotBotProfile.DEFAULT_PRESET]))


## The commands with the aim turned against the recoil the next shot will carry. The weapon offsets each bullet by
## the kick left from the shots before it (dot-weapon's recoil rules); a player pulls the view back against it, but
## a bot's view is its command, so held on a target the bullets walked off it: most of a held burst missed a
## target dead on the crosshair (headless_bot_hitreg). Only the trigger-down tick is turned, and the stored
## last commands the coast repeats are not, so the correction never compounds.
static func _recoil_comp(bot: ArenaPlayer, mind: Mind, cmds: Array, tick: int, tick_rate: float) -> Array:
	mind.recoil_comp = Vector2.ZERO
	if not recoil_compensation:
		return cmds
	var fire: DotWeaponCommand = cmds[1]
	if bot == null or bot.arsenal == null or not fire.is_pressed(DotWeaponCommand.BUTTON_ATTACK):
		return cmds
	var offset := next_recoil_offset(bot, tick, tick_rate) * recoil_share(mind)
	if offset == Vector2.ZERO:
		return cmds
	var move: DotFpsCommand = cmds[0]
	move.pitch -= offset.x
	move.yaw -= offset.y
	mind.recoil_comp = Vector2(offset.y, offset.x)
	return cmds


## Degrees (pitch up, yaw left) the next bullet of [param bot]'s weapon is turned off its aim by recoil, as
## [method DotWeaponRecoilRules.apply] will work it out at [param tick]; zero with recoil patterns off.
static func next_recoil_offset(bot: ArenaPlayer, tick: int, tick_rate: float) -> Vector2:
	var rr := DotWeaponRecoilRules.of(bot.arsenal)
	var slot: DotWeaponSlot = bot.arsenal.current()
	if rr == null or slot == null or slot.behaviour == null or slot.behaviour.def == null:
		return Vector2.ZERO
	var b := slot.behaviour.def.tuning as DotWeaponBallistics
	if b == null:
		return Vector2.ZERO
	var state: Dictionary = slot.behaviour.state
	var elapsed := maxf(float(tick - int(state.get(&"recoil_tick", -1000000))) / maxf(tick_rate, 1.0), 0.0)
	var n := int(state.get(&"recoil_n", 0)) if elapsed <= rr.reset else 0
	var residual := Vector2(float(state.get(&"recoil_ax", 0.0)), float(state.get(&"recoil_ay", 0.0))) * exp(-b.recoil_recovery * rr.recovery * elapsed)
	var grow := 1.0 + minf(b.recoil_build * rr.build * float(n), b.recoil_build_max * rr.build)
	var kick := Vector2(b.recoil_pitch * rr.vertical * grow, b.recoil_yaw * rr.horizontal * grow * DotWeaponRecoilRules.drift(DotWeaponRecoilRules.seed_for(b, slot.behaviour.def.id), n))
	var share := b.recoil_camera if b.recoil_camera >= 0.0 else rr.punch
	return (residual + kick) * (1.0 - share) + residual * share * rr.follow


## Degrees from [param a] to [param b] the short way round.
static func _turn(a: float, b: float) -> float:
	return fposmod(b - a + 180.0, 360.0) - 180.0


## The commands of a tick the brain sits out: the last ones, with the view carried on towards where the last think turned it.
static func _coast(mind: Mind, tick: int) -> Array:
	var step := tick - mind.last_think_tick
	var move := mind.last_move.duplicate_command()
	var fraction := float(step + 1) / float(mind.every)
	move.yaw = mind.view_from.x + _turn(mind.view_from.x, mind.view_to.x) * fraction
	move.pitch = mind.view_from.y + (mind.view_to.y - mind.view_from.y) * fraction
	mind.last_move.yaw = move.yaw
	mind.last_move.pitch = move.pitch
	return [move, mind.last_fire.duplicate_command()]


## Whether a bot that just thought may sit out the next ticks: nothing in hand but a walk.
static func _coastable(mind: Mind, intent: DotBotIntent, move: DotFpsCommand, fire: DotWeaponCommand) -> bool:
	return mind.ride == null and mind.throw_stage == 0 and intent.target_id < 0 and intent.state != &"dead" \
		and move.buttons == 0 and fire.buttons == 0


## Whether a tiered bot that just thought may sit out the next ticks: no ride or throw. Its edge buttons are not
## repeated (see [method think_finish]), so a fight or a jump may coast; a dead bot coasts with nothing pressed.
static func _tier_coastable(mind: Mind, _intent: DotBotIntent) -> bool:
	return mind.ride == null and mind.throw_stage == 0


## Whether this tick repeats the last commands rather than think. See [member think_every] and [member tiers].
static func _coasts(mind: Mind, tick: int, world: World, id: int) -> bool:
	if not mind.coasting or mind.every <= 1 or mind.last_move == null or mind.brain == null or mind.ride != null or mind.throw_stage != 0:
		return false
	if mind.last_think_tick < 0 or tick <= mind.last_think_tick or tick - mind.last_think_tick >= mind.every:
		return false
	return not world.woken.has(id)


## Whether no live enemy of [param me] is within [member think_near] metres.
static func _nobody_near(me: DotBotContact, world: World) -> bool:
	var near_sq := think_near * think_near
	if world.near_cell > 0.0 and world.near_cell == think_near:
		var cx := int(floorf(me.position.x / think_near)) + 4096
		var cz := int(floorf(me.position.z / think_near)) + 4096
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var cell: Variant = world.near_cells.get((cx + dx) * 8192 + cz + dz)
				if cell == null:
					continue
				for item: DotBotContact in cell:
					if item.id != me.id and me.is_enemy(item) and item.position.distance_squared_to(me.position) < near_sq:
						return false
		return true
	for item: DotBotContact in world.contacts():
		if item.alive and item.id != me.id and me.is_enemy(item) and item.position.distance_squared_to(me.position) < near_sq:
			return false
	return true


## Turns the brain's [member DotBotIntent.throw] into the presses a person makes: draw the
## throwable, cook it, let go along the view the brain chose, and draw what was held before.
## While a throw is under way it owns the trigger, the slot and the view; the legs stay the
## brain's.
static func _throw(bot: ArenaPlayer, mind: Mind, intent: DotBotIntent, move: DotFpsCommand, fire: DotWeaponCommand, tick: int, tick_rate: float) -> void:
	var arsenal := bot.arsenal
	if arsenal == null or not bot.is_alive():
		mind.throw_stage = 0
		return
	if mind.throw_stage == 0:
		if not intent.throw or not _has_throwable(arsenal):
			return
		mind.throw_stage = THROW_DRAW
		mind.throw_view = Vector2(intent.yaw, intent.pitch)
		mind.throw_back = arsenal.current_slot()
		mind.throw_at = tick

	var thrown := AwWeaponIds.thrown_slot()
	if tick - mind.throw_at > int(THROW_GIVE_UP_SEC * tick_rate) and mind.throw_stage < THROW_RELEASE:
		mind.throw_stage = THROW_RELEASE if mind.throw_stage == THROW_COOK else THROW_BACK

	fire.set_button(DotWeaponCommand.BUTTON_ATTACK, false)
	match mind.throw_stage:
		THROW_DRAW:
			fire.slot = thrown
			if arsenal.current_slot() == thrown and not arsenal.is_switching():
				mind.throw_stage = THROW_COOK
				mind.throw_cook_from = tick
				fire.set_button(DotWeaponCommand.BUTTON_ATTACK, true)
		THROW_COOK:
			fire.set_button(DotWeaponCommand.BUTTON_ATTACK, true)
			if tick - mind.throw_cook_from >= maxi(1, int(COOK_SEC * tick_rate)):
				mind.throw_stage = THROW_RELEASE
		THROW_RELEASE:
			# The trigger up on this tick is the throw.
			mind.throw_stage = THROW_BACK
		THROW_BACK:
			var back := mind.throw_back if mind.throw_back > 0 and mind.throw_back != thrown and arsenal.has_slot(mind.throw_back) else 0
			if back > 0 and arsenal.current_slot() != back:
				fire.slot = back
			if back == 0 or arsenal.current_slot() == back or tick - mind.throw_at > int(THROW_GIVE_UP_SEC * tick_rate) * 2:
				mind.throw_stage = 0

	if mind.throw_stage in [THROW_DRAW, THROW_COOK, THROW_RELEASE]:
		# Looking where the brain lobbed it until it is gone.
		for command: Object in [move, fire]:
			command.set(&"yaw", mind.throw_view.x)
			command.set(&"pitch", mind.throw_view.y)


## Whether [param arsenal] holds a throwable it can pay for.
static func _has_throwable(arsenal: DotWeaponArsenal) -> bool:
	var slot := arsenal.slot_at(AwWeaponIds.thrown_slot())
	if slot == null or slot.def == null:
		return false
	var def := slot.def
	if not def.uses_ammo():
		return true
	if def.uses_magazine():
		return slot.magazine >= def.cost_per_use
	return def.infinite_reserve or arsenal.ammo().has(def.ammo_type, def.cost_per_use)


## Forgets a bot that left, so its brain is not told about hits any more.
static func forget(game: Object, id: int) -> void:
	if game != null and game.has_meta(WORLD_META):
		var held: Variant = game.get_meta(WORLD_META)
		if held is World:
			(held as World).brains.erase(id)
			(held as World)._loadouts.erase(id)
			(held as World).woken.erase(id)
