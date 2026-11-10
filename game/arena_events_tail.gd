extends RefCounted

## The tail of the wire format (toys, awards, killview) and the helpers it shares with
## [code]arena_events.gd[/code], which extends this file so every caller's path is unchanged.

static func _w() -> DotNetWriter:
	return DotNetWriter.new()

const NPC_ID_BYTES := 64


# toys

static func write_toys(map_id: StringName, net_ids: PackedInt64Array) -> PackedByteArray:
	var w := _w()
	w.write_string(String(map_id), NPC_ID_BYTES)
	w.write_varint(net_ids.size())
	for id in net_ids:
		w.write_varint(maxi(int(id), 0))
	return w.to_bytes()


static func read_toys(r: DotNetReader) -> Dictionary:
	var map_id := StringName(r.read_string(NPC_ID_BYTES))
	var count := r.read_varint()
	var ids := PackedInt64Array()
	if count < 0 or count > 256:
		return {"map_id": map_id, "ids": ids, "ok": false}
	for i in count:
		ids.append(r.read_varint())
	return {"map_id": map_id, "ids": ids, "ok": r.ok()}


# award

## Bits a medal index occupies. Five is thirty-two medals; there are eleven.
const MEDAL_BITS := 5

## At most this many medals on one kill. The rules can give eight at once (a first-blood
## no-scope headshot long-shot revenge shutdown triple kill that made a nemesis); a reader
## that met more would be reading something that is not an AWARD.
const MEDALS_MAX := 12


static func write_award(
	killer_id: int, victim_id: int, points: int, streak: int, medals: Array
) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(maxi(0, killer_id))
	writer.write_varint(maxi(0, victim_id))
	writer.write_uint(clampi(points, 0, 65535), 16)
	writer.write_uint(clampi(streak, 0, 255), 8)
	var count := mini(medals.size(), MEDALS_MAX)
	writer.write_uint(count, 4)
	for i in range(count):
		writer.write_uint(clampi(int(medals[i]), 0, (1 << MEDAL_BITS) - 1), MEDAL_BITS)
	return writer.to_bytes()


static func read_award(reader: DotNetReader) -> Dictionary:
	var out := {
		"killer_id": reader.read_varint(),
		"victim_id": reader.read_varint(),
		"points": reader.read_uint(16),
		"streak": reader.read_uint(8),
	}
	var medals: Array[int] = []
	var count := mini(reader.read_uint(4), MEDALS_MAX)
	for _i in range(count):
		medals.append(reader.read_uint(MEDAL_BITS))
	out["medals"] = medals
	out["ok"] = reader.ok()
	return out


# killview

## Most bytes a KILLVIEW body ([method DotKillViewClip.pack]) may take: the event body's cap, less its framing.
const KILLVIEW_BYTES := 15000
