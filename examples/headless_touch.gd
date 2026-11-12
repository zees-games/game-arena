extends DotGameCheckSuite

const ArenaTouch := preload("../game/arena_touch.gd")
const TagRules := preload("../game/arena_name_tag_rules.gd")

## The touch layout fits a phone without overlapping; dot-mobile's overlay drives the sampler; auto-fire's crosshair holds fire on team-mates and the dead.
## Run: `godot --headless --path . res://examples/headless_touch.tscn`

const CHECKS := 27


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact: touch buttons")
	var sets: Dictionary = {"arena": ArenaTouch.LAYOUT}
	for label: String in sets:
		var layout: Array[Dictionary] = sets[label]
		var ids: Array[StringName] = []
		for b: Dictionary in layout:
			ids.append(b["id"])
		_check(ids.size() >= 4, "%s: the layout has its buttons" % label)
		var smallest := 999.0
		for b: Dictionary in layout:
			smallest = minf(smallest, float(b["radius"]))
		_check(smallest * 2.0 >= 44.0, "%s: every button is thumb size (44 px or more)" % label, str(smallest * 2.0))
		for size: Vector2 in [Vector2(844, 390), Vector2(667, 375), Vector2(932, 430)]:
			var buttons := DotTouchButtons.new()
			buttons.size = size
			buttons.set_buttons(layout)
			add_child(buttons)
			_check(Rect2(Vector2.ZERO, size).encloses(buttons.footprint()), "%s: the cluster fits %dx%d" % [label, size.x, size.y], str(buttons.footprint()))
			var clash := ""
			for i in ids.size():
				for j in range(i + 1, ids.size()):
					var gap := buttons.centre_of(ids[i]).distance_to(buttons.centre_of(ids[j])) - buttons.radius_of(ids[i]) - buttons.radius_of(ids[j])
					if gap < 4.0:
						clash = "%s and %s" % [ids[i], ids[j]]
			_check(clash == "", "%s: no two buttons overlap at %dx%d" % [label, size.x, size.y], clash)
			buttons.free()
	# A phone: 844x390 stretched to a 720-unit canvas, 0.54 real px per unit, so a 72-unit button is 39 px.
	var canvas := Vector2(1556, 720)
	var fit := DotGameScreenFit.button_scale_for(ArenaTouch.LAYOUT, 390.0 / 720.0, DotGameScreenFit.target_px_for(400.0), canvas)
	var fitted := DotTouchButtons.new()
	fitted.size = canvas
	fitted.set_buttons(ArenaTouch.LAYOUT)
	fitted.button_scale = fit
	add_child(fitted)
	_check(fit > 1.0, "phone fit: the buttons grow past the design", str(fit))
	_check(36.0 * 2.0 * fit * 390.0 / 720.0 >= 44.0 - 0.01, "phone fit: the smallest button is 44 real px across", str(fit))
	_check(Rect2(Vector2.ZERO, canvas).encloses(fitted.footprint()), "phone fit: the grown cluster still fits the canvas", str(fitted.footprint()))
	fitted.free()
	DotPlatform.touch_override = 0
	var off := DotTouchButtons.new()
	add_child(off)
	_check(not off.visible, "no touch: the buttons are hidden")
	off.free()
	DotPlatform.touch_override = -1
	var client_methods: Array = []
	for m: Dictionary in load("res://game/arena_client.gd").get_script_method_list():
		client_methods.append(m["name"])
	_check("touch_next_weapon" in client_methods and "_touch_held" in client_methods, "the split client carries the touch wiring")
	var drag := InputEventScreenDrag.new()
	drag.relative = Vector2(NAN, 3.0)
	var sampler := DotFpsTouchSampler.new(DotFpsTunables.new())
	sampler.handle_event(drag)
	var turned := sampler.sample(1.0 / 60.0)
	_check(is_finite(turned.yaw) and is_finite(turned.pitch), "a NaN touch drag leaves the look finite")
	_overlay()
	_crosshair()
	_report(CHECKS)


## A stand-in for a remote player: the members the crosshair test reads.
class Body extends Node3D:
	var player_id: int = 0
	var team: int = 0
	var alive: bool = true
	var body_mesh: Node3D = null

	func is_alive() -> bool:
		return alive

	static func stand_height() -> float:
		return 1.8


