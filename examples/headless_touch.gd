extends DotGameCheckSuite

const ArenaTouch := preload("../game/arena_touch.gd")

## The touch layout: the buttons fit a phone at three sizes without overlapping, and each DotTouchButtons is freed.
## Run: `godot --headless --path . res://examples/headless_touch.tscn`

const CHECKS := 8


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-arena: touch buttons")
	var sets: Dictionary = {"arena": ArenaTouch.LAYOUT}
	for label: String in sets:
		var layout: Array[Dictionary] = sets[label]
		var ids: Array[StringName] = []
		for b: Dictionary in layout:
			ids.append(b["id"])
		_check(ids.size() >= 4, "%s: the layout has its buttons" % label)
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
	DotPlatform.touch_override = 0
	var off := DotTouchButtons.new()
	add_child(off)
	_check(not off.visible, "no touch: the buttons are hidden")
	off.free()
	DotPlatform.touch_override = -1
	_report(CHECKS)
