@tool
extends DotHud

const ArenaGame := preload("arena_game.gd")
const ArenaFrameProbe := preload("arena_frame_probe.gd")
const ArenaPlayer := preload("arena_player.gd")
const ArenaAwards := preload("arena_awards.gd")
const ArenaStats := preload("arena_stats.gd")
const ArenaPaths := preload("arena_paths.gd")
const ArenaAvatars := preload("arena_avatars.gd")
const ArenaHudGlance := preload("arena_hud_glance.gd")

## The in-game display, laid out for a glance (see [ArenaHudGlance] for where each thing
## is and why): scores, clock and portraits at the top centre, the kill feed top right,
## health bottom left, magazine and reserve bottom right with the carried weapons up the
## right edge, abilities bottom centre, key hints on the left; and the kill feedback
## (hit marker, damage numbers, medals, the streak meter) over the middle. The health, the
## ammunition, the strip, the prompt, the hints, the hit marker and the damage numbers are
## dot-ui's glance pieces (`DotHudPiece`); the rest are arena's own.
##
## [b]Built here rather than shipped by dot-ui, and that is the division of labour.[/b]
## dot-ui knows how to draw a bounded self-expiring list of coloured fragments; it does
## not know what a kill is. It knows how to draw a bar from a `Callable`; it does not
## know what health is. Every widget below is a dot-ui class bound to a game value, and
## the binding is the only thing in this file.
##
## Almost no art: the bars and plates are drawn; the weapon silhouettes are rendered from
## the models (`tools/build_weapon_icons.sh`); the medal and ability icons are Kenney's CC0.

## The player this HUD is about. Rebound on spawn, because the body is replaced.
var player: ArenaPlayer = null

var game: ArenaGame = null

var crosshair: DotCrosshair = null
## Whether the host's DotCrosshair fades while aiming (dot-ui API 5).
var _crosshair_fades: bool = DotAddonApi.build_level("dot_ui") >= 5

## Bottom left: health as a bar with its number, armour as a thin bar under it.
var vitals: DotVitals = null
## `magazine | reserve` under the weapon's name, bottom right.
var ammo: DotAmmoCounter = null
## The carried weapons up the right edge.
var slots: ArenaHudGlance.WeaponSlots = null
## Top right: killer, weapon silhouette, victim.
var feed: ArenaHudGlance.KillFeed = null
## Top centre: the two scores and the clock, the target and the mode.
var strip: DotScoreStrip = null
## Under the strip: every player ranked, portrait, rank and kills.
var portraits: ArenaHudGlance.Portraits = null
var portrait_cache: ArenaHudGlance.PortraitCache = null
## Bottom centre: slide, launch, dash and the wall jump, with keys and cooldowns.
var abilities: ArenaHudGlance.AbilityBar = null
## The right edge: the keys worth knowing.
var hints: DotKeyHints = null

## Seconds left, when something other than this game's own match knows. NAN means
## "ask the match", which is what a server and an offline client do.
var remaining_override: float = NAN

## The key each prompt, hint and button names, as the player has it bound. The client
## writes these from its key table ([method ArenaClient._hud_keys]); the defaults are the
## table's.
var keys: Dictionary = {
	&"slide": "C", &"launch": "E", &"dash": "Shift", &"jump": "Space",
	&"scoreboard": "Tab", &"menu": "Esc", &"chat": "Y", &"reload": "R", &"help": "H",
	&"maps": "M", &"loadout": "", &"roam": "T",
}

## The spectator's key hint ("Free camera", "Back to players"), set by the client while the
## viewer is dead and may roam; empty otherwise. Drawn in the prompt line.
var roam_hint: String = ""

## Seconds until the portraits are read again: a ranked row a few times a second is a
## row that keeps up, and once a frame is ten lookups for nothing.
var _portraits_in: float = 0.0

## What the round is about, when it is about something. Empty in a deathmatch.
##
## One line rather than a widget per objective, because the two modes that have any
## want completely different pictures — a hill wants a clock and a flag wants two
## states — and a widget general enough for both would draw neither well. A game that
## wants a proper objective HUD builds it; this is the line that says a mode is
## running and how far along it is.
var objective_label: Label = null

## An administrator's `blind`, over the world and under the rest of the HUD.
##
## [b]Under the widgets, on purpose.[/b] A blind takes the game away, not the player's
## bearings: the clock, the kill feed, their own health and the chat box still say that
## the match is going on and that they are in it, which is what makes it read as "an
## admin did this" rather than as a client that stopped drawing. The menus and the chat
## box are above the HUD altogether.
##
## Black rather than white. A white screen at full brightness is a thing a player can be
## hurt by in a dark room, and taking the picture away is the whole of the point.
var blind_overlay: ColorRect = null

## The scope, drawn at full aim with a scoped weapon. Under every widget, over the world.
var scope: ZeeScopeOverlay = null

## Red at the screen's edge when the followed player is badly hurt, and a short pulse of it
## on every hit. Drawn by a shader per pixel ([constant HURT_SHADER]), so no art and no
## resolution of its own; strongest at no health, gone above [constant HURT_FROM].
##
## [b]A shader, not a gradient texture.[/b] It was a `GradientTexture2D`, which is 64 by 64
## unless told otherwise, stretched over the whole viewport: Christian's first play test
## showed the oval in visible pixel steps at 1080p. Computed per pixel there is nothing to
## stretch, and a little dither keeps the long soft ramp from banding into rings.
var hurt_overlay: ColorRect = null
const HURT_FROM := 0.35

## The hit pulse: dot-fx's `hurt_flash` (its strength in [member flash_source]'s
## `flash_colour`), drawn at the edge rather than over the screen. dot-fx computes the
## flash and draws nothing; nothing drew it before this, so a hit showed no red at all until
## health fell under [constant HURT_FROM]. Read through dot-fx so the player's "no flashes"
## and the three-a-second limit hold. [constant HURT_PULSE_GAIN] maps the flash's peak
## (0.28) to about [constant HURT_PULSE_MAX] of the edge.
var flash_source: Object = null
const HURT_PULSE_GAIN := 2.2
const HURT_PULSE_MAX := 0.6

## The edge, per pixel. Distance is measured in the screen's own shape (an ellipse touching
## the edges), so the clear middle is the same share of a 4:3 and a 21:9 frame; `smoothstep`
## then a square gives a soft start and a deep rim. Alpha is the node's modulate, so the
## strength is one number the HUD writes and the checks read.
const HURT_SHADER := """
shader_type canvas_item;
uniform vec4 tint : source_color = vec4(0.62, 0.0, 0.02, 0.78);
uniform float inner = 0.7;
uniform float outer = 1.32;
void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float d = length(p);
	float a = smoothstep(inner, outer, d);
	a = a * a * (1.6 - 0.6 * a);
	float n = fract(sin(dot(FRAGCOORD.xy, vec2(12.9898, 78.233))) * 43758.5453);
	a = clamp(a + (n - 0.5) / 96.0, 0.0, 1.0);
	COLOR = vec4(tint.rgb, tint.a * a);
}
"""

## The launch's key, which is X in a mode where E is the prop tool: the client's to say.
var launch_key_text: String:
	get:
		return str(keys.get(&"launch", "E"))
	set(value):
		keys[&"launch"] = value

## The prompt for what can be done now: "Cancel slide [C]" while sliding, "Reload [R]" on
## an empty magazine.
var slide_label: DotKeyPrompt = null

## The coins this player has collected this match, from the drops layer.
var coins_label: Label = null

## Kills since each player last died, counted from the KILL events every client gets, so
## the meter needs nothing new on the wire. See [method note_kill].
var streaks: Dictionary = {}

## Players the server named as the followed player's nemesis (an AWARD with
## [constant ArenaAwards.Medal].NEMESIS for a kill of them), until they are killed back.
## Only ever written from AWARD: the HUD counts nothing about who killed whom itself.
var nemeses: Dictionary = {}

## The streak meter on the left: a bar that fills toward [constant STREAK_FULL] and a count.
var streak_meter: StreakMeter = null
const STREAK_FULL := 10

## The hit marker: four ticks round the crosshair on every hit the server confirmed, red
## on a kill. See [method note_hit].
var hit_marker: DotHitMarker = null

## Numbers rising off whatever was hit, gold for a headshot.
var damage_numbers: DotDamageNumbers = null

## The medals of the followed player's last kills: icon, name, scale in, hold, fade.
var medal_row: MedalRow = null

## "Killed by NAME (weapon)", and the nemesis line, while the followed player is dead.
var death_label: Label = null
var _death_text: String = ""


## The feedback's gold: the streak, the points, a headshot's number.
const GOLD := Color(1.0, 0.8, 0.22)

