# Animation review

How to find and fix glitches in fc-weapons' first-person and third-person animations (reload, draw, holster, arms) by looking at them. A check can only flag a problem; the sheets are what you judge.

## The loop

1. Capture: `tools/anim_review.sh . <weapon[,weapon]|all> [--anim reload_empty,draw]`, run as gamedev from the checkout or a `~/wt` worktree (`sudo -u gamedev env WT_ROOT=$HOME/wt tools/anim_review.sh . rifle`). The default clips are idle, draw, holster, fire, ads, reload_empty, reload_tactical, sprint and inspect.
2. Read `screenshots/anim_review/report.md`: one row per weapon and clip with PASS, FAIL, N/A (the weapon has no such clip: no magazine, no sights) or MISSING (no inspect animation), the failing metrics with their frame numbers, and the paths of both sheets.
3. Open **every** sheet with the Read tool, FAIL rows first, then every reload and draw sheet even when it passes. Judge each by the [checklist](#reading-a-sheet).
4. Fix what is wrong where it lives: the weapon pose and rig in arena-weapons (`view/aw_weapon_pose.gd`, `view/aw_view_model.gd`, `runtime/aw_weapon_rig*.gd`), the arms and grip in dot-player-char (`DotPlayerViewArms`, `DotViewGrip`), or one weapon's numbers in its def. Work in a `~/wt` worktree of that addon with a board claim, and link the worktree's addon into your game worktree for the run.
5. Capture again with `--anim` limited to the clips you touched, read the sheets again, and repeat until the report is clean and the sheets look right.
6. Run the game's suites (`./game.sh test`) once before committing an addon change.
7. File a nightly item per weapon for anything left, naming the clip, the frame numbers and the sheet.

## What it captures

`tools/anim_review.gd` extends `tools/weapon_lab.gd`. For each weapon the offline client is built, the weapon is put in hand on a flat floor, and each clip is played at a fixed 30 frames a second (`--fixed-fps 30`). Every frame saves two images:

- first person: the client's own camera, the arms and the view model, with your own body left out;
- third person: a fixed camera 2 m behind and to the right of the player, looking at the waist, showing the whole figure with the gun in its hands as other players see it.

`tools/anim_review_shot.sh` turns the frames into contact sheets with ffmpeg: every second frame (15 a second), eight to a row, each cell labelled `#<frame> <seconds>s`. The frames themselves are deleted, so read the sheets.

A draw or holster is a real switch (`DotWeaponArsenal.select`, the holster then the deploy, as a slot key does), never `equip`, which is the spawn hand-out and swaps instantly. The draw starts from another slot (often a grenade), so its first frames show that weapon going down.

## Where it runs

- `heavy` hands `tools/*_shot.sh` to a GPU box (staging or staging02) through gpu.sh, which needs gamedev's box key, and brings the sheets back. gpu.sh may print "could not copy the frames back" because the frames are already deleted; the sheets still arrive.
- If rsync cannot write into `screenshots/`, make the folder writable for gamedev first (`chmod -R a+rwX screenshots`).
- `--soft` keeps it on the local machine with software rendering. On dev02 that build crashes (signal 11 in llvmpipe), as `weapon_lab.gd` does too, so use the GPU route.
- One weapon with one clip takes 1 to 3 minutes; every weapon with every clip takes much longer. Run it in the background and poll.

## The metrics

Every frame is sampled just before it is drawn. Each clip's verdict, with every frame's numbers, is in `<weapon>/fp_<clip>_metrics.json` when the capture ran locally; the GPU route brings back only the sheets and the `ANIMREVIEW` line in the log.

| Metric | Fails when | What it usually is |
| --- | --- | --- |
| pop (`<part> jumps … m at #n`) | a hand, an elbow or the weapon moves more than 0.04 m in one frame (0.09 m in a fire clip, where each shot kicks the gun by design), and more than 3 times as far as in the frames on either side | a missing key, a pose snapping between two blends, a reload phase starting from the wrong place |
| turn (`weapon turns … deg at #n`) | the weapon turns more than 25 degrees in one frame, 3 times its neighbours | the same, in rotation |
| hand off grip | a hand more than 0.06 m from its grip point | IK not reaching, a grip point wrong for this weapon |
| forearm inside weapon | the forearm (elbow to just short of the wrist) more than 0.03 m inside one part of the weapon (receiver, scope, magazine); the air under a scope does not count | the hands placed too far forward or the weapon too close |
| arm through near plane | any visible arm point closer than the near plane plus the arm's radius | the arms clipped open at the screen edge |
| weapon through near plane | the weapon cut more than 0.005 m by the near plane | a muzzle or stock poking through the camera |
| wrong hand | the left hand nearer the main grip than the right for more than 2 frames | mirrored arms, a swapped grip |
| T-pose | the upper arm straight out sideways and level in a frame, for an arm with some of its forearm on screen (the free arm of a one-handed weapon hangs out of view) | IK not applied, a missing skeleton pose |
| weapon drawn without arms | the model shown, not scoped, with no arms holding it, for more than 3 frames | the arms losing the weapon after a swap |
| no draw / holster motion | the deploy fraction never goes below 0.9 in a draw or holster | an instant swap with no animation |
| tp body pop | dot-core's `DotClipMetrics` bone pop on the third-person figure | the body snapping between animations |

The pop checks skip the frame where the weapon node changes and the hands' regrip in the frame after it, so a swap is not a pop, and a hand jump off screen in both frames (the free hand of a one-handed weapon going to rest). A loop discontinuity shows as a pop where the clip wraps (idle, sprint).

## Reading a sheet

Read the first-person sheet left to right as a flip book, then the third-person sheet. Look for:

- a cell that does not follow from its neighbours (a pop the threshold missed);
- the gun or a hand cut off at the edge of the screen;
- an arm passing through the gun, or a hand floating off it;
- the hands crossing to the wrong side, or a left arm holding the trigger;
- arms straight out (a T-pose), or arms with no gun;
- a reload that never takes the magazine out, or puts it back in the wrong place;
- a draw or holster with no motion, or a gun that ends somewhere other than where idle holds it;
- in third person, the gun out of the hands, held at the knee, or pointing away from where the player looks.

Frame 0 of a third-person sheet can show the scene before the camera is placed; ignore it.
