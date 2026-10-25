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


## The cvars a workbench set offers: name -> profile type.
static func cvar_types() -> Dictionary:
	var rules := make_rules()
	var out := {}
	for key: String in DotAmbienceRules.VARS:
		var row: Array = DotAmbienceRules.VARS[key]
		out[rules.cvar_of(row)] = "string" if row[2] == null else "float"
	return out
