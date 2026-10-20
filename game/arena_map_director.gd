extends Node

const ArenaGame := preload("arena_game.gd")
const ArenaMapSession := preload("arena_map_session.gd")
const ArenaMaps := preload("arena_maps.gd")
const ArenaMode := preload("arena_mode.gd")

## Maps as content: a catalogue, a rotation, a clock, and a change that reaches clients.
##
## [b]This is what "there is no hot changelevel" used to mean.[/b] `ArenaGame.setup`
## built the combat trace, the match node and every spawn point in one pass and was not
## re-entrant, so the map was chosen at boot with `-- --map <id>` and `arena_maps`
## listed what could be typed. [method ArenaGame.change_map] is the half that makes a
## change possible at all; this is the half that makes it reach the players.
##
## Four dot-map pieces, and each is here for a reason a line of code could not replace:
##
## [codeblock]
## DotMapCatalogue   what can be played, with versions. ArenaMaps builds it.
## DotMapRotation    what plays next, with a cooldown, so dm_box does not come
##                   round twice in three maps on a two-map server.
## DotMapTimeLimit   how long a map lasts, with warnings, rtv and extends.
## DotMapSyncHost    announce -> wait for every peer -> swap -> tell them to load.
## [/codeblock]
##
## [b]The sync host is the one that is not optional.[/b] Without it a map change is a
## change in this process: the server frees the world, builds the next one, and every
## connected client carries on playing a map that no longer exists — which is precisely
## the absence dot-map's own notes call "the structural one".
##
## [codeblock]
## var maps := ArenaMapDirector.new()
## maps.game = game
## add_child(maps)
## maps.setup()
## maps.sync.send_fn = func(peer: int, payload: Dictionary) -> void:
##     link.send_map_message(peer, payload)
## [/codeblock]

const CHANNEL := "arena.maps"

## The map changed here and every peer has been told. Carries the new definition.
signal map_changed(map: DotMapDef)

## A change was abandoned; the previous map is still running.
signal change_failed(map: DotMapDef, reason: String)

## The map's clock ran out. The host decides what happens next — this node does NOT
## change the map on its own, because on a server with a vote the answer is "open the
## ballot" and on one without it is "next in rotation", and only the host knows which.
signal map_over(map: DotMapDef, reason: StringName)

## Seconds left, at each of the rules' warning marks.
signal time_warning(seconds_left: float)

@export_group("Rotation")

@export var rotation_mode: DotMapRotation.Mode = DotMapRotation.Mode.RANDOM

## How many other maps must play before one can come round again.
##
## [b]Clamped against the catalogue's size at [method setup], not here.[/b] A cooldown
## of five on a two-map server is a rotation that can never offer anything, and
## dot-map's own `on_cooldown` takes a pool size for exactly that reason — but a value
## that silently means "never" is worse than one that was reduced with a log line.
@export_range(0, 32, 1) var rotation_cooldown: int = 3

@export_group("Time limit")

## How long a map runs before [signal map_over]. Zero runs it for ever.
@export_range(0.0, 86400.0, 30.0) var map_seconds: float = 2700.0

@export_range(0.0, 3600.0, 10.0) var warn_seconds: float = 120.0

@export_group("Wiring")

## Where the meshes go, on a deployment that draws any. Null on a dedicated server.
@export var world_ref: DotNodeRef = null

## The game whose world is replaced. Required before [method setup].
var game: ArenaGame = null

## Whatever names this server's delivered maps: the dot-server, read through
## [code]games.current_maps()[/code] (see `ArenaMaps.server_map_keys`). Null — a suite, a
## listen server with no host config — means none, and the catalogue is the built-ins and
## the local imports, exactly as before.
var server: Object = null

var session: ArenaMapSession = null
var sync: DotMapSyncHost = null

## The server's maps.yml, or null when there is none (every map rotates, as it always did).
## See [method load_rotation].
var rotation_file: DotMapRotationFile = null

## The file looked for, without or with an extension: `cfg/maps.yml`. `sv_map_rotation_file`.
var rotation_file_name: String = DEFAULT_ROTATION_FILE

const DEFAULT_ROTATION_FILE := "cfg/maps.yml"

## The map running now. Duck-typed by [DotVoteMapSource] through `get("current")`.
var current: DotMapDef = null

