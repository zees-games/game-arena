extends DotKillViewServer

## The kill view's server over FC: [member eyes_fn] is asked only for the eyes the ring would keep.
##
## The ring keeps a sample per [member DotKillViewRules.record_hz] (30) and the tick is 66, so two in three of
## the eyes built every tick (a dictionary, a basis, a transform, the fov and the aux floats, per living
## player) were refused by [method DotKillViewRing.record] on its rate check. [member due] is that same
## check, asked before the eye is built: what the ring holds is unchanged, sample for sample.

## The rate check the eyes ask. Its own object so the [member eyes_fn] closure holding it holds no
## reference back to this server (a cycle a RefCounted never frees).
var due: Due = null


func _init(p_rules: DotKillViewRules = null) -> void:
	super(p_rules)
	due = Due.new(ring)


func record(time: float) -> void:
	due.now = time
	due.recording = true
	super.record(time)
	due.recording = false


func forget(id: Variant) -> void:
	due.last.erase(id)
	super.forget(id)


## [method DotKillViewRing.record]'s rate check, before the sample is built.
class Due:
	extends RefCounted

	## Off asks for every eye every tick and lets the ring refuse, as before: headless_bot_pull holds
	## the two to the same samples.
	static var ask_due_only := true

	## The time of the [method record] call in progress.
	var now: float = 0.0
	## True only inside [method record]: anyone else asking [member eyes_fn] (a test, a probe) gets every eye.
	var recording := false
	## The time each id's eye was last handed to the ring.
	var last: Dictionary = {}
	var _ring: DotKillViewRing = null

	func _init(p_ring: DotKillViewRing) -> void:
		_ring = p_ring

	## Whether the ring takes a sample of [param id] at [member now]. An id with no samples (new,
	## forgotten, cleared, or refused for a full table) is always asked, and the ring decides.
	func check(id: Variant) -> bool:
		if not ask_due_only or not recording:
			return true
		if _ring.sample_count(id) == 0 or not last.has(id):
			last[id] = now
			return true
		if now - float(last[id]) < 1.0 / _ring.rules.record_hz - 0.0001:
			return false
		last[id] = now
		return true
