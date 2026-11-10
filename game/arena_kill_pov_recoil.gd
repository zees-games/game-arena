extends RefCounted

## The killer's recoil in a killcam, shot by shot: every round the recorded fire count moved by kicks the replay camera as it kicked the killer's, climbing along a burst and settling once the trigger was let go.
## The recorded look is the killer's aim, which carries none of the live camera's recoil, so without this a killcam showed a still crosshair under a full-auto burst. A frame can see several rounds, and a mirrored killer records no kick,
## so the pattern is rebuilt from the weapon's own tuning with the server's sv_recoil_* rules, the same function the bullets followed.

const KillPov := preload("arena_kill_pov.gd")

## cl_killcam_recoil: how far the killer's recoil turns the killcam view; 0 holds it still, 1 as they saw it.
static var scale: float = 1.0

## The most rounds one frame may replay (a hitch, or a wrapped counter, is not a 4000-round burst).
const MAX_SHOTS := 8

## The server's recoil rules, or null for the weapon's flat kick.
var rules: DotWeaponRecoilRules = null
var catalogue: DotWeaponCatalogue = null
var tick_rate := 64

var _recoil := DotWeaponRecoil.new()
var _state := {}
var _id := &""
var _seq := -1.0
var _clock := 0.0


## The rounds fired since the last frame, one outcome each, in order; advances the replay clock by [param delta].
func shots(aux: PackedFloat32Array, delta: float) -> Array[DotWeaponOutcome]:
	_clock += maxf(delta, 0.0)
	var out: Array[DotWeaponOutcome] = []
	var id := KillPov.weapon_of(aux[KillPov.WEAPON])
	if id != _id:
		_id = id
		_state.clear()
	var seq := aux[KillPov.FIRE_SEQ]
	if _seq < 0.0 or seq == _seq:
		_seq = seq
		return out
	var n := mini((int(seq) - int(_seq) + 4096) % 4096, MAX_SHOTS)
	_seq = seq
	var b := _ballistics(id)
	var interval := _interval(id)
	var now := int(_clock * tick_rate)
	for i in n:
		out.append(_one(aux, id, b, now - (n - 1 - i) * interval))
	return out


func _one(aux: PackedFloat32Array, id: StringName, b: DotWeaponBallistics, tick: int) -> DotWeaponOutcome:
	var outcome := DotWeaponOutcome.new()
	outcome.used = true
	outcome.kind = DotWeaponOutcome.KIND_SHOT
	var flags := int(aux[KillPov.FLAGS])
	var recorded := Vector2(aux[KillPov.KICK_PITCH], aux[KillPov.KICK_YAW])
	if rules != null and b != null:
		var ctx := DotWeaponContext.new()
		ctx.tick = tick
		ctx.aiming = aux[KillPov.ADS] > 0.5
		ctx.crouched = flags & KillPov.CROUCHED != 0
		ctx.airborne = flags & KillPov.GROUNDED == 0 and aux[KillPov.SPEED] != 0.0
		ctx.speed = aux[KillPov.SPEED]
		var _bullet := rules.apply(outcome, b, _state, ctx, id, tick_rate)
		# The killer's own kick, when it was recorded, already holds the weapon's posture.
		if recorded != Vector2.ZERO and flags & KillPov.SIGNED != 0:
			outcome.recoil = recorded
	elif recorded != Vector2.ZERO:
		outcome.recoil = recorded
		outcome.recoil_signed = flags & KillPov.SIGNED != 0
	elif b != null:
		outcome.recoil = Vector2(b.recoil_pitch, b.recoil_yaw)
		outcome.recoil_recovery = b.recoil_recovery
	else:
		outcome.recoil = Vector2(0.5, 0.1)
	return outcome


## Adds one round's kick to the camera's share.
func kick(outcome: DotWeaponOutcome) -> void:
	_recoil.kick_outcome(outcome)


## Settles by [param delta] and returns the offset to add to the replay camera (x pitch up, y yaw, degrees),
## less [param pose_share], the part the view model's own spring already turns the camera by.
func step(delta: float, pose_share: float) -> Vector2:
	_recoil.advance(delta)
	var shown := _recoil.offset() * clampf(scale, 0.0, 5.0) * (1.0 - pose_share)
	return shown if shown.is_finite() else Vector2.ZERO


func offset() -> Vector2:
	return _recoil.offset()


func clear() -> void:
	_recoil = DotWeaponRecoil.new()
	_state.clear()
	_id = &""
	_seq = -1.0
	_clock = 0.0


func _ballistics(id: StringName) -> DotWeaponBallistics:
	if catalogue == null or id == &"" or not catalogue.has(id):
		return null
	var def := catalogue.get_def(id)
	return def.tuning as DotWeaponBallistics if def != null else null


func _interval(id: StringName) -> int:
	if catalogue == null or id == &"" or not catalogue.has(id):
		return 6
	var def := catalogue.get_def(id)
	return maxi(def.use_interval_ticks, 1) if def != null else 6
