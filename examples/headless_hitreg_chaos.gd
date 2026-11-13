extends "headless_hitreg_ping.gd"

## Hit registration over a bad link: headless_hitreg_ping's server and two clients, with every
## packet given a seeded random jitter on top of half the round trip, and lost at a seeded 2%
## each way. Round trips of 30, 60 and 120 ms; peer 3 strafes as a bot does (ADAD, turns at
## random intervals, now and then a stop). Every tap is aimed at peer 3's torso where the
## shooter's screen drew it, middle and edges, with the gun's noise zeroed as in the ping suite,
## so the expected hit rate is 100% and every miss is the netcode's. Each miss is put down to
## one cause: the command never resolved, the frame was extrapolated past the newest snapshot,
## the frame was blended across a lost one, or the server's rewind stood the body elsewhere.
##
## Three links per round trip: clean; jitter and loss with the buffer the adaptive
## interpolator settles on for it (one snapshot period, the 95th percentile lateness and one
## period more for a loss); and jitter and loss with the shipped starting buffer of two
## snapshots, before it has grown. The input lead covers the jitter as DotNetClock's does.
## Deterministic: the clocks are placed by hand, the buffer is set rather than adapted (its
## arrival-gap estimate reads the wall clock), and every random draw is seeded.

const CHAOS_RTTS: Array[int] = [30, 60, 120]
const JITTER_MS := 30.0
const LOSS := 0.02
## name, jitter ms, loss, buffer in snapshots (-1: what the adaptive buffer settles on).
const LINKS: Array = [
	["clean", 0.0, 0.0, 2.0],
	["jitter+loss, buffer adapted", JITTER_MS, LOSS, -1.0],
	["jitter+loss, buffer 2 (not grown)", JITTER_MS, LOSS, 2.0],
]
const CHAOS_CHECKS := 532
const CHAOS_SECTIONS := 12
# A drawn body still this far off its interpolated spot is easing out of an extrapolation.
const EASED_M := 0.005

var _rng := RandomNumberGenerator.new()
var _move_rng := RandomNumberGenerator.new()
var _jitter_ticks := 0
var _loss := 0.0
var _link := ""
## The target's stick: [step index it starts on, Vector2 move], in order.
var _strafe: Array = []
## {link: {rtt: {weapon: [shots, hits, causes{}]}}}
var _table: Dictionary = {}
var _rewinds: Dictionary = {}
## Diagnostics: step -> [server tick then, step the input packet sent then lands on (-1 lost)].
var _ups: Dictionary = {}
## Up packets sent and lost this section, every peer.
var _ups_sent := 0
var _ups_lost := 0
## The late-tap section: the send step of each tap, and how many were sent.
var _late_mode := false
var _late_sends: Array[int] = []
var _late_sent := 0


func _run() -> void:
	print("game-fatal-contact headless hit registration over a jittery, lossy link")
	_build()
	var weapons := _hitscan_weapons()
	_check(weapons.size() >= 3, "the pack has hitscan guns to try", str(weapons))
	if "--late" in OS.get_cmdline_user_args():
		# Only the late-tap section, for the quick loop: `hv <wt> scene res://examples/headless_hitreg_chaos.tscn -- --late`.
		# A fresh match still has the target under spawn protection, which refuses the first shots: play a round first.
		_round(&"pistol", 6)
		_late_tap_section(weapons)
		_report_sections(_entered, _completed, 2, -1)
		return
	var net: DotNetManager = _clients[SHOOTER_PEER]["net"]
	var period := float(net.config.ticks_per_snapshot())
	print("    tick %d Hz, snapshots %d Hz (every %d ticks), input copies %d, max extrapolation %.3f s" % [
		TICK_RATE, net.config.snapshot_rate, int(period), ArenaNetBridge.INPUT_COPIES, net.config.max_extrapolation_sec])
	print("    server rewind: max_unlag %.0f ms, ring %.1f s, collision lag cap %.3f s" % [
		_server_game.max_unlag_ms, ArenaGame.UNLAG_SECONDS, ArenaGame.COLLISION_LAG_MAX_SEC])
	for link: Array in LINKS:
		for rtt in CHAOS_RTTS:
			_link = link[0]
			_jitter_ticks = int(roundf(float(link[1]) / 1000.0 * float(TICK_RATE)))
			_loss = link[2]
			var buffer: float = link[3]
			if buffer < 0.0:
				# The adaptive buffer's lateness rule: a period, the p95 lateness, a period for a loss.
				buffer = (period + float(_jitter_ticks) + (period if _loss > 0.0 else 0.0)) / period
			for peer_id: int in _clients:
				var interp: DotNetInterpolator = _clients[peer_id]["net"].interpolator
				interp._delay_snapshots = buffer
				interp._target_snapshots = buffer
			var total := int(roundf(float(rtt) / 1000.0 * float(TICK_RATE)))
			_section("%s, rtt %d ms: up %d down %d ticks, jitter 0-%d ticks, loss %.0f%%, lead %d ticks, interp %.2f snapshots (%.1f ticks)" % [
				_link, rtt, total / 2, total - total / 2, _jitter_ticks, _loss * 100.0, total / 2 + 1 + _jitter_ticks,
				buffer, buffer * period])
			_ups_sent = 0
			_ups_lost = 0
			for id in weapons:
				_ups.clear()
				_rng.seed = hash([_link, rtt, String(id)])
				_move_rng.seed = hash([rtt, String(id)])
				_plan_strafe()
				_round(id, rtt)
			print("    up packets lost: %d of %d (%.1f%%)" % [_ups_lost, _ups_sent, 100.0 * float(_ups_lost) / float(maxi(1, _ups_sent))])
			_done()
	_summary(weapons)
	_late_tap_section(weapons)
	_report_sections(_entered, _completed, CHAOS_SECTIONS, CHAOS_CHECKS if CHAOS_CHECKS > 0 else -1)


