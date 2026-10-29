extends RefCounted
## The glance flags that stage a player state to look at: --dead, --killcam and --dropped.

const ArenaGame := preload("../game/arena_game.gd")


## Stages the flags given; true when the staging took over the shots (so the caller stops).
static func stage(host: Object, game: ArenaGame, late: Array) -> bool:
	var args := OS.get_cmdline_user_args()
	if args.has("--dead"):
		host._local.make_dead()
	if args.has("--killcam"):
		host._local.make_dead()
		late.append([20, func() -> void: host._play_killview(game, 113)])
	if args.has("--dropped"):
		_dropped(host)
		return true
	return false


## The local player throws the weapon in hand, nobody picks it up, and a close frame is taken once it lies still.
static func _dropped(host: Object) -> void:
	var local = host._local
	var layer: DotWeaponDrops = host._glance_game.weapon_drops
	host._glance_game.weapon_drop_rules.pickup_radius = 0.0
	layer.draws = true
	var thrown: int = layer.throw(local.arsenal, local.muzzle_position(), local.aim_direction(), 112)
	var shot := {"name": "%s_dropped" % String(host._staged_id), "from": local.global_position + Vector3.UP * 2.0, "at": local.global_position, "wait": 100}
	shot["late"] = [[2, func() -> void:
		for entry in layer.snapshot():
			var at: Vector3 = (entry["at"] as Transform3D).origin
			print("dropped weapon ", thrown, " at ", at, " rest ", entry["rest"])
			host._camera.position = at + Vector3(0.5, 0.45, 0.7)
			host._camera.look_at(at, Vector3.UP)
			return]]
	host._shots = [shot]
