extends Node3D

## Draws capture the flag's flags: a pole with a banner and a faint light in the team's colour, on its stand, on the floor where it was dropped, or on the carrier's back. Built by [ArenaObjectives] when the game draws anything (not headless); it reads [DotObjectiveCtf] every frame, so a rebuilt layout (new map, new match) needs no wiring.

const ArenaGame := preload("arena_game.gd")

const POLE_HEIGHT := 2.6
const BANNER_SIZE := Vector2(1.3, 0.9)
const COLORS := {1: Color(0.95, 0.18, 0.15), 2: Color(0.2, 0.42, 0.98), 3: Color(0.2, 0.8, 0.3), 4: Color(0.98, 0.85, 0.2)}

var game: ArenaGame = null
var ctf: DotObjectiveCtf = null

var _views := {}


## The colour of a team's flag.
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
	for team: int in _views.keys():
		if not seen.has(team):
			(_views[team] as Node3D).queue_free()
			_views.erase(team)


## Where [param flag]'s pole stands: on a carrier's back, where it fell, or on its stand.
func _place(flag: DotObjectiveFlag) -> Vector3:
	if flag.state == DotObjectiveFlag.State.CARRIED and game != null and flag.carrier.is_valid_int():
		var carrier := game.player_for(int(flag.carrier))
		if carrier != null and is_instance_valid(carrier) and carrier.is_inside_tree():
			return carrier.global_position + Vector3(0.0, 0.2, 0.0)
	return flag.at


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

	var light := OmniLight3D.new()
	light.light_color = colour
	light.omni_range = 5.0
	light.light_energy = 0.8
	light.position = Vector3(0.0, 1.5, 0.0)
	root.add_child(light)
	return root
