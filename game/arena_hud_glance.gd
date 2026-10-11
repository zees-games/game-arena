extends RefCounted

const ArenaPaths := preload("arena_paths.gd")

## The HUD laid out for a glance: the pieces [ArenaHud] places round the edge of the screen.
##
## [b]Where a player looks for each thing is the layout, and the genre has settled it:[/b]
## the score, the clock and who is winning at the top centre; who killed whom, with what, at
## the top right; your health bottom left; your magazine and reserve bottom right with the
## weapons you carry stacked up the right edge; your abilities bottom centre with the key
## under each; the keys that matter on the right. A player who has played one of these
## games finds every number here without looking for it.
##
## [b]Each piece draws itself from plain values it is handed[/b] (`show_*`), and knows
## nothing about a player or a match, so a suite can drive one without a game and a render
## tool can put up a frame with chosen numbers. [ArenaHud] reads the game and hands them
## over once a frame.
##
## [b]Readable over a pale map[/b]: every number is bold with a dark outline, and every
## group sits on a dark translucent plate. The first HUD drew thin regular-weight text
## straight over white prototype tiles, and health, ammunition and the key hints all but
## disappeared (`screenshots/dm_box_feel_kill_compat.png` before 2026-10-10).
##
## Art: the weapon silhouettes are rendered from zee's models by
## `tools/build_weapon_icons.sh` (Kenney's CC0 blaster and tool kits); the ability icons are
## Kenney's CC0 game and mobile-control icons (`assets/hud_icons/`). A missing file draws
## the words instead.

const WEAPON_ICON_DIR := "res://assets/weapon_icons"
const HUD_ICON_DIR := "res://assets/hud_icons"

## The plates' fill: near black, see-through.
const PLATE := Color(0.06, 0.07, 0.11, 0.62)
const PLATE_EDGE := Color(1.0, 1.0, 1.0, 0.14)
const GOLD := Color(1.0, 0.8, 0.22)
const TEXT := Color(0.97, 0.98, 1.0)
const DIM := Color(0.82, 0.85, 0.92)
const LOW := Color(1.0, 0.32, 0.28)
## The two sides' colours when the teams give none, and the free-for-all plates.
const BLUE := Color(0.22, 0.5, 0.95)
const RED := Color(0.9, 0.24, 0.32)


## Fonts, outlined text, plates and keycaps, shared by every piece. An inner class so the
## pieces (themselves inner classes) can reach it.
class Ink:
	extends RefCounted

	static var _fonts: Dictionary = {}
	static var _textures: Dictionary = {}

	## The fallback font, emboldened, slanted when [param italic].
	static func font(italic: bool = false) -> Font:
		if not _fonts.has(italic):
			var f := FontVariation.new()
			f.base_font = ThemeDB.fallback_font
			f.variation_embolden = 0.85
			if italic:
				f.variation_transform = Transform2D(Vector2(1.0, 0.0), Vector2(-0.2, 1.0), Vector2.ZERO)
			_fonts[italic] = f
		return _fonts[italic]

	static func width(text: String, size: int) -> float:
		return font().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size).x

	## [param text] with its baseline at [param at], outlined dark.
	static func text(
		canvas: CanvasItem, at: Vector2, words: String, size: int, colour: Color,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, box: float = -1.0, outline: int = 6
	) -> void:
		var f := font()
		if outline > 0:
			canvas.draw_string_outline(f, at, words, align, box, size, outline, Color(0.02, 0.02, 0.05, 0.85 * colour.a))
		canvas.draw_string(f, at, words, align, box, size, colour)

	static func plate(canvas: CanvasItem, rect: Rect2, fill: Color = PLATE, radius: int = 7, edge: Color = PLATE_EDGE, edge_width: int = 1) -> void:
		var box := StyleBoxFlat.new()
		box.bg_color = fill
		box.set_corner_radius_all(radius)
		box.anti_aliasing = true
		if edge.a > 0.0 and edge_width > 0:
			box.border_color = edge
			box.set_border_width_all(edge_width)
		canvas.draw_style_box(box, rect)

	## A key drawn as a key: a light cap with the key's name, its left edge at
	## [param at].x and its centre at [param at].y. Returns its width.
	static func keycap(canvas: CanvasItem, at: Vector2, key: String, size: int = 13, alpha: float = 1.0) -> float:
		var w := maxf(width(key, size) + 12.0, float(size) + 10.0)
		var h := float(size) + 10.0
		var rect := Rect2(at.x, at.y - h * 0.5, w, h)
		plate(canvas, Rect2(rect.position + Vector2(0.0, 2.0), rect.size), Color(0.0, 0.0, 0.0, 0.45 * alpha), 5, Color(0, 0, 0, 0), 0)
		plate(canvas, rect, Color(0.93, 0.94, 0.97, 0.95 * alpha), 5, Color(1, 1, 1, 0.0), 0)
		canvas.draw_string(font(), Vector2(rect.position.x, rect.end.y - 6.0), key, HORIZONTAL_ALIGNMENT_CENTER, w, size, Color(0.08, 0.09, 0.14, alpha))
		return w

	static func keycap_width(key: String, size: int = 13) -> float:
		return maxf(width(key, size) + 12.0, float(size) + 10.0)

	## A texture under `res://` by path, through the pack rebase; null when missing.
	static func texture(path: String) -> Texture2D:
		if not _textures.has(path):
			var at := ArenaPaths.rebase(path)
			_textures[path] = load(at) as Texture2D if ResourceLoader.exists(at) else null
		return _textures[path]

	static func weapon_icon(id: StringName) -> Texture2D:
		return texture("%s/%s.png" % [WEAPON_ICON_DIR, String(id)]) if id != &"" else null

	## [param icon] scaled to [param height], its left edge at [param at].x and centred on
	## [param at].y. Returns the width drawn.
	static func icon(canvas: CanvasItem, tex: Texture2D, at: Vector2, height: float, tint: Color = Color.WHITE, max_width: float = 9999.0) -> float:
		if tex == null:
			return 0.0
		var s := tex.get_size()
		var w := minf(s.x * height / maxf(s.y, 1.0), max_width)
		var h := w * s.y / maxf(s.x, 1.0)
		canvas.draw_texture_rect(tex, Rect2(at.x, at.y - h * 0.5, w, h), false, tint)
		return w


