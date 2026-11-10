extends Node

const ArenaGame := preload("arena_game.gd")


const ArenaPlayer := preload("arena_player.gd")

## The player-facing addons, stood up once and bound to the game. Seven addons that each know
## nothing about the arena, met here: session roster, sides, classes, spawns and physics settings.


var game: ArenaGame = null


var physics: DotPhysicsWorld = null
var roster: DotPlayerRoster = null
var teams: DotTeamRoster = null


## The dot-team side for one of dot-match's team ids. [b]An id, not an index[/b]: dot-match's `standard_pair()` is Red `1` and Blue `2`, a spectator team `31`; treating `team_of()`'s answer as a position would put team 1 on dot-team's first side by luck and a spectator nowhere.
## So the id is looked up in the match's own ordered team list and the POSITION crosses over: the nth playing side there is the nth playing side here.
func _side_of_id(team_id: int) -> StringName:
	if game.match_node.teams == null or team_id <= 0:
		return &""

	var playing := teams.teams.playing_ids()
	var listed := game.teams()

	for i in range(listed.size()):
		if listed[i] != null and listed[i].id == team_id:
			return playing[i] if i < playing.size() else &""

	return &""


## The roster side whose match team claims a spawn point with one of [param tags], or
## empty for a point any side may use — which is every point outside a team mode.
func _side_of_tags(tags: Array[StringName]) -> StringName:
	if tags.is_empty():
		return &""

	for team in game.teams():
		if team != null and team.spawn_tag != &"" and tags.has(team.spawn_tag):
			return _side_of_id(team.id)

	return &""


func _alive_of_key(key: String) -> bool:
	var player := game.player_for(int(key))
	return player != null and player.is_alive()


func _joined_tick_of_key(key: String) -> int:
	var record := roster.get_record(key)
	return record.joined_tick if record != null else 0


func _score_of_key(key: String) -> float:
	var score := game.match_node.scoreboard.find(key)
	return float(score.score) if score != null else 0.0


## Where a player's EYES are, which is not where their feet are. dot-spectate's documentation is explicit: a chase camera derived from a capsule's origin sits in the floor and a first-person one is at the knees.
## The controller answers it, because it knows the eye height and the pitch.
func _pose_of_key(key: String) -> Transform3D:
	var player := game.player_for(int(key))

	if player == null or player.controller == null:
		return Transform3D.IDENTITY

	return player.controller.eye_transform()


## Everybody alive who is an enemy of the spawning player: in a free-for-all everybody but them, in a team mode the other sides.
## The spawning player is never their own enemy: one respawned while alive (a map change, an admin) stood on the site being scored and scored it as the most dangerous place on the map.
func _enemy_positions(team: StringName, key: String = "") -> Array:
	var out: Array = []
	# The MODE says whether there are sides, not dot-match's team manager: that exists in a free-for-all too, and the roster keeps whatever side a team mode left everybody on,
	# which told a free-for-all respawner its old team-mates were friends.
	var sided := game.mode != null and game.mode.is_team_mode() and team != &""

	for player in game.players():
		if not player.is_alive() or player.controller == null or str(player.player_id) == key:
			continue

		if sided and teams != null and teams.team_of(str(player.player_id)) == team:
			continue

		out.append(player.controller.state.position)

	return out


## The spawning player's side, alive, in a team mode; nobody in a free-for-all.
func _friend_positions(team: StringName, key: String = "") -> Array:
	var out: Array = []

	if game.mode == null or not game.mode.is_team_mode() or team == &"" or teams == null:
		return out

	for player in game.players():
		if player.is_alive() and player.controller != null and str(player.player_id) != key \
				and teams.team_of(str(player.player_id)) == team:
			out.append(player.controller.state.position)

	return out


## Whether an enemy standing at [param from] can see a site: eye height to head height, walls in the way. [b]Through the map's own trace, the one shots use[/b] (`combat.trace`: the box list on a built-in map, the brushes on an imported one).
## Godot's physics space holds no built-in map on a dedicated server or in any headless game (the level is analytic there), so every site was "seen" by every enemy and `sight_penalty` decided nothing.
## Props are not in the trace; a prop is not cover a spawn should count on. The physics query stays as the fallback for a game with no combat yet.
func _can_see_site(from: Vector3, to: Vector3) -> bool:
	var eye := from + Vector3(0, ArenaPlayer.eye_height(), 0)
	var head := to + Vector3(0, ArenaPlayer.eye_height(), 0)
	var trace: DotTrace = game.combat.trace if game != null and game.combat != null else null

	if trace != null:
		var span := head - eye
		var length := span.length()
		if length < 0.01:
			return true
		var hit := trace.ray(eye, span / length, length)
		return not hit.ok() or hit.distance >= length - 0.05

	if physics == null or not is_inside_tree():
		return false

	return physics.query().line_of_sight_3d(get_viewport().find_world_3d(), eye, head)
