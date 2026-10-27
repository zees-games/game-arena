extends Sprite3D

const ArenaWeaponIcons := preload("arena_weapon_icons.gd")

## A weapon sprite drawn as a flat model: the optional view model (under the camera) or a held
## sprite (on a hand). Pixel art is 2D side-on, so this is a look, not a replacement for the models.

enum Mode { VIEW, HELD }

var mode: Mode = Mode.VIEW
var _shown: StringName = &""


static func make(p_mode: Mode) -> Variant:
	var s = new()
	s.mode = p_mode
	s.name = "SpriteWeapon"
	s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	s.shaded = false
	s.double_sided = true
	s.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	s.no_depth_test = p_mode == Mode.VIEW
	s.render_priority = 10 if p_mode == Mode.VIEW else 0
	if p_mode == Mode.VIEW:
		s.position = Vector3(0.24, -0.2, -0.55)
		s.rotation_degrees = Vector3(0.0, -8.0, 0.0)
	else:
		s.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		s.position = Vector3(0.0, 0.0, 0.0)
	return s


## Draws weapon [param id]; hidden when the set has no sprite for it.
func show_weapon(id: StringName) -> void:
	var key := StringName("%s/%s" % [id, ArenaWeaponIcons.shared.style])
	if key == _shown:
		return
	_shown = key
	var tex := ArenaWeaponIcons.shared.icon_set().texture_for(id)
	texture = tex
	visible = tex != null
	if tex != null:
		# A 40 px sprite is about 0.5 m in the hand view and 0.8 m held.
		pixel_size = (0.5 if mode == Mode.VIEW else 0.8) / maxf(tex.get_size().x, 1.0)