var _ready_for_changes: bool = false


## Builds the session and the sync host over [member game]'s current map.
##
## [b]It adopts the map the game is already on rather than loading one.[/b] The game is
## set up before this node exists — it has to be, because `ArenaGame.setup` builds the
## combat manager this hangs no part of itself off but every change depends on — so the
## first map is not a change and must not be announced as one. A director that "started"
## by changing to the map already running would put every client through a download and
## a swap for nothing, on every boot.
func setup() -> DotResult:
	if game == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The map director has no game to change."
		)

	if game.map == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The game has no map, so setup() has not run."
		)

	var catalogue := ArenaMaps.catalogue()

	# The maps the server owner named, catalogued as delivered and fetched only when one is
	# changed to (`ArenaMapSession`). Before the session and the cooldown, so the rotation
	# and its pool size see them.
	var _adopted := ArenaMaps.adopt_delivered(catalogue, ArenaMaps.server_map_keys(server))

	session = ArenaMapSession.new()
	session.name = "MapSession"
	session.game = game
	session.catalogue = catalogue
	session.world_ref = world_ref
	session.rotation_mode = rotation_mode
	session.map_seconds = map_seconds
	session.warn_seconds = warn_seconds
	# Emphatically not set: `initial_map` makes `DotMapSession._ready` change to it,
	# which would rebuild the world the game has already built. See the note above.
	session.initial_map = &""
	add_child(session)

	# `_ready` has run by the time add_child returns, so the rotation exists and its
	# cooldown can be corrected against what is actually in the catalogue.
	var pool := maxi(catalogue.size() - 1, 0)

	if rotation_cooldown > pool:
		DotLog.info(CHANNEL, "the rotation cooldown was reduced to fit the catalogue", {
			"asked": rotation_cooldown, "used": pool, "maps": catalogue.size()
		})
		session.rotation.cooldown = pool
	else:
		session.rotation.cooldown = rotation_cooldown

	session.changed.connect(_on_session_changed)
	session.change_failed.connect(_on_session_failed)
	session.map_over.connect(_on_map_over)
	session.time_warning.connect(func(left: float) -> void: time_warning.emit(left))

	sync = DotMapSyncHost.new()
	sync.name = "MapSync"
	sync.session = session
	add_child(sync)

	sync.change_finished.connect(_on_sync_finished)
	sync.change_failed.connect(_on_session_failed)

	# The map the game booted on, recorded as played so the rotation does not offer it
	# again immediately. Without this the first change on a small server has a good
	# chance of being to the map already running.
	current = catalogue.get_map(game.map.id)

	if current != null:
		session.current = current
		session.rotation.note_played(current.id)
		session.time_limit.start(-1.0)
	else:
		DotLog.warn(CHANNEL, "the booted map is not in the catalogue", {
			"map": String(game.map.id)
		})

	_ready_for_changes = true

	var _loaded := load_rotation()

	return DotResult.success(self)


## Reads maps.yml and applies it: which installed maps the rotation, the next map, the vote's
## ballot and nominations may choose. Called at boot, by `sv_map_rotation_file` and by
## [method adopt_server_maps]. A map outside the active rotation stays installed and
## loadable by `arena_map <id>`; it is only never chosen.
##
## The merge, the wildcards and the rules are dot-map's [DotMapRotationFile]; this game
## supplies the paths. A file that is present and unreadable is an ERROR and changes nothing:
## rotating every map is a better failure than rotating none.
func load_rotation() -> DotResult:
	var dir := DotMapRotationFile.config_dir_arg()
	var found := DotMapRotationFile.find(rotation_file_name, dir)

	if found == "" and rotation_file_name != "" and (dir != "" or rotation_file_name != DEFAULT_ROTATION_FILE):
		# The default name being absent is an install with no maps.yml; a name or a directory
		# somebody chose that finds nothing is a typo they would otherwise never hear about.
		DotLog.warn(CHANNEL, "the map rotation file was not found; every map rotates", {
			"file": rotation_file_name, "config_dir": dir,
		})

	var paths := PackedStringArray()
	for candidate in ["res://maps.yml", found]:
		if candidate != "" and not paths.has(candidate) and FileAccess.file_exists(candidate):
			paths.append(candidate)

	var read := DotMapRotationFile.load_files(paths, "game-arena")

	if not read.ok:
		DotLog.error(CHANNEL, "the map rotation file could not be read; every map rotates", {
			"why": read.error.message,
		})
		rotation_file = null
		apply_rotation()
		return read

	rotation_file = read.value
	if rotation_file.has_rotations():
		DotLog.info(CHANNEL, "the map rotation file", {
			"paths": ", ".join(rotation_file.sources), "active": rotation_file.active_name(),
		})
		if session != null and not _rotation_attached:
			_rotation_attached = true
			# The file object is replaced on a reload, so the hook reads the current one.
			session.changed.connect(func(_map: DotMapDef, _world: Node) -> void:
				apply_rotation())

	apply_rotation()
	return read


