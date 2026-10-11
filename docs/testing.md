# Testing

The family's rules for checks are in [testing.md](../../../docs/testing.md) and [bugs-found.md](../../../docs/bugs-found.md). `./game.sh test` runs the parse pass and every suite with a timeout and the stderr check, and writes each suite's log to `.godot/test-logs/`; `./game.sh test <suite>` runs one.

**Run the suites after changing any dot-* addon this game links.** That is what this project is for.

## The suites

| Suite | What it drives |
| --- | --- |
| `headless_match` | an `ArenaGame` directly, no socket, no rendering. Bots aim at the nearest player and hold the trigger. Modes, maps and the survey, map changes, the horde, objectives, effects, progression, weapons, drops, gun game, lag compensation, every medal rule beside its near miss, the wall cvars and "off is what it was", every map's wall routes driven through the motor |
| `headless_net` | a server and a client in one process over a loopback that drops packets: the wire, mirroring, prediction, config agreement, the death camera on a client, weapons and projectiles, movement rules, a wall run and a chimney climb predicted from the client's own state, admin flags, an imported map |
| `headless_lossy` | real ENet through real loss (below) |
| `headless_presentation` | the client's presentation layer, effects, HUD pieces (HIT and AWARD read off the wire into the hit marker, numbers, medals and points), the private match over HTTP, every key the client reads as a rebindable action (fire, a slot, the props-mode remap, a saved binding after a restart) |
| `headless_stack` | the player stack: spawning, sides, protection |
| `headless_admin` | the admin tools on a real `DotServer` with the module loaded by path |
| `headless_imported` | a deathmatch on a combat surf map: catalogue, spawns, floors, ramps, pits, surf air control, mechanics, delivery from a fake mount. Skips, and says so, without the g2gfast-maps link |
| `dedicated` | a real `DotServer` loading `ArenaModule`: boot, commands, the vote's clock, bots, unload, exiting clean |
| `headless_feel` | what each rendered frame shows, at a display rate (below) |

**`headless_presentation` is reachable from none of the others.** `headless_match` plays with no client and `dedicated` never connects one, which is how a module looked a session up by the wrong key and nobody could join a dedicated server while `dedicated` passed throughout. `dedicated` does not connect a client on purpose: dot-platform and game-hungario's `sandbox` already run that seam over a real socket.

`headless_match` asserts what did not happen as well as what did: nobody fell through the floor, nobody left the room, and the geometry blocks shots, because if the trace ignored the map every other check would still pass.

## headless_lossy: real ENet through real loss

