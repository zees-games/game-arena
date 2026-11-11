extends "arena_player_stack_calls.gd"

const ArenaContent := preload("arena_content.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaBspMap := preload("../maps/arena_bsp_map.gd")

const CHANNEL := "arena.stack"
const SERVICE := &"arena_player_stack"
## The loadout the arena's one class names.
const LOADOUT_STANDARD := &"arena_standard"

## What each `loadout_id` in the class catalogue means, in weapon ids.
static func loadout_weapons() -> Dictionary:
	return {"arena_standard": ArenaContent.default_loadout()}

## Somebody's class changed, after a spawn honoured a pending choice.
signal class_applied(id: int, class_id: StringName)

## The physics profile was applied or switched.
signal physics_applied(profile: DotPhysicsProfile)

@export var register_service: bool = true

## Whether to apply a physics profile at all. Off for a client joined to a server: the server's tick
## rate is what matters and a client that re-applied a different one would simulate at a rate the
## server does not.
@export var apply_physics: bool = true

## Which physics preset. The arena is an arcade shooter.
@export var physics_preset: StringName = &"arcade_shooter"


var classes: DotPlayerClassManager = null
var spawns: DotSpawnDirector = null
var spectate: DotTeamSpectate = null

var _registered: bool = false

## Which map's spawn points are in the director. See [method _ensure_sites_current].
var _sites_from: ArenaMap = null


## Builds everything and binds it to [param p_game]. Returns a failure without having built anything
## when the game is not set up, because half a stack is worse than none: the roster would exist,
## nothing would feed it, and every consumer would read an empty scoreboard on a running server.
func setup(p_game: ArenaGame) -> DotResult:
	if p_game == null:
		return DotResult.fail(DotError.CODE_INVALID, "No game to bind to.")

	if p_game.match_node == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"ArenaGame is not set up yet.",
			"Call ArenaGame.setup() first; this reads its match, its spawn points and "
			+ "its tick rate."
		)

	game = p_game

	var built := _build_physics()

	if not built.ok:
		return built

	_build_roster()
	_build_teams()
	_build_classes()
	_build_spawns()
	_build_spectate()
	_connect_game()

	if register_service:
		DotRegistry.register(SERVICE, self)
		_registered = true

	_print_dot_sim_status()
	DotLog.info(CHANNEL, "player stack up", {
		"tick_rate": game.tick_rate,
		"classes": classes.catalogue.ids().size(),
		"sites": spawns.sites().size(),
	})

	return DotResult.success(null)


static var _dot_sim_status_printed: bool = false


# The addon's default is off. On at script load, so a solo client and a listen host run it too
# (motor_native_tick exists only where ArenaModule loads), and that cvar can still turn it off.
static func _static_init() -> void:
	DotFpsMotor.native_tick = true


## One line per process saying whether dot-sim's library loaded and what runs in it, so a
## player or a log can tell native from the GDScript twins (bootstrap fetches the library;
## the web never has it).
static func _print_dot_sim_status() -> void:
	if _dot_sim_status_printed:
		return
	_dot_sim_status_printed = true
	print(dot_sim_status())


## [code]dot-sim: native motor=on bots=on snapshot=on[/code], or that the library is not loaded.
static func dot_sim_status() -> String:
	var natives := {"motor": &"DotSimFpsBody", "bots": &"DotSimBotSenses", "snapshot": &"DotSimSnapshotCodec"}
	var parts: PackedStringArray = []
	var any := false
	for module: String in natives:
		var loaded := ClassDB.class_exists(natives[module])
		any = any or loaded
		var used := loaded
		if module == "motor":
			used = loaded and DotFpsPhysicsBody.native_enabled
			if used and DotFpsMotor.native_tick and DotFpsPhysicsBody.native_tick_available():
				parts.append("motor_tick=%s" % ("full" if DotFpsMotor.native_full and DotFpsPhysicsBody.native_full_available() else "on"))
		elif module == "bots":
			used = loaded and DotBotWorld.native_enabled
		parts.append("%s=%s" % [module, ("on" if used else "off") if loaded else "missing"])
	if not any:
		return "dot-sim: native library not loaded, the GDScript twins run (bootstrap fetches it; web never has it)"
	return "dot-sim: native " + " ".join(parts)


func _exit_tree() -> void:
	if _registered:
		DotRegistry.unregister_instance(SERVICE, self)


# --- Building ---------------------------------------------------------------

