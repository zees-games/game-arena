extends DotGameCheckSuite

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaEffects := preload("../game/arena_effects.gd")

## Team deathmatch must spawn each side at its own spots; a free-for-all stays random.
## Every built-in dm_ map and every imported map that is linked: per team, many respawns, each landing on a
## spawn of that team's set (tagged by the map, else the documented split of the list into two halves).
const PLAYERS := 8
const ROUNDS := 12


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena team spawn")
	var ids: Array[StringName] = [&"dm_box", &"dm_atrium", &"dm_pit"]
	var extra: Array[StringName] = []
	for a in OS.get_cmdline_user_args():
		extra.append(StringName(a))
	if extra.is_empty():
		for id in ["crackhouse", "blackhawkdown", "dm-morpheus", "gg-woods", "dm-overwatch", "surf_ski_2"]:
			extra.append(StringName(id))
	for id in extra:
		if ArenaMap.by_id(id) == null:
			print("skip %s: not linked" % id)
		else:
			ids.append(id)
	for id in ids:
		_one(id)
	_ffa_is_random()
	_split_is_documented()
	_protection()
	_jump_gate()
	_report_sections(ids.size() + 4, ids.size() + 4, ids.size() + 4, ids.size() * 2 + 27)


func _game(map: ArenaMap, mode: ArenaMode, split := true) -> ArenaGame:
	var game := ArenaGame.new()
	game.team_spawn_split = split
	game.tick_rate = 64
	game.score_limit = 100000
	game.time_limit_sec = 0.0
	game.headless = true
	game.is_authority = true
	game.register_service = false
	game.mode = mode
	add_child(game)
	if not game.setup(map).ok:
		return null
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	return game


func _one(id: StringName) -> void:
	var map := ArenaMap.by_id(id)
	var game := _game(map, ArenaMode.team_deathmatch())
	if game == null:
		_check(false, "%s sets up" % id)
		return
	for b in PLAYERS:
		var _a := game.add_player(b + 1, "P%d" % b, 1 + (b % 2))
	game.start(0)
	game.tick({})
	var sets := map.team_spawn_sets()
	var spots := {1: [], 2: []}
	for team in [1, 2]:
		for index in sets[team]:
			spots[team].append(map.spawns[index].origin)
	_check(not spots[1].is_empty() and not spots[2].is_empty(), "%s: both teams own spawns" % id, "%d / %d" % [spots[1].size(), spots[2].size()])
	var bad := 0
	var total := 0
	for r in ROUNDS:
		for b in PLAYERS:
			var _r := game.respawn_player(b + 1)
			var team := game.team_of(b + 1)
			var at: Vector3 = game.player_for(b + 1).controller.state.position
			var ok := false
			for p: Vector3 in spots.get(team, []):
				if p.distance_to(at) < 0.6:
					ok = true
					break
			total += 1
			if not ok:
				bad += 1
		game.tick({})
	print("MAP %s: tagged %d, red %d blue %d, off-team %d of %d" % [id, map.spawn_tags.size() - Array(map.spawn_tags).count(""), spots[1].size(), spots[2].size(), bad, total])
	_check(bad == 0, "%s: every spawn is in the player's team set" % id, "%d of %d off" % [bad, total])
	game.queue_free()


## FFA ignores teams: players land on both ends of dm_atrium.
func _ffa_is_random() -> void:
	var map := ArenaMap.dm_atrium()
	var game := _game(map, ArenaMode.free_for_all())
	var seen := {}
	for b in PLAYERS:
		var _a := game.add_player(b + 1, "P%d" % b)
	game.start(0)
	game.tick({})
	for r in ROUNDS:
		for b in PLAYERS:
			var _r := game.respawn_player(b + 1)
			var at: Vector3 = game.player_for(b + 1).controller.state.position
			seen["red" if at.z < 0.0 else "blue"] = true
		game.tick({})
	_check(seen.size() == 2, "free-for-all uses both ends of dm_atrium", str(seen.keys()))
	game.queue_free()


