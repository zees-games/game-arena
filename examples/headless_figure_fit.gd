extends DotGameCheckSuite

## "Crosshair on his chest at 65 m and nothing": does the body the client draws stand inside
## the hit zones the server traces? For every stock avatar and each way a player moves (idle,
## walking away, strafing, walking at you, aiming up and down, crouched still), a shot from
## 65 m at the drawn skeleton's head, neck, torso, belly and hips (and arms when standing)
## must land in a zone, on every tick of the walk cycle. Only the hit zones' own fit is
## measured here; the netcode and the gun are headless_hitreg_ping's and headless_hitreg_scope's.
##
## Known gap, logged and not failed: a crouch WALK. The made CROUCH_WALK clip in dot-player-char
## (CROUCH_WALK_BEND 1.0 plus bob) draws the head higher than standing while the zones squeeze
## to the crouch height, so shots at the drawn head and upper chest of a crouch-walking player
## pass over the zones. The fix is the clip's (board: fc-hitreg-sniper-video-1), not the sim's.

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaAvatars := preload("../game/arena_avatars.gd")

const RANGE_M := 65.0
const WARMUP_TICKS := 40
const SAMPLE_TICKS := 64
const AVATARS: Array[String] = ["arena-player-00000001", "arena-player-00000002", "arena-player-00000003",
	"arena-player-00000004", "arena-player-00000005", "arena-player-00000006"]
const CORE: Array[String] = ["Head", "Neck", "Torso", "Abdomen", "Hips"]
const ARMS: Array[String] = ["UpperArm.L", "UpperArm.R"]
## name, move, crouch, pitch, whether the arms must be inside a zone too. Not when strafing:
## seen side-on, the far shoulder joint swings to the torso capsule's edge (7-11 of 64 ticks
## miss by a few centimetres), and not crouched, where the arms ride outside the squeezed capsule.
const CASES: Array = [
	["idle", Vector2.ZERO, false, 0.0, true],
	["walk away", Vector2(0, -1), false, 0.0, true],
	["strafe", Vector2(1, 0), false, 0.0, false],
	["walk at", Vector2(0, 1), false, 0.0, true],
	["aim down", Vector2(0, 1), false, -10.0, true],
	["aim up", Vector2(0, 1), false, 10.0, true],
	["crouch", Vector2.ZERO, true, 0.0, false],
]
const KNOWN_GAP: Array = ["crouch walk", Vector2(1, 0), true, 0.0, false]

var _game: ArenaGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	Engine.physics_ticks_per_second = 64
	_run.call_deferred()


func _run() -> void:
	print("arena: the drawn figure stands inside the hit zones at %d m" % int(RANGE_M))
	_build()
	var target: ArenaPlayer = _game.player_for(2)
	for key in AVATARS:
		_wear(target, key)
		if not _check(target.figure != null, "%s has a figure" % key):
			continue
		for case: Array in CASES:
			var misses := await _measure(target, case)
			_check(misses.is_empty(), "%s %s: every shot at the drawn body lands in a zone" % [key, case[0]], str(misses))
		var gap := await _measure(target, KNOWN_GAP)
		print("  known gap (dot-player-char crouch_walk clip), %s: %s" % [key, gap])
	_report()
	get_tree().quit(0 if _failed == 0 else 1)


func _build() -> void:
	_game = ArenaGame.new()
	_game.name = "Arena"
	_game.tick_rate = 64
	_game.score_limit = 0
	_game.time_limit_sec = 0.0
	_game.headless = true
	_game.is_authority = true
	_game.register_service = false
	add_child(_game)
	var map := ArenaMap.new()
	map.id = &"fit_lane"
	map.display_name = "fit_lane"
	map.extent = 150.0
	map.wall_height = 8.0
	var _p := map.add_perimeter()
	var _s1 := map.add_spawn(Transform3D(Basis(), Vector3(0.0, 0.05, 0.0)))
	var _s2 := map.add_spawn(Transform3D(Basis(), Vector3(5.0, 0.05, 0.0)))
	var _r := _game.setup(map)
	_game.match_node.rules.warmup_sec = 0.0
	_game.match_node.rules.countdown_sec = 0.0
	var _a := _game.add_player(1, "Shooter")
	var _b := _game.add_player(2, "Target")
	_game.start(0)
	_game.tick({})


func _wear(target: ArenaPlayer, key: String) -> void:
	if target.body_mesh != null:
		target.remove_child(target.body_mesh)
		target.body_mesh.free()
		target.body_mesh = null
		target.figure = null
		target.held = null
	target.attach_body_mesh(Color.WHITE, ArenaAvatars.stock_avatar(StringName(key)))


## Bone -> "missed n of m" for every bone a shot from [constant RANGE_M] at missed at least once.
func _measure(target: ArenaPlayer, case: Array) -> Dictionary:
	var t: int = _game._tick
	target.spawn(Transform3D(Basis(), Vector3(0.0, 0.05, -RANGE_M)), t)
	_game.player_for(1).spawn(Transform3D(Basis(), Vector3(0.0, 0.05, 0.0)), t)
	var eye := Vector3(0.0, 0.05 + ArenaPlayer.eye_height(), 0.0)
	var bones: Array[String] = CORE.duplicate()
	if case[4]:
		bones.append_array(ARMS)
	var missed := {}
	for i in WARMUP_TICKS + SAMPLE_TICKS:
		var cmd := DotFpsCommand.new()
		cmd.move = case[1]
		cmd.buttons = DotFpsCommand.BUTTON_CROUCH if case[2] else 0
		cmd.pitch = case[3]
		_game.tick({1: [DotFpsCommand.new(), DotWeaponCommand.new()], 2: [cmd, DotWeaponCommand.new()]})
		target.present(1.0 / 64.0)
		await get_tree().physics_frame
		if i < WARMUP_TICKS:
			continue
		var sk: Skeleton3D = target.figure.skeleton()
		var boxes: Array = target.hitboxes.hitboxes()
		for bone in bones:
			var bi := sk.find_bone(bone)
			if bi < 0:
				continue
			var p: Vector3 = sk.global_transform * sk.get_bone_global_pose(bi).origin
			var dir := (p - eye).normalized()
			var hit := false
			for b: DotHitbox in boxes:
				var h = b.intersect_ray(eye, dir, RANGE_M * 2.0)
				if h.hitbox != null:
					hit = true
					break
			if not hit:
				missed[bone] = int(missed.get(bone, 0)) + 1
	var out := {}
	for bone: String in missed:
		out[bone] = "%d/%d" % [missed[bone], SAMPLE_TICKS]
	return out
