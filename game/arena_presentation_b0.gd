extends Node

const ArenaRecoilView := preload("arena_recoil_view.gd")
const ArenaFlagCarry := preload("arena_flag_carry.gd")
const ArenaKillPovRecoil := preload("arena_kill_pov_recoil.gd")
const ArenaFrameProbe := preload("arena_frame_probe.gd")
const ArenaAudioManager := preload("arena_audio_manager.gd")


const ArenaBlood := preload("arena_blood.gd")
const ArenaHoleSizes := preload("arena_hole_sizes.gd")


const ArenaAwards := preload("arena_awards.gd")


const ArenaHud := preload("arena_hud.gd")


const ArenaWeaponIcons := preload("arena_weapon_icons.gd")
const ArenaViewArms := preload("arena_view_arms.gd")
const ArenaBspMap := preload("../maps/arena_bsp_map.gd")
const ArenaPlayer := preload("arena_player.gd")
const ArenaKillcamBodies := preload("arena_killcam_bodies.gd")

## Settings, audio, effects and a console, on the client.


const CHANNEL := "arena.presentation"


## The ping an administrator's beacon makes. See [method sound_catalogue].
const BEACON_SOUND := &"beacon"


## A rocket or a grenade going off: one id for the sound and the effect.
const EXPLOSION := &"explosion"


## A hit that killed: the hit marker's heavier sound.
const KILL_CONFIRMED := &"kill_confirmed"


## The local player's own wall moves: a scuff as a wall run starts, a kick as they jump off
## a wall. Flat and their own, like the hurt sound: somebody else's run is not news.
const WALL_RUN_SOUND := &"wall_run"
const WALL_JUMP_SOUND := &"wall_jump"


## Seconds between one kill's medal sounds; the HUD's `MedalRow.STAGGER_SEC`.
const MEDAL_STAGGER_SEC := 0.14


## How far an explosion shakes the camera, and how hard at its centre.
const EXPLOSION_SHAKE_RANGE := 18.0
const EXPLOSION_SHAKE := 0.6


## Where a muzzle flash is drawn, from the eye, in the aim's frame: forward, down, right.
const MUZZLE_OFFSET := Vector3(0.12, -0.14, -0.55)


var settings: DotSettingsManager = null


var audio: DotAudioManager = null


## Everybody's footsteps by surface and a bed per map: dot-audio's stock (Kenney's footsteps
## and generated beds, CC0; the addon's stock/CREDITS.md).
var steps: DotAudioFootsteps = null
var ambience: DotAudioAmbience = null


## Quiet moods under the map (dot-audio's stock set); the bed above plays only when none loaded.
var ambient: DotAmbienceDirector = null
var fx: DotFxManager = null
## Blood behind a body the local player hit; drawn only while `gore` is on.
var blood: ArenaBlood = null


## The player's console, built by [method build_console] once the client has a menu.
var console: DotConsoleController = null
var console_panel: DotConsolePanel = null


## The in-game chat box. See [method _build_chat].
var chat_window: DotChatWindow = null


## The client, for the commands that ask it questions.
var client: Node = null


var _chat_layer: CanvasLayer = null


## Whether the server said something else is carrying chat. See [method set_chat_relayed].
var _chat_relayed: bool = false


## Longest a frame spends baking sounds with the cover down, in milliseconds; the gate widens it under the cover.
const BAKE_BUDGET_MSEC := 6


var _bake_recipes: Dictionary = {}
var _bake_ids: Array = []


## Bakes the recipes named by [param ids] (consumed from the end) into [param bank] until
## [param budget_msec] is spent; one recipe is never split, so the call overruns by at most one.
## Stock voices (dot_audio stock/voices, self-synthesised) replace the sine-sweep stand-ins for shot, hit, hurt, die, impact, boom.
static func bake_into(bank: Dictionary, catalogue: DotAudioCatalogue, recipes: Dictionary, ids: Array, budget_msec: int) -> void:
	var until := Time.get_ticks_msec() + budget_msec
	while not ids.is_empty() and Time.get_ticks_msec() < until:
		var id: Variant = ids.pop_back()
		bank.merge(DotAudioSynth.bank(catalogue, {id: recipes[id]}, true))


## Calls [method bake_into] on the sink's bank until the frame's budget is spent, then lets the gate
## open once none are left. A recipe is one stream (or one per variant), so a frame overruns
## by at most one of them.
func _bake_slice() -> void:
	var sink := audio.sink as DotAudioSinkGodot if audio != null else null
	if sink == null:
		_bake_ids.clear()
		_bake_hold(false)
		return
	var gate: Object = client.get(&"gate") if client != null else null
	var budget := int(gate.call(&"slice_msec", BAKE_BUDGET_MSEC)) if gate != null and gate.has_method(&"slice_msec") else BAKE_BUDGET_MSEC
	bake_into(sink.bank, audio.catalogue, _bake_recipes, _bake_ids, budget)
	if _bake_ids.is_empty():
		_bake_hold(false)


## The load gate stays closed while sounds bake, so the cover only drops once they are all there.
func _bake_hold(on: bool) -> void:
	var gate: Object = client.get(&"gate") if client != null else null
	if gate == null:
		return
	if on:
		gate.call(&"hold", &"sounds", "Preparing sounds")
	else:
		gate.call(&"release", &"sounds")


