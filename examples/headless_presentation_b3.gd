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
	var uncovered: Array[String] = []
	for id in cat.ids():
		# dot-audio's stock footsteps and beds are files the addon ships: no stand-in needed.
		# Nor are the ambience moods' files, which DotAmbience registers when a mood starts.
		if not recipes.has(id) and not DotAudioStock.ids().has(id) and not String(id).begins_with("shot_") and not String(id).begins_with(DotAmbience.ID_PREFIX):
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

	# The bank is what the real sink would be given. Baking it here is the only place a
	# headless run can tell "the game would make a noise" from "the game has a table".
	var bank := DotAudioSynth.bank(cat, recipes)
	_check(
		bank.has(&"fire_rifle") and bank.has("res://audio/fire_rifle.ogg"),
		"the bank answers under both the id and the path the def names"
	)
	_check(
		(
			(bank[&"fire_rail"] as AudioStreamWAV).data
			!= (bank[&"fire_rifle"] as AudioStreamWAV).data
		),
		"and a rail is a different noise from a rifle, not a quieter one"
	)

	# Baked a few recipes a frame under the loading cover, never as one 0.7 s frame: the
	# sliced bank must hold exactly what the one-shot bank does, in many short calls.
	var sliced := {}
	var queue: Array = recipes.keys()
	var calls := 0
	var longest := 0
	while not queue.is_empty() and calls < 10000:
		var t0 := Time.get_ticks_msec()
		ArenaPresentation.bake_into(sliced, cat, recipes, queue, 1)
		longest = maxi(longest, Time.get_ticks_msec() - t0)
		calls += 1
	_check(sliced.keys().size() == bank.keys().size() and sliced.has(&"fire_rifle"),
		"the sound bank baked in slices holds what the one-shot bank does (%d of %d)" % [sliced.size(), bank.size()])
	_check(calls > 4 and longest < 250,
		"and it took %d calls, none over 250 ms (longest %d ms)" % [calls, longest])

	p.queue_free()
	_audio_firefight_rest()


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

	p.queue_free()
	_done()


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


