extends "arena_client_part1.gd"

## The load gate's give-up time in a browser (DotLoadGate's default is 20 s); see setup's use.
const WEB_GATE_TIMEOUT_SEC := 60.0
## The cover's render warm-up: milliseconds a round's frame may cost, the bare load frame included; see setup's use.
const GATE_WARM_BUDGET_MSEC := 100.0
## A drawing client's share of a frame for the server's events; the join backlog spreads over frames.
const EVENT_BUDGET_USEC := 8000

## Set by an offline start that builds in frames: [method _adopt] leaves the arming (and the loadout
## restore, which equips into the armed rig) to it, so the arming gets frames of its own.
var _arm_after_adopt := false

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
	if not _arm_after_adopt:
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
		# `DotFpsController.teleport` turns the controller's OWN sampler, and this client samples
		# with its own.
		player.spawned.connect(func(at: Transform3D) -> void:
			if _sampler != null:
				_sampler.look_at_angles(rad_to_deg(at.basis.get_euler().y), 0.0)
		)

	_hear_the_local_player()
	if not _arm_after_adopt:
		_restore_loadout.call_deferred()
	gate.freeze(player)

	# Logged because this is the moment everything a person can see comes into existence — the
	# camera, the HUD's subject and every key below the `player == null` guard.
	DotLog.info(CHANNEL, "following the local player", {
		"id": player.player_id,
		"name": player.display_name,
		"health": player.health.health if player.health != null else -1.0,
		"alive": player.is_alive(),
	})

# --- Following the local player --------------------------------------------

## Follows a player: the camera, the HUD, and everything the keys act on.
func _watch(session_id: int) -> void:
	_watch_id = session_id
	_adopt(game.player_for(session_id))

func _on_hello(info: Dictionary) -> void:
	_watch(int(info["session_id"]))

	if hud != null:
		hud.notice("Connected to %s" % String(info["map_name"]))

func _in_match_end() -> bool:
	return game != null and game.match_node != null and game.match_node.state == DotMatch.State.MATCH_END

## The scoreboard up, and the MVP named: best score, then kills. Client side.
func _show_match_summary() -> void:
	var ranked := game.match_node.scoreboard.ranked() if game.match_node.scoreboard != null else []
	if hud != null and not ranked.is_empty():
		var best: DotPlayerScore = ranked[0]
		hud.notice(ArenaMatchText.mvp_notice(best))
	if game_menu != null and not game_menu.any_open():
		game_menu.scoreboard.open()
		_summary_board_open = true

func _on_reveal_finished(_skipped: bool) -> void:
	for n: Variant in _reveal_hid:
		if is_instance_valid(n):
			(n as Object).set(&"visible", _reveal_hid[n])
	_reveal_hid.clear()
	if _in_match_end():
		_show_match_summary()

## The podium is built at the first match end, not at start: about 22 nodes nobody sees before then.
func _ensure_winner_reveal() -> void:
	if winner_reveal != null:
		return
	winner_reveal = DotWinnerReveal.new()
	winner_reveal.name = "WinnerReveal"
	winner_reveal.skip_actions = ArenaKillcamBodies.SKIP_ACTIONS
	if not winner_reveal.finished.is_connected(_on_reveal_finished):
		winner_reveal.finished.connect(_on_reveal_finished)
	add_child(winner_reveal)

