extends DotSpectatorHost

const ArenaGame := preload("arena_game.gd")
const ArenaPlayer := preload("arena_player.gd")

## Where a dead player looks.
##
## [b]The arena has killed people since the day it was written and had nowhere for them
## to look.[/b] A dead player's camera stayed where their body fell, which is the one
## thing a first-person game must not do: the corpse is on the floor, so the view is on
## the floor, and the two seconds before respawn are spent looking at a wall from ankle
## height.
##
## The camera part is four lines. The part that matters is that the **server** decides
## who may watch whom: this game defaults to own-team-only, so a dead player cannot
## call out the other side's positions, and the delay is available for a server that
## wants one.
##
## [codeblock]
## var spectate := ArenaSpectate.new()
## spectate.game = game
## add_child(spectate)
## spectate.setup()
## # on the client, once a frame:
## camera.global_transform = spectate.camera_for(str(my_id))  # keys are strings
## [/codeblock]

const CHANNEL := "arena.spectate"

var game: ArenaGame = null
var _participant_ids: Array[int] = []
var _participant_keys := PackedStringArray()


func setup() -> DotResult:
	if game == null:
		return DotResult.fail(DotError.CODE_STATE, "ArenaSpectate needs a game.")

	# [b]Authoritative on a client too, over its own camera and nothing else.[/b] This
	# game's server sends no spectator views — a client learns of a death from the KILL
	# event and of a respawn from the replicated health — so a MIRROR here would be one
	# nobody tells anything, and a mirror runs no timers: the death camera it was handed
	# would never hand over. The client runs the same rules from the same mode over the
	# players it already draws, and decides nothing the server has to trust; what the
	# server enforces is what it replicates. See dot-spectate's docs/design.md, on mirrors.
	authoritative = true
	# The game's own object, so the cvars the module binds (and a client follows) are the
	# rules in use.
	rules = game.spectate_rules
	_adopt_tuning()

	var res := super.setup()
	if not res.ok:
		return res.wrap("arena spectate")

	# Once per game, and INFO because it is the policy an admin is asked about: "why
	# can I only watch my own team" has its answer in this line.
	DotLog.info(CHANNEL, "spectating is set up", {
		"own_team_only": manager.rules.force_camera == 1,
		"roaming": manager.rules.roaming_permitted(),
		"death_cam_ticks": manager.rules.death_cam_ticks,
		"authoritative": manager.authoritative,
	})

	# The authority's signals. A networked client emits neither — dot-combat resolves no
	# death on a mirror and dot-match's respawn queue runs on the authority — so a client
	# is fed by the bridge instead: [method on_kill_event] and [method client_tick].
	if not game.player_killed.is_connected(_on_killed):
		game.player_killed.connect(_on_killed)
	if not game.player_spawned.is_connected(_on_spawned):
		game.player_spawned.connect(_on_spawned)

	return DotResult.success(null)


## [b]force_camera and allow_roaming are deliberately not set[/b]: they are the operator's
## (`mp_forcecamera`, `mp_freeroam`) and default to anybody-may-watch with free roam on.
## Until 2026-10-21 a team mode forced own-team-only here, which also switched roaming off
## with nobody having said so.
func _adopt_tuning() -> void:
	tick_rate = game.tick_rate
	death_cam_seconds = 1.0
	freeze_cam_seconds = 1.5
	chase_distance = 3.5
	chase_height = 0.9
	history_seconds = 4.0
	eye_height = ArenaPlayer.eye_height()


## The camera timers are seconds turned into ticks at setup; a client whose server runs another
## rate adopts it after setup (HELLO), so the bridge calls this again or the death camera would
## last the default rate's tick count at the new rate (1 s became 2 s at 33 Hz).
func retime() -> void:
	if manager != null:
		_adopt_tuning()
		manager.rules = tune_rules(game.spectate_rules)


func _channel() -> String:
	return CHANNEL


## Asked for by every spectator rule check (about 20 a frame with 32 players). game.player_ids() hands back the same
## array until the roster changes and then a new one, so the keys are rebuilt only when that array is a new one.
func _participants() -> PackedStringArray:
	var ids: Array[int] = game.player_ids()
	if is_same(ids, _participant_ids) and ids.size() == _participant_keys.size():
		return _participant_keys
	var out := PackedStringArray()
	for id in ids:
		out.append(str(id))
	_participant_ids = ids
	_participant_keys = out
	return out


func _team_of(key: String) -> int:
	return game.team_of(int(key))


func _is_alive(key: String) -> bool:
	var player := game.player_for(int(key))
	return player != null and player.is_alive()


func _current_tick() -> int:
	return game.current_tick()


## Where a player's eyes are.
##
## Eyes rather than the body's origin, and it is not a nicety: a chase camera derived
## from a capsule origin sits in the floor and a first-person one is at the knees.
## `ArenaPlayer.muzzle_position` is the same 1.6 metres and is deliberately not reused —
## a muzzle is where a shot leaves and an eye is where a view starts, and the day one of
## them moves is the day sharing them is a bug.
func _pose_of(key: String) -> Transform3D:
	var player := game.player_for(int(key))
	if player == null or player.controller == null:
		return Transform3D.IDENTITY
	var state := player.controller.state
	return eye_pose(state.position, state.pitch, state.yaw)


func tick(_delta: float) -> void:
	advance_live()


## A networked client's tick, from [code]ArenaNetBridge.client_tick[/code]: a networked
## client never calls `game.tick`, see [method DotSpectatorHost.advance_client].
func client_tick(tick: int) -> void:
	advance_client(tick)


## A KILL event arrived, on a networked client. The same chain [method _on_killed] starts
## on the authority, from where THIS machine drew the victim.
func on_kill_event(info: Dictionary) -> void:
	if manager == null:
		return
	var victim := int(info.get("victim_id", 0))
	var killer := int(info.get("killer_id", 0))
	var player := game.player_for(victim)
	if player == null or player.controller == null:
		# A kill for somebody this client does not hold: nobody here to draw a camera for.
		return
	death(str(victim), player.controller.state.position, str(killer) if killer != 0 else "")


## Cycle first person, chase, roaming — whatever the server's policy allows.
func cycle_mode(key: String) -> DotResult:
	if manager == null:
		return _unset()
	var view := manager.view(key)
	var next := DotSpectatorView.Mode.CHASE
	if view.mode == DotSpectatorView.Mode.CHASE:
		next = DotSpectatorView.Mode.ROAMING
	elif view.mode == DotSpectatorView.Mode.ROAMING:
		next = DotSpectatorView.Mode.FIRST_PERSON
	return manager.set_mode(key, next)


func _on_killed(entry: DotKillFeed.Entry) -> void:
	if manager == null:
		return
	var player := game.player_for(int(entry.victim_key))
	var at := Vector3.ZERO
	if player != null and player.controller != null:
		at = player.controller.state.position
	else:
		# A kill for somebody the game no longer holds: their death cam starts at the
		# world origin, which is a camera in the floor of the middle of the map.
		DotLog.warn(CHANNEL, "a death for a player the game does not hold; the death cam starts at the origin", {
			"victim": entry.victim_key,
		})
	death(entry.victim_key, at, entry.killer_key)


func _on_spawned(player: ArenaPlayer) -> void:
	spawned(str(player.player_id))


func on_leave(id: int) -> void:
	left(str(id))
