# game-fatal-contact docs

The detail behind [CLAUDE.md](../CLAUDE.md). Fatal Contact plays free-for-all, team, objective, horde (`siege`), props and gun game modes ([modes.md](modes.md)). One subject per file; open the one you are about to touch. Family-wide rules are in the family's [CLAUDE.md](../../../CLAUDE.md) and [docs/](../../../docs/).

| File | Read it before |
| --- | --- |
| [architecture.md](architecture.md) | adding or changing a join between two addons, the player id space, the order inside a tick, `ArenaMap`'s three representations, or how the game is delivered |
| [netcode.md](netcode.md) | touching `ArenaNetBridge`, `ArenaPlayerNet`, the shared constants, event and request kinds, RULES, weapons over the wire, monsters on the wire, server bots, input copies, the clock, or lag compensation |
| [client.md](client.md) | touching `ArenaClient`, the mouse, the keys, touch controls, the camera, the presentation layer and effect scenes, the menus and settings screens, the HUD, the chat box, avatars, or the render tools |
| [modes.md](modes.md) | touching the movement tunables, a mode, gun game and weapon pools, objectives, effects, spawn protection, spawning, spectating, criticals, drops, or streaks |
| [maps.md](maps.md) | changing a built-in map, the map catalogue or versions, `change_map`, the map director and sync, which maps host which modes, or the survey |
| [imported-maps.md](imported-maps.md) | touching the combat surf maps: the loader, the solid, settled spawns, pits, the surf air control, the rotation, delivered maps, or the maps' mechanics |
| [horde.md](horde.md) | touching monsters (ids, wiring, tactics, heat, figures) or the props tools |
| [weapons.md](weapons.md) | touching fc-weapons' wiring, the rig, projectiles, or loadout slots |
| [services.md](services.md) | touching progression, chat and its commands, moderation, voice, the website relay, the admin tools, the map vote, the server browser, or private matches |
| [sim-thread.md](sim-thread.md) | touching `--sim_host`, the solo server process, or planning what may leave the main thread |
| [perf-architecture.md](perf-architecture.md) | planning frame-time work: where a 32-player frame goes, per thread and system, and what each lever is worth |
| [perf-vs-css.md](perf-vs-css.md) | asking why CS:S runs 32 players faster: a CS:S server profiled on staging02 beside FC's budget, and the five structural differences ranked by what FC could gain |
| [anim-review.md](anim-review.md) | judging or fixing a weapon's first-person or third-person animation: the capture, the contact sheets, the glitch metrics, the loop |
| [testing.md](testing.md) | adding a check, or believing a green run |
| [history.md](history.md) | a bug that "cannot be happening"; what this game found and how it looked |
| [not-yet.md](not-yet.md) | planning: what is not built yet (the dot-game conversion, bots on the nav graph, monster animation, pickups, real audio, …) |
