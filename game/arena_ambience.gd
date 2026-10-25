extends RefCounted

## What the arena's ambience is: the cvar defaults shared by the simulation (binds `arena_ambient*`) and the presentation (plays them).

const PREFIX := "arena"
## A deathmatch wants the ambience felt, not heard: under the layer's own level, and fewer one-shots.
const LEVEL := 0.3
const RATE := 0.5


static func make_rules() -> DotAmbienceRules:
	var r := DotAmbienceRules.new()
	r.prefix = PREFIX
	r.volume = LEVEL
	r.frequency = RATE
	return r
