extends Node

const ArenaContent := preload("../game/arena_content.gd")

## The slot audit: melee 1, sidearms 2, EVERY gun 3 (rifles, smgs, lmg, sniper, launchers, minigun,
## beamer, railgun), frag and sticky 4, and slot 5 only for the utility throwables (flash, smoke, incendiary).
##
## [codeblock]
## godot --headless --path . res://examples/headless_slots.tscn
## [/codeblock]

var _checks := 0
var _failed := 0


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("   ok   ", what)
	else:
		_failed += 1
		print("  FAIL  ", what)


func _ready() -> void:
	var sidearms: Array[StringName] = [&"pistol", &"revolver", &"machine_pistol", &"derringer"]
	var utility: Array[StringName] = [&"flash", &"smoke", &"incendiary"]
	var lethal: Array[StringName] = [&"frag", &"sticky"]
	var seen := 0
	for def in ArenaContent.weapons():
		seen += 1
		var want := 3
		if def.id == &"knife":
			want = 1
		elif sidearms.has(def.id):
			want = 2
		elif lethal.has(def.id):
			want = 4
		elif utility.has(def.id):
			want = 5
		_check(def.slot == want, "%s sits in slot %d (is %d)" % [def.id, want, def.slot])
	_check(seen >= 20, "the catalogue has its weapons (%d)" % seen)
	_check(ArenaContent.loadout_slot_for(5) == &"thrown", "slot 5 is a grenade loadout slot")
	_check(ArenaContent.loadout_slot_for(3) == &"primary", "slot 3 is the primary loadout slot")
	_check(ArenaContent.is_grenade_slot(4) and ArenaContent.is_grenade_slot(5) and not ArenaContent.is_grenade_slot(3), "grenade slots are 4 and 5")
	print("%d checks, %d failed" % [_checks, _failed])
	get_tree().quit(1 if _failed > 0 else 0)
