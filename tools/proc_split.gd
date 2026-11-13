extends Node

## Bench probe (`--proc-split 1`): splits the engine's process phase by wall clock into the early flush (process_frame
## to the first _process), the _process pass, the late flush (deferred calls such as Skeleton3D pose updates) and the
## rest up to RenderingServer.frame_pre_draw (transform notifications, timers, tweens). Also a census of what processes.

var frames := 0
var us := PackedInt64Array([0, 0, 0, 0])
var _t := PackedInt64Array([0, 0, 0, 0])


class Edge extends Node:
	var on_process: Callable

	func _process(_delta: float) -> void:
		on_process.call()


func _ready() -> void:
	var first := Edge.new()
	first.process_priority = -2147483647
	first.on_process = func() -> void: _t[1] = Time.get_ticks_usec()
	add_child(first)
	process_priority = 2147483647
	var _a := get_tree().process_frame.connect(func() -> void: _t[0] = Time.get_ticks_usec())
	var _b := RenderingServer.frame_pre_draw.connect(_on_pre_draw)


func _exit_tree() -> void:
	if RenderingServer.frame_pre_draw.is_connected(_on_pre_draw):
		RenderingServer.frame_pre_draw.disconnect(_on_pre_draw)


func _process(_delta: float) -> void:
	_t[2] = Time.get_ticks_usec()
	_flushed.call_deferred()


func _flushed() -> void:
	_t[3] = Time.get_ticks_usec()


func _on_pre_draw() -> void:
	var now := Time.get_ticks_usec()
	if _t[0] == 0 or _t[3] < _t[2] or _t[2] < _t[1] or _t[1] < _t[0]:
		return
	us[0] += _t[1] - _t[0]
	us[1] += _t[2] - _t[1]
	us[2] += _t[3] - _t[2]
	us[3] += now - _t[3]
	frames += 1


## ms per frame of each part.
func report() -> Dictionary:
	var n := maxf(frames, 1.0)
	return {"frames": frames, "early_flush": snappedf(us[0] / 1000.0 / n, 0.001), "process_pass": snappedf(us[1] / 1000.0 / n, 0.001),
		"late_flush": snappedf(us[2] / 1000.0 / n, 0.001), "to_pre_draw": snappedf(us[3] / 1000.0 / n, 0.001)}


## Nodes per class that run an engine (internal) process or physics process, scripts with a _process, and skeleton facts.
static func census(root: Node) -> Dictionary:
	var internal := {}
	var internal_phys := {}
	var scripted := {}
	var skel := {"count": 0, "bones": 0, "modifiers": 0, "attachments": 0, "mixers_auto": 0, "mixers_manual": 0}
	var classes := {}
	var scripted_phys := {}
	var bodies := {"static": 0, "character": 0, "rigid": 0, "area": 0, "other": 0, "shapes": 0, "areas_monitoring": 0}
	var meshes := {"total": 0, "visible": 0, "skinned": 0, "shadow_casting": 0, "multimesh": 0}
	var lights := {"total": 0, "shadowed": 0, "omni": 0, "spot": 0, "directional": 0}
	var misc := {"gpu_particles": 0, "cpu_particles": 0, "audio_players": 0, "audio_playing": 0, "signal_connections": 0}
	var total := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		var cls := n.get_class()
		total += 1
		classes[cls] = int(classes.get(cls, 0)) + 1
		for s: Dictionary in n.get_signal_list():
			misc.signal_connections += n.get_signal_connection_list(StringName(s["name"])).size()
		if n.is_physics_processing() and n.get_script() != null:
			var pp := (n.get_script() as Script).resource_path.get_file()
			if pp == "":
				pp = "inner %s" % String(n.name).rstrip("0123456789@")
			scripted_phys[pp] = int(scripted_phys.get(pp, 0)) + 1
		if n is CollisionObject3D:
			var co := n as CollisionObject3D
			for owner_id: int in co.get_shape_owners():
				bodies.shapes += co.shape_owner_get_shape_count(owner_id)
			if n is Area3D:
				bodies.area += 1
				if (n as Area3D).monitoring:
					bodies.areas_monitoring += 1
			elif n is CharacterBody3D:
				bodies.character += 1
			elif n is RigidBody3D:
				bodies.rigid += 1
			elif n is StaticBody3D:
				bodies.static += 1
			else:
				bodies.other += 1
		elif n is MeshInstance3D:
			var mi := n as MeshInstance3D
			meshes.total += 1
			if mi.is_visible_in_tree():
				meshes.visible += 1
				if mi.skin != null or (not mi.skeleton.is_empty() and mi.get_node_or_null(mi.skeleton) is Skeleton3D):
					meshes.skinned += 1
				if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
					meshes.shadow_casting += 1
		elif n is MultiMeshInstance3D:
			meshes.multimesh += 1
		elif n is Light3D:
			var li := n as Light3D
			if li.is_visible_in_tree():
				lights.total += 1
				if li.shadow_enabled:
					lights.shadowed += 1
				if li is OmniLight3D:
					lights.omni += 1
				elif li is SpotLight3D:
					lights.spot += 1
				else:
					lights.directional += 1
		elif n is GPUParticles3D:
			misc.gpu_particles += 1
		elif n is CPUParticles3D:
			misc.cpu_particles += 1
		elif n is AudioStreamPlayer3D or n is AudioStreamPlayer:
			misc.audio_players += 1
			if bool(n.get("playing")):
				misc.audio_playing += 1
		if n.is_processing_internal():
			internal[cls] = int(internal.get(cls, 0)) + 1
		if n.is_physics_processing_internal():
			internal_phys[cls] = int(internal_phys.get(cls, 0)) + 1
		if n.is_processing() and n.get_script() != null:
			var p := (n.get_script() as Script).resource_path.get_file()
			if p == "":
				# A built-in or inner-class script: named by the node (digits off) under its parent.
				p = "inner %s/%s" % [n.get_parent().name if n.get_parent() != null else "", String(n.name).rstrip("0123456789@")]
			scripted[p] = int(scripted.get(p, 0)) + 1
		if n is Skeleton3D:
			skel.count += 1
			skel.bones += (n as Skeleton3D).get_bone_count()
		elif n is SkeletonModifier3D:
			skel.modifiers += 1
		elif n is BoneAttachment3D:
			skel.attachments += 1
		elif n is AnimationMixer:
			var m := n as AnimationMixer
			if m.callback_mode_process == AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL or not m.active:
				skel.mixers_manual += 1
			else:
				skel.mixers_auto += 1
	var top: Array = classes.keys()
	top.sort_custom(func(a: Variant, b: Variant) -> bool: return int(classes[a]) > int(classes[b]))
	var top_classes := {}
	for c: Variant in top.slice(0, 15):
		top_classes[c] = classes[c]
	return {"internal_process": internal, "internal_physics": internal_phys, "scripted_process": scripted,
		"scripted_physics": scripted_phys, "skeleton": skel, "nodes": total, "top_classes": top_classes,
		"bodies": bodies, "meshes": meshes, "lights": lights, "misc": misc}
