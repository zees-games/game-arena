# game-arena docs

The detail behind [CLAUDE.md](../CLAUDE.md). Arena plays free-for-all, team, objective, horde (`siege`), props and gun game modes ([modes.md](modes.md)). One subject per file; open the one you are about to touch. Family-wide rules are in the family's [CLAUDE.md](../../../CLAUDE.md) and [docs/](../../../docs/).

| File | Read it before |
| --- | --- |
| [architecture.md](architecture.md) | adding or changing a join between two addons, the player id space, the order inside a tick, `ArenaMap`'s three representations, or how the game is delivered |
| [netcode.md](netcode.md) | touching `ArenaNetBridge`, `ArenaPlayerNet`, the shared constants, event and request kinds, RULES, weapons over the wire, monsters on the wire, server bots, input copies, the clock, or lag compensation |
| [client.md](client.md) | touching `ArenaClient`, the mouse, the keys, the camera, the presentation layer and effect scenes, the menus and settings screens, the HUD, the chat box, avatars, or the render tools |
| [modes.md](modes.md) | touching the movement tunables, a mode, gun game and weapon pools, objectives, effects, spawn protection, spawning, spectating, criticals, drops, or streaks |
| [maps.md](maps.md) | changing a built-in map, the map catalogue or versions, `change_map`, the map director and sync, which maps host which modes, or the survey |
| [imported-maps.md](imported-maps.md) | touching the combat surf maps: the loader, the solid, settled spawns, pits, the surf air control, the rotation, delivered maps, or the maps' mechanics |
| [horde.md](horde.md) | touching monsters (ids, wiring, tactics, heat, figures) or the props tools |
| [weapons.md](weapons.md) | touching zee-dot-weapons' wiring, the rig, projectiles, or loadout slots |
| [services.md](services.md) | touching progression, chat and its commands, moderation, voice, the website relay, the admin tools, the map vote, the server browser, or private matches |
| [testing.md](testing.md) | adding a check, or believing a green run |
| [history.md](history.md) | a bug that "cannot be happening"; what this game found and how it looked |
| [not-yet.md](not-yet.md) | planning: what is not built yet (the dot-game conversion, bots on the nav graph, monster animation, pickups, real audio, …) |
