extends Node

const ArenaAvatars := preload("arena_avatars.gd")
const ArenaBindings := preload("arena_bindings.gd")
const ArenaBots := preload("arena_bots.gd")
const ArenaBrowser := preload("arena_browser.gd")
const ArenaClientExtras := preload("arena_client_extras.gd")
const ArenaEvents := preload("arena_events.gd")
const ArenaFrameProbe := preload("arena_frame_probe.gd")
const ArenaGame := preload("arena_game.gd")
const ArenaHud := preload("arena_hud.gd")
const ArenaHudGlance := preload("arena_hud_glance.gd")
const ArenaKillcam := preload("arena_killcam.gd")
const ArenaContent := preload("arena_content.gd")
const ArenaMode := preload("arena_mode.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMapLighting := preload("../maps/arena_map_lighting.gd")
const ArenaMenus := preload("arena_menus.gd")
const ArenaMaps := preload("arena_maps.gd")
const ArenaModes := preload("arena_modes.gd")
const ArenaNetBridge := preload("arena_net_bridge.gd")
const ArenaPaths := preload("arena_paths.gd")
const ArenaProjectileView := preload("arena_projectile_view.gd")
const ArenaPlayer := preload("arena_player.gd")
const ArenaPresentation := preload("arena_presentation.gd")

## A playable game-arena: one local player, a camera, a HUD, menus and the keys.
##
## [b]Separate from [ArenaGame], which is the simulation and runs headless.[/b] A
## dedicated server never loads this. That split is the reason `headless_match` can play
## a whole deathmatch with no renderer and no window, and it is the reason this file is
## the only one in the project that mentions a `Camera3D` or an `InputEvent`.
##
## Until this existed, game-arena was the reference game with nothing to sit down at:
## `ArenaNetBridge` ran, `headless_net` drove it, and there was no camera rig, no input
## sampling, no renderer and no sound. Everything here is modelled on `G2GClient`,
## which is the one in this family proven over a real socket and in a browser.
##
## [codeblock]
## WASD          move                Space   jump (hold; auto-hop is on)
## Ctrl          crouch              Mouse1  fire
## R             reload              1..4    weapon slots  (wheel cycles)
## Tab (hold)    scoreboard          Esc     release the mouse, then the menu
## H             help
## [/codeblock]

const CHANNEL := "arena.client"

## The player pressed Leave on the Escape menu.
##
## [b]Announced, and acted on by dot-menu's stock Leave[/b] ([member DotMenu.leave_on_its_own],
## set in [ArenaMenus]): connected, it disconnects the client link, and the shell that loaded
## this client goes back to its own menu on the disconnect; solo on a desktop it quits. This
## signal is for an embedder that wants to know. Until 2026-10-11 nothing listened to it and
## the button did nothing.
signal leave_requested()

## The level and the local player's camera exist, so the frame shows the game and not an
## empty room. A shell that knows the contract (dot-server-deploy's `_watch_game_ready`)
## keeps its loading screen up until this, then draws every material once under it so the
## shaders compile there rather than at the first shot; see [method warm_up_items]. Emitted
## again after each map change. Nothing here depends on anyone listening.
signal ready_to_show()

## dot-game's platform layer: the load gate and its cover (held until the level, the local
## body and the camera exist, then the weapon materials drawn once under it), the browser
## filesystem flush, and [signal DotGameClient.input_blocked_changed] for the sampler. Not its
## settings, menu, console, pointer or board: arena's are [ArenaMenus] and
## [ArenaPresentation], see [method _build_platform]. The root keeps `ready_to_show` and
## `warm_up_items` only because it declares its own signal (the gate then leaves it alone) and
## because a shell older than the gate asks the root's methods, not the gate.
var platform: DotGameClient = null
var gate: DotLoadGate

## Field of view, horizontal at 4:3. An arena shooter's number, not Godot's.
const FIELD_OF_VIEW := 100.0

var game: ArenaGame = null
var player: ArenaPlayer = null
var hud: ArenaHud = null
## The Escape menu, its pages and the Tab board: dot-menu's ([ArenaMenus]).
var game_menu: DotMenu = null
## The Tab board's rows from dot-match. See [ArenaMenus.Board].
var board: ArenaMenus.Board = null
## The match summary opened the Tab board (rather than a held Tab), so the client closes it.
var _summary_board_open: bool = false
## The final killcam ([ArenaKillcam]): records every frame, plays before the summary.
var killcam: ArenaKillcam = null
var winner_reveal: DotWinnerReveal = null
var _reveal_hid: Dictionary = {}
var _seen_match_state: int = -1
## Applies dot-menu's stock settings this game does not apply itself: the window, V-Sync,
## the frame cap and render scale.
var applier: DotMenuApplier = null
var net: DotNetManager = null
var bridge: ArenaNetBridge = null
var link: Node = null

## Chat, voice and map changes: the client halves of what [ArenaServices] and
## [ArenaMapDirector] run on the server.
##
## [b]Null offline, deliberately.[/b] All three are about a server that is telling this
## client something, and an offline game has nobody to be told by. Building them anyway
## would open a microphone in a single-player match.
var extras: ArenaClientExtras = null

## Play alone even when a link is available. `--offline`.
@export var force_offline: bool = false

## How many bots to add when playing offline. Zero is an empty arena. `bot_quota` at the
## console changes it while playing (people + bots, as on a server); `-- --bots N` at launch.
@export_range(0, 15, 1) var offline_bots: int = 3

var _offline := true
var _sampler: DotFpsSampler = null
var _fire := DotWeaponCommand.new()

## A weapon slot the player asked for this tick, or 0 for "no change". Cleared once
## sent — see [method _read_fire].
var _wanted_slot: int = 0

## What the server last said was left on the clock, in seconds. Negative for "no
## limit", which is what `DotMatch.seconds_remaining` returns and what the HUD reads as
## "show the state name instead".
var _match_seconds_remaining: float = -1.0

## Seconds since the last position report. See `_process`.
var _report_timer: float = 0.0

## Whether the cursor is waiting for a click before it can be captured. Web only.
var _awaiting_click := false

## Who [member player] should be, whether or not that player exists yet.
##
## [b]HELLO names you and JOIN creates you, in that order.[/b] A client that resolved
## the player here and never tried again holds null for the whole session — and the
## list of what that breaks is the interesting part: the HUD binds by id and works, the
## camera follows the entity and works, movement works because `DotFpsSampler.sample`
## polls the `InputMap` rather than reading events, and *everything below the
## `player == null` guard in `_unhandled_input` does not*. A client that connects,
## draws, shows a live HUD and walks around, with a dead mouse and a dead keyboard.
## g2gfast shipped exactly that and a person had to report it.
var _watch_id: int = -1

## The spectator's free camera while roaming, and the mouse motion not yet turned into a look.
var _free_cam: DotSpectatorFreeCam = null
var _roam_look: Vector2 = Vector2.ZERO

## Bots this client drives, offline only. Session id -> the bot's body.
var _bots: Dictionary = {}

## Their minds (ArenaBots.Mind), by session id: the same brain a server's bots run.
var _bot_minds: Dictionary = {}

## Names offline bots from dot-bot's pool, and keeps their number.
var _bot_roster := DotBotRoster.new()

## The next offline bot's session id.
var _next_bot_id: int = 100

## The meshes of the map currently drawn. Replaced on a map change.
var _level: Node3D = null

## The map's sun and environment (`ArenaMapLighting.build`), replaced with the level.
var _lighting: Node3D = null

## dot-browser's client half, and the screen over it.
var browser: ArenaBrowser = null

## Settings, audio, effects and the console. Everything that belongs to the person at the
## keyboard rather than to the match.
var presentation: ArenaPresentation = null

## Whether this client believes it is holding a prop.
##
## [b]A belief, not a fact, and the distinction is the whole reason props are not
## predicted.[/b] The server decides whether a grab happened; this is only what the
## next press of the same key should ask for. A rigid body's contact solver is not
## reproducible across machines, so a client that tracked a held prop's position
## locally would be corrected on every snapshot.
var _holding: bool = false

## The last `ArenaEvents.PropAct` a key asked the prop tool for, or -1. Noted before the
## request goes anywhere, so a suite with no server can see which key did what.
var last_prop_asked: int = -1

## The local player's hands, under their camera. Built on adoption.
var view_model: ZeeViewModel = null

## Every rocket and grenade in the air, drawn.
var projectile_view: ArenaProjectileView = null

## Where the dead lie: dot-player-char's ragdolls, built from each KILL's death (the server's
## pick) under [member ArenaGame.ragdoll_rules]. Client side.
var ragdolls: DotPlayerRagdolls = null

## The projectile layer whose detonations are being heard, so a new one is noticed.
var _heard_projectiles: RefCounted = null

## The slot in hand and the one before it, for Q. Read off the arsenal each tick, because
## the server decides what is in hand and a client that kept its own idea would switch
## "back" to a weapon the server already took away.
var _held_slot: int = 0
var _last_slot: int = 0


## dot-game's platform layer, added first so the cover is the first thing drawn.
##
## [b]Only the pieces that remove duplicate code without moving a documented rule.[/b] Taken:
## the gate (with the map hold and the weapon warm-up on it), the link and the offline
## answer, the browser flush, and the input-blocked signal. Left off, each for a reason:
## [code]use_settings[/code] and [code]use_console[/code], because the settings document is
## [ArenaPresentation]'s plain manager with a menu built round it by [ArenaMenus] (the
## Servers page, the camera rows) and the console must be built after that menu;
## [code]capture_pointer[/code], because Escape releases and then opens, and "Click to play"
## is arena's ([method _unhandled_input]); the Tab board, because [ArenaMenus].Board merges
## dot-match's records with the roster.
func _build_platform() -> void:
	platform = DotGameClient.new()
	platform.name = "Platform"
	platform.force_offline = force_offline
	platform.use_settings = false
	platform.use_console = false
	platform.capture_pointer = false
	platform.scoreboard_action = &""
	platform.spawned_fn = func() -> bool: return player != null and player.camera != null
	add_child(platform)
	gate = platform.gate
	link = platform.link as Node
	gate.ready_to_show.connect(func() -> void: ready_to_show.emit())
	gate.hold(&"map", "Loading the map")
	gate.warm_up(_weapon_warm_items())
	if ArenaFrameProbe.on() and DotWeb.available():
		# Lets a page script split its own frame log at the cover (window.arena_gate_open, ms).
		gate.opened.connect(func() -> void: DotWeb.eval("window.arena_gate_open = performance.now()", true))
	# The chat box and console have the keyboard, and so does the menu: the platform polls
	# this every frame, so there is no signal to forward from each of them.
	platform.busy_fn = _input_busy
	platform.input_blocked_changed.connect(_suspend_input)


func _ready() -> void:
	# zee-dot-weapons' art is this game's copy of it, wherever this game is mounted. A
	# delivered pack sits under `res://dot_cloud/<id>/<version>/`, and the pack's art table
	# names `res://assets/...` — so without this every gun loads invisible, one WARN each.
	ZeeModelCache.set_asset_root(ArenaPaths.root())
	ArenaFrameProbe.from_launch()

	# Closed before anything else is built, so no frame shows a half-made world.
	_build_platform()
	_offline = platform.offline

	game = ArenaGame.new()
	game.name = "Game"
	game.is_authority = _offline

	# [b]HEADLESS collision, on a client with a screen.[/b] It reads like the wrong
	# setting and it is the only correct one here.
	#
	# `Mode.HEADLESS` is not a degraded mode — it is `ArenaMap`'s analytic geometry, and
	# `ArenaMap`'s whole design is that the meshes, the physics bodies and the analytic
	# boxes come from ONE list of `AABB`s so they cannot drift. What matters for a
	# client is the last clause of dot-player-controller's own note on it: *it gives the
	# same answer on a client replaying a tick and a server that ran it.*
	#
	# A predicting client MUST use the same collision backend as the server it is
	# predicting against. The server is headless and analytic; a client on Godot physics
	# is a second solver with its own contact epsilons and its own idea of a step, so
	# every replay would land somewhere slightly different and reconciliation would
	# correct a client that had done nothing wrong. That is the 0.500 correction rate
	# this project already paid for once.
	#
	# Measured the first time it was tried the other way: `Mode.PHYSICS` needs a
	# collision shape on the player node, `ArenaPlayer` is a plain `Node3D`, and the
	# player fell through a floor that was drawn perfectly — a void with one box in it
	# and no error anywhere.
	#
	# The visible level below is still added: it is what the player SEES, and nothing
	# collides against it.
	game.headless = true
	game.register_service = _offline
	add_child(game)

	# Connected here, before anything can create a player, rather than inside
	# `_watch`. HELLO and JOIN are both reliable and ordered so HELLO does arrive
	# first — but "the ordering happens to save us" is exactly the reasoning that put
	# this bug in game-g2gfast, and a connection that costs nothing is cheaper than
	# depending on it. `_watch_id` is -1 until HELLO names us, so nothing matches
	# before then.
	game.player_added.connect(_on_player_added)
	# The mode's banner, the moment a client learns it: "Gun Game: every kill gives you a
	# different gun", the way the genre says it when you spawn into one.
	game.mode_shown.connect(func(shown: ArenaMode) -> void:
		if hud != null:
			hud.notice("%s  -  %s" % [shown.display_name, shown.description])
	)

	# Offline, `-- --map <id>` picks the map, as it does for a dedicated server; a
	# connected client is told the server's map and rebuilds on it.
	var built := game.setup(_startup_map() if _offline else ArenaMap.dm_box())

	if not built.ok:
		DotLog.result(CHANNEL, "the arena could not be built", built)
		return

	# The world, which the server does not need and a player cannot do without. Held,
	# because a map change has to take it away again — see `_on_map_changed`.
	_level = game.map.to_scene()
	_classify_level()
	add_child(_level)
	_light()
	# **Connected, this level is a placeholder and the cover stays up over it** (2026-10-19).
	# The server names its map only once the client says READY (`ArenaModule` admits the peer
	# to the map sync then), and the first `_on_map_changed` releases this hold. Released here,
	# the cover lifted on dm_box while the server's map was still a round trip (or a download)
	# away: the player saw and walked the wrong level, and the cover report told the server
	# the seat was loaded, so it could be shot behind the second cover the map change put up.
	# `client_bench` with a probe, dm_atrium at 100 ms each way: open on dm_box for 140 ms.
	if _offline:
		gate.release(&"map")

	projectile_view = ArenaProjectileView.new()
	projectile_view.name = "Projectiles"
	add_child(projectile_view)

	_build_ragdolls()
	_build_killcam()
	if _offline:
		# Solo, the world is this process's and there is no KILL message: the death the game
		# decided is on the kill's entry.
		game.player_killed.connect(_on_solo_kill)

	_sampler = make_sampler()
	# C slides as well as Duck: added once the key table has been applied, in
	# `_build_interface` (`_add_slide_key`), or applying it would take C off again.

	# Before the interface, because the field of view and the crosshair come out of the
	# settings document and a screen built first would have laid itself out from the
	# defaults.
	_build_presentation()
	_build_interface()

	# The player's look and crosshair settings, onto the two things they shape. After both
	# exist, and pushed rather than waited for: a value loaded from disk has not changed,
	# so a binding that only listened would leave a saved sensitivity doing nothing.
	if presentation != null:
		presentation.bind_look(_sampler.tunables)
		if hud != null:
			presentation.bind_crosshair(hud.crosshair)

	if _offline:
		_start_offline()
	else:
		var netted := _build_netcode()
		DotLog.result(CHANNEL, "netcode", netted)

	_grab_mouse()
	DotLog.result(CHANNEL, "the platform", platform.setup())
	_suspend_input(platform.is_input_blocked())


func _exit_tree() -> void:
	# A static outlives this game: the next one a shell loads must not look for its art
	# under this game's mount.
	ZeeModelCache.set_asset_root("res://")


## The map's own sun, sky and air, replacing whatever the last map had.
##
## [b]Per map, and replaced with the level[/b], because a built-in map carries its lighting
## as a dot-lighting document (`ArenaMap.lighting`) and the next map may be lit differently.
## Two `WorldEnvironment`s in one tree is the second one ignored with a warning, so the old
## one goes first, with `free()` for the same reason the level does.
func _light() -> void:
	if _lighting != null and is_instance_valid(_lighting):
		remove_child(_lighting)
		_lighting.free()

	_lighting = ArenaMapLighting.build(game.map)
	add_child(_lighting)


func _build_interface() -> void:
	hud = ArenaHud.new()
	hud.name = "Hud"
	add_child(hud)
	hud.build(game)
	# The hit pulse at the screen's edge is dot-fx's hurt flash, drawn: so it obeys the
	# player's "no flashes" and the flash rate limit like every other flash.
	if presentation != null:
		hud.flash_source = presentation.fx

	# The server browser: the one page that is about something other than this game. Built
	# whether or not this client is connected, because looking for a server is what you do
	# when you are not on one. A list that did not come up leaves the page out.
	browser = ArenaBrowser.new()
	browser.name = "Browser"
	add_child(browser)
	var listed := browser.setup()
	DotLog.result(CHANNEL, "the server browser", listed)
	browser.join_requested.connect(_on_join_requested)

	# [b]dot-menu's menu, and the client still owns the pointer.[/b] The menu is told not
	# to manage it: pointer lock needs a click in a browser, which only this client knows
	# about ([method _apply_mouse]), and two owners fighting is a cursor that flickers.
	game_menu = ArenaMenus.build(self, presentation, browser if listed.ok else null)
	# The HUD in the menu's theme and at the player's HUD size, switched live (dot-menu 7). By
	# name, so a client shell older than that still runs the game in dot-ui's dark default.
	if game_menu.has_method(&"follow_hud"):
		game_menu.call(&"follow_hud", hud, ArenaHud.accent_theme())
	# M: the maps and the modes (dot-menu's map menu). Solo a choice changes here at once;
	# connected the server decides, by the owner's `sv_map_menu_flag`, and anybody without it
	# gets a vote instead (dot-vote's map menu, over this game's ballot). By name, so a client
	# shell older than the map menu still runs the game without it.
	if game_menu.has_method(&"use_maps"):
		var maps: Variant = game_menu.call(&"use_maps", map_menu_rows, change_from_menu)
		if maps is Object:
			(maps as Object).set(&"noun", "maps and modes")
	_use_loadout_menu()
	game_menu.action_requested.connect(func(id: StringName) -> void:
		if id != ArenaMenus.LEAVE:
			return
		# Closed first, so a client that cannot actually leave (an embedded one, a
		# single-process test) is not left showing a menu over a game that carried on.
		game_menu.close()
		leave_requested.emit())
	# The menu, its help or the console opening or closing: the pointer and the sampler.
	game_menu.overlays_changed.connect(func(_open: bool) -> void:
		_apply_mouse())

	board = ArenaMenus.Board.new(
		game_menu.scoreboard, game.match_node.scoreboard,
		link if not _offline else null, game.match_node.teams, game
	)

	if presentation != null:
		applier = DotMenuApplier.new()
		applier.name = "Applier"
		applier.settings = presentation.settings
		add_child(applier)
		applier.bind_audio(presentation.audio)
		applier.bind_fx(presentation.fx)
		DotLog.result(CHANNEL, "the settings applier", applier.setup())
		presentation.settings.changed.connect(func(key: StringName, value: Variant, _w: StringName) -> void:
			if key == &"hud_safe_area" and hud != null:
				hud.set_safe_area(float(value))
			elif presentation.bindings.row_for_setting(key).size() > 0:
				# Deferred: the table applies a rebound row after the setting changes. Any
				# row, not only Duck's: one given C takes C off the slide.
				_add_slide_key.call_deferred()
				_hud_keys.call_deferred())
		hud.set_safe_area(presentation.settings.get_float(&"hud_safe_area", 16.0))
	_add_slide_key()
	_hud_keys()


## The keys the HUD's buttons, hints and prompts name, from the key table as the player
## has it bound. Slide says C while Duck is on its default, because that is where C slides.
func _hud_keys() -> void:
	if hud == null or presentation == null or presentation.bindings == null:
		return
	var table: DotMenuBindings = presentation.bindings
	hud.keys[&"jump"] = table.key_for(&"dot_fps_jump")
	hud.keys[&"dash"] = table.key_for(ArenaBindings.DASH)
	hud.keys[&"chat"] = table.key_for(ArenaBindings.CHAT)
	hud.keys[&"scoreboard"] = table.key_for(ArenaBindings.SCOREBOARD)
	hud.keys[&"reload"] = table.key_for(ArenaBindings.RELOAD)
	hud.keys[&"help"] = table.key_for(DotMenuBindings.HELP_ACTION)
	hud.keys[&"maps"] = table.key_for(&"dot_menu_maps")
	hud.keys[&"loadout"] = table.key_for(&"dot_menu_loadout") if loadout_menu != null else ""
	hud.keys[&"launch"] = table.key_for(launch_action())
	hud.keys[&"roam"] = table.key_for(ArenaBindings.ROAM)
	for i in range(ArenaBindings.SLOTS.size()):
		hud.keys[StringName("slot_%d" % (i + 1))] = table.key_for(ArenaBindings.SLOTS[i])
	hud.keys[&"slide"] = "C" if _slide_on_c() else table.key_for(ArenaBindings.DUCK)


## The movement sampler, with dot-player-controller's default actions registered for any
## the key table has not made yet.
##
## [b]No noclip key.[/b] The addon's default for it is V, which is push to talk here, and
## arena's noclip is an administrator's modifier (`noclip` at the console or in chat; the
## motor ignores the bit unless the server granted it). The role is taken off before the
## defaults are registered, so `dot_fps_noclip` is never created on V and V does one thing.
static func make_sampler() -> DotFpsSampler:
	var sampler := DotFpsSampler.new(ArenaPlayer.arena_tunables())
	sampler.actions["noclip"] = &""
	var _registered := DotFpsSampler.register_default_actions(sampler)
	return sampler


## C slides as well as Duck, while Duck is on its default key and no other row has been
## given C. A slide IS a duck at a run, and C is where the genre puts it. Deferred after a
## rebind: the table applies the row after the setting changes, and that apply would take
## C off again.
##
## [b]Taken off again when another row gets C.[/b] C is not a stored binding, so the
## table's swap cannot see it: binding Last weapon to C would otherwise have one press
## switch weapons and slide.
func _add_slide_key() -> void:
	if _sampler == null:
		return
	var duck := _sampler.actions.get("crouch", &"") as StringName
	if _slide_on_c():
		_add_key(duck, KEY_C)
	elif presentation != null and presentation.bindings != null:
		var row := presentation.bindings.row_for_action(duck)
		if not row.is_empty():
			var _bound := presentation.bindings.apply_row(row, presentation.bindings.stored(row, presentation.settings))


## Whether C is Duck's second key now: Duck on its default and C on no other row.
func _slide_on_c() -> bool:
	if presentation == null or presentation.settings == null or presentation.bindings == null:
		return true
	var table: DotMenuBindings = presentation.bindings
	var duck := table.row_for_action(ArenaBindings.DUCK)
	if duck.is_empty() or table.stored(duck, presentation.settings) != str(duck["default"]):
		return false
	return table.row_using("C", &"bind_duck", presentation.settings).is_empty()


## A fresh map by id: the game's own, else a subscribed pack's from the catalogue the menu
## lists (so only a solo, accepted, valid one). Null value with ok is not returned: an unknown
## id is a failure here, as the menu's own refusal.
func _build_map(id: StringName) -> DotResult:
	var own := ArenaMap.by_id(id)
	if own != null:
		return DotResult.success(own)
	if _menu_catalogue == null:
		_menu_catalogue = ArenaMaps.catalogue()
	var def := _menu_catalogue.get_map(id)
	if ArenaMaps.is_workshop(def):
		return ArenaMaps.build_workshop(def)
	return DotResult.fail(DotError.CODE_INVALID, "There is no map called '%s'." % id)


# --- Offline ---------------------------------------------------------------
# --- The map menu (M) ------------------------------------------------------

# --- The loadout menu (B) -----------------------------------------------------

## dot-menu's loadout menu, or null on a host whose dot-menu predates it (API 6).
var loadout_menu: Object = null
var _loadout_restored := false
var _loadout_scratch := false
var _account_auth: Object = null

## dot-auth's client, as the shell that signed the player in registers it. Absent solo
## without a shell, or from a shell that predates it: then every loadout is "local".
const AUTH_SERVICE := &"dot_auth_client"

const WEAPON_CARDS_SCRIPT := "res://addons/zee_weapons/content/zee_weapon_cards.gd"
var _weapon_cards: Script = null
var _weapon_table: Dictionary = {}


## B: primary, sidearm, melee, grenades and gear, as cards with each weapon's picture and
## numbers. Solo the game's own loadouts answer; connected the server does (dot-loadout's
## `/loadout`), under the owner's `mp_loadout_*` rules. Guarded on the host's dot-menu and
## dot-loadout levels, so an older client shell still runs the game without it.
func _use_loadout_menu() -> void:
	if DotAddonApi.build_level("dot_menu") < 6 or DotAddonApi.build_level("dot_loadout") < 2:
		return
	if not game_menu.has_method(&"use_loadout"):
		return
	loadout_menu = game_menu.call(&"use_loadout", loadout_offer, choose_loadout, decorate_loadout_choice)
	if loadout_menu != null:
		# Remembered under the signed-in site account (or "local" as a guest), and never
		# from a suite or a render on scratch settings: those must not write, or read back, a
		# player's real choice.
		_loadout_scratch = ArenaPresentation.settings_directory.begins_with("user://scratch/")
		follow_account(DotRegistry.get_node_service(AUTH_SERVICE))


## The key a loadout is remembered under for [param auth] (a DotAuthClient, or null): its
## account's public id when signed in, "local" for a guest or a client with no auth. Never a
## token. Untyped because a shell older than dot-auth's `account_key` has no such method.
static func loadout_account_key(auth: Object) -> String:
	if auth == null or not is_instance_valid(auth) or not auth.has_method(&"account_key"):
		return "local"
	var key := str(auth.call(&"account_key"))
	return key if key != "" else "local"


## Files the loadout under [param auth]'s account from now on, and again whenever the player
## signs in or out mid-session (a different account's choice is then the one restored).
func follow_account(auth: Object) -> void:
	if _account_auth != null and is_instance_valid(_account_auth):
		for sig: StringName in [&"signed_in", &"signed_out"]:
			if _account_auth.is_connected(sig, _on_account_changed):
				_account_auth.disconnect(sig, _on_account_changed)
	_account_auth = auth
	if auth != null and is_instance_valid(auth):
		for sig: StringName in [&"signed_in", &"signed_out"]:
			if auth.has_signal(sig):
				auth.connect(sig, _on_account_changed)
	_rekey_loadout()


func _on_account_changed(_identity: Variant = null) -> void:
	_rekey_loadout()
	if _loadout_restored:
		_loadout_restored = false
		_restore_loadout()


func _rekey_loadout() -> void:
	if loadout_menu != null:
		loadout_menu.call(&"remember_as", "" if _loadout_scratch else "arena", loadout_account_key(_account_auth))


## Solo: what this player may pick, from the game's own manager.
func loadout_offer() -> Variant:
	if game == null or game.loadout_command == null or player == null:
		return DotResult.fail(DotError.CODE_STATE, "Join the match first.")
	return await game.loadout_command.call(&"offer", ArenaGame.storage_key(player.player_id))


## Solo: saves [param picks], and hands them over now in warmup or spawn protection.
func choose_loadout(picks: Dictionary) -> Variant:
	if game == null or game.loadout_command == null or player == null:
		return DotResult.fail(DotError.CODE_STATE, "Join the match first.")
	return await game.loadout_command.call(&"choose", null, ArenaGame.storage_key(player.player_id), picks)


## A card's picture (the HUD's rendered weapon silhouettes) and numbers (zee's cards).
func decorate_loadout_choice(_slot_id: String, choice: Dictionary) -> Dictionary:
	var id := StringName(str(choice.get("id", "")))
	var out: Dictionary = {}
	var icon := ArenaHudGlance.Ink.weapon_icon(id)
	if icon != null:
		out["icon"] = icon
	if id == &"armour":
		out["detail"] = "Takes half of every hit until it wears through."
		out["kind"] = "Gear"
		out["stats"] = [{"label": "Armour", "value": 1.0, "text": "100"}]
		return out
	if _weapon_cards == null and DotAddonApi.build_level("zee_weapons") >= 3 and ResourceLoader.exists(WEAPON_CARDS_SCRIPT):
		_weapon_cards = load(WEAPON_CARDS_SCRIPT) as Script
	if _weapon_table.is_empty():
		_weapon_table = ArenaContent.weapon_table()
	if _weapon_cards != null and _weapon_table.has(id):
		var card: Variant = _weapon_cards.call(&"card", _weapon_table[id])
		if card is Dictionary:
			out.merge(card as Dictionary)
	return out


## Sends the choice this player saved last time (dot-menu remembers it on this device), once
## per join: solo into the game's own manager, connected to the server.
func _restore_loadout() -> void:
	if loadout_menu == null or _loadout_restored:
		return
	_loadout_restored = true
	var _sent: Variant = await loadout_menu.call(&"restore")


## Built once: making the catalogue builds every map, the imported ones included.
var _menu_catalogue: DotMapCatalogue = null


## What M lists solo, in the ballot's ids so a server's list reads the same: every map that
## can host the mode being played (`map:<id>`), then every mode the map being played can host
## (`mode:<id>`).
func map_menu_rows() -> Array:
	if game == null:
		return []
	if _menu_catalogue == null:
		_menu_catalogue = ArenaMaps.catalogue()
	var here := game.map.id if game.map != null else &""
	return ArenaMaps.menu_rows(_menu_catalogue, here, game.mode, ArenaModes.all())


## Solo: a map (`map:<id>`) or a mode on this map (`mode:<id>`), now. The game changes and the
## level is rebuilt as a server's change would have it rebuilt ([method _on_map_changed]).
func change_from_menu(id: StringName) -> DotResult:
	if not _offline:
		return DotResult.fail(DotError.CODE_STATE, "The server changes the map.")
	var text := String(id)
	var map := game.map
	var mode: ArenaMode = null
	if text.begins_with("map:"):
		var built := _build_map(StringName(text.substr(4)))
		if not built.ok:
			return built
		map = built.value
	elif text.begins_with("mode:"):
		mode = ArenaModes.by_id(StringName(text.substr(5)))
		if mode == null:
			return DotResult.fail(DotError.CODE_INVALID, "There is no mode called '%s'." % text.substr(5))
		var rebuilt := _build_map(game.map.id)
		if not rebuilt.ok:
			return rebuilt
		map = rebuilt.value
	if map == null:
		return DotResult.fail(DotError.CODE_INVALID, "There is no map called '%s'." % text)
	var changed := game.change_map(map, mode)
	if not changed.ok:
		return changed
	if _menu_catalogue == null:
		_menu_catalogue = ArenaMaps.catalogue()
	var def := _menu_catalogue.get_map(map.id)
	if def != null:
		_on_map_changed(def)
	return DotResult.success(id)


# --- Offline ---------------------------------------------------------------

## The map an offline client starts on: `-- --map <id>`, else `dm_box`.
##
## An unknown id is said out loud and the default played, because a person who typed a
## map name and got a different room has nothing else to tell the two apart by.
static func _startup_map() -> ArenaMap:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--map")

	if index < 0 or index + 1 >= args.size():
		return ArenaMap.dm_box()

	var map := ArenaMap.by_id(StringName(args[index + 1]))

	if map == null:
		DotLog.warn(CHANNEL, "no such map, playing dm_box", {
			"asked": args[index + 1],
			"known": ArenaMap.ids() + ArenaMap.imported_ids(),
		})
		return ArenaMap.dm_box()

	return map


func _start_offline() -> void:
	game.start(0)

	# Offline this game is the authority, so the confirmations come off it directly; the
	# same handlers a server's HIT, AWARD and KILL reach. The feed is the HUD's own
	# `player_killed` connection, so this one leaves the feed alone.
	game.hit_confirmed.connect(
		func(attacker: int, victim: int, amount: float, point: Vector3, headshot: bool, lethal: bool) -> void:
			if player != null and attacker == player.player_id:
				_on_hit({
					"victim_id": victim, "amount": amount, "point": point,
					"headshot": headshot, "lethal": lethal,
				})
	)
	game.medals_awarded.connect(
		func(killer: int, victim: int, medals: Array, points: int, streak: int) -> void:
			_on_award({
				"killer_id": killer, "victim_id": victim, "medals": medals,
				"points": points, "streak": streak,
			})
	)
	game.player_killed.connect(func(entry: DotKillFeed.Entry) -> void:
		if hud != null:
			hud.note_kill(
				{
					"killer_id": int(entry.killer_key) if entry.killer_key.is_valid_int() else 0,
					"victim_id": int(entry.victim_key) if entry.victim_key.is_valid_int() else 0,
					"weapon": ArenaHud.cause_label(entry.cause),
				},
				player.player_id if player != null else 0,
				entry.killer_name
			)
	)

	# [b]Named as ours BEFORE it exists.[/b] `add_player` emits `player_added`
	# synchronously, and `_on_player_added` gives every player it does not recognise as
	# ours a body to be seen as. With `_watch_id` still -1 that was this one: the local
	# player wore a capsule and a nose with the camera inside it, and the nose was a pale
	# slab across the bottom of every offline frame. A networked client never had it,
	# because HELLO names the session before JOIN creates it.
	_watch_id = 1

	var added := game.add_player(1, "Player")

	if added.ok:
		_adopt(added.value as ArenaPlayer)

	_bind_bot_console()
	_keep_offline_bots(_launch_bots())


# --- Networked -------------------------------------------------------------

func _build_netcode() -> DotResult:
	# The server's `mp_teammate_passthrough` through the link (ArenaGame.follow_server_cvars).
	if link != null:
		var _following := game.follow_server_cvars(link)

	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.local_peer_id = multiplayer.get_unique_id() if multiplayer != null else 2
	net.auto_tick = false
	net.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = game.tick_rate
	config.snapshot_rate = ArenaGame.snapshot_rate_for(game.tick_rate)
	config.enable_prediction = true
	# Off on a client: rewinding is what a server does to resolve somebody else's shot,
	# and a client resolves nobody's.
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 64
	# From the game, not written here. See ArenaGame.NET_WORLD_EXTENT — this line said
	# 256 while the server said 128, and a quantised position decoded against the wrong
	# range is a different position rather than a less precise one.
	config.world_extent = ArenaGame.NET_WORLD_EXTENT
	# One reconciliation a frame, against the newest snapshot, however many arrived: each
	# replays the whole input lead, and a browser that read a stall's worth of queued
	# snapshots in one frame replayed them all and never caught up (docs/netcode.md, "A
	# frame's cost"). By name, because a pack runs on whatever dot-net its shell carries.
	# `cl_reconcile_per_snapshot 1` at launch is the old way, kept so the two can be
	# measured against each other in one build under the same load.
	if &"reconcile_once_per_frame" in config:
		config.set(&"reconcile_once_per_frame", ArenaFrameProbe.launch_value("cl_reconcile_per_snapshot") != "1")
	# And none at all when the snapshot says what this client already predicted, which is
	# most of them: the replay's cost is the lead, a round trip of ticks, so without this a
	# higher ping was a slower frame (docs/netcode.md, "A frame's cost"). By name for the
	# same reason; `cl_replay_always 1` at launch replays every one, for an A/B.
	if &"skip_matching_replays" in config:
		config.set(&"skip_matching_replays", ArenaFrameProbe.launch_value("cl_replay_always") != "1")
	net.config = config
	add_child(net)

	var started := net.setup()

	if not started.ok:
		return started

	bridge = ArenaNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	var attached := bridge.attach(game, net)

	if not attached.ok:
		return attached

	# Under the link, and NAMED the same as the server's — the name is the routing.
	bridge.open_link(link)
	net.messages.seal()

	# The client halves. Built here rather than in `_ready` because every one of them
	# needs the bridge, and there is no bridge offline.
	extras = ArenaClientExtras.new()
	extras.name = "Extras"
	add_child(extras)

	var extra := extras.attach(bridge, game)
	DotLog.result(CHANNEL, "the client's chat, voice and map layers", extra)
	platform.look_voice = extras.voice
	platform.look_chat = extras.chat
	platform.look_gag_action = ArenaBindings.VOICE_GAG
	platform.look_mute_action = ArenaBindings.VOICE_MUTE
	platform.look_position_fn = _look_position
	platform.build_look_mute()

	# The join's map hold (see `_ready`) is let go by the first map the server names; if
	# that map cannot be had, a cover that never lifts is worse than the level in hand.
	if extras.maps != null:
		extras.maps.fetch_failed.connect(func(_map: DotMapDef, _error: DotError) -> void:
			gate.release(&"map"))
		extras.maps.change_aborted.connect(func(_id: StringName, _reason: String) -> void:
			gate.release(&"map"))
	else:
		gate.release(&"map")

	extras.said.connect(_on_said)

	# What the server says is carrying chat. It decides whether the box is drawn at all
	# when the player's setting is `auto`.
	extras.chat_relay_changed.connect(func(relayed: bool) -> void:
		if presentation != null:
			presentation.set_chat_relayed(relayed)
	)

	# [b]Where chat actually arrives.[/b] `ArenaServices` routes a line through
	# dot-chat and then hands it to dot-server's manager to put on the wire, so on
	# this end it lands on `DotClientLink.chat_received` — not on anything dot-chat
	# owns. Without this connection the client's `DotChatClient` is a history nothing
	# feeds: empty scrollback, zero unread, and chat working perfectly on screen.
	if link != null and link.has_signal("chat_received"):
		link.connect("chat_received", extras.receive_wire)
	extras.map_changing.connect(_on_map_changing)
	extras.map_changed.connect(_on_map_changed)

	bridge.hello_received.connect(_on_hello)
	bridge.notice_received.connect(_on_notice)
	bridge.vote_received.connect(_on_vote)
	bridge.kill_received.connect(_on_kill)
	bridge.hit_received.connect(_on_hit)
	bridge.award_received.connect(_on_award)
	bridge.match_received.connect(_on_match)

	# The one thing that writes an RTT sample. dot-net never touches a transport, so
	# nothing in it can; without this the clock's input lead omits the flight time and
	# past ~30 ms every command arrives after its tick and is discarded as late.
	# ENet's own round trip when on ENet, the heartbeat's otherwise: see `link_rtt_ms`.
	if link != null:
		bridge.rtt_source = func() -> float: return ArenaNetBridge.link_rtt_ms(link)

	# READY, and not one byte before the scene exists. dot-server's signon finishes and
	# THEN the client builds this; anything the server sent in between landed on a node
	# that did not exist and was lost, one "Node not found" per call.
	if link != null and link.has_method("is_playing") and bool(link.call("is_playing")):
		_say_ready()
	elif link != null and link.has_signal("spawned"):
		link.connect("spawned", _say_ready, CONNECT_ONE_SHOT)

	return net.start()


func _say_ready() -> void:
	if bridge != null:
		bridge.send_request(ArenaEvents.Ask.READY)


## A chat line, on the HUD's notice line.
##
## The HUD is the whole chat window this game has, which is a level of ambition rather
## than an oversight: a scrolling window with an input field is a screen, and a screen
## is [DotScreenStack]'s. [DotChatClient] is holding the history the moment somebody
## writes one.
# --- Chat ------------------------------------------------------------------

## Joins the chat box to the two things it needs: a way out, and a way to stop the player.
##
## [b]The sampler is the half that is easy to forget.[/b] `swallows_input` keeps typed keys
## out of `_unhandled_input`, but movement here is POLLED — `DotFpsSampler.sample` reads
## the device every physics frame and does not care what consumed an event. Without
## `suspended`, typing "sw" walks you backwards off whatever you were standing on.
## `DotFpsSampler.suspended` is documented "for a chat box or a menu" and until now
## nothing in this game had ever set it.
func _wire_chat_window() -> void:
	var window: DotChatWindow = presentation.chat_window if presentation != null else null

	if window == null:
		return

	window.submitted.connect(_on_chat_submitted)


## Something other than the cover has the keyboard or the screen.
func _input_busy() -> bool:
	return (presentation != null and presentation.swallows_input()) \
		or (game_menu != null and game_menu.any_open())


## Movement stops while anything has the keyboard or the screen: the cover, the chat box,
## the console, or dot-menu's menu ([member platform]'s [code]busy_fn[/code] says which). Only
## when none does is it given back, so the console closing while the chat box is still open
## does not walk the player.
func _suspend_input(blocked: bool) -> void:
	if _sampler != null:
		_sampler.suspended = blocked


## Whether the menu, its help or the console is up, in which case the mouse is a pointer.
func _menu_open() -> bool:
	return game_menu != null and game_menu.any_open()


## What a player typed, on its way to the server.
##
## [b]Nothing is filtered here.[/b] The server decides what a line may contain and its
## answer is the only one that counts; a client that filtered first would be a second
## filter that drifts from the real one.
func _on_chat_submitted(text: String, channel: StringName) -> void:
	if _offline:
		# Offline there is no server to decide anything, so the line goes straight to the
		# log. Saying nothing at all would read as a chat box that does not work.
		if presentation != null and presentation.chat_window != null:
			presentation.chat_window.add_said(
				_local_display_name(), text, Color(0.62, 0.78, 1.0)
			)
		return

	if link != null and link.has_method("send_chat"):
		link.send_chat(text, channel == &"team")


## What to draw beside an offline player's own line.
func _local_display_name() -> String:
	if player != null and player.display_name != "":
		return player.display_name

	return "You"


## A line somebody said, in the chat box, with the name drawn apart from the text.
func _on_said(speaker: String, text: String, kind: String) -> void:
	# The server's own lines also go on the HUD's centre notice. Only those: every line
	# used to, which put whatever anybody typed in the middle of the screen.
	if kind == "system" and hud != null:
		hud.notice(text)

	if presentation == null or presentation.chat_window == null:
		return

	# The server has already decided who hears a team line; the colour is only so that a
	# player can see which of their own lines went where.
	var speaker_colour := Color(0.55, 0.85, 0.60) if kind == "team" else Color(0.62, 0.78, 1.0)

	if speaker == "":
		presentation.chat_window.add_text(text, Color(0.80, 0.82, 0.86))
		return

	presentation.chat_window.add_said(speaker, text, speaker_colour)


func _on_map_changing(map: DotMapDef) -> void:
	if hud != null:
		hud.notice("Changing map to %s…" % map.name_or_id())


## The world was replaced under this client.
##
## [b]The meshes have to go with it, and nothing else does that.[/b]
## `ArenaGame.change_map` replaces the collision, the trace and the match; the level a
## player can SEE is a scene this client added, and a client that rebuilt one and not
## the other would walk through walls it can see and stop at walls it cannot.
func _on_map_changed(map: DotMapDef) -> void:
	# Cover and stop the frozen body until the new level is in (released below).
	gate.hold(&"map", "Loading the map")
	# **The client has to ADOPT the map it was handed, and this is where that was
	# missing.** `ArenaGame.map` is assigned in exactly three places — `setup`, the
	# module's mode change, and `change_map` — and every one of them runs on the
	# SERVER. A mirroring client never calls `change_map`; it is told the new map by
	# `DotMapSyncClient` and that is the only notice it ever gets.
	#
	# So this handler received the correct `DotMapDef` and then rebuilt the level from
	# `game.map`, which was still whatever it had been at signon. Measured on a live
	# server: the server swapped dm_atrium for dm_box and reported `all peers have the
	# map`, and the client tore down its level and rebuilt **the same one**. The player
	# was then standing in geometry the server no longer had, with the server's
	# collision somewhere else entirely — which reads as the client freezing, because
	# every move they make is refused by a wall they cannot see.
	#
	# Nothing errored on either end. The server was right, the protocol completed, the
	# handshake reported success, and the one line that mattered read a stale field.
	# [b]Only when it is not already the one in hand.[/b] The client's own
	# `ArenaMapSession` ran `ArenaGame.change_map` before this signal, so normally
	# `game.map` IS the announced map — and for an imported one it is the instance the game
	# bound its solid to (`collision_root`). Replacing it with a fresh `by_id` would leave
	# the trace below bound to nothing: every shot through every wall.
	var adopted := (
		game.map if game.map != null and game.map.id == map.id else ArenaMap.by_id(map.id)
	)

	if adopted != null:
		game.map = adopted
		# **And every player already here moves with it** (2026-10-18). `change_map` rebinds
		# its roster, but a joining client adopts the announced map here without it, after
		# its own player was built against the signon map (`dm_box`): the server walked
		# dm_atrium while the client predicted dm_box's walls, so every snapshot near a wall
		# disagreed. `client_bench --play` on dm_atrium: 83-95% of reconciles corrected,
		# about 2.5 ticks replayed a frame, and a client predicting a level it cannot see.
		for player in game.players():
			if player != null and player.map_in_hand() != adopted:
				player.apply_map_movement(game.map_movement())
				player.rebind_map(adopted)
	else:
		# A delivered map this build has no geometry for. The level cannot be drawn,
		# and drawing the OLD one is what this whole comment is about — so say so
		# rather than silently showing a world that is not there.
		DotLog.warn(CHANNEL, "the announced map has no local geometry", {
			"map": String(map.id),
		})

	if _level != null and is_instance_valid(_level):
		remove_child(_level)
		# free(), not queue_free(): the new one goes in on this line and a deferred
		# free would leave two levels drawn over each other for a frame.
		_level.free()

	_level = game.map.to_scene()
	_classify_level()
	add_child(_level)
	_light()
	gate.release(&"map")

	# A mirroring client's combat manager is never rebuilt — `change_map` is the server's —
	# and its trace is what the copies of every rocket and grenade bounce off. Left alone,
	# a grenade on the new map bounces off the walls of the old one.
	if not _offline and game.combat != null:
		game.combat.trace = game.map.shot_trace()
	if game.projectiles != null:
		game.projectiles.clear()
	if ragdolls != null:
		# A body lying on the old map's floor would hang in the new one's air.
		ragdolls.clear()

	if presentation != null:
		# Everything drawn for the old map is meaningless now -- a decal is a hole in a
		# wall that no longer exists, and a decal ring that survives a map change is one
		# that survives the map it was about.
		presentation.on_map_changed(game.map.id if game.map != null else &"")

	if hud != null:
		# An imported map is somebody else's work, and its author is named where it starts.
		var by := (
			", by %s" % game.map.author
			if game.map != null and game.map.is_imported() and game.map.author != "" else ""
		)
		hud.notice("Now playing %s%s." % [map.name_or_id(), by])


## Asks the server to do something with a prop.
##
## [b]An intent over the wire, and the aim is the only thing on it.[/b] The server
## already knows where this player is — it simulated them — and a client that could
## name its own origin could grab a prop from across the map. What it cannot know is
## where they were looking between two ticks, so that is the claim, and
## `DotPropTool.may_act_on` is what decides whether it reaches.
func _ask_prop(action: int) -> void:
	last_prop_asked = action
	if _offline or bridge == null or player == null:
		return

	var state := player.controller.state

	bridge.send_request(
		ArenaEvents.Ask.PROP_TOOL,
		ArenaEvents.write_prop_act(action, state.yaw, state.pitch)
	)


## The player picked a server.
##
## [b]It does not connect, and that is honest rather than lazy.[/b] Joining means
## tearing down this client's netcode, opening a transport at a new address and going
## through dot-server's signon again — which is a launcher's job, and this game is
## loaded BY one. What this does is note the visit, so the server lands in the
## player's history, and say where to go.
func _on_join_requested(entry: DotBrowserEntry) -> void:
	if browser != null:
		browser.note_connected(entry.key())

	if hud != null:
		hud.notice("Join %s at %s" % [entry.name, entry.join_address()])

	DotLog.info(CHANNEL, "the player picked a server", {
		"name": entry.name, "address": entry.join_address()
	})


func _on_hello(info: Dictionary) -> void:
	_watch(int(info["session_id"]))

	if hud != null:
		hud.notice("Connected to %s" % String(info["map_name"]))


## The server's match state, put where the HUD already reads it.
##
## [b]The client's own `DotMatch` never runs.[/b] Nothing ticks it, it has no spawn
## points and its scoreboard is fed by replication, so every value on it is whatever it
## was constructed with — and `ArenaHud` reads `match_node.state` and
## `seconds_remaining()` directly. Before this, a connected browser client showed
## "IDLE" for ever while the server was playing a round: not a stale value, a value
## nothing had ever written.
##
## Written onto the node rather than into a parallel copy so the HUD stays one code
## path. A HUD that read one field on a server and another on a client would be two
## HUDs, and only one of them would ever be looked at.
func _on_match(info: Dictionary) -> void:
	if game == null or game.match_node == null:
		return

	var was := game.match_node.state
	game.match_node.state = int(info["state"]) as DotMatch.State
	game.match_node.round_number = int(info["round"])

	# The end of the match: the scoreboard comes up by itself, and the notice line names
	# the most valuable player, which is the summary the genre shows between matches.
	if game.match_node.state == DotMatch.State.MATCH_END and was != DotMatch.State.MATCH_END:
		_begin_match_end()
	elif was == DotMatch.State.MATCH_END and game.match_node.state != DotMatch.State.MATCH_END:
		if killcam != null:
			killcam.skip()
		if winner_reveal != null:
			winner_reveal.skip()
	# The summary board came up by itself, so nothing is holding Tab to close it: it goes
	# when the next match begins, else it covers the whole of the next round.
	if was == DotMatch.State.MATCH_END and game.match_node.state != DotMatch.State.MATCH_END and _summary_board_open:
		_summary_board_open = false
		if game_menu != null:
			game_menu.scoreboard.close()

	# What the HUD's "24 / 35" divides by. This match's rules are its own copy
	# (`ArenaGame` duplicates the mode's), so writing them touches nothing shared.
	if info.has("score_limit") and game.match_node.rules != null:
		game.match_node.rules.score_limit = int(info["score_limit"])

	# Ticks, divided by OUR rate — which HELLO set to the server's, so the two agree.
	# Sending seconds instead would have been a number derived from the sender's rate
	# and read as though it were derived from the receiver's.
	var ticks := int(info["remaining_ticks"])
	_match_seconds_remaining = (
		-1.0 if ticks < 0 else float(ticks) / float(maxi(game.tick_rate, 1))
	)

	if hud != null:
		hud.remaining_override = _match_seconds_remaining


func _on_notice(text: String) -> void:
	if hud != null:
		hud.notice(text)


## The map vote's cue and countdown. The ballot itself arrives as chat, which is where
## `announce_fn` sends it; this is what chat cannot carry.
func _on_vote(info: Dictionary) -> void:
	var seconds_left := int(info.get("seconds_left", 0))

	if seconds_left > 0 and hud != null:
		hud.notice(
			"%s in %d…" % ["Runoff" if bool(info.get("runoff", false)) else "Map vote", seconds_left]
		)

	if presentation != null:
		presentation.on_vote_cue(StringName(str(info.get("cue", ""))))


func _on_kill(info: Dictionary) -> void:
	# The feed is dot-ui's and takes an entry, not a dictionary. Rebuilt here rather
	# than replicated as one, because a `DotKillFeed.Entry` has ten fields and three of
	# them are only meaningful on the server that scored it.
	if hud == null or game == null:
		return

	var entry := DotKillFeed.Entry.new()
	entry.killer_key = str(int(info["killer_id"])) if int(info["killer_id"]) != 0 else ""
	entry.victim_key = str(int(info["victim_id"]))
	entry.cause = StringName(String(info["weapon"]))
	entry.headshot = bool(info["headshot"])
	if killcam != null:
		killcam.note_kill(int(info["killer_id"]), int(info["victim_id"]), String(info["weapon"]), entry.headshot)

	var killer := game.player_for(int(info["killer_id"]))
	var victim := game.player_for(int(info["victim_id"]))
	entry.killer_name = killer.display_name if killer != null else "the world"
	entry.victim_name = victim.display_name if victim != null else "?"

	hud.show_kill(entry)
	hud.note_kill(info, player.player_id if player != null else 0, entry.killer_name)

	# A headshot you made says so over the body, briefly, rising: the bullseye the genre
	# draws. A Label3D, because it belongs where the victim is, not on the HUD.
	if (
		player != null and victim != null and int(info["killer_id"]) == player.player_id
		and bool(info["headshot"])
	):
		var tag := Label3D.new()
		tag.text = "HEADSHOT!"
		tag.modulate = Color(1.0, 0.25, 0.2)
		tag.outline_modulate = Color(0.0, 0.0, 0.0, 0.8)
		tag.font_size = 48
		tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		tag.no_depth_test = true
		victim.get_parent().add_child(tag)
		tag.global_position = victim.global_position + Vector3(0.0, 2.3, 0.0)
		var rise := tag.create_tween()
		rise.tween_property(tag, "global_position:y", tag.global_position.y + 0.8, 1.2)
		rise.parallel().tween_property(tag, "modulate:a", 0.0, 1.2)
		rise.tween_callback(tag.queue_free)

	# The body comes apart, if the server's rules say this death breaks one. Seeded from
	# the victim and the tick so every client breaks it the same way; pushed away from
	# the killer, which every client knows. Then what is left of it falls, the way the
	# server picked (`death_*` on the KILL), so every client draws the same fall.
	if victim != null and victim != player:
		var away := Vector3.ZERO
		if killer != null:
			away = victim.global_position - killer.global_position
			away.y = 0.0
		var _broke := victim.break_body(
			game.break_rules(),
			away,
			# Not the tick: each client receives this at its own tick, and a seed that
			# differs per client breaks a different arm on every screen.
			int(info["victim_id"]) * 7919 + int(info["killer_id"]),
			bool(info.get("critical", false))
		)
		var death := DotPlayerDeath.from_dict(info)
		if death.direction == Vector3.ZERO and away != Vector3.ZERO:
			# An older server sent no direction: away from the killer is the honest guess.
			death.direction = away.normalized()
		var _fell := victim.fall_body(ragdolls, death)


## A kill in a solo game: the same fall a connected client draws from the KILL message, from
## the death [method ArenaGame.decide_death] put on the entry.
func _on_solo_kill(entry: DotKillFeed.Entry) -> void:
	if game == null or not String(entry.victim_key).is_valid_int():
		return
	if killcam != null and String(entry.killer_key).is_valid_int():
		killcam.note_kill(int(entry.killer_key), int(entry.victim_key), String(entry.cause), entry.headshot)
	var victim := game.player_for(int(entry.victim_key))
	if victim == null or victim == player:
		return
	var death: DotPlayerDeath = entry.get_meta(&"death", null)
	var _fell := victim.fall_body(ragdolls, death if death != null else DotPlayerDeath.new())


## The dead bodies' yard: the game's ragdoll rules, the world's collision layers, and the
## presentation's sound. Built once; cleared on a map change.
func _build_ragdolls() -> void:
	ragdolls = DotPlayerRagdolls.new()
	ragdolls.name = "Ragdolls"
	ragdolls.rules = game.ragdoll_rules
	var stack := game.player_stack
	if stack != null and stack.physics != null and stack.physics.layout != null:
		# The level is classified onto `world` (see `_classify_level`); props are on `prop`.
		game.ragdoll_rules.collision_mask = stack.physics.layout.mask_of([&"world", &"prop"])
	ragdolls.sound_fn = _ragdoll_sound
	add_child(ragdolls)
	# The map's toys are heard the same way: a bounce, a knock, a barrel's roll.
	if not game.toy_sound.is_connected(_ragdoll_sound):
		var _toys := game.toy_sound.connect(_ragdoll_sound)


## The level's layers: what the third-person and spectator cameras stop against.
func _level_mask() -> int:
	var stack := game.player_stack if game != null else null
	if stack != null and stack.physics != null and stack.physics.layout != null:
		return stack.physics.layout.mask_of([&"world", &"prop"])
	return 1


## The camera's two guards from dot-core, once a player is adopted.
##
## [b]The fade is what keeps a bot's face out of the lens.[/b] Players here are not in the
## physics space (their movement is a shape query and their hitboxes are analytic), so
## nothing stops one walking into another; the fade is handed the figures and hides any
## within a hand of the camera, and in third person fades one standing between the camera
## and the player. The third-person camera itself is swept by the player's probe against
## [method _level_mask].
func _guard_camera(p: ArenaPlayer) -> void:
	if p == null or p.camera == null:
		return
	p.third_person_mask = _level_mask()
	# Seen from behind, a player with no site avatar is the stock figure everybody else
	# already sees them as (the same document, from the same key), not a plain capsule.
	if p.avatar == null:
		p.rewear(ArenaAvatars.stock_avatar(StringName(ArenaGame.storage_key(p.player_id))))
	if p.camera.get_node_or_null(^"Fade") == null:
		var fade := DotCameraFade.new()
		fade.name = "Fade"
		fade.bodies_fn = _other_figures
		p.camera.add_child(fade)
	if not game.view_rules.changed.is_connected(_on_view_rules_changed):
		game.view_rules.changed.connect(_on_view_rules_changed)
	_set_third_person(game.view_rules.resolve(p.third_person))


## Everybody else's drawn figure, for the camera fade.
func _other_figures() -> Array:
	var out: Array = []
	if game == null:
		return out
	for id in game.player_ids():
		var other := game.player_for(id)
		if other != null and other != player and other.body_mesh != null:
			out.append(other.body_mesh)
	return out


## The view key: the other view if the server's `mp_forceview` allows it, a line if not.
func toggle_view() -> void:
	if player == null:
		return
	var wanted := game.view_rules.toggled(player.third_person)
	if wanted == player.third_person:
		if hud != null and game.view_rules.refusal() != "":
			hud.notice(game.view_rules.refusal())
		return
	_set_third_person(wanted)
	if hud != null:
		hud.notice("Third person" if wanted else "First person")


func _set_third_person(on: bool) -> void:
	if player == null:
		return
	player.third_person = on
	var fade := player.camera.get_node_or_null(^"Fade") as DotCameraFade if player.camera != null else null
	if fade != null:
		fade.focus = player.view if on else null


## The server changed `mp_forceview`: the view it now allows.
func _on_view_rules_changed() -> void:
	if player != null:
		_set_third_person(game.view_rules.resolve(player.third_person))


func _ragdoll_sound(id: StringName, at: Vector3, volume: float) -> void:
	if presentation != null and presentation.audio != null:
		var _played := presentation.audio.play_at(id, at, clampf(volume, 0.3, 1.0))


## The server confirmed this player's damage landed. The hit marker, the number and the
## sound; nothing about a hit is drawn from the client's own prediction of its shot.
func _on_hit(info: Dictionary) -> void:
	if hud == null:
		return
	var point: Vector3 = info.get("point", Vector3.ZERO)
	var victim := game.player_for(int(info.get("victim_id", 0))) if game != null else null
	# Near zero rather than zero: the wire quantises, and "no point" comes back as a few
	# millimetres off the origin.
	if point.length() < 0.05 and victim != null:
		# A hit with no point (world damage passed on): the chest of who took it.
		point = victim.global_position + Vector3(0.0, 1.3, 0.0)
	var lethal := bool(info.get("lethal", false))
	hud.note_hit(int(info.get("victim_id", 0)), float(info.get("amount", 0.0)), point, bool(info.get("headshot", false)), lethal)
	if presentation != null:
		presentation.on_hit_confirmed(lethal)
	_draw_body_hit(point)


## A kill's medals and points, as the server judged them. Every client hears every
## award; the HUD draws only the followed player's own and the nemesis line on their death.
func _on_award(info: Dictionary) -> void:
	if hud == null or game == null:
		return
	var own := player.player_id if player != null else 0
	var killer := game.player_for(int(info.get("killer_id", 0)))
	var victim := game.player_for(int(info.get("victim_id", 0)))
	hud.note_award(
		info, own,
		victim.display_name if victim != null else "?",
		killer.display_name if killer != null else "?"
	)
	if presentation != null and int(info.get("killer_id", 0)) == own and own != 0:
		presentation.on_medals(info.get("medals", []))


## The match ended: the final killcam if there is a kill to show, then the summary.
func _begin_match_end() -> void:
	if killcam == null:
		_reveal_winner()
	elif killcam.match_ended():
		DotLog.debug(CHANNEL, "the summary waits for the final killcam")


func _build_killcam() -> void:
	killcam = ArenaKillcam.new()
	killcam.name = "FinalKillcam"
	killcam.players_fn = func() -> Array: return game.players() if game != null else []
	killcam.player_for_fn = func(id: int) -> Variant: return game.player_for(id) if game != null else null
	killcam.seconds_fn = func() -> float: return game.rule("killcam") if game != null else 0.0
	killcam.weapon_name_fn = func(id: String) -> String:
		var def: DotWeaponDef = ArenaPlayer.weapon_catalogue().get_def(StringName(id)) if id != "" else null
		return def.display_name if def != null and def.display_name != "" else id.capitalize()
	killcam.over.connect(func(_skipped: bool) -> void: _reveal_winner())
	add_child(killcam)
	winner_reveal = DotWinnerReveal.new()
	winner_reveal.name = "WinnerReveal"
	winner_reveal.skip_actions = ArenaKillcam.SKIP_ACTIONS
	winner_reveal.finished.connect(_on_reveal_finished)
	add_child(winner_reveal)


func _in_match_end() -> bool:
	return game != null and game.match_node != null and game.match_node.state == DotMatch.State.MATCH_END


## The winner named and the top three on a podium, after the killcam and before the scoreboard.
func _reveal_winner() -> void:
	if not _in_match_end():
		return
	var ranked: Array = game.match_node.scoreboard.ranked() if game.match_node.scoreboard != null else []
	if winner_reveal == null or ranked.is_empty():
		_show_match_summary()
		return
	var entries: Array = []
	for row: DotPlayerScore in ranked.slice(0, 3):
		entries.append({"name": row.display_name, "score": "%d %s  %d %s" % [
			row.kills, "kill" if row.kills == 1 else "kills", row.deaths, "death" if row.deaths == 1 else "deaths"]})
	var team := game.mode != null and game.mode.is_team_mode()
	winner_reveal.reduced_motion = presentation != null and presentation.settings != null \
		and presentation.settings.get_bool(&"reduce_motion", false)
	var shown := winner_reveal.present(entries, {"title": "MATCH MVP" if team else "WINNER",
		"hint": "Jump or Fire to skip"})
	if not shown.ok:
		_show_match_summary()
		return
	for n: Variant in [hud, view_model]:
		if n is Object and is_instance_valid(n):
			_reveal_hid[n] = bool((n as Object).get(&"visible"))
			(n as Object).set(&"visible", false)


func _on_reveal_finished(_skipped: bool) -> void:
	for n: Variant in _reveal_hid:
		if is_instance_valid(n):
			(n as Object).set(&"visible", _reveal_hid[n])
	_reveal_hid.clear()
	if _in_match_end():
		_show_match_summary()


## Records the frame for the killcam, or draws the replay over it. Solo has no MATCH message,
## so the end of a solo match is seen here.
func _killcam_frame() -> void:
	if killcam == null or game == null:
		return
	killcam.hide_while_playing = [hud, view_model]
	killcam.frame()
	var now := int(game.match_node.state) if game.match_node != null else -1
	if _offline and now != _seen_match_state and now == DotMatch.State.MATCH_END:
		_begin_match_end()
	_seen_match_state = now


## The scoreboard up, and the MVP named: best score, then kills. Client side.
func _show_match_summary() -> void:
	var ranked := game.match_node.scoreboard.ranked() if game.match_node.scoreboard != null else []
	if hud != null and not ranked.is_empty():
		var best: DotPlayerScore = ranked[0]
		hud.notice("MVP: %s  -  %d kills, %d deaths, %d assists" % [
			best.display_name, best.kills, best.deaths, best.assists
		])
	if game_menu != null and not game_menu.any_open():
		game_menu.scoreboard.open()
		_summary_board_open = true


# --- Following the local player --------------------------------------------

## Follows a player: the camera, the HUD, and everything the keys act on.
func _watch(session_id: int) -> void:
	_watch_id = session_id
	_adopt(game.player_for(session_id))

## A player exists. Ours is one of them; the rest need something to be seen as.
##
## [b]`player_added`, not `player_spawned`.[/b] `player_spawned` comes out of
## dot-match's respawn queue, which runs on the AUTHORITY — a mirroring client never
## fires it, so a client waiting on it waits for ever. The symptom is precise and
## misleading: the HUD binds by id and works, the scoreboard works, the connection is
## live, and there is no camera and no world at all, because both hang off the
## reference this sets. Seen in a real browser against a real server; nothing headless
## could show it, because nothing headless has a camera to be missing.
func _on_player_added(added: ArenaPlayer) -> void:
	if added == null:
		return

	_hear_beacon(added)

	if player == null and added.player_id == _watch_id:
		_adopt(added)
		return

	# Offline this game ticks everybody, and nothing but a tick moves a bot's node: its body
	# is drawn between ticks by the player itself (`ArenaPlayer.interpolate_body`). A mirror's
	# node is moved once a frame by dot-net's interpolator instead.
	if added != player:
		added.interpolate_body = _offline

	if added != player and added.body_mesh == null:
		# A stock avatar until the server says otherwise. It is a real document over
		# the same schema and deterministic in the player's storage key, so a remote
		# player looks the same on every client that draws them — which is the whole
		# reason `stock_avatar` hashes an id rather than picking at random.
		# What the server said they look like, when it said; JOIN carries it.
		added.attach_body_mesh(
			Color.from_hsv(fmod(float(added.player_id) * 0.37, 1.0), 0.55, 0.85),
			added.avatar if added.avatar != null else ArenaAvatars.stock_avatar(
				StringName(ArenaGame.storage_key(added.player_id))
			)
		)


## Settings, audio, effects and the console.
func _build_presentation() -> void:
	presentation = ArenaPresentation.new()
	presentation.name = "Presentation"
	presentation.client = self
	add_child(presentation)
	DotLog.result(CHANNEL, "the presentation layer", presentation.setup())

	_wire_chat_window()

	presentation.settings.changed.connect(func(key: StringName, _v: Variant, _w: StringName) -> void:
		# The field of view is the one setting that has to reach something already built.
		# A camera that keeps the value it was created with is exactly the "produced
		# correctly and consumed by nothing" this family keeps finding.
		if key == &"field_of_view" and player != null:
			player.attach_camera(_field_of_view())
	)


func _adopt(candidate: ArenaPlayer) -> void:
	if candidate == null or player != null:
		return

	player = candidate
	_hear_beacon(player)
	# The player's own field of view, capped by whatever the server clamped it to. A
	# server capping it is a legitimate competitive rule; the player's *choice* is what is
	# saved, so leaving the server gives it back rather than editing their settings.
	player.attach_camera(_field_of_view())
	_guard_camera(player)
	if presentation != null:
		presentation.bind_camera_motion(player)
	_arm(player)

	if hud != null:
		hud.follow(player)
		if board != null:
			board.follow(str(player.player_id) if "player_id" in player else "")

	if _sampler != null:
		_sampler.tunables = player.controller.tunables
		# A different tunables object, carrying the default sensitivity again.
		if presentation != null:
			presentation.bind_look(_sampler.tunables)

		# [b]A spawn faces the way its mapper faced it, and the look is the sampler's.[/b]
		# `DotFpsController.teleport` turns the controller's OWN sampler, and this client
		# samples with its own — so every spawn's yaw was overwritten by the next command
		# and an offline player always started looking along -Z. On the built-in maps that
		# is a room; on an imported combat surf map it is the spawn room's back wall, three
		# metres away, which is what the first rendered frame showed. `spawned` fires where
		# the spawn is simulated: offline and on a listen server. A connected client's
		# respawn is the server's and does not fire it; [method _face_a_respawn] turns that
		# client's look instead, when its own snapshot shows the player alive again.
		player.spawned.connect(func(at: Transform3D) -> void:
			if _sampler != null:
				_sampler.look_at_angles(rad_to_deg(at.basis.get_euler().y), 0.0)
		)

	_hear_the_local_player()
	_restore_loadout.call_deferred()
	gate.freeze(player)

	# Logged because this is the moment everything a person can see comes into
	# existence — the camera, the HUD's subject and every key below the `player == null`
	# guard. When a client draws a world and shows a dead HUD, this line is what says
	# whether the local player was ever found; without it the two failures look
	# identical from a browser console.
	DotLog.info(CHANNEL, "following the local player", {
		"id": player.player_id,
		"name": player.display_name,
		"health": player.health.health if player.health != null else -1.0,
		"alive": player.is_alive(),
	})


func is_ready_to_show() -> bool:
	return gate != null and gate.is_open()


## What a shell draws once under its loading screen besides what is already in the tree:
## the meshes and materials of every weapon model the art table names, so the first time
## somebody draws a gun nobody has held yet is not also the first time its materials compile
## (in a browser, a stall of a few hundred milliseconds in the middle of a fight). Loading
## them here also fills `ZeeModelCache`, so the first equip does not read the file either.
## Collected here rather than with dot-core's `DotRenderWarmup.collect`: a pack runs on
## whatever dot-core its shell carries, and naming a class an older one lacks fails to parse.
func warm_up_items() -> Array:
	return gate.warm_items() if gate != null else []


func _weapon_warm_items() -> Array:
	var out: Array = []
	for path in ZeeWeaponArtTable.model_paths():
		var model := ZeeModelCache.instantiate(path)
		if model == null:
			continue
		var stack: Array[Node] = [model]
		while not stack.is_empty():
			var node: Node = stack.pop_back()
			stack.append_array(node.get_children())
			var mi := node as MeshInstance3D
			if mi == null or mi.mesh == null:
				continue
			if not out.has(mi.mesh):
				out.append(mi.mesh)
			for i in mi.mesh.get_surface_count():
				var m := mi.get_active_material(i)
				if m != null and not out.has(m):
					out.append(m)
		model.free()
	return out


## The hands under the camera, and the player's rig rebuilt to draw them.
##
## [b]With the authority only offline.[/b] Connected, the server's rig is the one whose
## shots land; this one predicts, animates the hands and draws the shot the moment the
## button goes down, which is the one piece of feedback a player judges the whole game's
## responsiveness by.
func _arm(body: ArenaPlayer) -> void:
	if body == null or body.camera == null or view_model != null:
		return

	view_model = ZeeViewModel.new()
	view_model.name = "Hands"
	view_model.feel_rules = game.feel_rules
	body.camera.add_child(view_model)
	body.arm_first_person(view_model, _offline)


## The hit drawn on the body the server says was hit: zee's red burst at [param point]. The
## presentation ray draws one already when it meets the victim's body here, and the rig's
## effects skip a second within a fifth of a second; this is for the hit the ray missed (a
## lag-compensated hit on a body that has since moved). Through `has_method`: an older
## shell's zee has no `play_body_hit`.
func _draw_body_hit(point: Vector3) -> void:
	if not weapon_draws_shots():
		return
	var fx: Object = player.weapons.call(&"shot_fx")
	if fx == null or not fx.has_method(&"play_body_hit"):
		return
	var from: Vector3 = player.global_position + Vector3(0.0, 1.6, 0.0)
	fx.call(&"play_body_hit", point, point - from)


## Whether the local weapon draws its own shot. True on a client shell carrying a
## zee-dot-weapons with `ZeeShotFx`; through `has_method`, because an older shell's copy
## of the rig has no `shot_fx` and a call by name would not compile there.
func weapon_draws_shots() -> bool:
	if player == null or player.weapons == null or not player.weapons.has_method(&"shot_fx"):
		return false

	return player.weapons.call(&"shot_fx") != null


## Whether E is the prop tool's key here: only in a mode where players use props. Anywhere
## else E is the launch, which is what most of the arena's modes want it for.
func props_on_e() -> bool:
	if game == null:
		return false
	# The mode the server says, not the one this client was built with: a client's own
	# `mode` is never replaced, and in Siege it read free-for-all and E launched.
	var shown := game.displayed_mode()
	return shown != null and shown.player_props


## Whether right mouse aims (the player's setting, on by default) rather than bashes.
func right_mouse_aims() -> bool:
	if presentation == null or presentation.settings == null:
		return true
	return bool(presentation.settings.get_value(&"right_mouse_aims"))


## The launch's action: the Launch row (E), or its own row (X) in a mode where the Launch
## key is the prop tool's grab.
func launch_action() -> StringName:
	return ArenaBindings.LAUNCH_PROPS if props_on_e() else ArenaBindings.LAUNCH


## Whether [param action] is held, and false for an action the InputMap does not have (a
## suite's client, built with no presentation, has applied no table).
static func _held(action: StringName) -> bool:
	return InputMap.has_action(action) and Input.is_action_pressed(action)


## Adds [param key] to [param action] if neither is missing and it is not bound already.
static func _add_key(action: StringName, key: Key) -> void:
	if action == &"" or not InputMap.has_action(action):
		return

	for existing in InputMap.action_get_events(action):
		if existing is InputEventKey and (existing as InputEventKey).physical_keycode == key:
			return

	var event := InputEventKey.new()
	event.physical_keycode = key
	InputMap.action_add_event(action, event)


# --- The loop --------------------------------------------------------------

func _physics_process(delta: float) -> void:
	var t := Time.get_ticks_usec()
	_physics_step(delta)
	ArenaFrameProbe.add(&"physics", t)


func _physics_step(delta: float) -> void:
	var move := _sampler.sample(delta) if _sampler != null else DotFpsCommand.new()
	if hud != null and presentation != null and presentation.bindings != null:
		hud.launch_key_text = presentation.bindings.key_for(launch_action())

	# The launch: the movement command's first user bit, which the motor reads when the
	# server's rules have the launch on. Same guard as the trigger, so typing in the chat
	# box does not throw anybody into the air.
	move.set_button(
		DotFpsCommand.BUTTON_USER_0, mouse_drives_view() and _held(launch_action())
	)
	if is_roaming():
		# The roaming spectator flies a camera and does not walk the dead player about.
		move.move = Vector2.ZERO
		move.buttons = 0
	_read_fire(move)

	if _offline:
		if game != null:
			_drive_bots()
			game.tick(_local_commands(move))
		return

	if net == null or not net.is_running() or bridge == null:
		return

	# The clock says how many ticks this frame is worth, which on a client whose engine
	# runs at the server's rate is almost always exactly one.
	var ticks := net.clock.advance(delta)

	# [b]Each pass is its own tick.[/b] `advance` has already moved the clock by all of
	# them, so `input_tick()` is the LAST one on every pass: a frame worth two ticks sent
	# the second twice and the first never, the server repeated a stale command for the
	# one it never got, and the predictor's replay stopped at the hole and drew the player
	# short of where they were -- after every hitch, and on every frame the display and
	# the tick rate do not line up. Arithmetic here rather than a new dot-net call,
	# because a pack has to run on whatever client shell the player already has.
	for i in range(ticks):
		if not net.clock.is_synced():
			continue

		var tick := net.clock.input_tick() - (ticks - 1 - i)
		bridge.client_tick(tick, move, _fire)

		if bridge.link != null:
			bridge.link.send_input(bridge.encode_input(tick, move, _fire))


func _local_commands(move: DotFpsCommand) -> Dictionary:
	var out: Dictionary = {}

	if player != null:
		out[player.player_id] = [move, _fire]

	for id in _bots:
		var bot: ArenaPlayer = _bots[id]
		out[int(id)] = [bot.get_meta("bot_move", DotFpsCommand.new()), bot.get_meta("bot_fire", DotWeaponCommand.new())]

	return out


## The offline bots: the brain a server's bots run (ArenaBots, dot-bot), with the same
## `bot_difficulty`. Offline only; a server's bots are the server's.
##
## [b]Not the test fixture any more.[/b] This used to face the nearest player through any
## wall and hold the trigger under 40 m -- `headless_match`'s aimbot -- and a first play test
## died twelve times in ninety seconds to it. See ArenaBots.
func _drive_bots() -> void:
	var tick := game.current_tick()
	for id in _bots:
		var bot: ArenaPlayer = _bots[id]

		# A tool or suite that stages a bot (tools/screenshot_weapons.gd, headless_feel)
		# writes its `bot_move` and `bot_fire` itself; driving it here as well would
		# overwrite them every tick.
		if bot.get_meta(&"bot_scripted", false):
			continue

		var mind: ArenaBots.Mind = _bot_minds.get(id)
		if mind == null:
			mind = ArenaBots.Mind.new()
			mind.seed = int(id)
			_bot_minds[id] = mind
		var made := ArenaBots.think(game, bot, mind, tick, float(game.tick_rate))
		bot.set_meta("bot_move", made[0])
		bot.set_meta("bot_fire", made[1])


## Adds or removes offline bots until there are [param count], named from dot-bot's pool.
func _keep_offline_bots(count: int) -> void:
	var taken: Array = []
	for p in game.players():
		taken.append(p.display_name)
	var ids: Array = _bots.keys()
	var _kept := _bot_roster.keep(count, ids, _add_offline_bot, _remove_offline_bot, taken)


func _add_offline_bot(bot_name: String) -> int:
	var id := _next_bot_id
	_next_bot_id += 1
	var bot := game.add_player(id, bot_name)
	if not bot.ok:
		return 0
	var body := bot.value as ArenaPlayer
	# A stock avatar, deterministic in the id, so an offline bot looks the same every launch
	# and different from the bot beside it.
	body.attach_body_mesh(
		Color.from_hsv(float(id - 100) / 6.0, 0.55, 0.85),
		ArenaAvatars.stock_avatar(StringName(ArenaGame.storage_key(body.player_id)))
	)
	_bots[body.player_id] = body
	return id


func _remove_offline_bot(id: int) -> void:
	_bots.erase(id)
	_bot_minds.erase(id)
	ArenaBots.forget(game, id)
	game.remove_player(id)


## How many bots a solo launch starts with: `-- --bots N`, else [member offline_bots].
func _launch_bots() -> int:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--bots")
	if index >= 0 and index + 1 < args.size() and args[index + 1].is_valid_int():
		return clampi(args[index + 1].to_int(), 0, 15)
	return offline_bots


## `bot_difficulty` and every `bot_*` setting at the solo console, the names a server has;
## `bot_quota` too, counted the server's way (people + bots). `-- --bot_difficulty hard` at
## launch picks the preset before the first bot thinks.
func _bind_bot_console() -> void:
	var settings := DotBotSettings.of(game)
	var args := OS.get_cmdline_user_args()
	var index := args.find("--bot_difficulty")
	if index >= 0 and index + 1 < args.size():
		DotLog.result(CHANNEL, "bot difficulty from the command line", settings.set_difficulty(args[index + 1]))
	elif presentation != null and presentation.settings != null:
		# The menu's saved pick (General, Solo bots), and again whenever it is changed there.
		DotLog.result(CHANNEL, "bot difficulty from the settings", settings.set_difficulty(presentation.settings.get_string(&"solo_bot_difficulty", "medium")))
	if presentation != null and presentation.settings != null and not presentation.settings.changed.is_connected(_on_solo_bot_setting):
		presentation.settings.changed.connect(_on_solo_bot_setting)

	if presentation == null or presentation.local_console == null:
		return
	var local := presentation.local_console
	var _bound := settings.bind_console(local)
	local.add_var(&"bot_quota", "Players in a solo match, you included; the rest are bots (0 to 16).",
		func() -> Variant: return _bots.size() + 1,
		func(v: Variant) -> Variant:
			var text := str(v).strip_edges()
			if not text.is_valid_int():
				return DotResult.fail(DotError.CODE_INVALID, "bot_quota takes a number")
			_keep_offline_bots(DotBotRoster.solo_wanted(clampi(text.to_int(), 0, 16)))
			return DotResult.success(_bots.size() + 1)
	)


## The menu's Bot difficulty (General, Solo bots) onto this match's bots, as it is changed.
## A method rather than a lambda, so the connection goes when the client does.
func _on_solo_bot_setting(key: StringName, value: Variant, _why: StringName) -> void:
	var settings := DotBotSettings.of(game) if game != null else null
	if key == &"solo_bot_difficulty" and settings != null and str(value) != settings.difficulty():
		DotLog.result(CHANNEL, "bot difficulty from the menu", settings.set_difficulty(str(value)))


## Whether the local player was alive last frame, for [method _face_a_respawn].
var _was_alive: bool = true


## A connected client's respawn faces the way its spawn faces.
##
## [b]Only the client can turn the view[/b]: the server teleports the player facing the spawn,
## then applies the next command, whose angles are this client's sampler's -- the look the
## mouse left before the death. Offline `spawned` does this (see [method _adopt]); a mirror
## never fires it, so a respawn is read where the spectate layer reads one, off the
## replicated health: dead last frame, alive now. The spawn is the map's own nearest one,
## which this client holds, rather than a yaw off the wire, because by the time the client
## sees the snapshot the server has already put this client's old angles back.
##
## A pit's teleport is not turned here: it runs inside the predicted tick, replays included,
## and a look turned on a replayed tick would snap a player's view back to the destination's
## yaw after they had moved the mouse.
func _face_a_respawn() -> void:
	if _offline or player == null or player.controller == null or _sampler == null or game == null:
		return

	var alive := player.is_alive()
	var came_back := alive and not _was_alive
	_was_alive = alive

	if not came_back or game.map == null:
		return

	var at := player.controller.state.position
	var nearest := INF
	var yaw := NAN

	for spawn: Transform3D in game.map.spawns:
		var d := spawn.origin.distance_to(at)
		if d < nearest:
			nearest = d
			yaw = rad_to_deg(spawn.basis.get_euler().y)

	if nearest < SPAWN_FACE_REACH:
		_sampler.look_at_angles(yaw, 0.0)


## How near a respawn has to land to a map spawn to take its yaw, in metres. The server
## puts a player exactly on one; anything further is somewhere else entirely.
const SPAWN_FACE_REACH := 2.0


func _process(delta: float) -> void:
	var t := Time.get_ticks_usec()
	_present_frame(delta)
	ArenaFrameProbe.add(&"present", t)
	ArenaFrameProbe.frame(delta, _probe_extra)


## The round trip and the input lead beside a frame report: a stalled frame shows up in
## both before it shows up anywhere else.
func _probe_extra() -> Dictionary:
	if net == null or _offline:
		return {"offline": true}
	var clock := net.clock.describe()
	return {
		"rtt_ms": int(net.stats.rtt_percentile(0.5)),
		"link_rtt_ms": int(ArenaNetBridge.link_rtt_ms(link)) if link != null else -1,
		"lead": net.clock.tick - net.clock.server_tick(),
		"snaps": clock.get("snaps", 0),
		"lost_ms": clock.get("lost_ms", 0),
	}


func _present_frame(delta: float) -> void:
	if net != null and not _offline:
		# Once a frame, and it is not optional: `DotNetInterpolator` blends two
		# snapshots perfectly and the result sits in a property nothing reads unless
		# this runs. Remote players otherwise step at the snapshot rate.
		var t := Time.get_ticks_usec()
		var replays := bridge.probe_replays_before() if bridge != null else -1
		net.interpolate_frame()
		if bridge != null:
			bridge.probe_replays_after(replays)
		ArenaFrameProbe.add(&"interpolate", t)

	# Where every speaker is, so a proximity voice comes from the player who said it.
	# The server already decided who hears whom by distance; playing the result from
	# nowhere in particular throws away the only thing that made the distance worth
	# computing.
	if extras != null:
		extras.pump_voice(delta)

	_fold_look()
	_fold_correction()
	_fold_alpha()

	# Your own body when you look down, if the server's `fp_body` rule is on.
	if player != null and game != null and player.controller != null:
		player.present_own_body(game.rule("fp_body") != 0.0,
			(player.view_now as Vector2).x if player.view_now != null else player.controller.state.yaw)

	_face_a_respawn()

	if presentation != null:
		# dot-audio culls by distance from the listener and dot-fx ages what it spawned;
		# neither ticks itself, for the reason everything tickable in this family is
		# explicit -- `_process` does not run while a tree is paused, and a pause menu is
		# exactly when nothing finishes.
		var eye := camera_position()
		var forward := Vector3.FORWARD
		if player != null and player.camera != null:
			forward = -player.camera.global_transform.basis.z
		presentation.present(delta, eye, forward)
		_apply_shake()
		presentation.keep_walkers(game.players())

	# A position report, once a second, for as long as the client has a player.
	#
	# [b]There is no other way to see where a browser client thinks it is.[/b] Every
	# assertion available runs headless and has no camera; a screenshot shows what was
	# drawn and not the number it was drawn from. When a client renders sky in every
	# direction, this is the line that says whether the player is somewhere wrong or
	# the world is somewhere wrong, and those have completely different fixes.
	_report_timer += delta

	if _report_timer >= 1.0 and player != null:
		_report_timer = 0.0
		var st := player.controller.state
		DotLog.info(CHANNEL, "where the local player is", {
			"position": st.position,
			"node": player.global_position,
			"camera": camera_position(),
			"yaw": st.yaw,
			"pitch": st.pitch,
			"grounded": st.is_grounded(),
			"predicted": _is_predicted(),
		})

	if game == null:
		return

	var t := Time.get_ticks_usec()
	for body in game.players():
		body.present(delta)
	ArenaFrameProbe.add(&"bodies", t)

	_watch_projectiles()

	_drive_spectator_camera()
	_killcam_frame()


## Hands the local player this frame's view, this frame's mouse motion folded in, so a
## frame on which no tick ran still turns. See [member ArenaPlayer.view_now].
##
## By name, with the state's angles as the fallback: a pack runs on whatever
## dot-player-controller the client shell carries, and one older than `look_now` draws
## exactly what it drew before. Not while the mouse is a pointer: nothing moves the view
## then, and the state's angles are the honest answer.
func _fold_look() -> void:
	if player == null:
		return
	if _sampler == null or not _sampler.has_method(&"look_now"):
		player.view_now = null
		return
	player.view_now = _sampler.call(&"look_now")


## Hands the local player what is left of its prediction corrections, so the eye eases
## across one rather than jumping with it. See [member ArenaPlayer.drawn_offset].
func _fold_correction() -> void:
	if player == null:
		return
	player.drawn_offset = Vector3.ZERO
	if _offline or net == null or net.predictor == null or bridge == null:
		return
	var mine := bridge.behaviour_for(player.player_id)
	if mine != null and mine.identity != null and mine.identity.is_predicted():
		player.drawn_offset = net.predictor.visual_offset(mine.identity.net_id)


## Hands the local player how far through the clock's current tick this frame is, which
## a connected client's ticks are counted on. See [member ArenaPlayer.drawn_alpha].
##
## By name: a pack runs on whatever dot-net the client shell carries, and one older than
## `render_alpha` draws at the engine's fraction, as before.
func _fold_alpha() -> void:
	if player == null:
		return
	player.drawn_alpha = NAN
	if _offline or net == null or net.clock == null or not net.clock.has_method(&"render_alpha"):
		return
	player.drawn_alpha = float(net.clock.call(&"render_alpha"))


## Points the drawing and the explosions at whichever projectile layer the game has now.
##
## Every frame and cheap, because a map change builds a new layer on the authority and a
## layer connected once at boot would go deaf after the first `changelevel`.
func _watch_projectiles() -> void:
	var layer: RefCounted = game.projectiles if game != null else null

	if projectile_view != null:
		projectile_view.projectiles = layer

	if layer == _heard_projectiles:
		return

	_heard_projectiles = layer

	if layer != null and not layer.detonated.is_connected(_on_detonated):
		layer.detonated.connect(_on_detonated)


func _on_detonated(at: Vector3, _spawn: DotWeaponSpawn) -> void:
	if presentation != null:
		presentation.on_explosion(at, camera_position())


## Where a dead player looks.
##
## [b]Until this existed the camera stayed where the body fell.[/b] That is the one
## thing a first-person game must not do: the corpse is on the floor, so the view is on
## the floor, and the seconds before a respawn are spent looking at a wall from ankle
## height. dot-spectate decides what to look at and the server decides whether it is
## allowed; this is the four lines that put the answer on the camera.
##
## Once a FRAME rather than once a tick, deliberately. A camera moved on the tick
## timeline steps at the tick rate however smoothly the thing it is following is
## interpolated — which is the jitter this family measured at 47% in g2gfast and spent
## a day on.
func _drive_spectator_camera() -> void:
	if game.spectate == null or player == null or player.camera == null:
		return

	var id := player.player_id

	if not game.spectate.is_spectating(id):
		if hud != null:
			hud.roam_hint = ""
		if not player.camera.current:
			player.camera.current = true
		return

	if hud != null:
		var roaming := game.spectate.is_roaming(id)
		hud.roam_hint = "Back to players" if roaming else ("Free camera" if game.spectate.can_roam(id) else "")

	# The chase and death cameras are pulled out of the level by dot-spectate, given it.
	var manager := game.spectate.manager
	if manager != null and manager.camera_world == null:
		manager.camera_world = player.camera.get_world_3d()
		manager.camera_mask = _level_mask()

	var where := game.spectate.camera_for(id)

	if game.spectate.is_roaming(id):
		where = _fly_free_camera(id, where)
	else:
		_free_cam = null

	if where == Transform3D.IDENTITY:
		return

	player.camera.global_transform = where


## The free-roam key: into a free camera while spectating, and back onto a player from it.
## A line when the server has roaming off (`mp_freeroam 0`) or a restricted camera
## (`mp_forcecamera`). Local: this game's client manager is authoritative over its own camera.
func toggle_roam() -> void:
	if game == null or game.spectate == null or player == null:
		return
	var id := player.player_id
	if not game.spectate.is_spectating(id):
		return
	var res := game.spectate.toggle_roam(id)
	if not res.ok:
		if hud != null:
			hud.notice("Free roam is off on this server.")
		return
	_free_cam = null
	_roam_look = Vector2.ZERO


func is_roaming() -> bool:
	return game != null and game.spectate != null and player != null \
		and game.spectate.is_roaming(player.player_id)


## One frame of the free camera: the mouse turn folded in, then the movement keys. Seeded from
## where the camera was on the first frame of a roam, so it starts where the spectator looked.
func _fly_free_camera(id: int, current: Transform3D) -> Transform3D:
	if _free_cam == null:
		_free_cam = DotSpectatorFreeCam.new()
		_free_cam.rules = game.spectate_rules
		_free_cam.seed_from(current)
	var tunables := player.controller.tunables if player.controller != null else null
	var sens := deg_to_rad(tunables.mouse_sensitivity) if tunables != null else 0.0025
	_free_cam.look(Vector2(-_roam_look.x, -_roam_look.y) * sens)
	_roam_look = Vector2.ZERO
	var move := Vector3(
		_strength(&"dot_fps_right") - _strength(&"dot_fps_left"),
		_strength(&"dot_fps_jump") - _strength(&"dot_fps_crouch"),
		_strength(&"dot_fps_forward") - _strength(&"dot_fps_back"),
	)
	if not mouse_drives_view():
		move = Vector3.ZERO
	var pose := _free_cam.step(move, _held(ArenaBindings.DASH), _held(ArenaBindings.WALK), get_process_delta_time())
	var _kept := game.spectate.manager.move_free(str(id), pose.origin, pose.basis)
	return pose


static func _strength(action: StringName) -> float:
	return Input.get_action_strength(action) if InputMap.has_action(action) else 0.0


## The fire command, from the keyboard and the mouse.
##
## [b]`DotWeaponCommand` is a button BITMASK, not a set of booleans.[/b] `set_button`
## is the accessor; assigning `.attack` creates nothing and errors at runtime with
## "Invalid assignment of property or key 'attack'". Also the aim, which is read from
## the movement command's angles rather than sampled again — sampling the mouse twice
## gives a shot that leaves at a different angle than the player was looking along.
func _read_fire(move: DotFpsCommand) -> void:
	var firing := mouse_drives_view() and _held(ArenaBindings.FIRE)

	_fire.set_button(DotWeaponCommand.BUTTON_ATTACK, firing)
	# The Aim key (right mouse) aims down the sights, by default; the Bash key (F) is the
	# pack's alt-fire ("quick melee"). A player who would rather bash with the Aim key turns
	# the `right_mouse_aims` setting off. Same guard as the trigger, so a right click on a
	# menu neither zooms nor swings a rifle butt. In a mode where the Bash key is the prop
	# tool's freeze, the bash is the Aim key's whatever the setting says.
	var right := mouse_drives_view() and _held(ArenaBindings.AIM)
	var aims := right_mouse_aims() and not props_on_e()
	var bash := (right and not aims) or (
		not props_on_e() and mouse_drives_view() and _held(ArenaBindings.BASH)
	)
	_fire.set_button(DotWeaponCommand.BUTTON_ALT, bash)
	if player != null:
		player.aim_held = right and aims
	# On the wire as well, for the server's No Scope medal; nothing simulated reads it.
	_fire.set_button(ArenaPlayer.BUTTON_AIM, right and aims)
	_fire.set_button(DotWeaponCommand.BUTTON_RELOAD, mouse_drives_view() and _held(ArenaBindings.RELOAD))
	_note_held_slot()
	_fire.yaw = move.yaw
	_fire.pitch = move.pitch

	# `DotArsenal` reads `command.slot > 0` as "switch to this" and 0 as "leave it
	# alone", so this is a REQUEST that is cleared once made rather than a mirror of
	# the current slot. Reading the arsenal back into the command instead would make
	# every tick a switch to the weapon already held, and `select()` refuses that — so
	# it would have looked like it worked while doing nothing.
	_fire.slot = _wanted_slot
	_wanted_slot = 0


## Remembers the slot before the one in hand, for Q.
func _note_held_slot() -> void:
	if player == null or player.arsenal == null:
		return

	var now := player.arsenal.current_slot()

	if now != _held_slot:
		if _held_slot > 0:
			_last_slot = _held_slot
		_held_slot = now


## The carried slot [param step] places along from the one in hand, wrapping. For the
## wheel. 0 when there is nothing else to go to.
func _cycled_slot(step: int) -> int:
	if player == null or player.arsenal == null:
		return 0

	var carried := player.arsenal.slots()

	if carried.size() < 2:
		return 0

	var at := carried.find(player.arsenal.current_slot())
	return carried[posmod(at + step, carried.size())]


# --- The mouse -------------------------------------------------------------

## Asks a browser for the cursor rather than telling it.
##
## Pointer lock needs **transient user activation** — a real click — and `_ready()` is
## the one moment guaranteed not to have one. A browser refuses it *silently*:
## `Input.mouse_mode` reads back as CAPTURED, the view still turns, and the cursor sits
## on top of the game and wanders out of the window.
func _grab_mouse() -> void:
	if not DotPlatform.is_web():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_awaiting_click = true

	if hud != null:
		hud.notice("Click to play")



## Puts the drawn level on the layout's `world` layer.
##
## A client draws the level and that is what puts it in the physics space, so the client
## is where its collision layers have to be set — and they have to be the SAME numbers the
## server used, which is why the layout is built on every instance rather than only where
## `apply_physics` is on. See `ArenaPlayerStack._build_physics`.
func _classify_level() -> void:
	if _level == null or game == null or game.player_stack == null:
		return

	var done := game.player_stack.classify_tree(_level, &"world")
	DotLog.debug(CHANNEL, "level classified", {"bodies": done})


## Set by a headless suite to answer [method mouse_drives_view] without a display
## server. Left null in play, where the real mouse mode is the only honest answer.
var mouse_capture_override: Variant = null


## Whether the pointer is currently the player's aim rather than a pointer.
##
## [b]Only while the cursor is actually captured.[/b] Escape releases it, and on the web
## [member _awaiting_click] leaves it released before the first click — in both states
## the pointer is a pointer, so spending its motion on the view turns the player away
## from the "Click to play" notice they are being asked to click, and a click on a menu
## would fire the rifle. Both the look and the trigger ask here.
##
## [b]A method with an override rather than a read of `Input.mouse_mode` at the call
## site, because that read cannot be tested.[/b] The dummy display server pins the mode
## to `MOUSE_MODE_VISIBLE` and drops every write to it without erroring, so no headless
## suite could put a client into the state a player plays in: the guard this game had
## from the start had never once been exercised, in either direction.
## `headless_presentation` drives it both ways now. Same shape as game-g2gfast's and
## game-playground's.
func mouse_drives_view() -> bool:
	if mouse_capture_override != null:
		return bool(mouse_capture_override)

	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	# [b]The console first, and before the click that captures the mouse.[/b] Without it,
	# a click inside an open console grabs pointer lock and the next keystroke goes to
	# movement -- so typing `noclip` walks the player forward, which is the single most
	# reported bug in every game that ships a console and forgets this line.
	if presentation != null and presentation.swallows_input():
		return

	# Before the `player == null` guard, deliberately. A browser player clicks while
	# the world is still loading more often than not, and a click swallowed for want of
	# a player is a click that never captures anything — after which the only
	# affordance the game offers is one it has already ignored.
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not _menu_open():
			_awaiting_click = false
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

			if hud != null:
				hud.notice("")

			return

	# The menu is up: every key is its own (dot-menu closes on Escape), and nothing below
	# may act on the world behind it.
	if _menu_open():
		return

	if event.is_action_pressed(&"ui_cancel"):
		# Escape RELEASES and does not toggle. Escape is how a browser itself exits
		# pointer lock, and it then refuses to re-enter for about a second — so a
		# toggle bound to it silently does nothing every other press on the web. One
		# key that releases and one gesture that captures is the same contract on
		# every platform.
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			if hud != null:
				hud.notice("Click to play. Escape again for the menu.")
		elif game_menu != null:
			game_menu.open()
		return

	if player == null:
		return

	if event is InputEventMouseMotion:
		if mouse_drives_view():
			if is_roaming():
				# The free camera turns on the mouse, and the dead body's view stays put.
				_roam_look += (event as InputEventMouseMotion).relative
			elif _sampler != null:
				_sampler.handle_event(event)
		return

	# A talk key's release is read wherever the pointer is: push to talk may be on a mouse
	# button, and a release dropped below is a microphone that never closes.
	if _is(event, ArenaBindings.VOICE) and not event.is_pressed():
		if extras != null:
			extras.set_talking(false)
		return

	# A mouse button reaching here with the pointer released is aimed at a menu or at
	# "Click to play" (the click that captures returned above); it acts on nothing.
	if event is InputEventMouseButton and not mouse_drives_view():
		return

	if not (event is InputEventKey or event is InputEventMouseButton):
		return

	if event is InputEventKey and event.is_echo():
		return

	# Every key below is read through its action in `ArenaBindings`, so the Controls page
	# moves it. Push to talk first, BEFORE the "is this a press" filter, because a talk key
	# needs the release as much as the press: a key whose release nobody reads is a
	# microphone that never closes.
	if _is(event, ArenaBindings.VOICE):
		if extras != null:
			extras.set_talking(event.is_pressed())
		return

	if not event.is_pressed():
		return

	# In a mode where players use props the Launch key is the prop tool's grab and the Bash
	# key its freeze (the launch moves to its own key, `launch_action`).
	if props_on_e() and _is(event, ArenaBindings.LAUNCH):
		# Grab, or let go of what is already held. One key for both, because a player who
		# has to remember which of two keys they pressed last is a player holding a crate
		# they cannot put down.
		_ask_prop(
			ArenaEvents.PropAct.RELEASE if _holding
			else ArenaEvents.PropAct.GRAB
		)
		_holding = not _holding
		return
	if props_on_e() and _is(event, ArenaBindings.BASH):
		_ask_prop(ArenaEvents.PropAct.FREEZE)
		return
	if _is(event, ArenaBindings.PUNT):
		_ask_prop(ArenaEvents.PropAct.PUNT)
		_holding = false
		return
	if _is(event, ArenaBindings.VIEW):
		toggle_view()
		return
	if _is(event, ArenaBindings.ROAM):
		toggle_roam()
		return

	# The slots: requested through the COMMAND, never by calling the arsenal directly. A
	# client that switched its own weapon would be predicting a switch the server never
	# simulated, and the next snapshot would take it back. Five keys for the pack's five
	# slots: melee, sidearm, primary, heavy, throwable.
	for i in range(ArenaBindings.SLOTS.size()):
		if _is(event, ArenaBindings.SLOTS[i]):
			_wanted_slot = i + 1
			return
	# The wheel walks the carried slots, by the same request.
	if _is(event, ArenaBindings.WEAPON_PREVIOUS):
		_wanted_slot = _cycled_slot(-1)
	elif _is(event, ArenaBindings.WEAPON_NEXT):
		_wanted_slot = _cycled_slot(1)
	elif _is(event, ArenaBindings.WEAPON_LAST):
		# The last weapon, which is the switch players make most.
		_wanted_slot = _last_slot


## Whether [param event] is on [param action], pressed or released. False for an action the
## InputMap does not have, which `InputEvent.is_action` reports as an error.
static func _is(event: InputEvent, action: StringName) -> bool:
	return InputMap.has_action(action) and event.is_action(action)


## The cursor, from one place.
##
## A screen that wants the mouse gets it; otherwise the game does, subject to the
## browser having been clicked at least once.
func _apply_mouse() -> void:
	if _menu_open():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return

	if _awaiting_click:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Connects the local player's own noises and pictures.
##
## [b]Only the local player's.[/b] Somebody else being hurt is their business: a damage
## tint for every player in the match would be a screen that is permanently red, and a
## shake for somebody else's rifle would make a crowded room unplayable. What everybody
## hears is the positional half -- the shot, the impact -- which comes from the world.
func _hear_the_local_player() -> void:
	if presentation == null or player == null:
		return

	presentation.on_spawned()

	if player.health != null and not player.health.damaged.is_connected(_on_local_damaged):
		player.health.damaged.connect(_on_local_damaged)
		player.health.died.connect(_on_local_died)

	# The wall moves, predicted like the shot below and for the same reason: a sound never
	# changes the simulation. The controller does not emit either during a replay, so a
	# corrected tick is never heard twice.
	var controller := player.controller
	if controller != null and not controller.wall_run_changed.is_connected(_on_local_wall_run):
		controller.wall_run_changed.connect(_on_local_wall_run)
		controller.wall_jumped.connect(_on_local_wall_jumped)

	if not player.used.is_connected(_on_local_used):
		# The PREDICTED use, on the client that made it. Waiting for the server's
		# confirmation would put the bang a round trip after the click, which is the one
		# piece of feedback a player judges the whole game's responsiveness by -- and it
		# is safe to predict for exactly the reason dot-fx is built the way it is: a sound
		# never changes the simulation, so a shot the server later refuses cost a noise.
		#
		# ArenaPlayer.used rather than arsenal.used, because ArenaPlayer already forwards
		# it and is the one node this client is handed. Going through the arsenal means
		# reaching two levels into somebody else's addon for a signal the player above it
		# re-emits unchanged.
		player.used.connect(_on_local_used)


## Plays a beacon's ping wherever its ripple goes out, for [param body] — every player,
## this client's own included: somebody who has been beaconed should hear it too.
##
## From both [method _on_player_added] and [method _adopt], because a player found by
## `_watch` is adopted without passing through the first, and the connection is guarded so
## the two never make it twice.
func _hear_beacon(body: ArenaPlayer) -> void:
	if body == null or body.beacon_pulsed.is_connected(_on_beacon_pulsed):
		return

	body.beacon_pulsed.connect(_on_beacon_pulsed)


func _on_beacon_pulsed(at: Vector3) -> void:
	if presentation != null:
		var _voice := presentation.on_beacon(at)


## One tick of weapon use, predicted. An outcome rather than a shot, because a use is
## not always one: a rocket produces a spawn and no shot at all, and a burst produces
## several shots that are all one trigger pull.
func _on_local_used(outcome: DotWeaponOutcome) -> void:
	if presentation == null or outcome == null or not outcome.used:
		return

	presentation.on_used(outcome, weapon_draws_shots())


func _on_local_wall_run(running: bool) -> void:
	if presentation != null:
		var _voice := presentation.on_wall_run(running)


func _on_local_wall_jumped() -> void:
	if presentation != null:
		var _voice := presentation.on_wall_jumped()


func _on_local_damaged(damage: DotDamage) -> void:
	if presentation != null:
		presentation.on_hurt(damage.amount)


func _on_local_died(_damage: DotDamage) -> void:
	if presentation == null or player == null:
		return
	var where := Transform3D.IDENTITY
	where.origin = player.global_position
	presentation.on_died(where)


## Adds the frame's camera shake. dot-fx computes it; this is the only thing that applies it.
##
## Same rule as dot-spectate's camera: one implementation then serves the play rig, a
## spectator's and a headless suite, with no second code path to keep in step.
func _apply_shake() -> void:
	if player == null or player.camera == null or presentation == null:
		return
	# Handed to the player rather than written onto the camera. `ArenaPlayer.present` is
	# the one place the camera's transform is set -- it says so in its own comment -- and a
	# second writer would fight it every frame for the same value.
	player.camera_offset = presentation.camera_shake()
	player.camera_roll = presentation.camera_roll()


## The field of view to use: the player's own, under any cap a server has applied.
func _field_of_view() -> float:
	if presentation == null:
		return FIELD_OF_VIEW
	return float(presentation.settings.get_int(&"field_of_view", int(FIELD_OF_VIEW)))


## Where this client thinks it is, as one line. What the console's `where` prints.
func describe_position() -> PackedStringArray:
	if player == null:
		return PackedStringArray(["no local player yet"])
	var st := player.controller.state
	return PackedStringArray([
		"position %s" % st.position,
		"node     %s" % player.global_position,
		"camera   %s" % camera_position(),
		"yaw %.1f  pitch %.1f  grounded %s" % [st.yaw, st.pitch, st.grounded],
	])


## Where the camera actually is, or the origin when there is none.
func camera_position() -> Vector3:
	return player.camera.global_position if player != null and player.camera != null \
		else Vector3.ZERO


## Whether the local player is dot-net's idea of a predicted entity.
##
## Not the same question as "is it ours". `DotNetIdentity.is_predicted` also requires
## the authority to be SHARED and the owner peer id to match this manager's local one —
## and a client whose local peer id does not match what the server addressed it as gets
## an entity that is neither predicted nor interpolated, which nothing then moves.
func _is_predicted() -> bool:
	if bridge == null or player == null:
		return false

	var behaviour := bridge.behaviour_for(player.player_id)

	return behaviour != null \
		and behaviour.identity != null \
		and behaviour.identity.is_predicted()


func describe() -> Dictionary:
	return {
		"offline": _offline,
		"player": player.player_id if player != null else -1,
		"watching": _watch_id,
		"bots": _bots.size(),
		"net": bridge.describe() if bridge != null else "none",
	}


## Where a roster row's player stands, for dot-game's look-to-gag key (J, K).
func _look_position(row: Dictionary) -> Variant:
	if game == null:
		return null
	for who: ArenaPlayer in game.players():
		if who != player and who.display_name == row["name"]:
			return who.global_position + Vector3.UP * 1.5
	return null