## How the feedback is drawn: fonts, icons, colours, outlined text. An inner class so the
## widgets below can call it (an inner class cannot call its outer script's functions).
class Look:
	extends RefCounted

	## Where the medal icons are (Kenney's CC0 icons, `assets/medals/`), through the rebase.
	const MEDAL_ICON_DIR := "res://assets/medals"

	static var _icons: Dictionary = {}
	static var _fonts: Dictionary = {}


	## The fallback font, bold, and slanted when [param italic]: what every feedback line is
	## drawn in. The genre's medal names and streak count are bold italic, and the theme's
	## regular weight read as a debug overlay beside them (first render).
	static func feedback_font(italic: bool = false) -> Font:
		if not _fonts.has(italic):
			var font := FontVariation.new()
			font.base_font = ThemeDB.fallback_font
			font.variation_embolden = 0.9
			if italic:
				font.variation_transform = Transform2D(Vector2(1.0, 0.0), Vector2(-0.22, 1.0), Vector2.ZERO)
			_fonts[italic] = font
		return _fonts[italic]


	## A medal icon by file name, or null when the art is missing: the badge still draws.
	static func medal_icon(file: String) -> Texture2D:
		if not _icons.has(file):
			var at := ArenaPaths.rebase("%s/%s.png" % [MEDAL_ICON_DIR, file])
			_icons[file] = load(at) as Texture2D if ResourceLoader.exists(at) else null
		return _icons[file]


	## What each medal looks like: an icon file and a colour. The server's [ArenaAwards] says
	## what a medal is called and what it is worth; this is only how it is drawn.
	static func medal_look(medal: int) -> Array:
		match medal:
			ArenaAwards.Medal.FIRST_BLOOD: return ["splat", Color(0.86, 0.12, 0.18)]
			ArenaAwards.Medal.HEADSHOT: return ["target", Color(1.0, 0.33, 0.2)]
			ArenaAwards.Medal.DOUBLE_KILL: return ["skull", Color(1.0, 0.62, 0.1)]
			ArenaAwards.Medal.TRIPLE_KILL: return ["skull", Color(1.0, 0.45, 0.1)]
			ArenaAwards.Medal.MULTI_KILL: return ["skull", Color(0.95, 0.25, 0.55)]
			ArenaAwards.Medal.REVENGE: return ["sword", Color(0.78, 0.1, 0.32)]
			ArenaAwards.Medal.SHUTDOWN: return ["fire", Color(0.2, 0.52, 1.0)]
			ArenaAwards.Medal.POINT_BLANK: return ["arrows", Color(0.55, 0.36, 1.0)]
			ArenaAwards.Medal.NO_SCOPE: return ["zoom_out", Color(0.0, 0.7, 0.62)]
			ArenaAwards.Medal.LONG_SHOT: return ["arrow", Color(0.16, 0.7, 0.96)]
			ArenaAwards.Medal.NEMESIS: return ["skull_tile", Color(0.42, 0.12, 0.6)]
		return ["", Color(0.5, 0.5, 0.5)]


	## Text with a dark outline, the way every piece of feedback is drawn over a bright map.
	static func draw_outlined(
		canvas: CanvasItem, font: Font, at: Vector2, text: String, font_size: int, colour: Color,
		outline: int = 6, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1.0
	) -> void:
		var ink := ArenaHudGlance.Ink.c(canvas, &"ink")
		canvas.draw_string_outline(
			font, at, text, align, width, font_size, outline, Color(ink, ink.a * colour.a)
		)
		canvas.draw_string(font, at, text, align, width, font_size, colour)


## The killstreak meter: a thin rounded bar up the left edge, a flame over it, and
## "Killstreak xN" under it, all gold. Drawn, with the flame from `assets/medals/`.
class StreakMeter extends Control:
	var fraction: float = 0.0
	var count: int = 0
	## Seconds since the count last went up, for the flame's pulse.
	var _since: float = 99.0
	var _shown: float = 0.0

	func set_count(value: int, full: int) -> void:
		if value > count:
			_since = 0.0
		count = value
		fraction = float(value) / float(maxi(1, full))

	func advance(delta: float) -> void:
		_since += delta
		# The fill eases toward the count rather than jumping, so a kill reads as a rise.
		_shown = move_toward(_shown, clampf(fraction, 0.0, 1.0), delta * 2.5)
		queue_redraw()

	## The bar and the flame over it: a thin column. The words under it are
	## [method label_footprint], apart, because one box round both would take in the key
	## hints beside the bar.
	func footprint() -> Rect2:
		return Rect2(-10.0, -36.0, 30.0, size.y + 37.0)

	## "Killstreak xN" under the bar.
	func label_footprint() -> Rect2:
		var w := Look.feedback_font(true).get_string_size("Killstreak x%d" % count, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 17).x
		return Rect2(-17.0, size.y + 8.0, w + 6.0, 24.0)

	func _draw() -> void:
		var width := 10.0
		var track := Rect2(0.0, 0.0, width, size.y)
		var back := StyleBoxFlat.new()
		back.bg_color = Color(ArenaHudGlance.Ink.c(self, &"plate"), 0.6)
		back.set_corner_radius_all(4)
		back.border_color = Color(ArenaHudGlance.Ink.c(self, &"text"), 0.25)
		back.set_border_width_all(1)
		draw_style_box(back, track.grow(1.0))
		var gold := ArenaHudGlance.Ink.c(self, &"highlight")
		var fill := track.size.y * _shown
		if fill > 0.5:
			var bar := StyleBoxFlat.new()
			bar.bg_color = gold
			bar.set_corner_radius_all(4)
			draw_style_box(bar, Rect2(0.0, track.size.y - fill, width, fill))
			draw_rect(Rect2(1.5, track.size.y - fill + 2.0, 2.0, maxf(0.0, fill - 4.0)), Color(1.0, 0.95, 0.7, 0.7))

		var pulse := 1.0 + 0.35 * maxf(0.0, 1.0 - _since / 0.3)
		var icon := Look.medal_icon("fire")
		var side := 26.0 * pulse
		var at := Rect2(Vector2(width * 0.5 - side * 0.5, -side - 8.0), Vector2(side, side))
		if icon != null:
			draw_texture_rect(icon, at.grow(2.0), false, Color(0.1, 0.05, 0.0, 0.6))
			draw_texture_rect(icon, at, false, gold if count > 0 else Color(1.0, 1.0, 1.0, 0.45))
		Look.draw_outlined(
			self, Look.feedback_font(true), Vector2(-14.0, size.y + 26.0), "Killstreak x%d" % count,
			17, gold if count > 0 else Color(1.0, 1.0, 1.0, 0.6), 6
		)


