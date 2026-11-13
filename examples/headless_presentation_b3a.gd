extends "headless_presentation_b2.gd"

func _test_schema() -> void:
	_section("What a player may change, and what a server may cap")

	var s := ArenaPresentation.schema()
	_check(s.validate().ok, "the schema validates")
	_check(
		ArenaPresentation.settings_directory.begins_with("user://scratch/"),
		"this suite's settings are a scratch document, not the player's",
		ArenaPresentation.settings_directory
	)

	var clamped := s.keys_in_scope(DotSettingsDef.Scope.SERVER_CLAMPED)
	_check(clamped.has(&"field_of_view"), "a server may cap the field of view")
	_check(clamped.has(&"view_model"), "and force view models off")
	_check(
		not clamped.has(&"sensitivity") and not clamped.has(&"master_volume"),
		"and may not touch the sensitivity or the volume, which are a fingerprint"
	)

	var account := s.keys_in_scope(DotSettingsDef.Scope.ACCOUNT)
	_check(
		account.has(&"sensitivity") and account.has(&"crosshair"),
		"sensitivity and a crosshair follow the person, because they are about their hand"
	)

	_check(
		ArenaPresentation.sound_catalogue().validate().ok,
		"the sound catalogue validates with no audio files present at all"
	)
	_check(
		ArenaPresentation.fx_catalogue().validate().ok,
		"and so does the effect catalogue, which loads no scene to validate"
	)
	var stock_ok := true
	for sound: StringName in DotAudioWeaponStock.COUNTS:
		stock_ok = stock_ok and ArenaPresentation.sound_catalogue().find(DotAudioWeaponStock.id_of(sound)) != null
	_check(stock_ok, "the game's sound catalogue carries every stock weapon sound")
	var stock_streams := true
	for sound in [AwWeaponSound.LIGHT, AwWeaponSound.SHOTGUN, AwWeaponSound.DRY, AwWeaponSound.EQUIP,
			AwWeaponSound.RELOAD_OUT, AwWeaponSound.RELOAD_SHELL, AwWeaponSound.SUPPRESSED]:
		var stock_stream := AwWeaponSound.stream(sound)
		stock_streams = stock_streams and stock_stream is AudioStreamOggVorbis and stock_stream.resource_path.begins_with(DotWeaponSound.DIR)
	_check(stock_streams, "weapon shots, dry, equip and reloads play the stock recordings, not the synth fallback")
	var stock_problems := DotWeaponSound.check_stock()
	_check(stock_problems.is_empty(), "every weapon class resolves a non-silent, unclipped stock voice (%s)" % ", ".join(stock_problems))
	_done()


func _test_ambience_is_quiet_and_obeys_settings() -> void:
	_section("The ambience is quiet by default, follows the map and obeys the settings")

	var p := _make()
	var a := p.ambient
	_check(a != null and a.has_moods() and a.ambient.mood_names().size() == 8, "dot-audio's stock mood set loaded")
	if a == null or not a.has_moods():
		p.queue_free()
		_done()
		return
	a.ambient.set_process(false)
	_check(a.mood_for_map()["mood"] == &"industrial", "the built-in halls get the machinery mood")
	p.on_map_changed(&"surf_ski_2")
	_check(a.ambient.effective_mood() == &"snow_wind" and a.mood_for_map()["why"] == "name prefix", "a surf map is wind")
	p.on_map_changed(&"kz_cave")
	_check(a.ambient.effective_mood() == &"cave_tunnel", "a climb map is a cave")
	a.map_lookup = func(id: StringName) -> Variant: return {"meta": {"ambient": {"level": 1.6, "lively": true}}} if id == &"zz_doc" else null
	p.on_map_changed(&"zz_doc")
	_check(p.ambience != null and is_equal_approx(p.ambience._gain(), p.ambience.level * 1.6), "on_map_changed(id) alone reaches the bed with the map definition's ambient.level through the lookup")
	p.on_map_changed(&"zz_plain")
	_check(p.ambience != null and is_equal_approx(p.ambience._gain(), p.ambience.level), "and the next map without one is back at the quiet default")
	_check(a.ambient.config.enabled and a.ambient.config.volume <= 0.35, "the level is quiet by default (%.2f)" % a.ambient.config.volume)
	_check(a.ambient.target_level() < 0.5, "and the layer's target level is under half (%.2f)" % a.ambient.target_level())

	var _r1 := p.settings.set_value(&"ambient_volume", 0.5)
	_check(is_equal_approx(a.ambient.config.volume, ArenaAmbience.LEVEL * 0.5), "the player's slider turns it down")
	var _r2 := p.settings.set_value(&"ambient", false)
	_check(not a.ambient.config.enabled, "the player's switch turns it off")
	var _r3 := p.settings.set_value(&"ambient", true)
	var _r4 := p.settings.set_value(&"master_volume", 0.0)
	_check(p.audio.mixer.master == 0.0 and a.ambient.bus == &"Ambience", "the master volume reaches it through the Ambience bus")
	_check(str(p.describe_lines()).contains("ambience"), "describe says what plays")

	p.queue_free()
	_done()