## Taps whose every early copy is lost and whose one surviving copy lands after the server has
## simulated the tick, as at tick 26660 of the 60 ms jitter+loss link: the copies sent with the tap
## and the two steps after are lost, the fourth lands two ticks after the tap's tick, the fifth is
## lost. The shooter drew each and the server must fire it, with the rewind of the shooter's view.
func _late_tap_section(weapons: Array[StringName]) -> void:
	var id: StringName = &"pistol" if &"pistol" in weapons else weapons[0]
	_section("a tap whose only surviving copy lands late (%s, 60 ms, clean link otherwise)" % id)
	_late_mode = true
	_late_sends.clear()
	_link = "clean"
	_jitter_ticks = 0
	_loss = 0.0
	for peer_id: int in _clients:
		var interp: DotNetInterpolator = _clients[peer_id]["net"].interpolator
		interp._delay_snapshots = 2.0
		interp._target_snapshots = 2.0
	var honoured := _late_counter("late_fire_honoured")
	var dropped := _late_counter("late_fire_dropped")
	_round(id, 60)
	_late_mode = false
	var buffer := _server_net.input_buffer_for(SHOOTER_PEER)
	print("    late shots fired %d, dropped %d; the input buffer counted %d late" % [
		_late_counter("late_fire_honoured") - honoured, _late_counter("late_fire_dropped") - dropped, buffer.late_count])
	_check(_late_counter("late_fire_honoured") - honoured == _late_sent, "every late tap is fired by the server and counted",
		"%d of %d" % [_late_counter("late_fire_honoured") - honoured, _late_sent])
	_done()


func _late_counter(counter: StringName) -> int:
	var value: Variant = _server_bridge.get(counter)
	return 0 if value == null else int(value)


func _judge_late(weapon_id: StringName, c: Dictionary) -> void:
	_late_sent = int(c["sent"])
	var hits := 0
	for r in _resolved:
		if r["hit"]:
			hits += 1
	_check(_resolved.size() == _late_sent, "%s: a tap that arrived late still resolves once" % weapon_id,
		"%d resolved of %d sent" % [_resolved.size(), _late_sent])
	_check(hits == _resolved.size(), "%s: and hits where the shooter drew the target (lag compensated)" % weapon_id,
		"%d of %d hit" % [hits, _resolved.size()])


func _step_once(slot: int, firing: bool, index: int, side: int) -> int:
	if _late_mode and firing:
		_late_sends.append(_step + 1)
	return super(slot, firing, index, side)


func _plan_strafe() -> void:
	_strafe.clear()
	var at := 0
	var dir := 1.0
	while at < SETTLE_TICKS + TAPS * PLAYED_TAP_TICKS + 200:
		var stop := _move_rng.randf() < 0.15
		_strafe.append([at, Vector2(0.0 if stop else dir, 0.0)])
		at += _move_rng.randi_range(4, 12) if stop else _move_rng.randi_range(8, 40)
		if not stop:
			dir = -dir


