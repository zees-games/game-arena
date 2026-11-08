extends Node3D

## Draws capture the flag's flags: a pole with a banner and a faint light in the team's colour, on its stand, on the floor where it was dropped, or on the carrier's back. Built by [ArenaObjectives] when the game draws anything (not headless); it reads [DotObjectiveCtf] every frame, so a rebuilt layout (new map, new match) needs no wiring.

const ArenaGame := preload("arena_game.gd")

const POLE_HEIGHT := 3.4
const BANNER_SIZE := Vector2(1.8, 1.2)
## A carried flag is worn smaller, on the back.
const CARRIED_SCALE := 0.55
const BEAM_HEIGHT := 40.0
const NAMES := {1: "RED", 2: "BLUE", 3: "GREEN", 4: "YELLOW"}
const COLORS := {1: Color(0.95, 0.18, 0.15), 2: Color(0.2, 0.42, 0.98), 3: Color(0.2, 0.8, 0.3), 4: Color(0.98, 0.85, 0.2)}

var game: ArenaGame = null
var ctf: DotObjectiveCtf = null

var _views := {}
## What each flag was last seen doing: {team: [state, carrier]}, to raise [signal ArenaGameState.ctf_seen] on a change.
var _last := {}


## The colour of a team's flag.
static func name_of(team: int) -> String:
	return NAMES.get(team, "TEAM %d" % team)


static func color_of(team: int) -> Color:
	return COLORS.get(team, Color(0.8, 0.8, 0.8))


## How many flags are drawn right now.
func drawn_count() -> int:
	return _views.size()


func _process(_delta: float) -> void:
	refresh()


## Bring the drawn flags in line with the layer: one per flag, placed by its state.
func view_position(team: int) -> Vector3:
	var v: Node3D = _views.get(team)
	return v.position if v != null else Vector3(INF, INF, INF)


func refresh() -> void:
	if ctf == null or not is_instance_valid(ctf) or ctf.manager == null:
		return
	var seen := {}
	for flag in ctf.flags():
		var team := flag.home_team()
		seen[team] = true
		var view: Node3D = _views.get(team)
		if view == null:
			view = _build(team)
			_views[team] = view
		view.position = _place(flag)
		_see(flag)
		var carried := flag.state == DotObjectiveFlag.State.CARRIED
		view.scale = Vector3.ONE * (CARRIED_SCALE if carried else 1.0)
		(view.get_node("Plate") as Node3D).visible = not carried
		(view.get_node("Tag") as Label3D).text = "%s CARRIER" % name_of(team) if carried else "%s FLAG" % name_of(team)
		view.visible = true
		if carried:
			var c := _carrier_of(flag)
			if c != null:
				view.rotation.y = c.global_rotation.y
				# Worn by the player whose eyes these are, it would be a pole in their face: the HUD tells them instead.
				var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
				view.visible = cam == null or cam.global_position.distance_to(c.global_position + Vector3.UP * 1.4) > 1.2
		else:
			view.rotation.y = 0.0
	for team: int in _views.keys():
		if not seen.has(team):
			(_views[team] as Node3D).queue_free()
			_views.erase(team)


## Raise [signal ArenaGameState.ctf_seen] when [param flag] changed state since the last frame (not for the first sight of it).
func _see(flag: DotObjectiveFlag) -> void:
	var team := flag.home_team()
	var was: Array = _last.get(team, [])
	_last[team] = [flag.state, flag.carrier]
	if was.is_empty() or was[0] == flag.state or game == null:
		return
	var by := int(was[1]) if str(was[1]).is_valid_int() else 0
	var what := &""
	match flag.state:
		DotObjectiveFlag.State.CARRIED:
			what = &"taken"
			by = int(flag.carrier) if flag.carrier.is_valid_int() else 0
		DotObjectiveFlag.State.DROPPED:
			what = &"dropped"
		DotObjectiveFlag.State.HOME:
			what = &"captured" if was[0] == DotObjectiveFlag.State.CARRIED else &"returned"
	if what != &"":
		game.ctf_seen.emit(what, team, by)