## The medals of the followed player's kills: a row above the crosshair, each a coloured
## badge with a white icon and its name under it. Each scales in with an overshoot, holds,
## and fades; several from one kill come in one after another, and the row re-centres as
## they come and go.
class MedalRow extends Control:
	const IN_SEC := 0.22
	const HOLD_SEC := 2.4
	const OUT_SEC := 0.5
	const STAGGER_SEC := 0.14
	const SPACING := 134.0
	const RADIUS := 30.0
	const MAX_SHOWN := 6
	var shown: Array[Dictionary] = []

	func add(medal: int, label: String, delay: float = 0.0) -> void:
		var look := Look.medal_look(medal)
		shown.append({
			"medal": medal, "label": label, "icon": Look.medal_icon(String(look[0])),
			"colour": look[1], "age": -delay, "x": NAN,
		})
		while shown.size() > MAX_SHOWN:
			shown.remove_at(0)

	## Every medal still on screen, in order: what a check reads.
	func labels() -> PackedStringArray:
		var out := PackedStringArray()
		for m in shown:
			out.append(String(m["label"]))
		return out

	func advance(delta: float) -> void:
		var life := IN_SEC + HOLD_SEC + OUT_SEC
		for i in range(shown.size() - 1, -1, -1):
			shown[i]["age"] = float(shown[i]["age"]) + delta
			if float(shown[i]["age"]) >= life:
				shown.remove_at(i)
		# Slots for the ones that have appeared; each slides to its own.
		var visible_now: Array[Dictionary] = []
		for m in shown:
			if float(m["age"]) >= 0.0:
				visible_now.append(m)
		for i in range(visible_now.size()):
			var target := (float(i) - float(visible_now.size() - 1) * 0.5) * SPACING
			var m := visible_now[i]
			m["x"] = target if is_nan(float(m["x"])) else lerpf(float(m["x"]), target, minf(1.0, delta * 12.0))
		queue_redraw()

	## Every medal on screen at full size, its badge and its name under it.
	func footprint() -> Rect2:
		var centre := Vector2(size.x * 0.5, size.y * 0.27)
		var out := Rect2()
		for m in shown:
			if float(m["age"]) < 0.0 or is_nan(float(m["x"])):
				continue
			var w := maxf((RADIUS + 4.0) * 2.0,
				Look.feedback_font(true).get_string_size("%s!" % String(m["label"]), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 20).x + 6.0)
			var one := Rect2(centre.x + float(m["x"]) - w * 0.5, centre.y - RADIUS - 4.0, w, RADIUS * 2.0 + 38.0)
			out = one if not out.has_area() else out.merge(one)
		return out

	func _draw() -> void:
		var centre := Vector2(size.x * 0.5, size.y * 0.27)
		var font := Look.feedback_font(true)
		for m in shown:
			var age := float(m["age"])
			if age < 0.0 or is_nan(float(m["x"])):
				continue
			var grow: float
			if age < IN_SEC:
				# Overshoot: in from nothing past full size and back, the genre's pop.
				var t := age / IN_SEC
				grow = lerpf(0.2, 1.3, t / 0.6) if t < 0.6 else lerpf(1.3, 1.0, (t - 0.6) / 0.4)
			else:
				grow = 1.0
			var fade := clampf((IN_SEC + HOLD_SEC + OUT_SEC - age) / OUT_SEC, 0.0, 1.0)
			var at := centre + Vector2(float(m["x"]), 0.0)
			var r := RADIUS * grow
			var colour: Color = m["colour"]
			draw_circle(at + Vector2(0.0, 3.0), r + 4.0, Color(0.0, 0.0, 0.0, 0.35 * fade))
			# The dark HUD: a deep disc rimmed in the medal's colour, the icon in it lit in the
			# colour. The bright theme ("Arcade"): the first HUD's white-ringed coloured badge.
			var dark := ArenaHudGlance.Ink.bright(self) < 0.5
			var icon: Texture2D = m["icon"]
			if dark:
				draw_circle(at, r + 3.5, Color(colour.lightened(0.2), fade))
				draw_circle(at, r, Color(ArenaHudGlance.Ink.c(self, &"plate"), 0.94 * fade))
				draw_circle(at, r * 0.86, Color(colour.darkened(0.55), 0.55 * fade))
			else:
				draw_circle(at, r + 3.5, Color(1.0, 1.0, 1.0, 0.92 * fade))
				draw_circle(at, r, Color(colour.darkened(0.25), fade))
				draw_circle(at - Vector2(0.0, r * 0.12), r * 0.86, Color(colour, fade))
			if icon != null:
				var side := r * 1.4
				draw_texture_rect(icon, Rect2(at - Vector2(side, side) * 0.5, Vector2(side, side)), false,
					Color(colour.lightened(0.45), fade) if dark else Color(1.0, 1.0, 1.0, fade))
			var medal := int(m["medal"])
			var tally := (
				"2" if medal == ArenaAwards.Medal.DOUBLE_KILL
				else "3" if medal == ArenaAwards.Medal.TRIPLE_KILL
				else "4+" if medal == ArenaAwards.Medal.MULTI_KILL else ""
			)
			if tally != "":
				var badge := at + Vector2(r * 0.72, r * 0.62)
				draw_circle(badge, 12.0 * grow, Color(colour.lightened(0.2), fade) if dark else Color(1.0, 1.0, 1.0, fade))
				draw_circle(badge, 10.0 * grow, Color(colour.darkened(0.35), fade))
				draw_string(
					Look.feedback_font(), badge + Vector2(-20.0, 5.0 * grow), tally, HORIZONTAL_ALIGNMENT_CENTER,
					40.0, int(14.0 * grow), Color(1.0, 1.0, 1.0, fade)
				)
			Look.draw_outlined(
				self, font, at + Vector2(-90.0, r + 26.0), "%s!" % String(m["label"]),
				int(20.0 * minf(grow, 1.15)), Color(1.0, 1.0, 1.0, fade), 6, HORIZONTAL_ALIGNMENT_CENTER, 180.0
			)


## A line for everybody to read: a chat line, a map change, "REVENGE!". Held for
## [constant NOTICE_SEC] and faded.
##
## [b]It did not exist[/b], and three callers in `ArenaClient` (chat lines, the map
## changing, the map loaded) had called it since the client was written. Found adding the
## first caller in this file, which the parser refused where the client's had not.
##
## [b]Wrapped, two lines at most, and narrower than the gap between the right-hand column
## and the middle.[/b] It was one unbounded line: the server's "Vote: Smash Copter, Hide &
## Seek, …" as a ballot opened ran off the right edge of a 1280-wide frame, behind the drawn
## ballot the client shell puts down the right-hand side (360 px wide, 16 px in). Centred,
## the line clears that column only when its half-width is under the distance from the
## middle to the column, so the width follows the frame: `notice_width`.
func notice(text: String) -> void:
	# The ballot already says it, with the time left and the counts: see `is_ballot_line`.
	if is_ballot_line(text) and DotHudPiece.covered_rect(self).has_area():
		return
	if notice_label == null:
		# Under the portraits and the medal row: `notice_top`.
		notice_label = _make_label("Notice", Control.PRESET_CENTER_TOP, Vector2(0.0, 182.0))
		notice_label.add_theme_font_size_override(&"font_size", 20)
		notice_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		notice_label.max_lines_visible = 2
		notice_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var width := notice_width(size.x)
	notice_label.offset_left = -width * 0.5
	notice_label.offset_right = width * 0.5
	notice_label.offset_top = notice_top(size.y)
	notice_label.text = text
	notice_label.modulate.a = 1.0
	_notice_age = 0.0

var notice_label: Label = null
var _notice_age: float = 0.0


## [b]A vote's opening line, which a drawn ballot makes a duplicate.[/b] dot-vote says
## "Vote: Box, Atrium, … (20s)" in chat as its ballot opens, and `ArenaClient._on_said` centre
## prints every system line, so while the shell's ballot was on screen the same list was in
## the middle of it as well, two lines deep, over the medals' row. Only that shape: dot-server's
## yes/no vote ("Vote: <question> — type !yes or !no (20s)") stays, because "!yes" is how to
## answer it and a ballot is not always drawn for one.
static func is_ballot_line(text: String) -> bool:
	if not text.begins_with("Vote: ") or text.contains("!yes"):
		return false
	var open := text.rfind(" (")
	return open > 0 and text.ends_with("s)") and text.substr(open + 2, text.length() - open - 4).is_valid_int()


## [b]Keeps the HUD out from under the client shell's ballots[/b], every frame. The shell
## draws every ballot down the right-hand side, over whatever the game drew, and cannot reach
## into a delivered game, so the game looks: `DotHudPiece.covered_rect` is every visible
## member of the `dot_hud_cover` group, merged, in this HUD's own coordinates. dot-ui's
## pieces (health, ammunition, the strip, the hints) each dim themselves under one. The
## weapon slots up the right edge tighten, then show only the rows around the current one, to
## end above a ballot that comes down over them (a seven-row map ballot reaches slot 1 at
## 1280x720); and the vote's centre line goes while its ballot is drawn.
func make_room() -> void:
	var cover := DotHudPiece.covered_rect(self)
	if slots != null:
		var bottom := -INF
		if cover.has_area():
			# In the slots' own coordinates, and only where the cover is over their column.
			var local := slots.get_transform() * Rect2(Vector2.ZERO, slots.size)
			if cover.position.x < local.end.x and cover.end.x > local.position.x and cover.position.y < local.end.y:
				bottom = cover.end.y - local.position.y
		slots.set_cover_bottom(bottom)
	if cover.has_area() and notice_label != null and notice_label.text != "" and is_ballot_line(notice_label.text):
		notice_label.text = ""
const NOTICE_SEC := 4.0

## The right-hand column the client shell draws ballots in: 360 px wide and 16 px from the
## edge, plus a gap. The notice keeps its half-width inside the distance to it.
const SHELL_COLUMN := 376.0 + 16.0

## The centre notice's width on a frame [param frame_width] wide: clear of the shell's
## ballot column on both sides, never under 260 px (a phone in landscape has no room
## beside a 360 px ballot anyway, and two short lines beat four) and never over 640.
static func notice_width(frame_width: float) -> float:
	return clampf(frame_width - SHELL_COLUMN * 2.0, 260.0, 640.0)


## Where the centre notice starts on a frame [param frame_height] tall: under the medal
## row's labels (the row is centred at 27 % of the height and its names end about 65 px
## below that), so a system line arriving with a kill is not printed through "Headshot!",
## which a fixed 182 px was on any frame over about 600 tall. Never lower than 70 px above
## the middle, where the crosshair is: on a short frame the medals give way, not the aim.
static func notice_top(frame_height: float) -> float:
	return minf(maxf(182.0, frame_height * 0.27 + 70.0), frame_height * 0.5 - 70.0)