## The winner named and the top three on a podium, after the killcam and before the scoreboard.
func _reveal_winner() -> void:
	if not _in_match_end():
		return
	var ranked: Array = game.match_node.scoreboard.ranked() if game.match_node.scoreboard != null else []
	if ranked.is_empty():
		_show_match_summary()
		return
	# Without a killcam there is no podium to build: a bare client keeps the summary notice.
	if killcam != null:
		_ensure_winner_reveal()
	if winner_reveal == null:
		_show_match_summary()
		return
	var entries := ArenaMatchText.reveal_entries(ranked)
	var team := game.mode != null and game.mode.is_team_mode()
	winner_reveal.reduced_motion = presentation != null and presentation.settings != null \
		and presentation.settings.get_bool(&"reduce_motion", false)
	var shown := winner_reveal.present(entries, {"title": "MATCH MVP" if team else "WINNER",
		"hint": "Jump or Fire to skip"})
	if not shown.ok:
		_show_match_summary()
		return
	for n: Variant in [hud, view_model]:
		if n is Object and is_instance_valid(n) and not _reveal_hid.has(n):
			_reveal_hid[n] = bool((n as Object).get(&"visible"))
			(n as Object).set(&"visible", false)

## The match ended: the final killcam if there is a kill to show, then the summary.
func _begin_match_end() -> void:
	if killcam == null:
		_reveal_winner()
	elif killcam.match_ended():
		DotLog.debug(CHANNEL, "the summary waits for the final killcam")

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

# --- Offline ---------------------------------------------------------------

func _build_netcode() -> DotResult:
	# The server's `mp_teammate_passthrough` through the link (ArenaGame.follow_server_cvars).
	if link != null:
		var _following := game.follow_server_cvars(link)
		platform.map_config_game = "game-arena"
		DotLog.result(CHANNEL, "noblock", platform.add_noblock(game, Callable(game, "block_side")))
		game.noblock = platform.noblock

	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.local_peer_id = multiplayer.get_unique_id() if multiplayer != null else 2
	net.auto_tick = false
	net.config_file = ""

	var config := _client_net_config()
	net.config = config
	add_child(net)
	var started := net.setup()
	if not started.ok:
		return started
	ArenaLoadTimeline.mark("netcode: manager set up")

	bridge = ArenaNetBridge.new()
	bridge.name = "Bridge"
	if _builds_in_frames():
		bridge.event_budget_usec = EVENT_BUDGET_USEC
	add_child(bridge)

	var attached := bridge.attach(game, net)
	if not attached.ok:
		return attached
	ArenaLoadTimeline.mark("netcode: bridge attached")

	# Under the link, and NAMED the same as the server's — the name is the routing.
	bridge.open_link(link)
	# Before the seal and in the server's order (after the bridge), or the actions stay local.
	DotLog.result(CHANNEL, "avatar action message", DotGameAvatarActionMessage.register(net))
	# The server's order again (after the avatar frame): the remote workbench's frame and the profile rows.
	_workbench_remote = DotGameWorkbenchRemoteClient.attach(net)
	_profile_runtime = DotProfileRuntime.new()
	_profile_link = DotNetProfileLink.attach(net, _profile_runtime)
	net.messages.seal()
	ArenaLoadTimeline.mark("netcode: messages sealed")

	# The client halves, built here because each needs the bridge.
	extras = ArenaClientExtras.new()
	extras.name = "Extras"
	add_child(extras)

	var extra := extras.attach(bridge, game)
	DotLog.result(CHANNEL, "the client's chat, voice and map layers", extra)
	ArenaLoadTimeline.mark("netcode: extras attached")
	_install_profiler_context()
	platform.look_voice = extras.voice
	platform.look_chat = extras.chat
	platform.look_gag_action = ArenaBindings.VOICE_GAG
	platform.look_mute_action = ArenaBindings.VOICE_MUTE
	platform.look_position_fn = _look_position
	platform.build_look_mute()

	# A map that cannot be had must not leave the cover up forever: let the hold go.
	if extras.maps != null:
		extras.maps.fetch_failed.connect(func(_map: DotMapDef, _error: DotError) -> void:
			gate.release(&"map"))
		extras.maps.change_aborted.connect(func(_id: StringName, _reason: String) -> void:
			gate.release(&"map"))
	elif _level_map == null and not _level_busy:
		# No map sync, so no announcement will draw the level: draw the one the game was set up on.
		_enter_level.call(true)
	else:
		gate.release(&"map")

	extras.said.connect(_on_said)
	# What the server says is carrying chat decides whether the box is drawn when the setting is `auto`.
	extras.chat_relay_changed.connect(func(relayed: bool) -> void:
		if presentation != null:
			presentation.set_chat_relayed(relayed)
	)

	# Chat arrives on `DotClientLink.chat_received`, not on anything dot-chat owns; unconnected
	# the client's DotChatClient is a history nothing feeds.
	if link != null and link.has_signal("chat_received"):
		link.connect("chat_received", extras.receive_wire)
	extras.map_changing.connect(_on_map_changing)
	extras.map_changed.connect(_on_map_changed)

	_connect_bridge_events()

	# The one thing that writes an RTT sample: without it the input lead omits flight time
	# and past ~30 ms every command arrives late.
	if link != null:
		bridge.rtt_source = func() -> float: return ArenaNetBridge.link_rtt_ms(link)
	# READY only once the scene exists, or what the server sent in between hits a missing node.
	if link != null and link.has_method("is_playing") and bool(link.call("is_playing")):
		_announce()
	elif link != null and link.has_signal("spawned"):
		link.connect("spawned", _announce, CONNECT_ONE_SHOT)

	ArenaLoadTimeline.mark("netcode: wired")
	return net.start()


