extends RefCounted

## Turns the view arms' hands onto a gun and closes their fingers round it, after the arms' IK has placed the wrists.
## The kit has no wrist bone: the four finger roots share the wrist, so turning all four together is the wrist's turn.

const ROOTS: Array[String] = ["Index1", "Middle1", "Pinky1", "Thumb1"]
const CURLED: Array[String] = ["Index2", "Index3", "Middle2", "Middle3", "Pinky2", "Pinky3", "Thumb2"]
## Finger bend at the knuckle and the last joint as a share of `curl` (the thumb bends less).
const JOINT_SHARE := {"2": 1.0, "3": 0.85, "Thumb2": 0.45}
const GRIP_CURL := 80.0
const SUPPORT_CURL := 55.0
## How far the palm-up support hand's wrist rises above the fore-end point, for the palm below its bones (life-size metres).
const SUPPORT_LIFT := 0.07
## Poses whose hands close on a pistol grip and a fore-end; anything else keeps the kit's open hands.
const GUN_POSES: Array[StringName] = [&"rifle", &"pistol", &"heavy"]


## Poses both hands of [param skeleton] for [param grip] (AwViewModel.art_hand_grip()); [param two_hand] also poses the left.
static func apply(skeleton: Skeleton3D, grip: Dictionary, two_hand: bool) -> void:
	if skeleton == null or not grip.has("forward") or not grip.get("pose") in GUN_POSES:
		return
	# The gun's right is taken in the world: a mirrored arms rig would flip a cross product taken in the skeleton.
	var world_fwd: Vector3 = (grip["forward"] as Vector3).normalized()
	var world_right := world_fwd.cross(grip["up"] as Vector3).normalized()
	var to_skel := skeleton.global_transform.basis.inverse()
	var fwd := (to_skel * world_fwd).normalized()
	var right := (to_skel * world_right).normalized()
	var up := (to_skel * world_right.cross(world_fwd)).normalized()
	# A pistol grip rakes back: its axis runs up and forward; the straight fingers cross it.
	var grip_axis := (up + fwd * 0.3).normalized()
	var across := (fwd - grip_axis * fwd.dot(grip_axis)).normalized()
	_hand(skeleton, ".R", -right, across, float(grip.get("curl", GRIP_CURL)))
	if not two_hand:
		return
	if not palm_up(grip):
		# Palm in on the left of the firing hand, fingers forward over it.
		_hand(skeleton, ".L", right, across, float(grip.get("support_curl", SUPPORT_CURL)))
	else:
		# Palm up under the fore-end, fingers round its right side.
		_hand(skeleton, ".L", up, right, float(grip.get("support_curl", SUPPORT_CURL)))


## True when [param grip]'s support hand cups the fore-end from below rather than closing over the firing hand.
static func palm_up(grip: Dictionary) -> bool:
	return grip.get("pose") in GUN_POSES and str(grip.get("support", "side" if grip.get("pose") == &"pistol" else "under")) == "under"


## Turns one hand so its palm faces [param palm_dir] and its straight fingers run along [param finger_dir], then curls them.
static func _hand(skeleton: Skeleton3D, side: String, palm_dir: Vector3, finger_dir: Vector3, curl: float) -> void:
	var middle := skeleton.find_bone("Middle1" + side)
	var index := skeleton.find_bone("Index2" + side)
	var pinky := skeleton.find_bone("Pinky2" + side)
	if middle < 0 or index < 0 or pinky < 0:
		return
	for root in ROOTS:
		var b := skeleton.find_bone(root + side)
		if b >= 0:
			skeleton.set_bone_pose_rotation(b, skeleton.get_bone_rest(b).basis.get_rotation_quaternion())
	for joint in CURLED:
		var b := skeleton.find_bone(joint + side)
		if b >= 0:
			skeleton.set_bone_pose_rotation(b, skeleton.get_bone_rest(b).basis.get_rotation_quaternion())
	var now_d := _rot(skeleton, middle).y
	var now_s := _global(skeleton, index).origin - _global(skeleton, pinky).origin
	# Which way the palm faces is read off the kit's resting curl of the last index joint, not assumed from the side's name.
	var tip := _rot(skeleton, skeleton.find_bone("Index3" + side)).y
	var knuckle := _rot(skeleton, index).y
	var bend := tip - knuckle * tip.dot(knuckle)
	var hand := 1.0 if side == ".R" else -1.0
	if bend.length() > 0.2:
		hand = signf(bend.dot(now_s.cross(now_d)))
	var now := _frame(now_s, now_d, hand)
	var want := _frame(finger_dir.cross(palm_dir) * hand, finger_dir, hand)
	var turn := (want * now.inverse()).orthonormalized()
	for root in ROOTS:
		var b := skeleton.find_bone(root + side)
		if b >= 0:
			_set_global_rot(skeleton, b, turn * _rot(skeleton, b))
	var palm: Vector3 = want.z
	for joint in CURLED:
		var b := skeleton.find_bone(joint + side)
		if b < 0:
			continue
		var share := float(JOINT_SHARE.get(joint, JOINT_SHARE[joint.right(1)]))
		var g := _rot(skeleton, b)
		var axis := g.y.cross(palm)
		if axis.length_squared() < 1e-6:
			continue
		_set_global_rot(skeleton, b, Basis(axis.normalized(), deg_to_rad(curl * share)) * g)


## Index side, finger direction and palm normal as columns; the palm faces `s x d` times [param hand].
static func _frame(s: Vector3, d: Vector3, hand: float) -> Basis:
	var dn := d.normalized()
	var sn := (s - dn * s.dot(dn)).normalized()
	return Basis(sn, dn, sn.cross(dn) * hand)


static func _rot(skeleton: Skeleton3D, bone: int) -> Basis:
	return _global(skeleton, bone).basis.orthonormalized()


## The bone's pose in the skeleton from the local poses just set: get_bone_global_pose is not refreshed until the skeleton updates.
static func _global(skeleton: Skeleton3D, bone: int) -> Transform3D:
	var t := skeleton.get_bone_pose(bone)
	var parent := skeleton.get_bone_parent(bone)
	while parent >= 0:
		t = skeleton.get_bone_pose(parent) * t
		parent = skeleton.get_bone_parent(parent)
	return t


static func _set_global_rot(skeleton: Skeleton3D, bone: int, global_rot: Basis) -> void:
	var parent := skeleton.get_bone_parent(bone)
	var parent_rot := _rot(skeleton, parent) if parent >= 0 else Basis.IDENTITY
	skeleton.set_bone_pose_rotation(bone, (parent_rot.inverse() * global_rot).get_rotation_quaternion())