## Builds the physics node, and applies the engine half of it only where that is wanted.
func _build_physics() -> DotResult:
	physics = DotPhysicsWorld.new()
	physics.name = "Physics"
	physics.profile = DotPhysicsProfile.preset(physics_preset)

	if physics.profile == null:
		physics.profile = DotPhysicsProfile.arcade_shooter()

	# The game's tick rate wins over the preset's.
	physics.profile.tick_rate = game.tick_rate

	physics.layout = DotPhysicsLayout.shooter_3d()
	# The map's loose toys (dot-props'): a ball or a barrel on `toy`, which the level, props and
	# other toys stop and a person never does (they walk through and push it,
	# `ArenaGame._advance_toys`).
	physics.layout.layers.append(DotPhysicsLayer.make(
		&"toy", [&"world", &"prop", &"debris", &"toy"],
		"A map's loose toy: a ball, a barrel, a tyre. People walk through it and push it."
	))
	physics.layout.layers.append(DotPhysicsLayer.make(
		&"footprint", [], "Where a fixed toy stands, for a walkable mesh's bake only."
	))
	physics.surfaces = DotPhysicsSurfaceSet.standard()
	physics.register_service = false
	# A dedicated server has no inspector to read layer names in, and the write is
	# pure cost there.
	physics.write_layer_names = not game.headless
	add_child(physics)

	# The layout alone, so `classify` answers on a client too.
	var built := physics.layout.build()

	if not built.ok:
		return built.wrap("The arena's collision layout")

	if not apply_physics:
		return DotResult.success(null)

	var res := physics.setup()

	if res.ok:
		physics_applied.emit(physics.profile)

	return res.wrap("The arena's physics profile")


## Puts [param node] on the layout's [param layer_id] layer, with that layer's mask.
func classify(node: Node, layer_id: StringName) -> DotResult:
	if physics == null or physics.layout == null:
		return DotResult.fail(DotError.CODE_STATE, "No collision layout.")

	return physics.classify(node, layer_id)


## Puts every collision object under [param root] on [param layer_id].
##
## For a level: one call rather than a call per box, because the geometry is built by
## `ArenaMap` and a loop there would put a physics decision inside a description of
## boxes. Nodes that are not collision objects are skipped, so handing it a whole scene
## is safe. Returns how many were classified.
func classify_tree(root: Node, layer_id: StringName) -> int:
	if root == null or physics == null or physics.layout == null:
		return 0

	var done := 0

	# Importer hull bodies (clip, fence, glass) and the sky mark keep their layers, or shots and sight could not tell them from a wall.
	if DotMapGlassSight.is_exempt(root) or root.is_in_group(ArenaBspMap.SKY_GROUP):
		return 0

	if root is CollisionObject3D or root is CollisionObject2D:
		if classify(root, layer_id).ok:
			done += 1

	for child in root.get_children():
		done += classify_tree(child, layer_id)

	return done


## The mask a player's movement sweeps against, out of the layout.
##
## [b]`DotFpsTunables.collision_mask` defaults to 1 and no game here had ever set it.[/b]
## One is correct only for as long as everything is on bit 0, which is exactly the state
## the layout exists to end — so the moment props moved to the prop bit, a mask of 1
## would have been a player who walks through every crate in the map.
func player_collision_mask() -> int:
	if physics == null or physics.layout == null:
		return 1

	return physics.layout.collision_mask(&"player")


func _build_roster() -> void:
	roster = DotPlayerRoster.new()
	roster.name = "Roster"
	roster.authoritative = game.is_authority
	roster.register_service = false

	var config := DotPlayerConfig.new()
	config.tick_rate = game.tick_rate
	config.max_players = 0  # unlimited; the server cvar sv_maxplayers is the limit
	# Long enough to survive a map change, which is what a player reconnecting into an
	# arena is most often doing.
	config.reconnect_window_sec = 90.0
	roster.config = config

	add_child(roster)


