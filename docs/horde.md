# The horde: monsters and props

`siege` is the mode where dot-npc, dot-npc-ai, dot-npc-ai-director and dot-props are live at once. Monsters make the middle of the map expensive to hold, and movable cover is the only answer a player can build. It is also the only place those four run together.

## A monster's entity id

**Allocated by the `DotEntityTable` the game holds as `entities`**: `kind * 10^12 + serial`, so `is_npc_entity` asks the id what it names. It used to be derived from the engine's instance id modulo a million; instance ids are neither small nor dense, so two monsters could share an entity id, and the second `register_health` overwrote the first, leaving one shootable and unkillable with no error. `headless_match` asserts every monster alive has an id of its own.

**Players still use the dot-server session id as their entity id, deliberately not converted.** Seven things depend on that equality: dot-match's scoreboard keys, dot-effects' per-entity scales, dot-stats rows, dot-spectate, the player-stack roster, the kill feed on the wire, and the client that rebuilds one from two ints. dot-effects makes it indivisible: it is keyed from both spaces today (`damage_taken_scale(damage.victim)` against `move_speed_scale(session_id)`), so a half-done conversion is an effect layer that silently stops applying to damage. The two cannot collide meanwhile, because a table id is above 10^12 and a session id is not.

## A non-player entity in dot-combat

- **`_on_entity_killed` emits `non_player_killed` for anything that is not a player**, which `ArenaHorde` listens to; handing a monster's id to `DotMatch.report_kill` creates a scoreboard record for a player nobody has.
- **`_on_damage_applied` filters the same way**, or `ArenaProgress` files stats, progress and leaderboard rows against a monster.

## Wiring traps in the NPC addons

- **`DotNpcAiBrain._npc_ready` seeds the character and puts it on the context before calling `_build`.** A brain that assigns `character` inside `_build` gets neither: every monster of a kind rolls the same aim error at the same moment, and `ctx.character` stays null. Nothing errors.
- **`DotNpcSpawner._ready` builds its own `DotNpcSenses` when it finds none**, so assign senses before `add_child`.
- **The map's furniture shares a player's prop budget.** `may_spawn` checks `per_player_budget` against whatever owner it is given, including the empty owner, so map props must fit a budget or be placed outside it.
- The brain reaches `ArenaHorde` through `DotRegistry`, never by name.

## How the horde fights

Four kinds: grunts, brutes and stalkers close in, but only three of the horde attack one player at a time (`"attackers"` in `ArenaNpcs`, dot-npc-ai's attack slots); the rest wait on a ring just out of reach, shared out so they stand apart, and the stalkers end up behind you. The gunner builds a ranged branch from its definition's `range_damage`: it breaks off to cover when badly hurt, one per player flanks, and the rest hold a 9-18 m band, strafing, and fire through `ArenaHorde.npc_shoot`, a `DotShot` dot-combat resolves against real hitboxes (armour, kill feed and lag compensation apply). Its accuracy is set to about half on purpose: a hard preset's 0.85 at three shots a second is a gunner nobody can cross the room against. Gunners still fire the damage type `bullet`, which is why the damage table keeps it.

The monsters hear: every player shot is a combat sound owned by the shooter, every rocket in the air a danger with its splash as the reach (they dodge), every detonation an explosion. And they learn the map: `ArenaHorde.heat` samples where players walk twice a second, and monsters with the tactics for it patrol those places. `ArenaModule` turns on `ArenaGame.persist_npc_heat` so a real server keeps it per map in `user://npc_heat`; it is off by default because every suite builds an `ArenaGame`.

## Over the wire

Monsters are replicated by `ArenaNpcNet` ([netcode](netcode.md#monsters-are-server-authoritative-mirrors)), announced with the `NPC` and `NPC_GONE` events.

## Figures

`npcs/arena_npc_body.gd` draws one of the family's animated people (dot-player-char's `DotHumanoidFigure`, the person of the character kit's skin letter, animating from how far its body moves) when its scene names a `skin`: grunt `l`, brute `o`, stalker `r`, gunner `g`, its top tinted half way toward its old colour, scaled to `body_height`. With no skin or no art, the capsule and snout draw. The collision is not this node's. Its preload is relative (`../game/arena_paths.gd`): an absolute `res://` in a script inside a delivered pack resolves against the host.

## Props

`ArenaProps.act` is the door to dot-props' physics gun and gravity gun, and `ArenaEvents.Ask.PROP_TOOL` is how a client reaches it: an intent, because a rigid body's contact solver is not reproducible across machines, so the aim is a claim the client makes and the origin is a fact the server already has. **`DotPhysGun.hold` must be called every tick**; a layer that only calls `grab` leaves the prop where it was picked up.
