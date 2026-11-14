extends RefCounted

## One Valve VPK archive set (v1 or v2: a `<base>_dir.vpk` and its `<base>_NNN.vpk` parts) on the player's own disk.
##
## [b]LOCAL ONLY.[/b] It reads the stock textures of a Source game the player installed (`ArenaSourceInstall`), to draw
## a dropped `<map>_orig` pack on that machine. Nothing it reads is ever written into the repository or a pack that
## leaves the machine: Valve's files are not ours to ship. dot-map-convert's `dotbsp/vpk.py` is the same reader for
## the converter (internal, offline); this one runs in the game.
##
## [codeblock]
## var vpk := ArenaVpk.new()
## if vpk.open("C:/…/tf/tf2_textures_dir.vpk", PackedStringArray(["vmt", "vtf"])):
##     var bytes := vpk.read("materials/brick/brickwall003.vtf")  # empty and [member error] set when absent or broken
## [/codeblock]

const SIG := 0x55AA1234
## The archive index of a file stored after the tree in the `_dir.vpk` itself.
const IN_DIR := 0x7FFF

## The `_dir.vpk` read.
var dir_path := ""
## The parts' name before `_NNN.vpk`.
var base := ""
## Where data stored in the `_dir.vpk` starts.
var data_start := 0
## Lower-case path -> [archive, offset, length, crc, preload bytes].
var entries: Dictionary = {}
## Why the last [method open] or [method read] failed; empty when it did not.
var error := ""

static var _crc_table := PackedInt64Array()


## Reads the tree of [param dir_vpk]; only files whose extension is in [param only_ext] (lower case, no dot) are kept
## when it is not empty. False with [member error] set when it is not a VPK v1/v2 or is cut short.
func open(dir_vpk: String, only_ext: PackedStringArray = PackedStringArray()) -> bool:
	error = ""
	entries.clear()
	dir_path = dir_vpk
	if not dir_vpk.ends_with("_dir.vpk"):
		return _fail("not a *_dir.vpk: %s" % dir_vpk)
	base = dir_vpk.trim_suffix("_dir.vpk")
	var f := FileAccess.open(dir_vpk, FileAccess.READ)
	if f == null:
		return _fail("cannot open %s (%s)" % [dir_vpk, error_string(FileAccess.get_open_error())])
	var head := f.get_buffer(12)
	if head.size() < 12:
		return _fail("short header: %s" % dir_vpk)
	var version := head.decode_u32(4)
	if head.decode_u32(0) != SIG or (version != 1 and version != 2):
		return _fail("not a VPK v1/v2: %s" % dir_vpk)
	if version == 2:
		f.seek(28)
	var tree_size := head.decode_u32(8)
	var tree := f.get_buffer(tree_size)
	data_start = f.get_position()
	if tree.size() < tree_size:
		return _fail("truncated tree: %s" % dir_vpk)
	return _parse(tree, only_ext)


func _parse(tree: PackedByteArray, only_ext: PackedStringArray) -> bool:
	var pos := 0
	while true:
		var end := tree.find(0, pos)
		if end < 0:
			return _fail("malformed tree: %s" % dir_path)
		var ext := tree.slice(pos, end).get_string_from_utf8()
		pos = end + 1
		if ext == "":
			return true
		var keep := only_ext.is_empty() or only_ext.has(ext.to_lower())
		while true:
			end = tree.find(0, pos)
			if end < 0:
				return _fail("malformed tree: %s" % dir_path)
			var folder := tree.slice(pos, end).get_string_from_utf8()
			pos = end + 1
			if folder == "":
				break
			while true:
				end = tree.find(0, pos)
				if end < 0:
					return _fail("malformed tree: %s" % dir_path)
				var leaf := tree.slice(pos, end).get_string_from_utf8()
				pos = end + 1
				if leaf == "":
					break
				if pos + 18 > tree.size():
					return _fail("malformed tree: %s" % dir_path)
				var preload_size := tree.decode_u16(pos + 4)
				if tree.decode_u16(pos + 16) != 0xFFFF or pos + 18 + preload_size > tree.size():
					return _fail("bad entry in %s" % dir_path)
				if keep:
					var file := leaf if ext == " " else leaf + "." + ext
					var path := file if folder == " " else folder + "/" + file
					entries[path.to_lower().replace("\\", "/")] = [tree.decode_u16(pos + 6), tree.decode_u32(pos + 8),
						tree.decode_u32(pos + 12), tree.decode_u32(pos), tree.slice(pos + 18, pos + 18 + preload_size)]
				pos += 18 + preload_size
	return true


## Whether [param path] is in the archive.
func has(path: String) -> bool:
	return entries.has(path.to_lower())


## The bytes of [param path], CRC-checked; empty with [member error] set when it is absent, its part is missing (a
## dedicated server lists archives it does not ship) or it does not match its CRC.
func read(path: String) -> PackedByteArray:
	error = ""
	var e: Array = entries.get(path.to_lower(), [])
	if e.is_empty():
		error = "not in %s: %s" % [dir_path.get_file(), path]
		return PackedByteArray()
	var length: int = e[2]
	var out: PackedByteArray = (e[4] as PackedByteArray).duplicate()
	if length > 0:
		var part := dir_path if int(e[0]) == IN_DIR else "%s_%03d.vpk" % [base, int(e[0])]
		var f := FileAccess.open(part, FileAccess.READ)
		if f == null:
			error = "cannot open %s" % part
			return PackedByteArray()
		f.seek((data_start if int(e[0]) == IN_DIR else 0) + int(e[1]))
		var body := f.get_buffer(length)
		if body.size() != length:
			error = "short read of %s" % path
			return PackedByteArray()
		out.append_array(body)
	if crc32(out) != int(e[3]):
		error = "crc mismatch: %s" % path
		return PackedByteArray()
	return out


## The CRC-32 (zlib's) of [param data].
static func crc32(data: PackedByteArray) -> int:
	if _crc_table.is_empty():
		_crc_table.resize(256)
		for n in 256:
			var c := n
			for _k in 8:
				c = (0xEDB88320 ^ (c >> 1)) if c & 1 else (c >> 1)
			_crc_table[n] = c
	var crc := 0xFFFFFFFF
	for b in data:
		crc = _crc_table[(crc ^ b) & 0xFF] ^ (crc >> 8)
	return crc ^ 0xFFFFFFFF


func _fail(why: String) -> bool:
	error = why
	entries.clear()
	return false