## Top centre: the two scores either side of the clock, and under them what wins and the
## mode. In a team mode the plates are the sides; in a free-for-all the left one is you and
## the right one whoever is ahead of you (or behind, when you lead).
class ScoreStrip extends Control:
	const PLATE_W := 132.0
	const CLOCK_W := 112.0
	const H := 46.0
	const GAP := 6.0

	var left_score: int = 0
	var right_score: int = 0
	var left_tag: String = "YOU"
	var right_tag: String = "LEADER"
	var left_colour: Color = BLUE
	var right_colour: Color = RED
	var clock: String = "0:00"
	## "First to 25" and the mode's name, under the plates.
	var target: String = ""
	var mode_name: String = ""
	var clock_low: bool = false

	func show_scores(p_left: int, p_right: int, p_left_tag: String, p_right_tag: String, p_left_colour: Color, p_right_colour: Color) -> void:
		left_score = p_left
		right_score = p_right
		left_tag = p_left_tag
		right_tag = p_right_tag
		left_colour = p_left_colour
		right_colour = p_right_colour
		queue_redraw()

	func show_clock(p_clock: String, p_low: bool, p_target: String, p_mode: String) -> void:
		clock = p_clock
		clock_low = p_low
		target = p_target
		mode_name = p_mode
		queue_redraw()

	func _draw() -> void:
		var mid := size.x * 0.5
		var clock_rect := Rect2(mid - CLOCK_W * 0.5, 0.0, CLOCK_W, H)
		var left := Rect2(clock_rect.position.x - GAP - PLATE_W, 0.0, PLATE_W, H)
		var right := Rect2(clock_rect.end.x + GAP, 0.0, PLATE_W, H)
		_side(left, left_colour, left_tag, left_score)
		_side(right, right_colour, right_tag, right_score)
		Ink.plate(self, clock_rect, Color(0.07, 0.08, 0.13, 0.82), 8, Color(1, 1, 1, 0.22), 1)
		Ink.text(self, Vector2(clock_rect.position.x, clock_rect.end.y - 12.0), clock, 26,
			LOW if clock_low else TEXT, HORIZONTAL_ALIGNMENT_CENTER, CLOCK_W, 5)
		var under := _under()
		if under != "":
			Ink.text(self, Vector2(0.0, H + 22.0), under, 15, Color(TEXT, 0.92), HORIZONTAL_ALIGNMENT_CENTER, size.x, 5)

	func _under() -> String:
		return target if mode_name == "" else ("%s   ·   %s" % [target, mode_name] if target != "" else mode_name)

	## What it draws, in its own space: the plates and the clock, and the line under them.
	## `ArenaHud.footprints` reads every piece's, for the layout check.
	func footprint() -> Rect2:
		var w := maxf(PLATE_W * 2.0 + GAP * 2.0 + CLOCK_W, Ink.width(_under(), 15))
		return Rect2(size.x * 0.5 - w * 0.5, 0.0, w, H + 28.0)

	func _side(rect: Rect2, colour: Color, tag: String, score: int) -> void:
		Ink.plate(self, rect, Color(colour.darkened(0.15), 0.9), 8, Color(1, 1, 1, 0.35), 1)
		# A lighter top half: the plates read as buttons, not as flat paint.
		Ink.plate(self, Rect2(rect.position + Vector2(2.0, 2.0), Vector2(rect.size.x - 4.0, rect.size.y * 0.45)), Color(1, 1, 1, 0.12), 6, Color(0, 0, 0, 0), 0)
		Ink.text(self, Vector2(rect.position.x, rect.position.y + 13.0), tag, 11, Color(1, 1, 1, 0.9), HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 3)
		Ink.text(self, Vector2(rect.position.x, rect.end.y - 7.0), str(score), 26, TEXT, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 5)