func _build_teams() -> void:
	teams = DotTeamRoster.new()
	teams.name = "Teams"
	teams.authoritative = game.is_authority
	teams.register_service = false
	teams.teams = DotTeamSet.standard_pair(&"blue", &"red")
	teams.policy = DotTeamPolicy.competitive()
	teams.policy.tick_rate = game.tick_rate
	teams.alive_fn = _alive_of_key
	teams.joined_fn = _joined_tick_of_key
	teams.score_fn = _score_of_key
	teams.live_fn = func() -> bool: return game.match_node.is_live()
	add_child(teams)

	var res := teams.setup()

	if not res.ok:
		DotLog.error(CHANNEL, "team roster", {"why": res.error.message})
		return

	# [b]dot-match is the authority here, and dot-team mirrors it. That is the opposite
	# direction from dot-team's usual one, and the reason is the arena's.[/b]
	#
	# dot-team can drive a match manager — `bind_match` exists and is the right shape
	# for a lobby or a server whose sides outlive four map changes. The arena is not
	# that: its sides are decided by `DotTeamManager.assign`, which reads a requested
	# team, balances an uneven pair and refuses a full one, and its spawns are chosen
	# from spawn points the MAP tagged per side. Driving that from outside would mean
	# reimplementing the balance and the map tags, badly.
	#
	# So `bind_match` is deliberately NOT called, and `_on_player_added` adopts the side
	# dot-match assigned instead. What the session roster still buys is the part
	# dot-match cannot offer: an assignment that survives a map change, a spectator
	# side, and one place for dot-combat, dot-chat and dot-spectate to ask "are these
	# two enemies".
	teams.policy.auto_assign = game.match_node.teams == null


func _build_classes() -> void:
	classes = DotPlayerClassManager.new()
	classes.name = "Classes"
	classes.authoritative = game.is_authority
	classes.register_service = false

	# One class. The arena is a deathmatch and everybody is the same, and a catalogue
	# with one entry is how that is said without every consumer branching on whether
	# classes exist at all. A mode that wants more replaces the catalogue.
	classes.catalogue = DotPlayerClassCatalogue.single(100.0)

	# [b]The one class names its loadout, so the arsenal comes from the document rather
	# than from a hardcoded pair.[/b] `DotWeaponPlayerBridge.give_class_loadout` reads
	# `loadout_id` off a class and looks it up in a table the GAME owns — dot-weapon
	# deliberately does not own the id space between a loadout and a weapon — and until
	# this line neither half had a caller: every player got pistol-and-rifle written into
	# `ArenaPlayer.give_default_loadout`, and the class's own field reached nothing.
	var only := classes.catalogue.classes[0]
	only.loadout_id = LOADOUT_STANDARD
	var _rebuilt := classes.catalogue.build()

	classes.rules = DotPlayerClassRules.instant()
	classes.team_fn = func(key: String) -> StringName: return teams.team_of(key)
	classes.alive_fn = _alive_of_key
	classes.live_fn = func() -> bool: return game.match_node.is_live()
	add_child(classes)

	var res := classes.setup()

	if not res.ok:
		DotLog.error(CHANNEL, "class manager", {"why": res.error.message})


## How a respawn picks its site, as the server owner set it (`arena_spawn_*` cvars):
##
## - `mode`: "avoid" (the default: safest-first, and never closer to an enemy than `min_enemy`
##   metres when anywhere else will do), "weighted" (safest-first, no hard floor), "furthest"
##   (as far from every enemy as the map allows), or "random" (what the arena did until
##   2026-10-06: any of the side's points).
## - `min_enemy`: the hard floor for "avoid", in metres.
## - `sight_penalty`: what an enemy being able to see a site costs it.
## - `enemy_weight`: what each metre from the nearest enemy is worth.
##
## A mode may name its own (`ArenaMode.spawn_mode`); empty takes this one.
var spawn_settings := {"mode": "scatter", "min_enemy": 10.0, "sight_penalty": 500.0, "enemy_weight": 1.5}

const SPAWN_MODES := ["avoid", "weighted", "furthest", "random"]


func _build_spawns() -> void:
	spawns = DotSpawnDirector.new()
	spawns.name = "Spawns"
	spawns.tick_rate = game.tick_rate
	spawns.register_service = false
	spawns.rules = DotSpawnRules.deathmatch()
	spawns.rules.seed_value = 0x4A5E4
	spawns.enemies_fn = _enemy_positions
	spawns.friends_fn = _friend_positions
	spawns.can_see_fn = _can_see_site
	spawns.generate_fn = _generate_sites
	spawns.rules.generate = "when_few"
	spawns.rules.generate_count = 16
	add_child(spawns)

	refresh_spawn_rules()
	refresh_spawns()