## How far along a challenge is, in the words its stat is counted in.
##
## [b]Never the raw counter over the raw target.[/b] Christian's first play test showed
## "(2/100000)" over the score box: damage dealt against a hundred-thousand target, which
## read as a debug print. Playing time is seconds and reads as a clock ("0:03 of 10 h");
## a target of a thousand or more is shortened ("2 of 100k"); a small one stays a count
## ("3/25"), which is what a player wants to see go up.
static func progress_text(stat: StringName, value: int, target: int) -> String:
	if stat == ArenaStats.PLAYTIME_SEC:
		return "%s of %s" % [_duration(value), _duration(target)]
	if target >= 1000:
		return "%s of %s" % [_short_count(value), _short_count(target)]
	return "%d/%d" % [value, target]


static func _short_count(n: int) -> String:
	if absi(n) >= 1000000:
		return ("%.1fM" % (n / 1000000.0)).replace(".0M", "M")
	if absi(n) >= 1000:
		return ("%.1fk" % (n / 1000.0)).replace(".0k", "k")
	return str(n)


static func _duration(sec: int) -> String:
	if sec >= 3600 and sec % 3600 == 0:
		return "%d h" % (sec / 3600)
	if sec >= 3600:
		return "%d:%02d h" % [sec / 3600, (sec % 3600) / 60]
	return "%d:%02d" % [sec / 60, sec % 60]


## "1 coin", "5 coins": the count and the noun, agreed (the play test read "+1 COINS").
static func coins_text(count: int) -> String:
	return "%d coin" % count if absi(count) == 1 else "%d coins" % count


## The challenge bar at the top: the achievement the player is nearest to, and how near.
var challenge_label: Label = null
var challenge_bar: ProgressBar = null
var _challenges: DotAchievementCatalogue = null


func present_challenge(live: bool) -> void:
	if challenge_label == null:
		# Top left: the top centre is the scores and the portraits now.
		challenge_label = _make_label("Challenge", Control.PRESET_TOP_LEFT, Vector2(0.0, 2.0))
		challenge_label.grow_horizontal = Control.GROW_DIRECTION_END
		challenge_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		challenge_label.offset_left = 8.0
		challenge_label.add_theme_font_size_override(&"font_size", 14)
		challenge_bar = ProgressBar.new()
		challenge_bar.name = "ChallengeBar"
		challenge_bar.show_percentage = false
		challenge_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		challenge_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		challenge_bar.offset_left = 8.0
		challenge_bar.offset_right = 300.0
		challenge_bar.offset_top = 28.0
		challenge_bar.offset_bottom = 34.0
		var fill := StyleBoxFlat.new()
		fill.bg_color = Color(1.0, 0.78, 0.25)
		challenge_bar.add_theme_stylebox_override(&"fill", fill)
		var back := StyleBoxFlat.new()
		back.bg_color = Color(0.0, 0.0, 0.0, 0.45)
		challenge_bar.add_theme_stylebox_override(&"background", back)
		add_child(challenge_bar)
		_challenges = ArenaAwards.catalogue()

	var index := player.challenge if player != null else -1
	var shown := live and index >= 0 and index < _challenges.achievements.size()
	challenge_label.visible = shown
	challenge_bar.visible = shown

	if not shown:
		return

	var a: DotAchievement = _challenges.achievements[index]
	var target := int(a.requirements[0].value)
	challenge_label.text = "%s — %s  %s" % [
		a.display_name, a.description.trim_suffix("."),
		progress_text(a.requirements[0].stat, player.challenge_value, target),
	]
	challenge_bar.max_value = float(target)
	challenge_bar.value = float(player.challenge_value)


## Seconds a "+N" popup rises and fades over.
const POPUP_SEC := 1.3

## A kill's "+points  Victim" stays longer: it is the line the genre holds while the
## medals play.
const KILL_POPUP_SEC := 2.6

## Rising "+1" / "+3 COINS" lines beside the crosshair: [Label, age].
var _popups: Array = []

## The coin count last frame, so a rise can be told as a popup.
var _coins_seen: int = -1


## A "+N" beside the crosshair that rises and fades: the genre's way of saying a kill or a
## pickup counted. Several stack upward rather than overwriting each other. [param tail]
## follows in [param tail_colour]: the victim's name after a kill's points.
func popup(
	text: String, colour: Color = GOLD, tail: String = "", tail_colour: Color = Color.WHITE,
	life: float = POPUP_SEC
) -> void:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override(&"separation", 10)
	row.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	# Level with the crosshair and right of it, clear of the hit marker: the damage number
	# of the shot that killed rises from about where the crosshair is, so a line above it
	# was drawn over that number in the first render.
	row.offset_left = 64.0
	row.offset_right = 528.0
	row.offset_top = -16.0 - 30.0 * float(_popups.size())
	row.offset_bottom = row.offset_top + 32.0
	for part in [[text, colour], [tail, tail_colour]]:
		if String(part[0]) == "":
			continue
		var label := Label.new()
		label.text = String(part[0])
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_font_override(&"font", Look.feedback_font(true))
		label.add_theme_font_size_override(&"font_size", 22)
		label.add_theme_color_override(&"font_color", part[1])
		label.add_theme_color_override(&"font_outline_color", Color(0.05, 0.03, 0.08, 0.85))
		label.add_theme_constant_override(&"outline_size", 7)
		row.add_child(label)
	add_child(row)
	_popups.append([row, 0.0, life])


func _advance_popups(delta: float) -> void:
	for i in range(_popups.size() - 1, -1, -1):
		var entry: Array = _popups[i]
		var label: Control = entry[0]
		entry[1] = float(entry[1]) + delta
		var t := float(entry[1]) / float(entry[2])

		if t >= 1.0 or not is_instance_valid(label):
			if is_instance_valid(label):
				label.queue_free()
			_popups.remove_at(i)
			continue

		# A slow drift: a kill's line is read, not glanced at, and the first renders at
		# 40 px a second had it halfway to the medals before it could be.
		label.position.y -= delta * 14.0
		label.modulate.a = clampf((1.0 - t) / 0.35, 0.0, 1.0)


## A kill, as every client hears it: the streaks and the death panel. The points, the
## medals and the nemesis are [method note_award]'s, from the server's AWARD.
func note_kill(info: Dictionary, own_id: int, killer_name: String) -> void:
	var killer := int(info.get("killer_id", 0))
	var victim := int(info.get("victim_id", 0))
	streaks[victim] = 0
	if killer != 0 and killer != victim:
		streaks[killer] = int(streaks.get(killer, 0)) + 1

	if victim == own_id and killer != 0 and killer != victim:
		_death_text = "Killed by %s  (%s)" % [killer_name, String(info.get("weapon", ""))]
		if nemeses.has(killer):
			_death_text += "\n%s is your NEMESIS" % killer_name


## Your damage landed, as the server confirmed it ([constant ArenaEvents.Kind].HIT, or
## [signal ArenaGame.hit_confirmed] offline): the hit marker flashes, red if it killed, and
## a number rises from [param point]. Nothing here is predicted.
func note_hit(victim: int, amount: float, point: Vector3, headshot: bool, lethal: bool) -> void:
	_build_feedback()
	hit_marker.flash(lethal, headshot)
	damage_numbers.add(victim, amount, point, headshot)


## A kill's award, as every client hears it. For the followed player's own kill: the
## medals, "+points  Victim", and the server's streak. For their death: the nemesis line.
func note_award(info: Dictionary, own_id: int, victim_name: String, killer_name: String) -> void:
	_build_feedback()
	var killer := int(info.get("killer_id", 0))
	var victim := int(info.get("victim_id", 0))
	var medals: Array = info.get("medals", [])

	if killer == own_id and own_id != 0:
		# The server's count, which the KILL-counted one agrees with unless an event was
		# missed; the server's wins.
		streaks[killer] = int(info.get("streak", streaks.get(killer, 0)))
		nemeses.erase(victim)
		popup("+%d" % int(info.get("points", ArenaAwards.KILL_POINTS)), GOLD, victim_name, Color.WHITE, KILL_POPUP_SEC)
		for i in range(medals.size()):
			medal_row.add(int(medals[i]), ArenaAwards.medal_name(int(medals[i])), MedalRow.STAGGER_SEC * float(i))

	if victim == own_id and medals.has(ArenaAwards.Medal.NEMESIS):
		nemeses[killer] = true
		var line := "%s is your NEMESIS" % killer_name
		if not _death_text.contains(line):
			_death_text += "\n" + line


