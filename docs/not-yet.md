# Not here yet

What this game does not do yet, each with where the detail is. Each is unfinished work, not a design: when one is done, take it out of this list.

- **dot-game.** The module extends `DotModule` and `ArenaServices` is its own, not `DotGameModule` / `DotGameServices`. Not yet converted; dot-game's CLAUDE.md names arena as the one to convert first.
- **Delivering the combat surf maps**: code done; the packs need publishing from arena-surf-dm-maps (a `v*` tag), each author's permission confirming, and naming in `cfg/content.yml`. [imported](imported-maps.md#delivered-maps)
- **Server bots** buy or choose nothing and are not a separate count in the query answer. [netcode](netcode.md#bots)
- **Monsters do not animate**: the figure stands while the monster moves. [horde](horde.md#figures)
- **Coins** do not feed the match score or a power-up meter and are not a dot-stats stat. **Challenges** (a dot-achievements progress bar) are not built. [modes](modes.md#coins-out-of-a-body)
- **Pickups in the world**: the map places none (only what a critical kill drops). A level-design decision, not a wiring one.
- **Joining from the browser** is deliberately not done: Join notes the visit and says where to go, because reconnecting elsewhere is the launcher's job and this game is loaded by one.
- **Real audio files**: synthesised stand-ins for every id. [client](client.md#the-presentation-layer)
- **Heavy-loss stalls** and the other games' bridges lacking input copies. [netcode](netcode.md#still-open)
- **The camera's feel past smoothness**: no landing dip, strafe roll or speed widening, which dot-player-controller's own camera has (`arena-camera-feel-1`). [client](client.md#the-camera-is-written-in-exactly-one-place)
- **Workshop maps are solo box-list documents only, and no Workshop weapons.** A pack map plays in solo, but it is a box list (`maps/arena_map_doc.gd`), not a scene: no mechanics, toys, packs, climbs or wall routes, no team spawns (so no team mode), and none of the modes that build a layer from boxes (monsters, objectives, props). A pack with a scene-built map would need collision from its meshes. [maps](maps.md#workshop-maps) **Weapons are not accepted**: the loadout, bots, mode pools and the weapon art tables all read `ArenaContent.weapon_catalogue()`'s fixed twenty-seven, so `DotWeaponCatalogue.follow_content` needs those to tolerate an id with no art table row first. [testing](testing.md#the-suites)