## The client's netcode settings: the server's rates, prediction on, rewinding left to the server.
func _client_net_config() -> DotNetConfig:
	var config := DotNetConfig.new()
	config.tick_rate = game.tick_rate
	config.snapshot_rate = ArenaGame.snapshot_rate_for(game.tick_rate)
	config.interpolation_buffer = ArenaGame.client_interp_buffer(config.snapshot_rate)
	config.enable_prediction = true
	config.enable_lag_compensation = false  # rewinding is a server's job
	config.max_entities_per_snapshot = 0
	# From the game: a quantised position decoded against the wrong range is a different position.
	config.world_extent = ArenaGame.NET_WORLD_EXTENT
	# By name, as a pack runs on whatever dot-net its shell carries (docs/netcode.md, "A frame's cost").
	if &"reconcile_once_per_frame" in config:
		config.set(&"reconcile_once_per_frame", ArenaFrameProbe.launch_value("cl_reconcile_per_snapshot") != "1")
	# And no replay when the snapshot matches the prediction; `cl_replay_always 1` replays every one.
	if &"skip_matching_replays" in config:
		config.set(&"skip_matching_replays", ArenaFrameProbe.launch_value("cl_replay_always") != "1")
	return config


## What the bridge relays from the wire, onto the handlers that draw it.
func _connect_bridge_events() -> void:
	bridge.hello_received.connect(_on_hello)
	bridge.notice_received.connect(_on_notice)
	bridge.vote_received.connect(_on_vote)
	bridge.kill_received.connect(_on_kill)
	bridge.hit_received.connect(_on_hit)
	bridge.killview_received.connect(_on_killview)
	bridge.award_received.connect(_on_award)
	bridge.stomp_received.connect(_on_stomp)
	bridge.grenade_fx_received.connect(_on_grenade_fx)
	bridge.match_received.connect(_on_match)


## READY, and the field of view setting the kill view of a victim of mine draws through.
func _announce() -> void:
	_say_ready()
	send_field_of_view()


## Tells the server the field of view setting.
func send_field_of_view() -> void:
	if bridge != null and not _offline:
		bridge.send_request(ArenaEvents.Ask.FOV, ArenaEvents.write_fov(_field_of_view()))

