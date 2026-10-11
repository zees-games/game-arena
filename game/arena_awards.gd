extends RefCounted

const ArenaStats := preload("arena_stats.gd")

## What a player can earn here, as a document rather than as code.
##
## Every rule reads an id from [ArenaStats] and nothing else. That is the whole
## integration: dot-achievements never hears about a kill, a weapon or a round — it
## hears that a number moved, which is what makes the catalogue a thing an operator
## could edit into a JSON file without a rebuild ([method DotAchievementCatalogue.save_json_file]
## writes exactly the shape [method DotAchievementCatalogue.from_json_file] reads).
##
## [b]One stat may be read with only one merge rule across the whole catalogue.[/b]
## dot-achievements refuses a catalogue that breaks it, at [method DotAchievementCatalogue.validate]
## rather than at the first reading, and the reason is worth restating: one number
## cannot be both a running total and a personal best. So every rule over
## [constant ArenaStats.BEST_STREAK] and [constant ArenaStats.BEST_ROUND_KILLS] uses
## [constant DotAchievementRule.Merge.HIGHEST] and everything else uses
## [constant DotAchievementRule.Merge.SUM]. The helpers below are the only reason that
## cannot be got wrong one entry at a time.
##
## The counterpart of that rule lives in [ArenaProgress]: dot-stats' `recorded` signal
## carries a session total and an achievement is about a lifetime, so
## [DotAchievementStatsLink] differences SUM stats and passes the rest through. A
## HIGHEST stat here is therefore an absolute in both systems, which is the only way
## "best streak" means the same thing on both sides.

# No `CHANNEL`: a static catalogue document, validated by dot-achievements, which is
# where a refusal is reported. Nothing here runs.

## Categories, so a menu can group them without parsing names.
const CAT_COMBAT := &"combat"
const CAT_SKILL := &"skill"
const CAT_MATCH := &"match"
const CAT_SANDBOX := &"sandbox"


# --- Medals: what one kill was, decided by the server ----------------------
#
# The catalogue above is a lifetime ("a hundred kills"). A medal is one kill's shape
# ("that was a headshot, and your second in four seconds"), judged the moment it happens
# and gone from the screen two seconds later. Both live here because both are "what a
# player earned", and the server is the only machine that decides either.
#
# [b]The server decides every medal, and no client works one out.[/b] A client sees the
# kill feed, so it COULD count a revenge or a nemesis itself, and arena's HUD once did:
# every client then held its own copy of who killed whom, which a late joiner started
# empty and a dropped event put out of step. `MedalBook` runs on the authority; the
# result travels as `ArenaEvents.Kind.AWARD` and the HUD only draws it.

## A medal's index on the wire (`ArenaEvents.write_award`). [b]Append, never insert or
## reorder[/b]: a client built a day earlier reads the number, not the name.
enum Medal {
	FIRST_BLOOD,
	HEADSHOT,
	DOUBLE_KILL,
	TRIPLE_KILL,
	MULTI_KILL,
	REVENGE,
	SHUTDOWN,
	POINT_BLANK,
	NO_SCOPE,
	LONG_SHOT,
	NEMESIS,
}

## What a kill is worth before its medals: the "+100" by the crosshair.
const KILL_POINTS := 100

## Kills by one player this close together chain into a double, a triple, a multi kill.
const MULTI_WINDOW_SEC := 4.0

## Killing somebody on a streak at least this long is a shutdown. The streak meter's
## second reward rung, so a shutdown is always somebody the server was already rewarding.
const SHUTDOWN_AT := 5

## Metres between the two players, eye to eye: under this is point blank, over the other
## is a long shot. The built-in maps are 60 m across, so 30 m is the far half of a room.
const POINT_BLANK_M := 3.0
const LONG_SHOT_M := 30.0

## Kills of one victim, without them killing you back, that make you their nemesis.
const NEMESIS_AT := 3