## The streak meter, the hit marker, the damage numbers and the medal row. Built once, on
## first need, over everything else on the HUD.
func _build_feedback() -> void:
	if streak_meter != null:
		return
	streak_meter = StreakMeter.new()
	streak_meter.name = "Streak"
	streak_meter.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	streak_meter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	streak_meter.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	# [b]Short enough that its words clear a full chat log.[/b] The chat box's eight rows
	# reach y 424 at 1280x720 (`ArenaPresentation._build_chat`: 110 off the bottom, the
	# entry, 8 x 20); a 250-tall bar put "Killstreak xN" at 468..492, and the sixth chat
	# line wrote over it in the client shell (a ballot's "Vote: …" line wraps to two).
	streak_meter.position = Vector2(34.0, -160.0)
	streak_meter.size = Vector2(10.0, 180.0)
	add_child(streak_meter)
	damage_numbers = DotDamageNumbers.new()
	damage_numbers.name = "DamageNumbers"
	damage_numbers.mouse_filter = Control.MOUSE_FILTER_IGNORE
	damage_numbers.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(damage_numbers)
	hit_marker = DotHitMarker.new()
	hit_marker.name = "HitMarker"
	hit_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hit_marker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(hit_marker)
	medal_row = MedalRow.new()
	medal_row.name = "Medals"
	# 128 px icons drawn at about 40: without mipmaps the edges shimmer.
	medal_row.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	medal_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	medal_row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(medal_row)


## Seconds a blind takes to come down and to lift. Short, so it is unmistakably on, and
## not instant, so it reads as something done to the screen rather than a frame dropped.
const BLIND_FADE_SEC := 0.25

const BLIND_COLOUR := Color(0.01, 0.01, 0.015)


## Builds every widget. Call after adding to the tree.
## How far in from the screen's edge the HUD sits, in pixels: the `hud_safe_area` setting,
## applied live. dot-ui's `DotHud` reads its config's margin once, when it enters the tree.
func set_safe_area(pixels: float) -> void:
	if config == null:
		config = DotUiConfig.new()
	config.safe_area = maxf(pixels, 0.0)
	_apply_safe_area()
	_fit_feed()


## The frame the HUD is drawn for ([member DotHud.fit_design]): below it the whole HUD is
## scaled down by `DotHud.fit_scale`, never laid out again. [b]On a frame smaller than this
## its pieces ran into each other[/b]: standalone at 854x480 the challenge ran over the
## scores, the ability bar over the health, the medals over the portraits and "Cancel slide"
## over the health; at 960x720 the scores reached the kill feed. The client shell never shows
## a game a frame like that (its canvas is 1280x720, stretched to the window), so this is the
## same answer the shell gives, for the game on its own. Never larger: on a bigger frame the
## pieces keep their size and the map gets the room. Arena found this and dot-ui took it over
## (`fit_design`, `fit_scale`, `fit_to_frame`, API 4); below half size (`fit_min`) a frame
## gets overlap, not dust.
const DESIGN_FRAME := Vector2(1280.0, 720.0)


func _init() -> void:
	# Before `_ready`, which is where `DotHud` decides between anchoring and fitting, and
	# follows the viewport's size from then on.
	fit_design = DESIGN_FRAME


## Arena's own colour over whichever theme the player picked: gold for "yours" (your ring,
## row, slot and streak). Everything else (plates, words, ink, key caps) is the theme's, so
## Paper and High contrast can change it; `ArenaClient` hands this to dot-menu's
## `follow_hud` with the HUD (Christian's first play test, 2026-10-11: a darker HUD that
## follows the menu's theme).
static func accent_theme() -> Theme:
	var t := Theme.new()
	t.set_color(&"highlight", &"DotHudPiece", GOLD)
	return t


## Where the client shell's right-hand column starts, in frame pixels: its game ballot and
## its lines are drawn from here down, a third of the frame wide (dot-server-deploy's
## `client/notice_overlay.gd`, `COLUMN_TOP`; a copy, keep in step).
const SHELL_COLUMN_TOP := 110.0


## How many kill feed rows end above the shell's column when the HUD is inset by
## [param inset] px: three at the default 16. The rows below that were drawn under an open
## ballot, and this game cannot tell when one is open, so the feed is never longer.
static func feed_lines_clear(inset: float) -> int:
	var pitch := ArenaHudGlance.KillFeed.ROW_H + ArenaHudGlance.KillFeed.ROW_GAP
	return maxi(int(floor((SHELL_COLUMN_TOP - inset + ArenaHudGlance.KillFeed.ROW_GAP) / pitch)), 1)


func _fit_feed() -> void:
	if feed == null:
		return
	var inset := config.safe_area * config.scale if config != null else 16.0
	var wanted := config.feed_lines if config != null else 5
	feed.max_lines = mini(wanted, feed_lines_clear(inset))
	while feed.entries.size() > feed.max_lines:
		feed.entries.pop_back()
	feed.queue_redraw()


func build(p_game: ArenaGame) -> void:
	game = p_game

	# First, so every widget added below draws over it. See [member blind_overlay].
	blind_overlay = ColorRect.new()
	blind_overlay.name = "Blind"
	blind_overlay.color = BLIND_COLOUR
	# Not anchored to this HUD's rect: `DotHud` insets itself by the safe area, and a
	# blind the size of the HUD left a 16-pixel frame of the world visible round the edge
	# of the first rendered frame. Sized to the whole viewport in `present_blind` instead.
	blind_overlay.set_anchors_preset(Control.PRESET_TOP_LEFT)
	blind_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	blind_overlay.modulate.a = 0.0
	blind_overlay.visible = false
	add_child(blind_overlay)

	hurt_overlay = ColorRect.new()
	hurt_overlay.name = "Hurt"
	# Clear over the middle, so it reads as the edge of vision closing in rather than as a
	# red filter over the screen (the first render was the second).
	var shader := Shader.new()
	shader.code = HURT_SHADER
	var material := ShaderMaterial.new()
	material.shader = shader
	hurt_overlay.material = material
	hurt_overlay.color = Color.WHITE
	# Top-left anchored and sized to the viewport in `present_body`, like the blind: full-rect
	# anchors with a size written every frame drew an engine warning per write.
	hurt_overlay.set_anchors_preset(Control.PRESET_TOP_LEFT)
	hurt_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hurt_overlay.modulate.a = 0.0
	add_child(hurt_overlay)

	scope = ZeeScopeOverlay.new()
	scope.name = "Scope"
	add_child(scope)

	crosshair = DotCrosshair.new()
	crosshair.name = "Crosshair"
	crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	crosshair.fov_degrees = 75.0
	crosshair.length = 7.0
	crosshair.base_gap = 3.0
	crosshair.thickness = 2.0
	# Bound to the weapon's actual spread, so the crosshair opening means something.
	# A crosshair that opens by an arbitrary factor tells the player something
	# confident and wrong about where their shots will go.
	crosshair.bind(func() -> Variant:
		return player.spread_degrees() if _live() else 0.0
	)
	add_child(crosshair)

	# Bottom left: health as a thick bar with its number at the end, armour as a thin one
	# under it when there is any. The bars ease and the numbers do not (`DotVitals`).
	vitals = DotVitals.new()
	vitals.name = "Vitals"
	_place(vitals, Control.PRESET_BOTTOM_LEFT, Rect2(0.0, -84.0, 380.0, 76.0))
	vitals.bar_start = 38.0
	vitals.bar_end = 300.0

	# Bottom right: the weapon's name, then `magazine | reserve`.
	ammo = DotAmmoCounter.new()
	ammo.name = "Ammo"
	_place(ammo, Control.PRESET_BOTTOM_RIGHT, Rect2(-300.0, -84.0, 290.0, 70.0))

	# [b]The right edge below 110 px belongs to the client shell[/b]: its ballots and lines are
	# one column there, a third of the frame wide (`SHELL_COLUMN_TOP`). This game cannot see
	# when one is open, so its right edge stays clear always. The key hints were centre right
	# and the weapons' top slot just under the middle; rendered with a ballot open
	# (`screenshot.sh --glance --ballot`) both were under it at 1280x720, the hints at
	# 1600x900 too. The hints moved to the left edge beside the streak meter, and the weapons
	# carried sit on the ammunition counter, bottom up, which keeps five of them below a
	# six-row ballot at 720 tall.
	hints = DotKeyHints.new()
	hints.name = "KeyHints"
	# Seven rows since B (the loadout) joined them: started higher, so the last row ends above
	# the streak meter's words (rendered: at -128 the Slide row sat on "Killstreak").
	_place(hints, Control.PRESET_CENTER_LEFT, Rect2(62.0, -170.0, 200.0, 196.0))

	slots = ArenaHudGlance.WeaponSlots.new()
	slots.name = "Slots"
	_place(slots, Control.PRESET_BOTTOM_RIGHT, Rect2(-170.0, -294.0, 160.0, 202.0))

	# Bottom centre: the abilities, clear of the hands at the bottom right.
	abilities = ArenaHudGlance.AbilityBar.new()
	abilities.name = "Abilities"
	_place(abilities, Control.PRESET_CENTER_BOTTOM, Rect2(-200.0, -98.0, 400.0, 90.0))

	slide_label = DotKeyPrompt.new()
	slide_label.name = "Prompt"
	_place(slide_label, Control.PRESET_CENTER, Rect2(-330.0, 120.0, 300.0, 36.0))
	slide_label.visible = false

	feed = ArenaHudGlance.KillFeed.new()
	feed.name = "KillFeed"
	_place(feed, Control.PRESET_TOP_RIGHT, Rect2(-470.0, 0.0, 460.0, 170.0))
	_fit_feed()
	feed.lifetime_sec = config.feed_lifetime_sec if config != null else 6.0

	strip = DotScoreStrip.new()
	strip.name = "Scores"
	_place(strip, Control.PRESET_CENTER_TOP, Rect2(-260.0, 0.0, 520.0, 72.0))

	portraits = ArenaHudGlance.Portraits.new()
	portraits.name = "Portraits"
	_place(portraits, Control.PRESET_CENTER_TOP, Rect2(-270.0, 74.0, 540.0, 80.0))
	portrait_cache = ArenaHudGlance.PortraitCache.new()
	portrait_cache.name = "PortraitCache"
	add_child(portrait_cache)

	objective_label = _make_label(
		"Objective", Control.PRESET_CENTER_TOP, Vector2(0.0, 154.0)
	)
	# No match, nothing to score: a render tool or a suite building the HUD alone.
	strip.visible = game != null
	portraits.visible = game != null

	if game != null:
		game.player_killed.connect(_on_kill)


