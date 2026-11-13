extends RefCounted

## The loadouts bots draw from: one `cfg/game/game-arena/bot_loadout/<id>.yml` profile per kit,
## dealt per life by weight, narrowed by `sv_bot_loadouts` and the bot difficulty.
## Deterministic: a draw depends only on [member seed], the bot's id and its life count.

const CHANNEL := "arena.bots"
const ArenaContent := preload("arena_content.gd")

## The profile kind, and the folder under `cfg/game/game-arena/`.
const KIND := "bot_loadout"
## The cvar word for every enabled profile.
const ALL := "all"

## The loadout slots a profile can fill.
const SLOTS: Array[StringName] = [&"primary", &"secondary", &"melee", &"thrown", &"gear"]
## The slots the default loadout fills, in [method ArenaContent.default_loadout]'s order.
const DEFAULT_SLOTS: Array[StringName] = [&"melee", &"secondary", &"primary", &"thrown"]

## `sv_bot_loadouts`: "all" (or empty) for every enabled profile, or "id[:weight],..." for only those.
static var mode: String = ALL
## Mixed into every draw's seed; a suite sets it to repeat or vary a run.
static var seed: int = 0


## One loaded profile.
class Kit extends RefCounted:
	var id: StringName = &""
	var display_name := ""
	var weight := 1.0
	## Loadout slot -> weapon id; a slot left out keeps the default loadout's.
	var items: Dictionary = {}
	## Weapon id -> {mount: attachment id}.
	var attachments: Dictionary = {}
	## Bot difficulties (dot-bot presets) it is dealt at; empty for any.
	var difficulty := PackedStringArray()
	var tags := PackedStringArray()


## What a draw gave: the kit and the loadout built from it, already conformed to the owner's rules.
class Draw extends RefCounted:
	var kit: Kit = null
	var loadout: DotLoadout = null


var kits: Array[Kit] = []
var _override: Dictionary = {}
var _override_text := "\u0001"
## Bot id -> lives drawn so far, so each life rolls afresh and a run still repeats.
var _lives: Dictionary = {}


## The profile schema.
static func schema() -> Array:
	return [
		DotProfileSet.field("name", "string", ""),
		DotProfileSet.field("primary", "string", ""),
		DotProfileSet.field("secondary", "string", ""),
		DotProfileSet.field("melee", "string", ""),
		DotProfileSet.field("thrown", "string", ""),
		DotProfileSet.field("gear", "string", ""),
		DotProfileSet.field("attachments", "dict", {}),
		DotProfileSet.field("weight", "float", 1.0, {"min": 0.0}),
		DotProfileSet.field("difficulty", "any", []),
		DotProfileSet.field("tags", "list", []),
		DotProfileSet.field("enabled", "bool", true),
	]


## Loads every enabled profile of [param profiles] (the game's when null). Returns how many loaded.
func load_from(profiles: DotProfileSet = null) -> int:
	if profiles == null:
		profiles = DotProfileSet.create("", "game-arena", KIND, schema())
	kits.clear()
	_override_text = "\u0001"
	for id in profiles.list_ids():
		var res := profiles.load_profile(id)
		if not res.ok:
			DotLog.warn(CHANNEL, "a bot loadout profile did not load", {"id": id, "error": str(res.error)})
			continue
		var v: Dictionary = (res.value as DotProfile).values
		if not bool(v.get("enabled", true)):
			continue
		var kit := Kit.new()
		kit.id = StringName(id)
		kit.display_name = str(v.get("name", "")) if str(v.get("name", "")) != "" else id
		kit.weight = maxf(float(v.get("weight", 1.0)), 0.0)
		for slot in SLOTS:
			var item := str(v.get(String(slot), "")).strip_edges()
			if item != "":
				kit.items[slot] = StringName(item)
		var att: Variant = v.get("attachments", {})
		if att is Dictionary:
			kit.attachments = (att as Dictionary).duplicate(true)
		kit.difficulty = _words(v.get("difficulty", []))
		kit.tags = _words(v.get("tags", []))
		kits.append(kit)
	return kits.size()


