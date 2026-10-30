extends RefCounted

## Which key a player's saved loadouts are filed under. A stable stats key where there is one
## (it survives a restart and a reconnect); the per-session seat key otherwise, kept in memory.

const SEAT_PREFIX := "arena-player-"
const STORE_DIR := "user://loadouts"

var feed: DotGameStatsFeed = DotGameStatsFeed.new()
var _key_of: Dictionary = {}
var _id_of: Dictionary = {}


func _init() -> void:
	feed.open_sessions = false


## The durable store: files for stable keys, memory for seat keys.
static func make_store(dir: String = STORE_DIR) -> DotLoadoutStore:
	return DotLoadoutStoreTiered.of(DotLoadoutStoreLocal.at(dir), is_durable)


## The per-session key of player [param id]; ArenaGame.storage_key is this.
static func seat_key(id: int) -> String:
	return SEAT_PREFIX + "%08d" % id


## Whether a loadout key can outlive the session: not a seat key.
static func is_durable(key: String) -> bool:
	return not key.begins_with(SEAT_PREFIX)


## Binds [param session]'s player to a stable key when it has a usable one (not a bare seat).
func bind(session: DotClientSession) -> String:
	var key := String(feed.key_for(session))
	var seat_only := key == "u%d" % session.userid or not DotLoadoutKey.is_usable(key)
	if seat_only:
		return ""
	_key_of[session.userid] = key
	_id_of[key] = session.userid
	return key


func release(userid: int) -> void:
	_id_of.erase(_key_of.get(userid, ""))
	_key_of.erase(userid)
	feed.forget(userid)


## The loadout key for player [param id].
func key_of(id: int) -> String:
	return _key_of.get(id, seat_key(id))


## The player id a loadout key names, or 0.
func id_of(key: String) -> int:
	if _id_of.has(key):
		return _id_of[key]
	return key.trim_prefix(SEAT_PREFIX).to_int() if key.begins_with(SEAT_PREFIX) else 0
