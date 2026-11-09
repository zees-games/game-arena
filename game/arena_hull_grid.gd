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

## Test hook (scale128 --hullverify): every grid answer is also computed by the full scan and compared.
## Cvar `arena_hull_fast`: 0 runs the per-candidate [method ArenaGame._add_hull] for the grid's candidates.
static var fast := true
## Cvar `arena_hull_native`: with [member fast], a mover that is not lag-compensated gathers its hulls in dot-sim's
## `DotSimHullWorld` (same hulls, no script call per player); 0 or without the library, by script.
static var native := true
## With [member verify], native gathers checked against the script's (exact AABB equality) and how many differed.
static var native_verified := 0
static var native_mismatches := 0
static var verify := false
static var verified := 0
static var mismatches := 0

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
	var reach := sqrt(reach_sq)
	var x0 := int(floorf((at.x - reach) / CELL)) + BIAS
	var x1 := int(floorf((at.x + reach) / CELL)) + BIAS
	var z0 := int(floorf((at.z - reach) / CELL)) + BIAS
	var z1 := int(floorf((at.z + reach) / CELL)) + BIAS
	var out: Array = []
	for cx in range(x0, x1 + 1):
		for cz in range(z0, z1 + 1):
			var cell: Variant = _cells.get(cx * 8192 + cz)
			if cell != null:
				out.append_array(cell)
	if out.size() > 1:
		out.sort()
	return out
