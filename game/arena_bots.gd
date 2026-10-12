extends RefCounted
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
## sound for every shot fired (from [signal ArenaPlayer.used]) and who hit whom (from
## [signal ArenaGame.hit_confirmed]). Nothing else, so it cannot see through a wall.
##
## [b]Deterministic per bot[/b]: the brain's randomness is seeded from the bot's id, and its
## clock is the game's tick, so two runs of the same inputs play the same bots.

const ArenaPlayer := preload("arena_player.gd")

## Where the world is kept on the game.
const WORLD_META := &"arena_bot_world"

## Height of the eye and of a target's chest above its feet, metres.
const EYE := 1.6
const CHEST := 1.25


## One bot's memory between ticks. Kept by the caller, one per bot.
class Mind:
	extends RefCounted
	var brain: DotBotBrain = null
	var seed: int = 0


## What the brain may know of this game.
class World:
	extends DotBotWorld

	var game: Object = null
	var tick_rate: float = 64.0
	var brains: Dictionary = {}
	var _tick: int = -1
	var _contacts: Array = []
	var _by_id: Dictionary = {}

	func _init(p_game: Object) -> void:
		game = p_game
		if game.has_signal(&"hit_confirmed"):
			game.connect(&"hit_confirmed", _on_hit)
		if game.has_signal(&"player_added"):
			game.connect(&"player_added", _hear_player)
		for p in game.call("players"):
			_hear_player(p)

	## Rebuilds the contacts once a tick, however many bots ask.
	func refresh(tick: int, rate: float) -> void:
		tick_rate = maxf(rate, 1.0)
		if tick == _tick:
			return
		_tick = tick
		_contacts.clear()
		_by_id.clear()
		var teams := _team_mode()
		for p: ArenaPlayer in game.call("players"):
			var c := DotBotContact.new()
			c.id = p.player_id
			c.eye_height = EYE
			c.aim_height = CHEST
			c.alive = p.is_alive()
			c.team = p.team if teams else 0
			if p.controller != null:
				c.position = p.controller.state.position
				c.velocity = p.controller.state.velocity
				c.view_yaw = p.controller.state.yaw
				c.view_pitch = p.controller.state.pitch
			else:
				c.position = p.global_position
			if p.health != null and p.health.max_health > 0.0:
				c.health = p.health.health / p.health.max_health
			_contacts.append(c)
			_by_id[c.id] = c

	func now() -> float:
		return float(maxi(_tick, 0)) / tick_rate

	func contact(id: int) -> DotBotContact:
		return _by_id.get(id)

	func contacts() -> Array:
		return _contacts

	func line_of_sight(from: Vector3, to: Vector3) -> bool:
		var combat: Variant = game.get("combat")
		var trace: Variant = (combat as Object).get("trace") if combat is Object else null
		if trace is DotTrace:
			return (trace as DotTrace).line_of_sight(from, to)
		return true

	func waypoints() -> PackedVector3Array:
		var out := PackedVector3Array()
		var map: Variant = game.get("map")
		var spawns: Array = (map as Object).get("spawns") if map is Object else []
		for spawn: Transform3D in spawns:
			out.append(spawn.origin)
		return out

	func _team_mode() -> bool:
		var mode: Variant = game.get("mode")
		return mode is Object and (mode as Object).has_method("is_team_mode") and bool((mode as Object).call("is_team_mode"))

	## Every shot is a sound; a swing or a throw is a quieter one.
	func _hear_player(p: Object) -> void:
		if not (p is ArenaPlayer) or p.has_meta(&"arena_bot_heard"):
			return
		p.set_meta(&"arena_bot_heard", true)
		var body := p as ArenaPlayer
		body.used.connect(func(outcome: DotWeaponOutcome) -> void:
			if outcome == null or not outcome.used:
				return
			var loud := 1.0 if not outcome.shots.is_empty() or not outcome.spawns.is_empty() else 0.3
			emit_sound(body.muzzle_position(), loud, body.player_id, now())
		)

	func _on_hit(attacker: int, victim: int, _amount: float, _point: Vector3, _headshot: bool, _lethal: bool) -> void:
		var brain: DotBotBrain = brains.get(victim)
		if brain == null:
			return
		var from := contact(attacker)
		brain.hurt(from.eye() if from != null else Vector3.INF, now())


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
	var move := DotFpsCommand.new()
	var fire := DotWeaponCommand.new()

	if game == null or bot == null:
		return [move, fire]

	var world := world_for(game)
	world.refresh(tick, tick_rate)

	if mind.brain == null:
		mind.brain = DotBotBrain.new(mind.seed if mind.seed != 0 else bot.player_id, DotBotSettings.of(game))
	world.brains[bot.player_id] = mind.brain

	var me := world.contact(bot.player_id)
	var intent := mind.brain.think(me, world, world.now())
	intent.write_move(move)
	intent.write_fire(fire)
	move.sanitise()
	fire.sanitise()
	return [move, fire]


## Forgets a bot that left, so its brain is not told about hits any more.
static func forget(game: Object, id: int) -> void:
	if game != null and game.has_meta(WORLD_META):
		var held: Variant = game.get_meta(WORLD_META)
		if held is World:
			(held as World).brains.erase(id)