## A dead body falls as the server said: the death rides the KILL, the client builds a ragdoll from
## the figure it draws, the body lies on the floor rather than through it.
func _test_bodies_fall() -> void:
	_section("A dead body falls the way the server picked, and gets up on respawn")

	var g := ArenaGame.new()
	g.is_authority = true
	add_child(g)
	var _set := g.setup(ArenaMap.dm_box())
	var dmg := DotDamage.new()
	dmg.attacker = 3
	dmg.weapon_id = AwWeaponIds.SNIPER
	dmg.amount = 120.0
	dmg.direction = Vector3(0, 0, -1)
	var plain := g.decide_death(9, dmg)
	_check(plain.reaction != &"power_launch", "by default a sniper kill does not launch (%s)" % plain.reaction)
	g.ragdoll_rules.set_cvar("sv_ragdoll_exaggerate", "1")
	var sniped := g.decide_death(9, dmg)
	_check(sniped.reaction == &"power_launch", "with sv_ragdoll_exaggerate a sniper kill is a power launch (%s)" % sniped.reaction)
	g.ragdoll_rules.set_cvar("sv_ragdoll_exaggerate", "0")
	dmg.weapon_id = AwWeaponIds.PISTOL
	var counted := {}
	for tick in range(200):
		g._tick = tick
		var d := g.decide_death(9, dmg)
		counted[d.reaction] = int(counted.get(d.reaction, 0)) + 1
	_check(not counted.has(&"power_launch") and not counted.has(&"headshot_launch") and counted.size() >= 2,
		"a pistol body shot never launches, and is not always the same fall (%s)" % str(counted))
	g.ragdoll_rules.set_cvar("sv_ragdoll_reactions", "limp=0,crumple=0,face_plant=1")
	_check(g.decide_death(9, dmg).reaction == &"face_plant", "sv_ragdoll_reactions reweights the server's pick")
	g.ragdoll_rules.set_cvar("sv_ragdoll_reactions", "")

	# The wire: the death rides KILL, and an older kill still reads.
	var wrote := ArenaEvents.write_kill(3, 9, "sniper", false, true, sniped)
	var read := ArenaEvents.read_kill(DotNetReader.new(wrote))
	var back := DotPlayerDeath.from_dict(read)
	_check(bool(read["ok"]) and bool(read["critical"]) and back.reaction == sniped.reaction
		and back.roll_seed == sniped.roll_seed and absf(back.damage - 120.0) < 0.5
		and back.direction.distance_to(sniped.direction) < 0.02,
		"the KILL carries the reaction, the seed, the damage and the direction (%d bytes)" % wrote.size())
	var old := ArenaEvents.read_kill(DotNetReader.new(ArenaEvents.write_kill(3, 9, "pistol", true, false)))
	_check(bool(old["ok"]) and not old.has("death_reaction") and DotPlayerDeath.from_dict(old).reaction == &"limp",
		"a KILL without one reads as a plain fall")

	# The client's half, on a floor in a physics world.
	var floor_body := _test_floor()
	var yard := DotPlayerRagdolls.new()
	add_child(yard)

	var player := ArenaPlayer.new()
	player.setup(ArenaPlayer.Mode.HEADLESS, ArenaMap.dm_box(), 6, "Faller")
	add_child(player)
	# Away from the origin: the game above keeps a collision copy of the level there.
	player.spawn(Transform3D(Basis(), Vector3(20.0, 0.0, 20.0)), 0)
	player.attach_body_mesh(Color.WHITE, ArenaAvatars.stock_avatar(&"faller"))
	player.present(0.016)
	player.make_dead()
	var fall := DotPlayerDeath.new()
	fall.reaction = &"limp"
	fall.direction = Vector3(1, 0, 0)
	fall.damage = 80.0
	var gun_mesh := BoxMesh.new()
	var gun_node := MeshInstance3D.new()
	gun_node.mesh = gun_mesh
	player.held = AwWorldModel.new()
	player.held.add_child(gun_node)
	player.body_mesh.add_child(player.held)
	var body := player.fall_body(yard, fall, false)
	var gun_in_ragdoll := false
	if body != null:
		for m in body.find_children("*", "MeshInstance3D", true, false):
			gun_in_ragdoll = gun_in_ragdoll or (m as MeshInstance3D).mesh == gun_mesh
	_check(not gun_in_ragdoll and not player.held.visible,
		"the held gun is not copied into the falling body (it would stay on end in the hand)")
	player.body_mesh.remove_child(player.held)
	player.held.free()
	player.held = null
	_check(body != null and body.style == DotPlayerRagdollRules.Style.RAGDOLL and body.part_count() == 6,
		"the stock avatar falls as a six-part ragdoll (%s)" % (str(body.describe()) if body != null else "none"))
	_check(not player.body_mesh.visible, "and the standing figure is hidden")
	var waited := 0.0
	while waited < 8.0 and not body.settled:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	_check(body.settled and body.centre().y < 0.6 and body.lowest_point() > -0.12,
		"it lies on the floor and stops (torso %.2f m, lowest %.2f m, %.1f s)" % [body.centre().y, body.lowest_point(), waited])
	player.health.alive = true
	player.present(0.016)
	_check(player.body_mesh.visible, "a respawn draws the figure again")

	yard.rules.enabled = false
	player.make_dead()
	var toppled := player.fall_body(yard, fall)
	_check(toppled != null and toppled.style == DotPlayerRagdollRules.Style.TOPPLE, "sv_ragdoll 0: a topple, no physics")
	player.health.alive = true
	player.present(0.016)
	yard.rules.style = DotPlayerRagdollRules.Style.HIDE
	player.make_dead()
	_check(player.fall_body(yard, fall) == null and not player.body_mesh.visible,
		"sv_ragdoll_style hide: nothing, and the figure gone")

	var client := ArenaClient.new()
	client.game = g
	client._build_ragdolls()
	# The client is not in the tree here (its _ready builds a whole game); its yard has to be.
	client.remove_child(client.ragdolls)
	add_child(client.ragdolls)
	var added: DotResult = g.add_player(11, "Eleven")
	var eleven: ArenaPlayer = added.value if added.ok else null
	eleven.attach_body_mesh(Color.WHITE, ArenaAvatars.stock_avatar(&"eleven"))
	eleven.make_dead()
	var entry := DotKillFeed.Entry.new()
	entry.victim_key = "11"
	entry.set_meta(&"death", fall)
	_test_bodies_fall_rest(g, floor_body, yard, player, client, entry)