## Re-reads the mode's spawn protection into the director's rules.
##
## [b]One duration, three consumers, and they used to be two durations.[/b] Spawn
## protection is enforced in three places here: [DotHealth]'s invulnerable window, the
## `arena_protected` effect, and — since the director started choosing — dot-spawn's own
## ledger. The mode sets `DotMatchRules.spawn_protection_sec` (1.5 s in a free-for-all,
## 2.5 s in the horde) and the effect table carried a hardcoded two seconds, so a
## free-for-all player was protected for 1.5 s by one gate and 2.0 s by another. Which
## one a hit met depended on the order the two were asked in.
##
## Called on a map change because a mode change goes through one.
func refresh_spawn_rules() -> void:
	if spawns == null or game == null or game.match_node == null:
		return

	spawns.rules.protection_sec = game.match_node.rules.spawn_protection_sec

	var mode := str(spawn_settings.get("mode", "scatter"))

	if game.mode != null and game.mode.spawn_mode != "":
		mode = game.mode.spawn_mode

	# Only `scatter` draws across the whole map; the others keep the map strategy and their scoring.
	spawns.rules.strategy = "scatter,map" if mode == "scatter" else "map"

	match mode:
		"scatter":
			spawns.rules.mode = DotSpawnRules.Mode.RANDOM
			spawns.rules.minimum_enemy_distance = 0.0
		"random":
			spawns.rules.mode = DotSpawnRules.Mode.RANDOM
			spawns.rules.minimum_enemy_distance = 0.0
		"furthest":
			spawns.rules.mode = DotSpawnRules.Mode.FURTHEST
			spawns.rules.minimum_enemy_distance = 0.0
		"weighted":
			spawns.rules.mode = DotSpawnRules.Mode.SAFEST
			spawns.rules.minimum_enemy_distance = 0.0
		_:
			spawns.rules.mode = DotSpawnRules.Mode.SAFEST
			spawns.rules.minimum_enemy_distance = maxf(float(spawn_settings.get("min_enemy", 10.0)), 0.0)

	spawns.rules.visible_penalty = maxf(float(spawn_settings.get("sight_penalty", 500.0)), 0.0)
	spawns.rules.enemy_distance_weight = float(spawn_settings.get("enemy_weight", 1.5))

	# [b]Off, and not because breaking on attack is wrong.[/b] It is the behaviour a
	# deathmatch wants — firing out of your own spawn should end the window. But only
	# ONE of the three gates above can be revoked: [DotHealth] counts to a tick and the
	# effect expires on its own, and neither has a "somebody shot" input. Revoking the
	# ledger alone would make a player who fired stop being protected by the resolver
	# and stay protected by the other two, which is worse than either answer.
	#
	# Turning it on is a change to all three at once. It is not a flag to flip here.
	spawns.rules.protection_breaks_on_attack = false


## Re-reads the game's spawn points into the director. Call after a map change.
##
## [b]dot-match's spawn points are the source, and are not replaced.[/b] A mapper
## places a `DotSpawnPoint`, dot-match picks one for a respawn, and this reads the same
## nodes into `DotSpawnSite` values so that the richer selector — conditions, occupancy,
## visibility, protection — can be asked as well. Two systems reading one set of markers
## is fine; two systems owning two sets of markers is a map that spawns people in
## different places depending on which asked.
func refresh_spawns() -> void:
	if spawns == null or game == null:
		return

	spawns.clear_sites()
	_sites_from = game.map

	for point in game.match_node.spawn_points():
		var at := point.spawn_transform()
		var site := DotSpawnSite.point(
			StringName(point.name), at.origin, at.basis.get_euler().y
		)
		# dot-match calls it `weight` and means the same thing: which point is preferred
		# when nothing else separates two. Rounded because dot-spawn's is an integer,
		# and a weight of 1.0 — the default — has to come out as a priority of 1 rather
		# than as a floor to zero that makes every point equal.
		site.priority = int(round(point.weight))
		site.cooldown_ticks = point.cooldown_ticks
		site.enabled = point.enabled
		# [b]And the side it belongs to, which the copy used to leave out.[/b] The map
		# tags a team's points and dot-match sends each side to its own through
		# `DotTeam.spawn_tag`; a site with no team admits everybody, so once the director
		# was the one choosing, a team mode spawned both sides out of one pool again —
		# the thing the tags were written to stop. Found by the first check that looked
		# at WHICH spawn a team player landed on (`[arena-mapchange-floor-1]`).
		site.team = _side_of_tags(point.tags)
		spawns.add_site(site)

	# A team mode spawns on the team's own spots only: a generated floor site belongs to no side, so it
	# would put either team anywhere. (Free-for-all keeps them: a map with few spawns gets candidates.)
	spawns.rules.generate = "off" if game.mode != null and game.mode.is_team_mode() else "when_few"

	if game.map != null:
		spawns.ensure_generated(String(game.map.id))
		var applied := spawns.load_overrides(spawn_overrides, String(game.map.id))
		if not applied.ok:
			DotLog.warn(CHANNEL, "spawn overrides not read", {"why": applied.error.message})

	DotLog.debug(CHANNEL, "spawn sites", {"count": spawns.sites().size()})


