extends Node

const Roles := preload("../game/arena_weapon_roles.gd")
const ArenaContent := preload("../game/arena_content.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

## Weapons by role: with no extra pack the own pack (arena_weapons) fills every role on the append-only wire numbers; with a pack
## enabled its weapons join, carry a wire number and survive the round trip, and clearing puts everything back. Skips the pack half unless a
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
	var has_default := ResourceLoader.exists("res://addons/arena_weapons/spawn_provider.gd")
	_check(Roles.packs.has("arena_weapons") == has_default, "arena_weapons is the default provider exactly when linked")

	# A pack that is not there: the own pack alone fills every role.
	Roles.force_packs = ["not_installed"]
	Roles.scan()
	var own_count := Roles.pack_ids.size()
	_check(Roles.packs == PackedStringArray(["arena_weapons"]), "a missing pack is skipped, the own pack stays: %s" % str(Roles.packs))
	_check(Roles.resolve(&"primary") == AwWeaponIds.RIFLE and Roles.resolve(&"melee") == AwWeaponIds.KNIFE, "the own pack fills the roles")
	_check(ArenaContent.default_loadout() == ArenaContent.DEFAULT_LOADOUT, "default loadout is the shipped one")
	_check(Roles.wire_ids().slice(0, AwWeaponIds.all().size()) == AwWeaponIds.all(), "wire ids start with the append-only list")
	_check(own_count > 0 and ArenaContent.weapons().size() == own_count, "catalogue is the own pack's alone: %d" % own_count)

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

		var first := Roles.pack_ids[own_count] if Roles.pack_ids.size() > own_count else Roles.pack_ids[0]
		_check(ArenaContent.weapon_at(ArenaContent.weapon_index(first)) == first, "%s round-trips the wire" % first)
		_check(ArenaContent.weapon_index(first) < (1 << ArenaContent.WEAPON_INDEX_BITS), "its index fits the field")
		_check(AwWeaponArtTable.table().has(first), "%s has art" % first)
		_check(ArenaPlayer.weapon_catalogue().ids() == ArenaContent.weapon_catalogue().ids(), "the shared rig catalogue follows the scan of %s" % dir)
		_check(ArenaContent.loadout_schema().default_loadout().item_in(&"primary") == Roles.resolve(&"primary"), "the default loadout names the role's weapon")

		Roles.force_packs = ["not_installed"]
		Roles.scan()
		_check(Roles.pack_ids.size() == own_count and ArenaContent.weapons().size() == own_count, "clearing leaves the own pack alone")
		_check(ArenaPlayer.weapon_catalogue().ids() == ArenaContent.weapon_catalogue().ids(), "the shared rig catalogue follows the clear")

	Roles.clear()
	print("RESULT: ", "PASS" if _failed == 0 and _checks >= 5 else "FAIL", " ", _checks, " checks, ", _failed, " failed")
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String) -> void:
	_checks += 1

	if not ok:
		_failed += 1

	print("  %s  %s" % ["ok  " if ok else "FAIL", what])
