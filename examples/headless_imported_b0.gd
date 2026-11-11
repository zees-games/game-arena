extends "imported_base.gd"

const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaBspMap := preload("../maps/arena_bsp_map.gd")


const TICK_RATE := 64


## The map the ride check plays: the first combat surf map with planned rides (see
## docs/imported-maps.md, "Bots ride the ramps", for why not [constant MAP]).
const RIDE_MAP := &"surf_ski_2"
func _test_surf_movement() -> void:
	_section("the surf air control is on here, off on a built-in map, and on again")

	var player := _game.player_for(1)
	var surf := ArenaPlayer.SURF_TUNABLES
	var arena := ArenaPlayer.arena_tunables()
	_check(_matches(player, surf, 150.0),
		"on %s: air_accelerate %.0f, air cap %.3f m/s, gravity %.2f" % [
			MAP, player.controller.tunables.air_accelerate,
			player.controller.tunables.max_air_wish_speed, player.controller.tunables.gravity
		])

	var to_box := _game.change_map(ArenaMap.dm_box())
	_check(to_box.ok and is_equal_approx(player.controller.tunables.air_accelerate, arena.air_accelerate)
		and is_equal_approx(player.controller.tunables.max_air_wish_speed, arena.max_air_wish_speed)
		and is_equal_approx(player.controller.tunables.gravity, arena.gravity),
		"on dm_box: back to the arena's own (%.0f, %.2f, %.0f)" % [
			player.controller.tunables.air_accelerate,
			player.controller.tunables.max_air_wish_speed, player.controller.tunables.gravity
		])
	_check(_game.map.collision_root == null and _game._world_collision == null,
		"and the imported solid went with the map")

	var back := _game.change_map(ArenaMap.by_id(MAP))
	_check(back.ok and _matches(player, surf, 150.0), "back on %s: on again" % MAP)

	_game.set_movement_rules({"surf_air_accelerate": 400.0})
	_check(is_equal_approx(player.controller.tunables.air_accelerate, 400.0),
		"arena_surf_airaccelerate reaches a player on the map (%.0f)" % player.controller.tunables.air_accelerate)

	_game.set_movement_rules({"surf": 0.0})
	_check(is_equal_approx(player.controller.tunables.air_accelerate, arena.air_accelerate)
		and is_equal_approx(player.controller.tunables.gravity, arena.gravity),
		"and arena_surf 0 plays it with the arena's own")

	_game.set_movement_rules({"surf": 1.0, "surf_air_accelerate": 150.0})
	_check(_matches(player, surf, 150.0), "and 1 puts the genre's back")

	_done()


func _matches(player: ArenaPlayer, surf: Dictionary, air: float) -> bool:
	var t := player.controller.tunables
	return (
		is_equal_approx(t.air_accelerate, air)
		and is_equal_approx(t.max_air_wish_speed, float(surf["max_air_wish_speed"]))
		and is_equal_approx(t.gravity, float(surf["gravity"]))
		and is_equal_approx(t.jump_height, float(surf["jump_height"]))
	)


func _test_ramp() -> void:
	_section("a ramp is ridden, not stood on")

	var face := _steepest_big_ramp()
	_check(not face.is_empty(), "the map has a surf ramp (a face between %.0f and 75 degrees, %.0f m² of it)" % [
		ArenaPlayer.arena_tunables().max_slope_angle, float(face.get("area", 0.0))
	])

	if face.is_empty():
		_check(false, "so nothing could ride it")
		_check(false, "or slide down it")
		_done()
		return

	var normal: Vector3 = face["normal"]
	var player := _game.player_for(3)

	if not player.is_alive():
		_game.respawn_player(3)

	# Half a metre off the face, along its normal, and dropped: the hull lands ON the ramp.
	var start: Vector3 = face["centre"] + normal * 0.5
	player.controller.teleport(start, 0.0, 0.0)

	var grounded := 0
	var touching := 0
	var top_speed := 0.0
	var no_input := {3: [DotFpsCommand.new(), DotWeaponCommand.new()]}

	for i in range(TICK_RATE):
		_game.tick(no_input)
		var state := player.controller.state

		if state.is_grounded():
			grounded += 1

		# On the face: within a hand of its plane, above it.
		var height_over := normal.dot(state.position - (face["centre"] as Vector3))
		if height_over < 0.6 and height_over > -0.2:
			touching += 1

		top_speed = maxf(top_speed, state.velocity.length())

	var dropped := start.y - player.controller.state.position.y
	_line("     %d ticks on the face, %d grounded, top speed %.1f m/s, %.1f m down" % [
		touching, grounded, top_speed, dropped
	])
	_check(touching > TICK_RATE / 4 and grounded == 0,
		"the player rides it: %d ticks against the face and not one standing on it" % touching)
	_check(top_speed > 8.0 and dropped > 3.0,
		"and slides down it, picking up speed (%.1f m/s, %.1f m)" % [top_speed, dropped])

	_done()


