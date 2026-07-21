# CWR-CE working notes

Living reference for the CWR-CE (Arma: Cold War Assault - Remastered Community
Edition) port + upstream contributions. Not a spec — updated as we learn.

## START HERE (fresh session onboarding)

Read in this order, then open the one scope doc for the thread you're resuming:

1. **`DEBUGGING.md`** — build/run loop + the **exact benchmark command line**
   (`--no-splash --benchmark --test-mission ~/.config/CWR/Users/Test/Missions/Benchmark.Abel`),
   what `draw=` means, poudriere loop. Read this FIRST — it's the recurring
   time-sink if skipped.
2. This README (orientation: checkouts, branches, build override).
3. The **`PERF-*.md`** scope doc for the active work (see *Performance work* below).

**Build config is currently in dev state:** the port
(`~/freebsd-ports/games/CWR-CE/Makefile`) points at `GH_ACCOUNT=ocochard`,
`GH_TAGNAME=gpu-skinning` (fork branch), not the stock upstream tag — revert
to stock when the feature work lands. This host is **ser6** (present/vsync-bound;
FPS-neutral); FPS wins are validated on **t420** (CPU-bound) when it's online.

## Performance work (scope + findings docs)

- `PERF-multithread-scope.md` — **most recent thread.** MT main-loop (task-pool
  parallel-for), the `--mt-lod` pattern, CPU-load distribution, and the
  **determinism gate + rare-Heisenbug hunt** (categorization closed as
  document-and-move-on).
- `PERF-gpu-skinning-scope.md` — GPU vertex-shader skinning (implemented, off by
  default via `--gpu-skinning`; item 5e vehicle/prop skinning still open).
- `PERF-gpu-frametime-scope.md` — `--gpu-timing` GL_TIMESTAMP breakdown; ser6 =
  present-bound.
