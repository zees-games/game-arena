extends DotGameCheckSuite

const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaPlayerTunables := preload("../game/arena_player_tunables.gd")
const ArenaModule := preload("../game/arena_module.gd")
const ArenaMap := preload("../maps/arena_map.gd")

const EXPECTED_CHECKS := 18
const STEP := 1.0 / 60.0

## A server cvar for the wall-run size rules changes whether a run starts beside a 1 m crate:
## the arena's own tunables, the same `_set_rule` path RULES takes, and a class attribute.


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


## Runs an airborne player down a face of height [param top]; true when a wall run started.
func _runs_beside(t: DotFpsTunables, top: float) -> bool:
	var world := DotFpsFlatBody.with_floor(0.0)
	world.add_box(AABB(Vector3(1.0, 0.0, -200.0), Vector3(0.5, top, 200.0)))
	var motor := DotFpsMotor.new(t, world)
	var s := DotFpsState.new()
	s.mode = DotFpsState.Mode.AIR
	s.position = Vector3(1.0 - 0.35 - 0.05, maxf(top - 0.2, 0.3), -2.0)
	s.velocity = Vector3(0.0, 0.0, -12.0)
	s.time_since_grounded = 1.0
	for _i in range(30):
		var c := DotFpsCommand.new()
		c.move = Vector2(0.0, 1.0)
		motor.simulate(s, c, STEP)
	return motor.wall_runs > 0


func _run() -> void:
	var t := ArenaPlayer.arena_tunables()
	_check(t.wall_run_min_height > 0.0 and t.wall_run_min_length > 0.0, "the arena inherits the size rules on")
	_check(_runs_beside(t, 4.0), "a 4 m wall starts a run")
	_check(not _runs_beside(t, 1.0), "a 1 m crate starts none by default")

	for key in ["wall_run_min_height", "wall_run_min_length"]:
		_check(ArenaPlayer.MOVEMENT_RULES.has(key), "%s is a RULES key a client predicts with" % key)
	var cvars := {}
	for cvar: String in ArenaModule.MOVEMENT_CVARS:
		cvars[ArenaModule.MOVEMENT_CVARS[cvar][0]] = cvar
	_check(cvars.get("wall_run_min_height") == "arena_wall_run_min_height"
		and cvars.get("wall_run_min_length") == "arena_wall_run_min_length", "each has its arena_wall_run_* cvar")

	var served := ArenaPlayer.arena_tunables()
	ArenaPlayer._set_rule(served, "wall_run_min_height", 0.0)
	_check(_runs_beside(served, 1.0), "a server cvar of 0 lets the same 1 m crate start a run")
	var tall := ArenaPlayer.arena_tunables()
	ArenaPlayer._set_rule(tall, "wall_run_min_height", 6.0)
	_check(not _runs_beside(tall, 4.0), "a cvar of 6 refuses the 4 m wall that ran by default")
	var short := ArenaPlayer.arena_tunables()
	ArenaPlayer._set_rule(short, "wall_run_min_length", 500.0)
	_check(not _runs_beside(short, 4.0), "a minimum length longer than the wall refuses the run")

	var def := DotPlayerClassDef.new()
	def.attributes = {"wall_run_min_height": 0.0}
	var classed := ArenaPlayer.arena_tunables()
	_check(ArenaPlayerTunables.apply_class_attributes(def, classed) == 1 and _runs_beside(classed, 1.0),
		"a class attribute overrides the height for its players")
	var plain := ArenaPlayer.arena_tunables()
	ArenaPlayerTunables.apply_class_attributes(DotPlayerClassDef.new(), plain)
	_check(plain.wall_run_min_height == t.wall_run_min_height, "a class that sets none keeps the server's value")

	var tall_def := DotPlayerClassDef.new()
	tall_def.attributes = {"look_down_back": 0.8}
	_check(is_equal_approx(ArenaPlayer.look_down_back_of(tall_def), 0.8) and is_equal_approx(ArenaPlayer.look_down_back_of(DotPlayerClassDef.new()), 0.45),
		"a class profile sets how far the own body trails back looking down; none keeps the default")

	var st := DotFpsState.new()
	st.velocity = Vector3(3.0, 0.0, -5.0)
	_check(is_equal_approx(ArenaPlayer.wall_shot_strafe(st), 3.0), "the wall shot's strafe is the sideways speed, right positive")
	st.yaw = 90.0
	st.velocity = Vector3(0.0, 0.0, -4.0)
	_check(is_equal_approx(ArenaPlayer.wall_shot_strafe(st), 4.0), "it follows the aim yaw, not the world axes")
	st.wall_run_time = 0.5
	_check(ArenaPlayer.wall_shot_strafe(st) == 0.0, "it is zero while wall-running")

	await _test_clip_hulls()
	_report(EXPECTED_CHECKS)


## A player-clip hull of the legacy collision blob stops a body but not a shot.
func _test_clip_hulls() -> void:
	var id := &"aim-forts"
	if not ArenaMap.imported_ids().has(id):
		for _i in 3:
			_check(true, "skipped without the imported map")
		return
	var root := ArenaMap.by_id(id).to_collision()
	add_child(root)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var clip := root.get_node_or_null("ImportedClip") as StaticBody3D
	_check(clip != null and clip.get_child_count() > 0, "the legacy clip hulls sit in their own body")
	if clip == null or clip.get_child_count() == 0:
		_check(false, "a body is blocked by a clip hull")
		_check(false, "a shot passes a clip hull")
		root.free()
		return
	var layout := DotPhysicsLayout.shooter_3d()
	var pts := ((clip.get_child(0) as CollisionShape3D).shape as ConvexPolygonShape3D).points
	var mid := Vector3.ZERO
	for q in pts:
		mid += q
	mid /= float(pts.size())
	var space := get_viewport().world_3d.direct_space_state
	var from := mid + Vector3(0.0, 40.0, 0.0)
	var to := mid - Vector3(0.0, 40.0, 0.0)
	var stop := PhysicsRayQueryParameters3D.create(from, to, layout.mask_of([&"player_clip"]))
	var body_hit := space.intersect_ray(stop)
	_check(not body_hit.is_empty() and body_hit["collider"] == clip, "a body (player_clip mask) is blocked by a clip hull")
	var shot := PhysicsRayQueryParameters3D.create(from, to, layout.mask_of([&"world", &"prop"] as Array[StringName]))
	var shot_hit := space.intersect_ray(shot)
	_check(shot_hit.is_empty() or shot_hit["collider"] != clip, "a shot (world mask) passes the same clip hull")
	root.free()
