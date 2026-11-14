extends "arena_presentation_b2a.gd"

const ArenaPaths := preload("arena_paths.gd")
const ArenaAmbience := preload("arena_ambience.gd")
const ArenaBindings := preload("arena_bindings.gd")
const ArenaFxCatalogue := preload("arena_fx_catalogue.gd")
const ArenaNameTagRules := preload("arena_name_tag_rules.gd")


const SCHEMA_VERSION := 1


## Where the player's settings live; only [method use_scratch_settings] moves it.
const PLAYER_SETTINGS := "user://arena_settings"


## The directory the next [ArenaPresentation] stores its settings in.
static var settings_directory: String = PLAYER_SETTINGS


const SOUND_DIR := "res://audio"

## Degrees of view per unit of mouse motion at a sensitivity of 1.
const DEGREES_PER_COUNT := 0.022


## Where the four effect scenes are. Rebased once: [method ArenaPaths.rebase] is idempotent,
## so the second call this line made changed nothing either way.
static var FX_DIR := ArenaPaths.rebase("res://scenes/fx")


## Every key a player can move: the InputMap, the settings document, the menu's Controls
## page and its help screen read this one table. See [ArenaBindings].
var bindings: DotMenuBindings = ArenaBindings.make()


## The connection overlay (`net_stat` at the console). See [method DotMenuNetStat.follow].
var net_stat: DotMenuNetStat = null


## Splinters, shards and the crack of whatever breaks; the panes and map props call `burst`.
var break_fx: DotFxBreak = null
## The client's own console source ([method _local_commands]), so the offline client can add
## what only a solo game has: the bot settings, which a server's console holds otherwise.
var local_console: DotConsoleLocal = null


## What the look settings are written onto: the tunables the client's sampler reads.
## See [method bind_look].
var _look: DotFpsTunables = null


## The player whose camera the motion settings move. See [method bind_camera_motion].
var _camera_player: Node = null


## The HUD's crosshair, and the arm length it was built with. See [method bind_crosshair].
var _crosshair: DotCrosshair = null
var _crosshair_length: float = 0.0


func setup() -> DotResult:
	var settled := _build_settings()
	if not settled.ok:
		return settled
	var heard := _build_audio()
	if not heard.ok:
		return heard
	var drawn := _build_fx()
	if not drawn.ok:
		return drawn
	# cl_fx_pool_idle: one shot fx pool per player, so trim each one's idle meshes.
	_addon_static(DotFxMeshPool, &"max_idle", 0, fx_pool_idle)
	_build_chat()
	net_stat = DotMenuNetStat.follow(self, settings)

	# Every value pushed once, after everything exists.
	apply_all()
	return DotResult.success(null)


## Pushes every current setting at whatever reads it.
func apply_all() -> void:
	for key in settings.schema.keys():
		_on_setting_changed(key, settings.get_value(key), &"applied")


