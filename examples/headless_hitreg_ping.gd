extends DotGameCheckSuite

## "Shouldn't my bullets have hit that enemy?" — end to end, over a simulated link.
##
## A real server and two real clients (bridges, bit-packed commands, snapshots, the
## interpolator), with every packet held for half the round trip each way: 30, 50 and 80 ms
## at the shipped 66 Hz tick and snapshot rate. Peer 3 strafes. Peer 2 stands, and on each tap
## aims from its own muzzle at peer 3's torso exactly where its screen drew it on the frame
## before the click, and fires: at its middle, and at either edge [constant EDGE_MARGIN_M]
## inside the silhouette, where a rewind a few centimetres off turns a hit into a miss. The
## server must register every one. The gun's spread, bloom and recoil are zeroed for the
## round (they are the gun's, not the netcode's), and the trace reaching the server is
## checked to be the one aimed. Also measured, per shot: how far the server's rewound body
## stood from the one drawn, which must stay under [constant REWIND_TOLERANCE_M].
##
## The clocks are placed by hand, as the net suites do: [code]DotNetClock[/code] follows the
## wall clock, which would make the run a different one on every box. The client's frame is
## drawn at a fraction through the tick ([constant ALPHAS]), as a monitor faster than the
## tick rate draws it, and the click is read by the next tick's command, as the game does.

