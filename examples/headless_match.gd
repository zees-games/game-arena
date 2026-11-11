extends "headless_match_part11.gd"

func _run() -> void:
	print("game-fatal-contact headless match")
	print("")

	_test_content()
	_test_map()
	_test_map_look()
	_test_pit()
	await _test_atrium()
	_test_bot_ground_speed()
	_test_reach()
	_test_survey()
	await _test_collision_audit()
	await _test_crate_climb()
	_test_wall_routes()
	await _test_box_upper()
	_test_modes()
	await _test_team_deathmatch()
	await _test_pack_weapons()

	await _build()
	_build_vote()
	_test_players_exist()
	_test_wall_rules()
	await _play()
	_test_outcome()
	_test_score_vote()
	await _test_progression()
	_test_geometry_held()
	await _test_interface()

	await _test_horde()
	await _test_siege()
	await _test_freeze_countdown()

	await _test_effects()
	await _test_spectating()
	await _test_free_roam()
	await _test_ffa_spawn_sides()
	await _test_king_of_the_hill()
	await _test_capture_the_flag()
	await _test_drops()
	await _test_weapon_modes()
	await _test_lag_compensation()
	await _test_launch_inside_team_mate()
	await _test_streaks()
	_test_medal_rules()
	await _test_medals_from_a_game()
	await _test_toys()
	await _test_instant_loadout()

	# Last, and it has to be: it replaces the combat manager, the match node and the map, so
	# everything above that reads any of them (the kill feed.
	await _test_map_change()

	_check(_stats_errors.is_empty(), "the stats layer logged no error", str(_stats_errors))
	_check(ArenaStats.schema().validate().ok, "arena's stats schema, hitzones included, validates", str(ArenaStats.schema().validate().error))

	if _game != null:
		_game.queue_free()
		remove_child(_game)

	_report_sections(_entered, _completed, SECTIONS, CHECKS)

func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	DotLog.signals().record.connect(_on_log_record)
	_run.call_deferred()