static func schema() -> DotSettingsSchema:
	var s := DotSettingsSchema.new()
	s.version = SCHEMA_VERSION

	s.add(DotSettingsDef.number(&"master_volume", 0.8, 0.0, 1.0, &"audio"))
	s.add(DotSettingsDef.number(&"sfx_volume", 1.0, 0.0, 1.0, &"audio"))
	s.add(DotSettingsDef.number(&"voice_volume", 1.0, 0.0, 1.0, &"audio"))
	DotGameClient.declare_slide_setting(s)
	s.add(DotSettingsDef.boolean(&"push_to_talk", true, &"audio"))
	s.add(DotSettingsDef.choice(&"first_person_body", &"auto", [&"auto", &"off", &"legs", &"body"], &"video").with_description("Your own body when you look down: the server's choice (mp_fp_body), none, legs and feet, or the whole body."))
	var legs_def: Variant = DotOwnBodySetting.def()
	if legs_def != null:
		s.add(legs_def)
	ArenaNameTagRules.declare_settings(s)
	s.add(DotSettingsDef.boolean(&"ambient", true, &"audio").with_description("Quiet sounds under the map."))
	s.add(DotSettingsDef.number(&"ambient_volume", 1.0, 0.0, 1.0, &"audio"))

	# ACCOUNT scope: sensitivity is about the person's hand, not about this machine and
	# not about this game. A player who has found their number should never type it twice.
	s.add(DotSettingsDef.number(&"sensitivity", 2.5, 0.05, 20.0, &"controls").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))
	s.add(DotSettingsDef.boolean(&"invert_pitch", false, &"controls").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))
	# Hold the Aim key (right mouse) to aim down the sights (and look through a scope), or
	# to bash with the weapon as the pack's alt-fire does. Aiming by default; the Bash key
	# (X) bashes either way.
	s.add(DotSettingsDef.boolean(&"right_mouse_aims", true, &"controls").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	).with_description("Off: right mouse bashes with the weapon instead of aiming."))
	s.add(DotSettingsDef.choice(
		&"crosshair",
		&"cross",
		[&"dot", &"cross", &"circle", &"none"] as Array[StringName],
		&"controls"
	).with_scope(DotSettingsDef.Scope.ACCOUNT))

	# SERVER_CLAMPED, and this is the whole reason that scope exists.
	s.add(DotSettingsDef.integer(&"field_of_view", 100, 70, 120, &"video").with_scope(
		DotSettingsDef.Scope.SERVER_CLAMPED
	))
	s.add(DotSettingsDef.boolean(&"view_model", true, &"video").with_scope(
		DotSettingsDef.Scope.SERVER_CLAMPED
	))

	s.add(DotSettingsDef.integer(&"fx_quality", 3, 0, 3, &"video").with_description(
		"A lower tier is missing the most expensive effects, not running all of them badly."
	))

	s.add(DotSettingsDef.boolean(&"gore", true, &"video").with_description(
		"Blood when a player dies, and on the wall behind a body you hit. Bullet holes stay on either way."
	))

	_add_chat_and_comfort(s)

	# One binding setting per key in the table. The two chat keys are declared above with
	# their ACCOUNT scope, which the table leaves alone.
	ArenaBindings.make().add_to_schema(s)

	# dot-menu's stock video and interface settings: the window, V-Sync, the frame cap, render
	# scale, the theme, the frame-rate counter and net_stat. Keys already declared above keep this
	# game's default (a field of view of 100, horizontal at 4:3).
	return DotMenuStock.declare(s, [DotMenuStock.GROUP_VIDEO, DotMenuStock.GROUP_INTERFACE] as Array[StringName])


## Chat, accessibility, camera motion, HUD inset and the solo bots, split from [method schema] for length.
static func _add_chat_and_comfort(s: DotSettingsSchema) -> void:
	# Chat. ACCOUNT scope for all three: which key opens chat and whether a player wants
	# the box at all is about the person, not about this machine and not about this game.
	s.add(DotSettingsDef.choice(
		&"chat_window",
		&"auto",
		[&"auto", &"on", &"off"] as Array[StringName],
		&"chat"
	).with_scope(DotSettingsDef.Scope.ACCOUNT).with_description(
		"auto hides the box on a server that is already carrying chat somewhere the "
		+ "player can see it; on always draws it; off never does."
	))
	s.add(DotSettingsDef.binding(&"chat_open_key", "Y", &"chat").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))
	s.add(DotSettingsDef.binding(&"chat_team_key", "U", &"chat").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))

	s.add(DotSettingsDef.number(&"shake_scale", 1.0, 0.0, 2.0, &"accessibility")
		.with_description("Zero turns camera shake off entirely."))
	s.add(DotSettingsDef.boolean(&"allow_flashes", true, &"accessibility")
		.with_description("Off draws no full-screen flashes at all."))
	s.add(DotSettingsDef.boolean(&"penetration_decals", true, &"video")
		.with_description("Bullet marks on both faces of a wall a shot passed through, and where it ricocheted."))
	s.add(DotSettingsDef.boolean(&"reduce_motion", false, &"accessibility").with_scope(DotSettingsDef.Scope.ACCOUNT)
		.with_description("The end-of-match announcement appears at once, with nothing sliding, rising or bursting."))

	# Camera motion, each 0 (off) to 2, 1 being the game's pick (`ArenaPlayer.camera_motion_picks`).
	# ACCOUNT, like the sensitivity: whether motion makes somebody sick is about the person, not
	# the machine. One each, because a player who cannot take the roll may still want the dip.
	for key: StringName in CAMERA_MOTION_KEYS:
		s.add(DotSettingsDef.number(key, 1.0, 0.0, 2.0, &"accessibility", 0.05).with_scope(
			DotSettingsDef.Scope.ACCOUNT
		).with_description(CAMERA_MOTION_KEYS[key]))

	# How far the HUD sits in from the edge of the screen, for a television's overscan or a
	# phone's notch. DEVICE: it is about this screen. Applied live by `ArenaClient`.
	s.add(DotSettingsDef.integer(&"hud_safe_area", 16, 0, 120, &"hud")
		.with_description("Pixels between the HUD and the edge of the screen."))

	# How well the bots of a solo match play, saved with the player's other settings; the menu's
	# General page has it, and `ArenaClient._bind_bot_console` applies it to `DotBotSettings`.
	s.add(DotSettingsDef.choice(
		&"solo_bot_difficulty",
		&"medium",
		[&"easy", &"medium", &"hard", &"nightmare"] as Array[StringName],
		&"gameplay"
	).with_description("How well the bots play in a solo match. A server sets its own."))

	# LOCAL ONLY: the player's own Source game (TF2) folder, read for the stock textures a dropped `<map>_orig` pack lacks
	# (ArenaSourceInstall caches them in the user folder; they never ship). Empty: the usual Steam folders. A setting is its
	# own console command, so `source_game_path <folder>` sets it too; General > Local maps has a field.
	s.add(DotSettingsDef.text(&"source_game_path", "", &"gameplay")
		.with_description("Your own Source game (TF2) install folder, for the stock textures of a dropped _orig map. Empty: look in Steam's usual folders."))


