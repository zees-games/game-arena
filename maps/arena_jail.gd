extends RefCounted

## A combat surf map's jail, read out of its teleport volumes and made into a place with a gate.
##
## [b]What the map ships.[/b] No names, only `trigger_teleport` volumes (see `ArenaMap.pits`): the
## pits under the ramps aim at a point on the jail's button, a volume around that point aims at
## the cell, and two volumes at the cell's far side aim back at the top of a ramp. In the engine
## the map came from, the button opens a door in front of those two. The door is not solid in
## the import, so the way out was always open and the button was only a hop into the cell.
##
## [b]What this does with them[/b], while [member enabled] (`arena_jail`):
## - a fall (a pit that aims at the button) puts the player [i]in the cell[/i];
## - the button volume teleports nobody. Standing in it presses the button, which opens the gate
##   for [member open_ticks] and then keeps it shut for [member cooldown_ticks];
## - the way out is the two exit volumes, and they work only while the gate is open. Shut, a
##   player who walks into one is put back in the cell.
##
## [b]Pure functions of the tick and of one number, [member opened_at].[/b] The player's tick
## asks [method resolve] on the server and on the owning client's prediction alike, and the one
## fact that is not in the map (when the gate was last opened) is sent to clients (JAIL).
## Nothing here is physics: a door that collided would have to be toggled in the middle of a
## tick on both ends, and a closed door that is a volume putting you back needs no such thing.
##
## Found by shape, never by a map's name: a map that has this arrangement gets a jail, and the
## suite names the one that has it today.

const CHANNEL := "arena.jail"

## What a pit is to the jail.
enum Role { NONE, FALL, BUTTON, EXIT }

## Whether the jail is a jail. Off, every volume does what the map says.
var enabled: bool = true

## How long a press holds the gate open, in ticks, and how long it then stays shut.
var open_ticks: int = 640
var cooldown_ticks: int = 1280

## The tick the gate was last opened, or -1 for never. The one thing a client has to be told.
var opened_at: int = -1

## pit index -> Role, for the pits that have one.
var roles: Dictionary = {}

## The index of the button's pit (the cell is its `to`), and of each exit.
var button_index: int = -1
var exit_indices: Array[int] = []

## The pits, shared with the map (a reference: the map's destinations are lifted out of solids
## after import, and this reads them live).
var _pits: Array[Dictionary] = []


## The jail of [param pits], or null when they have none. A button is a pit whose volume holds
## where at least two others aim and which itself aims somewhere outside every volume; its
## exits are the pits within [param exit_reach] metres of its destination that aim far away.
static func detect(pits: Array[Dictionary], exit_reach: float = 8.0) -> RefCounted:
	for index in range(pits.size()):
		var candidate := _falls_into(pits, index)
		if candidate.size() < 2:
			continue

		var cell: Vector3 = pits[index]["to"]
		if _pit_holding(pits, cell, index) != -1:
			continue

		var exits: Array[int] = []
		for other in range(pits.size()):
			if other == index or candidate.has(other):
				continue
			var box: AABB = pits[other]["box"]
			var to: Vector3 = pits[other]["to"]
			if box.get_center().distance_to(cell) <= exit_reach and to.distance_to(cell) > exit_reach * 2.0:
				exits.append(other)

		if exits.is_empty():
			continue

		var jail: RefCounted = new()
		jail._pits = pits
		jail.button_index = index
		jail.exit_indices = exits
		jail.roles[index] = Role.BUTTON
		for fall in candidate:
			jail.roles[fall] = Role.FALL
		for gate in exits:
			jail.roles[gate] = Role.EXIT
		return jail

	return null


## The pits whose destination is inside the volume of pit [param index].
static func _falls_into(pits: Array[Dictionary], index: int) -> Array[int]:
	var out: Array[int] = []
	var box: AABB = (pits[index]["box"] as AABB).grow(0.3)
	for other in range(pits.size()):
		if other != index and box.has_point(pits[other]["to"]):
			out.append(other)
	return out


## The first pit (other than [param besides]) whose volume holds [param point], or -1.
static func _pit_holding(pits: Array[Dictionary], point: Vector3, besides: int) -> int:
	for index in range(pits.size()):
		if index != besides and (pits[index]["box"] as AABB).has_point(point):
			return index
	return -1


## Where the cell is: a player put in the jail stands here, facing [method cell_yaw].
func cell() -> Vector3:
	return _pits[button_index]["to"]


func cell_yaw() -> float:
	return float(_pits[button_index]["yaw"])


## The button's volume, for whoever presses it.
func button_box() -> AABB:
	return _pits[button_index]["box"]


## Whether the gate is open at [param tick].
func is_open(tick: int) -> bool:
	return enabled and opened_at >= 0 and tick >= opened_at and tick < opened_at + open_ticks


## Seconds-free form for a HUD or a door: how much of the open time is left, 0 to 1, or 0.
func open_left(tick: int) -> float:
	if not is_open(tick):
		return 0.0
	return float(opened_at + open_ticks - tick) / float(maxi(open_ticks, 1))


## Whether a press at [param tick] would open the gate: the gate is shut and the cooldown that
## follows an opening is over.
func can_press(tick: int) -> bool:
	return enabled and (opened_at < 0 or tick >= opened_at + open_ticks + cooldown_ticks)


## Ticks until a press works, 0 when it does.
func cooldown_left(tick: int) -> int:
	if can_press(tick):
		return 0
	return maxi(opened_at + open_ticks + cooldown_ticks - tick, 0)


## Opens the gate at [param tick]. False when it cannot be (see [method can_press]).
func press(tick: int) -> bool:
	if not can_press(tick):
		return false
	opened_at = tick
	return true


## What a player standing in pit [param index] at [param tick] is sent through: the pit's own
## `{box, to, yaw}`, a replacement, or an empty dictionary for none. The one rule of the jail.
func resolve(index: int, tick: int) -> Dictionary:
	var pit: Dictionary = _pits[index]
	if not enabled or not roles.has(index):
		return pit

	match int(roles[index]):
		Role.FALL:
			return {"box": pit["box"], "to": cell(), "yaw": cell_yaw()}
		Role.BUTTON:
			return {}
		Role.EXIT:
			if is_open(tick):
				return pit
			# Shut: back in the cell, which is the gate being a gate.
			return {"box": pit["box"], "to": cell(), "yaw": cell_yaw()}
	return pit


## The exit volumes, for drawing the gate.
func exit_boxes() -> Array[AABB]:
	var out: Array[AABB] = []
	for index in exit_indices:
		out.append(_pits[index]["box"])
	return out


func describe() -> Dictionary:
	return {
		"enabled": enabled, "button": button_index, "exits": exit_indices,
		"falls": roles.values().count(Role.FALL), "open_ticks": open_ticks,
		"cooldown_ticks": cooldown_ticks, "opened_at": opened_at,
	}
