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
## [b]Only arena's own pieces are here[/b]: the ranked portraits, the kill feed with its
## weapon silhouettes, the carried weapons, the ability bar. Health, ammunition, the scores
## and clock, the key prompt and hints, the hit marker and the damage numbers were drawn here
## too and moved to dot-ui once other games needed them (`DotVitals`, `DotAmmoCounter`,
## `DotScoreStrip`, `DotKeyPrompt`, `DotKeyHints`, `DotHitMarker`, `DotDamageNumbers`; dot-ui
## `docs/hud.md`, "The glance pieces"); [ArenaHud] places them beside these. The colours
## below are the same as `DotHudPiece.DEFAULTS`, so the two sets read as one HUD.
##
## Art: the weapon silhouettes are rendered from zee's models by
## `tools/build_weapon_icons.sh` (Kenney's CC0 blaster and tool kits); the ability icons are
## Kenney's CC0 game and mobile-control icons (`assets/hud_icons/`). A missing file draws
## the words instead.

const WEAPON_ICON_DIR := "res://assets/weapon_icons"
const HUD_ICON_DIR := "res://assets/hud_icons"

## Arena's accent: your own ring, row and slot. The rest of every piece's colours are the
## theme's ([method Ink.c]), so the menu's theme restyles these pieces with dot-ui's.
const GOLD := Color(1.0, 0.8, 0.22)
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

	## A HUD colour by dot-ui's name for it (`plate`, `plate_edge`, `text`, `dim`, `highlight`,
	## `ink`, `keycap`, ...): the theme's on [constant DotHudPiece.THEME_TYPE] as
	## [param canvas] sees it (the menu sets one on the HUD, see `ArenaClient`), else dot-ui's
	## default. Read when drawing, so a theme change is followed on the next frame.
	static func c(canvas: CanvasItem, key: StringName) -> Color:
		var control := canvas as Control
		if control != null and control.has_theme_color(key, &"DotHudPiece"):
			return control.get_theme_color(key, &"DotHudPiece")
		# `keycap_edge` is dot-ui 6's; on an older shell's dot-ui it is not in DEFAULTS.
		return DotHudPiece.DEFAULTS.get(key, Color(1.0, 1.0, 1.0, 0.3) if key == &"keycap_edge" else Color.WHITE)

	## How bright the theme's HUD is, 0 to 1: dot-ui's `team_fill` (38 in the dark default,
	## 100 in the bright "Arcade" theme). What a piece with its own saturated colour (the
	## ability buttons, a medal's ring) blends its dark and its bright look by.
	static func bright(canvas: CanvasItem) -> float:
		var control := canvas as Control
		var n := 38
		if control != null and control.has_theme_constant(&"team_fill", &"DotHudPiece"):
			n = control.get_theme_constant(&"team_fill", &"DotHudPiece")
		return clampf((float(n) - 38.0) / 62.0, 0.0, 1.0)

	static func width(text: String, size: int) -> float:
		return font().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size).x

	## [param text] with its baseline at [param at], outlined dark.
	static func text(
		canvas: CanvasItem, at: Vector2, words: String, size: int, colour: Color,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, box: float = -1.0, outline: int = 6
	) -> void:
		var f := font()
		if outline > 0:
			var ink := c(canvas, &"ink")
			canvas.draw_string_outline(f, at, words, align, box, size, outline, Color(ink, ink.a * colour.a))
		canvas.draw_string(f, at, words, align, box, size, colour)

	## A rounded plate; [param fill] and [param edge] default (alpha below 0) to the theme's
	## `plate` and `plate_edge`.
	static func plate(canvas: CanvasItem, rect: Rect2, fill: Color = Color(0, 0, 0, -1), radius: int = 7, edge: Color = Color(0, 0, 0, -1), edge_width: int = 1) -> void:
		if fill.a < 0.0:
			fill = c(canvas, &"plate")
		if edge.a < 0.0:
			edge = c(canvas, &"plate_edge")
		var box := StyleBoxFlat.new()
		box.bg_color = fill
		box.set_corner_radius_all(radius)
		box.anti_aliasing = true
		if edge.a > 0.0 and edge_width > 0:
			box.border_color = edge
			box.set_border_width_all(edge_width)
		canvas.draw_style_box(box, rect)

	## A key drawn as a key: a cap in the theme's `keycap` with the key's name, its left edge at
	## [param at].x and its centre at [param at].y. Returns its width.
	static func keycap(canvas: CanvasItem, at: Vector2, key: String, size: int = 13, alpha: float = 1.0) -> float:
		var w := maxf(width(key, size) + 12.0, float(size) + 10.0)
		var h := float(size) + 10.0
		var rect := Rect2(at.x, at.y - h * 0.5, w, h)
		plate(canvas, Rect2(rect.position + Vector2(0.0, 2.0), rect.size), Color(0.0, 0.0, 0.0, 0.45 * alpha), 5, Color(0, 0, 0, 0), 0)
		var cap := c(canvas, &"keycap")
		var edge := c(canvas, &"keycap_edge")
		plate(canvas, rect, Color(cap, cap.a * alpha), 5, Color(edge, edge.a * alpha), 1 if edge.a > 0.0 else 0)
		canvas.draw_string(font(), Vector2(rect.position.x, rect.end.y - 6.0), key, HORIZONTAL_ALIGNMENT_CENTER, w, size, Color(c(canvas, &"keycap_text"), alpha))
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
			var ring: Color = Ink.c(self, &"highlight") if me else e.get("ring", Color(1, 1, 1, 0.85))
			Ink.text(self, Vector2(c.x - 30.0, 11.0), "#%d" % int(e.get("rank", i + 1)), 11,
				Ink.c(self, &"highlight") if me else Color(Ink.c(self, &"text"), 0.95), HORIZONTAL_ALIGNMENT_CENTER, 60.0, 3)
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
				Ink.text(self, c + Vector2(-RADIUS, 6.0), initials, 15, Ink.c(self, &"text"), HORIZONTAL_ALIGNMENT_CENTER, RADIUS * 2.0, 4)
			Ink.text(self, Vector2(c.x - 30.0, c.y + RADIUS + 17.0), str(int(e.get("kills", 0))), 14,
				Ink.c(self, &"highlight") if me else Ink.c(self, &"text"), HORIZONTAL_ALIGNMENT_CENTER, 60.0, 4)


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
		Ink.plate(self, rect, Color(Ink.c(self, &"plate"), Ink.c(self, &"plate").a * fade), 6,
			Color(Ink.c(self, &"highlight"), 0.95 * fade) if involved else Color(Ink.c(self, &"plate_edge"), Ink.c(self, &"plate_edge").a * fade), 2 if involved else 1)
		var x := rect.position.x + pad
		var base := y + ROW_H * 0.5 + NAME_SIZE * 0.36
		if killer != "":
			Ink.text(self, Vector2(x, base), killer, NAME_SIZE, Color(e["killer_colour"], fade), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 4)
			x += killer_w + 10.0
		if tex != null:
			x += Ink.icon(self, tex, Vector2(x, y + ROW_H * 0.5), ICON_H, Color(1, 1, 1, fade), 64.0)
		else:
			Ink.text(self, Vector2(x, base), "[%s]" % str(e["weapon_text"]), 13, Color(Ink.c(self, &"dim"), fade), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 3)
			x += Ink.width("[%s]" % str(e["weapon_text"]), 13)
		if head != null:
			draw_texture_rect(head, Rect2(x + 4.0, y + ROW_H * 0.5 - 8.0, 16.0, 16.0), false, Color(1.0, 0.45, 0.3, fade))
			x += 22.0
		x += 10.0
		Ink.text(self, Vector2(x, base), victim, NAME_SIZE, Color(e["victim_colour"], fade), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 4)