## Each medal's name, sound and worth, by [enum Medal]. The name is what the popup says;
## the sound is a dot-audio id the client's catalogue maps to a voice. What it LOOKS like
## (icon, colour) is the HUD's, because it is only ever drawn.
const MEDALS := {
	Medal.FIRST_BLOOD: {"name": "First Blood", "sound": &"medal_first_blood", "points": 50},
	Medal.HEADSHOT: {"name": "Headshot", "sound": &"medal_headshot", "points": 25},
	Medal.DOUBLE_KILL: {"name": "Double Kill", "sound": &"medal_double_kill", "points": 25},
	Medal.TRIPLE_KILL: {"name": "Triple Kill", "sound": &"medal_triple_kill", "points": 50},
	Medal.MULTI_KILL: {"name": "Multi Kill", "sound": &"medal_multi_kill", "points": 75},
	Medal.REVENGE: {"name": "Revenge", "sound": &"medal_revenge", "points": 50},
	Medal.SHUTDOWN: {"name": "Shutdown", "sound": &"medal_shutdown", "points": 75},
	Medal.POINT_BLANK: {"name": "Point Blank", "sound": &"medal_point_blank", "points": 25},
	Medal.NO_SCOPE: {"name": "No Scope", "sound": &"medal_no_scope", "points": 50},
	Medal.LONG_SHOT: {"name": "Long Shot", "sound": &"medal_long_shot", "points": 50},
	Medal.NEMESIS: {"name": "Nemesis", "sound": &"medal_nemesis", "points": 25},
}


static func medal_name(medal: int) -> String:
	return String(MEDALS[medal]["name"]) if MEDALS.has(medal) else "?"


static func medal_sound(medal: int) -> StringName:
	return StringName(MEDALS[medal]["sound"]) if MEDALS.has(medal) else &""


## A kill's points: [constant KILL_POINTS] and every medal's.
static func points_for(medals: Array) -> int:
	var total := KILL_POINTS
	for medal in medals:
		total += int(MEDALS.get(int(medal), {}).get("points", 0))
	return total


## What the server knows about one player killing another, at the moment it happens.
## Filled by `ArenaGame._on_entity_killed`; every field is the simulation's, none a
## client's claim except [member aiming], which is the aim button in the killer's command.
class KillFacts:
	extends RefCounted
	var killer: int = 0
	var victim: int = 0
	var tick: int = 0
	var tick_rate: int = 64
	var headshot: bool = false
	## The victim's streak when they died, before it was reset.
	var victim_streak: int = 0
	## Eye to eye, metres.
	var distance: float = 0.0
	## The weapon's tags (`ZeeWeaponIds.TAG_*`).
	var tags: Array = []
	## Whether the killer held the aim on the tick of the kill.
	var aiming: bool = false
	var team_kill: bool = false