func _carrier_of(flag: DotObjectiveFlag) -> Node3D:
	if flag.state == DotObjectiveFlag.State.CARRIED and game != null and flag.carrier.is_valid_int():
		var carrier := game.player_for(int(flag.carrier))
		if carrier != null and is_instance_valid(carrier) and carrier.is_inside_tree():
			return carrier
	return null


## Where [param flag]'s pole stands: on a carrier's back, where it fell, or on the floor under its stand (the stand's own point floats a metre up).
func _place(flag: DotObjectiveFlag) -> Vector3:
	var carrier := _carrier_of(flag)
	if carrier != null:
		return carrier.global_position + carrier.global_basis.z * 0.45 + Vector3(0.0, 0.35, 0.0)
	return _grounded(flag.at)


func _grounded(at: Vector3) -> Vector3:
	if game == null or game.combat == null or game.combat.trace == null:
		return at
	var hit = game.combat.trace.ray(at + Vector3.UP * 0.6, Vector3.DOWN, 4.0)
	if hit != null and hit.ok():
		return Vector3(at.x, hit.point.y, at.z)
	return at


func _build(team: int) -> Node3D:
	var colour := color_of(team)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	mat.emission_enabled = true
	mat.emission = colour
	mat.emission_energy_multiplier = 0.8
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.85, 0.85, 0.88)

	var root := Node3D.new()
	root.name = "Flag%d" % team
	add_child(root)

	var pole := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.04
	cyl.bottom_radius = 0.05
	cyl.height = POLE_HEIGHT
	pole.mesh = cyl
	pole.material_override = pole_mat
	pole.position = Vector3(0.0, POLE_HEIGHT * 0.5, 0.0)
	root.add_child(pole)

	var banner := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = BANNER_SIZE
	banner.mesh = quad
	banner.material_override = mat
	banner.position = Vector3(BANNER_SIZE.x * 0.5 + 0.05, POLE_HEIGHT - BANNER_SIZE.y * 0.5 - 0.1, 0.0)
	root.add_child(banner)

	# A tall faint beam: the flag can be found from across the map.
	var beam_mat := StandardMaterial3D.new()
	beam_mat.albedo_color = Color(colour.r, colour.g, colour.b, 0.4)
	beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	beam_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	beam_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var beam := MeshInstance3D.new()
	var bm := CylinderMesh.new()
	bm.top_radius = 0.3
	bm.bottom_radius = 0.3
	bm.height = BEAM_HEIGHT
	beam.mesh = bm
	beam.material_override = beam_mat
	beam.position = Vector3(0.0, BEAM_HEIGHT * 0.5, 0.0)
	beam.name = "Beam"
	root.add_child(beam)

	# The capture plate under the stand.
	var plate := MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = 1.4
	pm.bottom_radius = 1.4
	pm.height = 0.04
	plate.mesh = pm
	plate.material_override = mat
	plate.position = Vector3(0.0, 0.03, 0.0)
	plate.name = "Plate"
	root.add_child(plate)

	# Its name, over the pole, through walls.
	var tag := Label3D.new()
	tag.name = "Tag"
	tag.text = "%s FLAG" % name_of(team)
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.no_depth_test = true
	tag.fixed_size = true
	tag.pixel_size = 0.0016
	tag.font_size = 40
	tag.outline_size = 12
	tag.modulate = colour.lightened(0.35)
	tag.position = Vector3(0.0, POLE_HEIGHT + 0.7, 0.0)
	root.add_child(tag)

	var light := OmniLight3D.new()
	light.light_color = colour
	light.omni_range = 5.0
	light.light_energy = 0.8
	light.position = Vector3(0.0, 1.5, 0.0)
	root.add_child(light)
	return root
