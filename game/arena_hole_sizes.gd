extends RefCounted
## How wide a bullet hole each weapon leaves, in metres across the decal. One 14 cm hole for
## every weapon read as a rifle punching plates into the wall (nightly 1722 item 7); the
## texture fades over its outer half, so the dark mark is about half the number here.

const DEFAULT := 0.06

const SIZE := {
	&"pistol": 0.045, &"revolver": 0.055, &"machine_pistol": 0.045, &"derringer": 0.045,
	&"smg": 0.05, &"carbine": 0.055, &"rifle": 0.06, &"bullpup": 0.06, &"burst_rifle": 0.06,
	&"battle_rifle": 0.07, &"marksman": 0.07, &"sniper": 0.09, &"rail": 0.09,
	# Several pellets per shot, so each is small; the group is what reads as a shotgun.
	&"shotgun": 0.035, &"drum_shotgun": 0.035,
	&"minigun": 0.055,
	# A scorch rather than a hole, and wider for it.
	&"beamer": 0.08, &"charge_rifle": 0.1,
}


static func size_of(weapon_id: StringName) -> float:
	return float(SIZE.get(weapon_id, DEFAULT))


## Resizes [param hole] (the bullet_hole scene, a Node3D holding a Decal) for [param weapon_id].
## Depth is left as the scene has it: that is how far the projection reaches, not how big the hole is.
static func fit(hole: Node, weapon_id: StringName) -> void:
	var decal := hole.get_node_or_null(^"Decal") as Decal if hole != null else null
	if decal == null:
		return
	var across := size_of(weapon_id)
	decal.size = Vector3(across, decal.size.y, across)
