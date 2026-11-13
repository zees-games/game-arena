extends DotGameCheckSuite

const ArenaBots := preload("../game/arena_bots.gd")
const ArenaBotLoadouts := preload("../game/arena_bot_loadouts.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

## Bot loadouts: the profiles load and fit the owner's rules, draws follow the weights,
## `sv_bot_loadouts` and the difficulty narrow them, a seed repeats them, and the kit a bot
## draws is the gun it spawns holding and fires.
##
## [codeblock]
## ./game.sh test headless_bot_loadouts
## [/codeblock]

const TICK_RATE := 64
const MAP := &"dm_atrium"
const DRAWS := 6000
const SHARE_SLACK := 0.025
const SPAWNED := 12
const FIGHT_SECONDS := 120.0

const SECTIONS := 7
const CHECKS := 23

var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact headless bot loadouts")
	ArenaBotLoadouts.mode = ArenaBotLoadouts.ALL
	ArenaBotLoadouts.seed = 0
	var game := _boot()
	var pool := ArenaBotLoadouts.new()
	_profiles(game, pool)
	_distribution(pool)
	_restricted(pool)
	_difficulty(pool)
	_determinism(pool)
	await _spawned(game)
	_free(game)
	await _fight()
	ArenaBotLoadouts.mode = ArenaBotLoadouts.ALL
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _profiles(game: ArenaGame, pool: ArenaBotLoadouts) -> void:
	_section("the profiles load and every item fits the owner's rules")
	var n := pool.load_from()
	_check(n >= 8, "at least eight kits load", "%d" % n)
	var unfit: Array[String] = []
	var primaries := {}
	for kit in pool.kits:
		var loadout := ArenaBotLoadouts.build(kit, game.loadouts, game._loadout_key(ArenaGame.BOT_SESSION_BASE))
		for slot: StringName in kit.items:
			if loadout.item_in(slot) != kit.items[slot]:
				unfit.append("%s.%s=%s" % [kit.id, slot, kit.items[slot]])
		primaries[kit.items.get(&"primary", &"")] = true
	_check(unfit.is_empty(), "no profile item is replaced by the rules", ", ".join(unfit))
	_check(primaries.size() >= 8, "the kits carry at least eight different primaries", "%d" % primaries.size())
	_done()


func _distribution(pool: ArenaBotLoadouts) -> void:
	_section("draws follow the profile weights")
	var counts := _count(pool, "")
	var total := 0.0
	for kit in pool.kits:
		total += kit.weight
	var off: Array[String] = []
	for kit in pool.kits:
		var share := float(counts.get(kit.id, 0)) / DRAWS
		if absf(share - kit.weight / total) > SHARE_SLACK:
			off.append("%s %.3f vs %.3f" % [kit.id, share, kit.weight / total])
	_check(counts.size() == pool.kits.size(), "every kit is drawn", "%d of %d" % [counts.size(), pool.kits.size()])
	_check(off.is_empty(), "each kit's share is within %.3f of its weight's" % SHARE_SLACK, ", ".join(off))
	_done()


func _restricted(pool: ArenaBotLoadouts) -> void:
	_section("sv_bot_loadouts narrows and reweighs the draw")
	ArenaBotLoadouts.mode = "sniper"
	var only := _count(pool, "")
	_check(only.size() == 1 and int(only.get(&"sniper", 0)) == DRAWS, "'sniper' deals only the sniper kit", str(only))
	ArenaBotLoadouts.mode = " smg, shotgun:3 "
	var two := _count(pool, "")
	var shotgun := float(two.get(&"shotgun", 0)) / DRAWS
	_check(two.size() == 2 and two.has(&"smg"), "'smg, shotgun:3' deals only those two", str(two))
	_check(absf(shotgun - 0.75) < SHARE_SLACK, "the cvar's weight replaces the profile's", "%.3f" % shotgun)
	ArenaBotLoadouts.mode = "no_such_kit"
	_check(pool.draw_kit(1) == null, "a list naming no kit draws nothing, so the bot keeps the default loadout")
	ArenaBotLoadouts.mode = "ALL"
	_check(_count(pool, "").size() == pool.kits.size(), "'ALL' is every kit again")
	_done()


func _difficulty(pool: ArenaBotLoadouts) -> void:
	_section("a kit tagged with difficulties is dealt only at those")
	var easy := _count(pool, "easy")
	var hard := _count(pool, "nightmare")
	_check(not easy.has(&"sniper") and not easy.has(&"drum_shotgun"), "easy bots never draw sniper or drum_shotgun", str(easy.keys()))
	_check(hard.has(&"sniper") and hard.has(&"drum_shotgun"), "nightmare bots do")
	_done()


func _determinism(pool: ArenaBotLoadouts) -> void:
	_section("the same seed deals the same kits")
	var a := _sequence(pool)
	var b := _sequence(pool)
	ArenaBotLoadouts.seed = 41
	var c := _sequence(pool)
	ArenaBotLoadouts.seed = 0
	_check(a == b, "two runs at one seed match")
	_check(a != c, "another seed deals another sequence")
	_done()


func _spawned(game: ArenaGame) -> void:
	_section("a spawning bot holds its kit's primary, a human the usual loadout")
	game.match_node.rules.respawn_delay_sec = 1.0
	for i in SPAWNED:
		var _a := game.add_player(ArenaGame.BOT_SESSION_BASE + 1 + i, "Bot%d" % i)
	var _h := game.add_player(7, "Human")
	game.start(0)
	game.tick({})
	await get_tree().process_frame
	var kinds := {}
	var wrong: Array[String] = []
	for i in SPAWNED:
		var bot := game.player_for(ArenaGame.BOT_SESSION_BASE + 1 + i)
		var kit := _kit_of(game, bot)
		if kit == null:
			wrong.append("bot %d drew nothing" % i)
			continue
		kinds[kit.id] = true
		var held := bot.arsenal.slot_at(bot.arsenal.current_slot())
		var carried := _carried(bot.arsenal)
		for slot: StringName in kit.items:
			# Gear (armour) is worn, not carried in the arsenal.
			if slot != &"gear" and not carried.has(kit.items[slot]):
				wrong.append("%s lacks %s" % [kit.id, kit.items[slot]])
		if held == null or held.id() != kit.items.get(&"primary", &""):
			wrong.append("%s holds %s" % [kit.id, held.id() if held != null else &"nothing"])
	_check(wrong.is_empty(), "every bot carries its whole kit and holds its primary", "; ".join(wrong))
	_check(kinds.size() >= 4, "%d bots spawn with at least four different kits" % SPAWNED, str(kinds.keys()))
	_check(not game.player_for(7).has_meta(&"bot_loadout"), "a human does not draw a bot kit")
	var bare := _bare_fittings(game)
	_check(bare.is_empty(), "a kit's attachments are fitted to its guns", bare)
	_done()


func _fight() -> void:
	_section("bots fire the guns their kit gave them")
	ArenaBotLoadouts.mode = "smg"
	var game := _boot()
	game.match_node.rules.respawn_delay_sec = 1.0
	var ids: Array[int] = [ArenaGame.BOT_SESSION_BASE + 1, ArenaGame.BOT_SESSION_BASE + 2]
	var minds := {}
	for id in ids:
		var _a := game.add_player(id, "Bot%d" % id)
		minds[id] = ArenaBots.Mind.new()
		minds[id].seed = 7 + id % 13
	game.start(0)
	game.tick({})
	await get_tree().process_frame
	var fired := {}
	var stray: Array[String] = []
	var mags := {}
	for i in range(int(FIGHT_SECONDS * TICK_RATE)):
		var tick := game.current_tick()
		var commands := {}
		for id in ids:
			commands[id] = ArenaBots.think(game, game.player_for(id), minds[id], tick, float(TICK_RATE))
		game.tick(commands)
		for id in ids:
			var bot := game.player_for(id)
			if bot == null or not bot.is_alive():
				continue
			var slot := bot.arsenal.slot_at(bot.arsenal.current_slot())
			if slot == null or slot.def == null or not slot.def.uses_magazine():
				continue
			var key := "%d/%s" % [id, slot.id()]
			if mags.has(key) and slot.magazine < int(mags[key]):
				fired[slot.id()] = true
				if not _kit_of(game, bot).items.values().has(slot.id()):
					stray.append(String(slot.id()))
			mags[key] = slot.magazine
		if fired.has(&"smg") and i > 10 * TICK_RATE:
			break
		if i % 8 == 0:
			await get_tree().process_frame
	_check(fired.has(&"smg"), "under 'smg' the bots fire the smg", str(fired.keys()))
	_check(stray.is_empty(), "no bot fires a gun its kit did not give", ", ".join(stray))
	var choice := _gun_choices(game.player_for(ids[0]))
	_check(choice.is_empty(), "the smg wears its kit's suppressor, and the gun choice keeps it close and picks a gun that reaches far", choice)
	_free(game)
	await get_tree().process_frame
	_done()


## What [method ArenaBots.gun_for] gets wrong for an smg bot, or "".
func _gun_choices(bot: ArenaPlayer) -> String:
	if bot == null or not bot.is_alive():
		return "the bot is dead"
	var arsenal := bot.arsenal
	var smg := _slot_of(arsenal, &"smg")
	if smg == 0:
		return "no smg slot"
	if arsenal.fitting_at(smg).attachment_on(&"muzzle") != &"suppressor":
		return "the kit's suppressor is not on the smg"
	var _e := arsenal.equip(smg)
	if arsenal.current_slot() != smg:
		return "the smg is not held"
	if ArenaBots.gun_for(arsenal, 8.0) != 0:
		return "it drops the smg at 8 m"
	var far := ArenaBots.gun_for(arsenal, 100000.0)
	if far == smg:
		return "it keeps the smg out of reach"
	return ""


func _boot() -> ArenaGame:
	var game := ArenaGame.new()
	game.tick_rate = TICK_RATE
	game.score_limit = 100000
	game.time_limit_sec = 0.0
	game.headless = true
	game.is_authority = true
	game.register_service = false
	add_child(game)
	_check(game.setup(ArenaMap.by_id(MAP)).ok, "the game sets up on %s" % MAP)
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	return game


func _free(game: ArenaGame) -> void:
	remove_child(game)
	game.queue_free()


func _count(pool: ArenaBotLoadouts, difficulty: String) -> Dictionary:
	pool.reset()
	var out := {}
	for i in DRAWS:
		var kit := pool.draw_kit(1 + i % 64, difficulty)
		if kit != null:
			out[kit.id] = int(out.get(kit.id, 0)) + 1
	return out


func _sequence(pool: ArenaBotLoadouts) -> Array[StringName]:
	pool.reset()
	var out: Array[StringName] = []
	for i in 64:
		out.append(pool.draw_kit(ArenaGame.BOT_SESSION_BASE + i % 4).id)
	return out


func _kit_of(game: ArenaGame, bot: ArenaPlayer) -> ArenaBotLoadouts.Kit:
	if bot == null or game.bot_loadouts == null or not bot.has_meta(&"bot_loadout"):
		return null
	for kit in game.bot_loadouts.kits:
		if kit.id == bot.get_meta(&"bot_loadout"):
			return kit
	return null


## The kit attachments missing from the guns of the spawned bots, or "" (also when no bot drew a kit with any).
func _bare_fittings(game: ArenaGame) -> String:
	var missing: Array[String] = []
	for i in SPAWNED:
		var bot := game.player_for(ArenaGame.BOT_SESSION_BASE + 1 + i)
		var kit := _kit_of(game, bot)
		if kit == null:
			continue
		for gun: Variant in kit.attachments:
			var slot := _slot_of(bot.arsenal, StringName(str(gun)))
			var fitting := bot.arsenal.fitting_at(slot)
			var mounts: Dictionary = kit.attachments[gun]
			for mount: Variant in mounts:
				if fitting.attachment_on(StringName(str(mount))) != StringName(str(mounts[mount])):
					missing.append("%s %s.%s" % [kit.id, gun, mount])
	return ", ".join(missing)


func _carried(arsenal: DotWeaponArsenal) -> Dictionary:
	var out := {}
	for slot in arsenal.slots():
		var held := arsenal.slot_at(slot)
		if held != null:
			out[held.id()] = true
	return out


func _slot_of(arsenal: DotWeaponArsenal, id: StringName) -> int:
	for slot in arsenal.slots():
		var held := arsenal.slot_at(slot)
		if held != null and held.id() == id:
			return slot
	return 0


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1
