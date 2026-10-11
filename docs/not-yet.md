# Not here yet

What this game does not do yet, each with where the detail is. Each is unfinished work, not a design: when one is done, take it out of this list.

- **dot-game.** The module extends `DotModule` and `ArenaServices` is its own, not `DotGameModule` / `DotGameServices`. Not yet converted; dot-game's CLAUDE.md names arena as the one to convert first.
- **Delivering the combat surf maps**: code done; the packs need publishing from g2gfast-maps, each author's permission confirming, and naming in `cfg/content.yml`. [imported](imported-maps.md#delivered-maps)
- **Server bots** do not use the horde's navigation graph (on a map with corners they walk into walls between spawns until they see somebody), buy or choose nothing, and are not a separate count in the query answer. [netcode](netcode.md#server-bots)
- **Monsters do not animate**: the figure stands while the monster moves. [horde](horde.md#figures)
- **Coins** do not feed the match score or a power-up meter and are not a dot-stats stat. **Challenges** (a dot-achievements progress bar) are not built. [modes](modes.md#coins-out-of-a-body)
- **Pickups in the world**: the map places none (only what a critical kill drops). A level-design decision, not a wiring one.
- **Joining from the browser** is deliberately not done: Join notes the visit and says where to go, because reconnecting elsewhere is the launcher's job and this game is loaded by one.
- **Real audio files**: synthesised stand-ins for every id. [client](client.md#the-presentation-layer)
- **Heavy-loss stalls** and the other games' bridges lacking input copies. [netcode](netcode.md#still-open)
- **The camera's feel past smoothness**: no landing dip, strafe roll or speed widening, which dot-player-controller's own camera has (`arena-camera-feel-1`). [client](client.md#the-camera-is-written-in-exactly-one-place)