func _test_bodies_fall_rest(g: ArenaGame, floor_body: StaticBody3D, yard: DotPlayerRagdolls, player: ArenaPlayer, client: ArenaClient, entry: DotKillFeed.Entry) -> void:
	client._on_solo_kill(entry)
	_check(client.ragdolls.live().size() == 1, "solo, a kill's entry carries the fall and the client draws it")
	_check(client.ragdolls.rules == g.ragdoll_rules, "and it draws under the game's (the server's) rules")

	client.ragdolls.queue_free()
	client.free()
	yard.queue_free()
	player.queue_free()
	floor_body.queue_free()
	g.queue_free()
	_done()


## The family's rule since the first play test: M opens the maps and the modes, and solo a choice
## changes now. A whole offline client, because the change rebuilds its level.
func _test_the_map_menu() -> void:
	_section("M opens the maps and the modes, and solo a choice changes the map")
	var client := ArenaClient.new()
	client.force_offline = true
	add_child(client)
	for _i in 6:
		await get_tree().process_frame
	var menu: DotMenu = client.game_menu
	var keys: DotMenuBindings = menu.bindings if menu != null else null
	_check(keys != null and keys.key_for(DotMenuBindings.MAPS_ACTION) == "M" and keys.defaults_on("M").size() == 1,
		"the map menu is on M, and nothing else in the table is",
		str(keys.defaults_on("M").map(func(r: Dictionary) -> String: return str(r["label"]))) if keys != null else "no menu")
	var rows := client.map_menu_rows()
	_check(rows.filter(func(r: Dictionary) -> bool: return str(r["id"]).begins_with("map:")).size() > 1
		and rows.any(func(r: Dictionary) -> bool: return str(r["id"]).begins_with("mode:")),
		"it lists more than one map, and the modes this map can host", str(rows.map(func(r: Dictionary) -> String: return str(r["id"]))))
	menu.close_all()
	_check(menu.handle_event(_key_press(KEY_M)) and menu.picker.is_open(), "M opens the picker")
	var tabbed: bool = menu.maps.has_tabs() and keys.key_for(DotMenuBindings.MODES_ACTION) == "Minus"
	var _tab1 := menu.handle_event(_key_press(KEY_MINUS))
	var on_modes: bool = menu.picker.items.size() > 0 and menu.picker.items.all(func(r: Dictionary) -> bool: return str(r["id"]).begins_with("mode:"))
	var _tab2 := menu.handle_event(_key_press(KEY_MINUS))
	_check(tabbed and on_modes and menu.picker.items.all(func(r: Dictionary) -> bool: return str(r["id"]).begins_with("map:")),
		"the picker has a Maps and a Game modes tab, switched by - (rebindable), maps first")
	var wanted := &""
	var key := KEY_NONE
	for row in range(1, DotMenuPicker.PAGE_SIZE + 1):
		var it: Variant = menu.picker.at_row(row)
		if it is Dictionary and str((it as Dictionary)["id"]).begins_with("map:") and not bool((it as Dictionary)["current"]):
			wanted = StringName(str((it as Dictionary)["id"]).substr(4))
			key = KEY_0 + row
			break
	var _k := menu.handle_event(_key_press(key))
	for _i in 4:
		await get_tree().physics_frame
	_check(wanted != &"" and client.game.map.id == wanted and client._level != null and is_instance_valid(client._level),
		"choosing a map changes to it now, and the level is rebuilt", "%s, now %s" % [wanted, client.game.map.id])
	var mode_id := &""
	for r: Dictionary in client.map_menu_rows():
		if str(r["id"]).begins_with("mode:") and not bool(r["current"]):
			mode_id = StringName(str(r["id"]).substr(5))
			break
	var changed := await client.change_from_menu(StringName("mode:%s" % mode_id))
	_check(changed.ok and client.game.mode.id == mode_id and client.game.map.id == wanted,
		"and a mode changes on the same map", "%s: %s" % [mode_id, changed.error.message if not changed.ok else "ok"])
	# The Tab board draws dot-match's records, not whatever the roster says: the client builds it
	# before the match node is in the tree.
	var present := client.game.match_node.scoreboard.present_count()
	menu.close_all()
	menu.scoreboard.open()
	_check(present >= 1 and menu.scoreboard.rows().size() == present and menu.scoreboard.rows().all(func(r: Dictionary) -> bool: return r.has("kills")),
		"the Tab board lists every record with its kills", "%d rows, %d present" % [menu.scoreboard.rows().size(), present])
	menu.scoreboard.close()
	# The summary board comes up with nobody holding Tab, so the next match closes it.
	client._on_match({"state": DotMatch.State.MATCH_END, "round": 1, "remaining_ticks": 0})
	var revealed: bool = client.winner_reveal != null and client.winner_reveal.is_active()
	if client.killcam != null:
		client.killcam.skip()
	if client.winner_reveal != null:
		client.winner_reveal.skip()
	_check(revealed and menu.scoreboard.is_open(), "the end of the match reveals the winner, then raises the board by itself")
	# A parse error in the client script (a misplaced line in one function) leaves no killcam, podium or board at all.
	var script := load("res://game/arena_client.gd") as GDScript
	_check(script != null and script.can_instantiate(), "the client script parses, so the end-of-match flow exists at all")
	_check(client.winner_reveal != null and client.killcam != null, "the killcam is built at start and the podium by the first match end")
	client._on_match({"state": DotMatch.State.WARMUP, "round": 2, "remaining_ticks": 0})
	_check(not menu.scoreboard.is_open(), "and the next match takes it down again")
	# Overlapping screens that each restore "what they found" left the HUD hidden for good.
	client.hud.visible = false
	client._restore_hud_if_orphaned()
	_check(client.hud.visible, "a HUD left hidden with no killview, killcam or reveal up comes back")
	client.hud.visible = false
	client._reveal_hid[client.hud] = true
	client._restore_hud_if_orphaned()
	_check(not client.hud.visible, "and a HUD hidden by a screen that is up stays hidden")
	client._reveal_hid.clear()
	client.hud.visible = true
	remove_child(client)
	await _check_map_menu_tail(client)