## Under the scores: every player ranked, a portrait each with their rank over it and their
## kills under it. Your own ring is gold; in a team mode the others are their side's colour.
class Portraits extends Control:
	const MAX_SHOWN := 10
	const SPACING := 50.0
	const RADIUS := 19.0

	## `{texture, name, rank, kills, ring, me}` per player, best first.
	var entries: Array[Dictionary] = []

	func show_players(p_entries: Array[Dictionary]) -> void:
		entries = p_entries.slice(0, MAX_SHOWN)
		queue_redraw()

	## The rank over the first face to the kills under the last.
	func footprint() -> Rect2:
		var count := entries.size()
		if count == 0:
			return Rect2()
		var first := size.x * 0.5 - SPACING * float(count - 1) * 0.5
		return Rect2(first - 30.0, 0.0, SPACING * float(count - 1) + 60.0, 14.0 + RADIUS * 2.0 + 21.0)

	func _draw() -> void:
		var count := entries.size()
		if count == 0:
			return
		var first := size.x * 0.5 - SPACING * float(count - 1) * 0.5
		for i in range(count):
			var e: Dictionary = entries[i]
			var c := Vector2(first + SPACING * float(i), 14.0 + RADIUS)
			var me := bool(e.get("me", false))
			var ring: Color = GOLD if me else e.get("ring", Color(1, 1, 1, 0.85))
			Ink.text(self, Vector2(c.x - 30.0, 11.0), "#%d" % int(e.get("rank", i + 1)), 11,
				GOLD if me else Color(TEXT, 0.95), HORIZONTAL_ALIGNMENT_CENTER, 60.0, 3)
			draw_circle(c + Vector2(0.0, 2.0), RADIUS + 3.0, Color(0, 0, 0, 0.35))
			draw_circle(c, RADIUS + 2.5, ring)
			var back: Color = e.get("colour", Color(0.3, 0.34, 0.45))
			draw_circle(c, RADIUS, back.darkened(0.25))
			var tex: Texture2D = e.get("texture", null)
			if tex != null:
				var side := RADIUS * 2.0
				draw_texture_rect(tex, Rect2(c - Vector2(side, side) * 0.5, Vector2(side, side)), false)
			else:
				var initials := str(e.get("name", "?")).substr(0, 2).to_upper()
				Ink.text(self, c + Vector2(-RADIUS, 6.0), initials, 15, TEXT, HORIZONTAL_ALIGNMENT_CENTER, RADIUS * 2.0, 4)
			Ink.text(self, Vector2(c.x - 30.0, c.y + RADIUS + 17.0), str(int(e.get("kills", 0))), 14,
				GOLD if me else TEXT, HORIZONTAL_ALIGNMENT_CENTER, 60.0, 4)


