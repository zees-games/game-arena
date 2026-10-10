extends RefCounted
## What a server's bot does with a tick: whom to fight, where to go, and when to pull the
## trigger, as the same two commands a client sends.
##
## [b]Commands, not a second simulation.[/b] A bot is an [ArenaPlayer] like anybody else and
## moves through the same controller, shoots through the same arsenal and is hit by the same
## lag-compensated trace; all this decides is what it would have pressed. That keeps a bot
## from ever doing something a player could not -- no walking through walls, no shot the
## arsenal would refuse -- and keeps the server's tick order exactly what it is for people.
##
## [b]Not the offline client's bots.[/b] Those aim at whoever is nearest and hold the
## trigger, through walls, from anywhere; they are a test fixture and their own comment says
## so. A server's bot is something somebody plays against, so it fires only at what it can
## see, keeps a fighting distance and strafes there, misses a little, waits a moment before
## reacting to somebody it has just seen, and walks between the map's spawns when there is
## nobody to fight.
##
## [b]Deterministic per bot and tick[/b], from a seed of its id: two servers given the same
## inputs play the same bots, which is what makes a bot's behaviour something a test can
## hold still.

const ArenaPlayer := preload("arena_player.gd")

## Farthest a bot opens fire from, metres.
const FIRE_RANGE := 45.0
## Distance a bot likes to fight at; closer it backs off, further it closes in.
const PREFERRED_RANGE := 9.0
## Seconds between a bot seeing somebody new and shooting at them.
const REACTION_SEC := 0.35
## Degrees of aim error at the start of a fight, shrinking as it goes on.
const AIM_ERROR_DEG := 3.5
## Height of the eye and of a target's chest above its feet, metres.
const EYE := 1.6
const CHEST := 1.25


## One bot's memory between ticks. Kept by the caller, one per bot.
class Mind:
	extends RefCounted
	var target: int = -1
	var seen_since_tick: int = -1
	var waypoint := Vector3.INF
	var strafe := 1.0
	var strafe_until_tick: int = 0
	var seed: int = 0


## [move, fire] for [param bot] this tick.
static func think(game: Object, bot: ArenaPlayer, mind: Mind, tick: int, tick_rate: float) -> Array:
	var move := DotFpsCommand.new()
	var fire := DotWeaponCommand.new()

	if bot == null or not bot.is_alive():
		return [move, fire]

	var here := bot.global_position
	var target := _choose_target(game, bot, mind, tick)

	if target != null:
		var to := target.global_position - here
		var flat := Vector2(to.x, to.z).length()
		var aim_at := target.global_position + Vector3.UP * CHEST
		var from := here + Vector3.UP * EYE

		# Aim error that settles as the fight goes on: a bot that hits with its first round
		# from across the map reads as a cheat, and one that never improves as a dummy.
		var engaged := float(tick - mind.seen_since_tick) / maxf(tick_rate, 1.0)
		var error := AIM_ERROR_DEG * clampf(1.0 - engaged / 2.0, 0.25, 1.0)
		var wobble := _noise(mind.seed, tick)

		var yaw := rad_to_deg(atan2(-to.x, -to.z)) + wobble.x * error
		var pitch := rad_to_deg(atan2((aim_at - from).y, maxf(flat, 0.01))) + wobble.y * error * 0.5

		move.yaw = yaw
		move.pitch = clampf(pitch, -85.0, 85.0)
		fire.yaw = move.yaw
		fire.pitch = move.pitch

		# Keep a fighting distance and strafe there, changing direction now and then.
		if tick >= mind.strafe_until_tick:
			mind.strafe = -mind.strafe
			mind.strafe_until_tick = tick + int(tick_rate * (0.8 + absf(wobble.x)))
		var forward := 1.0 if flat > PREFERRED_RANGE * 1.4 else (-0.6 if flat < PREFERRED_RANGE * 0.6 else 0.0)
		move.move = Vector2(mind.strafe, forward)

		var reacted := engaged >= REACTION_SEC
		fire.set_button(DotWeaponCommand.BUTTON_ATTACK, reacted and flat <= FIRE_RANGE)
		return [move, fire]

	# Nobody to fight: walk to a spawn, then the next one.
	if mind.waypoint == Vector3.INF or Vector2(mind.waypoint.x - here.x, mind.waypoint.z - here.z).length() < 2.0:
		mind.waypoint = _next_waypoint(game, mind, tick)

	if mind.waypoint != Vector3.INF:
		var to_point := mind.waypoint - here
		move.yaw = rad_to_deg(atan2(-to_point.x, -to_point.z))
		move.pitch = 0.0
		move.move = Vector2(0.0, 1.0)
		fire.yaw = move.yaw

	return [move, fire]


## The nearest living enemy the bot can see, keeping the current one while it stays visible
## so a bot does not flick between two people standing a metre apart.
static func _choose_target(game: Object, bot: ArenaPlayer, mind: Mind, tick: int) -> ArenaPlayer:
	var trace: DotTrace = _trace(game)
	var teams := _team_mode(game)
	var from := bot.global_position + Vector3.UP * EYE
	var best: ArenaPlayer = null
	var best_distance := INF

	for other: ArenaPlayer in game.call("players"):
		if other == bot or not other.is_alive():
			continue
		if teams and other.team == bot.team and bot.team != 0:
			continue
		if trace != null and not trace.line_of_sight(from, other.global_position + Vector3.UP * CHEST):
			continue

		var distance := bot.global_position.distance_to(other.global_position)
		if other.player_id == mind.target:
			distance *= 0.7

		if distance < best_distance:
			best_distance = distance
			best = other

	var chosen := best.player_id if best != null else -1
	if chosen != mind.target:
		mind.target = chosen
		mind.seen_since_tick = tick

	return best


static func _next_waypoint(game: Object, mind: Mind, tick: int) -> Vector3:
	var map: Variant = game.get("map")
	var spawns: Array = (map as Object).get("spawns") if map is Object else []
	if spawns.is_empty():
		return Vector3.INF
	var index := absi(hash(mind.seed * 7919 + tick)) % spawns.size()
	return (spawns[index] as Transform3D).origin


static func _trace(game: Object) -> DotTrace:
	var combat: Variant = game.get("combat")
	var trace: Variant = (combat as Object).get("trace") if combat is Object else null
	return trace as DotTrace if trace is DotTrace else null


static func _team_mode(game: Object) -> bool:
	var mode: Variant = game.get("mode")
	return mode is Object and (mode as Object).has_method("is_team_mode") and bool((mode as Object).call("is_team_mode"))


## A smooth -1..1 wobble per bot, from its seed and the tick.
static func _noise(seed: int, tick: int) -> Vector2:
	var t := float(tick) * 0.05 + float(seed % 1000)
	return Vector2(sin(t * 1.3) * cos(t * 0.7), sin(t * 0.9 + 1.7))
