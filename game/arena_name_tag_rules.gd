extends RefCounted

## When a name tag and a health bar draw over another player: the pure rules, no nodes.
##
## A setting is a set of reasons to show: [constant ALL] (always), [constant TEAM] (a team-mate),
## [constant HOVER] (the cursor is on the body) and [constant HURT] (hurt in the last few seconds).
## The player's choice (settings `name_tags`, `health_bars`) and the server's (`mp_nametags`,
## `mp_hpbars`, replicated in RULES as these masks) are both sets, and a tag draws only when BOTH
## allow it: the server's value is a ceiling the client can narrow and never widen.
## Written as a preset (`smart`) or a list (`team,hover`) in a setting, a cvar or a config.

const ALL := 1
const TEAM := 2
const HOVER := 4
const HURT := 8

## Preset -> mask. `smart` is the bar's default: team-mates always, anybody under the cursor or just hurt.
const PRESETS := {
	&"off": 0, &"always": ALL, &"team": TEAM, &"hover": HOVER, &"hurt": HURT,
	&"team_hover": TEAM | HOVER, &"smart": TEAM | HOVER | HURT,
}
const TOKENS := {
	"off": 0, "none": 0, "all": ALL, "always": ALL, "team": TEAM, "teammates": TEAM,
	"hover": HOVER, "cursor": HOVER, "aim": HOVER, "hurt": HURT, "smart": TEAM | HOVER | HURT,
}

## Farthest a body can be and still count as under the cursor, metres.
const MAX_RANGE := 80.0
## Half-width of the body the cursor must touch to count as over it, metres.
const BODY_RADIUS := 0.55

## The player's own picks, the server's ceilings, and who is looking. Written each frame by the client.
static var client_names: int = TEAM
static var client_bars: int = TEAM | HOVER | HURT
static var server_names: int = ALL
static var server_bars: int = ALL
static var viewer_id: int = -1
static var viewer_team: int = -1  # -1: a free-for-all, nobody is a team-mate
static var occluder_mask: int = 0  # physics layers that hide a body from the cursor; 0 skips the test


## A mask from [param text] (a preset or tokens split on , + | space _), or -1 when anything in it is unknown.
static func parse(text: String) -> int:
	var clean := text.strip_edges().to_lower()
	if clean == "":
		return -1
	if PRESETS.has(StringName(clean)):
		return PRESETS[StringName(clean)]
	var mask := 0
	for token in clean.replace("+", ",").replace("|", ",").replace(" ", ",").replace("_", ",").split(",", false):
		if not TOKENS.has(token):
			return -1
		mask |= int(TOKENS[token])
	return mask


## [param mask] as a cvar echoes it.
static func describe(mask: int) -> String:
	if mask == 0:
		return "off"
	if mask & ALL:
		return "always"
	var parts: PackedStringArray = []
	for part: String in ["team", "hover", "hurt"]:
		if mask & int(TOKENS[part]):
			parts.append(part)
	return ",".join(parts)


## Whether [param mask] admits somebody who is (or is not) a team-mate, under the cursor, recently hurt.
static func admits(mask: int, is_team: bool, hovered: bool, hurt: bool) -> bool:
	return (mask & ALL) != 0 or (is_team and (mask & TEAM) != 0) \
		or (hovered and (mask & HOVER) != 0) or (hurt and (mask & HURT) != 0)


## Whether a tag draws, given the player's mask and the server's.
static func shows(client: int, server: int, is_team: bool, hovered: bool, hurt: bool) -> bool:
	return admits(client, is_team, hovered, hurt) and admits(server, is_team, hovered, hurt)


## Whether either mask needs the cursor test at all (it costs a ray).
static func needs_hover(a: int, b: int) -> bool:
	return ((a | b) & HOVER) != 0 and ((a & b) & ALL) == 0


## Whether somebody with [param other_id] on [param other_team] is a team-mate of the viewer.
static func is_teammate(other_id: int, other_team: int) -> bool:
	return viewer_team >= 0 and other_id != viewer_id and other_team == viewer_team


## Whether the ray [param from] along [param dir] (unit) passes within [constant BODY_RADIUS] of the upright
## body standing at [param feet] and [param height] tall, in front of the eye and within [constant MAX_RANGE].
static func ray_hits_body(from: Vector3, dir: Vector3, feet: Vector3, height: float) -> bool:
	# Closest points of a ray and a vertical segment: solve for the segment's parameter, clamp, then the ray's.
	var w := from - feet
	var denom := height * (dir.y * dir.y - 1.0)
	var s := 0.5 if absf(denom) < 0.0001 else (dir.y * dir.dot(w) - w.y) / denom
	s = clampf(s, 0.0, 1.0)
	var on_segment := feet + Vector3(0.0, height * s, 0.0)
	var t := dir.dot(on_segment - from)
	if t <= 0.0 or t > MAX_RANGE:
		return false
	return (from + dir * t).distance_to(on_segment) <= BODY_RADIUS


## The two player settings, declared into the presentation schema.
static func declare_settings(s: DotSettingsSchema) -> void:
	s.add(DotSettingsDef.choice(&"name_tags", &"team", [&"always", &"team", &"team_hover", &"hover", &"off"], &"video").with_description("Names over other players' heads: everybody, team-mates, team-mates and whoever your cursor is on, only the cursor, or none. A server may allow fewer (mp_nametags)."))
	s.add(DotSettingsDef.choice(&"health_bars", &"smart", [&"always", &"smart", &"team", &"team_hover", &"hover", &"off"], &"video").with_description("Health bars over other players: smart is team-mates, whoever your cursor is on and anybody just hurt. A server may allow fewer (mp_hpbars)."))