func _build_killview() -> void:
	killview = DotKillViewClient.new()
	killview.name = "KillView"
	add_child(killview)
	killview.setup(game.killview_rules)
	killview.hide_fn = func() -> Array: return [hud, view_model]
	killview.stage = killcam
	_pov_spares.append(KillPovView.mount(self, game, killview, "KillViewScreen", not _builds_in_frames()))
	killview.respawn_requested.connect(func() -> void:
		if bridge != null:
			bridge.send_request(ArenaEvents.Ask.RESPAWN)
		elif solo_killview != null:
			var _skipped := solo_killview.skip())
	if _offline and game.killview_rules.enabled:
		solo_killview = DotKillViewSolo.new(game.make_killview_server())
		solo_killview.local_id_fn = func() -> Variant: return player.player_id if player != null else null
		solo_killview.tick_fn = game.current_tick
		solo_killview.deliver_fn = _on_killview

func _build_killcam() -> void:
	killcam = DotKillcamHost.new()
	killcam_shots = ArenaKillcamShots.new()
	killcam_shots.parent = self
	ArenaKillcamBodies.configure(killcam, func() -> Variant: return ragdolls, killcam_shots)
	killcam.name = "FinalKillcam"
	killcam.rules = game.killview_rules if game != null else null
	killcam.players_fn = func() -> Array: return game.players() if game != null else []
	killcam.player_for_fn = func(id: int) -> Variant: return game.player_for(id) if game != null else null
	killcam.seconds_fn = func() -> float: return game.rule("killcam") if game != null else 0.0
	killcam.camera_mode_fn = func() -> int: return game.killview_rules.camera if game != null else DotKillViewRules.Camera.EYE
	killcam.weapon_name_fn = func(id: String) -> String:
		var def: DotWeaponDef = ArenaPlayer.weapon_catalogue().get_def(StringName(id)) if id != "" else null
		return def.display_name if def != null and def.display_name != "" else id.capitalize()
	killcam.weapon_icon_fn = func(id: String) -> Texture2D:
		return ArenaWeaponIcons.shared.menu_texture(StringName(id))
	_pov_spares.append(KillPovView.mount(self, game, killcam, "KillcamScreen", not _builds_in_frames()))
	killcam.over.connect(func(_skipped: bool) -> void: _reveal_winner())
	add_child(killcam)

## A player exists. Ours is one of them; the rest need something to be seen as. [b]`player_added`,
## not `player_spawned`.[/b] `player_spawned` comes out of dot-match's respawn queue, which runs on
## the AUTHORITY — a mirroring client never fires it, so a client waiting on it waits for ever.
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

	if added == player:
		return
	if added.body_mesh == null and _builds_in_frames():
		_queue_body(added)
		return
	if added.body_mesh == null:
		_attach_stock_body(added)
	_share_shots_of(added)

## Their guns' reports go through the presentation's one shot player, not one built per shooter.
func _share_shots_of(added: ArenaPlayer) -> void:
	if presentation != null and added.held != null:
		presentation.share_shots(added.held)
		# After the presentation's own handler, so the report it sets is the one wrapped.
		if not added.held.child_entered_tree.is_connected(_wrap_suppressed_child):
			added.held.child_entered_tree.connect(_wrap_suppressed_child)


func _wrap_suppressed_child(child: Node) -> void:
	if child is AwShotFx:
		_wrap_suppressed(child as AwShotFx)

## The players whose stock bodies are not built yet, oldest first (see [method _queue_body]).
var _bodies_due: Array[ArenaPlayer] = []

## Builds [param added]'s stock body in a later frame. A body is about 4 ms on staging02 and a sim host's
## 31 bots all arrive in one frame (130 ms of bodies on top of arming), so they are built a budget a frame
## instead, behind a `bodies` hold while the gate is still closed.
func _queue_body(added: ArenaPlayer) -> void:
	_bodies_due.append(added)
	if _bodies_due.size() > 1:
		return
	if gate != null and not gate.is_open():
		gate.hold(&"bodies", "Dressing the players")
	_build_due_bodies()

