extends Node

const Roles := preload("../game/arena_weapon_roles.gd")
const ArenaContent := preload("../game/arena_content.gd")

## Weapons by role: with no pack zee fills every role and the wire numbers are zee's; with a pack enabled it fills them, its
## weapons carry a wire number and survive the round trip, and clearing puts everything back. Skips the pack half unless a
## pack is linked (zz_modern_weapons, or arena_weapons).
##
## [codeblock]
## ./game.sh --no-parse test headless_roles
## [/codeblock]

var _checks := 0
var _failed := 0


func _ready() -> void:
	Roles.clear()
	Roles.scan()
	_check(Roles.packs.is_empty(), "no pack is enabled by default")
	_check(Roles.resolve(&"primary") == ZeeWeaponIds.RIFLE and Roles.resolve(&"melee") == ZeeWeaponIds.KNIFE, "zee fills the roles")
	_check(ArenaContent.default_loadout() == ArenaContent.DEFAULT_LOADOUT, "default loadout is the zee one")
	_check(Roles.wire_ids() == ZeeWeaponIds.all(), "wire ids are zee's alone")
	_check(ArenaContent.weapons().size() == ZeeWeaponIds.all().size(), "catalogue is zee's alone")

	for dir in ["zz_modern_weapons", "arena_weapons"]:
		if not ResourceLoader.exists("res://addons/%s/spawn_provider.gd" % dir):
			print("  skip  %s is not linked" % dir)
			continue

		Roles.force_packs = [dir]
		Roles.scan()
		var added := Roles.pack_ids.size()
		_check(Roles.packs.has(dir) and added > 0, "%s registered: %d weapons" % [dir, added])
		var table := ArenaContent.weapon_table()

		for role: StringName in Roles.ROLE_DEFAULT:
			var id := Roles.resolve(role)
			_check(table.has(id), "%s resolves to %s, which the catalogue holds" % [role, id])

		var first := Roles.pack_ids[0]
		_check(ArenaContent.weapon_at(ArenaContent.weapon_index(first)) == first, "%s round-trips the wire" % first)
		_check(ArenaContent.weapon_index(first) < (1 << ArenaContent.WEAPON_INDEX_BITS), "its index fits the field")
		_check(ZeeWeaponArtTable.table().has(first), "%s has art" % first)
		_check(ArenaContent.loadout_schema().default_loadout().item_in(&"primary") == Roles.resolve(&"primary"), "the default loadout names the role's weapon")

		Roles.force_packs = []
		Roles.scan()
		_check(Roles.pack_ids.is_empty() and ArenaContent.weapons().size() == ZeeWeaponIds.all().size(), "clearing puts zee back")

	Roles.clear()
	print("RESULT: ", "PASS" if _failed == 0 and _checks >= 5 else "FAIL", " ", _checks, " checks, ", _failed, " failed")
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String) -> void:
	_checks += 1

	if not ok:
		_failed += 1

	print("  %s  %s" % ["ok  " if ok else "FAIL", what])
