extends "arena_client_view.gd"
## The solo client's offline bots, split out of [ArenaClient] so that file stays under the size gate.


## The offline bots: the brain a server's bots run (ArenaBots, dot-bot), with the same
## `bot_difficulty`. Offline only; a server's bots are the server's.
##
## [b]Not the test fixture any more.[/b] This used to face the nearest player through any
## wall and hold the trigger under 40 m -- `headless_match`'s aimbot -- and a first play test
## died twelve times in ninety seconds to it. See ArenaBots.
func _drive_bots() -> void:
	var tick := game.current_tick()
	for id in _bots:
		var bot: ArenaPlayer = _bots[id]

		# A tool or suite that stages a bot (tools/screenshot_weapons.gd, headless_feel)
		# writes its `bot_move` and `bot_fire` itself; driving it here as well would
		# overwrite them every tick.
		if bot.get_meta(&"bot_scripted", false):
			continue

		var mind: ArenaBots.Mind = _bot_minds.get(id)
		if mind == null:
			mind = ArenaBots.Mind.new()
			mind.seed = int(id)
			_bot_minds[id] = mind
		var made := ArenaBots.think(game, bot, mind, tick, float(game.tick_rate))
		bot.set_meta("bot_move", made[0])
		bot.set_meta("bot_fire", made[1])


## Adds or removes offline bots until there are [param count], named from dot-bot's pool.
func _keep_offline_bots(count: int) -> void:
	var taken: Array = []
	for p in game.players():
		taken.append(p.display_name)
	var ids: Array = _bots.keys()
	var _kept := _bot_roster.keep(count, ids, _add_offline_bot, _remove_offline_bot, taken)


func _add_offline_bot(bot_name: String) -> int:
	var id := _next_bot_id
	_next_bot_id += 1
	var bot := game.add_player(id, bot_name)
	if not bot.ok:
		return 0
	var body := bot.value as ArenaPlayer
	# A stock avatar, deterministic in the id, so an offline bot looks the same every launch
	# and different from the bot beside it.
	body.attach_body_mesh(
		Color.from_hsv(float(id - 100) / 6.0, 0.55, 0.85),
		ArenaAvatars.stock_avatar(StringName(ArenaGame.storage_key(body.player_id)))
	)
	_bots[body.player_id] = body
	return id


func _remove_offline_bot(id: int) -> void:
	_bots.erase(id)
	_bot_minds.erase(id)
	ArenaBots.forget(game, id)
	game.remove_player(id)


## How many bots a solo launch starts with: `-- --bots N`, else [member offline_bots].
func _launch_bots() -> int:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--bots")
	if index >= 0 and index + 1 < args.size() and args[index + 1].is_valid_int():
		return clampi(args[index + 1].to_int(), 0, 15)
	return offline_bots


## `bot_difficulty` and every `bot_*` setting at the solo console, the names a server has;
## `bot_quota` too, counted the server's way (people + bots). `-- --bot_difficulty hard` at
## launch picks the preset before the first bot thinks.
func _bind_bot_console() -> void:
	var settings := DotBotSettings.of(game)
	var args := OS.get_cmdline_user_args()
	var index := args.find("--bot_difficulty")
	if index >= 0 and index + 1 < args.size():
		DotLog.result(CHANNEL, "bot difficulty from the command line", settings.set_difficulty(args[index + 1]))
	elif presentation != null and presentation.settings != null:
		# The menu's saved pick (General, Solo bots), and again whenever it is changed there.
		DotLog.result(CHANNEL, "bot difficulty from the settings", settings.set_difficulty(presentation.settings.get_string(&"solo_bot_difficulty", "medium")))
	if presentation != null and presentation.settings != null and not presentation.settings.changed.is_connected(_on_solo_bot_setting):
		presentation.settings.changed.connect(_on_solo_bot_setting)

	if presentation == null or presentation.local_console == null:
		return
	var local := presentation.local_console
	var _bound := settings.bind_console(local)
	var _crosshair_bound := game.combat_feel.bind_console(local, hud.crosshair if hud != null else null)
	local.add_var(&"bot_quota", "Players in a solo match, you included; the rest are bots (0 to 16).",
		func() -> Variant: return _bots.size() + 1,
		func(v: Variant) -> Variant:
			var text := str(v).strip_edges()
			if not text.is_valid_int():
				return DotResult.fail(DotError.CODE_INVALID, "bot_quota takes a number")
			_keep_offline_bots(DotBotRoster.solo_wanted(clampi(text.to_int(), 0, 16)))
			return DotResult.success(_bots.size() + 1)
	)


## The menu's Bot difficulty (General, Solo bots) onto this match's bots, as it is changed.
## A method rather than a lambda, so the connection goes when the client does.
func _on_solo_bot_setting(key: StringName, value: Variant, _why: StringName) -> void:
	var settings := DotBotSettings.of(game) if game != null else null
	if key == &"solo_bot_difficulty" and settings != null and str(value) != settings.difficulty():
		DotLog.result(CHANNEL, "bot difficulty from the menu", settings.set_difficulty(str(value)))
