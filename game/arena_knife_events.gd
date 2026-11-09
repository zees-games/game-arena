extends RefCounted
## The wire format of the MORE event, the last kind the 5-bit field has: a varint sub-kind, then its body.
## KNIFE is the first sub-kind: one thrown knife's id, owner, phase, victim, where and how it moves.

enum More { KNIFE }

const _EXTENT := 4096.0


static func _w() -> DotNetWriter:
	return DotNetWriter.new()


static func write_knife(id: int, owner: int, phase: int, victim: int, at: Vector3, motion: Vector3) -> PackedByteArray:
	var w := _w()
	w.write_varint(More.KNIFE)
	w.write_varint(id)
	w.write_varint(maxi(0, owner))
	w.write_uint(clampi(phase, 0, 3), 2)
	w.write_varint(maxi(0, victim))
	w.write_vector3_range(at, -_EXTENT, _EXTENT, 20)
	w.write_vector3_range(motion, -64.0, 64.0, 12)
	return w.to_bytes()


## The sub-kind; the body after it is read with the matching reader.
static func read_more(reader: DotNetReader) -> int:
	return reader.read_varint()


static func read_knife(reader: DotNetReader) -> Dictionary:
	var out := {"id": reader.read_varint(), "owner": reader.read_varint(), "phase": reader.read_uint(2), "victim": reader.read_varint()}
	out["at"] = reader.read_vector3_range(-_EXTENT, _EXTENT, 20)
	out["motion"] = reader.read_vector3_range(-64.0, 64.0, 12)
	out["ok"] = reader.ok()
	return out
