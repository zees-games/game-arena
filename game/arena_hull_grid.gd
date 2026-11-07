extends RefCounted
## A spatial index of the players for [method ArenaGame.solid_hulls_for] (cvar `arena_hull_grid`): each bot asked
## for "every living player within a few metres", which scanned the whole roster, 127 reads per bot per tick at 128.
## Built once at the start of the players' loop and moved by one player's cell after that player ticked, so a
## player moved earlier in the tick is found where it moved to, as the full scan found it. The caller applies the
## same filters to the candidates in roster order, so the answer is the full scan's.

const ArenaPlayer := preload("arena_player.gd")

const CELL := 6.0
const BIAS := 4096

## Cvar `arena_hull_grid`: 0 scans the whole roster.
static var enabled := true

## Below this many players a scan is cheaper than the lookups.
const MIN_PLAYERS := 12

## True from [method begin] until the players' loop ends.
var live := false
var _cells := {}
var _key_of := PackedInt64Array()
var _index_of := {}


static func key_at(at: Vector3) -> int:
	return (int(floorf(at.x / CELL)) + BIAS) * 8192 + int(floorf(at.z / CELL)) + BIAS


static func _key_of_player(p: ArenaPlayer) -> int:
	if p == null or p.controller == null or p.controller.state == null:
		return -1
	return key_at(p.controller.state.position)


func begin(roster: Array[ArenaPlayer], ids: PackedInt64Array) -> void:
	_cells.clear()
	_index_of.clear()
	_key_of.resize(roster.size())
	for i in range(roster.size()):
		var k := _key_of_player(roster[i])
		_key_of[i] = k
		_index_of[int(ids[i])] = i
		if k >= 0:
			_put(k, i)
	live = true


func _put(k: int, i: int) -> void:
	var cell: Variant = _cells.get(k)
	if cell == null:
		_cells[k] = [i]
	else:
		(cell as Array).append(i)


## Player [param id] has just ticked: re-file it if it left its cell.
func moved(id: int, p: ArenaPlayer) -> void:
	var i: int = _index_of.get(id, -1)
	if i < 0:
		return
	var k := _key_of_player(p)
	var old := _key_of[i]
	if k == old:
		return
	if old >= 0:
		(_cells[old] as Array).erase(i)
	_key_of[i] = k
	if k >= 0:
		_put(k, i)


## Roster indices, ascending, of every player filed within [param reach_sq] (squared metres) of [param at], and some farther: the caller's own distance test decides.
func near(at: Vector3, reach_sq: float) -> Array:
	var ring := ceili(sqrt(reach_sq) / CELL)
	var cx := int(floorf(at.x / CELL)) + BIAS
	var cz := int(floorf(at.z / CELL)) + BIAS
	var out: Array = []
	for dx in range(-ring, ring + 1):
		for dz in range(-ring, ring + 1):
			var cell: Variant = _cells.get((cx + dx) * 8192 + cz + dz)
			if cell != null:
				out.append_array(cell)
	out.sort()
	return out
