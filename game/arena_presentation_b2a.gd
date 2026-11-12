extends "arena_presentation_b1.gd"

const ArenaVote := preload("arena_vote.gd")
## Ids that play recorded files from the addons: id -> [folder, file stem, how many, gain dB, pitch
## low, pitch high]. Folder: &"weapons", &"stock" (dot-audio `stock/`) or &"toys" (dot-props). The
## recipes in [method sound_recipes] stay for a build that lacks the files.
const RECORDED := {
	&"fire_rifle": [&"weapons", "rifle_fire", 5, 0.0, 0.95, 1.05],
	&"fire_shotgun": [&"weapons", "shotgun_fire", 5, 0.0, 0.95, 1.04],
	# Recorded a few dB hotter on average than the rifle, at a lower peak: level with it here.
	&"fire_rail": [&"weapons", "rail_fire", 4, -3.0, 0.97, 1.03],
	&"explosion": [&"weapons", "explosion", 5, 0.0, 0.9, 1.06],
	&"impact": [&"weapons", "impact", 5, -2.0, 0.9, 1.1],
	# A boot on a head: a meaty smack, not a sweep.
	&"stomp": [&"weapons", "melee_flesh", 5, 2.0, 0.85, 0.95],
	# Recorded about 10 dB under a shot; a pickup is meant to be heard over your own steps.
	&"pickup": [&"weapons", "equip", 3, 6.0, 0.95, 1.08],
	# A bell for the beacon: a ping that says where, and nothing like a hit marker.
	&"beacon": [&"toys", "bell", 2, 0.0, 0.97, 1.03],
	# The wall moves on the stock concrete step and light landing, pitched up a little so a run's
	# first step is not heard as somebody else's footstep.
	&"wall_run": [&"stock", "footsteps/footstep_concrete", 5, -4.0, 1.1, 1.2],
	&"wall_jump": [&"stock", "landing/landing_light", 1, -4.0, 1.12, 1.2],
	# A short tick for a hit and a two-note chime for a kill: information, not a noise in the world.
	# The tick is pitched down to about 0.8 (the recording sounded high and thin to the owner).
	&"hit_marker": [&"stock", "interface/tick", 3, 0.0, 0.78, 0.84],
	&"kill_confirmed": [&"stock", "interface/confirm", 2, 0.0, 0.98, 1.02],
	# The medals are spoken: a word says which medal, where a pitched sweep only said "good".
	&"medal_first_blood": [&"stock", "announcer/target_eliminated", 1, 0.0, 1.0, 1.0],
	&"medal_headshot": [&"stock", "announcer/perfect", 1, 0.0, 1.0, 1.0],
	&"medal_double_kill": [&"stock", "announcer/combo", 1, 0.0, 1.0, 1.0],
	&"medal_triple_kill": [&"stock", "announcer/multikill", 1, 0.0, 1.0, 1.0],
	&"medal_multi_kill": [&"stock", "announcer/godlike", 1, 0.0, 1.0, 1.0],
	&"medal_revenge": [&"stock", "announcer/eliminated", 1, 0.0, 1.0, 1.0],
	&"medal_shutdown": [&"stock", "announcer/combo_breaker", 1, 0.0, 1.0, 1.0],
	&"medal_point_blank": [&"stock", "announcer/target_destroyed", 1, 0.0, 1.0, 1.0],
	&"medal_no_scope": [&"stock", "announcer/fantastic", 1, 0.0, 1.0, 1.0],
	&"medal_long_shot": [&"stock", "announcer/sniper", 1, 0.0, 1.0, 1.0],
	&"medal_nemesis": [&"stock", "announcer/untouchable", 1, 0.0, 1.0, 1.0],
	# Spoken where a flag changed hands for a team, a plain cue for a drop or a return.
	&"flag_taken_by_me": [&"stock", "announcer/lets_go", 1, 0.0, 1.0, 1.0],
	&"flag_taken": [&"stock", "announcer/go_go_go", 1, 0.0, 1.0, 1.0],
	&"flag_lost": [&"stock", "announcer/enemy_captured", 1, 0.0, 1.0, 1.0],
	&"flag_lost_back": [&"stock", "announcer/target_lost", 1, 0.0, 1.0, 1.0],
	&"flag_dropped": [&"stock", "interface/drop", 1, 0.0, 1.0, 1.0],
	&"flag_returned": [&"stock", "interface/confirm_bright", 1, 0.0, 1.0, 1.0],
	&"flag_captured": [&"stock", "announcer/point_captured", 1, 0.0, 1.0, 1.0],
	&"vote_start": [&"stock", "interface/question", 1, 0.0, 1.0, 1.0],
	&"vote_end": [&"stock", "interface/confirm_long", 1, 0.0, 1.0, 1.0],
	&"vote_warning": [&"stock", "interface/bong", 1, 0.0, 1.0, 1.0],
	&"vote_count": [&"stock", "interface/pluck", 1, 0.0, 1.0, 1.0],
	# Kenney's phase jump peaks near -15 dBFS, well under the rest of the set.
	&"spawned": [&"stock", "interface/phase_jump", 3, 9.0, 0.98, 1.02],
	&"hurt": [&"stock", "body/punch", 5, -3.0, 0.95, 1.08],
	&"died": [&"stock", "body/punch_heavy", 5, 0.0, 0.85, 0.92],
}


