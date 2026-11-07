shader_type sky;
render_mode use_debanding;

// A day sky for the built-in maps: the horizon-to-zenith gradient the rig draws, a sun with a
// glow, and a layer of cumulus so the sky is something to look at and not a flat blue wall.
// Static (no TIME), so the radiance map is built once.

uniform vec3 top_colour : source_color = vec3(0.30, 0.56, 0.96);
uniform vec3 horizon_colour : source_color = vec3(0.80, 0.89, 1.0);
uniform vec3 sun_dir = vec3(0.4, 0.7, 0.5);
uniform vec3 sun_colour : source_color = vec3(1.0, 0.93, 0.80);
uniform float cloud_cover : hint_range(0.0, 1.0) = 0.5;
uniform float cloud_scale = 1.6;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1, 0)), f.x),
		mix(hash21(i + vec2(0, 1)), hash21(i + vec2(1, 1)), f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * vnoise(p);
		p = p * 2.03 + vec2(17.1, 9.7);
		a *= 0.5;
	}
	return v;
}

void sky() {
	vec3 d = normalize(EYEDIR);
	float h = abs(d.y);
	vec3 col = mix(horizon_colour, top_colour, pow(clamp(h, 0.0, 1.0), 0.5));

	vec3 s = normalize(sun_dir);
	float sd = max(dot(d, s), 0.0);
	col += sun_colour * (pow(sd, 8.0) * 0.18 + pow(sd, 64.0) * 0.35);
	col = mix(col, sun_colour * 4.0, smoothstep(0.9993, 0.9997, sd));

	if (d.y > 0.0) {
		vec2 p = d.xz / (d.y + 0.2) * cloud_scale;
		float n = fbm(p);
		float c = smoothstep(1.0 - cloud_cover, 1.0 - cloud_cover + 0.28, n);
		float lit = fbm(p + s.xz * 0.12);
		float shade = clamp((n - lit) * 4.0 + 0.55, 0.0, 1.0);
		vec3 cloud = mix(vec3(0.62, 0.68, 0.80), vec3(1.0, 0.98, 0.95), shade);
		c *= smoothstep(0.0, 0.25, d.y);
		col = mix(col, cloud, c * 0.92);
	}
	COLOR = col;
}
