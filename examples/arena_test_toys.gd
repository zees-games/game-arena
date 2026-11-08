extends RefCounted

const ArenaMap := preload("../maps/arena_map.gd")

## Test-only loose physics props. The built-in maps place none (owner 2026-11-08: toys stay in
## playground, prop hunt, murder mystery and hide n seek); the toy wire path and the
## sim stay covered by giving a test map these placements explicitly.

const BY_MAP := {
	&"dm_box": [
		{"toy": "beach_ball", "at": [12.0, 0.0, -8.0]},
		{"toy": "beach_ball", "at": [-12.0, 0.0, 8.0]},
		{"toy": "football", "at": [-20.0, 0.0, -10.0]},
		{"toy": "barrel", "at": [20.0, 0.0, 10.0], "yaw": 25.0},
		{"toy": "tyre", "at": [-20.0, 0.0, 20.0], "yaw": 60.0},
	],
	&"dm_atrium": [
		{"toy": "beach_ball", "at": [10.0, 0.0, -18.0]},
		{"toy": "beach_ball", "at": [-22.0, 0.0, 12.0]},
		{"toy": "football", "at": [4.0, 0.0, -2.0]},
		{"toy": "barrel", "at": [24.0, 0.0, 10.0]},
		{"toy": "barrel", "at": [24.8, 0.0, 10.7], "yaw": 40.0},
		{"toy": "tyre", "at": [-24.0, 0.0, -12.0], "yaw": 30.0},
		{"toy": "tyre", "at": [8.0, 0.0, 28.0], "yaw": 80.0},
	],
	&"dm_pit": [
		{"toy": "beach_ball", "at": [0.0, 0.0, 12.0]},
		{"toy": "football", "at": [10.0, 0.0, -12.0]},
	],
}


static func give(map: ArenaMap) -> ArenaMap:
	map.toys = (BY_MAP.get(map.id, []) as Array).duplicate(true)
	return map

## Makes every later [method ArenaMap.by_id] (a map change) carry the same placements.
static func install() -> void:
	ArenaMap.test_toys = BY_MAP.duplicate(true)