## Drains [member _bodies_due], at most [constant BODY_BUDGET_MS] of bodies a frame.
func _build_due_bodies() -> void:
	var slice := DotFrameSlice.new(BODY_BUDGET_MS)
	await slice.pause()
	while not _bodies_due.is_empty():
		var next: ArenaPlayer = _bodies_due.pop_front()
		if not is_instance_valid(next) or next == player:
			continue
		if next.body_mesh == null:
			_attach_stock_body(next)
		_share_shots_of(next)
		if slice.due() and not _bodies_due.is_empty():
			await slice.pause()
	if gate != null and gate.is_holding(&"bodies"):
		gate.release(&"bodies")

## Milliseconds of stock bodies a frame (see [method _queue_body]).
const BODY_BUDGET_MS := 12
## Milliseconds of offline bots added a frame at a solo start (each is ~4 ms with its body).
const OFFLINE_BOT_BUDGET_MS := 8

## A stock avatar until the server says otherwise.
func _attach_stock_body(added: ArenaPlayer) -> void:
	added.attach_body_mesh(
		Color.from_hsv(fmod(float(added.player_id) * 0.37, 1.0), 0.55, 0.85),
		added.avatar if added.avatar != null else ArenaAvatars.stock_avatar(
			StringName(ArenaGame.storage_key(added.player_id))
		)
	)

# --- Networked -------------------------------------------------------------

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

## Settings, audio, effects and the console.
func _build_presentation() -> void:
	presentation = ArenaPresentation.new()
	presentation.name = "Presentation"
	presentation.client = self
	add_child(presentation)
	DotLog.result(CHANNEL, "the presentation layer", presentation.setup())
	if presentation.blood != null and game != null:
		presentation.blood.mask = game.ragdoll_rules.collision_mask
	# on_map(id) alone then finds a map definition's `meta.ambient` (or `meta.doc`).
	if presentation.ambient != null:
		presentation.ambient.map_lookup = func(id: StringName) -> Variant:
			if _menu_catalogue == null:
				_menu_catalogue = ArenaMaps.catalogue()
			return _menu_catalogue.get_map(id)

	_wire_chat_window()

	presentation.settings.changed.connect(func(key: StringName, _v: Variant, _w: StringName) -> void:
		# The field of view is the one setting that has to reach something already built.
		# A camera that keeps the value it was created with is exactly the "produced
		# correctly and consumed by nothing" this family keeps finding.
		if key == &"field_of_view" and player != null:
			player.attach_camera(_field_of_view())
		if key == &"field_of_view":
			send_field_of_view()
	)

# --- The mouse -------------------------------------------------------------

## Asks a browser for the cursor rather than telling it. Pointer lock needs **transient user
## activation** — a real click — and `_ready()` is the one moment guaranteed not to have one.
func _grab_mouse() -> void:
	if not DotPlatform.is_web():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_awaiting_click = true

	if hud != null:
		hud.notice("Click to play")

## The art ids every spawn carries; the other models load after the cover lifts ([method _warm_rest_tick]).
const SPAWN_ARTS: Array[StringName] = [&"pistol", &"knife"]

var _rest_paths: Array[String] = []


func _spawn_model_paths() -> Array[String]:
	var arts: Array[AwWeaponVisual] = []
	for id in SPAWN_ARTS:
		var art := AwWeaponArtTable.get_art(id)
		if art != null:
			arts.append(art)
	return AwWeaponArtTable.Listing.model_paths(arts, false)


## Loads the models the cover did not wait for, one a frame, so the first draw of any gun is a cache hit.
func _warm_rest_tick() -> void:
	if _rest_paths.is_empty():
		get_tree().process_frame.disconnect(_warm_rest_tick)
		return
	AwModelCache.scene(_rest_paths.pop_back())


func _begin_warm_rest() -> void:
	var first := _spawn_model_paths()
	for path in AwWeaponArtTable.model_paths():
		if not first.has(path):
			_rest_paths.append(path)
	if not _rest_paths.is_empty() and not get_tree().process_frame.is_connected(_warm_rest_tick):
		get_tree().process_frame.connect(_warm_rest_tick)


