# Weapon lab

One fixed room, one fixed first-person camera (the player's own, standing at spawn, no look input), one fixed model-viewer
camera (30 degree fov, orbit about the model's bounds centre) and one fixed sun/ambient, so only the weapon and its animation
change between clips and runs. Built by `tools/weapon_lab.gd` (a SceneTree script driving the offline arena client with the
arena hidden); nothing in the game is touched.

## Run it

    sudo -u gamedev tools/weapon_lab_all.sh --run mytag              # every weapon, all animations + model viewer
    sudo -u gamedev tools/weapon_lab_all.sh --run mytag --only rifle,pistol --anims fire,reload_empty --no-turntable

`weapon_lab_all.sh` (dev02) splits the weapons over `LAB_SHARDS` (default 4) gpu.sh projects `wl-0..3` alternating between
`staging` (1660 Ti) and `staging02` (2070) (`LAB_BOXES`), so each shard has gpu.sh's per-project lock and a normal shot slot and does
not collide with other agents' jobs. It needs `GODOT_ROOT` symlinks (made in `/home/gamedev/wt/.lab-root`). In a fresh worktree run
`hv import` first. Output: `/home/gamedev/weapon-lab/out/<run>/`, published to `~/docs/weapon-lab/<run>/index.html`.
One weapon alone, on one box: `gpu.sh shot proj tools/weapon_lab.sh --out DIR --only rifle`.

## Per weapon (`<run>/<id>/`)

- `fp_<anim>.mp4` and `fp_<anim>_strip.png` (8 evenly spaced frames) for idle, draw, holster, fire, ads (in and out), reload_empty
  (magazine 0), reload_tactical (one round short of full), melee (bash), sprint. 960x540, 30 fps fixed-step.
- `inspect` is reported `n/a` in `manifest.json`: arena-weapons has no inspect animation yet.
- `tp_turntable.mp4`, `tp_orbit_strip.png` / `tp_orbit_<yaw>.jpg` (8 yaws, 12 degree elevation), `tp_closeup_{top,under,muzzle,rear,side_r,side_l}.jpg`
  and `tp_closeup_mag_{90,270,0}.jpg` (the magazine model in place on the weapon) for texture and mag work.
- `manifest.json`: per animation status (ok / n/a with reason), frame counts.

## Notes

- Weapons are the arena catalogue (`AwWeaponCatalogue`, the arena-weapons pack). zee-dot-weapons is not loaded by arena.
- The boxes need nothing but godot, xvfb-run and ffmpeg (they have all three). The JPEG frames are deleted after encoding.