## The biggest triangle of the map's own drawn RAMP surfaces whose slope is one the
## movement cannot stand on: `{centre, normal, area}`, or empty.
func _steepest_big_ramp() -> Dictionary:
	var manifest := ArenaImportedMaps.manifest(MAP)
	var dir := ArenaImportedMaps.manifest_path(MAP).get_base_dir()
	var blob := FileAccess.get_file_as_bytes(dir.path_join("%s.bin" % MAP))
	var limit := cos(deg_to_rad(ArenaPlayer.arena_tunables().max_slope_angle + 3.0))
	var best := {}
	var best_area := 0.0

	for entry: Variant in manifest.get("surfaces", []):
		var surface: Dictionary = entry

		if str(surface.get("role", "")) != "RAMP":
			continue

		var vcount := int(surface.get("vertex_count", 0))
		var icount := int(surface.get("index_count", 0))
		var floats := blob.slice(int(surface["vertex_offset"]),
			int(surface["vertex_offset"]) + vcount * ArenaBspMap.VERTEX_FLOATS * 4).to_float32_array()
		var indices := blob.slice(int(surface["index_offset"]),
			int(surface["index_offset"]) + icount * 4).to_int32_array()

		for t in range(0, icount - 2, 3):
			var p: Array[Vector3] = []

			for k in range(3):
				var o := int(indices[t + k]) * ArenaBspMap.VERTEX_FLOATS
				p.append(Vector3(floats[o], floats[o + 1], floats[o + 2]) * ArenaBspMap.METRES_PER_UNIT)

			var cross := (p[1] - p[0]).cross(p[2] - p[0])
			var area := cross.length() * 0.5

			if area <= best_area:
				continue

			# Either winding: the face a player lands on points up.
			var normal := cross.normalized()
			if normal.y < 0.0:
				normal = -normal

			if normal.y >= limit or normal.y < 0.26:
				continue

			best_area = area
			best = {"centre": (p[0] + p[1] + p[2]) / 3.0, "normal": normal, "area": area}

	return best


func _test_pits() -> void:
	_section("a pit sends a player where it aims, and the floor under the map catches")

	var pits := _game.map.pits
	_check(not pits.is_empty(), "the map has teleport volumes (%d)" % pits.size())

	var player := _game.player_for(2)

	if not player.is_alive():
		_game.respawn_player(2)

	var pit: Dictionary = pits[0]
	var box: AABB = pit["box"]
	player.controller.teleport(box.get_center(), 0.0, 0.0)
	_game.tick({})
	var at := player.controller.state.position
	_check(at.distance_to(pit["to"]) < 0.5,
		"stepped into one, the player is at its destination (%.2f m off)" % at.distance_to(pit["to"]))

	var under := _game.map.bounds.position - Vector3(-1.0, ArenaPlayer.FALL_OUT_DEPTH + 5.0, -1.0)
	player.controller.teleport(under, 0.0, 0.0)
	_game.tick({})
	var spawn: Transform3D = _game.map.spawns[0]
	_check(player.controller.state.position.distance_to(spawn.origin) < 0.5,
		"fallen out of the bottom of the map, back at a spawn")

	_done()


## surf_ski_2's catch-all floor teleport aims at a roofed cell whose only exit is a door the
## map's button opens; the zones file opens it (`open_doors`). Armed: nobody leaves the cell
## when the door is back in the import.
func _test_fallout() -> void:
	_section("surf_ski_2: a fall into the floor catch-all lands in the cell, and the way out is open")

	var changed := _game.change_map(ArenaMap.by_id(RIDE_MAP))
	_check(changed.ok, "the map loads")
	if not changed.ok:
		_done()
		return

	var catch_all := -1
	var biggest := 0.0
	for index in range(_game.map.pits.size()):
		var volume: float = (_game.map.pits[index]["box"] as AABB).get_volume()
		if volume > biggest:
			biggest = volume
			catch_all = index
	var pit: Dictionary = _game.map.pits[catch_all]
	var cell: Vector3 = pit["to"]

	var player := _fresh(2)
	player.controller.teleport((pit["box"] as AABB).get_center(), 0.0, 0.0)
	_game.tick({})
	var at := player.controller.state.position
	_check(at.distance_to(cell) < 0.5,
		"the floor catch-all puts a faller in the cell (%.2f m off)" % at.distance_to(cell))

	# The cell's door is in its +z wall (Source's -y): walk at it, yaw 180 being +z.
	var door_z := cell.z + 6.2
	var out_at := -1
	# Four seconds: the shut door was walked round in about twelve, sliding along it to a
	# corner, which is not a way out a bot's route would take.
	for tick in range(TICK_RATE * 4):
		var move := DotFpsCommand.new()
		move.yaw = 180.0
		move.move = Vector2(0.0, 1.0)
		move.sanitise()
		_game.tick({player.player_id: [move, DotWeaponCommand.new()]})
		if player.controller.state.position.z > door_z:
			out_at = tick
			break
	_check(out_at >= 0,
		"walked out through the door (%s; ended %.1f, %.1f, %.1f)" % [
			"after %d ticks" % out_at if out_at >= 0 else "never",
			player.controller.state.position.x, player.controller.state.position.y,
			player.controller.state.position.z])

	_done()


## A player alive and out of their spawn protection, standing still.
func _fresh(id: int) -> ArenaPlayer:
	var player := _game.player_for(id)
	if not player.is_alive():
		_game.respawn_player(id)
	return player
