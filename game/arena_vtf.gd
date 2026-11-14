extends RefCounted

## Valve textures (VTF) and materials (VMT) read into a Godot [Image]: the stock textures `ArenaSourceInstall` takes
## from the player's own Source game install. LOCAL ONLY, like `ArenaVpk`: what is read here is cached in the user
## folder and never shipped. The same rules as dot-map-convert's `dotbsp/vtf.py` and `reader.clean_material`.

## Bytes per pixel of the uncompressed formats read, by VTF format number.
const BYTES := {0: 4, 1: 4, 2: 3, 3: 3, 5: 1, 6: 2, 12: 4, 16: 4}
## The block-compressed ones: VTF format -> [Godot format, bytes per 4x4 block].
const BLOCKS := {13: [Image.FORMAT_DXT1, 8], 14: [Image.FORMAT_DXT3, 16], 15: [Image.FORMAT_DXT5, 16]}
## A cubemap's flag: six faces per frame.
const ENVMAP := 0x4000

## Why the last [method image] gave null.
static var error := ""


## The largest mip of VTF [param data] no wider or taller than [param max_side], as RGBA8; null with [member error] set
## when it is not a VTF or its format is not one read here.
static func image(data: PackedByteArray, max_side: int = 512) -> Image:
	error = ""
	if data.size() < 64 or data.slice(0, 4).get_string_from_ascii() != "VTF":
		error = "not a vtf"
		return null
	var header_size := data.decode_u32(12)
	var w := data.decode_u16(16)
	var h := data.decode_u16(18)
	var faces := 6 if data.decode_u32(20) & ENVMAP else 1
	var frames := maxi(1, data.decode_u16(24))
	var format := data.decode_s32(52)
	var mips := maxi(1, data[56])
	var low_format := data.decode_s32(57)
	var low_w := data[61]
	var low_h := data[62]
	if not BYTES.has(format) and not BLOCKS.has(format):
		error = "vtf format %d" % format
		return null
	var at := header_size
	if low_w > 0 and low_h > 0:
		if not BYTES.has(low_format) and not BLOCKS.has(low_format):
			error = "vtf thumbnail format %d" % low_format
			return null
		at += size_of(low_format, low_w, low_h)
	# Mips are stored smallest first; each holds every frame and face of that size.
	var starts := {}
	for m in range(mips - 1, -1, -1):
		starts[m] = at
		at += size_of(format, maxi(1, w >> m), maxi(1, h >> m)) * frames * faces
	var pick := mips - 1
	for m in mips:
		if maxi(w >> m, h >> m) <= max_side:
			pick = m
			break
	var mw := maxi(1, w >> pick)
	var mh := maxi(1, h >> pick)
	var start: int = starts[pick]
	var size := size_of(format, mw, mh)
	if start + size > data.size():
		error = "vtf cut short"
		return null
	return _decode(format, mw, mh, data.slice(start, start + size))


## Bytes of one [param w] x [param h] image in VTF [param format].
static func size_of(format: int, w: int, h: int) -> int:
	if BLOCKS.has(format):
		return maxi(1, (w + 3) / 4) * maxi(1, (h + 3) / 4) * int(BLOCKS[format][1])
	return w * h * int(BYTES.get(format, 4))


static func _decode(format: int, w: int, h: int, px: PackedByteArray) -> Image:
	var img: Image
	if BLOCKS.has(format):
		# Godot wants whole blocks: a mip under 4 pixels is drawn from its block, cropped.
		var bw := maxi(4, (w + 3) / 4 * 4)
		var bh := maxi(4, (h + 3) / 4 * 4)
		img = Image.create_from_data(bw, bh, false, int(BLOCKS[format][0]), px)
		if img == null or img.decompress() != OK:
			error = "dxt decode"
			return null
		if bw != w or bh != h:
			img = img.get_region(Rect2i(0, 0, w, h))
	elif format == 0:
		img = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, px)
	elif format == 2:
		img = Image.create_from_data(w, h, false, Image.FORMAT_RGB8, px)
	elif format == 5:
		img = Image.create_from_data(w, h, false, Image.FORMAT_L8, px)
	elif format == 6:
		img = Image.create_from_data(w, h, false, Image.FORMAT_LA8, px)
	else:
		img = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, _to_rgba(format, px))
	if img == null:
		error = "vtf decode"
		return null
	img.convert(Image.FORMAT_RGBA8)
	return img


## ABGR8888 (1), BGR888 (3), BGRA8888 (12) and BGRX8888 (16) to RGBA8.
static func _to_rgba(format: int, px: PackedByteArray) -> PackedByteArray:
	var step: int = BYTES[format]
	var n := px.size() / step
	var out := PackedByteArray()
	out.resize(n * 4)
	for i in n:
		var s := i * step
		var o := i * 4
		match format:
			1:
				out[o] = px[s + 3]
				out[o + 1] = px[s + 2]
				out[o + 2] = px[s + 1]
				out[o + 3] = px[s]
			3:
				out[o] = px[s + 2]
				out[o + 1] = px[s + 1]
				out[o + 2] = px[s]
				out[o + 3] = 255
			_:
				out[o] = px[s + 2]
				out[o + 1] = px[s + 1]
				out[o + 2] = px[s]
				out[o + 3] = px[s + 3] if format == 12 else 255
	return out


## Lower-case key -> value of a VMT's key/value pairs at any depth (the first of each key), quotes removed: enough for
## `$basetexture` and a patch material's `include`. Read as KeyValues tokens, so one-line blocks count too.
static func vmt_keys(text: String) -> Dictionary:
	var out := {}
	var tokens := PackedStringArray()
	var token := RegEx.create_from_string("\"([^\"]*)\"|([{}])|([^\\s\"{}]+)")
	for line in text.split("\n"):
		for m in token.search_all(_uncomment(line)):
			tokens.append(m.get_string(0) if m.get_string(2) != "" else (m.get_string(1) if m.get_start(1) >= 0 else m.get_string(3)))
	var i := 0
	while i < tokens.size() - 1:
		var key := tokens[i]
		var value := tokens[i + 1]
		if key == "{" or key == "}" or value == "{" or value == "}":
			i += 1
			continue
		if not out.has(key.to_lower()):
			out[key.to_lower()] = value.strip_edges()
		i += 2
	return out


## [param line] without a `//` comment outside quotes.
static func _uncomment(line: String) -> String:
	var inside := false
	for i in line.length() - 1:
		if line[i] == "\"":
			inside = not inside
		elif not inside and line[i] == "/" and line[i + 1] == "/":
			return line.left(i)
	return line


## The base material name as the converter writes it (dot-map-convert `reader.clean_material`): lower case, `/`, no
## leading `/`, and a cubemap-patched `maps/<map>/<path>_x_y_z` back to `<path>`.
static func clean_material(material: String) -> String:
	var m := material.to_lower().replace("\\", "/").lstrip("/")
	var patched := RegEx.create_from_string("^maps/[^/]+/").sub(m, "")
	if patched == m:
		return m
	return RegEx.create_from_string("_-?\\d+_-?\\d+_-?\\d+$").sub(patched, "")


## The file name an `_orig` pack gives [param material]'s texture (dot-map-convert `origtex.safe`), without `.png`.
static func safe_name(material: String) -> String:
	var s := RegEx.create_from_string("[^a-z0-9_.-]+").sub(clean_material(material), "_", true).left(80)
	return s if s != "" else "unnamed"
