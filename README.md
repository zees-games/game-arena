This is a game to demonstrate the capabilities of the [**Dot collection**](https://moddingcommunity.com/co/4-dot-assets) built on-top of [Godot 4](https://godotengine.org/) and [TMC's gaming platform](https://moddingcommunity.com/play). In this 3D game, players engage in an arena with different objectives, such as deathmatch, free-for-all, gungame, and more.

![Preview](https://github.com/zees-games/game-arena/blob/main/images/preview.gif?raw=true)

*Play on my test server [here](https://moddingcommunity.com/arena/s/arena01/play)!*

**This project and the assets under it are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This project, along with every asset it is built on, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** It has its own headless test suite and that suite passes, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## How it plays
Arena is a fast first-person shooter on three dev-textured maps (`dm_atrium`, `dm_pit` and `dm_box`) and the combat surf maps: small surf maps built for fighting rather than for a timer, imported by [game-g2gfast](https://github.com/zees-games/game-g2gfast) and kept in [arena-surf-dm-maps](https://github.com/zees-games/arena-surf-dm-maps). The game does not come with them: a server names them in its content configuration and each is fetched as its own pack. Two of them are in the rotation by default (`surf_10x_reloaded_fixed` and `surf_110b_austinpowers`); the rest are installed and can be played with `arena_map <id>`. On a surf map the air control is the surf genre's, so you can ride the ramps; on the arena's own maps it goes back to the arena's. It is also the reference game for the Dot collection: when a new game is started, this is the one it is copied from.

There are seven modes:

| Mode | |
| --- | --- |
| Free-For-All | Everybody for themselves. First to 25 kills. |
| Team Deathmatch | Red against Blue. First side to 75. |
| Siege | Everybody for themselves, with a horde of monsters in the arena and props to throw. |
| King of the Hill | One point in the middle. Hold it for ninety seconds. |
| Capture the Flag | Take theirs to yours. First side to 3. |
| Gun Game | Every kill gives you a different gun. First through the list wins. |
| Only Snipers | A random sniper on every spawn. First to 25. |

The weapons are all twenty-seven from [zee-dot-weapons](https://github.com/zees-games/zee-dot-weapons): melee weapons, sidearms, rifles, heavies and grenades, each with a view model, a world model, sounds and recoil. A loadout is a melee weapon, a sidearm, a primary, a grenade and armour on a seven-point budget. A headshot kill drops coins and a health pack, and kill streaks earn rewards. Every hit and kill is confirmed by the server and felt on screen: a hit marker, damage numbers, medals (First Blood, Headshot, Double, Triple and Multi Kill, Revenge, Shutdown, Point Blank, No Scope, Long Shot, Nemesis) with a sound each, a killstreak meter, and the points for each kill beside the victim's name.

A match starts in warmup, then counts down, then goes live. Nobody spawns until it is live (about thirteen seconds on the default rules), so an empty room at the start is normal.

## Controls

| Key | Action |
| --- | --- |
| **WASD** | Move |
| **Space** | Jump. Hold it to keep hopping |
| **Ctrl** | Crouch |
| **Alt** | Walk |
| **C** | Slide (Ctrl at a run does too) |
| **Shift** | Dash |
| **E** | Launch yourself forward |
| **Mouse 1** | Fire. Hold to cook a grenade, let go to throw it |
| **Mouse 2** | Aim down the sights |
| **F** | Bash with whatever is in your hand |
| **R** | Reload |
| **1**-**5** / wheel | Weapon slot: melee, sidearm, primary, heavy, grenade |
| **Q** | Last weapon |
| **V** | Push to talk |
| **Y** / **U** | Chat / team chat |
| **Tab** (hold) | Scoreboard |
| **H** | Help: the modes and every key as you have it bound |
| **Esc** | Menu, and release the mouse. Leave is at the bottom |

In Siege, **E** picks up and drops a prop, **F** freezes it, **G** punts it, and launch moves to **X**.

Every key except Esc can be moved under Menu → Controls; the change applies at once and is saved.

## Getting started
You need [Godot 4.7](https://godotengine.org/download). The game is built from twenty-six Dot addons, each in its own repository, so the easiest way to get everything is [dot-bootstrap](https://github.com/modcommunity/dot-bootstrap). It clones every project and links the addons into each one:

```bash
git clone https://github.com/modcommunity/dot-bootstrap.git
cd dot-bootstrap
./bootstrap.sh
cd projects/game-arena
./game.sh
```

On Windows, run `bootstrap.ps1` instead and open the project in Godot.

`game.sh` does everything else:

| Command | What it does |
| --- | --- |
| `./game.sh` | Play offline against bots, in a window |
| `./game.sh online` | Start a local server and the browser client, and print the link to open |
| `./game.sh online down` | Stop them |
| `./game.sh server` | Start a local dedicated server only |
| `./game.sh test` | Check every script and run every test suite |
| `./game.sh shot` | Save a screenshot to `screenshots/` |
| `./game.sh help` | All of the options |

The combat surf maps come from arena-surf-dm-maps, which bootstrap links in at `maps/imported`. Without it the game plays its three own maps. `./game.sh -- --offline --map surf_10x_reloaded_fixed` plays one offline.

`online` and `server` use [dot-server-deploy](https://github.com/modcommunity/dot-server-deploy), which bootstrap clones next to this one. Run its `./setup.sh` once first.

## Running a server
Settings are cvars. Set them in the server's config, on the command line, or live from the console. `cvarlist arena_` lists every one with its description.

```
arena_mode free_for_all        // free_for_all, team_deathmatch, siege, king_of_the_hill, capture_the_flag, gun_game, only_snipers
arena_scorelimit 25            // kills to win (a side's in a team mode); 0 for the mode's own; gun game ends at its last gun
arena_timelimit 600            // seconds a match lasts; 0 for the mode's own
arena_warmup -1                // seconds of warmup before a match; -1 for the mode's own
arena_minplayers 1             // players needed before a round starts
arena_wall_run 1               // run along a wall in the air (0 off); arena_wall_jump, arena_wall_slide likewise
arena_wall_run_min_speed 9.5   // m/s along the wall to start a run (arena_wall_run_end_speed 3 ends it)
arena_wall_run_time 1          // longest a run lasts, seconds (at most 1.9)
arena_wall_run_gravity 0.25    // share of gravity felt on the wall; arena_wall_run_damping 8, arena_wall_run_max_fall 6
arena_wall_run_angle 60        // widest angle off the wall to start a run; head-on is no run
arena_wall_jump_push 7         // space leaves the wall: push m/s, arena_wall_jump_up, arena_wall_jump_look, arena_wall_jumps, arena_wall_jumps_per_wall
arena_wall_run_body_roll 25    // degrees a drawn body rolls on the wall; arena_wall_run_body_yaw 12 turns it toward it
arena_streak_rewards ""        // kill streak rewards as streak:reward pairs (heal, armour, haste, empowered)
arena_spawn_mode avoid         // avoid, weighted, furthest or random
arena_imported_rotation "all"   // combat surf maps in the rotation: all, none, or ids
arena_surf 1                   // a combat surf map plays with the surf air control (1) or the arena's own (0)
arena_surf_airaccelerate 150   // the air acceleration on a combat surf map
mp_teammate_passthrough 1      // team modes: 0 a team-mate is hit and blocks, 1 shots pass one at the muzzle, 2 every team-mate in the line
```

`mp_teammate_passthrough` is the family's shared one from dot-combat, live from the next shot, and covers rockets and grenades in flight too. At 2 a team-mate never stops a shot; a blast still reaches them.

Dead bodies fall as ragdolls, from [dot-player-char](https://github.com/modcommunity/dot-player-char). The server picks how each one goes down and every player sees the same fall:

```
sv_ragdoll 1                   // 1 a physical body, 0 a quick fall with no physics
sv_ragdoll_style ragdoll       // ragdoll, stiff (one piece), topple (no physics) or hide (vanishes)
sv_ragdoll_time 10             // seconds a body lies there before it fades
sv_ragdoll_max 8               // most bodies at once; the oldest fades to make room
sv_ragdoll_force 1             // how hard kills throw bodies; 0 drops them where they stood
sv_ragdoll_reactions ""        // weights, e.g. "headshot_launch=6,power_launch=8,face_plant=1.5,crumple=2.5,limp=4"; 0 turns one off
```

A headshot can throw the body up and back, the sniper rifle and the rocket launcher always throw it, the shotguns and the heavy melee can, and anybody may go down on their face with a smack or crumple where they stood.

Bots come from [dot-bot](https://github.com/modcommunity/dot-bot), and they play the same way solo and on a server:

```
bot_quota 4                    // players to fill the server to; people take a bot's place
bot_quota_mode fill            // fill, fixed, per_player or off
bot_difficulty medium          // easy, medium, hard or nightmare
bot_reaction 0.3               // any single setting of the preset, e.g. seconds before a bot fires on somebody new
```

`bot_difficulty` sets about thirty `bot_*` settings at once (reaction time, aim error and how fast it settles, turn speed, view cone, hearing, strafing, peeking, preferred range, bursts and more). Change any one of them after choosing a preset and it stays changed; `bot_settings` lists them all and `bot_settings_reset` goes back to the preset. dot-bot's README has the full table. Solo, the same names work in the console (the key under Escape), `bot_quota` counts you as one of the players, and `./game.sh -- --bot_difficulty hard --bots 5` sets both at launch.

Console commands:

| Command | |
| --- | --- |
| `arena_status`, `arena_score` | The match state and the scoreboard |
| `arena_map <id>`, `arena_maps`, `arena_nextmap` | Change the map, list the maps, see what is next |
| `arena_modes` | List the modes |
| `arena_vote` | Open a map vote now |
| `arena_restart` | Restart the match |
| `arena_horde [clear]` | Show or clear the monsters |

### Admin commands
These come from [dot-moderation](https://github.com/modcommunity/dot-moderation). Type them in the console, or in chat with a `!` in front.

| Command | Needs | |
| --- | --- | --- |
| `noclip`, `god`, `buddha` `[player] [on\|off]` | `cheats` | With no player, they act on you |
| `hp <player> <n>`, `speed <player> <x>`, `gravity <player> <x>` | `cheats` | Speed and gravity go from 0.25x to 3x |
| `give <player> <weapon>`, `strip <player>` | `cheats` | |
| `freeze <player> [seconds]`, `unfreeze`, `slay`, `slap <player> [damage]`, `respawn`, `rename`, `burn` | `slay` | |
| `blind <player> [on\|off\|seconds]` | `slay` | Blacks out that player's screen |
| `beacon <player> [on\|off]` | `slay` | A ring and a ping on that player, for everybody to see |
| `bring`, `goto`, `send <player> <to>`, `return` | `teleport` | |
| `modtools [player]` | `generic` | What is on a player, or what this game supports |

A player can be a name, `@me`, `@all`, `@others`, `@alive`, `@dead` or `@team:<n>`.

### The map vote
The vote for the next map is [dot-vote](https://github.com/modcommunity/dot-vote). The defaults are in `game/arena_vote.gd`. To change them, put a file at `user://cfg/arena_vote.json` (or use `DOT_VOTE_*` environment variables, or `--vote-*` arguments):

```json
{ "end_vote": true, "vote_lead_sec": 120, "include_extend": true, "extend_seconds": 600, "max_extends": 3 }
```

`end_vote: false` turns the end-of-map vote off, and `include_extend: false` takes "extend" off the ballot. dot-vote's README lists every setting.

## Testing

```bash
./game.sh test                    # every script parses, then every suite runs
./game.sh test headless_match     # one suite
```

| Suite | What it covers |
| --- | --- |
| `headless_match` | A whole match with four bots, then the HUD, the menus and the weapons |
| `headless_bots` | A bot at each difficulty against the same reference player: kills and deaths, reaction time, aim, no shots through walls |
| `headless_net` | A server and a client in one process, over a connection that drops packets |
| `headless_presentation` | What a client draws and plays |
| `headless_stack` | The whole stack of addons together |
| `headless_admin` | The admin commands on a real server |
| `headless_imported` | A deathmatch on a combat surf map: spawns, floors, ramps, pits and the surf air control (skipped without arena-surf-dm-maps) |
| `dedicated` | A real server: boots, loads the game, runs its commands, unloads it |

## How the code is laid out
- `maps/arena_map.gd` builds every map from a list of boxes: the meshes, the collision, and what a headless server checks shots against.
- `maps/arena_bsp_map.gd` and `maps/arena_imported_maps.gd` find the combat surf maps and build them from game-g2gfast's map format.
- `game/arena_player.gd` puts movement, weapons, health and hitboxes on one body.
- `game/arena_game.gd` joins the addons together, for example turning a kill into a point.
- `game/arena_module.gd` is the dedicated-server side: cvars and console commands.

[`CLAUDE.md`](CLAUDE.md) has the reasoning behind each of these.

## Credits
The players and bots are dot-player-char's people, from Quaternius' [Zombie Apocalypse Kit](https://quaternius.com/packs/zombieapocalypsekit.html) (CC0 1.0, credited in [dot-player-char](https://github.com/modcommunity/dot-player-char)); the avatar parts and the horde's monsters are people coloured from Kenney's character kit skins, the built-in maps' grid is Kenney's [Prototype Textures](https://kenney.nl/assets/prototype-textures) (`assets/prototype/`), the medal icons are from Kenney's [Board Game Icons](https://kenney.nl/assets/board-game-icons) and [Game Icons](https://kenney.nl/assets/game-icons) (`assets/medals/`), the HUD's ability icons from Kenney's [Game Icons](https://kenney.nl/assets/game-icons) and [Mobile Controls](https://kenney.nl/assets/mobile-controls) (`assets/hud_icons/`), the weapon silhouettes are rendered from the weapons' Kenney models by `tools/build_weapon_icons.sh` (`assets/weapon_icons/`), and the weapons are from [zee-dot-weapons](https://github.com/zees-games/zee-dot-weapons), which credits its own art. Kenney's assets are CC0. The built-in maps' surfaces are photographic PBR materials from [ambientCG](https://ambientcg.com) by Lennart Demes and contributors (CC0 1.0): Bricks097 (walls), Concrete047A (ground), PaintedPlaster017 (structures), Concrete034 (walkways), Metal063 (stairs) and Planks039 (cover), vendored from dot-map's surface library into `assets/surfaces/` (4.4 MB source, about 2.1 MB imported; client-only), asset pages and licence in `assets/surfaces/CREDITS.md`. Footsteps are Kenney's Impact Sounds and the ambience beds are generated by dot-audio, both CC0 and shipped in dot-audio (`addons/dot_audio/stock/CREDITS.md`). The maps' toys are dot-props', drawn from meshes made in code; their sounds are Kenney's (CC0), credited in `addons/dot_props/toys/sounds/CREDITS.md`.

The combat surf maps are other people's work, imported by game-g2gfast. [arena-surf-dm-maps](https://github.com/zees-games/arena-surf-dm-maps) credits each one's author and where it came from (`maps.json`), and `arena_maps` names the author beside each one.

## License
MIT. See [LICENSE](LICENSE).