const STOMP_SOUND := &"stomp"


## Capture the flag's cues (see on_flag_event) and the medals, with the synthesised voice each
## falls back to in a build without dot-audio's stock files; their recordings are in RECORDED.
const FLAG_VOICES := {
	&"flag_taken_by_me": DotAudioSynth.Voice.PICKUP,
	&"flag_taken": DotAudioSynth.Voice.PICKUP,
	&"flag_lost": DotAudioSynth.Voice.DENY,
	&"flag_lost_back": DotAudioSynth.Voice.DENY,
	&"flag_dropped": DotAudioSynth.Voice.BLIP,
	&"flag_returned": DotAudioSynth.Voice.PICKUP,
	&"flag_captured": DotAudioSynth.Voice.SPAWN,
}

const MEDAL_VOICES := {
	&"medal_first_blood": DotAudioSynth.Voice.SPAWN,
	&"medal_headshot": DotAudioSynth.Voice.PICKUP,
	&"medal_double_kill": DotAudioSynth.Voice.SPAWN,
	&"medal_triple_kill": DotAudioSynth.Voice.SPAWN,
	&"medal_multi_kill": DotAudioSynth.Voice.SPAWN,
	&"medal_revenge": DotAudioSynth.Voice.PICKUP,
	&"medal_shutdown": DotAudioSynth.Voice.PICKUP,
	&"medal_point_blank": DotAudioSynth.Voice.IMPACT,
	&"medal_no_scope": DotAudioSynth.Voice.SHOT_TIGHT,
	&"medal_long_shot": DotAudioSynth.Voice.SHOT_TIGHT,
	&"medal_nemesis": DotAudioSynth.Voice.DENY,
}


