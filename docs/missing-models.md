# Imported maps: models that do not resolve

Measured 2026-11-02 over 76 converted worlds (arena-dm-maps 17, arena-surf-dm-maps 39 and the rest) with `bsp.py standins` and a scan of each manifest's props against its model store. Regenerate the first with `python3 -I ~/godot/dot-map-convert/bsp.py standins --tiers placeholder --top 30 <worlds dirs>`.

## Why a player saw an empty street

The converted world and its library models were never part of what a client downloads. A DM map's published pack held the legacy mesh only (no `worlds/<id>/`), so the client drew the legacy meshes (flat `standin_*` boxes for cars, vending machines and crates, no models at all) and collided with the manifest's prop hulls: an empty street, a white box, and invisible blockers. A surf pack carried the world but `licence.model_store` pointed at `../../model-library`, a git-ignored folder that exists only on a developer's disk, so every library prop fell back to a box of its measured size or to nothing.

`bsp.py bundle` (dot-map-convert `dotbsp/bundle.py`) now copies a world with exactly the library models it draws into `worlds/<id>/models/` and points `model_store` there. `arena-dm-maps/tools/stage_packs.sh` and `arena-surf-dm-maps/tools/stage_packs.sh` call it, so a pack is self-contained: Crackhouse is 15 models, 36 MB, cars and van included. Republishing the packs is the step that reaches players.

## Resolved status, all worlds

| | instances | share |
| --- | --- | --- |
| free model (Poly Haven, Sketchfab, Quaternius) | 3451 | 44.3% |
| Kenney block | 2725 | 35.0% |
| generated plain model of the original's size | 620 | 8.0% |
| placeholder (`detail` skip or a box) | 986 | 12.7% |

Every `lib/` prop of the 17 DM worlds (3007) resolves to a file in the store; so do 730 of the surf worlds' library props. `headless_imported` checks this on every run ("no prop collides without a visual").

## Props that draw as a box and collide

Surf worlds, 36 solid props over 6 maps (47 weapon props in all): weapon models (`w_pist_deagle`, `w_snip_awp`, `w_pist_elite`, `w_snip_scout`, `w_rif_aug`, `w_smg_mp5` and others) drawn as a cardboard box with a solid hull, from the `w_\w+` row of `free_models.tsv`. Three more props (`models/my model/circlejaillasers.mdl` among them) have no stand-in at all.

## Most-used placeholders (no collision)

keypad (36 inst, 5 maps), doorknob (30, 2), rebar_cluster001a (15, 2), awning002a (11, 2, drawn as a box), info_speech (9), combineball (10), rockcliff_cluster02b (6), vol_light (7). These are `detail` skips: they draw nothing and collide nowhere.
