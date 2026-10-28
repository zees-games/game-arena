extends RefCounted
## The arena's effect catalogue, split from ArenaPresentation for length.

static func make(fx_dir: String, explosion_id: StringName) -> DotFxCatalogue:
	var c := DotFxCatalogue.new()

	var muzzle := DotFxDef.new()
	muzzle.id = &"muzzle_flash"
	muzzle.scene_path = "%s/muzzle_flash.tscn" % fx_dir
	muzzle.lifetime_ms = 90
	muzzle.cost = 1
	muzzle.priority = 85
	muzzle.max_distance = 90.0
	muzzle.max_concurrent = 8
	c.add(muzzle)

	var spark := DotFxDef.new()
	spark.id = &"impact_spark"
	spark.scene_path = "%s/impact_spark.tscn" % fx_dir
	spark.lifetime_ms = 500
	spark.cost = 2
	spark.priority = 45
	spark.max_distance = 60.0
	# The expensive half of a firefight, and the first thing a low tier should not have.
	spark.min_quality = 1
	c.add(spark)

	var hole := DotFxDef.new()
	hole.id = &"bullet_hole"
	hole.kind = DotFxDef.Kind.DECAL
	hole.scene_path = "%s/bullet_hole.tscn" % fx_dir
	# Ten minutes; the ring is what bounds the count.
	hole.lifetime_ms = 600000
	hole.cost = 1
	hole.priority = 20
	hole.max_distance = 50.0
	hole.min_quality = 1
	c.add(hole)

	var gib := DotFxDef.new()
	gib.id = &"death_burst"
	gib.scene_path = "%s/death_burst.tscn" % fx_dir
	gib.lifetime_ms = 1500
	gib.cost = 12
	gib.priority = 70
	gib.max_distance = 80.0
	gib.min_quality = 2
	c.add(gib)

	# Drawn at every quality and above all but the hurt flash: where something went off is
	# information. Not the death burst's scene, which reads as somebody dying there.
	var boom := DotFxDef.new()
	boom.id = explosion_id
	boom.scene_path = "%s/explosion.tscn" % fx_dir
	boom.lifetime_ms = 1400
	boom.cost = 10
	boom.priority = 85
	boom.max_distance = 140.0
	c.add(boom)

	var hurt := DotFxDef.new()
	hurt.id = &"hurt_flash"
	hurt.kind = DotFxDef.Kind.SCREEN
	# Low, and still behind the player's off switch and the rate limit: a fast full-screen flash is a hazard.
	hurt.flash_peak = 0.28
	hurt.flash_colour = Color(0.85, 0.12, 0.12)
	hurt.flash_decay_ms = 260
	c.add(hurt)

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
