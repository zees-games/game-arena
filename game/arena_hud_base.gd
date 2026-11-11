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
const ArenaEvents := preload("arena_events.gd")

## The in-game display, laid out for a glance (see [ArenaHudGlance]): scores, clock and portraits at the top centre, the kill feed top right, health bottom left, magazine and reserve bottom right with the carried weapons up the right edge, abilities bottom centre, key hints on the left; kill feedback over the middle.
## [b]Built here rather than shipped by dot-ui, and that is the division of labour.[/b] dot-ui draws a bounded self-expiring list of coloured fragments and a bar from a `Callable`; it does not know what a kill or health is. Every widget below is a dot-ui class bound to a game value, and the binding is the only thing in this file.
## Almost no art: the bars and plates are drawn; the weapon silhouettes are rendered from the models (`tools/build_weapon_icons.sh`); the medal and ability icons are Kenney's CC0.


## The player this HUD is about. Rebound on spawn, because the body is replaced.
var player: ArenaPlayer = null


var game: ArenaGame = null


var crosshair: DotCrosshair = null
## Whether the host's DotCrosshair fades while aiming (dot-ui API 5).
var _crosshair_fades: bool = DotAddonApi.build_level("dot_ui") >= 5
## Whether DotCrosshair hides itself while the viewer is dead (dot-ui API 14).
var _crosshair_hides: bool = DotAddonApi.build_level("dot_ui") >= 14


## Bottom left: health as a bar with its number, armour as a thin bar under it.
var vitals: DotVitals = null
## `magazine | reserve` under the weapon's name, bottom right.
var ammo: DotAmmoCounter = null
## The carried weapons up the right edge.
var slots: ArenaHudGlance.WeaponSlots = null
## Top right: killer, weapon silhouette, victim.
var feed: ArenaHudGlance.KillFeed = null
## Top centre: each side's score (yours and the leader's in a free-for-all), the clock, the target and the mode.
var strip: ArenaHudGlance.TeamStrip = null
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


var _weapon_label := ""
var _label_slot: DotWeaponSlot = null
var _label_mode := -1
var _label_key := ""
const SLOT_KEYS: Array[StringName] = [&"slot_0", &"slot_1", &"slot_2", &"slot_3", &"slot_4", &"slot_5", &"slot_6", &"slot_7", &"slot_8", &"slot_9"]


## The key each prompt, hint and button names, as the player has it bound. The client
## writes these from its key table ([method ArenaClient._hud_keys]); the defaults are the
## table's.
var keys: Dictionary = {
	&"slide": "C", &"launch": "E", &"dash": "Shift", &"jump": "Space",
	&"scoreboard": "Tab", &"menu": "Esc", &"chat": "Y", &"reload": "R", &"help": "H",
	&"maps": "M", &"loadout": "", &"roam": "T", &"use": "E", &"fire_mode": "N",
}


## The spectator's key hint ("Free camera", "Back to players"), set by the client while the
## viewer is dead and may roam; empty otherwise. Drawn in the prompt line.
var roam_hint: String = ""
## "Pick up Assault Rifle" while a dropped weapon you can take is looked at; empty otherwise.
var use_hint: String = ""


## Seconds until the portraits are read again: a ranked row a few times a second is a
## row that keeps up, and once a frame is ten lookups for nothing.
var _portraits_in: float = 0.0


## What the round is about, when it is about something. Empty in a deathmatch.
##
## One line, not a widget per objective: a hill and a flag want different pictures.
var objective_label: Label = null

## "YOU HAVE THE RED FLAG", big, while the followed player carries one. Hidden otherwise.
var carry_label: Label = null


## An administrator's `blind`, over the world and under the rest of the HUD, so the clock, kill feed and health still read as "an admin did this"
## rather than a client that stopped drawing. Black, not white: full white hurts in a dark room.
var blind_overlay: ColorRect = null


