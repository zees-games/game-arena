extends RefCounted

## Arena's weapon pictures: Jestan's CC0 sprites (dot-ui's DotWeaponIcons) mapped weapon by weapon.

## `pixel` is the sprites as drawn, `flat` one colour, `silhouette` the old rendered Kenney outlines.
const STYLES := [&"pixel", &"flat", &"silhouette"]

## zee weapon id to the sprite's type tag. A weapon not here (fists) keeps its silhouette.
const TAGS := {
	&"battle_rifle": &"battle_rifle", &"beamer": &"energy_rifle", &"bullpup": &"bullpup",
	&"burst_rifle": &"assault_rifle", &"carbine": &"carbine", &"charge_rifle": &"charge_rifle",
	&"derringer": &"derringer", &"drum_shotgun": &"drum_shotgun", &"frag": &"grenade",
	&"hatchet": &"hatchet", &"knife": &"knife", &"launcher": &"launcher",
	&"machine_pistol": &"machine_pistol", &"mallet": &"hammer", &"marksman": &"marksman",
	&"minigun": &"lmg", &"pickaxe": &"pickaxe", &"pistol": &"pistol", &"revolver": &"revolver",
	&"rifle": &"rifle", &"shiv": &"dagger", &"shotgun": &"shotgun", &"smg": &"smg",
	&"sniper": &"sniper", &"spade": &"axe", &"sticky": &"sticky",
}

static var style: StringName = &"pixel"
## Draw the held weapon as a flat sprite (a billboard view model and held sprite). Off by default.
static var sprites := false
static var _set: DotIconSet = null


## The shared set: stock sheet, arena's aliases, and the player's overrides from `user://weapon_icons.json`.
static func icon_set() -> DotIconSet:
	if _set == null:
		_set = DotWeaponIcons.stock()
		for id in TAGS:
			_set.alias(id, TAGS[id])
		var path := "user://weapon_icons.json"
		if FileAccess.file_exists(path):
			var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			if doc is Dictionary:
				_set.load_overrides(doc)
	_set.flat = style == &"flat"
	_set.flat_colour = Color.WHITE
	return _set


## The picture for [param id], or null (draw the name). Under `silhouette` it is always null here.
static func texture(id: StringName) -> Texture2D:
	if style == &"silhouette" or id == &"":
		return null
	return icon_set().texture_for(id)


static func set_style(value: StringName) -> bool:
	if not STYLES.has(value):
		return false
	style = value
	return true


## Selects the icon profile whose overrides apply (`user://weapon_icons.json`'s nested keys).
static func set_profile(value: StringName) -> void:
	icon_set().profile = value


## Nearest filtering for pixel art; the silhouettes are mipmapped and stay smooth.
static func filter(canvas: CanvasItem) -> void:
	var want := CanvasItem.TEXTURE_FILTER_PARENT_NODE if style == &"silhouette" else CanvasItem.TEXTURE_FILTER_NEAREST
	if canvas.texture_filter != want:
		canvas.texture_filter = want


## A pale one-pixel halo behind a sprite, so its dark outline reads on the HUD's dark plates.
## [param height] is the sprite's drawn height; [param alpha] fades with the row.
static func halo(canvas: CanvasItem, id: StringName, at: Vector2, height: float, alpha: float, max_width: float) -> void:
	if style != &"pixel":
		return
	var tex := icon_set().silhouette_for(id, &"", Color(1, 1, 1, 0.9))
	if tex == null:
		return
	var s := tex.get_size()
	var w := minf(s.x * height / maxf(s.y, 1.0), max_width)
	var h := w * s.y / maxf(s.x, 1.0)
	for d: Vector2 in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		canvas.draw_texture_rect(tex, Rect2(at.x + d.x, at.y - h * 0.5 + d.y, w, h), false, Color(1, 1, 1, 0.55 * alpha))


static var _menu: Dictionary = {}


## The picture for a loadout card: the sprite with a pale one-pixel halo, enlarged four times with
## no filtering, because the menu draws it through a linear-filtered TextureRect.
static func menu_texture(id: StringName) -> Texture2D:
	var tex := texture(id)
	if tex == null:
		return null
	var key := [id, style, icon_set().profile]
	if _menu.has(key):
		return _menu[key]
	var src := tex.get_image()
	if src == null:
		return tex
	src.convert(Image.FORMAT_RGBA8)
	var out := Image.create(src.get_width() + 2, src.get_height() + 2, false, Image.FORMAT_RGBA8)
	if style == &"pixel":
		for y in src.get_height():
			for x in src.get_width():
				if src.get_pixel(x, y).a > 0.0:
					for d: Vector2i in [Vector2i(0, 1), Vector2i(2, 1), Vector2i(1, 0), Vector2i(1, 2)]:
						out.set_pixel(x + d.x, y + d.y, Color(1, 1, 1, 0.6))
	out.blend_rect(src, Rect2i(Vector2i.ZERO, src.get_size()), Vector2i(1, 1))
	out.resize(out.get_width() * 4, out.get_height() * 4, Image.INTERPOLATE_NEAREST)
	var made := ImageTexture.create_from_image(out)
	_menu[key] = made
	return made