## Top right: who killed whom, with the weapon's silhouette between the names, on a plate
## per line. A line you are in has a gold edge. Newest at the top; each fades after
## [member lifetime_sec].
class KillFeed extends Control:
	# 28 + 3, not 30 + 4: three rows from a 16 px inset end at 106, above the client shell's
	# column at 110 (`ArenaHud.feed_lines_clear`); at 34 a row the third ran 4 px under it.
	const ROW_H := 28.0
	const ROW_GAP := 3.0
	const ICON_H := 20.0
	const NAME_SIZE := 15

	var max_lines: int = 5
	var lifetime_sec: float = 6.0
	var entries: Array[Dictionary] = []

	func add_kill(
		killer: String, killer_colour: Color, weapon_id: StringName, weapon_text: String,
		victim: String, victim_colour: Color, headshot: bool = false, involved: bool = false
	) -> void:
		entries.push_front({
			"killer": killer, "killer_colour": killer_colour, "weapon": weapon_id,
			"weapon_text": weapon_text, "victim": victim, "victim_colour": victim_colour,
			"headshot": headshot, "involved": involved, "age": 0.0,
		})
		while entries.size() > max_lines:
			entries.pop_back()
		queue_redraw()

	func line_count() -> int:
		return entries.size()

	func clear() -> void:
		entries.clear()
		queue_redraw()

	func advance(delta: float) -> void:
		if lifetime_sec <= 0.0:
			return
		for i in range(entries.size() - 1, -1, -1):
			entries[i]["age"] = float(entries[i]["age"]) + delta
			if float(entries[i]["age"]) >= lifetime_sec:
				entries.remove_at(i)
		queue_redraw()

	func _draw() -> void:
		var y := 0.0
		for e in entries:
			var fade := 1.0 if lifetime_sec <= 0.0 else clampf((lifetime_sec - float(e["age"])) / 0.6, 0.0, 1.0)
			_row(e, y, fade)
			y += ROW_H + ROW_GAP

	## Names longer than this are cut with an ellipsis, so a line never reaches the portraits
	## at the top centre on a 1280-wide screen.
	const NAME_MAX := 14

	static func _short(name: String) -> String:
		return name if name.length() <= NAME_MAX else name.substr(0, NAME_MAX - 1) + "…"

	## Every row's plate, right-aligned, newest at the top.
	func footprint() -> Rect2:
		var out := Rect2()
		var y := 0.0
		for e in entries:
			var w := _inner(e) + PAD * 2.0
			var row := Rect2(size.x - w, y, w, ROW_H)
			out = row if not out.has_area() else out.merge(row)
			y += ROW_H + ROW_GAP
		return out

	const PAD := 10.0

	## A row's width inside its padding: killer, weapon, headshot mark, victim.
	static func _inner(e: Dictionary) -> float:
		var tex := Ink.weapon_icon(e["weapon"])
		var killer := _short(str(e["killer"]))
		var killer_w := Ink.width(killer, NAME_SIZE) if killer != "" else 0.0
		var victim_w := Ink.width(_short(str(e["victim"])), NAME_SIZE)
		var icon_w := 0.0
		if tex != null:
			icon_w = minf(tex.get_size().x * ICON_H / maxf(tex.get_size().y, 1.0), 64.0)
		else:
			icon_w = Ink.width("[%s]" % str(e["weapon_text"]), 13)
		var head_w := 22.0 if bool(e["headshot"]) else 0.0
		return killer_w + (10.0 if killer != "" else 0.0) + icon_w + head_w + 10.0 + victim_w

	func _row(e: Dictionary, y: float, fade: float) -> void:
		var tex := Ink.weapon_icon(e["weapon"])
		var killer := _short(str(e["killer"]))
		var victim := _short(str(e["victim"]))
		var killer_w := Ink.width(killer, NAME_SIZE) if killer != "" else 0.0
		var head := Ink.texture("res://assets/medals/target.png") if bool(e["headshot"]) else null
		var pad := PAD
		var inner := _inner(e)
		var rect := Rect2(size.x - inner - pad * 2.0, y, inner + pad * 2.0, ROW_H)
		var involved := bool(e["involved"])
		Ink.plate(self, rect, Color(PLATE, PLATE.a * fade), 6,
			Color(GOLD, 0.95 * fade) if involved else Color(PLATE_EDGE, PLATE_EDGE.a * fade), 2 if involved else 1)
		var x := rect.position.x + pad
		var base := y + ROW_H * 0.5 + NAME_SIZE * 0.36
		if killer != "":
			Ink.text(self, Vector2(x, base), killer, NAME_SIZE, Color(e["killer_colour"], fade), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 4)
			x += killer_w + 10.0
		if tex != null:
			x += Ink.icon(self, tex, Vector2(x, y + ROW_H * 0.5), ICON_H, Color(1, 1, 1, fade), 64.0)
		else:
			Ink.text(self, Vector2(x, base), "[%s]" % str(e["weapon_text"]), 13, Color(DIM, fade), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 3)
			x += Ink.width("[%s]" % str(e["weapon_text"]), 13)
		if head != null:
			draw_texture_rect(head, Rect2(x + 4.0, y + ROW_H * 0.5 - 8.0, 16.0, 16.0), false, Color(1.0, 0.45, 0.3, fade))
			x += 22.0
		x += 10.0
		Ink.text(self, Vector2(x, base), victim, NAME_SIZE, Color(e["victim_colour"], fade), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 4)