## Adds [param piece] with [param preset]'s anchors and [param rect] as its offsets from
## them. Every piece ignores the mouse: a HUD that takes a click eats the shot.
func _place(piece: Control, preset: Control.LayoutPreset, rect: Rect2) -> void:
	piece.set_anchors_preset(preset)
	piece.offset_left = rect.position.x
	piece.offset_top = rect.position.y
	piece.offset_right = rect.end.x
	piece.offset_bottom = rect.end.y
	piece.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Icons drawn smaller than their files: without mipmaps a silhouette's thin parts break up.
	piece.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	add_child(piece)


func _make_label(
	node_name: String,
	preset: Control.LayoutPreset,
	offset: Vector2
) -> Label:
	var label := Label.new()
	label.name = node_name
	label.set_anchors_preset(preset)
	label.offset_top = offset.y
	# [b]Grow both ways, or "centred" means "starts at the centre".[/b] A centre-top
	# preset is a zero-width box at the middle of the screen, and a `Label` wider than
	# its box grows by `grow_horizontal`, which defaults to END — so the text is pushed
	# rightwards from the midline and `HORIZONTAL_ALIGNMENT_CENTER` has nothing to centre
	# inside. The round clock drew at x = 640..680 on a 1280-wide frame, with every
	# property above reading correctly. Only a rendered frame shows it.
	label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Bold and outlined like every other piece: the theme's regular weight with no outline
	# all but vanished over the pale maps.
	label.add_theme_font_override(&"font", ArenaHudGlance.Ink.font())
	label.add_theme_font_size_override(&"font_size", 17)
	label.add_theme_color_override(&"font_outline_color", Color(0.02, 0.02, 0.05, 0.85))
	label.add_theme_constant_override(&"outline_size", 6)
	add_child(label)
	return label


## Where each piece of the HUD draws, in frame pixels: what it puts on screen, not its
## `Control`'s box (the feed's box is 460 wide; its rows are as wide as their names). Only
## pieces drawn now. What `headless_presentation` checks for overlap on small frames.
func footprints() -> Dictionary:
	var out := {}
	var pieces := {
		"scores": strip, "portraits": portraits, "feed": feed, "vitals": vitals,
		"ammo": ammo, "slots": slots, "abilities": abilities, "hints": hints,
		"prompt": slide_label, "streak": streak_meter, "medals": medal_row,
	}
	for key: String in pieces:
		var piece: Control = pieces[key]
		if piece == null or not piece.is_visible_in_tree():
			continue
		var local: Rect2 = piece.call(&"footprint")
		if local.has_area():
			out[key] = piece.get_global_transform() * local
	if streak_meter != null and streak_meter.is_visible_in_tree():
		out["streak_label"] = streak_meter.get_global_transform() * streak_meter.label_footprint()
	for label: Label in [challenge_label, notice_label, objective_label, death_label, coins_label]:
		if label != null and label.is_visible_in_tree() and label.text != "":
			out[String(label.name)] = label.get_global_rect()
	if challenge_bar != null and challenge_bar.is_visible_in_tree():
		out["challenge_bar"] = challenge_bar.get_global_rect()
	return out


## Points the HUD at a player. Called on every spawn.
##
## The widgets hold a `Callable` that reads `player`, so re-pointing this one field
## repoints all of them. Binding each widget to a body would mean rebinding six
## callables every time someone respawns, and the one that got missed would show the
## previous life's health for ever.
func follow(p_player: ArenaPlayer) -> void:
	player = p_player


func _live() -> bool:
	return player != null and is_instance_valid(player)


## Gives the crosshair the field of view the camera is actually drawing with.
##
## [b]The crosshair turns an angle of spread into pixels, and that conversion is only
## as right as the field of view it is given.[/b] It was a constant 75 here while the
## camera was the player's own setting converted from horizontal-at-4:3 — 83.6 degrees
## vertical at the default of 100 — so every gap was drawn 17% wider than the cone the
## shots actually leave in, and at a setting of 120 it was 69% wider. A crosshair that is
## confidently wrong about where the shots go is exactly what `DotCrosshair` says it
## exists to avoid.
##
## Read off the camera once a frame rather than pushed from the settings, because the
## camera is the one place the field of view is written: a player's slider, a server's
## clamp and the first `attach_camera` all end there, and a copy fed by one of them
## would disagree with the other two.
func match_view() -> void:
	if crosshair == null or not _live() or player.camera == null:
		return

	crosshair.fov_degrees = player.camera.fov


## Puts a kill on the feed.
##
## Public because on a NETWORKED client nothing local scores anything: `game.player_killed`
## fires on the server, and the client learns about a kill from an `ArenaEvents.Kind.KILL`
## event. `ArenaClient` rebuilds the entry and calls this; the signal path below is the
## offline and listen-server one. Both end in the same place deliberately — a feed that
## looked different depending on how the kill arrived would be two feeds.
func show_kill(entry: DotKillFeed.Entry) -> void:
	_on_kill(entry)


## A kill's cause as a player reads it: a weapon's display name ("Machine Pistol", not
## `machine_pistol`), and anything that is not a weapon — a monster, `slay`, the world —
## as it came.
static func cause_label(cause: Variant) -> String:
	var def := ArenaPlayer.weapon_catalogue().get_def(StringName(str(cause)))
	return def.display_name if def != null else str(cause)


func _on_kill(entry: DotKillFeed.Entry) -> void:
	if feed == null:
		return

	var me := str(player.player_id) if _live() else ""

	feed.add_kill(
		entry.killer_name if entry.killer_key != entry.victim_key else "",
		_name_colour(entry.killer_key, entry.killer_team, me),
		entry.cause,
		cause_label(entry.cause),
		entry.victim_name,
		_name_colour(entry.victim_key, entry.victim_team, me),
		entry.headshot,
		me != "" and (entry.killer_key == me or entry.victim_key == me)
	)


## A name's colour in the feed: gold for you, the side's colour in a team mode, else white.
func _name_colour(key: String, team: int, me: String) -> Color:
	if key == me and me != "":
		return GOLD
	var side := _team_colour(team)
	return side.lightened(0.35) if side.a > 0.0 else Color(0.95, 0.96, 0.98)


## [param team]'s colour, or transparent when it is no side (a free-for-all, nobody).
func _team_colour(team: int) -> Color:
	if team <= 0 or game == null or game.match_node == null or game.match_node.teams == null:
		return Color(0, 0, 0, 0)
	var mode := game.displayed_mode()
	if mode == null or not mode.is_team_mode():
		return Color(0, 0, 0, 0)
	var side := game.match_node.teams.team(team)
	return side.colour if side != null else Color(0, 0, 0, 0)


## Fills the feed from kills that happened before this HUD existed.
##
## What a client joining a match in progress needs, and what a HUD rebuilt after a
## settings change needs. `DotKillFeed` is bounded and keeps its entries, so the last
## few are always available -- taking them is one call and not having it is a feed that
## is empty until the next person dies.
func catch_up(since_tick: int = -1) -> int:
	if game == null or feed == null:
		return 0

	var entries := (
		game.match_node.feed.recent(feed.max_lines) if since_tick < 0
		else game.match_node.feed.since(since_tick)
	)

	for entry in entries:
		_on_kill(entry)

	return entries.size()