Servers listen on ENet as well as WebSocket, and over WebSocket "unreliable" is TCP. `headless_net`'s loss is its own loopback dropping packets in order and instantly. `examples/headless_lossy` puts dot-net's lossy UDP relay (`res://addons/dot_net/testing/dot_net_udp_relay.gd`, by path; see [dot-net's testing.md](../../dot-net/docs/testing.md)) between a real `DotClientLink` on ENet and a real dual-stack `DotServer` running `ArenaModule`. Client A goes through the relay and runs, strafes and turns every tick; client B connects straight and runs a circle, the smooth reference A's drawing is held to; a dummy is slain every 1.2 s for the kill feed. Each end has its own `MultiplayerAPI` (`SceneTree.set_multiplayer`), so one process holds all three.

It measures A's first three seconds, then a steady 55 ms window and 5% and 20% loss with 30-80 ms of uniform delay (so packets reorder): connection, injected loss, clock settling, the share of server ticks with A's command, B drawn every frame without freezes or jumps and close to where the server had him at render time, render-timeline steps back, extrapolation, A's prediction against the server tick for tick, `DotNetStats.loss_rate()` against the relay, and every numbered notice, kill and chat line exactly once and in order. After the windows, A runs dm_box's north wall and kicks off it through the 20% loss: both ends run and jump once, A hears each once, and its prediction stays within the windows' 5 cm. It plays in real time (about 50 seconds). `--verbose` prints the diagnostics. It is in `./game.sh test`; it was out while it failed one run in four, and the remaining heavy-loss stalls are queued ([netcode](netcode.md#still-open)).

## headless_feel: what a frame shows

Every other suite asserts a simulated value, and every simulation-to-screen bug passes all of them (the family's render jitter class). `examples/headless_feel` draws at `Engine.max_fps` (60 or 144), not the tick rate, and judges each frame's step against the motion it was drawn on: the local eye and an offline bot against the step between their last two ticks, a connected bot against the server's own track at the render time the interpolator drew (`DotNetClock.render_alpha` + `receive_slip`). A frame across a corner (a wall, a landing) is not judged, since no one velocity says where it should have ended, so every runner runs circles on open floor.

- **Offline**: the real `ArenaClient` runs, strafes and turns among its bots, which run circles (`bot_scripted`; a hunting bot shoots the player). Checks the view turns evenly, the eye, the bots drawn between ticks, the view model's bob.
- **Moves**: a player of its own on dm_box through `ArenaPlayer.present`, up the stair at a run (no frame rising more than 2.5 times the climb's average), a slide, a jump and a landing (printed).
- **Connected**: a dual-stack `DotServer` with one server bot whose commands the suite writes, and the real client over ENet through dot-net's relay, in six windows: 60 Hz and 144 Hz steady, the link's delay going 40 to 70 ms and back (which makes the clock drift, so physics frames run 0 or 2 ticks, and makes the receive timeline re-anchor), and 5% and 20% loss with 30..80 ms. The eye is not judged while the link slows: commands then reach the server late and the prediction is corrected dozens of times (`dot-net-input-lead-1`); the numbers are printed.

Before and after the 2026-10-11 fixes, same suite: 25 of 33 passed, now 33. Offline bots 2144 of 2144 frames over 2 cm off their motion (max 86 mm), now none (max 6 mm); the view model's p99 change of a frame's movement 2.98 mm, now 0.19; the stair 160 mm in one frame (6.7 times the climb's average), now 50 (2.0); the eye at 60 Hz and through 5% loss 2 to 4 frames 15 to 16 cm off, now none; the connected bot's render time going back 2 to 5 times a window, now never. It plays in real time, about 90 seconds; `--verbose` prints every frame it failed and why, `--only offline|moves|<window>` runs one part. The process draws at most about 145 frames a second with a server in it, so there is no 240 Hz window. Three runs in a row passed before it went in. `tools/render_feel.sh` draws the same moves to look at ([client](client.md#looking-at-it)).

## Traps the suites have hit

- **Read a suite's stderr even when it exits 0.** A script error aborts its section, not the run; four freed-object errors in `headless_match` once left every check passing.
- **Filter `--check-only` for the lines that mean a parse failed** (`SCRIPT ERROR`, `Parse Error`, `Failed to load script`), not against shutdown noise by exact wording, which goes stale when the engine rewords a line.
- **A scene whose script fails to parse hangs** rather than exiting. Cap every run with `timeout`.
- **An adopted session has no peer**, so a suite that adopts one catches what is sent to it, or every send is "Attempt to call RPC with unknown peer ID" in a green run. Either point the netcode's `send_fn` at nothing (`_test_bots`, `headless_admin`) or set the bridge link's `loopback` and check what it caught (`dedicated`'s `_test_client_spawn`: the join's schema event, then a snapshot per tick to 4242 through four sections). The adoption is what starts the sends, so catch before firing `client_spawn`.
- **Every position check starts on a spawn point**: `dm_box` has a platform at the origin and a body teleported there is pushed out.
- **A map check drives a walking bot** ([maps](maps.md#every-map-is-surveyed)).
- **A check that depends on how an earlier section ended is not a check.** The horde gunner check chooses a spot with line of sight and strips spawn protection from its target; the movement-rules section runs after the weapons section because this harness fires every eighth tick and spent the magazine.
- **A wait in `headless_lossy` on anything sent reliably is `RELIABLE_SECONDS` (35 s), never a guess.** ENet doubles a command's resend timeout each time it goes unacknowledged and a try fails on the data or the ack (36% at 20% each way), so the tail is seconds long and real; dot-core's peer timeouts make 30 s the contract. Every shorter wait written there flaked on it: 6 s for the windows' streams, 10 s for B's leave, 5 s for the `mp_teammate_passthrough` changes ([history](history.md#the-wire)). The wait ends on arrival; put the time in the detail.
- **`headless_net` has no input lead**: a lost packet is a tick the server runs on the previous command, so a check of a predicted move there allows a hand's width mid-move and asks for agreement once down. `headless_lossy` has the real buffer and holds 5 cm.
- **A suite or render tool never writes the player's settings.** `headless_presentation` typed `field_of_view 120` at the console into this machine's real `user://arena_settings` on every run, and every session and screenshot after it drew at 120. `ArenaPresentation.use_scratch_settings(<tag>)` points every presentation built after it at an emptied `user://scratch/<tag>/`; `headless_presentation` and all four tools that build a presentation or a client call it first, and the suite checks the player's file was not touched.
- **A frame-by-frame check measures against what the frame was drawn on.** Against the state's velocity it flagged every wall the runner touched; against `interpolate_frame`'s render time without the clock's slip terms it flagged dot-net's own easing (`headless_lossy`'s render tick reads them by name).
- **Arm every new check**: put the bug back and watch it fail. A check that has never failed may be asserting the bug (the effect-scene check once asserted a gib was refused "for the missing file").

## The detector for methods nothing calls

The family's rule is that an exported setting whose name occurs once in its repository is read by nothing. The same grep over public methods finds methods nothing calls, and on this project it found a physics gun, avatars and a chat history that were built and unreachable. **`addons/` is a symlink per addon and `grep -r` does not follow one**, so use `find -L` or every override of an addon's virtual reads as dead code. The greps are in [detectors.md](../../../docs/detectors.md).

## Looking at it

No suite reaches the screen. The render tools are in [client.md](client.md#looking-at-it).