## The camera motion settings, in [method ArenaPlayer.set_camera_motion_scales]' order, with
## what each moves.
const CAMERA_MOTION_KEYS := {
	&"camera_landing_dip": "How far the view dips when you land from a height. All the way left is off.",
	&"camera_strafe_roll": "How far the view leans into a strafe or a slide. All the way left is off.",
	&"camera_wall_lean": "How far the view leans away from a wall you run along. All the way left is off.",
	&"camera_speed_fov": "How much the view widens when you go faster than a run. All the way left is off.",
}


func _build_settings() -> DotResult:
	settings = DotSettingsManager.new()
	settings.name = "Settings"
	settings.schema = schema()
	settings.local_store = DotSettingsStoreFile.new(settings_directory)
	settings.app_namespace = &"game_arena"
	settings.shared_namespace = &"tmc_account"
	add_child(settings)

	var res := settings.setup()
	if not res.ok:
		return res.wrap("the arena's settings")
	settings.changed.connect(_on_setting_changed)
	return DotResult.success(null)


## Push to talk or an open microphone, on this player's voice (published by the client's
## extras as `dot_voice_client`). Also when the voice is published after the settings
## loaded, or a saved open microphone would wait for the switch to be touched.
func _apply_push_to_talk() -> void:
	var voice := DotRegistry.get_service(&"dot_voice_client")
	if voice != null and voice.has_method(&"set_open_mic") and settings != null:
		voice.call(&"set_open_mic", not settings.get_bool(&"push_to_talk", true))
	var bus := DotRegistry.signals()
	if not bus.service_registered.is_connected(_on_service_registered):
		bus.service_registered.connect(_on_service_registered)


func _on_service_registered(service: StringName, _instance: Object) -> void:
	if service == &"dot_voice_client":
		_apply_push_to_talk()


func _on_setting_changed(key: StringName, value: Variant, _why: StringName) -> void:
	match key:
		&"master_volume":
			audio.mixer.master = float(value)
			audio.mixer.apply_to_buses()
		&"sfx_volume":
			audio.mixer.sfx = float(value)
			audio.mixer.apply_to_buses()
		&"voice_volume":
			audio.mixer.voice = float(value)
		&"push_to_talk":
			_apply_push_to_talk()
			audio.mixer.apply_to_buses()
		&"shake_scale":
			fx.config.shake_scale = float(value)
		&"allow_flashes":
			fx.config.allow_flashes = bool(value)
		&"penetration_decals":
			fx.config.penetration_decals = bool(value)
		&"fx_quality":
			fx.config.quality = int(value)
		&"chat_window":
			_apply_chat_visibility()
		&"chat_open_key":
			_bind_chat(chat_window.open_action if chat_window != null else &"", str(value))
		&"chat_team_key":
			_bind_chat(chat_window.team_action if chat_window != null else &"", str(value))
		&"sensitivity", &"invert_pitch":
			_apply_look()
		&"camera_landing_dip", &"camera_strafe_roll", &"camera_wall_lean", &"camera_speed_fov":
			_apply_camera_motion()
		&"crosshair":
			_apply_crosshair()
		_:
			# A key binding (`bind_forward`, `bind_dash`, ...) onto the InputMap. The chat
			# keys are answered above, so an empty one keeps its key rather than going back
			# to the default.
			var _bound := bindings.apply_setting(key, value)