## The scope, drawn at full aim with a scoped weapon. Under every widget, over the world.
var scope: AwScopeOverlay = null


## Red at the screen's edge when the followed player is badly hurt, and a short pulse of it on every hit. Drawn by a shader per pixel ([constant HURT_SHADER]), so no art and no resolution of its own;
## strongest at no health, gone above [constant HURT_FROM]. A shader, not a gradient texture: a 64 by 64 one stretched over 1080p showed visible steps.
var hurt_overlay: ColorRect = null
const HURT_FROM := 0.35


## The hit pulse: dot-fx's `hurt_flash` (strength in [member flash_source]'s `flash_colour`), drawn at
## the edge. Read through dot-fx so "no flashes" and the three-a-second limit hold; the gain maps its peak (0.28) to about the max.
var flash_source: Object = null
const HURT_PULSE_GAIN := 2.2
const HURT_PULSE_MAX := 0.6


## The edge, per pixel. Distance is measured in the screen's own shape (an ellipse touching the edges), so the clear middle is the same share of a 4:3 and a 21:9 frame; `smoothstep` then a square gives a soft start and a deep rim.
## Alpha is the node's modulate, so the strength is one number the HUD writes and the checks read.
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


## The points this player has collected this match, from the drops layer.
var points_label: Label = null


## Kills since each player last died, counted from the KILL events every client gets, so
## the meter needs nothing new on the wire. See [method note_kill].
var streaks: Dictionary = {}


## Players the server named as the followed player's nemesis (an AWARD with
## [constant ArenaAwards.Medal].NEMESIS for a kill of them), until they are killed back.
## Only ever written from AWARD: the HUD counts nothing about who killed whom itself.
var nemeses: Dictionary = {}


## Kills the vitals' killstreak row counts toward.
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
		if shown.is_empty():
			return
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


## A line for everybody to read: a chat line, a map change, "REVENGE!". Held for [constant NOTICE_SEC] and faded.
## [b]Wrapped, two lines at most, and narrower than the gap between the right-hand column and the middle.[/b] It was one unbounded line: the server's "Vote: Smash Copter, Hide & Seek, …" ran off the right edge of a 1280-wide frame, behind the shell's ballot (360 px wide, 16 px in).
## Centred, the line clears that column only when its half-width is under the distance from the middle to the column, so the width follows the frame: `notice_width`.
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


## [b]A vote's opening line, which a drawn ballot makes a duplicate.[/b] dot-vote says "Vote: Box, Atrium, … (20s)" in chat as its ballot opens, and `ArenaClient._on_said` centre prints every system line,
## so while the shell's ballot was on screen the same list was in the middle too, over the medals' row. Only that shape: dot-server's yes/no vote ("Vote: <question> — type !yes or !no (20s)") stays,
## because "!yes" is how to answer it and a ballot is not always drawn for one.
static func is_ballot_line(text: String) -> bool:
	if not text.begins_with("Vote: ") or text.contains("!yes"):
		return false
	var open := text.rfind(" (")
	return open > 0 and text.ends_with("s)") and text.substr(open + 2, text.length() - open - 4).is_valid_int()


## [b]Keeps the HUD out from under the client shell's ballots[/b], every frame. The shell draws every ballot down the right-hand side, over whatever the game drew, and cannot reach into a delivered game, so the game looks:
## `DotHudPiece.covered_rect` is every visible member of the `dot_hud_cover` group, merged, in this HUD's own coordinates; dot-ui's pieces each dim themselves under one.
## The weapon slots up the right edge tighten, then show only the rows around the current one, to end above a ballot (a seven-row map ballot reaches slot 1 at 1280x720); the vote's centre line goes while its ballot is drawn.
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


## Where the centre notice starts on a frame [param frame_height] tall: under the medal row's labels (centred at 27 % of the height, names ending about 65 px below), so a system line arriving with a kill is not printed through "Headshot!".
## Never lower than 70 px above the middle, where the crosshair is: on a short frame the medals give way, not the aim.
static func notice_top(frame_height: float) -> float:
	return minf(maxf(182.0, frame_height * 0.27 + 70.0), frame_height * 0.5 - 70.0)


