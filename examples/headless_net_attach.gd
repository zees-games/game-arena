extends "lossy_base.gd"

const ArenaAttach := preload("res://game/arena_attach.gd")
const ArenaPlayerNet := preload("res://game/arena_player_net.gd")
const EXPECTED_CHECKS := 15

## An attachment a client asks for over a real ENet link (Ask.ATTACH) is fitted by the server alone, and reaches the
## client as `net_fitted`: a real `DotServer` running `ArenaModule` and a real client in one process (as headless_lossy).
## A request the catalogue refuses, or one cut short, leaves the server's fitting as it was.


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		print("FAIL: watchdog, the suite took over 300 s")
		get_tree().quit(1))


func _run() -> void:
	print("game-fatal-contact: weapon attachments over a real server and a real client")
	DotPaths.remove_tree(DATA)
	Engine.physics_ticks_per_second = TICK_RATE
	var ok := await _boot()
	var a: Dictionary = {}
	if ok:
		a = await _connect_client("A", _server.config.effective_enet_port())
		ok = _check(a.get("bridge") != null and int(a["session"]) != 0, "a client connects over ENet", str(a.get("error", "")))
	if ok:
		_clients["A"] = a
		ok = await _body(a)
	await _teardown()
	DotPaths.remove_tree(DATA)
	_report_sections(_entered, _completed, 3, EXPECTED_CHECKS)


func _teardown() -> void:
	for label in _clients:
		var link: DotClientLink = _clients[label]["link"]
		if link != null and is_instance_valid(link):
			link.disconnect_from_server("test over")
	await get_tree().process_frame
	for label in _clients:
		var side: Node = _clients[label]["side"]
		if side != null and is_instance_valid(side):
			remove_child(side)
			side.queue_free()
	_clients.clear()
	if _relay != null:
		_relay.stop()
	await get_tree().process_frame
	if _server != null and is_instance_valid(_server):
		_server.shutdown("test over")
	if _server_side != null and is_instance_valid(_server_side):
		remove_child(_server_side)
		_server_side.queue_free()
	await get_tree().process_frame


## The first gun in the catalogue a suppressor fits.
func _suppressible(arsenal: DotWeaponArsenal) -> DotWeaponDef:
	for id in arsenal.catalogue.ids():
		var def := arsenal.catalogue.get_def(id)
		if (arsenal.attachments.choices_for(def).get(&"muzzle", []) as Array).has(&"suppressor"):
			return def
	return null


func _body(a: Dictionary) -> bool:
	_section("the server fits what the client asks for")
	var session := int(a["session"])
	var bridge: ArenaNetBridge = a["bridge"]
	var served := _game.player_for(session)
	if not _check(served != null and served.arsenal.attachments != null, "the server's player has the attachments catalogue"):
		_done()
		return false
	var def := _suppressible(served.arsenal)
	if not _check(def != null and served.arsenal.give(def.id).ok, "the server gives it a gun a suppressor fits", str(def.id if def != null else &"")):
		_done()
		return false
	served.hold(def.slot)
	var held := await _until(func() -> bool: return served.arsenal.current_def() != null and served.arsenal.current_def().id == def.id, RELIABLE_SECONDS)
	_check(held and served.arsenal.fitting_at(def.slot).is_empty(), "and holds it, bare", str(def.id))

	bridge.send_request(ArenaEvents.Ask.ATTACH, ArenaAttach.write_request(def.slot, &"muzzle", &"suppressor"))
	var fitted := await _until(func() -> bool: return served.arsenal.fitting_at(def.slot).attachment_on(&"muzzle") == &"suppressor", RELIABLE_SECONDS)
	_check(fitted, "the request fits a suppressor on the server", served.arsenal.fitting_at(def.slot).key())
	var code := ArenaAttach.held_code(served.arsenal)
	_check(code != 0 and ArenaAttach.suppressed(def.id, code), "whose code reads as suppressed", str(code))
	var own: ArenaPlayerNet = bridge.behaviour_for(session)
	var reached := await _until(func() -> bool: return own != null and own.net_fitted == code, RELIABLE_SECONDS)
	_check(reached, "the client receives the server's fitting as net_fitted", "%d against %d" % [own.net_fitted if own != null else -1, code])
	_done()

	_section("a refused or cut-off request changes nothing")
	var before := served.arsenal.fitting_at(def.slot).key()
	bridge.send_request(ArenaEvents.Ask.ATTACH, ArenaAttach.write_request(def.slot, &"muzzle", &"no_such_part"))
	bridge.send_request(ArenaEvents.Ask.ATTACH, ArenaAttach.write_request(def.slot, &"muzzle", &"scope_6x"))
	bridge.send_request(ArenaEvents.Ask.ATTACH, ArenaAttach.write_request(31, &"muzzle", &"compensator"))
	# Wait out the three by a fourth that does change something: requests arrive in order on the reliable channel.
	bridge.send_request(ArenaEvents.Ask.ATTACH, ArenaAttach.write_request(def.slot, &"muzzle", &""))
	var bare := await _until(func() -> bool: return served.arsenal.fitting_at(def.slot).attachment_on(&"muzzle") == &"", RELIABLE_SECONDS)
	_check(bare and served.arsenal.fitting_at(def.slot).is_empty(), "an unknown part, a wrong mount and an empty slot fit nothing; an empty id takes it off", "%s then %s" % [before, served.arsenal.fitting_at(def.slot).key()])
	var cut := ArenaAttach.write_request(def.slot, &"muzzle", &"suppressor").slice(0, 3)
	_check(not ArenaAttach.serve(served.arsenal, DotNetReader.new(cut)).ok and served.arsenal.fitting_at(def.slot).is_empty(), "a cut-off request is refused")
	_check(not ArenaAttach.serve(served.arsenal, DotNetReader.new(ArenaAttach.write_request(def.slot, &"", &"suppressor"))).ok, "and one naming no mount")
	var cleared := await _until(func() -> bool: return own.net_fitted == 0, RELIABLE_SECONDS)
	_check(cleared and not ArenaAttach.suppressed(def.id, own.net_fitted), "the client sees the bare gun again", str(own.net_fitted))
	_done()
	return true