func _apply_look() -> void:
	if _look == null or settings == null:
		return

	_look.mouse_sensitivity = look_degrees_per_count(settings.get_float(&"sensitivity", 2.5))
	_look.invert_look_y = settings.get_bool(&"invert_pitch", false)


## Points the camera motion settings at [param player]'s camera, and applies them. Called by
## the client when it adopts a player, like [method bind_look], and for the same reason: a
## setting nobody applies is a slider that moves nothing.
func bind_camera_motion(player: Node) -> void:
	_camera_player = player
	_apply_camera_motion()


func _apply_camera_motion() -> void:
	if settings == null or _camera_player == null or not is_instance_valid(_camera_player):
		return
	_camera_player.set_camera_motion_scales(
		settings.get_float(&"camera_landing_dip", 1.0),
		settings.get_float(&"camera_strafe_roll", 1.0),
		settings.get_float(&"camera_wall_lean", 1.0),
		settings.get_float(&"camera_speed_fov", 1.0)
	)


## A sensitivity setting as degrees per unit of mouse motion. See [constant DEGREES_PER_COUNT].
static func look_degrees_per_count(sensitivity: float) -> float:
	return maxf(sensitivity, 0.0) * DEGREES_PER_COUNT


## Hands the crosshair setting a crosshair to shape, and shapes it. Like [method bind_look], and for
## the same reason: the `crosshair` choice was on the settings screen and nothing drew anything
## differently for any of its four answers.
func bind_crosshair(crosshair: DotCrosshair) -> void:
	_crosshair = crosshair
	_crosshair_length = crosshair.length if crosshair != null else 0.0
	_apply_crosshair()


func _apply_crosshair() -> void:
	if _crosshair == null or settings == null:
		return

	var style := StringName(settings.get_string(&"crosshair", "cross"))

	# `suppressed` rather than `visible`: dot-ui keeps a suppressed crosshair measuring its
	# spread, so nothing that reads the gap stops working because a player hid the lines.
	_crosshair.suppressed = style == &"none"
	_crosshair.centre_dot = true

	# **`circle` draws the cross**, because `DotCrosshair` has no ring to draw and a setting that
	# drew nothing at all would be worse than one that draws the default.
	_crosshair.length = 0.0 if style == &"dot" else _crosshair_length
	_crosshair.queue_redraw()


func _build_audio() -> DotResult:
	audio = ArenaAudioManager.new()
	audio.name = "Audio"
	audio.catalogue = sound_catalogue()
	audio.mixer = DotAudioMixer.new()
	audio.mixer.master = settings.get_float(&"master_volume", 0.8)
	audio.mixer.sfx = settings.get_float(&"sfx_volume", 1.0)
	audio.mixer.voice = settings.get_float(&"voice_volume", 1.0)
	# A firefight is the busiest this game gets and thirty-two is what it needs; past
	# that the pool is holding sounds nobody can pick out of the mix.
	audio.voices = 32
	# Measured toward the family's -17 LUFS (dot-audio docs/loudness.md) with the local player
	# driven by tools/loudness_pilot.gd (walking, turning off walls, firing bursts): at 4.0 a 40 s
	# round read -19.5 LUFS, at 7.5 three rounds read -16.8, -17.6 and -17.2.
	audio.loudness_trim_db = 7.5
	add_child(audio)

	var res := audio.setup()
	if not res.ok:
		return res.wrap("the arena's audio")

	steps = DotAudioFootsteps.new()
	steps.name = "Footsteps"
	steps.manager = audio
	# The loudest stock step carries 32 m, and no rule here reads a step: a body past
	# earshot costs no ground ray per tick (32 players made 31 of them).
	steps.hear_distance = 36.0
	add_child(steps)
	ambience = DotAudioAmbience.new()
	ambience.name = "Ambience"
	ambience.manager = audio
	ambience.fallback_bed = &"amb_industrial"
	add_child(ambience)
	shot_enclosure = DotAudioEnclosure.new()
	shot_enclosure.name = "ShotEnclosure"
	add_child(shot_enclosure)
	shots = DotShotPlayer.new()
	shots.name = "Shots"
	shots.manager = audio
	shots.enclosure = shot_enclosure
	add_child(shots)
	# Every stock class, not only the local weapons': other players' guns play through this one player
	# (`remote_shot`), so none of them builds a manager, a player and thirteen registrations (40 ms) on its first shot.
	for weapon_class in AwShotLayers.STOCK_CLASSES:
		var _registered := shots.register(DotAudioShotStock.shot(weapon_class))
	for gun: StringName in AwWeaponPack.SOUND_CLASSES:
		var own := AwShotLayers.gun_shot(gun) as DotShotDef
		if own != null:
			var _own_registered := shots.register(own)
	ambient = DotAmbienceDirector.new()
	ambient.name = "Ambient"
	ambient.manager = audio
	ambient.default_mood = &"industrial"
	ambient.prefix_moods = AMBIENT_PREFIXES
	ambient.rules = ArenaAmbience.make_rules()
	ambient.beds = ambience
	add_child(ambient)
	var _moods := ambient.setup()
	ambient.follow_settings(settings)
	if ambient.has_moods():
		ambient.on_map(&"")
	else:
		ambience.set_map_bed(bed_for(&""))

	# Only on a real sink, and only after setup: a headless server has nothing to bake for.
	# Baked a few recipes a frame under the cover: all at once it is a 0.7 s frame here and
	# several seconds in a browser.
	var godot_sink := audio.sink as DotAudioSinkGodot
	if godot_sink != null:
		godot_sink.bank = {}
		_bake_recipes = sound_recipes()
		_bake_ids = _bake_recipes.keys()
		_bake_hold(true)
		DotLog.info(
			CHANNEL,
			"synthesised stand-ins baked for ids whose files this build lacks",
			{"ids": _bake_ids.size(), "dir": SOUND_DIR}
		)

	return DotResult.success(null)


