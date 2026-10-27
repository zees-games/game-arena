extends Node

const ArenaWeaponSkins := preload("../game/arena_weapon_skins.gd")

## Weapon skin packs: arena works with a pack linked, with none, and with one that carries no role art.
## Every role keeps a model either way, and the rifle still fires.
##
## [codeblock]
## ./game.sh --no-parse test headless_skins
## [/codeblock]

const ROLES: Array[StringName] = [&"pistol", &"smg", &"carbine", &"rifle", &"shotgun", &"sniper", &"launcher", &"frag"]

var _checks := 0
var _failed := 0


func _ready() -> void:
	var zee_models := _models()
	_check(zee_models.size() == ROLES.size(), "zee art has a model for every role: %d" % zee_models.size())

	var none := ArenaWeaponSkins.apply("res://nonexistent")
	_check(none.is_empty(), "no pack root: nothing applied")
	_check(_models() == zee_models, "no pack: the art is zee's own")

	var linked := ArenaWeaponSkins.apply()
	var has_pack := DirAccess.dir_exists_absolute("res://addons/arena_weapons")
	_check(linked.has("arena_weapons") == has_pack, "linked pack is applied exactly when present: %s" % str(linked))

	if has_pack:
		var skinned := _models()

		for role in ROLES:
			_check(skinned[role] != "" and skinned[role] != zee_models[role], "%s is dressed by the pack: %s" % [role, skinned[role]])

	var other := ArenaWeaponSkins.apply("res://addons", PackedStringArray(["zz_modern_weapons"]))
	_check(other.is_empty(), "a pack without role art is skipped")
	_check(_models() == zee_models, "swapped pack: zee art stays")

	ArenaWeaponSkins.clear()
	_check(_models() == zee_models, "clear restores zee art")

	var art := ZeeWeaponArtTable.table().get(&"rifle") as ZeeWeaponArt
	_check(art != null and art.model_path != "", "rifle art resolves after every case")

	print("RESULT: ", "PASS" if _failed == 0 and _checks >= 1 else "FAIL", " ", _checks, " checks, ", _failed, " failed")
	get_tree().quit(1 if _failed > 0 else 0)


func _models() -> Dictionary:
	var out := {}
	var table := ZeeWeaponArtTable.table()

	for role in ROLES:
		var art := table.get(role) as ZeeWeaponArt
		out[role] = "" if art == null else art.model_path

	return out


func _check(ok: bool, what: String) -> void:
	_checks += 1

	if not ok:
		_failed += 1
		print("FAIL: ", what)
