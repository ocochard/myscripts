# Close-combat mission (GPU-skinning view-LOD stress)

A CWR-CE test scene that packs **110 soldiers at the view LOD** directly in front
of an eye-level camera, so the `--gpu-skinning` path is actually exercised. Built
to give GPU skinning a fair FPS test after the stock `Benchmark.Abel` patrol
(units at camera distance → coarse LODs) measured as a no-op on the t420.

See `../MISSION-SQM-FORMAT.md` for the sqm format, coordinate conventions, the
camera-init pattern, and the design rationale. See `../DEBUGGING.md` for the
benchmark command and screenshot capture.

## Files

- `mission.sqm` — the generated scene (11 groups × 10 soldiers, 2 m spacing,
  frozen with `disableAI "MOVE"` so the grid holds, eye-level camera 3 m ahead of
  the block on Malden = island "Abel").
- `gen_closecombat.sh` — regenerates `mission.sqm`; tune `ROWS`/`COLS`/`SP` and
  the camera `CAMY`/`CAMH` at the top (denser/closer = more view-LOD load).
- `closecombat_viewlod.png` — reference capture: front rows at full view LOD
  receding into depth.

## Use

```sh
mkdir -p ~/.config/CWR/Users/Test/Missions/CloseCombat.Abel
cp mission.sqm ~/.config/CWR/Users/Test/Missions/CloseCombat.Abel/mission.sqm

# FPS A/B: run once plain, once with --gpu-skinning, compare BENCHMARK RESULT
env DISPLAY=:0 XDG_RUNTIME_DIR=/tmp/xdg PoseidonGame -C ~/.local/share/CWR/base \
  --no-splash --no-sound --benchmark \
  --test-mission ~/.config/CWR/Users/Test/Missions/CloseCombat.Abel [--gpu-skinning]
```

`--benchmark` counts frames on whatever `--test-mission` loads, so the
`prof_bench.sh` / `t420_bench.sh` harness works by passing the mission name.