func _overlay() -> void:
	var rules: DotMobileRules = (load("res://game/arena_game_state.gd") as GDScript).call(&"_make_mobile_rules")
	var prefs := DotMobilePrefs.new()
	_check(rules.resolve(prefs, true).autofire, "auto-fire is on for a touch player by default")
	_check(not rules.resolve(prefs, false).autofire, "and off for keyboard and mouse")
	DotPlatform.touch_override = 1
	var host := Control.new()
	host.size = Vector2(844, 390)
	add_child(host)
	var sampler := DotFpsTouchSampler.new(DotFpsTunables.new())
	var touch: RefCounted = ArenaTouch.build(self, host, sampler, rules)
	var controls: DotMobileControls = touch.get(&"controls")
	_check(controls != null and controls.touch and controls.sampler == sampler, "the overlay drives the client's own sampler", str(touch.call(&"describe")))
	var tap := InputEventScreenTouch.new()
	tap.pressed = true
	var fake := InputEventMouseMotion.new()
	fake.device = InputEvent.DEVICE_ID_EMULATION
	_check(bool(touch.call(&"takes", tap)) and bool(touch.call(&"takes", fake)), "it takes touches and the mouse emulated from them")
	touch.call(&"sync", true, null)
	_check(not controls.visible and not bool(touch.call(&"active")), "a menu pauses it")
	touch.call(&"sync", false, null)
	_check(bool(touch.call(&"active")), "and closing the menu brings it back")
	host.free()
	DotPlatform.touch_override = -1


func _crosshair() -> void:
	TagRules.viewer_id = 1
	TagRules.viewer_team = 2
	var me := _body(1, 2, Vector3.ZERO)
	var enemy := _body(7, 3, Vector3(0, 0, -10))
	var eye := Vector3(0, 1.6, 0)
	var ahead := Vector3(0, 0, -1)
	var none := DotMobileAutoFire.TARGET_NONE
	var foe := DotMobileAutoFire.TARGET_ENEMY
	var friend := DotMobileAutoFire.TARGET_FRIEND
	_check(ArenaTouch.crosshair_kind(eye, ahead, me, [me, enemy], null, 0) == foe, "the crosshair on a living opponent is an enemy")
	_check(ArenaTouch.crosshair_kind(eye, Vector3(1, 0, 0), me, [me, enemy], null, 0) == none, "looking away is nothing")
	var mate := _body(4, 2, Vector3(0, 0, -5))
	_check(ArenaTouch.crosshair_kind(eye, ahead, me, [me, enemy, mate], null, 0) == friend, "a team-mate in front holds fire")
	mate.free()
	enemy.alive = false
	_check(ArenaTouch.crosshair_kind(eye, ahead, me, [me, enemy], null, 0) == friend, "the dead are never shot")
	enemy.alive = true
	TagRules.viewer_team = -1
	var other := _body(9, 2, Vector3(0, 0, -5))
	_check(ArenaTouch.crosshair_kind(eye, ahead, me, [me, enemy, other], null, 0) == foe, "without teams the nearest body is an enemy")
	_check(ArenaTouch.assist_targets(eye, ahead, me, [me, enemy, other], null, 0).size() == 2, "aim assist sees the living opponents near the crosshair")
	var crowd: Array = [me]
	for i in 31:
		crowd.append(_body(10 + i, 3, Vector3(float(i % 8) - 4.0, 0, -6.0 - float(i))))
	var reps := 200
	var t := Time.get_ticks_usec()
	for _r in reps:
		var _k := ArenaTouch.crosshair_kind(eye, ahead, me, crowd, null, 0)
	var each_ms := float(Time.get_ticks_usec() - t) / reps / 1000.0
	_check(each_ms < 0.1, "the crosshair query over 32 players is under 0.1 ms", "%.4f ms" % each_ms)
	for b: Node in crowd:
		b.free()
	enemy.free()
	other.free()
	TagRules.viewer_id = -1


func _body(id: int, team: int, at: Vector3) -> Body:
	var b := Body.new()
	b.player_id = id
	b.team = team
	add_child(b)
	b.global_position = at
	return b
