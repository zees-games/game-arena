extends Node3D

## The visible body of an arena monster, generated rather than modelled.
##
## [b]A plain [Node3D], not a [CharacterBody3D], and that is the same decision
## [ArenaPlayer] makes.[/b] This game's collision is [ArenaMap]'s analytic geometry —
## exact, needing no physics space, and giving the same answer on a client replaying a
## tick and a server that ran it. An NPC on Godot physics would be a second solver in
## a game that deliberately has none, and on a headless dedicated server it would have
## no space to be solved in. [method DotNpcBrain.steer_toward] handles a plain
## [Node3D] for exactly this case, and [DotNpcNavGraph] is what keeps one out of the
## walls.
##
## [b]Extended by nothing and referenced by PATH.[/b] A `class_name` here would be a
## global identifier reserved in every consuming project for a capsule, and — the
## reason that actually matters — a script inside a mounted dot-cloud pack cannot
## resolve one. `scene_path` in the catalogue and `extends` by path are what a
## delivered NPC must look like, so the shipped ones look like it too.
##
## The mesh is built in `_ready` rather than saved into the scene so the scene file is
## the three numbers that differ between one monster and the next. There is no art in
## this project by design.

## Radius of the trunk, in metres.
@export var body_radius: float = 0.45

## Total height. The head sits on top of it.
@export var body_height: float = 1.6

@export var tint: Color = Color(0.85, 0.30, 0.25)

## Drawn at all. Off on a dedicated server, which has no renderer to draw into and no
## reason to build a mesh per monster.
@export var visible_body: bool = true

## Which of the character kit's eighteen atlases this monster wears, by its letter. Empty
## draws the capsule.
##
## [b]A monster drawn as a capsule read as "no model".[/b] The kit is already shipped for
## players' avatars (`avatars/kenney/`), so a monster is that figure in an atlas nobody's
## avatar is likely to be (the robots and the green-faced one), tinted toward its kind's
## colour so the four kinds are told apart at a glance. Its height is [member body_height];
## the collision is not this node's and does not change.
@export var skin: String = ""

const ArenaPaths := preload("../game/arena_paths.gd")


func _ready() -> void:
	if not visible_body or Engine.is_editor_hint():
		return

	if skin != "" and _build_figure():
		return

	var material := StandardMaterial3D.new()
	material.albedo_color = tint
	material.roughness = 0.9

	var trunk := MeshInstance3D.new()
	trunk.name = "Trunk"
	var capsule := CapsuleMesh.new()
	capsule.radius = body_radius
	capsule.height = maxf(body_height, body_radius * 2.0 + 0.05)
	trunk.mesh = capsule
	trunk.material_override = material
	trunk.position = Vector3(0.0, body_height * 0.5, 0.0)
	add_child(trunk)

	# A snout, so which way it is facing is visible from across the arena. The smaller
	# shape has to sit OUTSIDE the larger one or the silhouette is a single blob —
	# game-playground drew every NPC icon as a coloured bar that way, and it took a
	# screenshot rather than an assertion to see it.
	var snout := MeshInstance3D.new()
	snout.name = "Snout"
	var box := BoxMesh.new()
	box.size = Vector3(body_radius * 0.5, body_radius * 0.5, body_radius * 1.1)
	snout.mesh = box
	snout.material_override = material
	snout.position = Vector3(
		0.0, body_height * 0.82, -(body_radius + box.size.z * 0.5)
	)
	add_child(snout)


## The kit's figure, turned to face -Z (it is glTF, which faces +Z) and scaled to
## [member body_height]. False when the art is not in this build, so the capsule draws.
func _build_figure() -> bool:
	var scene: Variant = load(ArenaPaths.rebase("res://avatars/kenney/character-a.glb"))
	var texture: Variant = load(ArenaPaths.rebase("res://avatars/kenney/Textures/texture-%s.png" % skin))

	if not (scene is PackedScene) or not (texture is Texture2D):
		return false

	var model := (scene as PackedScene).instantiate() as Node3D
	if model == null:
		return false

	var material := StandardMaterial3D.new()
	material.albedo_texture = texture
	# The atlas's own colours, nudged toward the kind's tint: enough to tell a grunt from a
	# brute at range, not so much that the figure is a silhouette.
	material.albedo_color = Color.WHITE.lerp(tint, 0.35)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

	var low := INF
	var high := -INF
	for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		mesh.material_override = material
		var box := _to_model(mesh, model) * mesh.get_aabb()
		low = minf(low, box.position.y)
		high = maxf(high, box.end.y)

	var anim := model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if anim != null:
		anim.stop()
		anim.active = false

	var scale_by := body_height / maxf(high - low, 0.01) if is_finite(low) else 1.0
	model.name = "Figure"
	model.basis = Basis(Vector3.UP, PI).scaled(Vector3.ONE * scale_by)
	model.position = Vector3(0.0, -low * scale_by, 0.0)
	add_child(model)
	return true


static func _to_model(node: Node3D, root: Node3D) -> Transform3D:
	var out := Transform3D.IDENTITY
	var walk: Node = node
	while walk != null and walk != root:
		if walk is Node3D:
			out = (walk as Node3D).transform * out
		walk = walk.get_parent()
	return out
