@tool
extends DotHud

const ArenaGame := preload("arena_game.gd")
const ArenaPlayer := preload("arena_player.gd")
const ArenaAwards := preload("arena_awards.gd")
const ArenaPaths := preload("arena_paths.gd")

## The in-game display: crosshair, health, armour, ammo, kill feed, round timer.
##
## [b]Built here rather than shipped by dot-ui, and that is the division of labour.[/b]
## dot-ui knows how to draw a bounded self-expiring list of coloured fragments; it does
## not know what a kill is. It knows how to draw a bar from a `Callable`; it does not
## know what health is. Every widget below is a dot-ui class bound to a game value, and
## the binding is the only thing in this file.
##
## No art. The theme is generated, the crosshair is drawn, and the bars are rectangles
## — which is what the rest of a dev-textured game looks like anyway.

## The player this HUD is about. Rebound on spawn, because the body is replaced.
var player: ArenaPlayer = null

var game: ArenaGame = null

var crosshair: DotCrosshair = null
var health_bar: DotStatBar = null
var armour_bar: DotStatBar = null
var ammo_bar: DotStatBar = null

## What is in hand and what is behind it: "Rifle  90". Over the ammunition.
var weapon_label: Label = null
var feed: DotFeedView = null
var timer_label: Label = null

## Seconds left, when something other than this game's own match knows. NAN means
## "ask the match", which is what a server and an offline client do.
var remaining_override: float = NAN
var score_label: Label = null

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

## Red at the screen's edge when the followed player is badly hurt. A radial gradient, so
## no art; strongest at no health, gone above [constant HURT_FROM].
var hurt_overlay: TextureRect = null
const HURT_FROM := 0.35

## The launch: "E LAUNCH" when ready, the seconds left when not. The key is the client's
## to say ([member launch_key_text]), because it is X in a mode where E is the prop tool.
var ability_label: Label = null
var launch_key_text: String = "E"

## "C  Cancel slide" while sliding, as the prompt the genre shows.
var slide_label: Label = null

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
var hit_marker: HitMarker = null

## Numbers rising off whatever was hit, gold for a headshot.
var damage_numbers: DamageNumbers = null

## The medals of the followed player's last kills: icon, name, scale in, hold, fade.
var medal_row: MedalRow = null

## "Killed by NAME (weapon)", and the nemesis line, while the followed player is dead.
var death_label: Label = null
var _death_text: String = ""


## The feedback's gold: the streak, the points, a headshot's number.
const GOLD := Color(1.0, 0.8, 0.22)