## The memory medals need between kills, and the rules. Authority side, one per game;
## [method reset_round] at every round start, [method forget] when a player leaves.
class MedalBook:
	extends RefCounted

	var first_blood_taken: bool = false
	## victim -> who killed them last, until they take their revenge.
	var last_killer: Dictionary = {}
	## killer -> [kills in the chain, tick of the last one].
	var chains: Dictionary = {}
	## "killer:victim" -> kills since the victim last killed the killer.
	var runs: Dictionary = {}

	func reset_round() -> void:
		first_blood_taken = false
		last_killer.clear()
		chains.clear()
		runs.clear()

	func forget(player_id: int) -> void:
		last_killer.erase(player_id)
		chains.erase(player_id)
		for key in last_killer.keys():
			if int(last_killer[key]) == player_id:
				last_killer.erase(key)
		for key in runs.keys():
			var pair := String(key).split(":")
			if int(pair[0]) == player_id or int(pair[1]) == player_id:
				runs.erase(key)

	## Somebody died to the world, or to themselves: no medal, and their chain ends.
	func note_death(victim: int) -> void:
		chains.erase(victim)

	## The medals [param k] earns, in the order they are shown. Updates the memory, so
	## call it exactly once per kill, and only for a kill of one player by another.
	func judge(k: KillFacts) -> Array[int]:
		var out: Array[int] = []
		note_death(k.victim)

		if k.team_kill or k.killer == 0 or k.killer == k.victim:
			return out

		if not first_blood_taken:
			first_blood_taken = true
			out.append(Medal.FIRST_BLOOD)

		# The chain: a kill within the window of the killer's last one extends it.
		var window := int(ceil(MULTI_WINDOW_SEC * float(maxi(1, k.tick_rate))))
		var chain: Array = chains.get(k.killer, [0, -window - 1])
		var count := int(chain[0]) + 1 if k.tick - int(chain[1]) <= window else 1
		chains[k.killer] = [count, k.tick]
		if count == 2:
			out.append(Medal.DOUBLE_KILL)
		elif count == 3:
			out.append(Medal.TRIPLE_KILL)
		elif count >= 4:
			out.append(Medal.MULTI_KILL)

		if k.headshot:
			out.append(Medal.HEADSHOT)

		if int(last_killer.get(k.killer, 0)) == k.victim:
			out.append(Medal.REVENGE)
			last_killer.erase(k.killer)
		last_killer[k.victim] = k.killer

		if k.victim_streak >= SHUTDOWN_AT:
			out.append(Medal.SHUTDOWN)

		# Range, for a gun. A knife is always close and a grenade lands where it lands,
		# so neither earns a distance medal.
		var melee := k.tags.has(ZeeWeaponIds.TAG_MELEE)
		var thrown := k.tags.has(ZeeWeaponIds.TAG_THROWN) or k.tags.has(ZeeWeaponIds.TAG_EXPLOSIVE)
		if not melee and not thrown:
			if k.distance < POINT_BLANK_M:
				out.append(Medal.POINT_BLANK)
			elif k.distance >= LONG_SHOT_M:
				out.append(Medal.LONG_SHOT)
			if k.tags.has(ZeeWeaponIds.TAG_SCOPED) and not k.aiming:
				out.append(Medal.NO_SCOPE)

		# The run: the killer's kills of this victim since the victim last got one back.
		runs.erase("%d:%d" % [k.victim, k.killer])
		var key := "%d:%d" % [k.killer, k.victim]
		var run := int(runs.get(key, 0)) + 1
		runs[key] = run
		if run == NEMESIS_AT:
			out.append(Medal.NEMESIS)

		return out