## The per-map spawn edits an admin authors in the workbench (`spawn` profile kind); [method refresh_spawns] applies them.
var spawn_overrides: DotProfileSet = DotSpawnOverrides.make_set("arena")


## Floor candidates for a map that ships too few spawn points, found with the map's own trace.
func _generate_sites(count: int, clearance: float, _map_id: String) -> Array[DotSpawnSite]:
	var trace: DotTrace = game.combat.trace if game != null and game.combat != null else null
	if trace == null or game.map == null:
		return []
	var ray := func(from: Vector3, to: Vector3) -> Dictionary:
		var span := to - from
		var length := span.length()
		if length < 0.01:
			return {}
		var hit := trace.ray(from, span / length, length)
		return {"position": hit.point, "normal": hit.normal} if hit.ok() else {}
	return DotSpawnFloorSampler.sample(game.map.bounds, count, clearance, ray)


func _build_spectate() -> void:
	spectate = DotTeamSpectate.new()
	spectate.name = "Spectate"
	spectate.teams = teams
	spectate.register_service = false
	spectate.rules = DotTeamSpectateRules.competitive()
	spectate.alive_fn = _alive_of_key
	spectate.pose_fn = _pose_of_key
	spectate.round_live_fn = func() -> bool: return game.match_node.is_live()

	var sr := DotSpectatorRules.new()
	# The arena is a free-for-all, so there is no "own side" to be restricted to and a
	# restriction would forbid everything.
	sr.force_camera = 0
	sr.delay_ticks = 0
	spectate.spectator_rules = sr

	add_child(spectate)

	var res := spectate.setup()

	if not res.ok:
		DotLog.error(CHANNEL, "team spectate", {"why": res.error.message})


func _connect_game() -> void:
	game.player_added.connect(_on_player_added)
	game.player_spawned.connect(_on_player_spawned)
	game.player_killed.connect(_on_player_killed)
	game.map_changed.connect(_on_map_changed)


# --- Keeping in step --------------------------------------------------------

func _on_player_added(player: ArenaPlayer) -> void:
	if not game.is_authority:
		return

	var key := str(player.player_id)
	var res := roster.join(key, player.display_name, player.player_id, game.current_tick())

	if not res.ok:
		DotLog.warn(CHANNEL, "player not added to the roster", {
			"key": key, "why": res.error.message
		})
		return

	var _team := teams.add(key, game.current_tick())

	# Adopt the side dot-match actually gave them, which is not necessarily the one
	# anybody asked for. Reading it back rather than assuming is the same rule
	# `ArenaGame.add_player` already follows one line above the signal that got us here.
	var side := _side_of_id(game.team_of(player.player_id))

	if side != &"":
		var _forced := teams.force_team(key, side, &"match")

	var _class := classes.add(key)


func _on_player_spawned(player: ArenaPlayer) -> void:
	if not game.is_authority:
		return

	var key := str(player.player_id)

	# Before the alive flag: a pending class change lands on the spawn, and anything
	# reading the class in an `alive_changed` handler should read the new one.
	var landed := classes.apply_pending(key)
	apply_class_numbers(player)
	class_applied.emit(player.player_id, landed)

	var _alive := roster.set_alive(key, true)
	spawns.cancel_respawn(key)

	if spectate.is_spectating(key):
		spectate.end(key)


func _on_player_killed(entry: DotKillFeed.Entry) -> void:
	if not game.is_authority:
		return

	var _dead := roster.set_alive(entry.victim_key, false)
	var _queued := spawns.queue_respawn(entry.victim_key, game.current_tick())


func _on_map_changed(_map: ArenaMap) -> void:
	# The rules first: a map change carries a mode change, and the mode is what says how
	# long spawn protection lasts. Refreshing the sites against the old duration would
	# grant the previous mode's protection until the next changelevel.
	refresh_spawn_rules()
	_adopt_match_sides()
	refresh_spawns()