## The box a player types in, and the three settings that decide it. A HUD widget, not a
## [DotScreenStack] screen: it is eight lines in a corner that leave the game visible.
func _build_chat() -> void:
	_chat_layer = CanvasLayer.new()
	_chat_layer.name = "ChatLayer"
	_chat_layer.layer = 100
	add_child(_chat_layer)

	# [b]Scaled with the HUD.[/b] Below 1280x720 `ArenaHud.fit_scale` shrinks the killstreak meter
	# and the key hints, and an unscaled box beside them reached both at 854x480.
	_chat_screen = Control.new()
	_chat_screen.name = "ChatScreen"
	_chat_screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chat_layer.add_child(_chat_screen)
	chat_window = make_chat_window()
	_chat_screen.add_child(chat_window)
	_fit_chat()


## The box as this game configures it; [method _build_chat] and the screenshot tool's
## `--glance --chat` both draw this one.
static func make_chat_window() -> DotChatWindow:
	var chat_window := DotChatWindow.new()
	chat_window.name = "ChatWindow"
	chat_window.open_action = &"arena_chat"
	chat_window.team_action = &"arena_chat_team"
	# [b]An outline, because the floors are pale.[/b] Light-blue names and white text over light
	# grey tiles were a log the players asked, in that log, to be able to read.
	chat_window.outline_size = 5
	# Flush with the left edge the health and armour bars use, and lifted clear of them. `ArenaHud`
	# puts health at 96 pixels off the bottom and armour at 56; a box at the default inset draws its
	# log straight through both, which is the kind of thing only a rendered frame says.
	chat_window.margin_left = 24.0
	chat_window.margin_bottom = 110.0
	# Narrower than the default 460: the slide prompt ("Cancel slide  C") is drawn from
	# x 381 at 1280x720, inside a full log's rows, and a long line ran under it.
	chat_window.width = 340.0
	chat_window.channels = [
		{"id": &"all", "label": "Say", "colour": Color(0.88, 0.90, 0.94)},
		{"id": &"team", "label": "Say (TEAM)", "colour": Color(0.55, 0.85, 0.60), "team": true},
	]
	return chat_window


## Lays [param screen], the chat box's parent, out on a frame [param frame] pixels: scaled
## by the HUD's own [method ArenaHud.fit_scale], so the box shrinks exactly as the HUD does.
static func fit_chat_screen(screen: Control, frame: Vector2) -> void:
	var fit := ArenaHud.fit_scale(frame)
	screen.set_anchors_preset(Control.PRESET_TOP_LEFT)
	screen.scale = Vector2(fit, fit)
	screen.position = Vector2.ZERO
	screen.size = frame / fit


## The chat box's parent; see [method _build_chat].
var _chat_screen: Control = null


## The frame the chat box was last fitted to.
var _chat_frame := Vector2.ZERO


func _fit_chat() -> void:
	if _chat_screen == null:
		return
	var frame := _chat_screen.get_viewport_rect().size if _chat_screen.is_inside_tree() else ArenaHud.DESIGN_FRAME
	if frame == _chat_frame:
		return
	_chat_frame = frame
	fit_chat_screen(_chat_screen, frame)


func _process(_delta: float) -> void:
	if not _bake_ids.is_empty():
		_bake_slice()
	# Polled rather than on `size_changed`: this node can be set up before it is in a tree,
	# and one Vector2 compare a frame is cheaper than tracking when it enters one.
	_fit_chat()


## Puts one binding from the settings document onto its action. Empty is left alone rather than
## applied: a settings file somebody cleared the field in would otherwise unbind chat with no way to
## get it back from inside the game.
func _bind_chat(action: StringName, text: String) -> void:
	if action == &"" or text.strip_edges() == "":
		return

	var bound := DotInputBinding.apply(action, text)

	if bound == "":
		DotLog.warn(CHANNEL, "a chat key was not understood", {
			"action": String(action), "binding": text
		})


## The server said whether anything else is carrying this conversation. Called by [ArenaClient] when
## the state payload arrives, and again if a relay comes up or goes down mid-match.
func set_chat_relayed(relayed: bool) -> void:
	if _chat_relayed == relayed:
		return

	_chat_relayed = relayed
	_apply_chat_visibility()


## Resolves the three-way setting against what the server said. `auto` draws the box unless this
## server already puts these lines where the player can see them (a web client whose page holds the
## relay's room). In every case the log keeps drawing what other people said.
func _apply_chat_visibility() -> void:
	if chat_window == null or settings == null:
		return

	match StringName(str(settings.get_value(&"chat_window"))):
		&"on":
			chat_window.enabled = true
		&"off":
			chat_window.enabled = false
		_:
			chat_window.enabled = not _chat_relayed


## This game's own commands; the kit has `help`, `clear`, `settings` and every setting.
## Idle meshes each shot fx pool keeps (`cl_fx_pool_idle`; -1 keeps all), pushed at [method setup].
static var fx_pool_idle := 8


## Reads, or with [param value] writes, a static of an addon class that an older checkout of
## the addon may not have yet: [param fallback] when it is missing, and the write is skipped.
static func _addon_static(script: Script, name: StringName, fallback: Variant, value: Variant = null) -> Variant:
	var have: Variant = script.get(name)
	if have == null:
		return fallback
	if value != null:
		script.set(name, value)
		return script.get(name)
	return have
