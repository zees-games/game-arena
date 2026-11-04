extends Node

const ArenaWeaponSkins := preload("../game/arena_weapon_skins.gd")
const Roles := preload("../game/arena_weapon_roles.gd")

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
	Roles.ensure()
	var own_models := _models()
	_check(own_models.values().all(func(m: String) -> bool: return m != ""), "the own pack has a model for every role: %s" % str(own_models))

	var none := ArenaWeaponSkins.apply("res://nonexistent")
	_check(none.is_empty(), "no pack root: nothing applied")
	var undressed := _models()
	_check(undressed.size() == ROLES.size(), "no pack: every role still has art")

	var linked := ArenaWeaponSkins.apply()
	var has_pack := DirAccess.dir_exists_absolute("res://addons/arena_weapons")
	_check(linked.has("arena_weapons") == has_pack, "linked pack is applied exactly when present: %s" % str(linked))

	if has_pack:
		# The role scan registers pack sources, which drops the art cache: it must not undo the dressing.
		Roles.clear()
		ArenaWeaponSkins.apply()
		Roles.ensure()
		var skinned := _models()

		for role in ROLES:
			_check(skinned[role].begins_with("res://addons/arena_weapons/"), "%s wears the pack's model: %s" % [role, skinned[role]])

		# Anything that rebuilds the table after apply() must keep it.
		AwWeaponArtTable.drop_cache()
		_check(_models() == skinned, "drop_cache after apply keeps the dressing")
		AwWeaponArtTable.add_source(&"skins_probe", Callable(self, &"_no_art"))
		_check(_models() == skinned, "add_source after apply keeps the dressing")
		AwWeaponArtTable.remove_source(&"skins_probe")
		_check(_models() == skinned, "remove_source after apply keeps the dressing")
		Roles.clear()
		Roles.ensure()
		_check(_models() == skinned, "a role rescan after apply keeps the dressing")

	var other := ArenaWeaponSkins.apply("res://addons", PackedStringArray(["zz_modern_weapons"]))
	_check(other.is_empty(), "a pack without role art is skipped")
	_check(_models() == undressed, "swapped pack: the undressed art stays")

	ArenaWeaponSkins.clear()
	_check(_models() == undressed, "clear restores the undressed art")

	var art := AwWeaponArtTable.table().get(&"rifle") as AwWeaponVisual
	_check(art != null and art.model_path != "", "rifle art resolves after every case")

	print("RESULT: ", "PASS" if _failed == 0 and _checks >= 1 else "FAIL", " ", _checks, " checks, ", _failed, " failed")
	get_tree().quit(1 if _failed > 0 else 0)


func _models() -> Dictionary:
	var out := {}
	var table := AwWeaponArtTable.table()

	for role in ROLES:
		var art := table.get(role) as AwWeaponVisual
		out[role] = "" if art == null else art.model_path

	return out


func _check(ok: bool, what: String) -> void:
	_checks += 1

	if not ok:
		_failed += 1
		print("FAIL: ", what)


func _no_art() -> Array[AwWeaponVisual]:
	return []
