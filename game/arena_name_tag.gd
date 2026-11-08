extends Node3D

## The tag over another player's head: a slim glass pill health bar (one shader quad: rounded ends, a
## fill that eases and a pale trail that drains behind a hit, quarter ticks, a gloss) and their name above it.
## Client side, drawing only. The player turns it to the camera; [method update] says what to show.

const BAR_SIZE := Vector2(1.0, 0.115)
const FILL_FULL := Color(0.30, 0.88, 0.50)
const FILL_MID := Color(1.0, 0.78, 0.22)
const FILL_LOW := Color(1.0, 0.27, 0.27)

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;
uniform float fraction = 1.0;
uniform float trail = 1.0;
uniform vec4 fill_colour : source_color = vec4(0.3, 0.88, 0.5, 1.0);
uniform vec4 accent : source_color = vec4(1.0);
uniform vec2 size = vec2(1.0, 0.115);
uniform float edge = 0.014;
float pill(vec2 p, vec2 half_size) {
	float r = half_size.y;
	vec2 q = abs(p) - (half_size - vec2(r));
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
void fragment() {
	vec2 p = (UV - 0.5) * size;
	float px = max(fwidth(p.x), 0.0005);
	float outer = pill(p, size * 0.5);
	float inner = pill(p, size * 0.5 - vec2(edge));
	float body = 1.0 - smoothstep(-px, px, outer);
	float well = 1.0 - smoothstep(-px, px, inner);
	float u = (p.x + size.x * 0.5 - edge) / (size.x - 2.0 * edge);
	float v = UV.y;
	float fill_on = 1.0 - smoothstep(fraction - px, fraction + px, u);
	float trail_on = 1.0 - smoothstep(trail - px, trail + px, u);
	vec3 col = mix(vec3(0.02, 0.025, 0.035), accent.rgb * 0.5, 1.0 - well);
	col = mix(col, vec3(0.95, 0.97, 1.0), trail_on * (1.0 - fill_on) * 0.8);
	vec3 lit = fill_colour.rgb * mix(1.3, 0.75, v);
	lit += vec3(0.18) * (1.0 - smoothstep(0.0, 0.42, v));
	col = mix(col, lit, fill_on * well);
	float k = u * 4.0;
	float to_tick = min(fract(k), 1.0 - fract(k)) * (size.x - 2.0 * edge) * 0.25;
	float ticks = (1.0 - smoothstep(0.003, 0.007, to_tick)) * step(0.02, u) * step(u, 0.98) * well;
	col = mix(col, vec3(0.02, 0.025, 0.035), ticks * 0.45);
	ALBEDO = col;
	ALPHA = body * mix(0.78, 0.96, well * max(fill_on, trail_on));
}
"""

## The shader and the mesh are the same for every tag: kept in the root window's metadata, not a static var
## (a static would still hold them at exit and the suites' leak check would count them).
static func _shared() -> Dictionary:
	var root: Window = (Engine.get_main_loop() as SceneTree).root
	if not root.has_meta(&"arena_name_tag_assets"):
		var shader := Shader.new()
		shader.code = SHADER_CODE
		var quad := QuadMesh.new()
		quad.size = BAR_SIZE
		root.set_meta(&"arena_name_tag_assets", {"shader": shader, "mesh": quad})
	return root.get_meta(&"arena_name_tag_assets")

var _bar: MeshInstance3D = null
var _material: ShaderMaterial = null
var _label: Label3D = null
## What the bar draws now: eased toward the health, with the trail lagging behind it.
var shown_fraction: float = 1.0
var trail_fraction: float = 1.0
var _target: float = 1.0


func _init() -> void:
	name = "HealthTag"
	var shared := _shared()
	_material = ShaderMaterial.new()
	_material.shader = shared["shader"]
	_material.render_priority = 1
	_bar = MeshInstance3D.new()
	_bar.name = "Bar"
	_bar.mesh = shared["mesh"]
	_bar.material_override = _material
	_bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_bar)

	_label = Label3D.new()
	_label.name = "Name"
	_label.font_size = 64
	_label.pixel_size = 0.0036
	_label.outline_size = 14
	_label.outline_modulate = Color(0.0, 0.0, 0.0, 0.85)
	_label.shaded = false
	_label.double_sided = true
	_label.alpha_cut = Label3D.ALPHA_CUT_DISABLED
	_label.position = Vector3(0.0, BAR_SIZE.y * 0.5 + 0.17, 0.001)
	add_child(_label)


## Colour of a fill at [param fraction]: green, through amber, to red.
static func fill_for(fraction: float) -> Color:
	var f := clampf(fraction, 0.0, 1.0)
	return FILL_MID.lerp(FILL_FULL, smoothf((f - 0.35) / 0.35)) if f > 0.35 else FILL_LOW.lerp(FILL_MID, smoothf(f / 0.35))


static func smoothf(x: float) -> float:
	var t := clampf(x, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## Draws what is asked: the bar at [param fraction] when [param bar], the [param player_name] when
## [param named] (in the teammate's colour when [param friend]). Hidden when it has neither.
func update(fraction: float, bar: bool, named: bool, player_name: String, friend: bool, delta: float) -> void:
	visible = bar or named
	_bar.visible = bar
	_label.visible = named
	_label.position.y = (BAR_SIZE.y * 0.5 + 0.17) if bar else 0.0
	_target = clampf(fraction, 0.0, 1.0)
	# The bar eases to its mark and the trail waits a beat, then drains; a heal lifts both at once.
	var ease_k := 1.0 - exp(-14.0 * delta)
	shown_fraction = _target if absf(shown_fraction - _target) < 0.002 else lerpf(shown_fraction, _target, ease_k)
	if trail_fraction < shown_fraction:
		trail_fraction = shown_fraction
	else:
		trail_fraction = maxf(shown_fraction, trail_fraction - 0.45 * delta)
	var accent := Color(0.55, 0.9, 1.0) if friend else Color(1.0, 0.55, 0.5)
	_material.set_shader_parameter("fraction", shown_fraction)
	_material.set_shader_parameter("trail", trail_fraction)
	_material.set_shader_parameter("fill_colour", fill_for(shown_fraction))
	_material.set_shader_parameter("accent", accent)
	if named:
		_label.text = player_name
		_label.modulate = Color(0.82, 0.96, 1.0) if friend else Color(1.0, 0.86, 0.84)