## Bottom left, the words over the bars: health in big numbers at the bar's end, armour
## smaller beside its own thin bar when there is any.
class Vitals extends Control:
	var health: float = 100.0
	var max_health: float = 100.0
	var armour: float = 0.0
	## Where the bars end, in this control's space: the numbers sit just past it.
	var bar_end: float = 260.0

	func show_vitals(p_health: float, p_max: float, p_armour: float) -> void:
		if not is_equal_approx(p_health, health) or not is_equal_approx(p_armour, armour) or not is_equal_approx(p_max, max_health):
			health = p_health
			max_health = p_max
			armour = p_armour
			queue_redraw()

	## The plate under the bars and the number.
	func footprint() -> Rect2:
		return Rect2(0.0, 0.0, bar_end + 22.0 + Ink.width(str(int(ceilf(health))), 30), 72.0 if armour > 0.0 else 56.0)

	func _draw() -> void:
		var low := max_health > 0.0 and health / max_health <= 0.25
		# The plate under the bars and the number: white text on a white floor is an
		# outline and nothing else (rendered in the client over dm_atrium's floor).
		var number_w := Ink.width(str(int(ceilf(health))), 30)
		Ink.plate(self, Rect2(0.0, 0.0, bar_end + 22.0 + number_w, 72.0 if armour > 0.0 else 56.0), PLATE, 9)
		# A cross, drawn: the genre's health mark, and no art to go missing.
		var c := Vector2(10.0, 22.0)
		draw_rect(Rect2(c - Vector2(3.0, 9.0), Vector2(6.0, 18.0)), Color(0, 0, 0, 0.5))
		draw_rect(Rect2(c - Vector2(9.0, 3.0), Vector2(18.0, 6.0)), Color(0, 0, 0, 0.5))
		var mark := LOW if low else Color(0.45, 0.92, 0.55)
		draw_rect(Rect2(c - Vector2(2.0, 8.0), Vector2(4.0, 16.0)), mark)
		draw_rect(Rect2(c - Vector2(8.0, 2.0), Vector2(16.0, 4.0)), mark)
		Ink.text(self, Vector2(bar_end + 10.0, 40.0), str(int(ceilf(health))), 30, LOW if low else TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 6)
		if armour > 0.0:
			Ink.text(self, Vector2(bar_end + 10.0, 62.0), "%d" % int(ceilf(armour)), 16, Color(0.6, 0.78, 1.0), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 4)


## Bottom right: what is in hand, and `magazine | reserve` in big numbers under its name.
## A weapon with no magazine shows what is left in its pool; a melee weapon its name alone.
class AmmoCounter extends Control:
	var weapon_name: String = ""
	var magazine: int = -1
	var reserve: int = -1
	var low: bool = false

	func show_ammo(p_name: String, p_magazine: int, p_reserve: int, p_low: bool) -> void:
		if p_name != weapon_name or p_magazine != magazine or p_reserve != reserve or p_low != low:
			weapon_name = p_name
			magazine = p_magazine
			reserve = p_reserve
			low = p_low
			queue_redraw()

	func _plate() -> Rect2:
		var name_w := Ink.width(weapon_name.to_upper(), 15)
		var count_w := 0.0
		if magazine >= 0:
			count_w = Ink.width(str(magazine), 36) + 10.0 + (Ink.width("| %d" % reserve, 22) if reserve >= 0 else 0.0)
		var plate_w := maxf(name_w, count_w) + 28.0
		return Rect2(size.x - plate_w + 14.0, -4.0, plate_w, 70.0 if magazine >= 0 else 32.0)

	## The plate under the name and the count; nothing with nothing in hand.
	func footprint() -> Rect2:
		return _plate() if weapon_name != "" else Rect2()

	func _draw() -> void:
		if weapon_name == "":
			return
		var right := size.x
		Ink.plate(self, _plate(), PLATE, 9)
		Ink.text(self, Vector2(0.0, 18.0), weapon_name.to_upper(), 15, Color(TEXT, 0.95), HORIZONTAL_ALIGNMENT_RIGHT, right, 4)
		if magazine < 0:
			return
		var mag := str(magazine)
		var rest := "| %d" % reserve if reserve >= 0 else ""
		var rest_w := Ink.width(rest, 22) if rest != "" else 0.0
		if rest != "":
			Ink.text(self, Vector2(right - rest_w, 56.0), rest, 22, DIM, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 5)
		var mag_w := Ink.width(mag, 36)
		Ink.text(self, Vector2(right - rest_w - 10.0 - mag_w, 56.0), mag, 36, LOW if low else TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 6)