## The fallback itself: a map with no sides is cut in two halves by position, both the same size, the
## red half holding one anchor; a map that tags both sides is left alone; `arena_team_spawn_split` 0 keeps one pool.
func _split_is_documented() -> void:
	var map := ArenaMap.dm_box()
	for index in range(map.spawns.size()):
		map.spawn_tags[index] = ""
	var n := map.split_spawns_for_teams()
	var sets := map.team_spawn_sets()
	var red := Array(map.spawn_tags).count("red")
	var blue := Array(map.spawn_tags).count("blue")
	_check(n == map.spawns.size() and red == blue and red == map.spawns.size() / 2, "an untagged map splits into two equal halves", "%d red %d blue" % [red, blue])
	var centre_red := Vector3.ZERO
	var centre_blue := Vector3.ZERO
	for i in range(map.spawns.size()):
		if map.spawn_tag(i) == &"red":
			centre_red += map.spawns[i].origin / float(red)
		elif map.spawn_tag(i) == &"blue":
			centre_blue += map.spawns[i].origin / float(blue)
	_check(centre_red.distance_to(centre_blue) > 5.0, "and the halves sit apart", "%.1f m" % centre_red.distance_to(centre_blue))
	_check(map.split_spawns_for_teams() == map.spawns.size() or map.split_spawns_for_teams() == 0, "and running it again does no harm")
	var tagged := ArenaMap.dm_atrium()
	var before := tagged.spawn_tags.duplicate()
	_check(tagged.split_spawns_for_teams() == 0 and tagged.spawn_tags == before, "a map that tags both sides keeps its tags")
	var off := _game(ArenaMap.dm_pit(), ArenaMode.team_deathmatch(), false)
	_check(off != null and Array(off.map.spawn_tags).count("") == off.map.spawns.size(), "with the split off both teams share one pool", str(off.map.spawn_tags) if off != null else "no game")
	if off != null:
		off.queue_free()


## Spawn protection: lasts the mode's seconds for the spawned player and no longer, the victim is the one protected
## and not the attacker, a shot or a move ends it when `spawn_protection_break` says so, and 0 seconds is none.
func _protection() -> void:
	var game := _game(ArenaMap.dm_atrium(), ArenaMode.team_deathmatch())
	game.match_node.rules.spawn_protection_sec = 1.0
	game.player_stack.refresh_spawn_rules()
	for b in 4:
		var _a := game.add_player(b + 1, "P%d" % b, 1 + (b % 2))
	game.start(0)
	game.tick({})
	var _r := game.respawn_player(1)
	var spawned := game.current_tick()
	var rate := game.tick_rate
	var first_hurt := -1
	var type := DotDamageType.make(&"generic")
	# Player 2 (the other side) shoots player 1 every tick; player 1 is hit back by 2 after both spawned.
	for step in range(rate * 4):
		var hit := DotDamage.make(2, 1, 0.01, type)
		hit.tick = game.current_tick()
		var done := game.combat.apply_damage(hit)
		if first_hurt < 0 and done.health_lost > 0.0:
			first_hurt = game.current_tick() - spawned
		game.tick({})
	_check(first_hurt >= rate - 2 and first_hurt <= rate + 3, "protection lasts spawn_protection_sec, no more and no less", "first hurt after %d ticks of %d" % [first_hurt, rate])
	_check(not game.player_for(1).health.is_protected(game.current_tick()) and not game.effects.has(ArenaEffects.PROTECTED, 1)
		and not game.player_stack.spawns.protection.is_protected("1", game.current_tick()), "and all three records have ended")
	# The attacker's own protection does not stop it hurting somebody unprotected.
	var _r2 := game.respawn_player(2)
	var hit2 := DotDamage.make(2, 1, 1.0, type)
	hit2.tick = game.current_tick()
	_check(game.combat.apply_damage(hit2).health_lost > 0.0, "a protected shooter still hurts an unprotected target")
	var hit3 := DotDamage.make(1, 2, 1.0, type)
	hit3.tick = game.current_tick()
	_check(game.combat.apply_damage(hit3).health_lost <= 0.0, "but the one just spawned is not hurt back")
	# Breaks.
	game.config.spawn_protection_break = 2
	var _r3 := game.respawn_player(3)
	_check(game.player_for(3).health.is_protected(game.current_tick()), "freshly spawned is protected")
	var walk := DotFpsCommand.new()
	walk.move = Vector2(0.0, 1.0)
	game.tick({3: [walk, DotWeaponCommand.new()]})
	_check(not game.player_for(3).health.is_protected(game.current_tick()) and not game.effects.has(ArenaEffects.PROTECTED, 3), "the first move ends it when the cvar says move")
	game.config.spawn_protection_break = 0
	var _r4 := game.respawn_player(3)
	game.tick({3: [walk, DotWeaponCommand.new()]})
	_check(game.player_for(3).health.is_protected(game.current_tick()), "and a move does not with the cvar at 0")
	game.config.spawn_protection_break = 1
	var _r5 := game.respawn_player(3)
	game.tick({3: [walk, DotWeaponCommand.new()]})
	_check(game.player_for(3).health.is_protected(game.current_tick()), "a move does not end it when the cvar says shot")
	var fire := DotWeaponCommand.new()
	fire.set_button(DotWeaponCommand.BUTTON_ATTACK, true)
	game.tick({3: [DotFpsCommand.new(), fire]})
	_check(not game.player_for(3).health.is_protected(game.current_tick()), "the first shot ends it when the cvar says shot")
	_check(not game.player_for(3).protected_view, "and the bubble goes with it")
	_protection_distance(game, walk)