func _check_map_menu_tail(client: ArenaClient) -> void:
	client.free()
	await get_tree().process_frame
	_done()


func _test_floor() -> StaticBody3D:
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 1, 60)
	shape.shape = box
	shape.position = Vector3(0, -0.5, 0)
	floor_body.add_child(shape)
	add_child(floor_body)
	return floor_body


func _key_press(key: Key) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = key
	e.keycode = key
	e.pressed = true
	return e


func _test_feedback_from_the_wire() -> void:
	_section("The server's hits and medals become a hit marker, numbers, medals and points")
	var M := ArenaAwards.Medal

	var g := ArenaGame.new()
	g.is_authority = true
	g.headless = true
	g.register_service = false
	add_child(g)
	var _set := g.setup(ArenaMap.dm_box())
	var me: ArenaPlayer = g.add_player(6, "Broken").value
	var them: ArenaPlayer = g.add_player(7, "Victim").value

	var hud := ArenaHud.new()
	hud.config = DotUiConfig.new()
	add_child(hud)
	hud.build(null)
	hud.follow(me)

	var client := ArenaClient.new()
	client.game = g
	client.player = me
	client.hud = hud

	var at := them.global_position + Vector3(0.0, 1.4, 0.0)
	client._on_hit(ArenaEvents.read_hit(DotNetReader.new(ArenaEvents.write_hit(7, 34.0, at, false, false))))
	_check(hud.hit_marker.alpha() > 0.9 and not hud.hit_marker.kill, "a HIT flashes the hit marker, white")
	_check(hud.damage_numbers.entries.size() == 1 and int(hud.damage_numbers.entries[0]["amount"]) == 34,
		"and a number rises from where it landed, saying what it took")
	client._on_hit(ArenaEvents.read_hit(DotNetReader.new(ArenaEvents.write_hit(7, 20.0, at, false, false))))
	_check(hud.damage_numbers.entries.size() == 1 and int(hud.damage_numbers.entries[0]["amount"]) == 54,
		"a second hit on them straight after adds into the same number (%s)" % [hud.damage_numbers.entries.map(func(e: Dictionary) -> int: return int(e["amount"]))])
	client._on_hit(ArenaEvents.read_hit(DotNetReader.new(ArenaEvents.write_hit(7, 80.0, at, true, true))))
	_check(hud.hit_marker.kill and bool(hud.damage_numbers.entries[0]["headshot"]),
		"a lethal hit to the head turns the marker red and the number gold")
	hud.hit_marker.advance(1.0)
	hud.damage_numbers.advance(1.0)
	_check(hud.hit_marker.alpha() == 0.0 and hud.damage_numbers.entries.is_empty(), "and both are gone within a second")

	var award := ArenaEvents.read_award(DotNetReader.new(
		ArenaEvents.write_award(6, 7, ArenaAwards.points_for([M.FIRST_BLOOD, M.HEADSHOT]), 4, [M.FIRST_BLOOD, M.HEADSHOT])
	))
	client._on_award(award)
	var texts: Array = []
	for entry in hud._popups:
		for label in (entry[0] as Control).get_children():
			texts.append((label as Label).text)
	_check(texts == ["+175", "Victim"], "an AWARD for your kill puts \"+points  Victim\" by the crosshair (%s)" % [texts])
	_check(hud.medal_row.shown.size() == 2 and float(hud.medal_row.shown[1]["age"]) < 0.0,
		"and its medals, the second waiting its turn")
	hud.medal_row.advance(0.3)
	_check(hud.medal_row.labels() == PackedStringArray(["First Blood", "Headshot"]) and float(hud.medal_row.shown[1]["age"]) > 0.0,
		"then both, by name, in the order the server sent them")
	hud.present_body()
	_check(hud.vitals.streak == 4, "the streak row takes the server's streak (%d)" % hud.vitals.streak)
	hud.medal_row.advance(3.5)
	_check(hud.medal_row.shown.is_empty(), "and the medals fade out after a couple of seconds")

	client._on_award({"killer_id": 7, "victim_id": 6, "medals": [M.HEADSHOT], "points": 125, "streak": 1})
	hud.medal_row.advance(0.3)
	_check(hud.medal_row.shown.is_empty() and hud._popups.size() == 1, "somebody else's medals are not drawn on your screen")

	var catalogue := ArenaPresentation.sound_catalogue()
	var recipes := ArenaPresentation.sound_recipes()
	var unheard: Array = []
	for medal in ArenaAwards.MEDALS:
		var id := ArenaAwards.medal_sound(int(medal))
		if catalogue.find(id) == null or not recipes.has(id):
			unheard.append(String(id))
	_check(unheard.is_empty() and catalogue.find(ArenaPresentation.KILL_CONFIRMED) != null,
		"every medal and the kill confirmation is a sound with a stand-in (%s)" % [unheard])

	client.free()
	hud.queue_free()
	g.queue_free()
	_done()


