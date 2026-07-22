# Paradrop A/B missions (GPU-skinning visual check)

Reusable CWR-CE editor missions built to visually A/B the parachute canopy
skinning (item 5e — `--gpu-skinning`). They spawn the **player** under an open
`ParachuteWest` canopy on Malden (island "Abel") with a scripted external camera,
so the deployed canopy can be captured headlessly via `--auto-screenshot`.

See `../DEBUGGING.md` → "Visual A/B via screenshots" for the full method and the
scripting gotchas (test-mode `--strict`, `_underscore` locals rejected in global
space, `createVehicle` ignores Z, canopy deploys ~3 s, one-shot camera).

## Files

- `paradrop-sideview-cam.sqm` — external camera to the **side** (`+30 m`, `z=96`);
  capture ~frame 240 for a 3/4 side view of the dome.
- `paradrop-topdown-cam.sqm` — external camera above/behind; capture ~frame 200
  for a top-down view of the canopy gores.

Both are the 197-unit `Benchmark.Abel` mission with the player `Item0` given a
parachute + camera `init`; every other unit is unchanged.

## Use

Drop into a Test profile and run headless (repeat with `--gpu-skinning` for the B
side, compare by eye — separate launches are not frame-aligned, so a pixel diff
is meaningless):

```sh
mkdir -p ~/.config/CWR/Users/Test/Missions/Paradrop.Abel
cp paradrop-sideview-cam.sqm ~/.config/CWR/Users/Test/Missions/Paradrop.Abel/mission.sqm

env DISPLAY=:0 XDG_RUNTIME_DIR=/tmp/xdg PoseidonGame -C ~/.local/share/CWR/base \
  --no-splash --no-sound --fullscreen \
  --test-mission ~/.config/CWR/Users/Test/Missions/Paradrop.Abel \
  --auto-screenshot "240:/tmp/canopy.png" --timeout 35
```
