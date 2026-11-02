extends RigidBody3D
## Put on a spawned prop so a shot treats it as a breakable: the combat manager calls hurt() on anything that has it.

var damage: DotPropDamage = null
var prop_id := 0


func hurt(amount: float, _at: Vector3 = Vector3.ZERO, by: StringName = &"") -> bool:
	if damage == null or not damage.is_breakable(prop_id):
		return false
	return damage.hurt(prop_id, amount, by).ok


func is_broken() -> bool:
	return damage == null or not damage.is_breakable(prop_id)
