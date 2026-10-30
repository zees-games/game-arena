extends "arena_client_state.gd"

const KillPovView := preload("arena_kill_pov_view.gd")
## Helpers of [ArenaClient] that touch only its state, split out so the client file stays under the size gate.


## The figure an avatar action plays on: that peer's player, or the local one offline.
func _avatar_figure(peer_id: int) -> Object:
	var who: ArenaPlayer = null
	if bridge != null and peer_id != 0:
		who = game.player_for(bridge.session_for_peer(peer_id))
	if who == null and player != null and (net == null or peer_id == net.local_peer_id):
		who = player
	return who.figure if who != null else null


func _exit_tree() -> void:
	# A static outlives this game: the next one a shell loads must not look for its art
	# under this game's mount.
	ZeeModelCache.set_asset_root("res://")
	ArenaWeaponSkins.clear()


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
## Older zee_weapons shells lack it; the sprite is the fallback.
const WEAPON_PREVIEW_SCRIPT := "res://addons/zee_weapons/view/zee_weapon_preview.gd"
var _weapon_table: Dictionary = {}
var _previews: Node = null


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
		# Items the player does not own, greyed with a store button, solo and connected.
		if DotAddonApi.build_level("dot_game") >= 40:
			platform.add_loadout_store(loadout_menu, func() -> Object: return game.loadout_command if game != null else null,
					func() -> String: return ArenaGame.storage_key(player.player_id) if player != null else "")
		loadout_menu.set(&"random_fn", random_loadout)
		loadout_menu.set(&"random_spawn_fn", random_spawn_loadout)
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


## Solo: rolls a random loadout under the same `mp_loadout_random*` rules the server applies.
func random_loadout() -> Variant:
	if game == null or game.loadout_command == null or player == null:
		return DotResult.fail(DotError.CODE_STATE, "Join the match first.")
	return await game.loadout_command.call(&"choose_random", null, ArenaGame.storage_key(player.player_id))


## Solo: the "random every spawn" toggle, under the same `mp_loadout_random_on_spawn` rule.
func random_spawn_loadout(on: bool) -> Variant:
	if game == null or game.loadout_command == null or player == null:
		return DotResult.fail(DotError.CODE_STATE, "Join the match first.")
	return await game.loadout_command.call(&"set_random_spawn", ArenaGame.storage_key(player.player_id), on)


## A card's picture (the HUD's rendered weapon silhouettes) and numbers (zee's cards).
func decorate_loadout_choice(_slot_id: String, choice: Dictionary) -> Dictionary:
	var id := StringName(str(choice.get("id", "")))
	var out: Dictionary = {}
	if _previews == null and ResourceLoader.exists(WEAPON_PREVIEW_SCRIPT):
		_previews = (load(WEAPON_PREVIEW_SCRIPT) as GDScript).new()
		_previews.name = "WeaponPreviews"
		add_child(_previews)
	var icon: Texture2D = _previews.texture(id) if _previews != null else null
	if icon == null:
		icon = ArenaWeaponIcons.shared.menu_texture(id)
	if icon == null:
		icon = ArenaHudGlance.Ink.weapon_icon(id)
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


## Solo: the same cfg/ layers as a server (lenient here), so shipped defaults and a yml reach a
## solo game; the noblock rules come from their own layers.
func _load_solo_config() -> void:
	_solo_binder = ArenaConfig.make_binder(game.config, "user://cfg/arena.json")
	DotLog.result(CHANNEL, "solo config", _solo_binder.load_layers())
	game.config_binder = _solo_binder
	DotLog.result(CHANNEL, "solo noblock", game.make_noblock())


func _say_ready() -> void:
	if _workbench_remote != null:
		_workbench_remote.ask()
	if bridge != null:
		bridge.send_request(ArenaEvents.Ask.READY)


## A chat line, on the HUD's notice line.
##
## The HUD is the whole chat window this game has, which is a level of ambition rather
## than an oversight: a scrolling window with an input field is a screen, and a screen
## is [DotScreenStack]'s. [DotChatClient] is holding the history the moment somebody
## writes one.
# --- Chat ------------------------------------------------------------------


## Something other than the cover has the keyboard or the screen.
func _input_busy() -> bool:
	return _workbench_open or (presentation != null and presentation.swallows_input()) \
		or (game_menu != null and game_menu.any_open())


## Movement stops while anything has the keyboard or the screen: the cover, the chat box,
## the console, or dot-menu's menu ([member platform]'s [code]busy_fn[/code] says which). Only
## when none does is it given back, so the console closing while the chat box is still open
## does not walk the player.
func _suspend_input(blocked: bool) -> void:
	if _sampler != null:
		_sampler.suspended = blocked


## Whether the menu, its help, the console, the workbench or a ballot in pointer mode is up, in which case the mouse is a pointer.
func _menu_open() -> bool:
	return _workbench_open or game_menu != null and game_menu.any_open() or _pointer_modal_up()


## A `dot_pointer_modal` node (dot-ui's ballot) that has freed the mouse; a click must not recapture it.
func _pointer_modal_up() -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return false
	for node in tree.get_nodes_in_group(&"dot_pointer_modal"):
		if node.has_method(&"is_pointer_mode") and bool(node.call(&"is_pointer_mode")):
			return true
	return false


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
		var _fell := victim.fall_body(ragdolls, death, not game.drops_weapon_on_death())


## A kill in a solo game: the same fall a connected client draws from the KILL message, from
## the death [method ArenaGame.decide_death] put on the entry.
func _on_solo_kill(entry: DotKillFeed.Entry) -> void:
	if game == null or not String(entry.victim_key).is_valid_int():
		return
	if killcam != null and String(entry.killer_key).is_valid_int():
		killcam.note_kill(int(entry.killer_key), int(entry.victim_key), String(entry.cause), entry.headshot)
	if solo_killview != null and String(entry.killer_key).is_valid_int():
		var named := game.player_for(int(entry.killer_key))
		var noted := solo_killview.note_kill(int(entry.killer_key), int(entry.victim_key), float(game.current_tick()) / float(game.tick_rate), {
			"killer": named.display_name if named != null else "", "weapon": String(entry.cause)})
		if not noted.ok:
			DotLog.trace(CHANNEL, "no kill view", {"why": noted.error.message})
	var victim := game.player_for(int(entry.victim_key))
	if victim == null or victim == player:
		return
	var death: DotPlayerDeath = entry.get_meta(&"death", null)
	var _fell := victim.fall_body(ragdolls, death if death != null else DotPlayerDeath.new(), not game.drops_weapon_on_death())