func _target_move(index: int) -> Vector2:
	var move := Vector2.ZERO
	for leg: Array in _strafe:
		if int(leg[0]) > index:
			break
		move = leg[1]
	return move


func _flight() -> int:
	if _loss > 0.0 and _rng.randf() < _loss:
		return -1
	return _rng.randi_range(0, _jitter_ticks) if _jitter_ticks > 0 else 0


func _down_at() -> int:
	var f := _flight()
	return -1 if f < 0 else _step + _down_ticks + f


func _up_at(k: int) -> int:
	if _late_mode:
		for f in _late_sends:
			var d: int = k - f
			if d == 3:
				return f + _lead_ticks() + 2
			if d >= 0 and d <= 4:
				return -1
		return k + _up_ticks
	var f := _flight()
	var lands := -1 if f < 0 else k + _up_ticks + f
	_ups_sent += 1
	if lands < 0:
		_ups_lost += 1
	_ups.get_or_add(k, []).append([_server_game.current_tick(), lands])
	return lands


func _lead_ticks() -> int:
	# DotNetClock: the flight up, and the larger of the margin and the jitter plus a tick.
	return _up_ticks + 1 + _jitter_ticks


func _judge(weapon_id: StringName, ping: int, c: Dictionary) -> void:
	if _late_mode:
		_judge_late(weapon_id, c)
		return
	var causes := {"unresolved": int(c["sent"]) - int(c["matched"])}
	var period := float((_clients[SHOOTER_PEER]["net"] as DotNetManager).config.ticks_per_snapshot())
	var errs: Array = _rewinds.get_or_add(_link, {}).get_or_add(ping, [])
	# The worst rewind of a frame the client drew between two snapshots it held, within the span a
	# shot is blended across: the server must stand the body where that frame drew it. Not a frame
	# still easing out of an extrapolation (DotNetInterpolator._ease_resume): that offset is the
	# client's alone, up to resume_ease_max (6 m), and a server that took it from the command
	# would let a client move hitboxes.
	var worst_blend := 0.0
	var blend_at := -1
	var blend_how := ""
	for r in _resolved:
		var seen: Dictionary = _drawn_for.get(int(r["tick"]), {})
		if seen.is_empty():
			continue
		errs.append(float(r["rewind_error"]))
		var held: Vector2i = seen["bracket"]
		if float(seen["time"]) <= float(seen["newest"]) and held.x >= 0 and held.y - held.x <= ArenaNetBridge.SHOT_BRACKET_MAX_SPAN \
				and float(seen.get("eased", 0.0)) <= EASED_M and float(r["rewind_error"]) > worst_blend:
			worst_blend = float(r["rewind_error"])
			blend_at = int(r["tick"])
			blend_how = "; drawn at %.2f in %s, sent %s, rewound to %.2f, %s" % [float(seen.get("drawn_tick", -1.0)), seen["bracket"],
				seen.get("sent_bracket", Vector2i(-1, -1)), float(r.get("view", -1.0)), "blended" if r.get("blended", false) else "the ring"]
			blend_how += ", eased %.3f m" % float(seen.get("eased", 0.0))
		if r["hit"]:
			continue
		var bracket: Vector2i = seen["bracket"]
		var cause := "rewind %.3f m" % float(r["rewind_error"])
		if float(seen["time"]) > float(seen["newest"]):
			cause = "extrapolated"
		elif float(seen.get("eased", 0.0)) > EASED_M:
			cause = "easing out of an extrapolation"
		elif float(bracket.y - bracket.x) > period:
			cause = "blend across a lost snapshot"
		elif float(r["rewind_error"]) <= REWIND_TOLERANCE_M:
			cause = "rewound right, side %d" % int(seen["side"])
		else:
			cause = "rewind off"
		causes[cause] = int(causes.get(cause, 0)) + 1
	_table.get_or_add(_link, {}).get_or_add(ping, {})[weapon_id] = [int(c["sent"]), int(c["hit"]), causes, int(c["matched"])]
	var tag := "%s %d ms %s" % [_link, ping, weapon_id]
	_check(int(c["matched"]) >= 2, "%s: the server resolves the shots" % tag, "%d of %d sent" % [c["matched"], c["sent"]])
	# A miss from a gap in the rewind ring is the harness's own (a match that ended mid-round
	# stood the target on a spawn once), never the network's: the ring is two seconds deep.
	_check(float(c["worst_err"]) < INF, "%s: every shot finds the target in the rewind history" % tag, "worst %.3f m" % float(c["worst_err"]))
	# The ring's own tick is not the drawn body: at a strafe reversal the blend of two snapshots cut
	# the corner by up to 12 cm, and edge shots missed (ArenaNetBridge.shot_feet).
	_check(worst_blend <= REWIND_TOLERANCE_M, "%s: the server rewinds each shot to the body the shooter drew" % tag,
		"worst %.3f m at tick %d%s" % [worst_blend, blend_at, blend_how])
	if _link == "clean":
		_check(int(c["hit"]) == int(c["matched"]), "%s: every shot at the drawn torso hits" % tag, "%d of %d; %s" % [c["hit"], c["matched"], c["first_miss"]])
	if c["first_miss"] != "":
		print("      causes %s" % str(causes))
	# Each miss and each tap the server never resolved, with where the server's trace went and
	# what became of the packets that carried its command.
	var done := {}
	for r in _resolved:
		done[int(r["tick"])] = true
		var seen: Dictionary = _drawn_for.get(int(r["tick"]), {})
		if seen.is_empty() or r["hit"]:
			continue
		var want := angles_to(seen["muzzle"], seen["point"])
		var got := angles_to(Vector3.ZERO, r["direction"])
		print("      miss at tick %d: aimed %s, traced %s, origin %.3f m off; drawn at %.2f, newest snapshot %d, bracket %s" % [
			int(r["tick"]), want, got, (r["origin"] as Vector3).distance_to(seen["muzzle"]), float(seen["time"]),
			int(seen["newest"]), seen["bracket"]])
		_print_carriers(int(r["tick"]))
	for t: int in _drawn_for:
		if not done.has(t):
			print("      unresolved tap at tick %d" % t)
			_print_carriers(t)