func _test_audio_is_a_firefight() -> void:
	_section("A shot you cannot place is a shot you cannot answer")

	var p := _make()
	var sink := p.audio.sink as DotAudioSinkNull
	_check(sink != null, "a headless run gets the sink that cannot make a noise")
	if sink == null:
		p.queue_free()
		_done()
		return

	var cat := p.audio.catalogue
	var rifle := cat.find(&"fire_rifle")
	_check(rifle != null, "a rifle has a sound")
	_check(
		rifle.kind == DotAudioDef.Kind.POSITIONAL_3D,
		"and it is positional, which is the only thing audio adds that the HUD cannot"
	)
	_check(rifle.max_distance > 0.0, "with a cull distance rather than an attenuation curve alone")
	_check(
		cat.find(&"hit_marker").kind == DotAudioDef.Kind.FLAT,
		"while a hit marker is flat, because it is information about your own shot and "
		+ "would otherwise get quieter the further away you hit somebody"
	)

	p.audio.listener_position = Vector3.ZERO
	sink.forget()
	var muzzle := Transform3D.IDENTITY
	muzzle.origin = Vector3(2, 0, 0)
	# The layered player has its own suite; this section checks the plain fire_* fallback and its throttle.
	p.shots.rules.layers = false
	for _i in range(12):
		p.on_fired(&"rifle", muzzle, false)
	_check(
		sink.count_of(&"fire_rifle") == 3,
		"twelve rifles in one tick make three sounds (%d), because twelve identical "
		% sink.count_of(&"fire_rifle")
		+ "streams half a millisecond apart is one gunshot twelve times as loud"
	)

	sink.forget()
	var far := Transform3D.IDENTITY
	far.origin = Vector3(0, 0, 400)
	p.on_fired(&"rifle", far, false)
	_check(
		sink.count_of(&"fire_rifle") == 0,
		"and a shot four hundred metres away costs nothing at all"
	)

	# Every id has a noise, and every noise has an id: an id with no recipe stays silent for ever,
	# and a recipe naming no id reaches nothing; neither errors, so check both directions.
	var recipes := ArenaPresentation.sound_recipes()
	_check_recipes_cover_ids(cat, recipes)

	# The bank is what the real sink would be given. Baking it here is the only place a
	# headless run can tell "the game would make a noise" from "the game has a table".
	var bank := DotAudioSynth.bank(cat, recipes)
	_check(
		bank.has(&"fire_rifle") and bank.has(rifle.path),
		"the bank answers under both the id and the path the def names"
	)

	_check_recorded_sounds(cat, rifle, bank)

	_check_sliced_bank(cat, recipes, bank)

	p.queue_free()
	_audio_firefight_rest()


func _check_recipes_cover_ids(cat: DotAudioCatalogue, recipes: Dictionary) -> void:
	var uncovered: Array[String] = []
	for id in cat.ids():
		# dot-audio's stock footsteps and beds are files the addon ships: no stand-in needed.
		# Nor are the ambience moods' files, which DotAmbience registers when a mood starts,
		# nor fc-weapons' own per-gun reports (aw_gun_*), recordings the pack ships.
		var sid := String(id)
		if not recipes.has(id) and not DotAudioStock.ids().has(id) and not sid.begins_with("shot_") and not sid.begins_with(DotAmbience.ID_PREFIX) \
				and not sid.begins_with(AwShotLayers.GUN_PREFIX):
			uncovered.append(String(id))
	_check(
		uncovered.is_empty(),
		"every id in the catalogue has a stand-in voice (missing: %s)" % str(uncovered)
	)

	var stray: Array[String] = []
	for id in recipes.keys():
		if cat.find(StringName(id)) == null:
			stray.append(String(id))
	_check(stray.is_empty(), "and no recipe names an id that is not there (%s)" % str(stray))


