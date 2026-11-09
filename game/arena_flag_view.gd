extends Node3D

## Draws capture the flag's flags: a pole with a banner and a faint light in the team's colour, on its stand, on the floor where it was dropped, or in the carrier's hand ([code]arena_flag_carry.gd[/code]). Over each one a small see-through flag icon in the team's colour with its distance ("19.4m"), like Halo's CTF marker (`arena_ctf_indicator`, `arena_ctf_indicator_seethrough`, both on by default; no beam, no "RED FLAG" text). Built by [ArenaObjectives] when the game draws anything (not headless); it reads [DotObjectiveCtf] every frame, so a rebuilt layout (new map, new match) needs no wiring.

const ArenaGame := preload("arena_game.gd")
const ArenaFlagCarry := preload("arena_flag_carry.gd")

const POLE_HEIGHT := 3.4
const BANNER_SIZE := Vector2(1.8, 1.2)
## A carried flag is held smaller, in the hand.
const CARRIED_SCALE := 0.55
## The marker over the flag: icon size in texels, how big a texel is on screen (fixed size), and how see-through it is.
const ICON_PX := 64
const ICON_PIXEL := 0.0007
const ICON_ALPHA := 0.7
const DIST_FONT := 22
const DIST_PIXEL := 0.0009
const NAMES := {1: "RED", 2: "BLUE", 3: "GREEN", 4: "YELLOW"}
const COLORS := {1: Color(0.95, 0.18, 0.15), 2: Color(0.2, 0.42, 0.98), 3: Color(0.2, 0.8, 0.3), 4: Color(0.98, 0.85, 0.2)}

var game: ArenaGame = null
var ctf: DotObjectiveCtf = null

var _views := {}
static var _icon_texture: ImageTexture = null
## What each flag was last seen doing: {team: [state, carrier]}, to raise [signal ArenaGameState.ctf_seen] on a change.
var _last := {}
## Who held each flag last frame: {team: player}, to let go of their arm.
var _holders := {}
## How fast a flag in flight is eased toward the position the server last sent.
const FLIGHT_EASE := 18.0


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
		var target := _place(flag)
		if ArenaFlagCarry.flying(game, team):
			view.position = view.position.lerp(target, clampf(get_process_delta_time() * FLIGHT_EASE, 0.0, 1.0))
		else:
			view.position = target
		_see(flag)
		var carried := flag.state == DotObjectiveFlag.State.CARRIED
		view.basis = Basis.from_scale(Vector3.ONE * (CARRIED_SCALE if carried else 1.0))
		(view.get_node("Plate") as Node3D).visible = not carried
		view.visible = true
		_mark(view)
		var c := _carrier_of(flag) if carried else null
		if c != null:
			ArenaFlagCarry.pose_view(view, c, get_viewport().get_camera_3d() if is_inside_tree() else null, CARRIED_SCALE)
		var was: Variant = _holders.get(team)
		if was != null and was != c and is_instance_valid(was):
			ArenaFlagCarry.release_arm(was)
		_holders[team] = c
	for team: int in _views.keys():
		if not seen.has(team):
			(_views[team] as Node3D).queue_free()
			_views.erase(team)


## The indicator settings the server sent (`ArenaGameState.ctf_view`); both on without a game.
func indicator_on() -> bool:
	return game == null or bool(game.ctf_view.get("indicator", true))


func see_through() -> bool:
	return game == null or bool(game.ctf_view.get("see_through", true))


## The marker over [param view]: shown or not, through walls or not, and the distance from the eye in metres ("19.4m").
func _mark(view: Node3D) -> void:
	var icon := view.get_node("Icon") as Sprite3D
	var dist := view.get_node("Dist") as Label3D
	var on := indicator_on()
	var through := see_through()
	icon.visible = on
	dist.visible = on
	icon.no_depth_test = through
	dist.no_depth_test = through
	if not on:
		return
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		dist.text = ""
		return
	dist.text = distance_text(cam.global_position.distance_to(icon.global_position))


## "19.4m": one decimal, metres (a Godot unit is a metre).
static func distance_text(metres: float) -> String:
	return "%.1fm" % maxf(metres, 0.0)


## A white flag on a pole, tinted per team by the sprite's modulate. Drawn once, shared by every marker.
static func icon_texture() -> ImageTexture:
	if _icon_texture != null:
		return _icon_texture
	var n := ICON_PX
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var pole_x := int(n * 0.2)
	var outline := Color(0.0, 0.0, 0.0, 0.55)
	# The banner: a waving cloth from the pole to the right, the top 55% of the icon.
	var top := int(n * 0.1)
	var height := int(n * 0.42)
	var right := int(n * 0.9)
	for x in range(pole_x + 2, right):
		var t := float(x - pole_x) / float(right - pole_x)
		var wave := int(round(sin(t * TAU) * n * 0.04))
		for y in range(top + wave, top + wave + height):
			var edge := x == pole_x + 2 or x == right - 1 or y == top + wave or y == top + wave + height - 1
			img.set_pixel(x, y, outline if edge else Color(1, 1, 1, 1))
	# The pole, full height, outlined so it reads on a light wall.
	for y in range(int(n * 0.04), n - 1):
		for x in range(pole_x - 2, pole_x + 3):
			var edge := x == pole_x - 2 or x == pole_x + 2
			img.set_pixel(x, y, outline if edge else Color(1, 1, 1, 1))
	_icon_texture = ImageTexture.create_from_image(img)
	return _icon_texture


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


## Where [param flag]'s pole stands: by its carrier (the hand pose then places it), where it is in flight, where it fell, or on the floor under its stand (the stand's own point floats a metre up).
func _place(flag: DotObjectiveFlag) -> Vector3:
	var carrier := _carrier_of(flag)
	if carrier != null:
		return carrier.global_position
	if ArenaFlagCarry.flying(game, flag.home_team()):
		return flag.at
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

	# The marker, over the pole and (by default) through walls: a small see-through flag icon in the team's colour, and its distance beside it in small text.
	var icon := Sprite3D.new()
	icon.name = "Icon"
	icon.texture = icon_texture()
	icon.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	icon.no_depth_test = true
	icon.fixed_size = true
	icon.pixel_size = ICON_PIXEL
	icon.shaded = false
	icon.double_sided = true
	icon.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	icon.modulate = Color(colour.r, colour.g, colour.b, ICON_ALPHA)
	icon.render_priority = 10
	icon.position = Vector3(0.0, POLE_HEIGHT + 0.7, 0.0)
	root.add_child(icon)

	var dist := Label3D.new()
	dist.name = "Dist"
	dist.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	dist.no_depth_test = true
	dist.fixed_size = true
	dist.pixel_size = DIST_PIXEL
	dist.font_size = DIST_FONT
	dist.outline_size = 6
	dist.outline_modulate = Color(0, 0, 0, 0.5)
	dist.modulate = Color(colour.lightened(0.45).r, colour.lightened(0.45).g, colour.lightened(0.45).b, 0.8)
	dist.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	# Beside the icon, to its right, as Halo puts it: half the icon's width plus a gap, in the label's own pixels.
	dist.offset = Vector2(ICON_PX * 0.5 * ICON_PIXEL / DIST_PIXEL + 4.0, 0.0)
	dist.render_priority = 10
	dist.position = icon.position
	root.add_child(dist)

	var light := OmniLight3D.new()
	light.light_color = colour
	light.omni_range = 5.0
	light.light_energy = 0.8
	light.position = Vector3(0.0, 1.5, 0.0)
	root.add_child(light)
	return root
