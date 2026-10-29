extends RefCounted
## The wire format of the WEAPON_DROP and WEAPON_SETTLED events, split from ArenaEvents; WEAPON_GONE reuses its taken pair.

const _EXTENT := 4096.0


static func _w() -> DotNetWriter:
	return DotNetWriter.new()


static func write_weapon_drop(id: int, weapon_index: int, magazine: int, reserve: int, at: Transform3D, velocity: Vector3, seconds: float, rest: bool) -> PackedByteArray:
	var w := _w()
	w.write_varint(id)
	w.write_varint(weapon_index)
	w.write_varint(maxi(0, magazine))
	w.write_varint(maxi(0, reserve))
	w.write_vector3_range(at.origin, -_EXTENT, _EXTENT, 20)
	w.write_quaternion(at.basis.get_rotation_quaternion(), 9)
	w.write_vector3_range(velocity, -64.0, 64.0, 12)
	w.write_varint(ceili(maxf(seconds, 0.0)))
	w.write_bool(rest)
	return w.to_bytes()


static func read_weapon_drop(reader: DotNetReader) -> Dictionary:
	var out := {"id": reader.read_varint(), "weapon": reader.read_varint(), "magazine": reader.read_varint(), "reserve": reader.read_varint()}
	var origin := reader.read_vector3_range(-_EXTENT, _EXTENT, 20)
	out["at"] = Transform3D(Basis(reader.read_quaternion(9)), origin)
	out["velocity"] = reader.read_vector3_range(-64.0, 64.0, 12)
	out["seconds"] = reader.read_varint()
	out["rest"] = reader.read_bool()
	out["ok"] = reader.ok()
	return out


static func write_weapon_settled(id: int, at: Transform3D) -> PackedByteArray:
	var w := _w()
	w.write_varint(id)
	w.write_vector3_range(at.origin, -_EXTENT, _EXTENT, 20)
	w.write_quaternion(at.basis.get_rotation_quaternion(), 9)
	return w.to_bytes()


static func read_weapon_settled(reader: DotNetReader) -> Dictionary:
	var out := {"id": reader.read_varint()}
	var origin := reader.read_vector3_range(-_EXTENT, _EXTENT, 20)
	out["at"] = Transform3D(Basis(reader.read_quaternion(9)), origin)
	out["ok"] = reader.ok()
	return out