## Takes every player's side from the match again, after a change built a new one.
##
## [method _on_player_added] adopts dot-match's assignment at a join, and a map change
## is not a join: the new match re-adds everybody and may put them on other sides, or on
## sides at all where the last mode had none. Left alone, the roster answers the
## director with the previous mode's side, and a player asks for spawns that belong to
## the other team.
func _adopt_match_sides() -> void:
	if not game.is_authority or teams == null:
		return

	var sided := game.mode != null and game.mode.is_team_mode()

	for id in game.player_ids():
		var key := str(id)
		var side := _side_of_id(game.team_of(id)) if sided else &""

		if side != &"":
			var _forced := teams.force_team(key, side, &"match")
		elif teams.teams.is_playing(teams.team_of(key)):
			# No sides now, so nobody keeps the last mode's. A free-for-all whose roster still
			# said blue and red was one where dot-team's `are_allies` called old team-mates
			# friends, to dot-spectate and anything else that asks it.
			var _cleared := teams.force_team(key, DotTeamSet.UNASSIGNED, &"match")


## Drops a player from every record. Call from `ArenaGame.remove_player`.
##
## [b]Not connected to a signal, because there is not one.[/b] `ArenaGame.remove_player`
## is a method, and adding a signal to it for this would be adding a signal for one
## subscriber. The call site is one line in that method and is easier to find than a
## connection made here.
func drop_player(id: int) -> void:
	var key := str(id)

	if not roster.authoritative:
		return

	spectate.end(key)
	spawns.cancel_respawn(key)
	classes.remove(key)
	var _left := teams.remove(key)
	# note_disconnected rather than remove: a player who drops out of an arena
	# mid-match and comes back within the window keeps their score, and the roster is
	# the only thing in this game that can offer that.
	var _held := roster.note_disconnected(key, game.current_tick())


## One tick of everything this node runs on its own.
##
## Deliberately small: the respawn timers are dot-match's, not dot-spawn's, because
## dot-match already owns the round clock and two systems queuing respawns would
## respawn everybody twice. What this drains is spawn protection and the roster's
## reconnect windows.
func tick(current_tick: int) -> void:
	if not game.is_authority:
		return

	if spawns.protection != null:
		spawns.protection.advance(current_tick)

	var _dropped := roster.advance(current_tick)
	spectate.advance(current_tick)


# --- Reading ----------------------------------------------------------------

## Rebuilds the sites when they came from a map that is no longer loaded.
##
## [b]Signal order, and it is not hypothetical.[/b] A map change emits `map_changed` and
## respawns everybody, and nothing orders this node's handler before the respawn. When it
## lost that race the director still held the previous map's points and answered — with a
## real site, a real transform and a successful `DotResult` — a coordinate from a map
## nobody was standing in. game-g2gfast hit exactly this and its surf section found it as
## a bot that never left the ground; the only reason it is not already a bug here is that
## `_on_respawn_due` had never asked the director at all.
func _ensure_sites_current() -> void:
	if spawns == null or game == null:
		return

	if _sites_from != game.map:
		refresh_spawns()


## Where a player should enter the world, and the grant of protection that goes with it.
##
## [b]This is the live path, and it was not.[/b] `ArenaGame._on_respawn_due` used
## dot-match's own choice and this was offered beside it — which meant the director was
## built, fed every site on the map, ticked every tick, and never asked anything. The
## visible half of that was harmless (dot-match picks a reasonable point). The invisible
## half was not: [DotSpawnProtection] is granted inside [method DotSpawnDirector.choose]
## and nowhere else, so `spawns.protection.advance()` in [method tick] was draining a
## ledger that was always empty, for ever, while reading exactly like working spawn
## protection.
##
## dot-match's points are still the source — see [method refresh_spawns]. What this adds
## on top of picking one of them is the part dot-match has no model for: enemy distance,
## line of sight, occupancy, per-site cooldown, and the protection window.
func choose_spawn(id: int) -> DotResult:
	_ensure_sites_current()

	var key := str(id)
	var request := DotSpawnRequest.make(
		key, teams.team_of(key), classes.class_of(key), game.current_tick()
	)
	return spawns.choose(request)