## Refreshes the two labels that are not widgets.
##
## The round timer and the score are read once a frame rather than through a
## `DotHudWidget`, because both are strings assembled from several values and a widget
## exists to bind one.
func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var t := Time.get_ticks_usec()
	_present(delta)
	ArenaFrameProbe.add(&"hud", t)


func _present(delta: float) -> void:
	match_view()
	present_blind(delta)
	present_body()

	if feed != null:
		feed.advance(delta)
	present_gear()
	make_room()

	if game == null or strip == null:
		return

	present_scores()
	_portraits_in -= delta
	if _portraits_in <= 0.0:
		_portraits_in = 0.25
		present_portraits()

	if objective_label != null:
		objective_label.text = _objective_line()


## The clock, the two scores, the target and the mode, into the strip. Public so a render
## tool or a suite can put it up without a frame.
func present_scores() -> void:
	# The override first, when there is one.
	#
	# [b]A networked client's own `DotMatch` never runs.[/b] Nothing ticks it, so
	# `seconds_remaining()` is derived from `_ticks_in_state` against a `_current_tick`
	# that is still 0 — a number nothing ever wrote, not a stale one. A connected
	# browser client showed "IDLE" for ever while the server was playing a round.
	# `ArenaClient` writes the server's figure here from the MATCH event.
	var remaining := (
		remaining_override if not is_nan(remaining_override)
		else game.match_node.seconds_remaining()
	)
	var clock := (
		String(DotMatch.State.keys()[game.match_node.state]).capitalize() if remaining < 0.0
		# Rounded up, so the clock never says 0:00 with time left (dot-ui's; arena's own
		# rounded down until 2026-10-11).
		else DotScoreStrip.clock_text(remaining)
	)
	var mode := game.displayed_mode()
	var limit := game.match_node.rules.score_limit if game.match_node.rules != null else 0
	strip.show_clock(clock, remaining >= 0.0 and remaining <= 30.0,
		"First to %d" % limit if limit > 0 else "", mode.display_name if mode != null else "")

	var board := game.match_node.scoreboard
	var me := str(player.player_id) if _live() else ""
	var mine_record: DotPlayerScore = board.find(me) if me != "" else null
	if mode != null and mode.is_team_mode() and game.match_node.teams != null:
		# Your side on the left, as the genre has it.
		var sides: Array[int] = []
		for id: int in game.match_node.teams.team_ids():
			var side := game.match_node.teams.team(id)
			if side != null and not side.is_spectator:
				sides.append(id)
		if sides.size() >= 2:
			var mine := mine_record.team if mine_record != null else sides[0]
			var left := mine if sides.has(mine) else sides[0]
			var right := sides[1] if left == sides[0] else sides[0]
			var l := game.match_node.teams.team(left)
			var r := game.match_node.teams.team(right)
			strip.show_scores(board.team_score(left), board.team_score(right),
				l.display_name.to_upper(), r.display_name.to_upper(), l.colour, r.colour)
			return
	# A free-for-all: you, and whoever is ahead of you (behind you, when you lead).
	var other: DotPlayerScore = null
	for record in board.ranked():
		if record.present and record != mine_record:
			other = record
			break
	var leading := mine_record != null and (other == null or mine_record.score >= other.score)
	strip.show_scores(
		mine_record.score if mine_record != null else 0, other.score if other != null else 0,
		"YOU", "%s  %s" % ["2ND" if leading else "1ST", other.display_name.to_upper() if other != null else "-"],
		ArenaHudGlance.BLUE, ArenaHudGlance.RED)


## The ranked row under the strip: a portrait, rank and kill count per player.
func present_portraits() -> void:
	var entries: Array[Dictionary] = []
	var me := str(player.player_id) if _live() else ""
	var mode := game.displayed_mode()
	var teams := mode != null and mode.is_team_mode()
	var ids: Array = []
	var rank := 1
	for record in game.match_node.scoreboard.ranked():
		if not record.present or rank > ArenaHudGlance.Portraits.MAX_SHOWN:
			continue
		var id := int(record.key) if record.key.is_valid_int() else 0
		ids.append(id)
		var who := game.player_for(id) if id != 0 else null
		var avatar: DotAvatar = who.avatar if who != null and who.avatar != null \
			else ArenaAvatars.stock_avatar(StringName(ArenaGame.storage_key(id)))
		var side := _team_colour(record.team) if teams else Color(0, 0, 0, 0)
		entries.append({
			"name": record.display_name, "rank": rank, "kills": record.kills, "me": record.key == me,
			"ring": side if side.a > 0.0 else Color(1, 1, 1, 0.85),
			"colour": Color.from_hsv(fmod(float(id) * 0.37, 1.0), 0.55, 0.85),
			"texture": portrait_cache.portrait(id, avatar) if portrait_cache != null else null,
		})
		rank += 1
	portraits.show_players(entries)
	if portrait_cache != null:
		portrait_cache.keep_only(ids)


## Health, ammunition, the carried weapons and the key hints, from the followed player.
func present_gear() -> void:
	var live := _live() and player.is_alive()
	if vitals != null:
		vitals.visible = _live()
		if _live() and player.health != null:
			vitals.show_vitals(player.health.health, player.health.max_health, player.health.armour, player.health.max_armour)

	var slot: DotWeaponSlot = player.arsenal.current() if live and player.arsenal != null else null
	if ammo != null:
		if slot == null:
			ammo.show_ammo("", -1, -1, false)
		elif slot.def.magazine <= 0 and slot.def.ammo_type == &"":
			ammo.show_ammo(slot.def.display_name, -1, -1, false)
		elif slot.def.magazine <= 0:
			var pool := player.arsenal.ammo().count(slot.def.ammo_type)
			ammo.show_ammo(slot.def.display_name, pool, -1, pool <= 0)
		else:
			var reserve := player.arsenal.ammo().count(slot.def.ammo_type) if slot.def.ammo_type != &"" else -1
			ammo.show_ammo(slot.def.display_name, slot.magazine, reserve,
				float(slot.magazine) <= float(slot.def.magazine) * 0.25)

	if slots != null:
		var rows: Array[Dictionary] = []
		if live and player.arsenal != null:
			for index in player.arsenal.slots():
				var held := player.arsenal.slot_at(index)
				if held != null:
					rows.append({"slot": index, "id": held.def.id, "name": held.def.display_name,
						"key": str(keys.get(StringName("slot_%d" % index), str(index)))})
		slots.show_slots(rows, player.arsenal.current_slot() if live and player.arsenal != null else 0)

	if hints != null:
		hints.visible = live
		var shown: Array = [
			["Scoreboard", keys[&"scoreboard"]], ["Menu", keys[&"menu"]], ["Help", keys[&"help"]],
			["Maps", keys[&"maps"]],
		]
		# The loadout's key only where there is a loadout menu: an older shell, or a mode that
		# hands out the weapons, has none to open.
		var shown_mode: Variant = game.displayed_mode() if game != null else null
		if str(keys.get(&"loadout", "")) != "" and (shown_mode == null or not bool(shown_mode.call(&"arms_players"))):
			shown.append(["Loadout", keys[&"loadout"]])
		shown.append_array([["Chat", keys[&"chat"]], ["Slide", keys[&"slide"]]])
		hints.show_hints(shown)


## What the ammunition counter shows for [param who]: the magazine, or for a weapon that
## has none, what is left in its pool. Static so a suite can ask it without a HUD.
static func rounds_in_hand(who: ArenaPlayer) -> int:
	if who == null or who.arsenal == null:
		return 0

	var slot := who.arsenal.current()

	if slot == null:
		return 0

	if slot.def.magazine > 0:
		return slot.magazine

	if slot.def.ammo_type == &"":
		return 0

	return who.arsenal.ammo().count(slot.def.ammo_type)


## The line over the counter: the weapon's name and, for one with a magazine, the reserve.
## A melee weapon is its name alone.
static func weapon_line(who: ArenaPlayer) -> String:
	if who == null or who.arsenal == null or not who.is_alive():
		return ""

	var slot := who.arsenal.current()

	if slot == null:
		return ""

	if slot.def.magazine <= 0 or slot.def.ammo_type == &"":
		return slot.def.display_name

	return "%s   %d" % [slot.def.display_name, who.arsenal.ammo().count(slot.def.ammo_type)]