var _rotation_attached: bool = false


## Marks every catalogue map in or out of rotation ([DotMapDef.in_rotation]) from the file.
## With no file, or a file with no rotations, every map is in, which is what this game did
## before maps.yml. The imported maps' own `arena_imported_rotation` is [member DotMapDef.enabled]
## and is a separate gate: a map must pass both.
func apply_rotation() -> void:
	if session == null or session.catalogue == null or session.rotation == null:
		return

	if rotation_file != null and rotation_file.has_rotations():
		rotation_file.apply(session.rotation)
		return

	session.rotation.order = []

	for def in session.catalogue.maps:
		def.in_rotation = true


## Reads the server's list again and makes the catalogue's delivered maps match it: a map
## newly named is offered, one no longer named is gone. In place, because the rotation and
## the vote hold the catalogue by reference. Returns `{added, removed}`.
func adopt_server_maps() -> Dictionary:
	if session == null or session.catalogue == null:
		return {"added": 0, "removed": 0}

	var playing := current.id if current != null else &""
	var out := ArenaMaps.adopt_delivered(
		session.catalogue, ArenaMaps.server_map_keys(server), playing
	)
	apply_rotation()
	restrict_rotation()
	return out


# --- Changing --------------------------------------------------------------

## Changes to a named map, taking every peer with it.
##
## A coroutine: the sync host announces, waits for peers to report the content, and
## only then swaps. On a server with no peers it resolves in the same frame.
func change_to(id: StringName) -> DotResult:
	if not _ready_for_changes:
		return DotResult.fail(DotError.CODE_STATE, "The map director is not set up.")

	return await sync.change_to(id)


## Changes to whatever the rotation offers next.
func change_to_next(players: int = 0) -> DotResult:
	if not _ready_for_changes:
		return DotResult.fail(DotError.CODE_STATE, "The map director is not set up.")

	restrict_rotation()

	return await sync.change_to_next(players)


## Narrows the rotation to the maps that can host the mode being played.
##
## [b]dot-map's rotation filters on player count and on cooldown, and knows nothing
## about modes — correctly.[/b] "What a mode needs from a map" is a game's question and
## every game answers it differently; here it is one property, whether any spawn is
## tagged. So the filtering has to happen on this side, and this is the only place that
## sees both the catalogue and [member ArenaGame.mode].
##
## It did not exist until `dm_pit`, and nothing was wrong before that: `dm_box` and
## `dm_atrium` both tag their spawns, so every map answered yes and an unfiltered
## rotation was indistinguishable from a filtered one. The first map that answers no
## is the first map the rotation could have dropped a team game into.
##
## Called before the rotation is asked, rather than once at setup, because the mode can
## change under a running server — a vote, an admin, or a map def that names one.
func restrict_rotation() -> void:
	if session == null or session.rotation == null or session.catalogue == null:
		return

	var mode: ArenaMode = game.mode if game != null else null
	var allowed: Array[StringName] = []

	# The file's own order (a `cycle` rotation plays in the order written) when it names maps,
	# else the catalogue's. Never a map outside the active rotation: this list replaces the one
	# the file set, so it must not widen it.
	var base: Array[StringName] = []
	if rotation_file != null and rotation_file.has_rotations():
		for id in rotation_file.resolve(session.catalogue):
			base.append(StringName(id))
	if base.is_empty():
		for def in session.catalogue.maps:
			base.append(def.id)

	for id in base:
		var def := session.catalogue.get_map(id)
		if def != null and def.in_rotation and ArenaMaps.supports_mode(def, mode):
			allowed.append(def.id)

	# Never leave it empty. A mode no map can host is a configuration mistake, and the
	# honest failure for it is "the map did not change", which says so — not "the
	# rotation has nothing in it", which is a server that sits on one map for ever and
	# never explains why.
	if allowed.is_empty():
		DotLog.warn(CHANNEL, "no map in the catalogue can host the current mode", {
			"mode": String(mode.id) if mode != null else "none",
			"maps": session.catalogue.size(),
		})
		return

	# Only when it actually differs. In [constant DotMapRotation.Mode.SEQUENTIAL] the
	# cursor indexes into `order`, so rewriting the same list every change would be a
	# rotation that never moves off the map it is on.
	if session.rotation.order != allowed:
		session.rotation.order = allowed