## The right edge: one silhouette per weapon carried, with the number that selects it.
## The one in hand is bright and larger; the rest wait dimmed.
class WeaponSlots extends Control:
	const ROW_H := 40.0

	## `{slot, id, name, key}` per carried slot, in slot order; `key` is the key it is bound
	## to (the slot's number when absent).
	var rows: Array[Dictionary] = []
	var current: int = 0

	func show_slots(p_rows: Array[Dictionary], p_current: int) -> void:
		if p_current != current or p_rows.size() != rows.size() or str(p_rows) != str(rows):
			rows = p_rows
			current = p_current
			queue_redraw()

	## Every slot's plate, from the bottom up.
	func footprint() -> Rect2:
		if rows.is_empty():
			return Rect2()
		var left := size.x
		for r in rows:
			left = minf(left, size.x - Ink.keycap_width(str(r.get("key", r["slot"])), 12) - 112.0)
		var top := size.y - float(rows.size()) * ROW_H + ROW_H * 0.5 - 17.0
		return Rect2(left, top, size.x + 4.0 - left, float(rows.size() - 1) * ROW_H + 34.0)

	func _draw() -> void:
		# From the bottom up, so the carried guns sit on the ammunition counter however few
		# there are, and the top of the box is the one that stays clear of the shell's column.
		var y := size.y - float(rows.size()) * ROW_H + ROW_H * 0.5
		for r in rows:
			var on := int(r["slot"]) == current
			var alpha := 1.0 if on else 0.72
			var key := str(r.get("key", r["slot"]))
			var cap_w := Ink.keycap_width(key, 12)
			var cap_x := size.x - cap_w
			# A plate per weapon: a white silhouette on a pale wall is no silhouette at all.
			var plate_x := cap_x - 112.0
			Ink.plate(self, Rect2(plate_x, y - 17.0, size.x - plate_x + 4.0, 34.0),
				Color(PLATE, 0.8 if on else 0.6), 7, Color(GOLD, 0.85) if on else Color(PLATE_EDGE, 0.1), 2 if on else 1)
			var _w := Ink.keycap(self, Vector2(cap_x, y), key, 12, alpha)
			var tex := Ink.weapon_icon(r["id"])
			var h := 24.0 if on else 18.0
			if tex != null:
				var s := tex.get_size()
				var w := minf(s.x * h / maxf(s.y, 1.0), 90.0)
				var at := Vector2(cap_x - 10.0 - w, y)
				# A shadow first, so a white gun reads on a white wall.
				var _s := Ink.icon(self, tex, at + Vector2(1.5, 1.5), h, Color(0, 0, 0, 0.55 * alpha), 90.0)
				var _d := Ink.icon(self, tex, at, h, Color(1, 1, 1, alpha), 90.0)
			else:
				Ink.text(self, Vector2(0.0, y + 5.0), str(r["name"]), 13, Color(TEXT, alpha), HORIZONTAL_ALIGNMENT_RIGHT, cap_x - 10.0, 4)
			y += ROW_H


