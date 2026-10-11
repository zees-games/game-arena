# The client

`ArenaClient` is everything a person needs on top of `ArenaGame`, and a dedicated server never loads it: a camera rig, input sampling, the renderer, the HUD, the menus and the keys. How it predicts and draws between ticks is in [netcode](netcode.md#the-client-predicts-with-the-servers-collision).

## Booting and adopting a player

- **It watches `player_added`, not `player_spawned`.** `player_spawned` comes out of dot-match's respawn queue, which runs on the authority; a mirroring client never fires it. The symptom of waiting on it is the most misleading one here: the HUD binds by id and works, the scoreboard works, the connection is live, and there is no camera and no world, because both hang off that one reference.
- **Offline, the player is named before it is created** (`_start_offline`), which is the order HELLO and JOIN already give a networked client. Otherwise `_on_player_added` gives everybody it does not recognise a body, including the player the camera sits in, and their own nose is a pale slab across the bottom of every frame.
- **A spawn's yaw has to reach this client's sampler.** `DotFpsController.teleport` turns the controller's own sampler and the client samples with its own, so the next command overwrites the yaw. Offline the client turns its sampler on the player's `spawned`; connected, `_face_a_respawn` turns it to the nearest map spawn's yaw when its player is seen dead and then alive. Pits are deliberately not turned there, because they run inside prediction replays.
- **`ArenaHud.catch_up()`** fills the kill feed for a HUD built after kills happened, which is what a client joining a match in progress sees.

## A client knows the mode only for display

A client's `game.mode` is whatever it was built with. The server puts the mode's catalogue index in RULES (`ArenaGame._announce_mode` at setup and on every map change); a client keeps it as `shown_mode`, and `displayed_mode()` is what the keys and the banner ask. Its own `mode` is never replaced, because logic reads it. `props_on_e` read `game.mode` once and E launched instead of grabbing in the props modes.

## The mouse

**The client owns the mouse; `DotScreenStack.manage_mouse` is off.** dot-ui's stack forces CAPTURED whenever no screen is open, which is right on a desktop and impossible in a browser: pointer lock needs transient user activation, and a browser refuses it silently while `Input.mouse_mode` reads back CAPTURED. Two owners fighting is a cursor that flickers, so there is one, and it knows about the click.

## Keys

E launches (dot-player-controller's launch, the movement command's first user bit), except in a mode where players use props (`ArenaClient.props_on_e`), where E is the prop tool and the launch moves to X. C or Ctrl at a run slides. Shift dashes. Right mouse aims (zee's `ZeeViewModel.aim`) and F is the bash; the `right_mouse_aims` setting (ACCOUNT scope) swaps the bash back onto right mouse, and in a mode where F is the prop tool's freeze the bash is right mouse's. Fire, reload and the scoreboard are matched on a keycode in `_unhandled_input` and are not `InputMap` actions; the bindable actions are `dot_fps_*` (from `DotFpsSampler.register_default_actions`) plus `arena_*`, which is why the rebinder's panel filters on `dot_fps_` and `also_prefixed` `arena_`.

## The camera is written in exactly one place

`ArenaPlayer.present` writes the camera. Shake is handed to the player as `camera_offset` / `camera_roll` rather than written by whoever computed it; the weapon's view punch is added there too. dot-fx computes a displacement and touches no camera, so one implementation serves the play rig, a spectator's and a headless suite. `attach_camera` is idempotent and re-applies the field of view when called again, or a player who moves that slider sees nothing happen. Aiming scales the lens from the player's own field of view, never from the last zoom.

`field_of_view` is why dot-settings has `SERVER_CLAMPED`: a server may cap it (a wide view is a competitive advantage) but never reads it, because a server reading the field of view, the sensitivity, the bindings or the audio device would be assembling a fingerprint that survives a new account and every ban. A clamp is a bound: a player who prefers 90 keeps 90 under a cap of 100.

The death camera is driven once a frame, not once a tick ([modes](modes.md#spectating)).

## The presentation layer

`ArenaPresentation` holds dot-settings, dot-audio, dot-fx and dot-console on the client. What was missing for a long time was never the files; it was the decision about what is audible, how many at once, how loud, and how far away it stops mattering, which is a document:

- Every weapon sound is positional with a real cull distance, because a shot you cannot place is a shot you cannot answer. A hit marker is flat: it is information about your own shot.
- `max_concurrent` is 3 on a rifle. Twelve in one tick is one gunshot twelve times as loud, with comb filtering.
- The shot is predicted on the client that fired it. Safe because a sound never changes the simulation: a shot the server later refuses cost a noise.
- **No audio files ship.** The catalogue names paths in `audio/` that do not exist; `sound_recipes()` maps each id to a `DotAudioSynth` voice and `DotAudioSinkGodot` falls through to that bank. Weapons get different voices on purpose: hearing somebody's shot is knowing what they hold. Dropping in real files switches the stand-ins off one id at a time. zee-dot-weapons brings its own baked reports; these are only what a client shell too old to carry `ZeeShotFx` falls back to.

**dot-effects and dot-fx are different things and this game has both.** `ArenaEffects` is burning, slows, invulnerability: things that change the simulation. `ArenaPresentation` is what they look like, and never changes the simulation, which is what lets a frame budget drop one.

### Effect scenes

`scenes/fx/` holds `muzzle_flash`, `impact_spark`, `bullet_hole`, `death_burst` and `explosion`, plain scenes with no script and no external resource, so a delivered pack has no path inside them to rewrite. `CPUParticles3D` rather than GPU so headless and Dummy renderers run them like anything else. dot-fx refuses a missing scene silently at DEBUG (a client whose pack is still arriving legitimately asks for scenes it lacks), so `_build_fx` warns when one is missing and `headless_presentation` asserts `missing_scenes()` is empty.

- **Every effect is built against one frame, `ArenaPresentation.facing(at, direction)`: -Z along the shot.** A `DotShot` carries no surface normal, so the hole's decal projects along the shot, which lands it on a wall, a floor or a ceiling alike.
- `ArenaPresentation.on_used(outcome)` is the loop, so the suite drives the exact path. The flash is placed `MUZZLE_OFFSET` along the aim and a little below and right, because a shot starts at the eye.
- The explosion is its own scene; reusing the death burst read as somebody dying.
- A one-shot shorter than a frame is not drawn (`CPUParticles3D` ages it by the first frame's whole delta). Irrelevant at 60 fps; it is why `--fx` renders slow the particles.

## Screens

- **The pause menu is dot-ui's `DotPauseScreen`** (`ArenaMenus`), not dot-menu's Escape menu, which every other game uses. Not converted to dot-menu yet; no reason is recorded (this game's settings are already a dot-settings document, so game-hungario's reason does not apply). Queued as `arena-dot-menu-1`. What is this game's own is `ArenaMenus.PAUSE_BUTTONS` and what a press does; the ids are derived from the labels, so there is no parallel list to disagree.
- **Leave emits `leave_requested`** and does not quit: what leaving means belongs to whatever loaded this client.
- **Servers opens the browser**, and is greyed until there is one: the browser is built after the menus and only when its list came up, so `ArenaMenus.note_screens` re-checks every button once the screen is registered. Greyed rather than removed, so a menu's shape is learnable.
- **Two settings screens.** `settings` is the player's document (`ArenaPresentation.settings`, a `DotSettingsManager`) on dot-ui's `DotSettingsScreen`; `interface` is `DotUiConfig` (scale, safe area, transitions) on a second `DotSettingsScreen` with `id_override` and `title_text`. Opening "Settings" to turn the game down used to find the interface scale. With no presentation manager the Settings button is greyed rather than opening nothing.
- **The Tab scoreboard is dot-menu's `DotMenuScoreboard`.** K, D, A, Score, then Time and Ping; rows from dot-match sorted by rank; on a connected client the server's roster (`DotClientLink.want_scoreboard`, sent only while Tab is held) is merged by player key. A team mode groups rows under the sides. Offline, Time and Ping read "-".
- **Build a screen's focus path after it is registered.** `initial_focus = button.get_path()` before the node is in the tree errors and the menu opens with nothing focused.
- `sensitivity`, `invert_pitch` and `crosshair` are pushed by `ArenaPresentation.bind_look` / `bind_crosshair` at bind time as well as on `changed` (a loaded value has not changed), and again when the sampler gets its player's tunables, a new object carrying the default. Sensitivity is 0.022 degrees per count, the same as game-g2gfast, because it is an ACCOUNT setting in the shared namespace.

## The HUD

- `ArenaHud._make_label` grows both ways: a centre-top preset is a zero-width box and a wider `Label` grows by `grow_horizontal`, which defaults to END.
- `ArenaHud.match_view` reads the camera's own `fov` each frame for the crosshair's spread, because the camera is where the slider, a server clamp and the first `attach_camera` all end.
- Full-screen overlays (the blind, the low-health edge, the scope) are sized to the viewport, not to the HUD: `DotHud` insets itself by the safe area and the first renders left a frame of world round the edge. The blind sits under the HUD's widgets so the clock and kill feed still show.
- `ArenaHud.notice` is a centre line held four seconds: chat lines, map-change notices, the mode banner, the end-of-match MVP.
- Also drawn: the streak meter, a hit cross (red for a headshot), "HEADSHOT!" over the victim, the death panel with nemesis and revenge, the launch and dash readout, coins, and a health bar over a hurt enemy for three seconds (two quads turned to the camera each frame).

## The chat box

A chat box is a HUD widget, not a `DotScreen`: a screen is modal and takes the display, a chat box is eight lines in a corner that leaves the game visible. It is dot-ui's `DotChatWindow`, built by `ArenaPresentation` beside the console.

- `chat_window` (`auto` / `on` / `off`), `chat_open_key` (Y) and `chat_team_key` (U), all ACCOUNT-scoped. Off never means out of the conversation: the log keeps drawing; the setting decides whether there is anywhere to type.
- `auto` is answered by the server: `ArenaServices` points `DotChatManager.watch_relay` at its relay, dot-server tells each joining client, and `ArenaClientExtras` turns that into `chat_relay_changed`. A client cannot know on its own whether its room also exists on a web page.
- **`ArenaPresentation.swallows_input()` covers the box as well as the console**, or typing walks the player.
- **The console is dot-console's `DotConsoleKit`**, with `quit`, `audio`, `fx` and `where` added before the server's console. The kit would register it with a `DotMenu`; arena has none, so `ArenaClient._wire_console` suspends the sampler on the console's `visibility_changed`, through the same `_refresh_suspended` as the chat box (`headless_presentation` holds a key down to prove it).
- **`DotFpsSampler.suspended` is set on `opened` and cleared on `closed`.** Movement is polled every physics frame regardless of what consumed an event, so `swallows_input` alone is not enough.
- A line reaches the client on `DotClientLink.chat_received` (dot-server's wire), and `ArenaClientExtras.receive_wire` hands it to `DotChatClient`, which refuses a dictionary with no `m` so the fallback draws it.

## Avatars

`avatars/arena_{body,head}_kenney_<a..r>.tscn` are 18 characters from the CC0 character kit, generated by `tools/build_avatar_parts.gd` out of `avatars/kenney/` because the kit is one mesh set and 18 atlases: 36 hand-written scenes would be 36 chances to get one wrong. The two primitives stay at the front of `BODIES` and `HEADS`, because `[0]` is the schema's default and must resolve without the art.

Three things a straight import gets wrong, all invisible in the file:

- The kit's character is 2.70 m and this game's capsule is 1.8 m. The generator measures the kit and scales it rather than carrying a constant.
- `Transform3D.scaled()` scales the origin as well as the basis; scaling the origin again scales the layout twice and limbs drift from the body.
- `ArenaAvatars` mounts a slot at a point; the body is aligned so its feet land on the floor (the head stays centred). The art fits the rig, not the other way round.

game-g2gfast has its own copy of the generator with its own numbers (a 72-unit hull), duplicated per the family rule. Remote players wear their avatar (`ArenaAvatars.make_rig`) and fall back to the capsule when the schema will not build. Monsters wear the same kit ([horde](horde.md#figures)).

**Your own body in first person** (`arena_fp_body`, off by default) builds the local player a body, hides the head, crest and upper body (the view model draws arms) and draws the legs `FIRST_PERSON_BACK` behind the eye. Off because from the eye the stock blocky avatar's hips are boxes a hand's width under the camera.

**Third person is deliberately not here.** The movement is analytic and lag-compensated, and server and clients agree because there is exactly one motor to agree about. game-playground is where third person runs.

## Looking at it

No assertion sees the screen. Render and look after any change to the client, a menu or a map:

- `tools/screenshot.sh <map>` renders a map from three angles into `screenshots/`, a built-in map under its own lighting document exactly as the client draws it; `RENDERER=gl_compatibility` renders what the client shell draws ([maps](maps.md#colour-and-light)); `--view <name> <from> <at>` adds a frame, `--admin` the beacon and blind, `--fx <eye> <aim>` six shots and a death, `--feel` the HUD, scope, drops and body breaking. On an imported map it plays a short deathmatch first and adds player, ramp, water and booster frames.
- `tools/screenshot_menus.sh` renders the pause menu, the interface screen, the rebinder, the scoreboard, the HUD with the chat box, and the console open (`hud_console.png`). The chat box sits at `margin_bottom = 110` to clear health and armour, and only the picture can say whether 110 is right. It refuses to save a grey rectangle when a `push` fails.
- `tools/screenshot_weapons.sh` plays the offline client through its own input path.
- `~/stack/game-dev/tools/screenshot.sh game-arena out.png --wait 35 -- --offline` is the real offline client. Arena starts in warmup, so an early frame lies.

All need `xvfb-run`: under `--headless` every saved frame is empty, which looks like a screenshot.