func _check_sliced_bank(cat: DotAudioCatalogue, recipes: Dictionary, bank: Dictionary) -> void:
	# Baked a few recipes a frame under the loading cover, never as one 0.7 s frame: the
	# sliced bank must hold exactly what the one-shot bank does, in many short calls.
	var sliced := {}
	var queue: Array = recipes.keys()
	var calls := 0
	var longest := 0
	var total := 0
	while not queue.is_empty() and calls < 10000:
		var t0 := Time.get_ticks_msec()
		ArenaPresentation.bake_into(sliced, cat, recipes, queue, 1)
		var took := Time.get_ticks_msec() - t0
		longest = maxi(longest, took)
		total += took
		calls += 1
	_check(sliced.keys().size() == bank.keys().size() and sliced.has(&"fire_rifle"),
		"the sound bank baked in slices holds what the one-shot bank does (%d of %d)" % [sliced.size(), bank.size()])
	# A slice is short in itself (under 250 ms) or small beside the whole bake (a scheduler stall on a loaded box
	# inflates one call, not the bake): what this guards is the one 0.7 s frame, where one call is the whole bake.
	_check(calls > 4 and (longest < 250 or longest * 4 < total),
		"and it took %d calls, none over 250 ms or a quarter of the bake (longest %d ms of %d)" % [calls, longest, total])


func _check_recorded_sounds(cat: DotAudioCatalogue, rifle: DotAudioDef, bank: Dictionary) -> void:
	# Item 1722: every game sound was a synthesised stand-in because its file was looked for in a
	# res://audio nobody filled. They name the addons' recorded files now.
	var unrecorded: Array[String] = []
	for id: StringName in ArenaPresentation.RECORDED:
		var def := cat.find(id)
		if def == null:
			unrecorded.append(String(id))
			continue
		var files: Array[String] = [def.path]
		for v in def.variants:
			files.append(String(v))
		if def.path.begins_with(ArenaPresentation.SOUND_DIR) or (def.variants.size() < 2 and int(ArenaPresentation.RECORDED[id][2]) > 1):
			unrecorded.append(String(id))
			continue
		for f in files:
			if not ResourceLoader.exists(f):
				unrecorded.append(f)
	_check(unrecorded.is_empty() and rifle.variants.size() == 5,
		"the recorded sounds play the addons' files, several each where several are named (wrong: %s)" % str(unrecorded))
	var unfilled: Array[String] = []
	for id: StringName in cat.ids():
		if cat.find(id).path.begins_with(ArenaPresentation.SOUND_DIR):
			unfilled.append(String(id))
	_check(unfilled.is_empty(), "and no sound still looks in the empty res://audio (%s)" % str(unfilled))
	_check(
		(
			(bank[&"fire_rail"] as AudioStreamWAV).data
			!= (bank[&"fire_rifle"] as AudioStreamWAV).data
		),
		"and a rail is a different noise from a rifle, not a quieter one"
	)


func _audio_firefight_rest() -> void:
	_done()