## Spawn protection by distance walked, the bubble cvar and a 0.5 s window; frees [param game].
func _protection_distance(game: ArenaGame, walk: DotFpsCommand) -> void:
	var rate := game.tick_rate
	# Distance: with the shot/move bits off, travel past spawn_protection_move_feet (2 ft = 0.61 m) ends it.
	game.config.spawn_protection_break = 0
	_check(game.config.spawn_protection_move_feet == 2.0 and game.config.spawn_protection_bubble, "defaults: 2 feet, bubble on")
	game.config.spawn_protection_sec = 3.0
	var _r6 := game.respawn_player(3)
	game.tick({})
	_check(game.player_for(3).protected_view, "a protected player shows the bubble")
	var start := game.player_for(3).global_position
	var steps := 0
	while game.player_for(3).health.is_protected(game.current_tick()) and steps < rate * 2:
		game.tick({3: [walk, DotWeaponCommand.new()]})
		steps += 1
	var travelled := game.player_for(3).global_position.distance_to(start)
	_check(steps < rate and travelled >= 0.55 and travelled < 1.6, "walking ends protection after about two feet", "ended after %d ticks at %.2f m" % [steps, travelled])
	_check(not game.effects.has(ArenaEffects.PROTECTED, 3) and not game.player_stack.spawns.protection.is_protected("3", game.current_tick()), "in all three records")
	game.config.spawn_protection_move_feet = 0.0
	var _r7 := game.respawn_player(3)
	for _i in 40:
		game.tick({3: [walk, DotWeaponCommand.new()]})
	_check(game.player_for(3).health.is_protected(game.current_tick()), "feet 0 turns the distance check off")
	game.config.spawn_protection_bubble = false
	game.tick({3: [walk, DotWeaponCommand.new()]})
	_check(not game.player_for(3).protected_view, "bubble cvar off hides the bubble")
	game.config.spawn_protection_move_feet = 2.0
	game.config.spawn_protection_bubble = true
	game.config.spawn_protection_sec = 0.5
	game.match_node.rules.spawn_protection_sec = 0.5
	game.player_stack.refresh_spawn_rules()
	var _r8 := game.respawn_player(4)
	var half := 0
	while game.player_for(4).health.is_protected(game.current_tick()) and half < rate:
		game.tick({})
		half += 1
	_check(absi(half - rate / 2) <= 2, "0.5 s protection lasts half a second", "%d ticks of %d" % [half, rate])
	game.queue_free()


func _jump_gate() -> void:
	var Gate := preload("../game/arena_jump_gate.gd")
	var gate := Gate.new()
	var held := DotFpsCommand.new()
	held.set_button(DotFpsCommand.BUTTON_JUMP, true)
	gate.filter(held, true)
	var spawn_cmd := DotFpsCommand.new()
	spawn_cmd.set_button(DotFpsCommand.BUTTON_JUMP, true)
	gate.filter(spawn_cmd, false)
	_check(not spawn_cmd.is_pressed(DotFpsCommand.BUTTON_JUMP), "space still held on the first spawned frame does not jump")
	var again := DotFpsCommand.new()
	again.set_button(DotFpsCommand.BUTTON_JUMP, true)
	gate.filter(again, false)
	_check(not again.is_pressed(DotFpsCommand.BUTTON_JUMP), "nor while it stays held")
	var up := DotFpsCommand.new()
	gate.filter(up, false)
	var next := DotFpsCommand.new()
	next.set_button(DotFpsCommand.BUTTON_JUMP, true)
	gate.filter(next, false)
	_check(next.is_pressed(DotFpsCommand.BUTTON_JUMP), "after a release, jump works again")
	var off := Gate.new()
	var c := DotFpsCommand.new()
	c.set_button(DotFpsCommand.BUTTON_JUMP, true)
	off.filter(c, true, false)
	off.filter(c, false, false)
	_check(c.is_pressed(DotFpsCommand.BUTTON_JUMP), "with cl_respawn_jump_gate 0 nothing is swallowed")
