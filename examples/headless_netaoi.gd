extends DotGameCheckSuite

## ArenaNetAoi: the relevance rings are off for a 16v16, on above sv_net_aoi_players with
## hysteresis, read their cvars live, and describe the same rings dot-net applies.

const ArenaNetAoi := preload("../game/arena_net_aoi.gd")


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _run() -> void:
	print("arena: net relevance rings")
	var console := DotConsole.new()
	add_child(console)
	var aoi := ArenaNetAoi.new()
	aoi.bind_cvars(console.cvar, DotConVar.FLAG_ARCHIVE)
	var interest := DotNetInterestDistance.new()
	var base := [interest.radius, interest.far_every, interest.far_distance, interest.far_tiers, interest.far_coherent]

	_check(console.get_int("sv_net_aoi_players") == 32 and is_equal_approx(console.get_float("sv_net_radius"), 120.0), "defaults: rings from the 33rd player, 120 m radius")
	_check(console.get_int("sv_net_far_every") == 2 and console.get_int("sv_net_far_tiers") == 2 and is_equal_approx(console.get_float("sv_net_far_distance"), 40.0), "defaults: half rate past 40 m, quarter past 80 m")

	for players in [1, 16, 31, 32]:
		var changed := aoi.refresh(interest, players)
		_check(not changed and not aoi.active, "%d players: rings stay off" % players)
		_check([interest.radius, interest.far_every, interest.far_distance, interest.far_tiers, interest.far_coherent] == base, "%d players: the interest object is exactly as it was" % players)

	_check(aoi.refresh(interest, 33) and aoi.active, "33 players turn the rings on")
	_check(is_equal_approx(interest.radius, 120.0) and interest.far_every == 2 and interest.far_tiers == 2 and interest.far_coherent and is_equal_approx(interest.far_distance, 40.0), "and set radius, divisor, bands and coherence on the interest")
	_check(not aoi.refresh(interest, 32) and aoi.active, "32 players do not turn them off again (hysteresis)")
	_check(not aoi.refresh(interest, 31) and aoi.active, "nor 31")
	_check(aoi.refresh(interest, 30) and not aoi.active, "30 players do")
	_check([interest.radius, interest.far_every, interest.far_distance, interest.far_tiers, interest.far_coherent] == base, "and the interest is back to what it was")

	console.set_cvar("sv_net_aoi_players", "0")
	console.set_cvar("sv_net_radius", "50")
	console.set_cvar("sv_net_far_distance", "10")
	console.set_cvar("sv_net_far_every", "4")
	console.set_cvar("sv_net_far_tiers", "3")
	console.set_cvar("sv_net_far_coherent", "0")
	_check(aoi.refresh(interest, 2) and aoi.active, "sv_net_aoi_players 0 is always on")
	_check(is_equal_approx(interest.radius, 50.0) and interest.far_every == 4 and interest.far_tiers == 3 and not interest.far_coherent and is_equal_approx(interest.far_distance, 10.0), "cvars are read live")
	console.set_cvar("sv_net_far_every", "99")
	var _r := aoi.refresh(interest, 2)
	_check(interest.far_every == 16, "a divisor past dot-net's 16 is clamped")
	console.set_cvar("sv_net_aoi_players", "9999")
	_check(aoi.refresh(interest, 128) == true and not aoi.active, "9999 turns them off whatever the count")

	var a := ArenaNetAoi.new()
	_check(a.ring_of(0.0) == 0 and a.ring_of(40.0) == 0 and a.ring_of(40.1) == 1 and a.ring_of(80.0) == 1 and a.ring_of(80.1) == 2 and a.ring_of(120.0) == 2 and a.ring_of(120.1) == -1, "rings: near, mid, far, none at 40/80/120 m")
	_check(a.every_for(0) == 1 and a.every_for(1) == 2 and a.every_for(2) == 4, "full, half and quarter rate")
	console.free()
	_report()