- `PERF-hotspot-profile.md` — pmcstat hotspots; terrain draw-call batching
  investigated and **KILLED** (don't re-derive).
- `PERF-low-fps-cpu-bound.md` — the CPU-bound-on-old-hardware framing.
- `prof_bench.sh` — 5-run ministat FPS harness.

## Companion docs in this directory

- `DEBUGGING.md` — hangs, crashes, logging, CLI flags, `--mod`
  isolation trick.
- `TROUBLESHOOTING-truncated-mod.md` — recognizing the truncated-mod
  crash pattern (`ShapeLOD.cpp:1525 _nLods >= 1`).
- `BUG-*.md` — per-bug engineering logs (root cause, repro, upstream
  status). Currently: `ai-radio-msgcmd-getfrom`,
  `content-reflecting-singletons`, `filecache-case-normalization`.
- `PR-*.md` — PR drafts for open branches on the fork.
- `cwr-logstat` — log post-processor (used in DEBUGGING.md worked
  examples).

## What is CWR-CE

- Community Edition rewrite of the **Poseidon engine** that powered *Arma:
  Cold War Assault* (BIS, 2001 — originally *Operation Flashpoint: Cold War
  Crisis*).
- Upstream: <https://github.com/ofpisnotdead-com/CWR-CE>
- Engine ships as several apps: `PoseidonGame`, `PoseidonServer`,
  `PoseidonGameDemo`, `PoseidonStudio`, `PoseidonTools`, `PoseidonTetris`.
- **Data is not redistributable.** Engine binaries alone run only the
  bundled `PoseidonTetris`. The full game needs assets from the free Steam
  demo (limited) or the retail GOG release (full campaigns).
- MSVC-first codebase; Linux CI builds via **vcpkg**; the "official" CMake
  path assumes vcpkg. FreeBSD builds against system ports + a
  `-DVCPKG_MANIFEST_MODE=OFF -DCMAKE_DISABLE_FIND_PACKAGE_VCPKG=ON` override.

## Local checkouts and branches

- Engine tree: `/home/olivier/CWR-CE/` (fork = `ocochard/CWR-CE`, upstream =
  `ofpisnotdead-com/CWR-CE`).
- Two feature branches maintained on `ocochard/CWR-CE`:
  - `freebsd` — POSIX portability. One squashed commit
    (`b6c9690` at time of writing). Basis for **PR #51** to upstream.
  - `GOG-pr` — GOG retail-data compatibility. Stacked on `freebsd`.
    One squashed commit (`85dd554` at time of writing).
- Port: `~/freebsd-official/ports/games/CWR-CE/`. Fetches upstream
  `ofpisnotdead-com` tarball at a pinned commit + two GitHub `compare/`
  patches (one per branch), so the port carries no local `patch-*` files.

Rebuild command:
```
sudo rm -f /usr/local/poudriere/data/packages/builder-official/.latest/All/CWR-CE-3.01.pkg
sudo poudriere bulk -j builder -p official games/CWR-CE
```
Test target for briefing/mission bug lives on `ser6fbsd`; ship the
`.pkg` via `scp` + `sudo pkg add -f`.

## Engine invariants worth knowing

### `platformPath()` and path separators
- `engine/Poseidon/Foundation/platform.hpp` (~line 195) defines
  `inline void platformPath(char* path)`:
  - `_WIN32`: rewrites `/` → `\`
  - POSIX: rewrites `\` → `/`
- Applied where the engine stores paths — notably `QFBank::SetPrefix()` in
  `engine/Poseidon/IO/Streams/QBStream.cpp` (~line 776) normalizes the
  stored prefix. So on POSIX, `QFBank::GetPrefix()` returns forward slashes
  even for prefixes constructed from string literals containing `\`.
- **Not applied uniformly by consumers.** `apps/tools/Studio/...` and
  `OptionsUIApp.cpp:~720` still parse returned prefixes with
  `strrchr(buf, '\\')`. Fixing a normalization mismatch by
  over-normalizing the returned string breaks these downstream parsers.
- The right pattern when comparing strings against a stored prefix on POSIX:
  copy the literal into a scratch buffer, call `platformPath(scratch)` on
  it, and use `strnicmp(bank.GetPrefix(), scratch, len)` — but return the
  original backslash form to callers.
- This mismatch was the root cause of the single-mission briefing bug:
  the unmount loop in `CreateSingleMissionBank` (`UI/OptionsUI.cpp`)
  compared `bank.GetPrefix()` against the literal `"missions\\__cur_sp."`
  → never matched on POSIX → old banks accumulated →
  `QIFStreamB::AutoOpen` returned the first-mounted `overview.html`
  regardless of which mission the user clicked.

### Where the mission editor saves missions
- The in-game editor (the "Arcade" map editor, `DisplayArcadeMap`) writes each
  saved mission as `mission.sqm` inside a per-mission folder
  `<Name>.<World>/`:
  - SP:  `<UserContentDir>/missions/<Name>.<World>/mission.sqm`
  - MP:  `<UserContentDir>/MPMissions/<Name>.<World>/mission.sqm`
  - `<Name>` = text typed in the Save dialog; `<World>` = island
    (`Glob.header.worldname`, e.g. `abel`, `noe`, `eden`, `demo`).
- `<UserContentDir>` = `GamePaths::Instance().UserContentDir()` — the
  discoverable content root, **not** the player profile: on Linux it is the
  XDG data dir under the product name, e.g.
  `~/.local/share/Cold War Assault/`; on Windows `Documents/<product>`.
  Legacy `-oldpaths` mode falls back to the per-profile `Users\<profile>\`
  dir.
- Verified on this host (2026-07-18): the one editor-saved SP mission is
  `~/.local/share/Cold War Assault/missions/load.demo/mission.sqm`
  (Name `load`, world `demo`). `MPMissions/` was empty. Note this is the
  live save path — the per-profile `~/.config/CWR/Users/<profile>/Saved/
  missions/*` folders are empty save-slot placeholders, **not** editor
  output; don't mistake them for saved missions.
- Save handler: `engine/Poseidon/UI/Map/UIMapExtDisplay.cpp:2189`
  (`DisplayArcadeMap::OnChildDestroyed`, `case IDD_TEMPLATE_SAVE`) → writes
  at `:2216` via `SaveTemplates()`. SP vs MP is picked at `:2197` from the
  `_multiplayer` member, choosing `GetMissionsDir()` = `"missions/"` vs
  `GetMPMissionsDir()` = `"MPMissions/"` (`UI/OptionsUI.cpp:790-817`); the
  dir is assembled by `GetMissionsDirectory()` (`OptionsUI.cpp:189`).
- The loose `mission.sqm` folder is the authoritative editable copy. The
  Save dialog's mode combo can additionally *pack* it into a `.pbo`
  (`Missions\<name>.<world>.pbo`, `MPMissions\<name>.<world>.pbo`, or an
  email export) — those are exports of the same folder.
- **POSIX note:** the editor's loose-folder path uses lowercase `missions/`
  deliberately (case-sensitive FS), but the packed-`.pbo` paths use
  `Missions\` / `MPMissions\` with backslashes — the same separator/case
  mismatch the `platformPath()` section above warns about.

### Logging
- `LOG_ERROR(Core, "fmt {}", arg)` — spdlog + fmt-style formatting.
  Used during trace-instrumented builds to hunt the briefing bug.

### Mutex portability
- `PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP` is **glibc-only** (also Bionic).
  FreeBSD/musl/etc. have no equivalent macro, and copying a
  `pthread_mutex_t` value is unsafe (may hold internal pointers).
  `PoCritical.cpp` uses an in-place `pthread_mutexattr_settype(...,
  PTHREAD_MUTEX_RECURSIVE)` fallback where the macro is absent.

### CLI11 version split
- `CLI::IsMember` / `CLI::IsNegation` moved from `<CLI/Validators.hpp>` to
  `<CLI/ExtraValidators.hpp>` in CLI11 **2.6**. Umbrella `<CLI/CLI.hpp>`
  still works with both. `AppConfig.cpp` uses targeted includes, so
  `<CLI/ExtraValidators.hpp>` is guarded with `#if __has_include(...)`.
  FreeBSD ports ship CLI11 2.6.2; vcpkg-bundled version is older.

### mimalloc v3 API shifts
- v3 removed `mi_option_eager_commit` / `eager_commit_delay`; global
  `mi_heap_get_default` / `mi_heap_check_owned` gained/changed. Guard v1/v2
  vs v3 with `MI_MALLOC_VERSION`. FreeBSD's `devel/mimalloc` is v3.
- FreeBSD's `libmimalloc.so` is built with `MI_OVERRIDE=ON`, so it
  **already provides global `operator new`/`delete`**. `Core/GlobalOperators.cpp`
  must be excluded from the FreeBSD build to avoid duplicate symbols.

### FreeBSD `<sys/types.h>` name clashes
- Defines `major()` and `minor()` as macros. Any local variable named
  `major` or `minor` in a file that transitively includes `<sys/types.h>`
  fails to compile. `World/Viewer.cpp` had this — renamed to
  `majorLine`/`minorLine`.

### `backtrace(3)` linkage
- FreeBSD `libc` does **not** contain `backtrace()` (unlike glibc). Link
  `libexecinfo` explicitly when `CMAKE_SYSTEM_NAME STREQUAL "FreeBSD"`.

## GOG retail-data bugs (branch `GOG-pr`)

Three real engine bugs that surface only with the retail data set. I
verified none of them is a data-merge workaround.

1. **Empty crew name in `CreateSoldier` / `CreateUnit`** —
   `engine/Poseidon/AI/AICenterImpl.cpp`. Retail vehicles can declare an
   empty crew name; `NewVehicle("")` returns null; caller crashed on
   deref. Fix: early return + guard the three crew slots.
2. **Uninitialized `_selection[]` in `AnimationSection::DoConstruct`** —
   `engine/Poseidon/World/Simulation/Animation/Animation.cpp`. The
   sibling class `Animation::DoConstruct` zero-inits `_selection`;
   `AnimationSection` had the same field with no init loop. Retail
   helicopters with fewer LODs than the animation iterates over triggered
   reads of garbage slots that missed the `< 0` guard. Fix: init all
   entries to `-1`.
3. **`scope=0` vehicles dispatched to generic type** —
   `engine/Poseidon/World/Entities/Vehicles/VehicleTypes.cpp`. In
   ARMA:CWA `CfgVehicles`, `scope=0` means "hidden from editor", **not**
   "no simulation". Retail missions reference `scope=0` helicopter/tank/
   car classes. Fix: move the simulation dispatch out of the `scope > 0`
   guard so known `_simName` strings always get the specific `TypeInfo`.

## Why the Steam demo is a required base (verified)

Confirmed on 2026-07-18 by staging a retail-GOG-only data root on `t420`
and booting it. Retail alone gets much further than expected: the engine
parses `BIN/CONFIG.BIN`, preloads every vehicle class, loads textures,
and logs `World initialized successfully` for the intro menu world. GOG
is the complete 2001 game and misses nothing *original* — its fonts even
ship in `DTA/Fonts.pbo`.

It still cannot run the CE engine, blocked by two hard dependencies on
the demo's remaster layer (fail in order):

1. **Fonts.** `FontSystem::Initialize` aborts with `required font
   missing: fonts\cwr_{title,body,mono,serif,hand}.ttf`. Those five
   loose remaster TrueType fonts ship only with the Remaster Demo; the
   CE UI does not use retail's `DTA/Fonts.pbo` bitmap fonts.
2. **Sky.** With stand-in `.ttf` files satisfying FontSystem, the boot
   advances to the first rendered frame and segfaults in
   `Poseidon::Landscape::DrawSky` (null deref at +0x70). Retail
   `CONFIG.BIN` has no `CfgLandscapeSky` / remaster sky models, so the
   sky object is null. This is exactly the remaster-only config the
   install helper's merge preserves by keeping the demo `CONFIG.BIN` as
   base instead of overwriting it with retail's.

So the demo is mandatory as the base layer (remaster fonts +
`CfgLandscapeSky` + sky models); retail is the overlay that adds the full
islands, vehicles, voices, and campaigns. Supplying just the five
`cwr_*.ttf` and a retail-compatible sky config would in principle boot
retail-only, but both only come from the demo.

## Port packaging quirks

- `USES=dos2unix` + `DOS2UNIX_REGEX=.*\.(c|h|cpp|hpp)` — upstream
  `.gitattributes` forces CRLF on C/C++ sources (MSVC-first). BSD
  `patch(1)` fails on CRLF context, so we normalize before patches apply.
- `USES+=localbase` — the port `#include`s headers from
  `${LOCALBASE}/include` (e.g. `<vulkan/vulkan.h>`); CMake's SYSTEM-dedup
  can silently drop the include path for one language but not the other,
  so make it explicit.
- `CMAKE_ARGS=-DVCPKG_MANIFEST_MODE=OFF -DCMAKE_DISABLE_FIND_PACKAGE_VCPKG=ON`
  — otherwise CMake tries to bootstrap vcpkg in the poudriere jail (no
  network) and fails.
- `CMAKE_OFF=POSEIDON_DISABLE_PCH POSEIDON_BUILD_FUZZERS` — PCH breaks the
  cross-platform include-graph experiments; fuzzers are dev-only.
- Two apps not packaged: `TcLister`/`TcPbo` build only as Windows Total
  Commander plugins (`.wlx64` / `.wcx64`).
- `bin/cwr-ce` — launcher shipped by the port. Detects data root via
  `$CWR_DATA` (default `~/.local/share/CWR/base`), verifies
  `bin/config.bin` or `bin/CONFIG.BIN` exists, then execs `PoseidonGame
  -C <data-root> "$@"`. Prints install instructions and exits 1 if
  data missing.
- `bin/install-cwr-data` — helper that builds the data root from the
  free Steam Remaster Demo zip (positional arg, the base), and optionally
  overlays retail GOG content passed via `--gog` (unpacked with
  `innoextract`, config class-merged into the demo `CONFIG.BIN`). GOG
  alone is not a supported install: the demo supplies `fonts/` and the
  base `bin/CONFIG.BIN` the overlay merges into. Layout lands under
  `~/.local/share/CWR/base`.

## Upstream / PR state

- **PR #51** (`ocochard/freebsd` → upstream `main`) — POSIX portability.
  CI gated at `action_required` (first-time-contributor policy); needs a
  maintainer to release the hold before Linux/Windows/SteamRT4/Lint
  workflows run.
- **GOG-pr** — not yet submitted as a PR. Depends on freebsd landing
  first (branches are stacked).
- Once PR 51 merges, the port `PATCH_SITES` compare-patch URLs need to
  update: the freebsd patch collapses to nothing (already in upstream)
  and only the GOG patch remains as an out-of-tree carry.

### Engine-fix branches (off `main`, drafts in `PR-*.md`)

Independent single-commit branches — each fixes one real engine bug
discovered while running the port. Drafts ready to submit upstream once
PR #51 unblocks the CI gate.

- `ai-radio-getfrom-fix` — `AIRadio` `GetFrom()` NPE.
- `soldier-killedby-brain-assert-fix` — assertion mismatch on kill
  attribution.
- `vehicle-supply-assert-fix` — vehicle-supply invariant.
- `landscape-crater-null-shape-fix` — guard null preloaded `CraterShell`
  (`ScenePreloader --no-strict` contract).
- `scene-preloader-remount-fix` — reset `ScenePreloader::_initialized`
  on `UnloadGameData` so mod re-mount repopulates `_preloaded[]` (root
  cause of the null-shape symptom above).
- `autoopen-loose-mod-file-fallback` — `QIFStreamB::AutoOpen` retries
  loose-file open against mounted mod dirs (POSIX vehicle-audio bug).

## Upstream code style (`.clang-format`)

Learned the hard way on PR #51: CI enforces clang-format strictly. Key
rules from the repo's `.clang-format`:

- `ColumnLimit: 120`
- `BreakBeforeBraces: Allman` — braces on their own line, always.
- `AllowShortFunctionsOnASingleLine: Inline` — only true class-inline
  methods can be one-liners. **Free functions (even 1-line ones) must
  span multiple lines.** This is what broke `initRecursiveMutex` when
  it was `static inline void initRecursiveMutex(pthread_mutex_t& m) { m
  = mutexInit; }` — had to expand to full brace-per-line form.
- `AllowShortBlocksOnASingleLine: Empty` — only `{}` may be inline.
- `AllowShortIfStatementsOnASingleLine: Never` — `if (x) return;` on one
  line is rejected.
- `AllowShortLoopsOnASingleLine: false`
- `AllowShortCaseLabelsOnASingleLine: false`

Before amending a freebsd-branch commit, sanity-check any touched .cpp
with `clang-format --dry-run --Werror <file>` (or trust that a
break-brace + newline pattern will pass). The CI lint job runs
`clang-format 21.1.8`.

Portability gates you write (`#ifdef __linux__`, `#if defined(...)`)
follow the same rules — an `#else` branch with a one-liner function will
still trigger the lint failure.

## Ongoing hazards

- Force-pushing `ocochard/freebsd` re-runs PR 51 CI from scratch each
  time — but also invalidates the compare-patch URLs the port uses,
  because the SHA in the URL changes. When you amend, update the port
  `PATCHFILES` + `distinfo` + delete the stale distfile in the same pass.
- Don't ship the port with a GOG-pr compare-patch commit that doesn't
  cleanly apply on top of the freebsd compare-patch — poudriere fails
  loudly, but only after fetching both.
