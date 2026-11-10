extends "bot_map_base.gd"


## Bots set loose on each imported map must leave their spawns: no bot may move less than [constant MIN_MOVE] m in [constant SECONDS] s. Prints one line per map.
## Run: [code]./game.sh test headless_bot_spawn[/code], or with map names after [code]--[/code].
const BOTS := 8
const SECONDS := 20.0
const MIN_MOVE := 3.0


func _title() -> String:
	return "game-arena bots leave their spawns"


func _default_maps() -> Array[StringName]:
	return [&"crackhouse", &"blackhawkdown", &"dm-morpheus", &"gg-woods", &"dm-overwatch", &"gg-garage", &"aim-forts"]


func _one(id: StringName) -> void:
	var game := await _boot_map(id, BOTS)
	if game == null:
		return
	var world := _world
	var minds := _make_minds(BOTS)
	var start := {}
	var far := {}
	var tick := 1000
	var nav := world.nav_for_rides()
	for i in int(SECONDS * TICK_RATE):
		_tick_bots(game, minds, BOTS, tick)
		tick += 1
		if i == 1:
			for b in BOTS:
				var p := game.player_for(b + 1)
				start[b + 1] = p.controller.state.position
				far[b + 1] = 0.0
		elif i > 1:
			for b in BOTS:
				var p := game.player_for(b + 1)
				if p != null and p.controller.state.position.distance_to(start[b + 1]) > far[b + 1]:
					far[b + 1] = p.controller.state.position.distance_to(start[b + 1])
		if i % 16 == 0:
			await get_tree().physics_frame
	var stuck := 0
	var detail := PackedStringArray()
	for b in BOTS:
		if far[b + 1] < MIN_MOVE:
			stuck += 1
			var sp: Vector3 = start[b + 1]
			var off := nav.closest(sp).distance_to(sp) if nav != null and nav.is_ready() else -1.0
			var linked := 0
			for o in BOTS:
				if o != b and nav != null and nav.joined(sp, start[o + 1]):
					linked += 1
			var brain: DotBotBrain = (minds[b + 1] as ArenaBots.Mind).brain
			var tag := " %s unstick %d" % [str(brain.last.state), brain._unstick.total] if brain != null else ""
			detail.append("%.1f,%.1f,%.1f(nav %.1f, joined to %d of %d others%s)" % [sp.x, sp.y, sp.z, off, linked, BOTS - 1, tag])
	print("MAP %s: stuck %d of %d (moved < %.0f m in %.0f s); nav ready=%s; %s" % [id, stuck, BOTS, MIN_MOVE, SECONDS,
		str(nav != null and nav.is_ready()), " ".join(detail)])
	_check(stuck == 0, "%s: no bot stuck at spawn" % id, "%d of %d" % [stuck, BOTS])
	await _release(game)
