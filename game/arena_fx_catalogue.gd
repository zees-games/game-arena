extends RefCounted
## The arena's effect catalogue, split from ArenaPresentation for length.

static func make(fx_dir: String, explosion_id: StringName) -> DotFxCatalogue:
	var c := DotFxCatalogue.new()

	var muzzle := _scene(fx_dir, &"muzzle_flash", "muzzle_flash", 90, 1, 85, 90.0)
	muzzle.max_concurrent = 8
	c.add(muzzle)
	# The expensive half of a firefight, and the first thing a low tier should not have.
	c.add(_scene(fx_dir, &"impact_spark", "impact_spark", 500, 2, 45, 60.0, 1))
	c.add(_scene(fx_dir, &"stomp_puff", "impact_spark", 500, 2, 80, 80.0))
	# Ten minutes; the ring is what bounds the count.
	var hole := _scene(fx_dir, &"bullet_hole", "bullet_hole", 600000, 1, 20, 50.0, 1)
	hole.kind = DotFxDef.Kind.DECAL
	c.add(hole)
	c.add(_scene(fx_dir, &"death_burst", "death_burst", 1500, 12, 70, 80.0, 2))
	# Drawn at every quality and above all but the hurt flash: where something went off is information.
	c.add(_scene(fx_dir, explosion_id, "explosion", 1400, 10, 85, 140.0))

	var hurt := DotFxDef.new()
	hurt.id = &"hurt_flash"
	hurt.kind = DotFxDef.Kind.SCREEN
	# Low, and still behind the player's off switch and the rate limit: a fast full-screen flash is a hazard.
	hurt.flash_peak = 0.28
	hurt.flash_colour = Color(0.85, 0.12, 0.12)
	hurt.flash_decay_ms = 260
	c.add(hurt)

	AwGrenadeFx.add_defs(c)

	var shake := DotFxDef.new()
	shake.id = &"hurt_shake"
	shake.kind = DotFxDef.Kind.SHAKE
	shake.shake_trauma = 0.35
	c.add(shake)

	var big_shake := DotFxDef.new()
	big_shake.id = &"death_shake"
	big_shake.kind = DotFxDef.Kind.SHAKE
	big_shake.shake_trauma = 0.7
	c.add(big_shake)

	return c


static func _scene(fx_dir: String, id: StringName, scene: String, lifetime_ms: int, cost: int, priority: int, max_distance: float, min_quality: int = 0) -> DotFxDef:
	var d := DotFxDef.new()
	d.id = id
	d.scene_path = "%s/%s.tscn" % [fx_dir, scene]
	d.lifetime_ms = lifetime_ms
	d.cost = cost
	d.priority = priority
	d.max_distance = max_distance
	d.min_quality = min_quality
	return d