func _weapon_warm_items() -> Array:
	var out: Array = []
	for path in _spawn_model_paths():
		var model := AwModelCache.instantiate(path)
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
	# A solo game hosted beside this process is joined like any server, whatever asked for offline.
	platform.force_offline = force_offline and _sim_host == null
	if _sim_host != null:
		# `--offline` means no remote server; the link to this machine's own server survives it.
		platform.link = _sim_host.link
		platform.local_link = true
	platform.use_settings = false
	platform.use_console = false
	platform.capture_pointer = false
	platform.scoreboard_action = &""
	platform.spawned_fn = func() -> bool: return player != null and player.camera != null
	add_child(platform)
	gate = platform.gate
	# A browser's first start compiles every shader while the weapons warm (slow frames of 0.3 to 3 s): the
	# "weapons" hold, progressing all along, ended 19.9 s after the gate closed, past the 20 s default.
	if DotPlatform.is_web():
		gate.timeout_sec = maxf(gate.timeout_sec, WEB_GATE_TIMEOUT_SEC)
	# The warm-up sizes its rounds by what is left of this budget after a bare frame, and a load frame
	# here (the match's ticks and the view) is 56-100 ms on staging02: at dot-core's 40 nothing is
	# left, every round is 4 items over 2 frames, and the warm-up took 9-11 s of the cover.
	if &"warm_budget_msec" in gate:
		gate.set(&"warm_budget_msec", maxf(float(gate.get(&"warm_budget_msec")), GATE_WARM_BUDGET_MSEC))
	link = platform.link as Node
	gate.ready_to_show.connect(func() -> void: ready_to_show.emit())
	gate.hold(&"map", "Loading the map")
	# Headless draws nothing: loading every weapon model to warm its materials is 38 MB for no frame.
	if not DotPlatform.is_headless():
		gate.warm_up(_weapon_warm_items())
		gate.opened.connect(_begin_warm_rest, CONNECT_ONE_SHOT)
		gate.opened.connect(_prebuild_catalogue, CONNECT_ONE_SHOT)
	if ArenaFrameProbe.on() and DotWeb.available():
		# Lets a page script split its own frame log at the cover (window.dotWeb.publishedAt.arena_gate_open, ms).
		gate.opened.connect(func() -> void: DotWeb.publish("arena_gate_open", "1"))
	# The chat box and console have the keyboard, and so does the menu: the platform polls
	# this every frame, so there is no signal to forward from each of them.
	platform.busy_fn = _input_busy
	platform.input_blocked_changed.connect(_suspend_input)

## Online: no local trust and no panel until the server names this player an admin (sv_workbench_remote).
func _start_remote_workbench() -> void:
	if _workbench_remote == null:
		return
	var wb := DotGameWorkbench.new()
	wb.name = "Workbench"
	wb.remote_client = _workbench_remote
	wb.remote_fn = func() -> bool: return true
	add_child(wb)
	var started := wb.start(_profile_runtime)
	DotLog.result(CHANNEL, "the remote workbench", started)
	if not started.ok:
		wb.queue_free()
		return
	wb.open_changed.connect(func(open: bool) -> void:
		_workbench_open = open
		if open:
			platform.hold_pointer(&"workbench")
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			platform.release_pointer(&"workbench")
			_apply_mouse())
	_workbench = wb