static func catalogue() -> DotAchievementCatalogue:
	var out: Array[DotAchievement] = []

	# --- Kills: the spine, three tiers ------------------------------------
	out.append(_sum(
		&"arena.first_blood", "First Blood", ArenaStats.KILLS, 1,
		"Kill somebody.", CAT_COMBAT, 5, &"arena.killer", 1
	))
	out.append(_sum(
		&"arena.centurion", "Centurion", ArenaStats.KILLS, 100,
		"A hundred kills.", CAT_COMBAT, 25, &"arena.killer", 2
	))
	out.append(_sum(
		&"arena.millennium", "Millennium", ArenaStats.KILLS, 1000,
		"A thousand kills.", CAT_COMBAT, 100, &"arena.killer", 3
	))

	# --- Headshots --------------------------------------------------------
	out.append(_sum(
		&"arena.marksman", "Marksman", ArenaStats.HEADSHOTS, 25,
		"Twenty-five headshots.", CAT_SKILL, 20, &"arena.headhunter", 1
	))
	out.append(_sum(
		&"arena.headhunter", "Headhunter", ArenaStats.HEADSHOTS, 250,
		"Two hundred and fifty headshots.", CAT_SKILL, 60, &"arena.headhunter", 2
	))

	# --- Streaks. HIGHEST, because a streak is a best and not a total. -----
	out.append(_best(
		&"arena.triple", "On a Roll", ArenaStats.BEST_STREAK, 3,
		"Three kills without dying.", CAT_SKILL, 10, &"arena.streak", 1
	))
	out.append(_best(
		&"arena.rampage", "Rampage", ArenaStats.BEST_STREAK, 5,
		"Five kills without dying.", CAT_SKILL, 20, &"arena.streak", 2
	))
	out.append(_best(
		&"arena.unstoppable", "Unstoppable", ArenaStats.BEST_STREAK, 10,
		"Ten kills without dying.", CAT_SKILL, 50, &"arena.streak", 3
	))
	out.append(_best(
		&"arena.big_round", "Carried It", ArenaStats.BEST_ROUND_KILLS, 15,
		"Fifteen kills in one round.", CAT_SKILL, 40
	))

	# --- Damage -----------------------------------------------------------
	out.append(_sum(
		&"arena.heavy_hitter", "Heavy Hitter", ArenaStats.DAMAGE_DEALT, 100000,
		"A hundred thousand points of damage.", CAT_COMBAT, 40
	))

	# --- Match ------------------------------------------------------------
	out.append(_sum(
		&"arena.regular", "Regular", ArenaStats.ROUNDS_PLAYED, 50,
		"Fifty rounds played.", CAT_MATCH, 15
	))
	out.append(_sum(
		&"arena.winner", "Winner", ArenaStats.MATCHES_WON, 1,
		"Win a match.", CAT_MATCH, 15, &"arena.champion", 1
	))
	out.append(_sum(
		&"arena.champion", "Champion", ArenaStats.MATCHES_WON, 25,
		"Win twenty-five matches.", CAT_MATCH, 60, &"arena.champion", 2
	))
	out.append(_sum(
		&"arena.veteran", "Veteran", ArenaStats.PLAYTIME_SEC, 36000,
		"Ten hours in the arena.", CAT_MATCH, 30
	))

	# --- Two-rule entries -------------------------------------------------
	#
	# The pair is the point: dot-achievements ANDs the requirements by default
	# (`require_all`), so "landed a lot of shots AND played a lot of rounds" is two
	# rules rather than a derived percentage. Accuracy is deliberately NOT a stat —
	# see ArenaStats.accuracy_of — because a stored percentage is a third number that
	# can disagree with the two it came from.
	var sharp: Array[DotAchievementRule] = [
		DotAchievementRule.make(ArenaStats.SHOTS_HIT, 5000.0),
		DotAchievementRule.make(ArenaStats.ROUNDS_PLAYED, 100.0),
	]
	var sharp_entry := DotAchievement.make(&"arena.sharpshooter", "Sharpshooter", sharp)
	sharp_entry.description = "Five thousand shots landed over a hundred rounds."
	sharp_entry.category = CAT_SKILL
	sharp_entry.points = 50
	out.append(sharp_entry)

	# --- Monsters, and the sandbox ----------------------------------------
	out.append(_sum(
		&"arena.exterminator", "Exterminator", ArenaStats.NPC_KILLS, 200,
		"Two hundred monsters put down.", CAT_COMBAT, 30
	))
	out.append(_sum(
		&"arena.decorator", "Interior Decorator", ArenaStats.PROPS_SPAWNED, 100,
		"Spawn a hundred props.", CAT_SANDBOX, 10
	))

	# --- One secret one ---------------------------------------------------
	#
	# `secret` withholds the description until it is earned and `hidden` withholds the
	# whole entry. Applied in `to_player_dictionary`, not in a UI: a description a
	# screen chose not to draw is one that was still sent to the client.
	var clumsy := _sum(
		&"arena.gravity", "Gravity Wins", ArenaStats.SUICIDES, 25,
		"Twenty-five deaths nobody else is to blame for.", CAT_COMBAT, 5
	)
	clumsy.secret = true
	out.append(clumsy)

	return DotAchievementCatalogue.of(out)


static func _sum(
	id: StringName,
	display: String,
	stat: StringName,
	threshold: float,
	description: String,
	category: StringName,
	points: int,
	series: StringName = &"",
	tier: int = 0
) -> DotAchievement:
	return _entry(
		id, display, stat, threshold, DotAchievementRule.Merge.SUM,
		description, category, points, series, tier
	)


static func _best(
	id: StringName,
	display: String,
	stat: StringName,
	threshold: float,
	description: String,
	category: StringName,
	points: int,
	series: StringName = &"",
	tier: int = 0
) -> DotAchievement:
	return _entry(
		id, display, stat, threshold, DotAchievementRule.Merge.HIGHEST,
		description, category, points, series, tier
	)


static func _entry(
	id: StringName,
	display: String,
	stat: StringName,
	threshold: float,
	merge: DotAchievementRule.Merge,
	description: String,
	category: StringName,
	points: int,
	series: StringName,
	tier: int
) -> DotAchievement:
	var rules: Array[DotAchievementRule] = [
		DotAchievementRule.make(stat, threshold, DotAchievementRule.Op.AT_LEAST, merge)
	]
	var out := DotAchievement.make(id, display, rules)
	out.description = description
	out.category = category
	out.points = points
	out.series = series
	out.tier = tier
	return out