## What a deathmatch makes a noise about.
static func sound_catalogue() -> DotAudioCatalogue:
	var c := DotAudioCatalogue.new()
	DotAudioStock.add_to(c)

	for id in [&"rifle", &"shotgun", &"rail"]:
		var fire := DotAudioDef.new()
		fire.id = StringName("fire_%s" % id)
		fire.kind = DotAudioDef.Kind.POSITIONAL_3D
		fire.bus = &"SFX"
		fire.unit_size = 14.0
		# Past this it is not a shot you can act on, and it would cost a voice every frame.
		fire.max_distance = 90.0
		# Twelve rifles in one tick is one gunshot, twelve times as loud. Three sounds like a firefight.
		fire.max_concurrent = 3
		fire.priority = 80
		fire.tags = [&"weapon"]
		c.add(recorded(fire))

	# A blast: positional and carrying far, few at once.
	var blast := DotAudioDef.new()
	blast.id = EXPLOSION
	blast.kind = DotAudioDef.Kind.POSITIONAL_3D
	blast.bus = &"SFX"
	blast.unit_size = 22.0
	blast.max_distance = 140.0
	blast.max_concurrent = 3
	blast.priority = 85
	blast.tags = [&"weapon"]
	c.add(recorded(blast))

	var impact := DotAudioDef.new()
	impact.id = &"impact"
	impact.kind = DotAudioDef.Kind.POSITIONAL_3D
	impact.bus = &"SFX"
	impact.max_distance = 40.0
	impact.max_concurrent = 4
	impact.priority = 40
	c.add(recorded(impact))

	_add_interface_sounds(c)

	# The wall moves: files and pitch in RECORDED; a cooldown each so a run is a step, not a buzz.
	for wall in [[WALL_RUN_SOUND, 120], [WALL_JUMP_SOUND, 90]]:
		var move := DotAudioDef.new()
		move.id = wall[0]
		move.bus = &"SFX"
		move.cooldown_ms = wall[1]
		move.max_concurrent = 1
		move.priority = 55
		c.add(recorded(move))

	var pickup := DotAudioDef.new()
	pickup.id = &"pickup"
	pickup.kind = DotAudioDef.Kind.POSITIONAL_3D
	pickup.bus = &"SFX"
	pickup.max_distance = 30.0
	pickup.max_concurrent = 3
	pickup.priority = 50
	c.add(recorded(pickup))

	_add_body_sounds(c)

	return c


## Hit, kill, medal, flag, vote, beacon and body-state cues: flat on the interface bus unless noted.
static func _add_interface_sounds(c: DotAudioCatalogue) -> void:
	# Flat, not positional: a hit marker is about your own shot and must not fade with distance.
	var hit := DotAudioDef.new()
	hit.id = &"hit_marker"
	hit.bus = &"UI"
	hit.cooldown_ms = 60
	hit.max_concurrent = 2
	hit.priority = 95
	c.add(recorded(hit))

	# A hit that killed: the same flat information, longer than the tick.
	var killed := DotAudioDef.new()
	killed.id = KILL_CONFIRMED
	killed.bus = &"UI"
	killed.max_concurrent = 1
	killed.priority = 96
	c.add(recorded(killed))

	# The medals: flat, on the interface bus, one at a time each. Information about your
	# own kill, like the hit marker; louder than the world so a medal is never lost in it.
	for id in MEDAL_VOICES:
		var medal := DotAudioDef.new()
		medal.id = id
		medal.bus = &"UI"
		medal.max_concurrent = 1
		medal.priority = 92
		c.add(recorded(medal))

	for id in FLAG_VOICES:
		var cue := DotAudioDef.new()
		cue.id = id
		cue.bus = &"UI"
		cue.max_concurrent = 2
		cue.priority = 93
		c.add(recorded(cue))

	var stomp := DotAudioDef.new()
	stomp.id = STOMP_SOUND
	stomp.bus = &"SFX"
	stomp.max_concurrent = 3
	stomp.priority = 88
	c.add(recorded(stomp))

	var hurt := DotAudioDef.new()
	hurt.id = &"hurt"
	hurt.bus = &"SFX"
	hurt.cooldown_ms = 180
	hurt.max_concurrent = 1
	hurt.priority = 90
	c.add(recorded(hurt))

	var died := DotAudioDef.new()
	died.id = &"died"
	died.bus = &"SFX"
	died.priority = 100
	c.add(recorded(died))

	var spawn := DotAudioDef.new()
	spawn.id = &"spawned"
	spawn.bus = &"UI"
	spawn.priority = 60
	c.add(recorded(spawn))
	_add_vote_sounds(c)