## A kill's red: the hit marker on a lethal hit.
const KILL_RED := Color(1.0, 0.22, 0.2)

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
		canvas.draw_string_outline(
			font, at, text, align, width, font_size, outline, Color(0.05, 0.03, 0.08, colour.a * 0.85)
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

	func _draw() -> void:
		var width := 10.0
		var track := Rect2(0.0, 0.0, width, size.y)
		var back := StyleBoxFlat.new()
		back.bg_color = Color(0.05, 0.04, 0.1, 0.5)
		back.set_corner_radius_all(4)
		back.border_color = Color(1.0, 1.0, 1.0, 0.25)
		back.set_border_width_all(1)
		draw_style_box(back, track.grow(1.0))
		var fill := track.size.y * _shown
		if fill > 0.5:
			var bar := StyleBoxFlat.new()
			bar.bg_color = GOLD
			bar.set_corner_radius_all(4)
			draw_style_box(bar, Rect2(0.0, track.size.y - fill, width, fill))
			draw_rect(Rect2(1.5, track.size.y - fill + 2.0, 2.0, maxf(0.0, fill - 4.0)), Color(1.0, 0.95, 0.7, 0.7))

		var pulse := 1.0 + 0.35 * maxf(0.0, 1.0 - _since / 0.3)
		var icon := Look.medal_icon("fire")
		var side := 26.0 * pulse
		var at := Rect2(Vector2(width * 0.5 - side * 0.5, -side - 8.0), Vector2(side, side))
		if icon != null:
			draw_texture_rect(icon, at.grow(2.0), false, Color(0.1, 0.05, 0.0, 0.6))
			draw_texture_rect(icon, at, false, GOLD if count > 0 else Color(1.0, 1.0, 1.0, 0.45))
		Look.draw_outlined(
			self, Look.feedback_font(true), Vector2(-14.0, size.y + 26.0), "Killstreak x%d" % count,
			17, GOLD if count > 0 else Color(1.0, 1.0, 1.0, 0.6), 6
		)


## Four ticks round the crosshair: white on a hit, larger and red on a kill, with a short
## pop outward as it appears and a fade. Only ever flashed by a hit the server confirmed.
class HitMarker extends Control:
	const HIT_SEC := 0.28
	const KILL_SEC := 0.6
	var age: float = 99.0
	var life: float = HIT_SEC
	var kill: bool = false
	var headshot: bool = false

	## 1 when it has just flashed, 0 when it is gone.
	var alpha: float:
		get:
			return clampf(1.0 - age / life, 0.0, 1.0)

	func flash(p_kill: bool, p_headshot: bool) -> void:
		# A pellet landing after the lethal one in the same burst must not turn red white.
		if kill and not p_kill and age < life * 0.5:
			return
		kill = p_kill
		headshot = p_headshot
		age = 0.0
		life = KILL_SEC if p_kill else HIT_SEC
		queue_redraw()

	func advance(delta: float) -> void:
		age += delta
		queue_redraw()

	func _draw() -> void:
		var a := alpha
		if a <= 0.0:
			return
		var c := size * 0.5
		var pop := 1.0 + 0.5 * maxf(0.0, 1.0 - age / 0.08)
		var gap := (9.0 if kill else 7.0) * pop
		var reach := gap + (16.0 if kill else 10.0) * pop
		var thick := 4.0 if kill else 2.5
		var colour := KILL_RED if kill else (Color(1.0, 0.9, 0.6) if headshot else Color.WHITE)
		for d in [Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]:
			var v: Vector2 = (d as Vector2).normalized()
			draw_line(c + v * (gap - 1.0), c + v * (reach + 1.0), Color(0.0, 0.0, 0.0, 0.55 * a), thick + 2.5, true)
			draw_line(c + v * gap, c + v * reach, Color(colour, a), thick, true)


## Damage numbers: each rises off the point the server said it landed, projected through
## the camera every frame, so it stays on the body while the view moves. Hits on one victim
## within [constant MERGE_SEC] add up into one number, the way a burst reads as one hit.
class DamageNumbers extends Control:
	const LIFE_SEC := 0.9
	const MERGE_SEC := 0.35
	const RISE_PX := 70.0
	var entries: Array[Dictionary] = []
	var _seed: int = 0

	func add(victim: int, amount: float, point: Vector3, headshot: bool) -> void:
		for e in entries:
			if int(e["victim"]) == victim and float(e["age"]) < MERGE_SEC:
				e["amount"] = float(e["amount"]) + amount
				e["headshot"] = bool(e["headshot"]) or headshot
				e["age"] = 0.0
				return
		_seed += 1
		# A small sideways scatter, deterministic, so two numbers on one body do not stack.
		var drift := float((_seed * 37) % 7 - 3) * 9.0
		entries.append({
			"victim": victim, "amount": amount, "point": point, "headshot": headshot,
			"age": 0.0, "drift": drift,
		})

	func advance(delta: float) -> void:
		for i in range(entries.size() - 1, -1, -1):
			entries[i]["age"] = float(entries[i]["age"]) + delta
			if float(entries[i]["age"]) >= LIFE_SEC:
				entries.remove_at(i)
		queue_redraw()

	func _draw() -> void:
		var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
		if camera == null:
			return
		var to_local := get_global_transform().affine_inverse()
		var font := Look.feedback_font(true)
		for e in entries:
			var point: Vector3 = e["point"]
			if camera.is_position_behind(point):
				continue
			var t := float(e["age"]) / LIFE_SEC
			var head := bool(e["headshot"])
			var at: Vector2 = to_local * camera.unproject_position(point)
			at += Vector2(float(e["drift"]), -RISE_PX * (1.0 - pow(1.0 - t, 2.0)))
			var pop := 1.0 + 0.6 * maxf(0.0, 1.0 - float(e["age"]) / 0.1)
			var font_size := int(round((30.0 if head else 24.0) * pop))
			var colour := GOLD if head else Color.WHITE
			colour.a = clampf((1.0 - t) / 0.4, 0.0, 1.0)
			var text := str(int(roundf(float(e["amount"]))))
			Look.draw_outlined(self, font, at + Vector2(-60.0, 0.0), text, font_size, colour, 7, HORIZONTAL_ALIGNMENT_CENTER, 120.0)


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
			draw_circle(at, r + 3.5, Color(1.0, 1.0, 1.0, 0.92 * fade))
			draw_circle(at, r, Color(colour.darkened(0.25), fade))
			draw_circle(at - Vector2(0.0, r * 0.12), r * 0.86, Color(colour, fade))
			var icon: Texture2D = m["icon"]
			if icon != null:
				var side := r * 1.4
				draw_texture_rect(icon, Rect2(at - Vector2(side, side) * 0.5, Vector2(side, side)), false, Color(1.0, 1.0, 1.0, fade))
			var medal := int(m["medal"])
			var tally := (
				"2" if medal == ArenaAwards.Medal.DOUBLE_KILL
				else "3" if medal == ArenaAwards.Medal.TRIPLE_KILL
				else "4+" if medal == ArenaAwards.Medal.MULTI_KILL else ""
			)
			if tally != "":
				var badge := at + Vector2(r * 0.72, r * 0.62)
				draw_circle(badge, 12.0 * grow, Color(1.0, 1.0, 1.0, fade))
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
func notice(text: String) -> void:
	if notice_label == null:
		notice_label = _make_label("Notice", Control.PRESET_CENTER_TOP, Vector2(0.0, 110.0))
	notice_label.text = text
	notice_label.modulate.a = 1.0
	_notice_age = 0.0

var notice_label: Label = null
var _notice_age: float = 0.0
const NOTICE_SEC := 4.0

## The challenge bar at the top: the achievement the player is nearest to, and how near.
var challenge_label: Label = null
var challenge_bar: ProgressBar = null
var _challenges: DotAchievementCatalogue = null


func present_challenge(live: bool) -> void:
	if challenge_label == null:
		challenge_label = _make_label("Challenge", Control.PRESET_CENTER_TOP, Vector2(0.0, 62.0))
		challenge_label.add_theme_font_size_override(&"font_size", 15)
		challenge_bar = ProgressBar.new()
		challenge_bar.name = "ChallengeBar"
		challenge_bar.show_percentage = false
		challenge_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		challenge_bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
		challenge_bar.offset_left = -150.0
		challenge_bar.offset_right = 150.0
		challenge_bar.offset_top = 88.0
		challenge_bar.offset_bottom = 94.0
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
	challenge_label.text = "%s — %s  (%d/%d)" % [a.display_name, a.description.trim_suffix("."), player.challenge_value, target]
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
	streak_meter.position = Vector2(34.0, -150.0)
	streak_meter.size = Vector2(10.0, 250.0)
	add_child(streak_meter)
	damage_numbers = DamageNumbers.new()
	damage_numbers.name = "DamageNumbers"
	damage_numbers.mouse_filter = Control.MOUSE_FILTER_IGNORE
	damage_numbers.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(damage_numbers)
	hit_marker = HitMarker.new()
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

	hurt_overlay = TextureRect.new()
	hurt_overlay.name = "Hurt"
	var gradient := Gradient.new()
	# Clear over the middle two thirds, so it reads as the edge of vision closing in
	# rather than as a red filter over the screen (the first render was the second).
	gradient.set_color(0, Color(0.75, 0.0, 0.0, 0.0))
	gradient.set_color(1, Color(0.75, 0.0, 0.0, 0.7))
	gradient.add_point(0.72, Color(0.75, 0.0, 0.0, 0.0))
	var radial := GradientTexture2D.new()
	radial.gradient = gradient
	radial.fill = GradientTexture2D.FILL_RADIAL
	radial.fill_from = Vector2(0.5, 0.5)
	radial.fill_to = Vector2(1.0, 0.5)
	hurt_overlay.texture = radial
	hurt_overlay.stretch_mode = TextureRect.STRETCH_SCALE
	hurt_overlay.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	hurt_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
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

	health_bar = _make_bar("Health", "%d", Vector2(24.0, -96.0), Vector2(220.0, 34.0))
	health_bar.fill_colour = Color(0.35, 0.80, 0.45)
	health_bar.low_colour = Color(0.90, 0.30, 0.28)
	health_bar.bind(func() -> Variant:
		return player.health.health if _live() else 0.0
	)
	health_bar.max_source = func() -> Variant:
		return player.health.max_health if _live() else 100.0

	armour_bar = _make_bar("Armour", "%d", Vector2(24.0, -56.0), Vector2(220.0, 26.0))
	armour_bar.fill_colour = Color(0.35, 0.62, 0.95)
	armour_bar.low_fraction = 0.0
	armour_bar.bind(func() -> Variant:
		return player.health.armour if _live() else 0.0
	)
	armour_bar.max_source = func() -> Variant:
		return player.health.max_armour if _live() else 100.0

	ammo_bar = _make_bar("Ammo", "%d", Vector2(-240.0, -96.0), Vector2(216.0, 34.0))
	ammo_bar.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	ammo_bar.offset_left = -240.0
	ammo_bar.offset_top = -96.0
	ammo_bar.offset_right = -24.0
	ammo_bar.offset_bottom = -62.0
	ammo_bar.show_bar = false
	# The magazine, or the pool for a weapon with none. The beamer feeds straight from
	# its cells and a grenade is its own round, so a magazine count reads 0 for both
	# while they are perfectly usable, and a player looking at a zero switches away.
	ammo_bar.bind(func() -> Variant:
		return float(rounds_in_hand(player if _live() else null))
	)
	ammo_bar.max_source = func() -> Variant:
		if not _live():
			return 1.0
		var slot := player.arsenal.current()
		return float(maxi(1, slot.def.magazine)) if slot != null else 1.0

	weapon_label = Label.new()
	weapon_label.name = "Weapon"
	weapon_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	# Over the counter and aligned with it: the bar draws its number at its left edge, and
	# a name right-aligned above it read as two unrelated pieces of text.
	weapon_label.offset_left = -240.0
	weapon_label.offset_top = -126.0
	weapon_label.offset_right = 0.0
	weapon_label.offset_bottom = -100.0
	weapon_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	weapon_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(weapon_label)

	feed = DotFeedView.new()
	feed.name = "KillFeed"
	feed.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	feed.offset_left = -480.0
	feed.offset_top = 12.0
	feed.offset_right = 0.0
	feed.offset_bottom = 140.0
	feed.max_lines = config.feed_lines
	feed.lifetime_sec = config.feed_lifetime_sec
	feed.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(feed)

	timer_label = _make_label("Timer", Control.PRESET_CENTER_TOP, Vector2(0.0, 8.0))
	score_label = _make_label("Score", Control.PRESET_CENTER_TOP, Vector2(0.0, 34.0))
	score_label.theme_type_variation = &"DotDim"

	objective_label = _make_label(
		"Objective", Control.PRESET_CENTER_TOP, Vector2(0.0, 58.0)
	)
	objective_label.theme_type_variation = &"DotDim"

	if game != null:
		game.player_killed.connect(_on_kill)


func _make_bar(
	node_name: String,
	format: String,
	offset: Vector2,
	size_hint: Vector2
) -> DotStatBar:
	var bar := DotStatBar.new()
	bar.name = node_name
	bar.format = format
	bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bar.offset_left = offset.x
	bar.offset_top = offset.y
	bar.offset_right = offset.x + size_hint.x
	bar.offset_bottom = offset.y + size_hint.y
	bar.ease_sec = 0.18
	add_child(bar)
	return bar


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
	add_child(label)
	return label


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

	var mine := Color(1.0, 0.85, 0.35)
	var theirs := Color(0.86, 0.88, 0.92)
	var me := str(player.player_id) if _live() else ""

	feed.add_kill(
		entry.killer_name,
		mine if entry.killer_key == me else theirs,
		cause_label(entry.cause),
		entry.victim_name,
		mine if entry.victim_key == me else theirs,
		entry.headshot
	)


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

	match_view()
	present_blind(delta)
	present_body()

	if weapon_label != null:
		weapon_label.text = weapon_line(player if _live() else null)

	if game == null or timer_label == null:
		return

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

	timer_label.text = (
		DotMatch.State.keys()[game.match_node.state] if remaining < 0.0
		else "%d:%02d" % [int(remaining) / 60, int(remaining) % 60]
	)

	var leader := game.match_node.scoreboard.leader()
	score_label.text = (
		"" if leader == null
		else "%s  %d / %d" % [
			leader.display_name, leader.score, game.match_node.rules.score_limit
		]
	)

	if objective_label != null:
		objective_label.text = _objective_line()


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

	if hurt_overlay != null:
		var hurt := 0.0
		if live and player.health != null and player.health.max_health > 0.0:
			var fraction := player.health.health / player.health.max_health
			hurt = clampf((HURT_FROM - fraction) / HURT_FROM, 0.0, 1.0)
		hurt_overlay.modulate.a = hurt
		if hurt > 0.0 and is_inside_tree():
			# The whole viewport, as the blind does: the HUD sits in the safe area and the
			# first render drew the edge as a rectangle over the top half of the screen.
			var inverse := get_global_transform().affine_inverse()
			hurt_overlay.position = inverse * Vector2.ZERO
			hurt_overlay.size = inverse.basis_xform(get_viewport_rect().size)

	if ability_label == null:
		# Left of centre and above the bars, clear of the hands and the gun in them.
		ability_label = _make_label("Ability", Control.PRESET_CENTER_BOTTOM, Vector2(0.0, -150.0))
		ability_label.offset_left = -360.0
		ability_label.offset_right = -200.0
		slide_label = _make_label("Slide", Control.PRESET_CENTER, Vector2(0.0, 80.0))

	var state: DotFpsState = player.controller.state if live else null
	var tunables: DotFpsTunables = player.controller.tunables if live else null

	ability_label.visible = live and tunables != null and (tunables.launch_enabled or tunables.dash_enabled)
	if ability_label.visible:
		var lines := PackedStringArray()
		if tunables.launch_enabled:
			var left := state.launch_cooldown_left
			lines.append(
				"%s  LAUNCH" % launch_key_text if left <= 0.0
				else "%s  %.1f" % [launch_key_text, left]
			)
		if tunables.dash_enabled:
			var dash_left := state.dash_cooldown_left
			lines.append("SHIFT  DASH" if dash_left <= 0.0 else "SHIFT  %.1f" % dash_left)
		ability_label.text = "\n".join(lines)

	slide_label.visible = live and state != null and state.is_sliding()
	slide_label.text = "C  Cancel slide"

	_build_feedback()
	if death_label == null:
		death_label = _make_label("Death", Control.PRESET_CENTER_TOP, Vector2(0.0, 150.0))

	var delta := get_process_delta_time()
	var streak := int(streaks.get(player.player_id, 0)) if player != null else 0
	streak_meter.visible = live
	streak_meter.set_count(streak, STREAK_FULL)
	streak_meter.advance(delta)
	hit_marker.advance(delta)
	damage_numbers.advance(delta)
	medal_row.advance(delta)

	if notice_label != null:
		_notice_age += delta
		notice_label.modulate.a = clampf((NOTICE_SEC - _notice_age) / 0.5, 0.0, 1.0)

	death_label.visible = player != null and not player.is_alive() and _death_text != ""
	death_label.text = _death_text

	if coins_label == null:
		coins_label = _make_label("Coins", Control.PRESET_CENTER_BOTTOM, Vector2(0.0, -150.0))
		coins_label.offset_left = 200.0
		coins_label.offset_right = 360.0
		coins_label.add_theme_color_override(&"font_color", Color(1.0, 0.82, 0.25))
	var count := 0
	if live and game != null and game.drops != null:
		count = int(game.drops.coins.get(player.player_id, 0))
	coins_label.visible = count > 0
	coins_label.text = "%d  COINS" % count

	if _coins_seen >= 0 and count > _coins_seen:
		popup("+%d  COINS" % (count - _coins_seen), Color(1.0, 0.82, 0.25))
	_coins_seen = count

	_advance_popups(get_process_delta_time())
	present_challenge(live)


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