## Bottom centre: one button per movement ability, its key under it. A charging one is
## darkened from the top by what is left and says the seconds; a ready one is bright; one
## in use (a slide, a wall run) has a gold edge. The wall jump shows its jumps left in the
## air as pips.
class AbilityBar extends Control:
	const SIDE := 56.0
	const GAP := 14.0

	## `{id, label, icon, key, left, total, active, pips, pips_max}`, left to right.
	var buttons: Array[Dictionary] = []

	func show_buttons(p_buttons: Array[Dictionary]) -> void:
		buttons = p_buttons
		queue_redraw()

	## One button as a line of words: "E  LAUNCH" when ready, "E  5.5" while it charges.
	## What a suite reads.
	func line(id: StringName) -> String:
		for b in buttons:
			if b["id"] == id:
				var left := float(b["left"])
				return "%s  %s" % [b["key"], str(b["label"]).to_upper() if left <= 0.0 else "%.1f" % left]
		return ""

	func has(id: StringName) -> bool:
		return line(id) != ""

	## The buttons, the wall jump's pips over them and the keys under them.
	func footprint() -> Rect2:
		var count := buttons.size()
		if count == 0:
			return Rect2()
		var total_w := SIDE * float(count) + GAP * float(count - 1)
		return Rect2(size.x * 0.5 - total_w * 0.5, -14.0, total_w, 14.0 + SIDE + 2.0 + 22.0 + 2.0)

	func _draw() -> void:
		var count := buttons.size()
		if count == 0:
			return
		var total_w := SIDE * float(count) + GAP * float(count - 1)
		var x := size.x * 0.5 - total_w * 0.5
		for b in buttons:
			_button(Rect2(x, 0.0, SIDE, SIDE), b)
			x += SIDE + GAP

	func _button(rect: Rect2, b: Dictionary) -> void:
		var left := float(b["left"])
		var total := maxf(float(b["total"]), 0.001)
		var ready := left <= 0.0
		var active := bool(b["active"])
		Ink.plate(self, Rect2(rect.position + Vector2(0.0, 3.0), rect.size), Color(0, 0, 0, 0.4), 10, Color(0, 0, 0, 0), 0)
		var fill := Color(0.2, 0.55, 0.95, 0.88) if ready else Color(0.16, 0.2, 0.3, 0.85)
		Ink.plate(self, rect, fill, 10, GOLD if active else Color(1, 1, 1, 0.55 if ready else 0.25), 3 if active else 2)
		Ink.plate(self, Rect2(rect.position + Vector2(3.0, 3.0), Vector2(rect.size.x - 6.0, rect.size.y * 0.42)), Color(1, 1, 1, 0.14 if ready else 0.05), 8, Color(0, 0, 0, 0), 0)
		var tex: Texture2D = b.get("icon", null)
		if tex != null:
			var side := SIDE * 0.62
			draw_texture_rect(tex, Rect2(rect.get_center() - Vector2(side, side) * 0.5, Vector2(side, side)), false, Color(1, 1, 1, 1.0 if ready else 0.45))
		else:
			Ink.text(self, Vector2(rect.position.x, rect.get_center().y + 5.0), str(b["label"]).substr(0, 5).to_upper(), 12, TEXT, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 3)
		if not ready:
			var cover := rect.size.y * clampf(left / total, 0.0, 1.0)
			Ink.plate(self, Rect2(rect.position, Vector2(rect.size.x, cover)), Color(0.0, 0.0, 0.02, 0.5), 10, Color(0, 0, 0, 0), 0)
			Ink.text(self, Vector2(rect.position.x, rect.get_center().y + 8.0), "%.1f" % left if left < 10.0 else "%d" % int(left), 20, TEXT, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 5)
		var pips_max := int(b.get("pips_max", 0))
		if pips_max > 0:
			var pips := int(b.get("pips", 0))
			var px := rect.get_center().x - 8.0 * float(pips_max - 1)
			for i in range(pips_max):
				var c := Vector2(px + 16.0 * float(i), rect.position.y - 9.0)
				draw_circle(c, 5.0, Color(0, 0, 0, 0.55))
				draw_circle(c, 3.8, GOLD if i < pips else Color(1, 1, 1, 0.25))
		var key := str(b["key"])
		var cap_w := Ink.keycap_width(key, 12)
		var _w := Ink.keycap(self, Vector2(rect.get_center().x - cap_w * 0.5, rect.end.y + 2.0), key, 12)


## The right edge: the keys worth knowing, each a word and its key, right-aligned.
class KeyHints extends Control:
	const ROW_H := 28.0

	## `[words, key]` per row, top to bottom.
	var rows: Array = []

	func show_hints(p_rows: Array) -> void:
		if str(p_rows) != str(rows):
			rows = p_rows
			queue_redraw()

	## Each row's key and words, from the left edge.
	func footprint() -> Rect2:
		var w := 0.0
		for r in rows:
			w = maxf(w, Ink.keycap_width(str(r[1]), 12) + 8.0 + Ink.width(str(r[0]), 16))
		return Rect2(0.0, 0.0, w, float(rows.size()) * ROW_H) if not rows.is_empty() else Rect2()

	func _draw() -> void:
		# Key first, then the words, from the left edge: the hints are on the left of the
		# frame (`ArenaHud.build` says why).
		var y := ROW_H * 0.5
		for r in rows:
			var key := str(r[1])
			var cap_w := Ink.keycap(self, Vector2(0.0, y), key, 12)
			Ink.text(self, Vector2(cap_w + 8.0, y + 6.0), str(r[0]), 16, TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 5)
			y += ROW_H