## The scope, the hurt edge, the launch's readiness and the slide prompt, from the
## followed player. Public so a suite can drive it without a frame.
func present_body() -> void:
	var live := _live()
	var hands: ZeeViewModel = (
		player.weapons.view_model() as ZeeViewModel
		if live and player.weapons != null else null
	)
	var scoped := hands != null and hands.is_scoped()

	if scope != null:
		scope.fraction = hands.aim_fraction() if scoped else 0.0
		if scoped and is_inside_tree():
			# The whole viewport, like the blind: sized to the HUD it left the safe area's
			# strip of world showing round the top and left of the scope (rendered).
			var inverse := get_global_transform().affine_inverse()
			scope.position = inverse * Vector2.ZERO
			scope.size = inverse.basis_xform(get_viewport_rect().size)
	if crosshair != null:
		# The scope has its own reticle; a crosshair drawn over it is two.
		crosshair.visible = not scoped
		# Down an iron sight the sight is the aiming mark: the crosshair fades out as the gun
		# comes up and back as it goes down (dot-ui's DotCrosshair, API 5; Christian's first
		# play test had both on screen at once). Hip fire keeps it.
		if _crosshair_fades:
			crosshair.call(&"set_aim", hands.aim_fraction() if hands != null and not scoped else 0.0)

	if hurt_overlay != null:
		var hurt := 0.0
		if live and player.health != null and player.health.max_health > 0.0:
			var fraction := player.health.health / player.health.max_health
			hurt = clampf((HURT_FROM - fraction) / HURT_FROM, 0.0, 1.0)
		if live and flash_source != null and is_instance_valid(flash_source):
			var flash: Color = flash_source.get(&"flash_colour")
			hurt = maxf(hurt, minf(flash.a * HURT_PULSE_GAIN, HURT_PULSE_MAX))
		hurt_overlay.modulate.a = hurt
		if hurt > 0.0 and is_inside_tree():
			# The whole viewport, as the blind does: the HUD sits in the safe area and the
			# first render drew the edge as a rectangle over the top half of the screen.
			var inverse := get_global_transform().affine_inverse()
			hurt_overlay.position = inverse * Vector2.ZERO
			hurt_overlay.size = inverse.basis_xform(get_viewport_rect().size)

	var state: DotFpsState = player.controller.state if live else null
	var tunables: DotFpsTunables = player.controller.tunables if live else null
	present_abilities(state, tunables)

	# What can be done right now, as the genre prompts it.
	if slide_label != null:
		if state != null and state.is_sliding():
			slide_label.show_prompt("Cancel slide", str(keys[&"slide"]))
		elif live and player.is_alive() and _needs_reload():
			slide_label.show_prompt("Reload", str(keys[&"reload"]))
		elif roam_hint != "" and player != null and not player.is_alive():
			slide_label.show_prompt(roam_hint, str(keys[&"roam"]))
		else:
			slide_label.show_prompt("", "")

	_build_feedback()
	if death_label == null:
		death_label = _make_label("Death", Control.PRESET_CENTER_TOP, Vector2(0.0, 222.0))
		death_label.add_theme_font_size_override(&"font_size", 22)

	var delta := get_process_delta_time()
	var streak := int(streaks.get(player.player_id, 0)) if player != null else 0
	streak_meter.visible = live
	streak_meter.set_count(streak, STREAK_FULL)
	streak_meter.advance(delta)
	# The hit marker and the damage numbers advance themselves (`DotHudPiece._process`).
	medal_row.advance(delta)

	if notice_label != null:
		_notice_age += delta
		notice_label.modulate.a = clampf((NOTICE_SEC - _notice_age) / 0.5, 0.0, 1.0)

	death_label.visible = player != null and not player.is_alive() and _death_text != ""
	death_label.text = _death_text

	if coins_label == null:
		# Top left, under the challenge: a count, not something to watch.
		coins_label = _make_label("Coins", Control.PRESET_TOP_LEFT, Vector2(0.0, 40.0))
		coins_label.grow_horizontal = Control.GROW_DIRECTION_END
		coins_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		coins_label.offset_left = 8.0
		coins_label.add_theme_color_override(&"font_color", Color(1.0, 0.82, 0.25))
	var count := 0
	if live and game != null and game.drops != null:
		count = int(game.drops.coins.get(player.player_id, 0))
	coins_label.visible = count > 0
	coins_label.text = coins_text(count)

	if _coins_seen >= 0 and count > _coins_seen:
		popup("+" + coins_text(count - _coins_seen), Color(1.0, 0.82, 0.25))
	_coins_seen = count

	_advance_popups(get_process_delta_time())
	present_challenge(live)


## The ability buttons from the followed player's movement state: slide, launch and dash
## with their cooldowns, and the wall jump with its jumps left in the air. Only the ones
## the server's rules turn on.
func present_abilities(state: DotFpsState, tunables: DotFpsTunables) -> void:
	if abilities == null:
		return
	var buttons: Array[Dictionary] = []
	if state != null and tunables != null:
		if tunables.slide_enabled:
			buttons.append(_button(&"slide", "Slide", state.slide_cooldown_left, tunables.slide_cooldown, state.is_sliding()))
		if tunables.launch_enabled:
			buttons.append(_button(&"launch", "Launch", state.launch_cooldown_left, tunables.launch_cooldown, false))
		if tunables.dash_enabled:
			buttons.append(_button(&"dash", "Dash", state.dash_cooldown_left, tunables.dash_cooldown, false))
		if tunables.wall_jump_enabled:
			var b := _button(&"wall_jump", "Wall jump", 0.0, 0.0, state.is_wall_running())
			b["key"] = keys[&"jump"]
			b["pips_max"] = tunables.wall_jump_max_per_air
			b["pips"] = maxi(0, tunables.wall_jump_max_per_air - state.wall_jumps_in_air)
			buttons.append(b)
	abilities.visible = not buttons.is_empty()
	abilities.show_buttons(buttons)


func _button(id: StringName, label: String, left: float, total: float, active: bool) -> Dictionary:
	return {
		"id": id, "label": label, "key": str(keys.get(id, "")), "left": maxf(left, 0.0), "total": total,
		"active": active, "icon": ArenaHudGlance.Ink.texture("%s/%s.png" % [ArenaHudGlance.HUD_ICON_DIR, String(id)]),
	}


## An empty magazine with rounds in reserve: the moment to say R.
func _needs_reload() -> bool:
	if player.arsenal == null:
		return false
	var slot := player.arsenal.current()
	if slot == null or slot.def.magazine <= 0 or slot.magazine > 0 or slot.def.ammo_type == &"":
		return false
	return player.arsenal.ammo().count(slot.def.ammo_type) > 0 and not player.arsenal.is_reloading()


## Fades [member blind_overlay] toward whether the followed player is blinded.
##
## Read off [member player] rather than pushed by anybody, because the flag arrives in a
## snapshot on a networked client and is set directly offline, and a HUD that had to be
## told would need telling from two places. Public so a check can step it.
func present_blind(delta: float) -> void:
	if blind_overlay == null:
		return

	var want := 1.0 if _live() and player.blinded else 0.0
	blind_overlay.modulate.a = move_toward(
		blind_overlay.modulate.a, want, maxf(delta, 0.0) / BLIND_FADE_SEC
	)
	blind_overlay.visible = blind_overlay.modulate.a > 0.0

	if blind_overlay.visible and is_inside_tree():
		# The whole viewport, in this HUD's own coordinates — whatever the safe area and
		# the interface scale did to where this HUD starts.
		var inverse := get_global_transform().affine_inverse()
		blind_overlay.position = inverse * Vector2.ZERO
		blind_overlay.size = inverse.basis_xform(get_viewport_rect().size)


## One line about the objectives, or nothing at all.
##
## Reads the mirroring manager on a client and the real one on a listen server, which
## is the same object either way: `ArenaObjectives` holds a `DotObjectiveManager` whose
## `authoritative` decides whether it simulates, and a HUD asking it for a fraction does
## not care which.
func _objective_line() -> String:
	if game.objectives == null or game.objectives.manager == null:
		return ""

	var manager := game.objectives.manager

	if not manager.has_objectives():
		return ""

	var parts := PackedStringArray()

	for objective in manager.objectives.objectives:
		var label := objective.def.label if objective.def.label != "" \
			else String(objective.id())

		if objective is DotObjectiveHoldout:
			var holdout := objective as DotObjectiveHoldout
			var lead := holdout.leader()
			if lead <= 0:
				parts.append("%s --" % label)
			else:
				var left := holdout.remaining_for(lead)
				parts.append(
					"%s %d:%02d" % [
						label,
						left / (60 * game.tick_rate),
						(left / game.tick_rate) % 60,
					]
				)
		elif objective is DotObjectiveFlag:
			var flag := objective as DotObjectiveFlag
			parts.append(
				"%s %s" % [
					label,
					DotObjectiveFlag.State.keys()[flag.state].substr(0, 4),
				]
			)
		elif objective.owner_team > 0:
			parts.append("%s:%d" % [label, objective.owner_team])
		else:
			parts.append("%s %d%%" % [label, int(objective.progress() * 100.0)])

	return "  ".join(parts)