func _test_effects_and_the_player_who_asked_for_none() -> void:
	_section("A damage tint a player asked not to see")

	var p := _make()
	p.fx.viewer_position = Vector3.ZERO

	p.fx.flash_colour.a = 0.0
	p.on_hurt(25.0)
	_check(p.fx.flash_colour.a > 0.0, "being hurt tints the screen")
	_check(
		p.fx.flash_colour.a <= 0.3,
		"not much -- a damage tint is the effect everybody sets to full strength because "
		+ "it is 'only a tint'"
	)

	p.settings.set_value(&"allow_flashes", false)
	p.fx.flash_colour.a = 0.0
	p.on_hurt(25.0)
	_check(
		is_equal_approx(p.fx.flash_colour.a, 0.0),
		"and a player who asked for no flashes gets none, however much damage they take"
	)
	p.settings.set_value(&"allow_flashes", true)

	# The grunt: scaled by the damage, and left to the death cry when the hit was lethal.
	var q := _make()
	var hurt_sink := q.audio.sink as DotAudioSinkNull
	hurt_sink.forget()
	q.on_hurt(5.0)
	q.on_hurt(60.0, true)
	var grunts := hurt_sink.count_of(&"hurt")
	_check(grunts == 1, "a lethal hit makes no hurt grunt (the death cry has it), a graze does (%d)" % grunts)
	hurt_sink.forget()

	# A low tier is MISSING the expensive effects rather than running all of them badly.
	# Halving a particle count on the effect that is killing the frame does not save it.
	p.settings.set_value(&"fx_quality", 0)
	var at := Transform3D.IDENTITY
	_check(
		p.fx.spawn(&"death_burst", at) == null,
		"at the lowest tier the expensive effect does not exist"
	)
	p.settings.set_value(&"fx_quality", 3)
	# This once asserted the refusal's reason was `missing`, because the scene
	# was not in the repository -- which made a check out of the bug. It is drawn now.
	var why := []
	p.fx.spawned.connect(func(_id: StringName, node: Node, reason: StringName) -> void:
		why.append(reason if node == null else &"drawn")
	)
	p.fx.spawn(&"death_burst", at)
	_check(
		why == [&"drawn"],
		"and at the highest it is drawn (%s)" % str(why)
	)

	_check_render_quality(p)

	p.queue_free()
	_done()


func _check_render_quality(p) -> void:
	# Texture detail and filtering reach the world's viewport through dot-fx's render quality,
	# which follows the presentation's settings only because the client hands them over.
	var screen := SubViewport.new()
	add_child(screen)
	var client := ArenaClient.new()
	client.presentation = p
	client.platform = DotGameClient.new()
	var quality: Node = load("res://addons/dot_fx/runtime/dot_fx_render_quality.gd").new()
	quality.set(&"viewport", screen)
	add_child(quality)
	client.platform.render_quality = quality
	client._follow_render_quality()
	p.settings.set_value(&"mip_bias", 1.0)
	p.settings.set_value(&"aniso", 8)
	_check(is_equal_approx(screen.texture_mipmap_bias, 1.0), "the menu's Texture detail reaches the viewport (%.2f)" % screen.texture_mipmap_bias)
	_check(screen.anisotropic_filtering_level == Viewport.ANISOTROPY_8X, "and so does its anisotropic filtering (%d)" % screen.anisotropic_filtering_level)
	p.settings.set_value(&"mip_bias", 0.0)
	p.settings.set_value(&"aniso", -1)
	for node: Node in [quality, screen, client.platform]:
		node.free()
	client.free()