## A prompt for what can be done right now: "Cancel slide [C]", "Reload [R]". Centred on
## its own position.
class Prompt extends Control:
	var words: String = ""
	var key: String = ""

	func show_prompt(p_words: String, p_key: String) -> void:
		if p_words != words or p_key != key:
			words = p_words
			key = p_key
			queue_redraw()
		visible = words != ""

	## What a suite reads.
	var text: String:
		get:
			return "%s  %s" % [words, key] if words != "" else ""

	## The plate under the words and the key.
	func footprint() -> Rect2:
		if words == "":
			return Rect2()
		var total := Ink.width(words, 17) + 10.0 + Ink.keycap_width(key, 13)
		return Rect2(size.x * 0.5 - total * 0.5 - 12.0, 0.0, total + 24.0, 34.0)

	func _draw() -> void:
		if words == "":
			return
		var cap_w := Ink.keycap_width(key, 13)
		var words_w := Ink.width(words, 17)
		var total := words_w + 10.0 + cap_w
		var x := size.x * 0.5 - total * 0.5
		Ink.plate(self, Rect2(x - 12.0, 0.0, total + 24.0, 34.0), PLATE, 8)
		Ink.text(self, Vector2(x, 23.0), words, 17, TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 4)
		var _w := Ink.keycap(self, Vector2(x + words_w + 10.0, 17.0), key, 13)


## A portrait per player: their avatar's head, rendered once into a small viewport of its
## own and drawn in the ranked row. Re-rendered only when what they wear changes.
##
## [b]Rendered, not drawn[/b], so the face in the row is the face on the body: a player who
## changes their avatar on the site sees it here too. Each viewport renders once
## (`UPDATE_ONCE`), so ten of them cost ten small draws when somebody joins, not ten a
## frame. Nothing is built with no display (every suite): the row draws initials instead.
class PortraitCache extends Node:
	const ArenaAvatars := preload("arena_avatars.gd")
	const SIDE := 96

	## player id -> [SubViewport, digest]
	var _made: Dictionary = {}

	## The portrait for [param id] wearing [param avatar], or null with no display.
	func portrait(id: int, avatar: DotAvatar) -> Texture2D:
		if DisplayServer.get_name() == "headless" or avatar == null:
			return null
		var digest := avatar.digest()
		var have: Array = _made.get(id, [])
		if not have.is_empty() and str(have[1]) == digest and is_instance_valid(have[0]):
			return (have[0] as SubViewport).get_texture()
		if not have.is_empty() and is_instance_valid(have[0]):
			(have[0] as Node).queue_free()
		var view := _render(avatar)
		_made[id] = [view, digest]
		return view.get_texture()

	## Forgets players who are gone.
	func keep_only(ids: Array) -> void:
		for id in _made.keys():
			if not ids.has(id):
				var have: Array = _made[id]
				if is_instance_valid(have[0]):
					(have[0] as Node).queue_free()
				_made.erase(id)

	func _render(avatar: DotAvatar) -> SubViewport:
		var view := SubViewport.new()
		view.size = Vector2i(SIDE, SIDE)
		view.transparent_bg = true
		view.own_world_3d = true
		view.msaa_3d = Viewport.MSAA_4X
		view.render_target_update_mode = SubViewport.UPDATE_ONCE
		add_child(view)

		var env := WorldEnvironment.new()
		env.environment = Environment.new()
		env.environment.background_mode = Environment.BG_CLEAR_COLOR
		env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.environment.ambient_light_color = Color(0.85, 0.87, 0.95)
		env.environment.ambient_light_energy = 0.7
		view.add_child(env)

		var sun := DirectionalLight3D.new()
		# Shining onto the face, which is on the -Z side.
		sun.rotation_degrees = Vector3(-30.0, 160.0, 0.0)
		sun.light_energy = 1.1
		view.add_child(sun)

		var rig := ArenaAvatars.make_rig()
		view.add_child(rig)
		var _built := ArenaAvatars.apply(avatar, rig, ArenaAvatars.schema(), ArenaAvatars.catalogue())

		# The figure faces -Z, so the camera is on that side, a little to one side so the
		# head has depth. `look_at_from_position`, because this may run before the viewport
		# is in the tree.
		var camera := Camera3D.new()
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		camera.size = FRAME_SIZE
		view.add_child(camera)
		camera.look_at_from_position(FACE + Vector3(-0.8, 0.15, -3.0), FACE)
		camera.current = true
		return view

	## Where the head is in the rig (measured from a render: the top at 1.72 m, the eyes at
	## about 1.58), and how much of it the frame holds.
	const FACE := Vector3(0.0, 1.49, 0.0)
	const FRAME_SIZE := 0.66
