# Testing

The family's rules for checks are in [testing.md](../../../docs/testing.md) and [bugs-found.md](../../../docs/bugs-found.md). `./game.sh test` runs the parse pass and every suite with a timeout and the stderr check, and writes each suite's log to `.godot/test-logs/`; `./game.sh test <suite>` runs one.

**Run the suites after changing any dot-* addon this game links.** That is what this project is for.

## The suites

| Suite | What it drives |
| --- | --- |
| `headless_match` | an `ArenaGame` directly, no socket, no rendering. Bots aim at the nearest player and hold the trigger. Modes, maps and the survey, map changes, the horde, objectives, effects, progression, weapons, drops, gun game, lag compensation, every medal rule beside its near miss, the wall cvars and "off is what it was", every map's wall routes driven through the motor |
| `headless_net` | a server and a client in one process over a loopback that drops packets: the wire, mirroring, prediction, config agreement, the death camera on a client, weapons and projectiles, movement rules, a wall run and a chimney climb predicted from the client's own state, admin flags, an imported map |
| `headless_lossy` | real ENet through real loss (below) |
| `headless_presentation` | the client's presentation layer, effects, HUD pieces (HIT and AWARD read off the wire into the hit marker, numbers, medals and points), the private match over HTTP |
| `headless_stack` | the player stack: spawning, sides, protection |
| `headless_admin` | the admin tools on a real `DotServer` with the module loaded by path |
| `headless_imported` | a deathmatch on a combat surf map: catalogue, spawns, floors, ramps, pits, surf air control, mechanics, delivery from a fake mount. Skips, and says so, without the g2gfast-maps link |
| `dedicated` | a real `DotServer` loading `ArenaModule`: boot, commands, the vote's clock, bots, unload, exiting clean |

**`headless_presentation` is reachable from none of the others.** `headless_match` plays with no client and `dedicated` never connects one, which is how a module looked a session up by the wrong key and nobody could join a dedicated server while `dedicated` passed throughout. `dedicated` does not connect a client on purpose: dot-platform and game-hungario's `sandbox` already run that seam over a real socket.

`headless_match` asserts what did not happen as well as what did: nobody fell through the floor, nobody left the room, and the geometry blocks shots, because if the trace ignored the map every other check would still pass.

## headless_lossy: real ENet through real loss

Servers listen on ENet as well as WebSocket, and over WebSocket "unreliable" is TCP. `headless_net`'s loss is its own loopback dropping packets in order and instantly. `examples/headless_lossy` puts dot-net's lossy UDP relay (`res://addons/dot_net/testing/dot_net_udp_relay.gd`, by path; see [dot-net's testing.md](../../dot-net/docs/testing.md)) between a real `DotClientLink` on ENet and a real dual-stack `DotServer` running `ArenaModule`. Client A goes through the relay and runs, strafes and turns every tick; client B connects straight and runs a circle, the smooth reference A's drawing is held to; a dummy is slain every 1.2 s for the kill feed. Each end has its own `MultiplayerAPI` (`SceneTree.set_multiplayer`), so one process holds all three.

It measures A's first three seconds, then a steady 55 ms window and 5% and 20% loss with 30-80 ms of uniform delay (so packets reorder): connection, injected loss, clock settling, the share of server ticks with A's command, B drawn every frame without freezes or jumps and close to where the server had him at render time, render-timeline steps back, extrapolation, A's prediction against the server tick for tick, `DotNetStats.loss_rate()` against the relay, and every numbered notice, kill and chat line exactly once and in order. After the windows, A runs dm_box's north wall and kicks off it through the 20% loss: both ends run and jump once, A hears each once, and its prediction stays within the windows' 5 cm. It plays in real time (about 50 seconds). `--verbose` prints the diagnostics. It is in `./game.sh test`; it was out while it failed one run in four, and the remaining heavy-loss stalls are queued ([netcode](netcode.md#still-open)).

## Traps the suites have hit

- **Read a suite's stderr even when it exits 0.** A script error aborts its section, not the run; four freed-object errors in `headless_match` once left every check passing.
- **Filter `--check-only` for the lines that mean a parse failed** (`SCRIPT ERROR`, `Parse Error`, `Failed to load script`), not against shutdown noise by exact wording, which goes stale when the engine rewords a line.
- **A scene whose script fails to parse hangs** rather than exiting. Cap every run with `timeout`.
- **An adopted session has no peer**, so a suite that adopts one points the netcode's `send_fn` at nothing, or every send is an engine RPC error.
- **Every position check starts on a spawn point**: `dm_box` has a platform at the origin and a body teleported there is pushed out.
- **A map check drives a walking bot** ([maps](maps.md#every-map-is-surveyed)).
- **A check that depends on how an earlier section ended is not a check.** The horde gunner check chooses a spot with line of sight and strips spawn protection from its target; the movement-rules section runs after the weapons section because this harness fires every eighth tick and spent the magazine.
- **`headless_net` has no input lead**: a lost packet is a tick the server runs on the previous command, so a check of a predicted move there allows a hand's width mid-move and asks for agreement once down. `headless_lossy` has the real buffer and holds 5 cm.
- **A suite or render tool never writes the player's settings.** `headless_presentation` typed `field_of_view 120` at the console into this machine's real `user://arena_settings` on every run, and every session and screenshot after it drew at 120. `ArenaPresentation.use_scratch_settings(<tag>)` points every presentation built after it at an emptied `user://scratch/<tag>/`; `headless_presentation` and all four tools that build a presentation or a client call it first, and the suite checks the player's file was not touched.
- **Arm every new check**: put the bug back and watch it fail. A check that has never failed may be asserting the bug (the effect-scene check once asserted a gib was refused "for the missing file").

## The detector for methods nothing calls

The family's rule is that an exported setting whose name occurs once in its repository is read by nothing. The same grep over public methods finds methods nothing calls, and on this project it found a physics gun, avatars and a chat history that were built and unreachable. **`addons/` is a symlink per addon and `grep -r` does not follow one**, so use `find -L` or every override of an addon's virtual reads as dead code. The greps are in [detectors.md](../../../docs/detectors.md).

## Looking at it

No suite reaches the screen. The render tools are in [client.md](client.md#looking-at-it).
