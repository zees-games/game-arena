extends RefCounted
## The wire between a solo client and the server process it owns (docs/sim-thread.md): one console
## line up as Ask.HOST, its answer down as the HOST sub-kind of the MORE event.

const ArenaKnifeEvents := preload("arena_knife_events.gd")
const TEXT_BYTES := 256
const SEQ_BITS := 8


static func write_line(seq: int, line: String) -> PackedByteArray:
	var w := DotNetWriter.new()
	w.write_uint(seq, SEQ_BITS)
	w.write_string(line, TEXT_BYTES)
	return w.to_bytes()


static func read_line(reader: DotNetReader) -> Dictionary:
	var out := {"seq": reader.read_uint(SEQ_BITS), "line": reader.read_string(TEXT_BYTES)}
	out["ok"] = reader.ok()
	return out


## [param done] ends the answer to [param seq] and carries whether the line worked; before it, each is a line to print.
static func write_reply(seq: int, done: bool, ok: bool, text: String) -> PackedByteArray:
	var w := DotNetWriter.new()
	w.write_varint(ArenaKnifeEvents.More.HOST)
	w.write_uint(seq, SEQ_BITS)
	w.write_bool(done)
	w.write_bool(ok)
	w.write_string(text.left(TEXT_BYTES / 2), TEXT_BYTES)
	return w.to_bytes()


## Read after the sub-kind.
static func read_reply(reader: DotNetReader) -> Dictionary:
	var out := {"seq": reader.read_uint(SEQ_BITS), "done": reader.read_bool(), "good": reader.read_bool(),
		"text": reader.read_string(TEXT_BYTES)}
	out["ok"] = reader.ok()
	return out
