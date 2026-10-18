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
- **Workshop maps are listed, not playable.** `provides.json` accepts subscribed maps of `map_kind` `arena` and the solo map menu (M), the vote and `/mapmenu` list them as `Name [Pack]`, but a choice answers "Arena cannot play Workshop maps yet": the game builds a map from a box list (`ArenaMap.by_id`), a pack's map is a scene, and the movement body, trace, spawns and lighting all come from the box list. Playing one needs an `ArenaMap` built from a pack scene (collision from its meshes or a pack-supplied box list, spawns from markers). **Weapons are not accepted**: the loadout, bots, mode pools and the weapon art tables all read `ArenaContent.weapon_catalogue()`'s fixed twenty-seven, so `DotWeaponCatalogue.follow_content` needs those to tolerate an id with no art table row first. [testing](testing.md#the-suites)