## Solo: F9 opens dot-workbench over the config and noblock sets (nothing without the addon).
func _start_solo_workbench() -> void:
	var wb := DotGameWorkbench.new()
	wb.name = "Workbench"
	wb.lazy_panel = true
	wb.listen_host_fn = func() -> bool: return true
	for set: DotProfileSet in _solo_binder.profile_sets():
		wb.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	if game.noblock != null:
		wb.add_set(game.noblock.binder.profile_set(), "Noblock")
	var _fl := game.flashlight_conf()
	for set: DotProfileSet in game.flashlight_binder.profile_sets():
		wb.add_set(set, "Flashlight")
	add_child(wb)
	var started := wb.start()
	DotLog.result(CHANNEL, "the workbench", started)
	if not started.ok or wb.api == null:
		return
	_solo_binder.attach(wb.api.runtime)
	if game.noblock != null:
		game.noblock.binder.attach(wb.api.runtime)
	game.flashlight_binder.attach(wb.api.runtime)
	wb.open_changed.connect(func(open: bool) -> void:
		_workbench_open = open
		if open:
			platform.hold_pointer(&"workbench")
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			platform.release_pointer(&"workbench")
			_apply_mouse())
	_workbench = wb

## `--sim_host 1`: the solo game in its own process, joined over loopback. Nothing of this client exists
## yet, so its callbacks stay off until the server answers; a failure plays the stock solo game.
func _start_sim_host() -> void:
	_set_client_processing(false)
	var host := ArenaSimHost.new()
	host.name = "SimHost"
	add_child(host)
	var started: DotResult = await host.start(_launch_bots())
	DotLog.result(CHANNEL, "sim host", started)
	if started.ok:
		_sim_host = host
	else:
		host.queue_free()
	_set_client_processing(true)

func _start_offline() -> void:
	# Offline catches up with wall-clock time only as far as a tick is cheap enough to
	# (`_physics_process` adjusts this from the measured cost, ArenaTickBudget); a flat
	# cap of 2 ran the whole simulation at half speed whenever a frame took over 30 ms.
	Engine.max_physics_steps_per_frame = ArenaTickBudget.MAX_STEPS
	var started := Time.get_ticks_usec()
	game.start(0)
	_start_solo_workbench()

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
	game.stomped.connect(
		func(_a: int, _v: int, _s: float, point: Vector3, sound: StringName, effect: StringName) -> void:
			_on_stomp({"point": point, "sound": String(sound), "effect": String(effect)})
	)
	game.grenade_effect.connect(_on_grenade_fx)
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
	ArenaLoadTimeline.mark("offline: match started, %d ms" % ((Time.get_ticks_usec() - started) / 1000))
	await _setup_frame()

	# In a client that draws, the match start, the player, its arming and the bots were one 460 ms
	# frame on staging02 (perf-bench 20261112-065900): each now gets frames of its own.
	_arm_after_adopt = _builds_in_frames()
	started = Time.get_ticks_usec()
	var added := game.add_player(1, "Player")

	if added.ok:
		_adopt(added.value as ArenaPlayer)
	ArenaLoadTimeline.mark("offline: player added, %d ms" % ((Time.get_ticks_usec() - started) / 1000))
	if _arm_after_adopt:
		_arm_after_adopt = false
		await _setup_frame()
		await _arm_stepped(player)
		_restore_loadout.call_deferred()
		await _setup_frame()

	_bind_bot_console()
	await _launch_offline_bots(_launch_bots())
	_run_launch_commands()

## A solo launch's bots: all at once headless, a few a frame in a client that draws, where 31 bots
## with their bodies were ~130 ms of one frame.
func _launch_offline_bots(count: int) -> void:
	if not _builds_in_frames():
		_keep_offline_bots(count)
		return
	var started := Time.get_ticks_usec()
	var frames := 0
	var slice := DotFrameSlice.new(OFFLINE_BOT_BUDGET_MS)
	for wanted in range(1, count + 1):
		var before := _bots.size()
		_keep_offline_bots(wanted)
		if _bots.size() <= before:
			break
		if slice.due() and wanted < count:
			await _setup_frame()
			frames += 1
			slice = DotFrameSlice.new(OFFLINE_BOT_BUDGET_MS)
	ArenaLoadTimeline.mark(
		"offline: %d bots, %d ms over %d frames"
		% [_bots.size(), (Time.get_ticks_usec() - started) / 1000, frames + 1]
	)
