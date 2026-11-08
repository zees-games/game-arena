extends Node

const ArenaGame := preload("arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaFlagView := preload("arena_flag_view.gd")

## What the round is about, when the mode says it is about something.
##
## [b]The arena's first mode that is not "kill people".[/b] Free-for-all, team
## deathmatch and siege are all scored on kills, which means [DotMatch] alone has always
## been enough. Capture the flag and king of the hill are not, and every hand-written
## version of either gets the same things wrong — see dot-objective's notes.
##
## [b]The layout comes from the map's own numbers.[/b] `ArenaMap` is built from
## constants — an extent, a floor height, a list of boxes — which is what lets a
## dedicated server that has never drawn the level still know where everything is. So
## the flags sit at the ends of its longest axis and the hill sits at its centre,
## derived rather than authored: a map added later gets a working layout without
## anybody remembering to place two more things in it.
##
## [codeblock]
## var objectives := ArenaObjectives.new()
## objectives.game = game
## add_child(objectives)
## objectives.setup()
## [/codeblock]

const CHANNEL := "arena.objectives"

## Anything a kind wants to say: a flag taken, a point contested. A HUD connects here.
signal objective_event(id: StringName, what: StringName, data: Dictionary)

## Layout ids a mode names.
const CTF := &"ctf"
const KOTH := &"koth"

const RED := 1
const BLUE := 2

var game: ArenaGame = null

var manager: DotObjectiveManager = null

## The capture-the-flag mechanic when the layout is `ctf`; its manager is [member manager].
var ctf: DotObjectiveCtf = null

## The drawn flags when the game draws at all (never headless); null otherwise.
var flag_view: ArenaFlagView = null

var _last_wire := ""
var _wire_tick := -1000000

## Which layout is running. Empty when the mode has none.
var layout: StringName = &""


func setup() -> DotResult:
	if game == null:
		return DotResult.fail(DotError.CODE_STATE, "ArenaObjectives needs a game.")
	if game.mode == null:
		return DotResult.fail(DotError.CODE_STATE, "There is no mode.")

	layout = game.mode.objective_layout
	if layout == &"":
		return DotResult.fail(
			DotError.CODE_STATE, "This mode has no objectives."
		)

	if layout == CTF:
		return _setup_ctf()

	var defs := build(layout, game.map, game.tick_rate)
	if defs.is_empty():
		return DotResult.fail(
			DotError.CODE_INVALID, "Unknown objective layout '%s'." % layout
		)

	manager = DotObjectiveManager.new()
	manager.name = "ObjectiveManager"
	manager.authoritative = game.is_authority
	manager.rules = _rules()
	manager.presence = _presence()
	add_child(manager)

	var res := manager.setup(defs)
	if not res.ok:
		return res.wrap("arena objectives")

	manager.score_fn = _score
	manager.objective_completed.connect(_on_completed)
	manager.objective_event.connect(_on_event)
	manager.round_objective_met.connect(_on_round_met)

	# A flag carrier who dies drops it. Connected rather than left to the kill handler,
	# because there are three ways to stop being alive here — shot, fell, disconnected —
	# and a carrier who dies still carrying is a flag nobody can take and that never
	# comes home. dot-objective re-tests it every tick as a second lock on the door.
	if not game.player_killed.is_connected(_on_player_killed):
		game.player_killed.connect(_on_player_killed)

	# The layout is derived from the map's own extent, so a new map is a new layout.
	# Without this a flag stays where the previous map's wall was and a hill sits
	# outside the room — with every objective still ticking, still capturable and
	# still scoring, which is the version of this bug nothing errors on.
	if not game.map_changed.is_connected(_on_map_changed):
		game.map_changed.connect(_on_map_changed)

	DotLog.info(CHANNEL, "layout ready", {"layout": str(layout), "count": defs.size()})
	return DotResult.success(null)


func _setup_ctf() -> DotResult:
	if manager != null and ctf == null:
		remove_child(manager)
		manager.queue_free()
		manager = null
	ctf = DotObjectiveCtf.new()
	ctf.name = "Ctf"
	ctf.rules = game.ctf_rules
	ctf.authoritative = game.is_authority
	ctf.tick_rate = game.tick_rate
	ctf.presence = _presence()
	add_child(ctf)

	var res := ctf.setup(ctf_bases(), _score)
	if not res.ok:
		return res.wrap("arena ctf")

	manager = ctf.manager
	_build_flag_view()
	manager.objective_completed.connect(_on_completed)
	manager.objective_event.connect(_on_event)
	ctf.flag_event.connect(_announce_flag)
	ctf.ended.connect(_on_ctf_ended)
	if not game.player_killed.is_connected(_on_player_killed):
		game.player_killed.connect(_on_player_killed)
	if not game.map_changed.is_connected(_on_map_changed):
		game.map_changed.connect(_on_map_changed)

	DotLog.info(CHANNEL, "ctf ready", {"teams": ctf.flags().size()})
	return DotResult.success(null)


## True when this process has a screen. `game.headless` must not be asked: it is the collision backend and is true on every client, which hid the flags (2026-11-08).
static func draws_flags(platform_headless: bool) -> bool:
	return not platform_headless


## Forces the flag view on, for a check that runs without a screen.
var draw_flags := false


## The flags are drawn wherever the game draws (a client, a listen server, a solo game); a dedicated or headless server has no eyes for them.
func _build_flag_view() -> void:
	if flag_view != null or ctf == null or not (draw_flags or draws_flags(DotPlatform.is_headless())):
		return
	flag_view = ArenaFlagView.new()
	flag_view.name = "FlagView"
	flag_view.game = game
	flag_view.ctf = ctf
	add_child(flag_view)


## Where each team's flag stands (team id -> position): a flag spawn the map or the workbench placed, else the middle of the team's own spawns, else a cluster of all spawns, else the ends of the map's longest axis.
func ctf_bases() -> Dictionary:
	var team_ids: Array[int] = []
	for team in game.mode.teams():
		team_ids.append(team.id)

	var sites: Array[DotSpawnSite] = []
	var stack = game.player_stack
	if stack != null and stack.spawns != null:
		var playing: Array[StringName] = stack.teams.teams.playing_ids() if stack.teams != null else []
		for site in stack.spawns.sites():
			var copy := DotSpawnSite.point(site.id, site.position, site.yaw, &"")
			copy.enabled = site.enabled
			copy.meta = site.meta
			if DotSpawnFlags.is_flag(site):
				copy.team = site.team
			else:
				var at := playing.find(site.team)
				if at >= 0 and at < team_ids.size():
					copy.team = StringName(str(team_ids[at]))
			sites.append(copy)

	var by_index := {}
	for i in team_ids.size():
		by_index[i + 1] = team_ids[i]

	# Authored flag stands name a team by its place in the mode (1..N), the same numbers the workbench offers.
	for site in sites:
		if DotSpawnFlags.is_flag(site):
			var wanted := DotSpawnFlags.team_id(site)
			site.team = StringName(str(by_index.get(wanted, 0)))

	var found := DotSpawnFlags.bases(sites, team_ids.max() if not team_ids.is_empty() else 2)
	var out := {}
	for id in team_ids:
		if found.has(id):
			out[id] = (found[id] as DotSpawnSite).position

	# A map that placed its flags (imported `flag_spawns`) keeps them where it put them: first team red, second blue.
	var homes: Dictionary = game.map.flag_homes
	if team_ids.size() == 2 and homes.has("red") and homes.has("blue"):
		out[team_ids[0]] = (homes["red"] as Vector3) + Vector3.UP
		out[team_ids[1]] = (homes["blue"] as Vector3) + Vector3.UP

	if out.size() == team_ids.size():
		return out

	# No usable spawns at all: the old derived ends of the map, two teams only.
	var reach := maxf(game.map.extent - 4.0, 4.0)
	var floor_y := game.map.floor_y
	for i in team_ids.size():
		if not out.has(team_ids[i]):
			var angle := TAU * float(i) / float(team_ids.size())
			out[team_ids[i]] = Vector3(-cos(angle) * reach * 0.8, floor_y + 1.0, sin(angle) * reach * 0.8)
	return out


func _announce_flag(team: int, what: StringName, data: Dictionary) -> void:
	if not game.is_authority:
		return
	var who := str(data.get("by", ""))
	var text := ""
	match what:
		&"taken":
			text = "Team %d's flag was taken" % team
		&"dropped":
			text = "Team %d's flag was dropped" % team
		&"returned":
			text = "Team %d's flag was returned" % team
		&"captured":
			text = "Team %d captured a flag" % int(data.get("team", 0))
	if who != "" and what != &"captured":
		var player := game.player_for(int(who)) if who.is_valid_int() else null
		if player != null:
			text += " by " + String(player.display_name)
	if text != "":
		game.ctf_announced.emit(text)


func _on_ctf_ended(winner: int, reason: StringName) -> void:
	DotLog.info(CHANNEL, "ctf ended", {"winner": winner, "reason": str(reason)})


## The replicated state as JSON text when it changed (or every two seconds), else "". The bridge sends it.
func ctf_wire_text(tick: int, force: bool = false) -> String:
	if ctf == null or not game.is_authority:
		return ""
	if not force and tick - _wire_tick < maxi(game.tick_rate / 8, 1):
		return ""
	var text := JSON.stringify(ctf.to_json_wire())
	if not force and text == _last_wire and tick - _wire_tick < game.tick_rate * 2:
		return ""
	_last_wire = text
	_wire_tick = tick
	return text


## A client applies what the server sent.
func apply_ctf_text(text: String) -> void:
	if ctf == null or game.is_authority:
		return
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		ctf.apply_wire(parsed)


## A client has no effects layer, so the slowdown it predicts with is applied here, from the same base the effects layer uses.
func _apply_carrier_speed() -> void:
	for id in game.player_ids():
		var player := game.player_for(id)
		if player == null or player.controller == null or player.controller.tunables == null:
			continue
		var tunables = player.controller.tunables
		if not tunables.has_meta("arena_base_speed"):
			tunables.set_meta("arena_base_speed", tunables.max_speed)
		tunables.max_speed = float(tunables.get_meta("arena_base_speed")) * speed_scale(id)


## Movement multiplier for a player: the carrier slowdown, else 1.
func speed_scale(id: int) -> float:
	return ctf.speed_scale(str(id)) if ctf != null else 1.0


func _rules() -> DotObjectiveRules:
	var rules := DotObjectiveRules.new()
	rules.live = false  # Warmup. The match turns it on.
	rules.block_style = 1
	rules.deteriorate_ticks = 60 * game.tick_rate
	return rules


func _presence() -> DotObjectivePresence:
	var presence := DotObjectivePresence.of(
		func() -> PackedStringArray:
			var out := PackedStringArray()
			for id in game.player_ids():
				out.append(str(id))
			return out,
		func(key: String) -> Vector3:
			var player := game.player_for(int(key))
			if player == null or player.controller == null:
				return Vector3(1e9, 1e9, 1e9)
			return player.controller.state.position,
		func(key: String) -> int:
			return game.team_of(int(key)),
		func(key: String) -> bool:
			var player := game.player_for(int(key))
			return player != null and player.is_alive()
	)
	# An invulnerable player may not capture and may still block, which is the whole
	# reason dot-objective asks those two questions separately.
	presence.may_capture_fn = func(key: String) -> bool:
		if game.effects == null:
			return true
		return game.effects.may_capture(int(key))
	return presence


## A layout, from a map's own geometry.
##
## Static and public so a suite can build one without a game, and so
## `ArenaModes.describe_lines` could one day say how many points a mode has.
static func build(
	which: StringName, map: ArenaMap, rate: int
) -> Array[DotObjectiveDef]:
	if map == null:
		return []

	var reach := maxf(map.extent - 4.0, 4.0)
	var floor_y := map.floor_y

	match which:
		KOTH:
			var hill := DotObjectiveDef.capture(
				&"hill",
				DotObjectiveArea.cylinder(
					Vector3(0.0, floor_y + 1.5, 0.0), reach * 0.3, 3.0
				),
				8 * rate
			)
			hill.display_name = "The Hill"
			hill.label = "H"
			hill.capture_required = 1
			hill.score_points = 0

			var clock := DotObjectiveDef.holdout(&"koth_clock", 90 * rate)
			clock.display_name = "Hold"
			clock.holdout_owner_of = &"hill"
			clock.area = hill.area
			clock.wins_round = true
			clock.score_points = 1
			clock.player_points = 1
			return [hill, clock]

		CTF:
			var red_home := Vector3(-reach * 0.8, floor_y + 1.0, 0.0)
			var blue_home := Vector3(reach * 0.8, floor_y + 1.0, 0.0)

			# A map that placed its flags (imported `flag_spawns`) keeps them where it put them.
			if map.flag_homes.has("red") and map.flag_homes.has("blue"):
				red_home = (map.flag_homes["red"] as Vector3) + Vector3.UP
				blue_home = (map.flag_homes["blue"] as Vector3) + Vector3.UP

			var red := DotObjectiveDef.flag(
				&"red_flag", DotObjectiveArea.sphere(red_home, 2.0), RED
			)
			red.display_name = "Red Flag"
			red.label = "R"
			red.flag_capture_area = DotObjectiveArea.sphere(blue_home, 3.0)
			red.flag_return_ticks = 30 * rate
			red.flag_requires_own_at_home = true
			red.score_points = 1
			red.player_points = 1

			var blue := DotObjectiveDef.flag(
				&"blue_flag", DotObjectiveArea.sphere(blue_home, 2.0), BLUE
			)
			blue.display_name = "Blue Flag"
			blue.label = "B"
			blue.flag_capture_area = DotObjectiveArea.sphere(red_home, 3.0)
			blue.flag_return_ticks = 30 * rate
			blue.flag_requires_own_at_home = true
			blue.score_points = 1
			blue.player_points = 1
			return [red, blue]

	return []


# --- The tick -----------------------------------------------------------------

func tick(_delta: float) -> void:
	if manager == null:
		return

	if ctf != null:
		ctf.advance(game.current_tick(), game.match_node != null and game.match_node.is_live())
		if not game.is_authority:
			_apply_carrier_speed()
		return

	# Live exactly while the match is being played. A capture made during warmup is one
	# nobody was allowed to make, and warmup is when everybody is standing on
	# everything.
	if game.match_node != null:
		manager.set_live(game.match_node.is_live())

	manager.advance(game.current_tick())
	_touch_flags()


## A player standing on a flag takes it, or sends it home.
##
## Polled rather than driven by a trigger, because this game has no triggers: every
## other test in it is analytic geometry against `ArenaMap`, for the reason the map is
## constants in the first place — a dedicated server has never drawn the level.
func _touch_flags() -> void:
	if manager.objectives == null:
		return
	for flag in manager.objectives.flags():
		for id in game.player_ids():
			var player := game.player_for(id)
			if player == null or not player.is_alive():
				continue
			var at := player.controller.state.position
			if at.distance_to(flag.at) > flag.def.flag_touch_radius:
				continue
			var res := flag.touch(str(id), manager.presence)
			if res.ok:
				break


# --- Events -------------------------------------------------------------------

## Where a completion becomes a score.
##
## [b]Through `report_objective` and not through `add_team_score`, whenever there is a
## player to name.[/b] dot-match's scoreboard credits the player's team from their own
## record, and `report_objective` runs the win check afterwards — which in a mode scored
## by objectives is what ends the round. Adding to the team directly skips both, so the
## capture that wins the game does not end it until somebody happens to get a kill.
##
## The fallback exists for the one completion with nobody to credit — a holdout clock
## running out with the whole team dead — and deliberately does NOT invent a key for it.
## Inventing one is this family's own "report_kill was handed any entity id" bug: a
## scoreboard row keyed on a number no player has ever had.
func _score(
	id: StringName, team: int, by: String, points: int, player_points: int
) -> void:
	if game.match_node == null:
		return
	if by != "" and player_points > 0:
		game.match_node.report_objective(by, id, game.current_tick(), player_points)
		return
	if team > 0 and points > 0:
		game.match_node.scoreboard.add_team_score(team, points)


func _on_completed(id: StringName, team: int, by: String) -> void:
	DotLog.info(
		CHANNEL, "objective completed",
		{"id": str(id), "team": team, "by": by}
	)


func _on_event(id: StringName, what: StringName, data: Dictionary) -> void:
	DotLog.debug(CHANNEL, "objective event", {"id": str(id), "what": str(what)})
	objective_event.emit(id, what, data)


## dot-objective announces and never ends a round. This is where the announcement
## becomes a decision, and it is in the game rather than in the addon.
##
## The scoring already happened in [method _score], which ran the win check with it —
## so this only has to say so. Adding a point here as well would score a capture twice,
## which is the "announce exactly once" bug this family found in dot-vote's play
## history and again in dot-objective's own sweep.
func _on_round_met(id: StringName, team: int, by: String) -> void:
	DotLog.info(
		CHANNEL, "the round objective was met",
		{"id": str(id), "team": team, "by": by}
	)


func _on_player_killed(entry: DotKillFeed.Entry) -> void:
	if manager == null or manager.objectives == null:
		return
	var key := entry.victim_key
	if ctf != null:
		ctf.player_died(key)
		return
	for flag in manager.objectives.flags():
		if flag.carrier != key:
			continue
		var _res := flag.drop(flag.at)


## Rebuild the layout for a new map, keeping the manager and its connections.
func _on_map_changed(new_map: ArenaMap) -> void:
	if manager == null:
		return

	var wanted: StringName = game.mode.objective_layout if game.mode != null else &""
	if wanted == &"":
		# The new mode has no objectives. Emptying the set is right and freeing the
		# layer is not: `ArenaGame.objectives` is read by the HUD and by the net
		# bridge, and a freed node behind a live reference is an error at the next
		# access rather than at the free.
		layout = &""
		var _cleared := manager.setup([] as Array[DotObjectiveDef])
		return

	layout = wanted
	if layout == CTF:
		_rebuild_ctf()
		return
	if ctf != null:
		# Leaving capture the flag: its manager goes with it, and the plain path builds its own.
		remove_child(ctf)
		ctf.queue_free()
		ctf = null
		manager = null
		if flag_view != null:
			remove_child(flag_view)
			flag_view.queue_free()
			flag_view = null
		var _again := setup()
		return
	var defs := build(layout, new_map, game.tick_rate)
	var res := manager.setup(defs)
	if not res.ok:
		DotLog.warn(
			CHANNEL, "the new map has no objective layout",
			{"why": res.error.message}
		)


func on_round_reset() -> void:
	if ctf != null:
		ctf.reset_match()
	elif manager != null:
		manager.reset_round()


## Flags back on stands read afresh from the spawns, scores to nought.
func _rebuild_ctf() -> void:
	if ctf == null:
		var res := _setup_ctf()
		if not res.ok:
			DotLog.warn(CHANNEL, "ctf would not build", {"why": res.error.message})
		return
	var res := ctf.setup(ctf_bases(), _score)
	if not res.ok:
		DotLog.warn(CHANNEL, "ctf would not rebuild", {"why": res.error.message})
	_last_wire = ""


func describe() -> Dictionary:
	return manager.describe() if manager != null else {}


func describe_lines() -> PackedStringArray:
	if manager == null:
		return PackedStringArray(["objectives: none"])
	return manager.describe_lines()