const ArenaContent := preload("../game/arena_content.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaNetBridge := preload("../game/arena_net_bridge.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaPlayerTunables := preload("../game/arena_player_tunables.gd")

const TICK_RATE := ArenaContent.TICK_RATE
const SHOOTER_PEER := 2
const TARGET_PEER := 3
const SHOOTER := 11
const TARGET := 12

const PINGS: Array[int] = [30, 50, 80]
## The range shot at, or 0.8 of a gun's reach if that is shorter (the derringer reaches 18 m).
const DISTANCE := 20.0
const TAPS := 12
const TAP_TICKS := 24
const SETTLE_TICKS := 90
## Where in its tick the frame on screen at the click was drawn: a monitor faster than the tick rate draws several per tick.
const ALPHAS: Array[float] = [0.0, 0.25, 0.5, 0.75, 0.95]
## How far inside the drawn torso's edge the edge shots go (the torso is 0.30 m in radius).
const EDGE_MARGIN_M := 0.05
## The wire's view angles (DotFpsCommand: yaw 12 bits round, pitch 9 bits over 180 degrees):
## the server's trace may leave up to half a step from the aim, and no further.
const YAW_STEP_DEG := 360.0 / 4096.0
const PITCH_STEP_DEG := 180.0 / 511.0
## How far the server's trace may start from the eye the client aimed from.
const ORIGIN_M := 0.01
## How far the server's rewound body may stand from the one drawn: a quarter-tick step of the wire, and the server's tick ring against the snapshots between.
const REWIND_TOLERANCE_M := 0.025
## The torso hitbox, [code]ArenaPlayer[/code]'s zones, before the body scale.
const TORSO_RADIUS := 0.30
const TORSO_HEIGHT := 0.98
const HITSCAN := "dot_weapon_hitscan.gd"
const BEAM := "dot_weapon_beam.gd"
## Every spread, bloom and recoil a ballistics tuning has, zeroed for the round.
const AIM_NOISE: Array[StringName] = [&"spread", &"spread_moving", &"spread_airborne", &"spread_crouched",
	&"bloom", &"bloom_max", &"spread_aim", &"spread_hip", &"spread_sprint", &"spread_slide", &"spread_flinch",
	&"bloom_crouch", &"recoil_pitch", &"recoil_yaw", &"recoil_build", &"recoil_build_max"]

const PLAYED_TAP_TICKS := 96
## Played rounds: the target crouches and stands every this many ticks.
const CROUCH_TICKS := 13
const CHECKS := 220
const SECTIONS := 4

var _entered := 0
var _completed := 0

var _server_game: ArenaGame = null
var _server_net: DotNetManager = null
var _server_bridge: ArenaNetBridge = null
var _clients: Dictionary = {}
var _joins: Array[PackedByteArray] = []

## Packets in flight: {"at": step it lands, "peer": int, "bytes": PackedByteArray}.
var _up: Array[Dictionary] = []
var _down: Array[Dictionary] = []
var _up_ticks := 1
var _down_ticks := 1
var _step := 0

## What the shooter's screen showed, per command tick it fired on.
var _drawn_for: Dictionary = {}
## The frame drawn last: {"point": chest, "time": render tick}.
var _last_frame: Dictionary = {}
## Server resolutions of the shooter's shots, as they come.
var _resolved: Array[Dictionary] = []
## Where the server's rewind for the shot being traced stood the target (null: no rewind).
var _stood: Variant = null
## The view tick of that rewind, and whether it blended the shooter's bracket (ArenaNetBridge.shot_feet).
var _stood_view := -1.0
var _stood_blended := false
## Ticks between taps this round: the gun's refire, at least [constant TAP_TICKS].
var _tap_ticks := TAP_TICKS
## A round as it is played rather than with the gun's noise zeroed: the tuning kept, the aim
## button held all round (scoped), the range [member _range] when above 0, the target walking at
## the shooter while it strafes, every shot at the middle of the drawn torso, a second and a half
## apart as the owner shot ([constant PLAYED_TAP_TICKS]). Off here; headless_hitreg_scope turns it on.
## The trace may leave a recoil's residue off the aim then, so only the hit is held.
var _as_played := false
var _range := 0.0
## Who is shot at: peer 3's player, or a server bot (headless_hitreg_scope).
var _target := TARGET


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact headless hit registration over a simulated link")
	_build()
	var weapons := _hitscan_weapons()
	_check(weapons.size() >= 3, "the pack has hitscan guns to try", str(weapons))
	for ping in PINGS:
		_section("ping %d ms" % ping)
		for id in weapons:
			_round(id, ping)
		_done()
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


## Every gun that resolves its shot on the tick by tracing it (hitscan and beam), not a
## projectile, a knife, a grenade or a gun that charges before it fires.
func _hitscan_weapons() -> Array[StringName]:
	var out: Array[StringName] = []
	for def: DotWeaponDef in ArenaContent.weapons():
		var tuning := def.tuning as DotWeaponBallistics
		var traced := def.behaviour_path.ends_with(HITSCAN) or def.behaviour_path.ends_with(BEAM)
		if tuning == null or not traced or def.fire_mode == DotWeaponDef.Fire.CHARGE:
			continue
		print("    %-22s slot %d pellets %d %s" % [def.id, def.slot, tuning.pellets, def.behaviour_path.get_file()])
		out.append(def.id)
	return out


# --- The three ends --------------------------------------------------------

func _lane() -> ArenaMap:
	var map := ArenaMap.new()
	map.id = &"hitreg_lane"
	map.display_name = "hitreg_lane"
	map.extent = 150.0
	map.wall_height = 8.0
	var _p := map.add_perimeter()
	var _s1 := map.add_spawn(Transform3D(Basis(), Vector3(0.0, 0.05, 0.0)))
	var _s2 := map.add_spawn(Transform3D(Basis(), Vector3(5.0, 0.05, 0.0)))
	return map


func _make_game(authority: bool) -> ArenaGame:
	var game := ArenaGame.new()
	game.name = "Arena%s" % ("Server" if authority else str(_clients.size()))
	game.tick_rate = TICK_RATE
	game.score_limit = 0
	# Not 0: that keeps the mode's 600 s, and a run past it ends the match mid-round and
	# stands everyone on a map spawn (headless_hitreg_chaos crossed it at tick 41054).
	game.time_limit_sec = 7200.0
	game.headless = true
	game.is_authority = authority
	game.register_service = false
	add_child(game)
	var ready := game.setup(_lane())
	_check(ready.ok, "%s game sets up" % ("server" if authority else "client"), str(ready.error))
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	game.start(0)
	return game


func _make_manager(is_server: bool, scope: StringName, peer_id: int) -> DotNetManager:
	var net := DotNetManager.new()
	net.name = "Net%s" % scope
	net.is_server = is_server
	net.service_scope = scope
	net.local_peer_id = peer_id
	net.auto_tick = false
	net.config_file = ""
	net.config = DotNetConfig.new()
	net.config.tick_rate = TICK_RATE
	net.config.snapshot_rate = ArenaGame.snapshot_rate_for(TICK_RATE)
	# Sized from wall-clock arrival gaps it would be a different delay on every box.
	net.config.adaptive_interpolation = false
	net.config.world_extent = ArenaGame.NET_WORLD_EXTENT
	add_child(net)
	_check(net.setup().ok, "%s manager sets up" % scope)
	return net


func _build() -> void:
	_section("a server and two clients")
	_server_game = _make_game(true)
	_server_net = _make_manager(true, &"server", 1)
	_server_bridge = ArenaNetBridge.new()
	_server_bridge.name = "ServerBridge"
	add_child(_server_bridge)
	_check(_server_bridge.attach(_server_game, _server_net).ok, "the server bridge attaches")
	_server_net.messages.seal()
	_server_net.start()
	_server_bridge.player_announced.connect(func(payload: PackedByteArray) -> void:
		_joins.append(payload))
	_server_net.send_fn = func(peer_id: int, payload: PackedByteArray, _d: int) -> void:
		var at := _down_at()
		if at >= 0:
			_down.append({"at": at, "peer": peer_id, "bytes": payload})
	_server_game.combat.shot_resolved.connect(_on_resolved)
	# Where the server's rewind stood the target, read inside the rewind: that, not the ring
	# recomputed here, is what the trace met.
	var rewind: Callable = _server_game.combat.rewind_fn
	_server_game.combat.rewind_fn = func(view_tick: float) -> void:
		rewind.call(view_tick)
		var target := _server_game.player_for(_target)
		_stood = target.global_position if target != null else null
		_stood_view = view_tick
		_stood_blended = _server_bridge.shot_feet(_target, SHOOTER, view_tick) != null

	for pair: Vector2i in [Vector2i(SHOOTER_PEER, SHOOTER), Vector2i(TARGET_PEER, TARGET)]:
		var game := _make_game(false)
		var net := _make_manager(false, &"client%d" % pair.x, pair.x)
		var bridge := ArenaNetBridge.new()
		bridge.name = "Bridge%d" % pair.x
		add_child(bridge)
		_check(bridge.attach(game, net).ok, "client %d's bridge attaches" % pair.x)
		net.messages.seal()
		net.start()
		_clients[pair.x] = {"game": game, "net": net, "bridge": bridge, "session": pair.y}

	for peer_id: int in _clients:
		var added := _server_bridge.add_player(peer_id, int(_clients[peer_id]["session"]), "Player %d" % peer_id)
		_check(added.ok, "peer %d joins" % peer_id, str(added.error))
	for peer_id: int in _clients:
		for payload in _joins:
			_check(_clients[peer_id]["bridge"].apply_join(payload).ok, "client %d mirrors a join" % peer_id)
	_done()


# --- One round -------------------------------------------------------------

func _players(id: int) -> Array[ArenaPlayer]:
	var out: Array[ArenaPlayer] = [_server_game.player_for(id)]
	for peer_id: int in _clients:
		out.append((_clients[peer_id]["game"] as ArenaGame).player_for(id))
	return out


func _round(weapon_id: StringName, ping: int) -> void:
	var total := int(roundf(float(ping) / 1000.0 * float(TICK_RATE)))
	_up_ticks = total / 2
	_down_ticks = total - _up_ticks
	var def: DotWeaponDef = ArenaPlayer.weapon_catalogue().get_def(weapon_id)
	# The catalogue's def is the one all three ends read: zeroed here, restored after.
	var tuning := def.tuning as DotWeaponBallistics
	var kept: Dictionary = {}
	for field in ([] if _as_played else AIM_NOISE):
		if field in tuning:
			kept[field] = tuning.get(field)
			tuning.set(field, 0.0)

	var distance := _range if _range > 0.0 else minf(DISTANCE, 0.8 * tuning.max_range)
	_tap_ticks = maxi(PLAYED_TAP_TICKS if _as_played else TAP_TICKS, def.use_interval_ticks + 4)
	# A tap past the magazine would wait out a reload; the edges come first, then the middle.
	# A burst gun spends a burst a tap: the burst rifle's twelve taps were 36 rounds from 30, and
	# the last two waited out the reload (its "10 of 12" under every link, the harness's own).
	var per_tap := maxi(1, def.burst_count) if def.fire_mode == DotWeaponDef.Fire.BURST else 1
	var taps := mini(TAPS, def.magazine / per_tap) if def.magazine > 0 else TAPS

	# Both stand whole, the shooter holding only this gun, everywhere it exists.
	var tick := _server_game.current_tick()
	for p in _players(SHOOTER):
		p.spawn(Transform3D(Basis(), Vector3(0.0, 0.05, 0.0)), tick)
		p.arsenal.clear()
		var _g := p.arsenal.give(weapon_id)
		p.hold(def.slot)
	for p in _players(_target):
		p.spawn(Transform3D(Basis(), Vector3(0.0, 0.05, -distance)), tick)
	# Peer 3 keeps walking when the target is someone else: well clear of the line of fire.
	if _target != TARGET:
		for p in _players(TARGET):
			p.spawn(Transform3D(Basis(), Vector3(40.0, 0.05, 0.0)), tick)

	_drawn_for.clear()
	_resolved.clear()
	_last_frame.clear()
	var shots_sent := 0
	for i in SETTLE_TICKS + taps * _tap_ticks:
		var tap := (i - SETTLE_TICKS) / _tap_ticks
		var firing := i >= SETTLE_TICKS and (i - SETTLE_TICKS) % _tap_ticks == 0
		if _step_once(def.slot, firing, i, 0 if _as_played else [-1, 1, 0][tap % 3]) >= 0:
			shots_sent += 1
	# The last shots' packets.
	for i in _up_ticks + _down_ticks + 8:
		var _t := _step_once(def.slot, false, i, 0)
	for field: StringName in kept:
		tuning.set(field, kept[field])

	var matched := 0
	var aimed := 0
	var hit := 0
	var edge_hit := 0
	var edges := 0
	var errors: Array[float] = []
	var first_miss := ""
	var worst_off := 0.0
	for r in _resolved:
		var seen: Dictionary = _drawn_for.get(int(r["tick"]), {})
		if seen.is_empty():
			continue
		matched += 1
		var error: float = r["rewind_error"]
		errors.append(error)
		# Read with the aim from the eye the client aimed from: the angles sent are rounded to the wire's steps.
		var want := angles_to(seen["muzzle"], seen["point"])
		var got := angles_to(Vector3.ZERO, r["direction"])
		var on_wire := absf(wrapf(got.x - want.x, -180.0, 180.0)) <= YAW_STEP_DEG * 0.5 + 0.001 \
			and absf(got.y - want.y) <= PITCH_STEP_DEG * 0.5 + 0.001
		var from_eye := (r["origin"] as Vector3).distance_to(seen["muzzle"]) <= ORIGIN_M
		var lateral := INF
		for pellet: Vector3 in r["pellets"]:
			lateral = minf(lateral, _lateral(r["origin"], pellet, seen["point"]))
		worst_off = maxf(worst_off, lateral)
		if on_wire and from_eye:
			aimed += 1
		if int(seen["side"]) != 0:
			edges += 1
		if r["hit"]:
			hit += 1
			if int(seen["side"]) != 0:
				edge_hit += 1
		elif first_miss == "":
			first_miss = "tick %d side %d drawn at %.2f (alpha %.2f) lag %.2f, trace %.3f m off the aim, rewind error %.3f m, crouch drawn %.2f server %.2f, struck %s at %s" % [
				r["tick"], seen["side"], seen["time"], seen["alpha"], seen["lag"], lateral, error,
				seen["crouch"], r["crouch"], r["victims"], r["impacts"]]

	var worst_err := 0.0
	var mean_err := 0.0
	for e in errors:
		worst_err = maxf(worst_err, e)
		mean_err += e / float(maxi(1, errors.size()))
	print("    %-16s at %4.1f m sent %2d resolved %2d hit %2d (edges %d of %d)  rewind error mean %.3f worst %.3f m, trace off the aim by up to %.3f m" % [
		weapon_id, distance, shots_sent, matched, hit, edge_hit, edges, mean_err, worst_err, worst_off])
	if first_miss != "":
		print("      first miss: %s" % first_miss)
	_judge(weapon_id, ping, {"sent": shots_sent, "matched": matched, "aimed": aimed, "hit": hit,
		"mean_err": mean_err, "worst_err": worst_err, "first_miss": first_miss})


## The round's checks, from its counts: every shot resolved, aimed and hit, the rewind within tolerance.
func _judge(weapon_id: StringName, ping: int, c: Dictionary) -> void:
	var matched: int = c["matched"]
	var shots_sent: int = c["sent"]
	var aimed: int = c["aimed"]
	var hit: int = c["hit"]
	var first_miss: String = c["first_miss"]
	var worst_err: float = c["worst_err"]
	var mean_err: float = c["mean_err"]
	var tag := "%d ms %s" % [ping, weapon_id]
	_check(matched >= 2, "%s: the server resolves the shots" % tag, "%d of %d sent" % [matched, shots_sent])
	_check(_as_played or aimed == matched, "%s: every trace leaves the eye along the aim, to the wire's angle step" % tag, "%d of %d" % [aimed, matched])
	_check(hit == matched, "%s: every shot at the drawn torso hits, edges too" % tag, "%d of %d; %s" % [hit, matched, first_miss])
	_check(worst_err <= REWIND_TOLERANCE_M, "%s: the server rewinds the target to where it was drawn" % tag,
		"worst %.3f m, mean %.3f m" % [worst_err, mean_err])


## Distance from [param point] to the ray from [param origin] along [param dir].
static func _lateral(origin: Vector3, dir: Vector3, point: Vector3) -> float:
	var v := point - origin
	var t := maxf(0.0, v.dot(dir.normalized()))
	return (v - dir.normalized() * t).length()


static func angles_to(from: Vector3, to: Vector3) -> Vector2:
	var d := (to - from).normalized()
	return Vector2(rad_to_deg(atan2(-d.x, -d.z)), rad_to_deg(asin(d.y)))


## One server tick of the link; returns the command tick fired on, or -1.
## [param side] is where on the drawn torso the shot goes: -1 its left edge, 0 its middle, 1 its right edge.
func _step_once(slot: int, firing: bool, index: int, side: int) -> int:
	_step += 1
	var k := _step
	var fired := -1

	# What reached each client by now.
	var later: Array[Dictionary] = []
	for packet in _down:
		if int(packet["at"]) > k:
			later.append(packet)
			continue
		var targets: Array = _clients.keys() if int(packet["peer"]) == 0 else [int(packet["peer"])]
		for target in targets:
			if _clients.has(target):
				_clients[target]["bridge"].receive_snapshot(packet["bytes"])
	_down = later

	# The clocks where a client would have them: the input runs ahead by the flight up and a
	# tick of margin, the receive timeline is the newest snapshot that can have arrived.
	var input_tick := k + _lead_ticks()
	for peer_id: int in _clients:
		var clock: DotNetClock = _clients[peer_id]["net"].clock
		clock.tick = input_tick
		clock._received_tick = k - _down_ticks
		clock._receive_slip = 0.0
		clock._slip = 0.0

	for peer_id: int in _clients:
		var entry: Dictionary = _clients[peer_id]
		var move := DotFpsCommand.new()
		var fire := DotWeaponCommand.new()
		fire.slot = slot
		if peer_id == TARGET_PEER:
			move.move = _target_move(index)
			# As bots do at range: down while shooting, up again; [constant CROUCH_TICKS] drifts across the taps.
			move.set_button(DotFpsCommand.BUTTON_CROUCH, _as_played and (index / CROUCH_TICKS) % 2 == 1)
		elif not _last_frame.is_empty():
			var me: ArenaPlayer = (entry["game"] as ArenaGame).player_for(SHOOTER)
			var muzzle := me.muzzle_position()
			var centre: Vector3 = _last_frame["point"]
			var across := (centre - muzzle).cross(Vector3.UP).normalized()
			var point := centre + across * float(side) * (TORSO_RADIUS * ArenaPlayerTunables.body_scale() - EDGE_MARGIN_M)
			var aim := angles_to(muzzle, point)
			_last_frame["aimed"] = point
			move.yaw = aim.x
			move.pitch = aim.y
			fire.yaw = aim.x
			fire.pitch = aim.y
			if _as_played:
				fire.set_button(ArenaPlayer.BUTTON_AIM, true)
			if firing:
				fire.set_button(DotWeaponCommand.BUTTON_ATTACK, true)
		var bridge: ArenaNetBridge = entry["bridge"]
		bridge.client_tick(input_tick, move, fire)
		var packet := bridge.encode_input(input_tick, move, fire)
		var lands := _up_at(k)
		if lands >= 0:
			_up.append({"at": lands, "peer": peer_id, "bytes": packet})
		if peer_id == SHOOTER_PEER and firing and not _last_frame.is_empty():
			fired = input_tick
			var seen := _last_frame.duplicate()
			seen["point"] = seen["aimed"]
			seen["muzzle"] = (entry["game"] as ArenaGame).player_for(SHOOTER).muzzle_position()
			seen["side"] = side
			seen["lag"] = float(bridge._lag_for_q) * 0.25
			seen["drawn_tick"] = bridge._drawn_tick
			seen["sent_bracket"] = Vector2i(input_tick - bridge._back_for, input_tick - bridge._back_for + bridge._span_for) \
				if bridge._back_for >= 0 else Vector2i(-1, -1)
			_drawn_for[input_tick] = seen

	var still: Array[Dictionary] = []
	for packet in _up:
		if int(packet["at"]) > k:
			still.append(packet)
			continue
		_server_bridge.receive_input(int(packet["peer"]), packet["bytes"])
	_up = still
	_server_game.combat.health_of(_target).health = 1.0e7
	_server_game.combat.health_of(SHOOTER).health = 1.0e7
	_server_bridge.server_tick(k)

	# The frame on the shooter's screen until the next tick reads the mouse.
	var net: DotNetManager = _clients[SHOOTER_PEER]["net"]
	if net.clock.is_synced():
		var alpha: float = ALPHAS[k % ALPHAS.size()]
		(_clients[SHOOTER_PEER]["bridge"] as ArenaNetBridge).draw_frame(alpha)
		var drawn: ArenaPlayer = (_clients[SHOOTER_PEER]["game"] as ArenaGame).player_for(_target)
		_last_frame = {
			"feet": drawn.global_position,
			"point": drawn.global_position + Vector3.UP * TORSO_HEIGHT * ArenaPlayerTunables.body_scale() * _stance_scale(drawn),
			"time": float(net.clock.received_tick()) + alpha - net.interpolator.delay_ticks(),
			"alpha": alpha,
			"crouch": drawn.controller.state.crouch_fraction,
			"newest": net._receiving_tick,
			"bracket": net.interpolator.bracket_at(float(net.clock.received_tick()) + alpha - net.interpolator.delay_ticks()),
			"eased": _ease_offset(net, _clients[SHOOTER_PEER]["bridge"]),
		}
	return fired


# --- The link, overridden by headless_hitreg_chaos ----------------------------

## The step a snapshot sent now lands on the clients, or -1 when it is lost.
func _down_at() -> int:
	return _step + _down_ticks


## The step an input packet sent on step [param k] reaches the server, or -1 when it is lost.
func _up_at(k: int) -> int:
	return k + _up_ticks


## How far the input clock runs ahead of the server: the flight up and a tick of margin.
func _lead_ticks() -> int:
	return _up_ticks + 1


## How far the interpolator's resume ease ([method DotNetInterpolator._ease_resume]) moved the drawn
## target off its blend this frame, in metres: what is left of the jump out of an extrapolation. The
## server rewinds to the blend; it cannot know this offset (and must not take one from a client).
func _ease_offset(net: DotNetManager, bridge: ArenaNetBridge) -> float:
	var behaviour: DotNetBehaviour = bridge._behaviours.get(_target)
	if behaviour == null or behaviour.identity == null:
		return 0.0
	var track: Variant = net.interpolator._tracks.get(behaviour.identity.net_id)
	if track == null:
		return 0.0
	var most := 0.0
	for property: Variant in track.offsets:
		var offset: Variant = track.offsets[property]
		if offset is Vector3:
			most = maxf(most, (offset as Vector3).length())
	return most


## Peer 3's stick on step [param index]: across, turning every 30 ticks (and at the shooter when played).
func _target_move(index: int) -> Vector2:
	return Vector2(1.0 if (index / 30) % 2 == 0 else -1.0, -1.0 if _as_played else 0.0)


## How far the drawn body is squeezed down by its stance: [method ArenaPlayer.fit_hitboxes_to_stance]'s factor.
static func _stance_scale(player: ArenaPlayer) -> float:
	var t := player.controller.tunables
	return lerpf(1.0, t.crouch_height / maxf(t.stand_height, 0.01), clampf(player.controller.state.crouch_fraction, 0.0, 1.0))


func _on_resolved(shot: DotShot) -> void:
	if shot.attacker != SHOOTER:
		return
	var hit := false
	for d: DotDamage in shot.damages:
		if d.victim == _target and not d.refused:
			hit = true
	# The tap this is: a late shot (ArenaNetBridge.take_late_fire) fires on a later tick than its
	# command's, so it is the newest tap not yet resolved within the late-fire window before it.
	var tap := shot.tick
	if not _drawn_for.has(tap):
		var done := {}
		for r in _resolved:
			done[int(r["tick"])] = true
		tap = -1
		for t: int in _drawn_for:
			if t < shot.tick and t >= shot.tick - ArenaNetBridge.LATE_FIRE_MAX_TICKS and not done.has(t) and t > tap:
				tap = t
	# Where the server stood the target for this shot: as its rewind left it, else its ring now.
	var error := INF
	var seen: Dictionary = _drawn_for.get(tap, {})
	if not seen.is_empty():
		var rewound: Variant = _stood if _stood != null else _server_game.unlag_position_at(_target, float(shot.tick) - float(seen["lag"]))
		if rewound != null:
			error = (rewound as Vector3).distance_to(seen["feet"])
	_stood = null
	_resolved.append({"tick": tap, "fired": shot.tick, "origin": shot.origin, "direction": shot.direction,
		"pellets": shot.pellets.duplicate(), "hit": hit, "rewind_error": error, "view": _stood_view, "blended": _stood_blended,
		"crouch": _server_game.player_for(_target).controller.state.crouch_fraction,
		"victims": shot.damages.map(func(d: DotDamage) -> int: return d.victim), "impacts": shot.impacts.duplicate()})
