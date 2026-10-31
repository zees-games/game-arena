extends DotGameCheckSuite

const ArenaViewArms := preload("../game/arena_view_arms.gd")
const ArenaAmbience := preload("../game/arena_ambience.gd")
const ArenaAvatars := preload("../game/arena_avatars.gd")
const ArenaAwards := preload("../game/arena_awards.gd")
const ArenaEvents := preload("../game/arena_events.gd")
const ArenaClient := preload("../game/arena_client.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaBindings := preload("../game/arena_bindings.gd")
const ArenaBrowser := preload("../game/arena_browser.gd")
const ArenaHud := preload("../game/arena_hud.gd")
const ArenaKillcamBodies := preload("../game/arena_killcam_bodies.gd")
const ArenaMenus := preload("../game/arena_menus.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaParty := preload("../game/arena_party.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaVote := preload("../game/arena_vote.gd")

## Settings, audio, effects, the console and the private-match party.
##
## [codeblock]
## godot --headless --path . res://examples/headless_presentation.tscn
## [/codeblock]
##
## [b]None of this is reachable from `headless_match` or `dedicated`.[/b] The first plays
## a whole deathmatch with no client in it; the second boots a real server and never
## connects one. That is exactly the shape this game has already been bitten by — its
## module looked a session up by the wrong key and **nobody could ever join a dedicated
## arena server**, silently, while `dedicated.tscn` passed its twenty-one checks
## throughout, because it never connected a client.
##
## Exits non-zero on any failure.

const CHECKS := 372

var _entered := 0
var _completed := 0


## The player's own settings file as it was before this run: its modification time, or -1
## for none. Checked at the end; see [method ArenaPresentation.use_scratch_settings].
var _player_file_was: int = -1


## A presentation layer, set up. [param console] builds its console with no menu, which is
## what a suite that wants the console alone needs; the client builds it after its menu
## ([method ArenaPresentation.build_console]).
## When the player's own settings document was last written, or -1 when there is none.
static func _player_file_stamp() -> int:
	var path := ProjectSettings.globalize_path(ArenaPresentation.PLAYER_SETTINGS).path_join("game_arena.local.json")
	return FileAccess.get_modified_time(path) if FileAccess.file_exists(path) else -1


func _make(console: bool = true) -> ArenaPresentation:
	var p := ArenaPresentation.new()
	p.name = "P%d" % _entered
	add_child(p)
	p.setup()
	if console:
		var _built := p.build_console()
	return p


## Gore is on by default, and off live (no restart) takes the blood and nothing else.
func _check_gore_toggle(p: ArenaPresentation, eye: Vector3, aim: Vector3, dead: Transform3D, drawn: Dictionary) -> void:
	_check(p.settings.get_bool(&"gore", false) and p.settings.schema.has(&"gore"), "gore is declared and on by default")
	p.settings.set_value(&"gore", false)
	drawn.clear()
	p.present(0.016, eye, aim)
	p.on_died(dead)
	p.present(0.016, eye, aim)
	var _slab_back := _slab(Vector3(0.0, 0.0, -5.0), aim)
	await get_tree().physics_frame
	await get_tree().physics_frame
	p.on_used(_outcome(eye, aim, [Vector3(0.0, 0.0, -5.0)]))
	_check(drawn.get(&"death_burst") == null, "gore off: a death draws no blood")
	_check(drawn.get(&"bullet_hole") != null, "and gore off still leaves the bullet holes", str(drawn.keys()))
	var gore_saved := p.settings.flush()
	var p_gore := _make(false)
	_check(gore_saved.ok and not p_gore.settings.get_bool(&"gore", true), "gore off is persisted and read back by the next start")
	p_gore.settings.set_value(&"gore", true)
	var _gf := p_gore.settings.flush()
	p_gore.queue_free()
	await _test_decals_need_a_surface(p, eye, aim)


## A 4 m square slab whose face is at [param at], facing back along [param aim]: what a hole needs to sit on.
func _slab(at: Vector3, aim: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 4.0, 0.4)
	shape.shape = box
	body.add_child(shape)
	add_child(body)
	var up := Vector3.RIGHT if absf(aim.normalized().dot(Vector3.UP)) > 0.99 else Vector3.UP
	body.global_transform = Transform3D(Basis.looking_at(aim, up), at + aim.normalized() * 0.2)
	return body


func _outcome(from: Vector3, aim: Vector3, impacts: Array[Vector3]) -> DotWeaponOutcome:
	var out := DotWeaponOutcome.new()
	out.used = true
	var shot := DotShot.new()
	shot.weapon_id = &"rifle"
	shot.origin = from
	shot.direction = aim
	shot.impacts = impacts
	out.add_shot(shot)
	return out


## Whether [param hole] holds a [Decal] whose projection (its -Y) runs along [param aim].
func _projects_along(hole: Variant, aim: Vector3) -> bool:
	if not hole is Node:
		return false
	var decals := (hole as Node).find_children("*", "Decal")
	if decals.is_empty():
		return false
	var decal := decals[0] as Decal
	return (-decal.global_basis.y).dot(aim.normalized()) > 0.99


## A key or mouse button down or up, through `Input`, so `Input.is_action_pressed` sees it.
static func _press(event: InputEvent, down: bool) -> void:
	if event is InputEventKey:
		(event as InputEventKey).pressed = down
	elif event is InputEventMouseButton:
		(event as InputEventMouseButton).pressed = down
	Input.parse_input_event(event)
	Input.flush_buffered_events()


static func _key_event(text: String, down: bool) -> InputEventKey:
	var key := DotInputBinding.from_text(text) as InputEventKey
	key.pressed = down
	return key


## The loadout is filed per site account: two accounts differ, a guest is "local", and a
## sign-in or sign-out mid-session re-keys it.
func _check_loadout_accounts(client: ArenaClient) -> void:
	var menu: Object = client.loadout_menu
	if not _check(menu != null, "the client has a loadout menu to key"):
		return
	_check(menu.get(&"remember_account") == "local", "with no auth client in the registry the loadout is filed under local")
	var bare := Node.new()
	_check(ArenaClient.loadout_account_key(null) == "local" and ArenaClient.loadout_account_key(bare) == "local",
		"no auth, or an auth with no account_key, is local")
	bare.free()
	var auth := FakeAuth.new()
	add_child(auth)
	client.follow_account(auth)
	_check(menu.get(&"remember_account") == "local", "a guest (signed out) is local")
	auth.key = "backbone:alice"
	auth.signed_in.emit(null)
	var alice: String = str(menu.get(&"remember_account"))
	auth.key = "backbone:bob"
	auth.signed_in.emit(null)
	var bob: String = str(menu.get(&"remember_account"))
	_check(alice == "backbone:alice" and bob == "backbone:bob" and alice != bob,
		"two accounts on one machine are filed apart", "%s / %s" % [alice, bob])
	auth.key = ""
	auth.signed_out.emit()
	_check(menu.get(&"remember_account") == "local", "signing out falls back to local")
	_check(not str(menu.get(&"remember_account")).contains("token"), "and no key is ever a token")
	client.follow_account(null)
	remove_child(auth)
	auth.free()


## The crosshair, down the sights: hip draws it, aimed hides it, released brings it back.
func _check_crosshair_sights(client: ArenaClient, me: ArenaPlayer, game: ArenaGame) -> void:
	var hud: ArenaHud = client.hud
	var hands: ZeeViewModel = me.weapons.view_model() as ZeeViewModel if me.weapons != null else null
	me.arsenal.select(ZeeWeaponIds.SLOT_PRIMARY, game.current_tick())
	for _i in 30:
		await get_tree().process_frame
	if _check(hud != null and hud.crosshair != null and hands != null, "the HUD has a crosshair and the player hands"):
		hud.present_body()
		hud.crosshair.follow_aim(1.0)
		var hip := hud.crosshair.aim_opacity
		# Fully raised, as the view model's ramp leaves it (set directly: headless has no pointer).
		hands.set(&"_aim_fraction", 1.0)
		hud.present_body()
		hud.crosshair.follow_aim(1.0)
		var aimed := hud.crosshair.aim_opacity
		hands.set(&"_aim_fraction", 0.0)
		hud.present_body()
		hud.crosshair.follow_aim(0.016)
		var easing := hud.crosshair.aim_opacity
		hud.crosshair.follow_aim(1.0)
		_check(easing > 0.0 and easing < 1.0, "lowering the gun fades the crosshair back rather than snapping it", "%.2f" % easing)
		_check(hip > 0.99 and aimed < 0.01 and hud.crosshair.aim_opacity > 0.99,
			"the crosshair is drawn at the hip, gone down the sights, and back after",
			"hip %.2f, aimed %.2f (fraction %.2f, scoped %s), after %.2f" % [hip, aimed, hands.aim_fraction(), hands.is_scoped(), hud.crosshair.aim_opacity])
		me.health.alive = false
		hud.crosshair.call(&"_process", 0.016)
		_check(not hud.crosshair.is_shown(), "a dead player's crosshair is not drawn")
		me.health.alive = true
		hud.crosshair.call(&"_process", 0.016)
		_check(hud.crosshair.is_shown(), "and it is back once alive")


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


## What the two flags `headless_net` delivers turn into on a client: a beacon that rings
## and pings, and a screen that goes dark. Nothing here can say they LOOK right — that is
## `tools/screenshot.sh --admin` — but it can say they are built, that they come and go
## with the flag, and that the ping happens once a period rather than once a frame.
static func _shrunk_bones(player: ArenaPlayer) -> int:
	if player.figure == null or player.figure.skeleton() == null:
		return -1
	var skel := player.figure.skeleton()
	var n := 0
	for i in skel.get_bone_count():
		if skel.get_bone_pose_scale(i).x < 0.01:
			n += 1
	return n


## A stand-in rendezvous: the four routes `DotP2PSignallerHttp` speaks, on a real socket,
## answering each request [member delay] frames after it arrives.
##
## [b]The delay is the point.[/b] The other party check here uses the loopback signaller,
## which answers inside the call — and a coroutine that never suspends is
## indistinguishable from a function, so a caller that forgot `await` passes against it.
## A rendezvous that answers frames later is the shape the real one has.
##
## Ported from game-playground's headless_presentation (d4ff040), on ports 38800-38860
## rather than playground's 38700-38760 so the two suites can run at the same time.
class RendezvousStub:
	extends Node

	var port := 0
	var delay := 4
	## An HTTP status to answer everything with instead of 200, to see a refusal arrive.
	var refuse := 0
	## What arrived, in order: `{route, body}`.
	var seen: Array[Dictionary] = []
	## The ids that announced themselves, so a join answers with who is here.
	var present: Array[String] = []

	var _server := TCPServer.new()
	var _open: Array[Dictionary] = []

	func start() -> bool:
		for candidate in range(38800, 38860):
			if _server.listen(candidate, "127.0.0.1") == OK:
				port = candidate
				return true
		return false

	func _exit_tree() -> void:
		_server.stop()

	func _process(_delta: float) -> void:
		while _server.is_connection_available():
			_open.append({"peer": _server.take_connection(), "bytes": PackedByteArray(), "wait": -1})

		for i in range(_open.size() - 1, -1, -1):
			var c: Dictionary = _open[i]
			var peer: StreamPeerTCP = c["peer"]
			peer.poll()
			var available := peer.get_available_bytes()
			if available > 0:
				var got := peer.get_data(available)
				if int(got[0]) == OK:
					# Written back: a packed array is a value, so appending to the one read
					# out of the dictionary appends to a copy and the bytes are lost.
					var buffer: PackedByteArray = c["bytes"]
					buffer.append_array(got[1] as PackedByteArray)
					c["bytes"] = buffer

			if int(c["wait"]) < 0:
				var text := (c["bytes"] as PackedByteArray).get_string_from_utf8()
				var split := text.find("\r\n\r\n")
				if split < 0:
					continue
				var length := 0
				for line in text.substr(0, split).split("\r\n"):
					if line.to_lower().begins_with("content-length:"):
						length = line.get_slice(":", 1).strip_edges().to_int()
				if (c["bytes"] as PackedByteArray).size() < split + 4 + length:
					continue
				var first := text.get_slice("\r\n", 0)
				var target := first.get_slice(" ", 1)
				var route := target.get_slice("?", 0).get_file()
				var body: Variant = JSON.parse_string(text.substr(split + 4)) if length > 0 else {}
				c["route"] = route
				c["body"] = body if body is Dictionary else {}
				seen.append({"route": route, "body": c["body"]})
				c["wait"] = delay
				continue

			if int(c["wait"]) > 0:
				c["wait"] = int(c["wait"]) - 1
				continue

			var answer := _answer(c["route"] as String, c["body"] as Dictionary)
			var status := "200 OK" if refuse == 0 else "".join(PackedStringArray([String.num_int64(refuse), " Refused"]))
			var payload := JSON.stringify(answer).to_utf8_buffer()
			var head := "".join(PackedStringArray(["HTTP/1.1 ", status, "\r\nContent-Type: application/json\r\nContent-Length: ", String.num_int64(payload.size()), "\r\nConnection: close\r\n\r\n"]))
			peer.put_data(head.to_utf8_buffer())
			peer.put_data(payload)
			peer.disconnect_from_host()
			_open.remove_at(i)

	func _answer(route: String, body: Dictionary) -> Dictionary:
		match route:
			"host":
				present.append(body.get("id", "") as String)
				return {}
			"join":
				var here := present.slice(0)
				present.append(body.get("id", "") as String)
				return {"peers": here}
			"poll":
				return {"messages": [], "cursor": 0}
		return {}


## A stand-in for dot-auth's client: the three members the loadout key reads.
class FakeAuth extends Node:
	signal signed_in(identity: Variant)
	signal signed_out()
	var key := ""
	func account_key() -> String:
		return key


## A hole needs a surface (dot-fx 0.3.3): a miss's endpoint is open air, a character walks
## away, and a crate that moves carries its hole with it.
func _test_decals_need_a_surface(p: ArenaPresentation, eye: Vector3, aim: Vector3) -> void:
	var drawn := {}
	p.fx.spawned.connect(func(id: StringName, node: Node, reason: StringName) -> void:
		drawn[id] = node if node != null else reason
	)
	var air := eye + aim * 60.0
	for draws in [false, true]:
		drawn.clear()
		p.present(0.016, eye, aim)
		p.on_used(_outcome(eye, aim, [air]), draws)
		_check(drawn.get(&"bullet_hole") == &"no_surface", "a shot into open air makes no hole (weapon_draws %s)" % draws, str(drawn.get(&"bullet_hole")))
		_check(drawn.get(&"impact_spark") == null, "and no spark floats there either (weapon_draws %s)" % draws)

	var crate := RigidBody3D.new()
	var cshape := CollisionShape3D.new()
	var cbox := BoxShape3D.new()
	cbox.size = Vector3.ONE
	cshape.shape = cbox
	crate.add_child(cshape)
	crate.gravity_scale = 0.0
	add_child(crate)
	crate.global_position = Vector3(0.0, 1.6, -30.0)
	var guard := CharacterBody3D.new()
	var gshape := CollisionShape3D.new()
	gshape.shape = CapsuleShape3D.new()
	guard.add_child(gshape)
	add_child(guard)
	guard.global_position = Vector3(30.0, 1.6, 0.0)
	await get_tree().physics_frame
	await get_tree().physics_frame

	drawn.clear()
	var toward_crate := Vector3.FORWARD
	var face := crate.global_position + Vector3(0.0, 0.0, 0.5)
	p.on_used(_outcome(eye, toward_crate, [face]), true)
	var hole: Variant = drawn.get(&"bullet_hole")
	_check(hole is Node3D, "a shot at a surface makes a hole on the crate", str(hole))
	_check(hole is Node and crate.is_ancestor_of(hole), "and a moving crate carries it: the hole is its child")
	if hole is Node3D:
		crate.global_position += Vector3(0.0, 2.0, 0.0)
		_check((hole as Node3D).global_position.y > 3.0, "so the hole moves with the crate")

	drawn.clear()
	p.on_used(_outcome(eye, Vector3.RIGHT, [guard.global_position - Vector3(0.5, 0.0, 0.0)]), true)
	_check(drawn.get(&"bullet_hole") == &"no_surface", "a character takes no hole", str(drawn.get(&"bullet_hole")))
	crate.queue_free()
	guard.queue_free()


## The wall the shot hits and a ceiling, solid by the time the shot is taken.
func _walls_for_a_shot(wall: Vector3, aim: Vector3) -> void:
	_slab(wall, aim)
	_slab(Vector3(0.0, 5.0, 0.0), Vector3.UP)
	await get_tree().physics_frame
	await get_tree().physics_frame


## Looking down in first person: the setting picks what is drawn and is kept, the legs are in view,
## and the feet stand on the floor under the eye.
func _test_own_body() -> void:
	_section("Looking down shows your own legs, feet on the floor, as the setting says")
	var p := _make(false)
	var _kept := p.settings.set_value(&"first_person_body", &"legs")
	var _flushed := p.settings.flush()
	var again := _make(false)
	_check(again.settings.get_string(&"first_person_body", "") == "legs", "the choice is saved for the next start")
	var g := ArenaGame.new()
	g.is_authority = true
	add_child(g)
	var _set := g.setup(ArenaMap.dm_box())
	var added: DotResult = g.add_player(9, "Nine")
	var me: ArenaPlayer = added.value if added.ok else null
	if not _check(me != null, "a player to look down from"):
		_done()
		return
	var _camera := me.attach_camera()
	me.attach_body_mesh(Color.WHITE, ArenaAvatars.stock_avatar(&"nine"))
	var client := ArenaClient.new()
	client.game = g
	client.player = me
	client.presentation = again
	var picks := []
	for choice: StringName in [&"off", &"body", &"auto", &"legs"]:
		var _r := again.settings.set_value(&"first_person_body", choice)
		picks.append(client.own_body_mode())
	_check(picks == [DotPlayerViewRules.BODY_OFF, DotPlayerViewRules.BODY_FULL, DotPlayerViewRules.BODY_LEGS, DotPlayerViewRules.BODY_LEGS],
		"none, whole body, the server's choice (legs) and legs each reach the player", str(picks))
	for _i in 30:
		g.tick()
	me.view_now = Vector2(me.controller.state.yaw, -60.0)
	for _i in 20:
		me.present_own_body(client.own_body_mode())
		me.present(1.0 / 60.0)
	var ankles := DotHumanoidLegs.ankles(me.figure.skeleton()) if me.figure != null else []
	var floor_y := me.controller.state.position.y
	var low := INF
	var mid := Vector3.ZERO
	for at: Vector3 in ankles:
		low = minf(low, absf(at.y - floor_y))
		mid += at / maxf(ankles.size(), 1)
	var look := -me.camera.global_basis.z
	var off_centre := rad_to_deg(look.angle_to(mid - me.camera.global_position))
	_check(me.body_mesh.visible and me.figure != null and me.figure.first_person == DotHumanoidOwnView.LEGS,
		"looking 60 degrees down, the legs are drawn and the rest is not")
	_check(ankles.size() == 2 and off_centre < me.camera.fov * 0.5,
		"and the feet are in view (%.0f degrees off centre of a %.0f degree view)" % [off_centre, me.camera.fov])
	_check(low < 0.06, "the lower foot is on the floor under the eye (%.3f m off it)" % low)
	client.player = null
	client.game = null
	client.free()
	g.queue_free()
	_done()