## Writes the player's class numbers onto their health and their movement.
##
## [b]The class document reached nothing at all before this.[/b] `DotPlayerClassDef`
## carries `max_health`, `max_armour`, regeneration, a move-speed scale, a jump scale, a
## mass and a knockback scale; the manager decided who was what, emitted it, and every
## one of those numbers was read by nobody. A catalogue a server can validate is only
## half of a class system — the other half is the spawn where it lands.
##
## [b]`base_tunables` is why this can run on every spawn.[/b] The scales multiply, so
## applying one to an object that already carries it compounds: 0.8 twice is 0.64, and a
## player who respawned four times would be at 0.41 of the speed with every number in the
## inspector looking deliberate. `DotPlayerClassApply` reads the untouched base and writes
## the product, which makes a respawn idempotent.
##
## Arena ships one class, so today this changes nothing visible — which is exactly when a
## mechanism is worth wiring, because a mode that swaps the catalogue is then a catalogue
## swap rather than a catalogue swap plus finding out why nothing happened.
func apply_class_numbers(player: ArenaPlayer) -> void:
	if player == null or classes == null:
		return

	var def := classes.def_of(str(player.player_id))

	# Before the null return: no class must clear what the last spawn wrote.
	var _kinds := DotGameClassImmunity.apply(game.combat, def, player.player_id)

	if def == null:
		return

	# Not reset to full here: `ArenaPlayer.spawn` already calls `DotHealth.reset`, and
	# two resets on one spawn is one of them undoing the other's protection window.
	var _h := DotPlayerClassApply.to_health(def, player.health)
	player.apply_class_movement(def)


## Fills a player's arsenal from what their class says they start with.
##
## Returns whether the class supplied one. False is an ordinary answer — a class with no
## `loadout_id` is legal, and a game with no class catalogue at all is the common case —
## so the caller falls back to its own default rather than leaving somebody unarmed.
func give_class_loadout(player: ArenaPlayer) -> bool:
	if player == null or player.arsenal == null or classes == null:
		return false

	var def := classes.def_of(str(player.player_id))

	if def == null:
		return false

	var res := DotWeaponPlayerBridge.give_class_loadout(
		player.arsenal, def, loadout_weapons()
	)

	if not res.ok:
		DotLog.debug(CHANNEL, "no class loadout", {
			"key": str(player.player_id), "why": res.error.message
		})
		return false

	return int(res.value) > 0


## Whether spawn protection should stop [param attacker] hurting [param victim].
##
## Handed to the damage path through [ArenaEffects.adjust_damage], which owns
## `DotDamageResolver.adjust`. Self damage is never blocked and world damage is not
## either — a protected player who walks into a pit is meant to die in it — and both of
## those decisions are [DotSpawnProtection]'s rather than this file's.
func blocks_damage(
	attacker_key: String, victim_key: String, tick: int, world_damage: bool = false
) -> bool:
	if spawns == null or spawns.protection == null:
		return false

	return spawns.protection.blocks(attacker_key, victim_key, tick, world_damage)


## The dot-spectate team number for [param key], derived from the side they are on.
##
## [b]An index, not a hash, and zero means "no side".[/b] dot-spectate keys teams by
## [code]int[/code] and treats 0 as no team at all — two entities with no team are never
## team-mates, so a free-for-all cannot accidentally become a truce. The playing sides
## are numbered from 1 in the order the set declares them, which is the same rule
## `DotTeamRoster._match_team_id` uses to push an assignment down into dot-match.
##
## Somebody unassigned, spectating, or not in the roster at all gets 0. That is the part
## a hardcoded `return 1` got wrong: a spectator read as a team-mate of everybody.
func team_index_of(key: String) -> int:
	if teams == null:
		return 0

	var side := teams.team_of(key)

	if side == &"" or not teams.teams.is_playing(side):
		return 0

	return teams.teams.playing_ids().find(side) + 1


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("--- player stack")

	if physics != null:
		out.append_array(physics.describe_lines())

	out.append_array(roster.describe_lines())
	out.append_array(teams.describe_lines())
	out.append_array(classes.describe_lines())
	out.append_array(spawns.describe_lines())
	out.append_array(spectate.describe_lines())
	return out


func describe() -> Dictionary:
	return {
		"players": roster.count(),
		"alive": roster.alive_count(),
		"teams": teams.describe(),
		"spawn_sites": spawns.sites().size(),
		"viewers": spectate.viewers().size(),
		"physics": physics.describe() if physics != null else "not applied",
	}