func _test_blind_and_beacon() -> void:
	_section("An admin's beacon is drawn and heard, and a blind darkens one screen")

	var p := _make()
	var sink := p.audio.sink as DotAudioSinkNull

	var def := p.audio.catalogue.find(ArenaPresentation.BEACON_SOUND)
	_check(
		def != null and def.kind == DotAudioDef.Kind.POSITIONAL_3D and def.max_distance >= 90.0,
		"the ping is positional and carries at least as far as a shot",
		"a beacon's job is to say where somebody is"
	)
	sink.forget()
	_check(p.on_beacon(Vector3(4.0, 0.0, 2.0)) != 0 and sink.count_of(ArenaPresentation.BEACON_SOUND) == 1,
		"and it plays where the beacon is")

	var player := ArenaPlayer.new()
	player.setup(ArenaPlayer.Mode.HEADLESS, ArenaMap.dm_box(), 5, "Marked")
	add_child(player)
	player.spawn(Transform3D(Basis(), Vector3(0.0, 0.05, 18.0)), 0)

	var pings: Array[Vector3] = []
	player.beacon_pulsed.connect(func(at: Vector3) -> void: pings.append(at))

	player.present(0.016)
	_check(player.beacon_marker == null and pings.is_empty(), "no beacon, no marker and no ping")

	player.beacon = true
	player.present(0.016)
	_check(
		player.beacon_marker != null and pings.size() == 1,
		"switched on, it is drawn and pings at once rather than a second later"
	)
	for _i in range(30):
		player.present(0.016)
	_check(pings.size() == 1, "and not again inside the same second (%d pings)" % pings.size())
	for _i in range(40):
		player.present(0.016)
	_check(pings.size() == 2, "then once a second (%d pings in 1.1 s)" % pings.size())
	_check(
		pings[1].distance_to(player.controller.state.position) < 0.01,
		"from where the player is"
	)

	player.make_dead()
	player.present(0.016)
	_check(player.beacon_marker == null, "a dead player's beacon is not drawn over the corpse")

	player.health.alive = true
	player.beacon = false
	player.present(0.016)
	_check(player.beacon_marker == null, "and switched off, the marker goes")

	var hud := ArenaHud.new()
	hud.config = DotUiConfig.new()
	add_child(hud)
	hud.build(null)
	hud.follow(player)

	_check(
		hud.blind_overlay != null and hud.blind_overlay.get_index() == 0
			and not hud.blind_overlay.visible,
		"the blind is under every HUD widget, and off"
	)
	player.blinded = true
	hud.present_blind(ArenaHud.BLIND_FADE_SEC * 0.5)
	_check(
		hud.blind_overlay.visible and hud.blind_overlay.modulate.a > 0.4
			and hud.blind_overlay.modulate.a < 0.6,
		"blinded, it fades in rather than cutting (%.2f half way)" % hud.blind_overlay.modulate.a
	)
	hud.present_blind(1.0)
	# The whole viewport, not the HUD's rect: `DotHud` insets itself by the safe area and the first rendered
	# blind left a frame of the world round the edge. This is the one layout check a 64 x 64 headless
	# viewport can still answer, because the inset is the same sixteen pixels there.
	_check(
		hud.blind_overlay.get_global_rect().is_equal_approx(hud.get_viewport_rect()),
		"and covers the whole screen, not the safe area the HUD sits in",
		"%s against %s" % [hud.blind_overlay.get_global_rect(), hud.get_viewport_rect()]
	)
	player.blinded = false
	hud.present_blind(1.0)
	_check(not hud.blind_overlay.visible, "and lifted, it is gone")

	hud.queue_free()
	player.queue_free()
	p.queue_free()
	_done()