## The map vote's cues and the administrator's beacon ping.
static func _add_vote_sounds(c: DotAudioCatalogue) -> void:
	# The map vote's cues. Flat and on the interface bus: a ballot is about the server, not about a
	# place in the world, and a countdown that got quieter the further you stood from the origin
	# would be a countdown some players never heard.
	for vote_id in [ArenaVote.CUE_START, ArenaVote.CUE_END, ArenaVote.CUE_WARNING, ArenaVote.CUE_COUNT]:
		var cue := DotAudioDef.new()
		cue.id = vote_id
		cue.bus = &"UI"
		cue.max_concurrent = 1
		cue.priority = 70
		c.add(recorded(cue))

	# An administrator's beacon: a ping once a second from the beaconed player, heard by everybody.
	# Positional, because the beacon's whole job is to say WHERE somebody is and a flat ping would
	# say only that somebody somewhere is beaconed.
	var ping := DotAudioDef.new()
	ping.id = BEACON_SOUND
	ping.kind = DotAudioDef.Kind.POSITIONAL_3D
	ping.bus = &"SFX"
	ping.unit_size = 20.0
	ping.max_distance = 160.0
	ping.max_concurrent = 4
	ping.priority = 45
	c.add(recorded(ping))


## The addon-shipped fall and toy sounds.
static func _add_body_sounds(c: DotAudioCatalogue) -> void:
	# A body landing: dot-player-char's stock death sounds (Kenney, CC0), the thud, the face
	# plant's smack, a crumple's slump and a launch's whoosh. Positional, because they say
	# where somebody went down; the files ship in the addon, so the paths are its own.
	for row: Dictionary in DotPlayerDeathSounds.rows():
		var fall := DotAudioDef.new()
		fall.id = row["id"]
		fall.path = row["path"]
		fall.variants = row["variants"]
		fall.kind = DotAudioDef.Kind.POSITIONAL_3D
		fall.bus = &"SFX"
		fall.gain_db = float(row["gain_db"])
		fall.pitch_min = float(row["pitch_min"])
		fall.pitch_max = float(row["pitch_max"])
		fall.cooldown_ms = int(row["cooldown_ms"])
		fall.max_distance = 45.0
		fall.max_concurrent = 3
		fall.priority = 45
		c.add(fall)

	# The map's toys: dot-props' stock toy sounds (Kenney, CC0, and a horn made for it),
	# shipped in the addon. Under the fight in priority: a ball bouncing never takes a voice
	# from a shot.
	for row: Dictionary in DotPropBodySounds.rows():
		var toy := DotAudioDef.new()
		toy.id = row["id"]
		toy.path = row["path"]
		toy.variants = row["variants"]
		toy.kind = DotAudioDef.Kind.POSITIONAL_3D
		toy.bus = &"SFX"
		toy.gain_db = float(row["gain_db"])
		toy.pitch_min = float(row["pitch_min"])
		toy.pitch_max = float(row["pitch_max"])
		toy.cooldown_ms = int(row["cooldown_ms"])
		toy.max_distance = float(row["distance"])
		toy.max_concurrent = 3
		toy.priority = 30
		c.add(toy)


## [param def] with its [constant RECORDED] files, gain and pitch spread; unchanged for an id that has none.
static func recorded(def: DotAudioDef) -> DotAudioDef:
	var row: Array = RECORDED.get(def.id, [])
	if row.is_empty():
		return def
	var dir := recorded_directory(row[0])
	var variants := PackedStringArray()
	for i in range(int(row[2])):
		variants.append(dir.path_join("%s_%d.ogg" % [row[1], i]) if int(row[2]) > 1 else dir.path_join("%s.ogg" % row[1]))
	def.path = variants[0]
	def.variants = variants if variants.size() > 1 else PackedStringArray()
	def.gain_db = float(row[3])
	def.pitch_min = float(row[4])
	def.pitch_max = float(row[5])
	return def


## Where a [constant RECORDED] folder is in this build.
static func recorded_directory(folder: StringName) -> String:
	match folder:
		&"weapons":
			return DotAudioWeaponStock.directory()
		&"toys":
			return DotPropBodySounds.directory()
	return DotAudioStock.directory()


