extends DotGameCheckSuite

const ArenaTouch := preload("../game/arena_touch.gd")

## The touch layout: the buttons fit a phone at three sizes without overlapping, and each DotTouchButtons is freed.
## Run: `godot --headless --path . res://examples/headless_touch.tscn`

const CHECKS := 14


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
	_report(CHECKS)