static func fx_catalogue() -> DotFxCatalogue:
	return ArenaFxCatalogue.make(FX_DIR, EXPLOSION)


func _build_fx() -> DotResult:
	fx = DotFxManager.new()
	fx.name = "Fx"
	fx.catalogue = fx_catalogue()
	fx.config = DotFxConfig.new()
	fx.config.quality = settings.get_int(&"fx_quality", 3)
	fx.config.shake_scale = settings.get_float(&"shake_scale", 1.0)
	fx.config.allow_flashes = settings.get_bool(&"allow_flashes", true)
	fx.config.max_decals = 192
	fx.config.penetration_decals = settings.get_bool(&"penetration_decals", true)
	add_child(fx)

	var res := fx.setup()
	if not res.ok:
		return res.wrap("the arena's effects")

	blood = ArenaBlood.new()
	add_child(blood)
	blood.follow(settings)

	break_fx = DotFxBreak.new()
	add_child(break_fx)
	break_fx.add_to_group(&"arena_break_fx")
	break_fx.follow(settings)

	# [b]Said out loud, because a missing scene is otherwise a DEBUG line.[/b] Once all
	# four scenes this catalogue names were missing and every muzzle flash, spark, hole and gib in
	# this game was refused for it, with no suite noticing.
	var missing := fx.catalogue.missing_scenes()
	if not missing.is_empty():
		DotLog.warn(CHANNEL, "effect scenes missing; those effects will not draw", {
			"paths": ", ".join(missing),
		})
	return DotResult.success(null)


## dot-console's kit: `help`, `clear`, `settings`, every setting by its own name, the in-process
## server's console, and the panel on layer 128, registered with [param menu]. This game adds its
## own four.
func build_console(menu: Object = null) -> DotResult:
	console = DotConsoleKit.build(self, settings, menu)

	var server_sources := console.sources().slice(1)
	for s in server_sources:
		console.remove_source(s)
	local_console = _local_commands()
	console.add_source(local_console)
	for s in server_sources:
		console.add_source(s)

	console_panel = get_node_or_null(^"ConsoleLayer/ConsolePanel") as DotConsolePanel
	return DotResult.success(null)


## The listener's roof, once a frame: under one the ambience crosses to its indoor mood.
func follow_roof(delta: float, eye: Vector3, space: PhysicsDirectSpaceState3D, world_mask: int) -> void:
	if shot_enclosure != null:
		shot_enclosure.mask = world_mask
		shot_enclosure.step(delta, eye, space)
	shot_roof.mask = world_mask
	var _changed := shot_roof.step(delta, eye, space)
	if ambient != null:
		ambient.follow_roof(delta, eye, space, world_mask)