## Which synthesised voice stands in for each id in a build that lacks its file. Which noise belongs
## to which id is this game's decision, not an addon's guess from an id like `fire_rail`.
static func sound_recipes() -> Dictionary:
	var out := _base_recipes()
	out[KILL_CONFIRMED] = DotAudioSynth.Voice.BLIP
	out[STOMP_SOUND] = DotAudioSynth.Voice.IMPACT
	for id in MEDAL_VOICES:
		out[id] = MEDAL_VOICES[id]
	for id in FLAG_VOICES:
		out[id] = FLAG_VOICES[id]
	return out


static func _base_recipes() -> Dictionary:
	return {
		&"fire_rifle": DotAudioSynth.Voice.SHOT,
		&"fire_shotgun": DotAudioSynth.Voice.SHOT_HEAVY,
		&"fire_rail": DotAudioSynth.Voice.SHOT_TIGHT,
		&"impact": DotAudioSynth.Voice.IMPACT,
		EXPLOSION: DotAudioSynth.Voice.BOOM,
		&"hit_marker": DotAudioSynth.Voice.BLIP,
		&"hurt": DotAudioSynth.Voice.HURT,
		&"died": DotAudioSynth.Voice.DIE,
		&"spawned": DotAudioSynth.Voice.SPAWN,
		&"pickup": DotAudioSynth.Voice.PICKUP,
		WALL_RUN_SOUND: DotAudioSynth.Voice.STEP,
		WALL_JUMP_SOUND: DotAudioSynth.Voice.IMPACT,
		BEACON_SOUND: DotAudioSynth.Voice.BLIP,
		# Up for a ballot opening, the one upward sweep, because up reads as "on"; a
		# blip for the warning and a click per second, so a countdown is heard without
		# being mistaken for a hit marker.
		ArenaVote.CUE_START: DotAudioSynth.Voice.SPAWN,
		ArenaVote.CUE_END: DotAudioSynth.Voice.PICKUP,
		ArenaVote.CUE_WARNING: DotAudioSynth.Voice.BLIP,
		ArenaVote.CUE_COUNT: DotAudioSynth.Voice.CLICK,
		# Stand-ins only for a build without dot-props' toy files.
		DotPropBodySounds.BOUNCE: DotAudioSynth.Voice.IMPACT,
		DotPropBodySounds.THUMP: DotAudioSynth.Voice.IMPACT,
		DotPropBodySounds.KNOCK: DotAudioSynth.Voice.IMPACT,
		DotPropBodySounds.PIN: DotAudioSynth.Voice.CLICK,
		DotPropBodySounds.WOOD: DotAudioSynth.Voice.IMPACT,
		DotPropBodySounds.RUBBER: DotAudioSynth.Voice.IMPACT,
		DotPropBodySounds.PUNCH: DotAudioSynth.Voice.HURT,
		DotPropBodySounds.METAL: DotAudioSynth.Voice.CLICK,
		DotPropBodySounds.BELL: DotAudioSynth.Voice.PICKUP,
		DotPropBodySounds.CLICK: DotAudioSynth.Voice.CLICK,
		DotPropBodySounds.WATER: DotAudioSynth.Voice.STEP,
		DotPropBodySounds.BOING: DotAudioSynth.Voice.SPAWN,
		DotPropBodySounds.HORN: DotAudioSynth.Voice.BLIP,
		# A body landing. The real files ship in dot-player-char; these stand in only on a
		# build that lacks them.
		DotPlayerDeathReactions.SOUND_THUD: DotAudioSynth.Voice.IMPACT,
		DotPlayerDeathReactions.SOUND_FACE_PLANT: DotAudioSynth.Voice.IMPACT,
		DotPlayerDeathReactions.SOUND_SLUMP: DotAudioSynth.Voice.STEP,
		DotPlayerDeathReactions.SOUND_WHOOSH: DotAudioSynth.Voice.SPAWN,
	}