## The right edge: one silhouette per weapon carried, with the number that selects it.
## The one in hand is bright and larger; the rest wait dimmed.
class WeaponSlots extends Control:
	const ROW_H := 40.0
	## The tightest pitch a row is drawn at under a ballot: a 24 px plate, which the 22 px
	## keycap and the 24 px current-weapon icon still fit in.
	const MIN_ROW_H := 30.0
	## Between a row's plate and the next one, at every pitch.
	const PLATE_GAP := 6.0
	## Between the top plate and whatever covers the box above it.
	const COVER_GAP := 6.0

	## `{slot, id, name, key}` per carried slot, in slot order; `key` is the key it is bound
	## to (the slot's number when absent).
	var rows: Array[Dictionary] = []
	var current: int = 0

	## [b]Where something on top of this box ends[/b], in this box's own coordinates: the
	## client shell's ballot down the right edge, which a seven-row map ballot carries over
	## the top slots at 1280x720. -INF while nothing covers it. Written by
	## [method ArenaHud.make_room] every frame; the rows tighten from [constant ROW_H] towards
	## [constant MIN_ROW_H] to stay under it, and past that only the rows around the current
	## one are drawn, which is the one a player is looking for.
	var cover_bottom: float = -INF

	func show_slots(p_rows: Array[Dictionary], p_current: int) -> void:
		if p_current != current or p_rows.size() != rows.size() or str(p_rows) != str(rows):
			rows = p_rows
			current = p_current
			queue_redraw()

	## Moves the top of the room the rows have; a redraw only on a change.
	func set_cover_bottom(y: float) -> void:
		if not is_equal_approx(y, cover_bottom) and not (is_inf(y) and is_inf(cover_bottom)):
			cover_bottom = y
			queue_redraw()

	## `{rows, pitch}`: the rows drawn, bottom-most last, and the pitch they are drawn at. All
	## of them at [constant ROW_H] while nothing covers the box; the bottom row's centre never
	## moves (it sits on the ammunition counter).
	func layout() -> Dictionary:
		var count := rows.size()
		if count == 0 or is_inf(cover_bottom):
			return {"rows": rows, "pitch": ROW_H}
		# The top plate (pitch - PLATE_GAP tall) has to end above the bottom row's centre by
		# no more than `room`: (count - 1) * pitch + (pitch - PLATE_GAP) / 2 <= room.
		var room := (size.y - ROW_H * 0.5) - (cover_bottom + COVER_GAP)
		var pitch := minf(ROW_H, (room + PLATE_GAP * 0.5) / (float(count) - 0.5))
		if pitch >= MIN_ROW_H:
			return {"rows": rows, "pitch": pitch}
		# Not even at the tightest pitch: the run of rows that fits, with the current one in it.
		var fit := mini(int(floor((room + PLATE_GAP * 0.5) / MIN_ROW_H + 0.5)), count)
		if fit <= 0:
			return {"rows": [] as Array[Dictionary], "pitch": MIN_ROW_H}
		var at := 0
		for i in count:
			if int(rows[i]["slot"]) == current:
				at = i
		var first := clampi(at - int(float(fit) / 2.0), 0, count - fit)
		return {"rows": rows.slice(first, first + fit), "pitch": MIN_ROW_H}

	## Every slot's plate drawn, from the bottom up.
	func footprint() -> Rect2:
		var laid := layout()
		var shown: Array = laid["rows"]
		if shown.is_empty():
			return Rect2()
		var pitch: float = laid["pitch"]
		var plate_h := pitch - PLATE_GAP
		var left := size.x
		for r in shown:
			left = minf(left, size.x - Ink.keycap_width(str(r.get("key", r["slot"])), 12) - 112.0)
		var top := size.y - ROW_H * 0.5 - float(shown.size() - 1) * pitch - plate_h * 0.5
		return Rect2(left, top, size.x + 4.0 - left, float(shown.size() - 1) * pitch + plate_h)

	func _draw() -> void:
		# From the bottom up, so the carried guns sit on the ammunition counter however few
		# there are, and the top of the box is the one that stays clear of the shell's column.
		var laid := layout()
		var shown: Array = laid["rows"]
		var pitch: float = laid["pitch"]
		var plate_h := pitch - PLATE_GAP
		var y := size.y - ROW_H * 0.5 - float(shown.size() - 1) * pitch
		for r in shown:
			var on := int(r["slot"]) == current
			var alpha := 1.0 if on else 0.72
			var key := str(r.get("key", r["slot"]))
			var cap_w := Ink.keycap_width(key, 12)
			var cap_x := size.x - cap_w
			# A plate per weapon: a white silhouette on a pale wall is no silhouette at all.
			var plate_x := cap_x - 112.0
			Ink.plate(self, Rect2(plate_x, y - plate_h * 0.5, size.x - plate_x + 4.0, plate_h),
				Color(Ink.c(self, &"plate"), 0.8 if on else 0.6), 7, Color(Ink.c(self, &"highlight"), 0.85) if on else Color(Ink.c(self, &"plate_edge"), 0.1), 2 if on else 1)
			var _w := Ink.keycap(self, Vector2(cap_x, y), key, 12, alpha)
			var tex := Ink.weapon_icon(r["id"])
			var h := minf(24.0 if on else 18.0, plate_h - 2.0)
			if tex != null:
				var s := tex.get_size()
				var w := minf(s.x * h / maxf(s.y, 1.0), 90.0)
				var at := Vector2(cap_x - 10.0 - w, y)
				# A shadow first, so a white gun reads on a white wall.
				var _s := Ink.icon(self, tex, at + Vector2(1.5, 1.5), h, Color(0, 0, 0, 0.55 * alpha), 90.0)
				var _d := Ink.icon(self, tex, at, h, Color(1, 1, 1, alpha), 90.0)
			else:
				Ink.text(self, Vector2(0.0, y + 5.0), str(r["name"]), 13, Color(Ink.c(self, &"text"), alpha), HORIZONTAL_ALIGNMENT_RIGHT, cap_x - 10.0, 4)
			y += pitch


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
		# The dark HUD draws a ready button as a deep slate edged in white and a charging one
		# near black; the bright theme ("Arcade") as the first HUD's saturated blue key.
		var bright := Ink.bright(self)
		var fill := Color(0.11, 0.16, 0.26, 0.92).lerp(Color(0.2, 0.55, 0.95, 0.88), bright) if ready \
			else Color(0.04, 0.05, 0.08, 0.86).lerp(Color(0.16, 0.2, 0.3, 0.85), bright)
		var edge := Ink.c(self, &"highlight") if active else Color(Ink.c(self, &"text"), (0.7 if ready else 0.22) if bright < 0.5 else (0.55 if ready else 0.25))
		Ink.plate(self, rect, fill, 10, edge, 3 if active else 2)
		Ink.plate(self, Rect2(rect.position + Vector2(3.0, 3.0), Vector2(rect.size.x - 6.0, rect.size.y * 0.42)), Color(1, 1, 1, lerpf(0.06, 0.14, bright) if ready else 0.04), 8, Color(0, 0, 0, 0), 0)
		var tex: Texture2D = b.get("icon", null)
		if tex != null:
			var side := SIDE * 0.62
			draw_texture_rect(tex, Rect2(rect.get_center() - Vector2(side, side) * 0.5, Vector2(side, side)), false, Color(1, 1, 1, 1.0 if ready else 0.45))
		else:
			Ink.text(self, Vector2(rect.position.x, rect.get_center().y + 5.0), str(b["label"]).substr(0, 5).to_upper(), 12, Ink.c(self, &"text"), HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 3)
		if not ready:
			var cover := rect.size.y * clampf(left / total, 0.0, 1.0)
			Ink.plate(self, Rect2(rect.position, Vector2(rect.size.x, cover)), Color(0.0, 0.0, 0.02, 0.5), 10, Color(0, 0, 0, 0), 0)
			Ink.text(self, Vector2(rect.position.x, rect.get_center().y + 8.0), "%.1f" % left if left < 10.0 else "%d" % int(left), 20, Ink.c(self, &"text"), HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 5)
		var pips_max := int(b.get("pips_max", 0))
		if pips_max > 0:
			var pips := int(b.get("pips", 0))
			var px := rect.get_center().x - 8.0 * float(pips_max - 1)
			for i in range(pips_max):
				var c := Vector2(px + 16.0 * float(i), rect.position.y - 9.0)
				draw_circle(c, 5.0, Color(0, 0, 0, 0.55))
				draw_circle(c, 3.8, Ink.c(self, &"highlight") if i < pips else Color(1, 1, 1, 0.25))
		var key := str(b["key"])
		var cap_w := Ink.keycap_width(key, 12)
		var _w := Ink.keycap(self, Vector2(rect.get_center().x - cap_w * 0.5, rect.end.y + 2.0), key, 12)


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
		var view := _render(avatar, id)
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

	func _render(avatar: DotAvatar, id: int) -> SubViewport:
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

		# The same person the body is (`ArenaPlayer` draws `ArenaAvatars.look_of` of the same
		# document and key), standing still, so the face in the row is the face in the world.
		var person := DotHumanoidFigure.new()
		view.add_child(person)
		person.build(ArenaAvatars.look_of(avatar, StringName("arena-player-%08d" % id)), 1.8)
		person.animate(0.0, 0.0)
		var face := FACE
		var bones := person.skeleton()
		if bones != null and bones.find_bone("Head") >= 0:
			face = _head_of(person, bones)

		# The figure faces -Z, so the camera is on that side, a little to one side so the
		# head has depth. `look_at_from_position`, because this may run before the viewport
		# is in the tree.
		var camera := Camera3D.new()
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		camera.size = FRAME_SIZE
		view.add_child(camera)
		camera.look_at_from_position(face + Vector3(-0.8, 0.15, -3.0), face)
		camera.current = true
		return view

	## The middle of the person's head, in the figure's space: the head bone (the bottom of the
	## head) carried up through the model, plus a third of a head.
	static func _head_of(person: DotHumanoidFigure, bones: Skeleton3D) -> Vector3:
		var to_figure := Transform3D.IDENTITY
		var node: Node = bones
		while node != null and node != person:
			if node is Node3D:
				to_figure = (node as Node3D).transform * to_figure
			node = node.get_parent()
		var head := to_figure * bones.get_bone_global_pose(bones.find_bone("Head")).origin
		return head + Vector3(0.0, 0.2, 0.0)

	## Where the head is when there is no skeleton to ask (the capsule), and how much of it the
	## frame holds.
	const FACE := Vector3(0.0, 1.3, 0.0)
	const FRAME_SIZE := 0.66
