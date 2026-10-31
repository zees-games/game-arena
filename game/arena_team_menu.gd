extends RefCounted

const ArenaGame := preload("arena_game.gd")
const CHANNEL := "arena.teams"
## Colours for the sides past the stock pair, and for any a config names without a colour.
const PALETTE: PackedStringArray = ["#d94040", "#4073e6", "#40b85a", "#e6c040", "#a050d0", "#e68a30", "#40c8c8", "#d060a0"]
const NAMES: PackedStringArray = ["Red", "Blue", "Green", "Yellow", "Purple", "Orange", "Teal", "Pink"]
const MAX_TEAMS := 8
const TeamMenuServer := preload("res://addons/dot_team/runtime/dot_team_menu_server.gd")

## dot-team's menu rules; the adapters below are what make it arena's.
var server: RefCounted = TeamMenuServer.new()
var game: ArenaGame = null
var names_cvar: DotConVar = null
var colours_cvar: DotConVar = null
var max_cvar: DotConVar = null


## Binds `mp_teamswitch_*` and the team layout cvars (`mp_team_names`, `mp_team_colours`, `mp_team_max`), then wires the server to [param p_game].
func bind(p_game: ArenaGame, add: Callable, host: Object) -> void:
	game = p_game
	var flags := DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	var _switch: Variant = server.bind_cvars(add, flags)
	names_cvar = add.call("mp_team_names", "", "Team names, comma separated (Red,Blue,Green); more names than the mode has teams adds teams, up to 8", flags)
	colours_cvar = add.call("mp_team_colours", "", "Team colours as #rrggbb, comma separated, in the same order as mp_team_names", flags)
	max_cvar = add.call("mp_team_max", "0", "Most players on one team (0 for no limit)", flags)
	for cv: DotConVar in [names_cvar, colours_cvar, max_cvar]:
		if cv != null:
			cv.changed.connect(apply_layout.unbind(2))
	server.teams_fn = rows
	server.state_fn = state
	server.join_fn = join
	server.spectate_fn = func(key: Variant) -> DotResult: return set_spectating(int(key), true)
	server.play_fn = func(key: Variant) -> DotResult: return set_spectating(int(key), false)
	server.window_fn = func(_key: Variant) -> bool:
		return game.match_node == null or not game.match_node.is_live()
	server.clock_fn = func() -> float: return float(game._tick) / maxf(1.0, float(game.tick_rate))
	var _installed: Variant = server.install(host)
	apply_layout()


## Drops the callables that point back at this object, so the menu and its server can be freed.
func release() -> void:
	for cv: DotConVar in [names_cvar, colours_cvar, max_cvar]:
		if cv != null and cv.changed.is_connected(apply_layout.unbind(2)):
			cv.changed.disconnect(apply_layout.unbind(2))
	server.release()
	game = null


## Renames, recolours, resizes and (with more names than sides) adds teams; live, from the cvars.
func apply_layout() -> void:
	if game == null or game.match_node == null or game.match_node.teams == null:
		return
	var manager: DotTeamManager = game.match_node.teams
	var wanted: PackedStringArray = _list(names_cvar)
	var colours: PackedStringArray = _list(colours_cvar)
	var count := mini(MAX_TEAMS, maxi(manager.teams.size(), wanted.size()))
	var limit := int(max_cvar.get_string()) if max_cvar != null and max_cvar.get_string().is_valid_int() else 0
	while manager.teams.size() < count:
		var index := manager.teams.size()
		manager.teams.append(DotTeam.make(index + 1, NAMES[index], Color.html(PALETTE[index])))
	for index in manager.teams.size():
		var team := manager.teams[index]
		if team.is_spectator:
			continue
		team.display_name = wanted[index] if index < wanted.size() and wanted[index] != "" else NAMES[index]
		team.abbreviation = team.display_name.substr(0, 3).to_upper()
		team.colour = Color.html(colours[index]) if index < colours.size() and Color.html(colours[index]) != Color() else Color.html(PALETTE[index])
		team.max_players = maxi(0, limit)
	manager.reindex()


static func _list(cv: DotConVar) -> PackedStringArray:
	var out := PackedStringArray()
	if cv == null or cv.get_string().strip_edges() == "":
		return out
	for part in cv.get_string().split(","):
		out.append(part.strip_edges())
	return out


## One row per playing team: `{id, name, colour, count, max}`; empty in a free-for-all.
func rows() -> Array:
	var out: Array = []
	if game == null or game.match_node == null or game.match_node.teams == null:
		return out
	var manager: DotTeamManager = game.match_node.teams
	for team in manager.teams:
		if team.is_spectator:
			continue
		out.append({"id": team.id, "name": team.display_name, "colour": team.colour.to_html(false),
			"count": manager.count_on(team.id), "max": team.max_players})
	return out


func state(key: Variant) -> Dictionary:
	var record := game.match_node.scoreboard.find(str(key)) if game != null and game.match_node != null else null
	return {"team": game.team_of(int(key)) if game != null else 0, "spectating": record != null and record.spectating}


## Moves [param key] to [param team_id] (a player who was spectating comes back in); [param kill] also kills a living player, which scores nothing.
func join(key: Variant, team_id: int, kill: bool) -> DotResult:
	var id := int(key)
	var player := game.player_for(id)
	if player == null:
		return DotResult.fail(DotError.CODE_INVALID, "Player %d is not in the match." % id)
	var manager: DotTeamManager = game.match_node.teams
	var was_out := bool(state(key)["spectating"])
	# The menu server already applied the imbalance rule; the manager's own would refuse a second time.
	var kept := manager.max_difference
	manager.max_difference = 0
	var res := manager.assign(str(id), game._tick, team_id)
	manager.max_difference = kept
	if not res.ok:
		return res
	game.match_node.scoreboard.record_for(str(id)).spectating = false
	player.team = team_id
	if was_out:
		return _bring_back(id)
	if kill and player.is_alive():
		_silent_kill(id)
	return DotResult.success(team_id)


## Takes [param id] out of play (on) or back in (off), in any mode; a free-for-all player and a team member alike.
func set_spectating(id: int, on: bool) -> DotResult:
	var player := game.player_for(id)
	if player == null:
		return DotResult.fail(DotError.CODE_INVALID, "Player %d is not in the match." % id)
	var record := game.match_node.scoreboard.record_for(str(id))
	if on:
		record.spectating = true
		game.match_node.respawns.cancel(str(id))
		if player.is_alive():
			_silent_kill(id)
		DotLog.debug(CHANNEL, "spectating", {"id": id})
		return DotResult.success(id)
	record.spectating = false
	return _bring_back(id)


func _bring_back(id: int) -> DotResult:
	var res := game.respawn_player(id)
	return DotResult.success(id) if res.ok else res


## A lethal hit from the world that leaves no death, streak or feed line behind: choosing a side is not a mistake to be scored.
func _silent_kill(id: int) -> void:
	var record := game.match_node.scoreboard.record_for(str(id))
	var deaths := record.deaths
	var damage := DotDamage.make(0, id, 100000.0, game.combat.damage_type(&"world"))
	damage.tick = game._tick
	var _dealt := game.combat.apply_damage(damage)
	record.deaths = deaths
	game.match_node.respawns.cancel(str(id))
