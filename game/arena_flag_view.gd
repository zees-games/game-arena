extends Node3D

## Draws capture the flag's flags: a pole with a banner and a faint light in the team's colour, on its stand, on the floor where it was dropped, or in the carrier's hand ([code]arena_flag_carry.gd[/code]). Over each one a small see-through flag icon in the team's colour with its distance ("19.4m"), like Halo's CTF marker (`arena_ctf_indicator`, `arena_ctf_indicator_seethrough`, both on by default; no beam, no "RED FLAG" text). Built by [ArenaObjectives] when the game draws anything (not headless); it reads [DotObjectiveCtf] every frame, so a rebuilt layout (new map, new match) needs no wiring.

const ArenaGame := preload("arena_game.gd")
const ArenaFlagCarry := preload("arena_flag_carry.gd")
const ArenaLoadTimeline := preload("arena_load_timeline.gd")

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
## What each flag was last seen doing ({team: state} and {team: carrier}), to raise [signal ArenaGameState.ctf_seen] on a change.
var _last_state := {}
var _last_carrier := {}
## Each flag's parts looked up once at build: {team: [plate, icon, dist]}, so a frame does no node lookup.
var _parts := {}
## The distance label's last shown tenth of a metre per team, so the text is rebuilt only when it changes.
var _dist_tenth := {}
## Teams seen this refresh; kept and cleared so a frame allocates nothing.
var _seen := {}
## Formats the distance; held as a callable because it runs only when the shown tenth changes.
var _format_distance: Callable = distance_text
## The floor under each resting flag: {team: [at, grounded]}. The trace is redone only when the flag's point moves,
## not every frame (a resting flag's floor does not change).
var _ground := {}
const NODE_NAMES := {1: &"Flag1", 2: &"Flag2", 3: &"Flag3", 4: &"Flag4"}
## Who held each flag last frame: {team: player}, to let go of their arm.
var _holders := {}
## How fast a flag in flight is eased toward the position the server last sent.
const FLIGHT_EASE := 18.0


## A flag view built once per process, hidden, so its materials, icon and label are compiled and held before a
## CTF map's first frame: built in that frame they were 143 ms of a map change's swap frame on the bench.
static var _warm: Node3D = null
## This script, for [method warm] to make one of itself.
const _SELF_PATH := "res://game/arena_flag_view.gd"
## The parts of a flag, in the order [method _build] adds them; [method warm] adds one a frame.
const _BUILD_PARTS: Array[StringName] = [&"_add_pole", &"_add_cloth", &"_add_icon", &"_add_label", &"_add_light"]


## Builds [member _warm] under [param host] (behind a loading cover) one part a frame, so no frame compiles every
## part's materials at once (all in one frame it was a 163 ms frame on the bench), each drawn far below the world,
## then hides it. A second call, or a headless process, does nothing.
static func warm(host: Node) -> void:
	if DotPlatform.is_headless() or (_warm != null and is_instance_valid(_warm)):
		return
	var view: Node3D = load(_SELF_PATH).new()
	view.name = "FlagViewWarm"
	view.position = Vector3(0.0, -10000.0, 0.0)
	view.set_process(false)
	host.add_child(view)
	_warm = view
	var root: Node3D = view._add_root(1)
	for part in _BUILD_PARTS:
		await host.get_tree().process_frame
		if not is_instance_valid(view):
			return
		view.call(part, root, 1)
		ArenaLoadTimeline.mark("change: flag view %s" % String(part).trim_prefix("_add_"))
	await host.get_tree().process_frame
	if is_instance_valid(view):
		view.visible = false


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
	var seen := _seen
	seen.clear()
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
		var parts: Array = _parts[team]
		(parts[0] as Node3D).visible = not carried
		view.visible = true
		_mark(team, parts[1], parts[2])
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
			_parts.erase(team)
			_dist_tenth.erase(team)


## The indicator settings the server sent (`ArenaGameState.ctf_view`); both on without a game.
func indicator_on() -> bool:
	return game == null or bool(game.ctf_view.get("indicator", true))


func see_through() -> bool:
	return game == null or bool(game.ctf_view.get("see_through", true))


