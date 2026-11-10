extends RefCounted

## Relevance tiers for a big server (arena-128-scale-1 / net-aoi-1): distance rings around each player that decide how often, and whether, another player is sent, built on dot-net's own DotNetInterestDistance (no new wire format).
## Defaults: inside far_distance (40 m) every snapshot; 40-80 m every far_every-th (2); 80 m to radius (120 m) every 4th; past radius nothing. The observer's own entity and a beaconed player (always_relevant) are never culled; scoreboard, kill feed and match state are not entity snapshots.
## Off until the room is big (min_players, 32: the tiers start at the 33rd player, with OFF_MARGIN hysteresis); an entity leaving the radius keeps its last drawn pose on the client (no pop). Pinned by headless_netaoi.

const OFF_MARGIN := 2
const BASE_UNSET := -1.0

var min_players: int = 32
var radius: float = 120.0
var far_distance: float = 40.0
var far_every: int = 2
var far_tiers: int = 2
var far_coherent: bool = true

var active: bool = false
## What the interest object held before the first refresh: restored when the tiers go off.
var _base: Dictionary = {}
var _cvars: Dictionary = {}


## Registers the cvars through [param add_cvar] (DotModule.add_cvar) and keeps them to read live.
func bind_cvars(add_cvar: Callable, flags: int) -> void:
	_cvars["min_players"] = add_cvar.call("sv_net_aoi_players", str(min_players),
		"Relevance tiers start above this many players, bots included (0 is always on, 9999 never)", flags)
	_cvars["radius"] = add_cvar.call("sv_net_radius", str(radius),
		"With the tiers on: players farther than this many metres are not sent at all", flags)
	_cvars["far_distance"] = add_cvar.call("sv_net_far_distance", str(far_distance),
		"With the tiers on: past this many metres a player is sent every sv_net_far_every-th snapshot", flags)
	_cvars["far_every"] = add_cvar.call("sv_net_far_every", str(far_every),
		"With the tiers on: the mid ring's snapshot divisor (2 is half rate); the ring after it is twice that", flags)
	_cvars["far_tiers"] = add_cvar.call("sv_net_far_tiers", str(far_tiers),
		"With the tiers on: rings past sv_net_far_distance, each twice as far and half as often (1 to 4)", flags)
	_cvars["far_coherent"] = add_cvar.call("sv_net_far_coherent", "1" if far_coherent else "0",
		"With the tiers on: every client gets the same turns, so peers in step share work (1) or each is staggered (0)", flags)


## Reads the cvars (when bound) into the fields.
func pull_cvars() -> void:
	if _cvars.is_empty():
		return
	min_players = (_cvars["min_players"] as DotConVar).get_int()
	radius = (_cvars["radius"] as DotConVar).get_float()
	far_distance = (_cvars["far_distance"] as DotConVar).get_float()
	far_every = clampi((_cvars["far_every"] as DotConVar).get_int(), 1, 16)
	far_tiers = clampi((_cvars["far_tiers"] as DotConVar).get_int(), 1, 4)
	far_coherent = (_cvars["far_coherent"] as DotConVar).get_bool()


## Whether the tiers should be on for [param players] given the current state (with hysteresis).
func wants_on(players: int) -> bool:
	if active:
		return players > min_players - OFF_MARGIN
	return players > min_players


## Applies (or lifts) the tiers on [param interest] for a room of [param players]. Safe to call
## every second; returns true when the state changed.
func refresh(interest: DotNetInterest, players: int) -> bool:
	if interest == null:
		return false
	pull_cvars()
	if _base.is_empty():
		_base = {
			"far_every": interest.far_every, "far_distance": interest.far_distance,
			"far_tiers": interest.far_tiers, "far_coherent": interest.far_coherent,
			"radius": (interest as DotNetInterestDistance).radius if interest is DotNetInterestDistance else BASE_UNSET,
		}
	var on := wants_on(players)
	var changed := on != active
	active = on
	if on:
		interest.far_every = far_every
		interest.far_distance = far_distance
		interest.far_tiers = far_tiers
		interest.far_coherent = far_coherent
		if interest is DotNetInterestDistance:
			(interest as DotNetInterestDistance).radius = radius
	else:
		interest.far_every = int(_base["far_every"])
		interest.far_distance = float(_base["far_distance"])
		interest.far_tiers = int(_base["far_tiers"])
		interest.far_coherent = bool(_base["far_coherent"])
		if interest is DotNetInterestDistance and float(_base["radius"]) != BASE_UNSET:
			(interest as DotNetInterestDistance).radius = float(_base["radius"])
	return changed


## The ring [param distance] metres out falls in: 0 inside far_distance, 1..far_tiers beyond it,
## -1 past the radius (not sent). What dot-net does, written down so a suite can pin it.
func ring_of(distance: float) -> int:
	if distance > radius:
		return -1
	if far_every <= 1 or distance <= far_distance:
		return 0
	var band := 1
	var edge := far_distance * 2.0
	while band < far_tiers and distance > edge:
		band += 1
		edge *= 2.0
	return band


## Snapshots between sends for [param ring] (1 = every one).
func every_for(ring: int) -> int:
	if ring <= 0:
		return 1
	return far_every << (ring - 1)