## The ammo line's name for [param slot]: the weapon, then its fire mode and the key when it has a choice.
static func mode_label(slot: DotWeaponSlot, key: String) -> String:
	var name := slot.def.display_name
	if slot.def.allowed_fire_modes().size() < 2:
		return name
	var mode := String(DotWeaponDef.Fire.keys()[slot.fire_mode()])
	return "".join([name, "  ", mode, "".join([" [", key, "]"]) if key != "" else ""])


## "1 point", "5 points": the count and the noun, agreed (the play test read "+1 POINTS").
static func points_text(count: int) -> String:
	return "%d point" % count if absi(count) == 1 else "%d points" % count


## Seconds a "+N" popup rises and fades over.
const POPUP_SEC := 1.3


## A kill's "+points  Victim" stays longer: it is the line the genre holds while the
## medals play.
const KILL_POPUP_SEC := 2.6


## Rising "+1" / "+3 POINTS" lines beside the crosshair: [Label, age].
var _popups: Array = []


## The point count last frame, so a rise can be told as a popup.
var _points_seen: int = -1


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


## The hit marker, the damage numbers and the medal row. Built once, on
## first need, over everything else on the HUD.
func _build_feedback() -> void:
	if hit_marker != null:
		return
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


## The frame the HUD is drawn for ([member DotHud.fit_design]): below it the whole HUD is scaled down by `DotHud.fit_scale`, never laid out again. [b]On a smaller frame its pieces ran into each other[/b]
## (at 854x480 the challenge ran over the scores, the ability bar over the health; at 960x720 the scores reached the kill feed). The shell never shows a game such a frame (canvas 1280x720, stretched), so this is the same answer for the game on its own.
## Never larger: on a bigger frame the pieces keep their size and the map gets the room. dot-ui took it over (`fit_design`, `fit_scale`, `fit_to_frame`, API 4); below half size (`fit_min`) a frame gets overlap, not dust.
const DESIGN_FRAME := Vector2(1280.0, 720.0)


func _init() -> void:
	# Before `_ready`, which is where `DotHud` decides between anchoring and fitting, and
	# follows the viewport's size from then on.
	fit_design = DESIGN_FRAME
	# The strip, the portraits and the text lines change a few times a second, not per frame: a timer, so the work (strings, rows) is off the frame path.
	var slow := Timer.new()
	slow.wait_time = SLOW_PERIOD
	slow.autostart = true
	slow.timeout.connect(_present_slow)
	add_child(slow, false, Node.INTERNAL_MODE_BACK)


## Seconds between the slow HUD parts (clock, scores, portraits, objective and flag lines).
const SLOW_PERIOD := 0.1


## The slow parts; `ArenaHud` fills it in.
func _present_slow() -> void:
	pass


## Arena's own colour over whichever theme the player picked: gold for "yours" (your ring, row, slot and streak). Everything else (plates, words, ink, key caps) is the theme's,
## so Paper and High contrast can change it; `ArenaClient` hands this to dot-menu's `follow_hud` with the HUD.
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


func _make_label(
	node_name: String,
	preset: Control.LayoutPreset,
	offset: Vector2
) -> Label:
	var label := Label.new()
	label.name = node_name
	label.set_anchors_preset(preset)
	label.offset_top = offset.y
	# [b]Grow both ways, or "centred" means "starts at the centre".[/b] A centre-top preset is a zero-width box at the middle of the screen, and a `Label` wider than its box grows by `grow_horizontal`,
	# which defaults to END, so the text is pushed rightwards from the midline and `HORIZONTAL_ALIGNMENT_CENTER` has nothing to centre inside (the round clock drew at x = 640..680 on a 1280-wide frame).
	# Only a rendered frame shows it.
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