## The map the rotation would choose next, without choosing it.
##
## For a `nextmap` command and for a HUD. [method DotMapRotation.choose] has a side
## effect in [constant DotMapRotation.Mode.SEQUENTIAL] — it advances the cursor — so
## this reads the forced next when there is one and otherwise says what mode is in use
## rather than lying about a random pick.
func next_map_hint() -> String:
	if session == null or session.rotation == null:
		return "-"

	var forced := session.rotation.forced_next()

	if forced != &"":
		return String(forced)

	return "(%s)" % DotMapRotation.Mode.keys()[session.rotation.mode].to_lower()


## Forces the next map. What a vote's result and an admin's `nextmap` both do.
func set_next(id: StringName) -> bool:
	if session == null or session.rotation == null:
		return false

	return session.rotation.set_next(id)


## Advances the map clock. Once per tick, from whatever drives the game.
##
## [b]Not a wall clock, deliberately[/b], and dot-map says why: a server that stalls
## should not lose that time off its map, and a test must be able to run an hour of a
## map in a millisecond.
func advance(delta: float) -> void:
	if session != null:
		session.advance(delta)


func rock_the_vote(player_id: StringName, player_count: int) -> bool:
	return session.rock_the_vote(player_id, player_count) if session != null else false


func extend_map(seconds: float = -1.0) -> bool:
	return session.extend_map(seconds) if session != null else false


# --- Peers -----------------------------------------------------------------

## Registers a peer that must follow map changes.
func add_peer(peer_id: int) -> void:
	if sync != null:
		sync.add_peer(peer_id)


## Registers a peer and tells it the map this server is on (now, or once a running
## change settles). The join path: [method add_peer] alone tells a joiner nothing.
func admit_peer(peer_id: int) -> void:
	if sync != null:
		sync.admit_peer(peer_id)


func remove_peer(peer_id: int) -> void:
	if sync != null:
		sync.remove_peer(peer_id)


## Feeds one received map message to the sync host. Returns whether it was one.
func handle(peer_id: int, payload: Dictionary) -> bool:
	return sync.handle(peer_id, payload) if sync != null else false


## What a joining peer is told so it can load the map before it spawns.
func join_payload() -> Dictionary:
	return sync.join_payload() if sync != null else {}


# --- Events ----------------------------------------------------------------

func _on_session_changed(map: DotMapDef, _world: Node) -> void:
	current = map


func _on_sync_finished(map: DotMapDef) -> void:
	current = map
	map_changed.emit(map)


func _on_session_failed(map: DotMapDef, reason: String) -> void:
	DotLog.warn(CHANNEL, "a map change failed", {
		"map": String(map.id) if map != null else "-", "why": reason
	})
	change_failed.emit(map, reason)


func _on_map_over(map: DotMapDef, reason: StringName) -> void:
	map_over.emit(map, reason)


# --- Diagnostics -----------------------------------------------------------

func describe() -> Dictionary:
	return {
		"map": String(current.id) if current != null else "-",
		"next": next_map_hint(),
		"session": session.describe() if session != null else {},
		"sync": sync.describe() if sync != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("maps      %s -> %s" % [
		String(current.id) if current != null else "-", next_map_hint()
	])

	if session != null:
		out.append_array(session.describe_lines())

	if sync != null:
		out.append_array(sync.describe_lines())

	return out
