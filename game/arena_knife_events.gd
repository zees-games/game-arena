extends RefCounted
## The wire format of the MORE event, the last kind the 5-bit field has: a varint sub-kind, then its body.
## KNIFE is the first sub-kind; its body is dot-weapon's DotWeaponKnifeWire.

enum More { KNIFE, HOST }


static func _w() -> DotNetWriter:
	return DotNetWriter.new()


static func write_knife(id: int, owner: int, phase: int, victim: int, at: Vector3, motion: Vector3) -> PackedByteArray:
	var w := _w()
	w.write_varint(More.KNIFE)
	DotWeaponKnifeWire.write_knife(w, id, owner, phase, victim, at, motion)
	return w.to_bytes()


## The sub-kind; the body after it is read with the matching reader.
static func read_more(reader: DotNetReader) -> int:
	return reader.read_varint()


static func read_knife(reader: DotNetReader) -> Dictionary:
	return DotWeaponKnifeWire.read_knife(reader)
