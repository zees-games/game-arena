extends SceneTree

## Rewrites cfg/game/game-arena/config_*/game.yml from ArenaConfig's fields: godot --headless --path . --script tools/cfg_templates.gd

const ArenaConfig := preload("../game/arena_config.gd")


func _init() -> void:
	var binder := ArenaConfig.make_binder(ArenaConfig.new())
	var files := binder.template_files()
	for path: String in files:
		var res := DotPaths.write_text("res://" + path, files[path])
		print("%s %s" % ["wrote" if res.ok else "FAILED", path])
	quit()
