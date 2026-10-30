extends DotGameCheckSuite

const ArenaBots := preload("../game/arena_bots.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")

## A bot climbs a ladder on an imported map: crackhouse has ladders up to platforms that nothing else reaches.
##
## [codeblock]
## ./game.sh test headless_bot_ladders
## [/codeblock]
const MAP := &"crackhouse"
const TICK_RATE := 64
const BOT := 1
## Seconds a bot gets to climb; the tries are different ladders.
const CLIMB_SECONDS := 25.0
const TRIES := 6
const CHECKS := 6
const SECTIONS := 1


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena bot ladders")
	var game := ArenaGame.new()
	game.tick_rate = TICK_RATE
	game.score_limit = 100000
	game.time_limit_sec = 0.0
	game.headless = true
	game.is_authority = true
	game.register_service = false
	add_child(game)
	var map := ArenaMap.by_id(MAP)
	_check(map != null and game.setup(map).ok, "the game sets up on %s" % MAP)
	if map == null:
		_report_sections(1, 0, SECTIONS, CHECKS)
		return
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	var _added := game.add_player(BOT, "Climber")
	game.start(0)
	game.tick({})
	await get_tree().process_frame

	var world := ArenaBots.world_for(game)
	var _first := world.route(Vector3.ZERO, Vector3.ONE)
	var frames := 0
	while world.is_route_pending() and frames < 2400:
		await get_tree().process_frame
		frames += 1
	var _surf := world.surf_for_map()
	_check(world.ladder_count() > 0, "ladders are linked into the mesh", "%d" % world.ladder_count())
	_check(world.ladder_fn.is_valid(), "the world answers the brain's ladder question")

	var nav := world.nav_for_rides()
	var tries := _tries(nav)
	_check(tries.size() >= TRIES, "ladders reach a platform the mesh joins by no other way", "%d found" % tries.size())

	var bot := game.player_for(BOT)
	var reached := 0
	var grabbed := 0
	var tick := 1000
	for t in mini(TRIES, tries.size()):
		var foot: Vector3 = tries[t]["foot"]
		var goal: Vector3 = tries[t]["goal"]
		bot.controller.state.position = foot
		bot.controller.state.velocity = Vector3.ZERO
		var mind := ArenaBots.Mind.new()
		mind.seed = 5 + t
		var done := false
		var grabbed_now := false
		var steps := int(CLIMB_SECONDS * TICK_RATE)
		for i in steps:
			var commands := {BOT: ArenaBots.think(game, bot, mind, tick, float(TICK_RATE))}
			if i == 1:
				mind.brain.set(&"_waypoint", goal)
			game.tick(commands)
			tick += 1
			grabbed_now = grabbed_now or bot.controller.state.mode == bot.ladder.mode_id
			var feet: Vector3 = bot.controller.state.position
			if Vector2(feet.x - goal.x, feet.z - goal.z).length() < 2.0 and absf(feet.y - goal.y) < 1.0:
				done = true
				break
			if i % 16 == 0:
				await get_tree().physics_frame
		reached += 1 if done else 0
		grabbed += 1 if grabbed_now else 0
	# A few imported ladders sit a hair beyond the player's grab reach behind a wall: no climber can take those.
	_check(grabbed >= 3, "the bot gets onto at least three ladders", "%d of %d" % [grabbed, mini(TRIES, tries.size())])
	_check(reached >= grabbed, "every ladder the bot gets onto it climbs to the platform", "%d of %d" % [reached, grabbed])

	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
	_report_sections(1, 1, SECTIONS, CHECKS)


## Up to a few {foot, goal}: a ladder's foot and a mesh point on its top platform 4 to 8 m off whose route to the foot crosses a ladder ride and cannot be walked.
func _tries(nav: DotBotNav) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for ride in nav.rides():
		if int(ride["id"]) < DotBotLinks.LADDER_ID or out.size() >= TRIES:
			continue
		var foot: Vector3 = ride["from"]
		var top: Vector3 = ride["to"]
		for k in 8:
			var a := TAU * float(k) / 8.0
			var at := nav.closest(top + Vector3(cos(a), 0.0, sin(a)) * 5.0)
			if absf(at.y - top.y) > 0.6 or Vector2(at.x - foot.x, at.z - foot.z).length() < 4.0:
				continue
			var way := nav.route(foot, at)
			var rides: PackedInt32Array = way["rides"]
			var climbs := false
			for r in rides:
				climbs = climbs or r >= DotBotLinks.LADDER_ID
			if climbs:
				out.append({"foot": foot, "goal": at})
				break
	return out
