extends RefCounted
## The glance flags that stage a player state to look at: --dead, --killcam and --dropped.

const ArenaGame := preload("../game/arena_game.gd")
const ArenaPlayer := preload("../game/arena_player.gd")


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


## `--glance --flashlight`: the map gone dark and the local player's flashlight on, to look at the beam.
static func stage_flashlight(local: ArenaPlayer, game: ArenaGame) -> void:
	for node in local.get_tree().root.find_children("*", "WorldEnvironment", true, false):
		var env := (node as WorldEnvironment).environment
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.01, 0.01, 0.02)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.02, 0.02, 0.03)
		env.ambient_light_energy = 1.0
	for node in local.get_tree().root.find_children("*", "DirectionalLight3D", true, false):
		(node as DirectionalLight3D).visible = false
	var beam := DotFlashlight.new()
	beam.name = "Flashlight"
	beam.config = game.flashlight_conf()
	beam.handle_input = false
	beam.authoritative = false
	local.camera.add_child(beam)
	beam.apply_state({"on": true})


## The glance shot's file name: the staged map, the mode, then one suffix per flag given.
static func shot_name(host: Object, game: ArenaGame, args: PackedStringArray, streak_at: int) -> String:
	var parts: Array[String] = [String(host._staged_id), "glance", String(game.mode_id)]
	if host._glance_ballot:
		parts.append("mapballot" if host._glance_map_ballot else "ballot")
	for flag in ["chat"]:
		if host._glance_chat:
			parts.append(flag)
	if args.has("--low"):
		parts.append("low")
	if streak_at >= 0:
		parts.append("streak")
	if OS.get_cmdline_user_args().has("--killcam"):
		parts.append("killcam")
	if host._glance_theme != "":
		parts.append(host._glance_theme)
	return "_".join(parts)