## [b]Every effect this game names was refused once[/b], because `scenes/fx/` did not
## exist, and dot-fx logs a missing scene at DEBUG.
func _test_a_shot_is_drawn() -> void:
	_section("A shot is drawn: a flash at the gun, a spark and a hole where it stopped")
	var missing := ArenaPresentation.fx_catalogue().missing_scenes()
	_check(
		missing.is_empty(),
		"every scene the effect catalogue names is present (missing: %s)" % ", ".join(missing)
	)

	var p := _make()
	var drawn := {}
	p.fx.spawned.connect(func(id: StringName, node: Node, reason: StringName) -> void:
		drawn[id] = node if node != null else reason
	)

	var eye := Vector3(0.0, 1.6, 0.0)
	var aim := Vector3(1.0, 0.0, 0.2).normalized()
	var wall := eye + aim * 10.0
	await _walls_for_a_shot(wall, aim)
	p.present(0.016, eye, aim)
	p.on_used(_outcome(eye, aim, [wall]))

	var flash: Variant = drawn.get(&"muzzle_flash")
	_check(
		flash is Node3D and (flash as Node3D).is_inside_tree(),
		"firing draws a muzzle flash (%s)" % str(flash)
	)
	if flash is Node3D:
		var off: Vector3 = (flash as Node3D).global_position - eye
		_check(
			off.dot(aim) > 0.3 and off.dot(aim) < 1.0 and off.y < 0.0,
			"in front of the eye and below it, not around the camera (%s)" % str(off)
		)
		_check(
			(flash as Node).find_children("*", "CPUParticles3D").size() > 0,
			"and it is particles, not an empty node"
		)
	else:
		_check(false, "in front of the eye and below it, not around the camera")
		_check(false, "and it is particles, not an empty node")

	var spark: Variant = drawn.get(&"impact_spark")
	_check(
		spark is Node3D and (spark as Node3D).global_position.distance_to(wall) < 0.01,
		"the impact draws a spark where the shot stopped (%s)" % str(spark)
	)

	var hole: Variant = drawn.get(&"bullet_hole")
	_check(
		hole is Node3D and (hole as Node3D).global_position.distance_to(wall) < 0.01,
		"and a bullet hole (%s)" % str(hole)
	)
	_check(
		_projects_along(hole, aim),
		"whose decal projects along the shot, so it lands on the wall it hit"
	)

	# Straight up is parallel to the up vector `facing` hands `looking_at`: still the ceiling.
	drawn.clear()
	var up := Vector3.UP
	p.present(0.016, eye, up)
	p.on_used(_outcome(eye, up, [Vector3(0.0, 5.0, 0.0)]))
	_check(
		_projects_along(drawn.get(&"bullet_hole"), up),
		"and a shot straight up puts its hole on the ceiling (%s)" % str(drawn.get(&"bullet_hole"))
	)

	drawn.clear()
	var dead := Transform3D.IDENTITY
	dead.origin = Vector3(3.0, 0.0, 0.0)
	p.present(0.016, eye, aim)
	p.on_died(dead)
	_check(drawn.get(&"death_burst") is Node3D, "and a death bursts (%s)" % str(drawn.get(&"death_burst")))
	var burst: Variant = drawn.get(&"death_burst")
	var chest: Vector3 = (burst as Node3D).global_position + Vector3(0.0, 1.2, 0.0) if burst is Node3D else eye
	_check(chest.distance_to(eye) > 1.0, "the burst is not in the dying player's own lens (%.2f m from the eye)" % chest.distance_to(eye))

	await _check_gore_toggle(p, eye, aim, dead, drawn)

	p.queue_free()
	_done()


func _test_blood() -> void:
	_section("Blood behind a body the server says was hit")
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40, 10, 0.5)
	shape.shape = box
	wall.add_child(shape)
	add_child(wall)
	wall.global_position = Vector3(0, 2, -4)
	var p := _make(false)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var npc := DotEntity.make_id(DotEntity.KIND_NPC, 1)
	var eye := Vector3(0, 1.7, 8)
	var chest := Vector3(0, 1.2, -1)

	_check(p.blood != null and p.blood.decals.blood_count() == 0, "the presentation owns a blood layer, empty")
	_check(p.break_fx != null and p.break_fx.is_in_group(&"arena_break_fx"), "the presentation owns the break effects, found by the panes")
	p.on_body_hit(DotEntity.make_id(DotEntity.KIND_PROP, 3), chest, eye)
	_check(p.blood.decals.blood_count() == 0, "a prop bleeds nothing")
	p.on_body_hit(npc, chest, eye)
	_check(p.blood.decals.blood_count() == 1, "gore on: a hit body splatters the wall behind it (%d)" % p.blood.decals.blood_count())
	p.present(0.016, eye, Vector3.FORWARD)
	p.on_map_changed(&"dm_box")
	_check(p.blood.decals.blood_count() == 0, "a map change clears the blood")

	p.settings.set_value(&"gore", false)
	p.on_body_hit(npc, chest, eye)
	_check(p.blood.decals.blood_count() == 0, "gore off: a hit draws no blood")
	var saved := p.settings.flush()
	var p2 := _make(false)
	_check(saved.ok and not p2.settings.get_bool(&"gore", true), "gore off is persisted and read back")
	_check(not p2.blood.decals.config.gore, "and the next start's blood layer follows it")
	p2.settings.set_value(&"gore", true)
	var _flushed := p2.settings.flush()
	p2.queue_free()
	p.queue_free()
	wall.queue_free()
	_done()