## The marker over [param view]: shown or not, through walls or not, and the distance from the eye in metres ("19.4m").
func _mark(team: int, icon: Sprite3D, dist: Label3D) -> void:
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
		if _dist_tenth.get(team, -1) != -1:
			dist.text = ""
			_dist_tenth[team] = -1
		return
	var tenth := int(roundf(maxf(cam.global_position.distance_to(icon.global_position), 0.0) * 10.0))
	if _dist_tenth.get(team, -1) != tenth:
		_dist_tenth[team] = tenth
		dist.text = _format_distance.call(tenth * 0.1)


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
	var known: bool = _last_state.has(team)
	var was_state: int = _last_state.get(team, -1)
	var was_carrier: String = _last_carrier.get(team, "")
	_last_state[team] = flag.state
	_last_carrier[team] = flag.carrier
	if not known or was_state == flag.state or game == null:
		return
	var by := int(was_carrier) if was_carrier.is_valid_int() else 0
	var what := &""
	match flag.state:
		DotObjectiveFlag.State.CARRIED:
			what = &"taken"
			by = int(flag.carrier) if flag.carrier.is_valid_int() else 0
		DotObjectiveFlag.State.DROPPED:
			what = &"dropped"
		DotObjectiveFlag.State.HOME:
			what = &"captured" if was_state == DotObjectiveFlag.State.CARRIED else &"returned"
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
	if game == null or game.combat == null or game.combat.trace == null:
		return flag.at
	var team := flag.home_team()
	var held: Array = _ground.get(team, [])
	if held.is_empty() or held[0] != flag.at:
		held = [flag.at, _grounded(flag.at)]
		_ground[team] = held
	return held[1]


func _grounded(at: Vector3) -> Vector3:
	if game == null or game.combat == null or game.combat.trace == null:
		return at
	var hit = game.combat.trace.ray(at + Vector3.UP * 0.6, Vector3.DOWN, 4.0)
	if hit != null and hit.ok():
		return Vector3(at.x, hit.point.y, at.z)
	return at


func _build(team: int) -> Node3D:
	var root := _add_root(team)
	for part in _BUILD_PARTS:
		call(part, root, team)
	_parts[team] = [root.get_node(^"Plate"), root.get_node(^"Icon"), root.get_node(^"Dist")]
	return root


func _add_root(team: int) -> Node3D:
	var root := Node3D.new()
	root.name = NODE_NAMES.get(team, &"Flag")
	add_child(root)
	return root


func _add_pole(root: Node3D, _team: int) -> void:
	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.85, 0.85, 0.88)
	var pole := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.04
	cyl.bottom_radius = 0.05
	cyl.height = POLE_HEIGHT
	pole.mesh = cyl
	pole.material_override = pole_mat
	pole.position = Vector3(0.0, POLE_HEIGHT * 0.5, 0.0)
	root.add_child(pole)


## The banner and the capture plate under the stand: one glowing, two-sided material in the team's colour.
func _add_cloth(root: Node3D, team: int) -> void:
	var colour := color_of(team)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	mat.emission_enabled = true
	mat.emission = colour
	mat.emission_energy_multiplier = 0.8
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var banner := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = BANNER_SIZE
	banner.mesh = quad
	banner.material_override = mat
	banner.position = Vector3(BANNER_SIZE.x * 0.5 + 0.05, POLE_HEIGHT - BANNER_SIZE.y * 0.5 - 0.1, 0.0)
	root.add_child(banner)

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


## The marker over the pole and (by default) through walls: a small see-through flag icon in the team's colour.
func _add_icon(root: Node3D, team: int) -> void:
	var colour := color_of(team)
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


## The marker's distance, beside the icon in small text.
func _add_label(root: Node3D, team: int) -> void:
	var colour := color_of(team)
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
	dist.position = Vector3(0.0, POLE_HEIGHT + 0.7, 0.0)
	root.add_child(dist)


func _add_light(root: Node3D, team: int) -> void:
	var colour := color_of(team)
	var light := OmniLight3D.new()
	light.light_color = colour
	light.omni_range = 5.0
	light.light_energy = 0.8
	light.position = Vector3(0.0, 1.5, 0.0)
	root.add_child(light)