## The cvar text as id -> weight; empty for "all".
static func parse_mode(text: String) -> Dictionary:
	var out := {}
	var t := text.strip_edges()
	if t == "" or t.to_lower() == ALL:
		return out
	for piece in t.split(",", false):
		var parts := piece.strip_edges().split(":")
		var id := parts[0].strip_edges()
		if id == "":
			continue
		var w := 1.0
		if parts.size() > 1 and parts[1].strip_edges().is_valid_float():
			w = maxf(parts[1].strip_edges().to_float(), 0.0)
		out[StringName(id)] = w
	return out


## The kits a bot at [param difficulty] can draw under [member mode]. A difficulty no kit
## allows is ignored rather than leaving the bot nothing.
func candidates(difficulty: String = "") -> Array[Kit]:
	_refresh_override()
	var out: Array[Kit] = []
	for kit in kits:
		if weight_of(kit) <= 0.0:
			continue
		if difficulty != "" and not kit.difficulty.is_empty() and not kit.difficulty.has(difficulty):
			continue
		out.append(kit)
	if out.is_empty() and difficulty != "":
		return candidates("")
	return out


## The weight [param kit] has under [member mode].
func weight_of(kit: Kit) -> float:
	_refresh_override()
	if _override.is_empty():
		return kit.weight
	return float(_override.get(kit.id, 0.0))


## The kit [param roll] (0..1) lands on among [param from], by weight; null when none can be drawn.
func pick(from: Array[Kit], roll: float) -> Kit:
	var total := 0.0
	for kit in from:
		total += weight_of(kit)
	if total <= 0.0:
		return null
	var at := clampf(roll, 0.0, 0.999999) * total
	for kit in from:
		at -= weight_of(kit)
		if at < 0.0:
			return kit
	return from[from.size() - 1]


## Draws the next life's kit for bot [param bot_id]; null when nothing can be drawn.
func draw_kit(bot_id: int, difficulty: String = "") -> Kit:
	var life := int(_lives.get(bot_id, 0))
	_lives[bot_id] = life + 1
	var rng := RandomNumberGenerator.new()
	rng.seed = (seed * 1_000_003 + bot_id * 7919 + life * 104_729) & 0x7fffffffffffffff
	return pick(candidates(difficulty), rng.randf())


## Draws the next kit and builds its loadout against [param manager]; null when there is none.
func draw(manager: DotLoadoutManager, key: String, bot_id: int, difficulty: String = "") -> Draw:
	if manager == null or manager.schema == null:
		return null
	var kit := draw_kit(bot_id, difficulty)
	if kit == null:
		return null
	var out := Draw.new()
	out.kit = kit
	out.loadout = build(kit, manager, key)
	return out


## [param kit] over the default loadout, conformed to [param manager]'s schema, the owner's rules and
## [param key]'s entitlements: an unknown or forbidden item falls back to its slot's default.
static func build(kit: Kit, manager: DotLoadoutManager, key: String) -> DotLoadout:
	var loadout := DotLoadout.empty(manager.schema.id)
	var defaults := ArenaContent.default_loadout()
	for i in DEFAULT_SLOTS.size():
		loadout.set_item(DEFAULT_SLOTS[i], defaults[i])
	for slot: StringName in kit.items:
		loadout.set_item(slot, kit.items[slot])
	for c in DotLoadoutValidator.conform(loadout, manager.schema, manager.entitlements_for(key), manager.rules):
		if c.was != &"":
			DotLog.debug(CHANNEL, "a bot loadout item was replaced", {"kit": String(kit.id), "change": str(c)})
	return loadout


## Forgets every bot's life count, so a fresh match deals the same sequence again.
func reset() -> void:
	_lives.clear()


func _refresh_override() -> void:
	if mode == _override_text:
		return
	_override_text = mode
	_override = parse_mode(mode)
	for id: StringName in _override:
		var found := false
		for kit in kits:
			found = found or kit.id == id
		if not found:
			DotLog.warn(CHANNEL, "sv_bot_loadouts names a loadout that does not exist", {"id": String(id)})


static func _words(v: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if v is String or v is StringName:
		for w in str(v).split(",", false):
			if w.strip_edges() != "":
				out.append(w.strip_edges().to_lower())
	elif v is Array or v is PackedStringArray:
		for w in v:
			out.append(str(w).strip_edges().to_lower())
	return out
