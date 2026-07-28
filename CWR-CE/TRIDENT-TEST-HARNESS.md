# Trident — CWR-CE's built-in test harness

Trident (CLI: **`tri`**, "OFPR test orchestrator 🔱") is CWR-CE's integration/stress test
harness. It's how missions are run for automated testing — functional integration tests,
multiplayer scenarios, and long-running stress runs. Source: `engine/Trident/` (Rust).

## The model

The game binary exposes a **control channel** via `--harness <port>`:

- `PoseidonGame --harness <port>` starts a `HarnessServer` on that TCP port
  (`apps/cwr/Game/GameApplication.cpp:545`). `port=0` → the game auto-assigns and prints
  `HARNESS_PORT=<n>` on stdout.
- `tri` spawns the game with `--harness`, waits for `HARNESS_PORT`, connects a client, and
  drives it over a JSON protocol (`engine/Trident/protocol/harness.schema.json`).

So it's not `--benchmark` (a fixed scripted flythrough) — it's a scriptable, bidirectional
control link: load a mission, evaluate SQF, inject input, query live game state, assert,
capture artifacts.

```
tri  ──spawn──►  PoseidonGame --harness <port>   (game starts HarnessServer)
   ◄─HARNESS_PORT─┘
tri  ──JSON protocol (eval/mission/players/click/key/events/…)──►  game
```

## `tri` subcommands

- **`tri test <paths…>`** — run integration tests. Recursive discovery of `*.test.sqf` and
  `*.test.{island}/` mission dirs. Flags: `--tag` / `--skip-tag` (TOML tags), `--jobs N`
  (parallel), `--retry N` (default 3), `--shard I/N` (CI matrix, balanced by declared
  timeout), `--list`, `--render gl33|dummy`, `--game-arg <arg>` (forward to instances),
  `--game-dir` / `--data-dir`, `--output-dir`, `--profile` (slowest tests).
- **`tri stress <dir.stress>`** — one long-running multiplayer stress scenario (see below).
- **`tri console <host:port>`** — interactive **SQF REPL** on a live instance.
- **`tri describe <host:port>`** — connect to a running harness and print the available
  protocol commands.
- **`tri ping <host:port>`** — ping a running instance.

## Test formats

An integration test is one of:

1. **`foo.test.sqf`** — an SQF script test, paired with **`foo.test.toml`** (same dir) for
   config. The script drives the game and asserts via `tri*` SQF commands.
2. **`foo.test.{island}/`** — a mission directory (`mission.sqm`), paired with
   **`foo.test.{island}.toml`** in the parent. Mission scripts drive the test.
3. **`foo.test/`** with **`test.toml` `[[instances]]`** — multi-instance orchestration
   (e.g. a server + N clients for multiplayer tests).

TOML config keys include: `mission = "path/to/mission.island"` (implies `no_menu`),
`no_player = true` (mission has no player; skip the player-ready wait), `tags = [...]`
(select/skip via `--tag`; `exclusive` forces full isolation), and a per-test timeout
(used to balance shards). CTest integration: `cmake/TridentCTest.cmake` →
`register_trident_integration_ctests()` (upstream's Trident CI runs a `--shard` matrix).

## Stress scenarios (the long-run / perf-relevant path)

A **`.stress`** directory holds a `StressConfig` (`engine/Trident/src/scenarios/stress.rs`):

- `mission` — the mission to load;
- `phases` — a list of phases, each with its own `duration_ms` (so a run can be arbitrarily
  long and staged);
- `probes` — periodic queries at `interval_ms` (default queries: `ngs`, `players`,
  `von_state`);
- optional **toxiproxy** fault injection (`toxicity`, a fault-proxy backend) to chaos-test
  the network layer under load.

This is the right tool when you want a **controlled, long, reproducible mission run** — unlike
`--benchmark` (hardcoded 1000 frames, ~10–17 s) or headless `--simulate --duration N` (no
control channel). For CPU profiling (`pmcstat`) of a heavy scene, a stress scenario driving
the battle for 60 s+ with probes gives a steadier, scriptable window.

## The harness protocol (what the control channel can do)

From `harness.schema.json` — the game answers commands including: `eval` (run SQF and return
a value), `exec` (fire-and-forget SQF), `mission` / `mission_state` (load / query),
`players` + `player_joined` / `player_left` events, input injection (`click`, `key`,
`key_up`), UI inspection (`display` / `idd` / `idc`), `events` (subscribe), `log`, `hold`,
`frames`, `von_state` (voice), `describe` (list commands), `ping`. So a test can boot a
mission, script the world in SQF, drive the UI/inputs, watch for events, and assert on state.

## Config & running

- Config file **`.trident.env`** (copy `./.trident.env.example`): `OFPR_GAME_DIR` (built
  game dir, e.g. `dist/x64-win-rwdi`), `OFPR_DATA_DIR` (data, e.g. `packages/Demo`). CLI
  flags and explicit env vars override it.
- Default scenario duration is 10 s (`src/config.rs`) unless a scenario/phase sets its own.
- Typical run: `tri test tests/…/foo.test.sqf --render dummy --game-dir <build> --data-dir <data>`.

## Availability on this setup (FreeBSD)

- Trident is **Rust** (`engine/Trident/Cargo.toml`, root `Cargo.toml`/`Cargo.lock`); build
  with `cargo build --release` → `target/release/tri`.
- It is **not built by the FreeBSD port** (the port disables tests, and `cargo` isn't
  installed here), so `tri` isn't available out of the box — you'd `pkg install rust` and
  `cargo build` it, pointing `--game-dir` at the port's installed game.
- Upstream CI builds and runs it on Linux (the integration + `--shard` matrix), which is the
  environment it targets.

## Relevance to our work

- **Perf:** the `stress` scenario is the clean way to run `load.Demo` (or any heavy mission)
  for a long, controlled window under `pmcstat` — better than the `--benchmark` / `--simulate`
  approach we used for the CPU A/B (which was fine for FPS but short for sampling).
- **Determinism / MP:** the `--harness` channel + multi-instance tests are the proper way to
  exercise the server-authoritative MP path (see `MP-DETERMINISM-ARCHITECTURE.md`) rather
  than the single-machine `--determinism-log` gate.