## The shooter's packets that carried the command for [param t]: the step each was sent, the server's tick then, the step it landed (-1 lost).
func _print_carriers(t: int) -> void:
	var at := _clients.keys().find(SHOOTER_PEER)
	var k0 := t - _lead_ticks()
	var line := "        carried by:"
	for k in range(k0, k0 + ArenaNetBridge.INPUT_COPIES):
		var sent: Array = _ups.get(k, [])
		if at < sent.size():
			line += " step %d (server tick %d) lands %d;" % [k, int(sent[at][0]), int(sent[at][1])]
	print(line)


func _summary(weapons: Array[StringName]) -> void:
	_section("hit rate against 100% expected")
	var header := "    %-34s %-16s" % ["link", "weapon"]
	for rtt in CHAOS_RTTS:
		header += "  %7d ms" % rtt
	print(header)
	for link: Array in LINKS:
		var totals := {}
		for id in weapons:
			var line := "    %-34s %-16s" % [link[0], id]
			for rtt in CHAOS_RTTS:
				var row: Array = _table[link[0]][rtt].get(id, [0, 0, {}, 0])
				line += "  %4d/%-5d" % [row[1], row[0]]
				var t: Array = totals.get_or_add(rtt, [0, 0, {}, 0])
				t[0] += int(row[0])
				t[1] += int(row[1])
				t[3] += int(row[3])
				for cause: String in row[2]:
					t[2][cause] = int(t[2].get(cause, 0)) + int(row[2][cause])
			print(line)
		var all := "    %-34s %-16s" % [link[0], "ALL"]
		for rtt in CHAOS_RTTS:
			var t: Array = totals[rtt]
			all += "  %5.1f%%    " % (100.0 * float(t[1]) / float(maxi(1, t[0])))
		print(all)
		for rtt in CHAOS_RTTS:
			var errs: Array = _rewinds[link[0]][rtt]
			errs.sort()
			var p50: float = errs[errs.size() / 2] if not errs.is_empty() else 0.0
			var worst: float = errs.back() if not errs.is_empty() else 0.0
			print("      %d ms: misses by cause %s; rewind error p50 %.3f worst %.3f m" % [rtt, str(totals[rtt][2]), p50, worst])
			if link[0] == "clean":
				# Resolved, not sent: a tap lost on a lossy link is counted by "unresolved". (The burst
				# rifle's "10 of 12" was its magazine: twelve bursts are 36 rounds of 30; it taps ten now.)
				_check(int(totals[rtt][1]) == int(totals[rtt][3]), "clean %d ms: every resolved shot hits" % rtt,
					"%d of %d" % [totals[rtt][1], totals[rtt][3]])
	_done()
