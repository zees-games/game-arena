class_name ArenaCoverWarm
extends Node

## Draws the weapon materials under the loading cover a few at a time, so a browser whose GPU
## shader cache is cold compiles them over many short frames and not in one.
##
## [b]Why.[/b] The Compatibility renderer compiles a shader synchronously the first time it is
## drawn, and in a browser (ANGLE) a program is seconds of driver work on a fresh profile. The
## load gate hands everything it was given with [method DotLoadGate.warm_up] to one
## [DotRenderWarmup] whose rounds are 1000 items, so on a cold cache the whole weapon set is one
## frame of seconds: the cover freezes, and a desktop calls the tab "not responding". This
## node holds the gate (reason [constant HOLD]) and draws [member batch] items per round
## instead. The total work is the same; a warm cache pays nothing extra. Whatever it draws the
## gate's own warm-up draws again at no cost, because the shaders are cached by then.
##
## [b]Setting.[/b] [code]cl_cover_warm[/code] (a launch option or the page's query
## parameter): [code]1[/code] on, [code]0[/code] off, anything else (the default) on in a
## browser only. [code]cl_cover_warm_batch[/code] is the items per round (default
## [constant DEFAULT_BATCH]). Headless draws nothing and never uses it.

const ArenaFrameProbe := preload("arena_frame_probe.gd")

const CHANNEL := "arena.cover_warm"
const HOLD := &"materials"
const DEFAULT_BATCH := 4
const TRAITS := [
	&"transparency", &"blend_mode", &"cull_mode", &"depth_draw_mode", &"no_depth_test", &"shading_mode",
	&"diffuse_mode", &"specular_mode", &"disable_ambient_light", &"disable_fog", &"vertex_color_use_as_albedo",
	&"normal_enabled", &"emission_enabled", &"rim_enabled", &"clearcoat_enabled", &"anisotropy_enabled",
	&"ao_enabled", &"heightmap_enabled", &"subsurf_scatter_enabled", &"backlight_enabled", &"refraction_enabled",
	&"detail_enabled", &"billboard_mode", &"fixed_size", &"uv1_triplanar", &"uv2_triplanar", &"grow",
	&"proximity_fade_enabled", &"distance_fade_mode", &"use_point_size", &"disable_receive_shadows",
	&"metallic_specular", &"alpha_antialiasing_mode", &"texture_filter", &"texture_repeat",
]
const TEXTURES := [&"albedo_texture", &"metallic_texture", &"roughness_texture", &"emission_texture", &"normal_texture"]

## Items per round.
var batch: int = DEFAULT_BATCH
## What the last run did: items, rounds, milliseconds, the worst frame in it.
var stats := {}

var _gate: Object = null
var _warm: DotRenderWarmup = null
var _start_msec := 0
var _last_usec := 0
var _worst_usec := 0


static func enabled() -> bool:
	if DotPlatform.is_headless():
		return false
	match ArenaFrameProbe.launch_value("cl_cover_warm"):
		"1":
			return true
		"0":
			return false
	return DotPlatform.is_web()


## Which shader a material needs, as a key: what makes a [BaseMaterial3D] generate different code (the
## renderer shares one program between materials of one key, so only the first of a key compiles). A
## [ShaderMaterial] is its shader. A stand-in for the generated program, which a headless run does not make.
static func signature_of(m: Material) -> String:
	if m is ShaderMaterial:
		var sh := (m as ShaderMaterial).shader
		return "shader:%s" % (sh.resource_path if sh != null and sh.resource_path != "" else str(hash(sh.code) if sh != null else 0))
	if m is BaseMaterial3D:
		var parts: Array = []
		for t in TRAITS:
			parts.append(str(m.get(t)))
		for t in TEXTURES:
			parts.append("1" if m.get(t) != null else "0")
		return "std:" + ",".join(parts)
	return m.get_class()


## [param items] with the first material of each signature, and every mesh, ahead of the rest: the early
## rounds hold the compiles (a few programs each), the late ones only upload what the shaders already
## have, and no round is a pile of new programs by the order the weapons happened to list them in.
static func ordered(items: Array) -> Array:
	var head: Array = []
	var tail: Array = []
	var seen := {}
	for item: Variant in items:
		if item is Material:
			var key := signature_of(item)
			if seen.has(key):
				tail.append(item)
			else:
				seen[key] = true
				head.append(item)
		else:
			head.append(item)
	return head + tail


static func batch_setting() -> int:
	var text := ArenaFrameProbe.launch_value("cl_cover_warm_batch")
	return clampi(text.to_int(), 1, 1000) if text.is_valid_int() else DEFAULT_BATCH


## Holds [param gate] and draws [param items] in front of [param camera], then releases. With
## nothing to draw it finishes on the next frame.
func run(gate: Object, camera: Camera3D, items: Array) -> void:
	_gate = gate
	_start_msec = Time.get_ticks_msec()
	_last_usec = Time.get_ticks_usec()
	if gate != null:
		gate.call(&"hold", HOLD, "Preparing materials")
	_warm = DotRenderWarmup.new()
	_warm.name = "CoverWarmup"
	_warm.process_mode = Node.PROCESS_MODE_ALWAYS
	_warm.batch_size = batch
	_warm.add_items(ordered(items))
	var _c := _warm.finished.connect(_on_finished.bind(_warm.item_count(), _warm.batch_count()))
	camera.add_child(_warm)
	_warm.start()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	_worst_usec = maxi(_worst_usec, now - _last_usec)
	_last_usec = now


func _exit_tree() -> void:
	# Freed mid-run (a quit, a reload): never leave the gate held by a node that is gone.
	if _gate != null and is_instance_valid(_gate) and stats.is_empty():
		_gate.call(&"release", HOLD)


func _on_finished(_placed: int, items: int, rounds: int) -> void:
	stats = {"items": items, "rounds": rounds, "batch": batch,
		"msec": Time.get_ticks_msec() - _start_msec, "worst_frame_msec": _worst_usec / 1000}
	DotLog.info(CHANNEL, "materials drawn under the cover", stats)
	if ArenaFrameProbe.on() and DotWeb.available():
		DotWeb.publish("arena_cover_warm", JSON.stringify(stats))
	if _gate != null and is_instance_valid(_gate):
		_gate.call(&"release", HOLD)
	queue_free()
