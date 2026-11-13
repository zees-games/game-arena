extends Node

## Every weapon kind dropped by a kill (the game's own death drop, from a live game) at spots over dm_atrium (open floor, plinth, stairs, beside walls): after settling, the client's lowest mesh point
## is not below the surface nor floating above it (the burst of deaths passes the active cap, which used to rest a drop
## in the air where it spawned: the small dark gun floating by a wall in arena-stray-weapon-3), the drop does not jitter, and it came to rest. Run: [code]godot --headless --path . res://examples/headless_weapondrop_death.tscn[/code]

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaTestToys := preload("arena_test_toys.gd")
const Wiring := preload("../game/arena_weapon_drop_wiring.gd")
const ArenaWeaponRoles := preload("../game/arena_weapon_roles.gd")

const TOLERANCE := 0.02
## Most a settled drop's lowest mesh point may sit above the surface under it, in metres (DotWeaponDrops grounds a drop resting higher than 0.25).
const FLOAT_MAX := 0.3
const TICK_RATE := 64
const RUN_TICKS := 640
const JITTER_TICKS := 96
const SPOTS_PER_WEAPON := 4

var _checks := 0
var _failed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	Engine.physics_ticks_per_second = TICK_RATE
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	if not condition or OS.get_environment("VERBOSE") != "":
		print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _ground(x: float, z: float, from_y: float, mask: int) -> float:
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, from_y, z), Vector3(x, from_y - 40.0, z), mask)
	var h := get_viewport().world_3d.direct_space_state.intersect_ray(q)
	return float(h["position"].y) if not h.is_empty() else NAN


## How far the deepest sampled mesh point under [param node] is below the surface (negative: clear).
func _sunk(node: Node, mask: int) -> float:
	var space := get_viewport().world_3d.direct_space_state
	var worst := -INF
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null and (n as MeshInstance3D).visible:
			var t := (n as MeshInstance3D).global_transform
			var faces := (n as MeshInstance3D).mesh.get_faces()
			var step := maxi(1, faces.size() / 120)
			for k in range(0, faces.size(), step):
				var w := t * faces[k]
				var h := space.intersect_ray(PhysicsRayQueryParameters3D.create(w + Vector3.UP * 0.4, w + Vector3.DOWN * 0.4, mask))
				worst = maxf(worst, (float(h["position"].y) - w.y) if not h.is_empty() else -0.4)
		stack.append_array(n.get_children())
	return worst


func _run() -> void:
	var game := ArenaGame.new()
	game.name = "G"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.team_deathmatch()
	add_child(game)
	_check(game.setup(ArenaTestToys.give(ArenaMap.dm_atrium())).ok, "a game sets up")
	game.start(0)
	var _a := game.add_player(21, "A")
	game.tick({})
	var player := game.player_for(21)
	var drops: DotWeaponDrops = game.weapon_drops
	drops.rules.lifetime = 0.0
	drops.rules.max_count = 0
	var mask := drops.collision_mask
	var client := DotWeaponDrops.new()
	client.is_authority = false
	client.draws = true
	client.look_of = Wiring.look
	client.rules.lifetime = 0.0
	client.rules.max_count = 0
	game.add_child(client)
	drops.dropped.connect(func(i: int, s: Dictionary, at: Transform3D, v: Vector3, _o: int) -> void: client.mirror_drop(i, s, at, v))
	drops.settled.connect(func(i: int, at: Transform3D) -> void: client.mirror_settled(i, at))

	var sent := _drop_deaths(game, player, drops, mask)
	var trail := {}
	for t in RUN_TICKS:
		await get_tree().physics_frame
		if t >= RUN_TICKS - JITTER_TICKS:
			for e: int in sent:
				var b: RigidBody3D = client.get("_entries")[e]["body"]
				var tr: Array = trail.get(e, [b.global_position, b.global_position])
				tr[0] = (tr[0] as Vector3).min(b.global_position)
				tr[1] = (tr[1] as Vector3).max(b.global_position)
				trail[e] = tr
	var deepest := -INF
	var worst := ""
	var jitter := 0.0
	var lost := 0
	var unrested := 0
	var floating: Array[String] = []
	for e: int in sent:
		var cb: RigidBody3D = client.get("_entries")[e]["body"]
		if cb.global_position.y < -50.0:
			lost += 1
			continue
		if not bool(drops.get("_entries")[e]["rest"]):
			unrested += 1
		var s := _sunk(cb, mask)
		if -s > FLOAT_MAX:
			floating.append("%s at %s y %.2f" % [sent[e][0], sent[e][1], cb.global_position.y])
		if s > deepest:
			deepest = s
			worst = "%s at %s" % [sent[e][0], sent[e][1]]
		jitter = maxf(jitter, ((trail[e][1] as Vector3) - (trail[e][0] as Vector3)).length())
	print("  death drops=%d deepest=%+.3f (%s) jitter=%.4f unrested=%d lost=%d floating=%d" % [sent.size(), deepest, worst, jitter, unrested, lost, floating.size()])
	_check(lost == 0, "no dead player's weapon fell out of the world", str(lost))
	_check(deepest <= TOLERANCE, "client mesh not below the surface at 10 s", "%.3f %s" % [deepest, worst])
	_check(floating.is_empty(), "no settled drop floats above the surface (the active cap rests a burst of drops)", "%d: %s" % [floating.size(), floating.slice(0, 6)])
	_check(jitter <= 0.003, "resting drops do not jitter", "%.4f" % jitter)
	_check(unrested == 0, "every drop came to rest", str(unrested))
	print("weapondrop_death: %d checks, %d failed" % [_checks, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


## Kills the player holding each weapon at spread spots; returns drop id -> [weapon, spot].
func _drop_deaths(game: ArenaGame, player: Object, drops: DotWeaponDrops, mask: int) -> Dictionary:
	var spots: Array[Vector2] = []
	for xi in range(-8, 9, 2):
		for zi in range(-8, 9, 2):
			spots.append(Vector2(xi, zi))
	ArenaWeaponRoles.ensure()
	var ids: Array = AwWeaponArtTable.table().keys()
	ids.sort()
	_check(ids.size() > 10, "the art table has weapons", str(ids.size()))
	var sent := {}
	var no_spot := 0
	var given := 0
	for w_i in ids.size():
		var id: StringName = ids[w_i]
		for k in SPOTS_PER_WEAPON:
			var sp := spots[(w_i * 7 + k * 13) % spots.size()]
			var g := _ground(sp.x, sp.y, 8.0, mask)
			if is_nan(g):
				no_spot += 1
				continue
			if not player.arsenal.give(id).ok:
				continue
			var def: Variant = player.arsenal.catalogue.get_def(id)
			if def == null or not player.arsenal.equip(def.slot):
				continue
			given += 1
			player.controller.state.position = Vector3(sp.x, g, sp.y)
			var before: Array = drops.get("_entries").keys()
			Wiring.drop_for_death(game, player)
			for e: int in drops.get("_entries").keys():
				if not before.has(e):
					sent[e] = [id, Vector2(sp.x, sp.y)]
	_check(given > ids.size(), "most weapons could be given and dropped", "%d of %d" % [given, ids.size() * SPOTS_PER_WEAPON])
	_check(not sent.is_empty(), "kills dropped weapons", str(sent.size()))
	return sent
