extends RefCounted

## The camera's half of the recoil: the kick each of the local player's shots turns the view by, piling up along a burst and settling once the trigger is let go. Same numbers as the bullet, so no desync:
## the server offsets each bullet by the kick left from earlier shots (DotWeaponRecoilRules, sv_recoil_*); this adds the kick of the same outcomes, decaying at the same recovery rate, to the camera.
## Presentation only: added where the camera is written, never to the command. Fed by the rig's used signal, which is silent while a correction replays, so a reconciliation never kicks twice.

## cl_recoil_view: multiplies the drawn kick. 0 keeps the crosshair still (the bullets still climb), 1 is the profile's.
static var scale: float = 1.0

## The part of the climb the camera takes from this node: the weapon pose's own spring (AwWeaponPose view_camera_share,
## 0.3) already turns the camera by that share of every shot, so adding the rest keeps the view's total at the
## bullet's climb instead of doubling it.
const POSE_SHARE := 0.3

## Most pitch the burst may pile up, in degrees.
var max_pitch: float = 30.0

var _recoil := DotWeaponRecoil.new()


func _init() -> void:
	_recoil.max_pitch = max_pitch


## One shot's outcome; a melee swing or a beam without recoil leaves the view alone.
func kick(outcome: DotWeaponOutcome) -> void:
	if outcome == null:
		return
	_recoil.max_pitch = max_pitch
	_recoil.kick_outcome(outcome)


## Settles by delta seconds and returns the offset to add to the camera (x pitch up, y yaw, degrees).
## A dead player's kick is dropped.
func step(delta: float, alive: bool = true) -> Vector2:
	if not alive:
		clear()
		return Vector2.ZERO
	_recoil.advance(delta)
	var shown := _recoil.offset() * clampf(scale, 0.0, 5.0) * (1.0 - POSE_SHARE)
	return shown if shown.is_finite() else Vector2.ZERO


func offset() -> Vector2:
	return _recoil.offset()


func clear() -> void:
	_recoil = DotWeaponRecoil.new()
	_recoil.max_pitch = max_pitch
