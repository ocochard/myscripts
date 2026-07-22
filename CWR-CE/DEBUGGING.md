# CWR-CE engine debugging guide

Working reference for diagnosing engine issues (hangs, crashes, silent
failures). All file:line refs are against `/home/olivier/CWR-CE/`. Update
when the tree drifts.

## First move: enable full logging + no audio

The single most useful command when the game hangs, crashes, or misbehaves:

```
PoseidonGame -C ~/.local/share/CWR/base \
    --log-level trace \
    --log-categories Core,Config,Audio,Graphics,Network,Mission \
    --log-file /tmp/cwr.log \
    --log-format text \
    --no-sound \
    --timeout 60
```

- `--log-level trace` — most verbose (default is `info`, `AppConfig.cpp:655-657`,
  `Logging.cpp:511`).
- `--log-categories` — restrict noise; full list below.
- `--log-file` — absolute path resolved *before* the `-C` chdir
  (`AppConfig.cpp:779`). Single file, appended, **no rotation**.
  If you crash and immediately relaunch, the log from the crashed run
  gets overwritten before you read it. Use a per-launch filename:
  `--log-file /tmp/cwr-$(date +%s).log`. Confirm PID/timestamp match the
  `core.*` file before analyzing — a mismatched log will send you down
  the wrong root-cause path.
- `--log-format text|jsonl` — jsonl if you want to grep/jq
  (`AppConfig.cpp:668-672`).
- `--no-sound` — bypass OpenAL device enumeration (see hang §1 below).
- `--timeout 60` — auto-exit after 60s (`AppConfig.cpp:590-593`). Useful when
  the game hangs headlessly and you don't want to `kill -9` every time.

The `cwr-ce` launcher forwards all extra args to `PoseidonGame`, so:

```
cwr-ce --log-level trace --log-file /tmp/cwr.log --no-sound --timeout 60
```

## Logging system

Defined in `engine/Poseidon/Foundation/Framework/Log.hpp` and implemented
in `engine/Poseidon/Foundation/Logging/Logging.cpp`.

- Backend: **spdlog** with per-category named loggers (`Logging.cpp:570-582`).
- Levels: `LOG_TRACE`, `LOG_DEBUG`, `LOG_INFO`, `LOG_WARN`, `LOG_ERROR`,
  `LOG_CRITICAL` (`Log.hpp:52-61`).
- Categories (enum `LogCategory` at `Log.hpp:13-29`):
  `Core, Config, Memory, Graphics, Audio, Input, Network, World, Script,
  AI, Physics, UI, Mission`.
- Sink: `spdlog::basic_file_sink_mt`, append mode, no rotation
  (`Logging.cpp:557`).
- Call form: `LOG_ERROR(Core, "fmt {}", arg)` — fmt-style formatting.

Related CLI flags:
- `--log-level trace|debug|info|warn|error|critical|off`
- `--log-categories <csv>`
- `--log-format text|jsonl`
- `--log-file <path>`
- `--strict` — treat any ERROR-level log as fatal, exit 1 (`AppConfig.cpp:520-524`).
- `--logfiles` — enable file-operation logging (`AppConfig.cpp:569-570`).
- `--netlog` — enable network logging (`AppConfig.cpp:572-573`; implementation not obvious).

`POSEIDON_TEST=1` suppresses console output; `POSEIDON_TEST_LOG=1` re-enables it under test mode (`Logging.cpp:508`).

## Debugging a hang

### Worked example: how a real hang was identified (2026-07-02)

This walks through the exact commands that identified an X11 Present
event hang on ser6fbsd. Follow the same pattern for other hangs.

**Step 1 — Confirm it's actually hung, not just slow.** Check process
state and accumulated CPU:
```
$ ps -auxww | grep PoseidonGame | grep -v grep
olivier  3413  0.1  1.2 1960928 749488  1  I+  10:16 25:50.70 PoseidonGame ...
```

`I+` = sleeping in kernel. `25:50` CPU across a ~6-hour wall-clock uptime
= 4% average. Not truly frozen — something ran for a while then stopped.
That rules out "hung at startup" (culprit #1 OpenAL) and points to
"ran, then wedged".

**Step 2 — Find *which* thread accumulated the CPU.** `ps -H` breaks
per-thread. Poseidon threads have distinctive names (`:cs0`, `:sh0`,
`:gdrv0`, etc.):
```
$ ps -H -o lwp,pcpu,time,comm -p 3413
   LWP %CPU     TIME COMMAND
100673  0.0 23:22.07 PoseidonGame/PoseidonGame       ← main, ate 23 min
101048  0.0  0:14.84 PoseidonGame/PoseidonGa:cs0
101059  0.0  0:55.40 PoseidonGame/Poseidon:gdrv0
101072  0.2  0:55.96 PoseidonGame/alsoft-mixer       ← still running
... rest all ~0
```

Main thread burned 23 min of CPU then stopped. `alsoft-mixer` is still
alive (0.2% now) — that explains why sound continued while the game
appeared frozen. **Focus on thread #1 (LWP 100673).**

**Step 3 — Dump the main thread's stack, deep enough to see the caller
chain.** Common trap: `lldb -p N -o "thread backtrace all"` in one-shot
mode only prints **frame #0** per thread. You get every thread's
syscall (`__sys_poll`, `__sys__umtx_op`) but no callers — misleading,
looks like everything's blocked on a mutex when they're just parked
normally. The fix is to select the thread and use `bt N` explicitly:

```
$ sudo lldb -p 3413 -o "thread select 1" -o "bt 40" -o quit
```

Actual output that identified the hang:
```
* thread #1, name = 'PoseidonGame', stop reason = signal SIGSTOP
  * frame #0:  libsys.so.7`__sys_poll
    frame #1:  libthr.so.3`__thr_poll(fds=..., timeout=-1)
    frame #2:  libxcb.so.1`___lldb_unnamed_symbol_17130 + 258
    frame #3:  libxcb.so.1`xcb_wait_for_special_event + 137
    frame #4:  libgallium-26.0.6.so`___lldb_unnamed_symbol_11218a0
    frame #5:  libgallium-26.0.6.so`loader_dri3_swap_buffers_msc
    frame #6:  libGLX_mesa.so.0`___lldb_unnamed_symbol_3e270
    frame #7:  libGLX_mesa.so.0`___lldb_unnamed_symbol_2f170
    frame #8:  libSDL3.so.0`___lldb_unnamed_symbol_2532f0
    frame #9:  PoseidonGame`EngineGL33::BackToFront at EngineGL33_VertexBuffer.cpp:587
    frame #10: PoseidonGame`EngineGL33::NextFrame     at EngineGL33_Lifecycle.cpp:222
    frame #11: PoseidonGame`Poseidon::World::Simulate at World.cpp:1704
    frame #12: PoseidonGame`Poseidon::RenderFrame     at GameLoop.cpp:75
    frame #13: PoseidonGame`Poseidon::AppIdle         at GameLoop.cpp:274
    frame #14: PoseidonGame`GameApplication::RunMainLoop at GameApplication.cpp:1230
    frame #15: PoseidonGame`GameApplication::RunAfterArgumentParsing at GameApplication.cpp:858
    frame #16: PoseidonGame`GameApplication::Run      at GameApplication.cpp:612
    frame #17: PoseidonGame`main                      at WinMain.cpp:28
```

**Step 4 — Read top-down. Frame names tell the story.** Symbol
resolution on FreeBSD:
- `libc`/`libthr`/`libxcb` keep public ELF symbols → full names visible
  (`xcb_wait_for_special_event`, `loader_dri3_swap_buffers_msc`)
- Mesa internals are stripped → `___lldb_unnamed_symbol_*` (no help)
- Poseidon frames resolve fully (file:line included) because the port
  builds `RelWithDebInfo` — debug info is retained even in the release
  package

Reading the visible-name frames: `EngineGL33::BackToFront` → SDL →
`libGLX_mesa` → `loader_dri3_swap_buffers_msc` →
`xcb_wait_for_special_event` → `poll(-1)`. That is the signature of
SwapBuffers waiting for an X11 Present-extension completion event that
never arrives. **Not** a Poseidon bug; the engine is doing what the
graphics stack told it to do.

**Step 5 — Confirm your read against every thread.** If the busy-thread
heuristic misled you, dump all threads at full depth from the
interactive prompt (`-o` doesn't work for `bt all` — must be
interactive):
```
$ sudo lldb -p $(pgrep -x PoseidonGame)
(lldb) bt all
```
In this hang every worker thread was sleeping in `_umtx_op` — normal
"waiting for work" state — which corroborated that the main thread was
the single stuck one.

### Reusable commands

```
# 1. Confirm hang + measure CPU
ps -auxww | grep PoseidonGame | grep -v grep

# 2. Find the busy thread
ps -H -o lwp,pcpu,time,comm -p $(pgrep -x PoseidonGame)

# 3. Stack of the busy thread (usually #1)
sudo lldb -p $(pgrep -x PoseidonGame) -o "thread select 1" -o "bt 40" -o quit

# 4. All threads at full depth (interactive)
sudo lldb -p $(pgrep -x PoseidonGame)
(lldb) bt all
(lldb) frame variable    # inspect locals in current frame
(lldb) thread select 5   # jump to another thread
```

gdb equivalent, in case lldb misbehaves:
```
sudo gdb -p $(pgrep -x PoseidonGame)
(gdb) thread apply all bt
(gdb) thread 1
(gdb) bt full            # backtrace + locals
```

**Read every thread's backtrace, not just thread 1** if the busy-thread
heuristic isn't decisive. Poseidon uses a worker pool (§3 below); on
some hangs the main thread is idle in an event pump while a worker is
deadlocked.

### Top 4 hang culprits

**1. OpenAL device enumeration (most common on headless / SSH sessions).**

`engine/PoseidonOpenAL/SoundSystemOAL.cpp` calls `alcOpenDevice(nullptr)`
with **no timeout wrapper**. On FreeBSD systems where OSS/ALSA/Pulse is
misconfigured, this blocks indefinitely before the main loop starts.

Test:
```
cwr-ce --no-sound          # or
cwr-ce --audio dummy
```

If the game reaches the menu with `--no-sound` but hangs without, it's
OpenAL. Look at `/dev/dsp*` permissions, `sndio` config, or
`AUDIODEV`/`OSS_AUDIODEV` env vars.

**2. Vulkan / SDL graphics init.**

The port depends on `libvulkan.so`, `libSDL3.so`, and glslang.
`SDL_Init(SDL_INIT_VIDEO)` is called in `EngineGL33.cpp:270` (the OpenGL
3.3 backend). Where the code calls into Vulkan (validation layers, device
selection) is not fully mapped yet — watch for `vkCreateInstance`,
`vkEnumeratePhysicalDevices` in backtraces.

Test running under `MESA_LOADER_DRIVER_OVERRIDE=llvmpipe` or
`LIBGL_ALWAYS_SOFTWARE=1` if you suspect the GPU driver.

**2b. SwapBuffers wait on X11 Present-completion (observed 2026-07-02).**

Symptoms: sound continues (alsoft-mixer thread unaffected), no input, no
frame progress, main thread accumulates minutes of CPU then stops.
Backtrace of thread #1 lands in the DRI3 swap chain:

```
EngineGL33::BackToFront            EngineGL33_VertexBuffer.cpp:587
  → SDL3 SDL_GL_SwapWindow
  → libGLX_mesa
  → loader_dri3_swap_buffers_msc   (libgallium)
  → xcb_wait_for_special_event     (libxcb)
  → __sys_poll(xfd, timeout=-1)    (BLOCKED)
```

`xcb_wait_for_special_event` waits for the X server's Present-extension
`PresentCompleteNotify` event. When that event is dropped (compositor
interception, KMS-DRM driver missing vblank delivery, misconfigured
modesetting driver) the swap chain waits forever with `timeout=-1`.
Because the main thread is inside SwapBuffers it cannot pump input or
advance simulation — the game *looks* frozen while sound keeps playing.

Triage steps, cheapest first:

1. **Disable vsync/present-sync** — confirms the Present path is the
   culprit:
   ```
   env vblank_mode=0 __GL_SYNC_TO_VBLANK=0 \
       cwr-ce --log-level trace --log-file /tmp/cwr.log --log-format text
   ```
   `vblank_mode=0` is honored by Mesa; `__GL_SYNC_TO_VBLANK=0` covers
   NVIDIA-proprietary if ever relevant.

2. **Kill any compositor** before launching — picom/xcompmgr can consume
   Present events meant for full-screen clients:
   ```
   pkill picom xcompmgr; cwr-ce ...
   ```

3. **Force software rasterizer** — bypasses DRI3 entirely, useful to
   isolate GPU driver from engine:
   ```
   env LIBGL_ALWAYS_SOFTWARE=1 cwr-ce ...
   ```

If (1) or (2) fixes the hang, the root cause is Mesa/Xorg/compositor
interaction — not a CWR-CE bug. File upstream against Mesa or the X
driver in that case. If (3) is needed to unblock, the specific KMS-DRM
driver on this host is not delivering vblank/present events correctly.

**How to identify this signature from a live process:**

Step 1 — find the busy thread. `pgrep` gives you the process, `ps -H`
lists LWPs with per-thread CPU time:
```
ps -H -o lwp,pcpu,time,comm -p $(pgrep -x PoseidonGame)
```
Look for one thread with several minutes of CPU while the rest are near
zero. That's the main thread on this hang (it burned CPU rendering
frames until Present broke, then wedged in poll).

Step 2 — dump the full stack of that thread with lldb. **Do not** use
`-o "thread backtrace all"` — in one-shot mode it emits only frame #0
per thread, which shows the syscall but not the caller and is
misleading (looks like every thread is stuck in a mutex when they're
just parked normally). Select the thread and use `bt N` explicitly:
```
sudo lldb -p $(pgrep -x PoseidonGame) \
    -o "thread select 1" -o "bt 40" -o quit
```

Step 3 — read the stack top-down. FreeBSD `libc`/`libthr`/`libxcb` keep
public symbols so their frame names resolve; Mesa/gallium internals
appear as `___lldb_unnamed_symbol_*` (stripped). Poseidon frames
resolve fully because the port builds `RelWithDebInfo`. The signature
here is a Poseidon `Render*`/`Swap*` frame flowing into
`SDL_GL_SwapWindow` → `libGLX_mesa` → `libgallium` →
`xcb_wait_for_special_event` → `__sys_poll(timeout=-1)`.

Step 4 (optional) — get every thread's full stack, not just #1. From
lldb's interactive prompt (no `-o`), `bt all` walks all threads with
full depth:
```
sudo lldb -p $(pgrep -x PoseidonGame)
(lldb) bt all
```
Use this when the busy-thread heuristic doesn't identify one clear
culprit.

**3. TaskPool worker deadlock.**

`engine/Poseidon/Core/TaskPool.cpp` wraps `enkiTS` with a worker pool
(`InitGlobalTaskPool` at `TaskPool.cpp:189-196`). Default thread count is
capped at 8; override with `--max-threads N` (`AppConfig.cpp:548-551`).
Try `--max-threads 1` to serialize — a hang that vanishes single-threaded
is almost certainly a race or task-graph cycle.

**4. Asset / mission loading loop.**

Look for `Mission` / `World` / `Core` log spam that stops without progressing to the game loop. `--log-categories Mission,World,Core --log-level trace` will show which asset the loader is chewing on.

### No POSIX watchdog

`DebugThreadWatch` in `engine/Poseidon/Dev/Debug/DebugTrap.cpp:23-136`
monitors the main-thread heartbeat — but it's **Windows-only**. The POSIX
side is a stub (`DebugTrap.cpp:233-258`). If you want detection of a stuck
main thread on FreeBSD, you have to attach a debugger or add one.

## Debugging a crash

`engine/Poseidon/Foundation/Platform/CrashHandler.cpp:107-342` installs
POSIX signal handlers for `SIGSEGV, SIGABRT, SIGFPE, SIGILL, SIGBUS`
(`CrashHandler.cpp:124`) via `sigaction` with `SA_SIGINFO | SA_ONSTACK |
SA_RESETHAND` (`CrashHandler.cpp:336`). An alternate stack is allocated
(`CrashHandler.cpp:327-331`) so stack-overflow crashes are still catchable.

On crash the handler:
- Prints a backtrace via `backtrace()` / `backtrace_symbols_fd()`
  (requires `libexecinfo` on FreeBSD — the port links it).
- Writes `crash_<pid>.txt` in the working directory (or the `crashDir`
  specified at `CrashHandler.cpp:308`).
- Includes return addresses and, on Linux only, `/proc/self/maps` for
  offline symbolization (`CrashHandler.cpp:238-250`).
- Extracts the NT_GNU_BUILD_ID for symbol lookup (`CrashHandler.cpp:261-299`).

On FreeBSD there is no `/proc/self/maps` by default — you'll get
addresses but no map. Use `procstat -v $(pgrep PoseidonGame)` on a
running instance to snapshot the map, or symbolize with `addr2line -e
/usr/local/bin/PoseidonGame <address>`.

### Isolating Remount-only crashes with `--mod`

`GameApplication::Remount()` (`GameApplication.cpp:1743`) tears the
content layer down (`UnloadGameData(keepEngine=true)`) and rebuilds it
without recreating the graphics engine — a code path exercised only
when the user picks a mod from the in-game Mods menu. Boot-time mod
activation via the CLI (`--mod <path>`, `AppConfig.cpp:428`) skips
`Remount()` entirely: content is loaded once against a fresh process.

Diagnosis rule: if a crash reproduces via Mods menu but NOT via
`cwr-ce --mod <path>`, the bug is something `Remount()` does that
direct-boot doesn't — typically state left over in a process-lifetime
singleton (see `BUG-content-reflecting-singletons.md`).

```
cwr-ce --mod ~/.local/share/Cold\ War\ Assault/Workshop/<MODNAME> \
       --log-file /tmp/cwr-mod-$(date +%s).log
```

Semicolon-separated for multiple mods. Legacy alias: `-mod`.

## Debugging low FPS / performance

Worked example: a report of "stuck at ~20 FPS" on strong hardware (Ryzen 7
7735HS + Radeon 680M). Full narrative in `PERF-low-fps-cpu-bound.md`;
saved baselines in `perf-data/`. Follow this order.

**Step 0 — `--fps` is a red herring.** `--fps` / `--show-fps` only toggles
the on-screen overlay (`AppConfig.cpp:335`). It does not uncap anything, and
FPS is drawn on screen only (`EngineDrawing.cpp:46-71`, iFPS/aFPS), never
written to `--log-file`. Read it off the overlay.

**Step 1 — capped or bound?** Rule out the deliberate limiters first:
- Auto-detail balancer: `frameRate` in `UserInfo.cfg` sets a target FPS
  band `frameRate*(10/15) .. frameRate*(20/15)` (`Scene.cpp:593-600`,
  default 15 → 10–20 FPS at `Scene.cpp:640`). The balancer then trades LOD
  detail to hit that band (`SceneDraw.cpp:780-926`) — so a low `frameRate`
  parks you at ~20 by *adding* detail. Raise it (e.g. 60).
- User cap: `gUserFpsCap` from the Graphics screen (`GameLoop.cpp:123-135`,
  `GraphicsApply.cpp:98`, `graphics.cfg fpsCap`).
- Vsync quantization: `graphics.cfg vsync=1` at 60Hz gives only 60/30/20/15
  (÷N). Exactly-20 or exactly-30 is the tell. Test `env vblank_mode=0`.
- Unfocused/rendering-disabled cap = 50 (`GameLoop.cpp:110`); cheat-key FPS
  limiter = 40/coef (`GameLoop.cpp:80-89`).

**Step 2 — GPU-bound or CPU-bound?** Per-thread CPU while running:
```
ps -H -o lwp,pcpu,time,comm -p $(pgrep -x PoseidonGame) | sort -k2 -rn | head
```
Main thread near 100% with `:gdrv0` (GPU driver) near 0% ⇒ **single-thread
CPU-bound** (the engine does per-vertex software skinning on the main
thread — `Object::AnimateGeometry`). A fast GPU cannot help. Confirm the GPU
is even engaged (not llvmpipe) from the game's own log line
`GL33: OpenGL … — <renderer>` (`EngineGL33.cpp:445`).

**Step 3 — profile the main thread with pmcstat** (hwpmc works under the
FreeBSD linuxlator):
```
sudo pmcstat -S ls_not_halted_cyc -O /tmp/pmc.out sleep 8
pmcstat -R /tmp/pmc.out -G /tmp/pmc.graph
grep -E "^[0-9]+\.[0-9]+%" /tmp/pmc.graph | grep -viE "Acpi|cpu_idle|lock_delay|doreti" | head -30
```
Filter the ACPI/idle noise: system-wide sampling captures the *other* idle
cores running `acpi_cpu_idle → AcpiOsReadPort`; that is not the game.

**Step 4 — is the shipped package even optimized?** A global `WITH_DEBUG`
on the builder silently produces an `-O0` package: `bsd.port.mk` does
`CFLAGS:= ${CFLAGS:N-O*} ${DEBUG_FLAGS}`, filtering out every `-O`. Symptoms:
- Binary is huge and unstripped (a `WITH_DEBUG` build was ~213 MB vs ~13 MB
  for `-O2` stripped).
- Trivial accessors are fat: `Vector3P::X()` (`return _e[0];`) becomes a
  ~60-instruction function with a stack frame, a stack canary, and a
  per-read NaN-validation branch into spdlog:
  ```
  objdump -d -C /usr/local/bin/PoseidonGame | \
    awk '/<Poseidon::Foundation::Vector3P::X\(\) const>:/{f=1} f{print} f&&/ret/{exit}'
  ```
  Optimized, this is ~2 instructions (`movss (%rdi),%xmm0; ret`).
- Build log has no `-O2`: `grep -c -- -O2 <buildlog>` returns 0; the env
  dump shows `WITH_DEBUG=yes` and `CFLAGS="… -g …"` with no `-O`.

Fix: remove `WITH_DEBUG` from `/etc/make.conf` and the poudriere
`make.conf` set, rebuild, reinstall. Verify `Vector3P::X()` collapses.

**Profiling an optimized build needs symbols — use RelWithDebInfo, NOT
`WITH_DEBUG`.** Normal `-O2` release packages are stripped (the engine's own
`cmake/DistCopy.cmake:37` strips in Release), so live pmcstat can only name
library frames, not Poseidon functions.

Do **not** reach for `WITH_DEBUG` to get symbols: besides filtering `-O*` (see
Step 4), it also **drops `NDEBUG`**, which flips `PoseidonAssert` on
(`DebugLog.hpp:63`). Every `Vector3P` accessor then carries a
`PoseidonAssert(_e[i] != FLT_MAX)` branch (+ stack canary) that the real
release does not — so the accessors stop inlining and the profile *misreports*
inlining/vectorization. Verified: a `WITH_DEBUG` build logs 0/1037 compiles
with `-DNDEBUG`.

The faithful recipe is `RelWithDebInfo`: `-O2 -g -DNDEBUG` — identical
semantics to Release (asserts off, optimized) but with symbols, and because
the build type is not `"Release"`, `DistCopy` skips its strip. In
`/usr/local/etc/poudriere.d/<jail>-make.conf`:
```
CMAKE_BUILD_TYPE=RelWithDebInfo
STRIP=
```
Verify the override before building (bare `make -V` reads `/etc/make.conf`,
not the poudriere make.conf, so point it explicitly):
```
make __MAKE_CONF=/usr/local/etc/poudriere.d/<jail>-make.conf -V CMAKE_BUILD_TYPE
# => RelWithDebInfo
```
Then `poudriere bulk -C -j <jail> games/CWR-CE` (the `-C` deletes the stale
package so it actually rebuilds — without it poudriere sees the pkg as
current and skips). Extract the unstripped `PoseidonGame` from the `.pkg`,
run *that* binary, pmcstat/objdump it. Sanity-check faithfulness first:
`Vector3P::X()` must be ~2 instructions (`movss (%rdi),%xmm0; ret`) with no
canary and no assert branch — if it isn't, `NDEBUG` didn't take and you are
profiling a debug build. Remove the make.conf afterward.

**Known hotspot (optimized build): `std::nearbyint`.** On the `-O2` build
the top non-idle cost is libm float→int rounding (`nearbyintf` + `fegetenv`
~19%). `Foundation/Common/FltOpts.hpp` routes every `toInt` / `toLargeInt` /
`toIntFloor/Ceil` / `fastRound` / `Fixed(float)` through `std::nearbyint`
(`FltOpts.hpp:140,148,159-168`). Its comment claims a "single cvtss2si", but
without `-fno-math-errno`/`-ffast-math` clang emits a real libm call (and it
blocks vectorization). Candidate fix: `-fno-math-errno` on the hot TUs, or a
direct SSE conversion (`_mm_cvtss_si32`/`lrintf`).

## Measuring frame rate

**The focus-throttle gotcha — read first.** The engine throttles rendering to
~5 fps whenever its window loses focus. So *any* FPS captured while another
window is active — a glance at the overlay, a log parsed from a terminal —
is the throttled background rate, not the real one. This silently poisons
background A/B measurements (a `--render-frame-log` capture taken while you are
typing elsewhere shows ~5 fps / 12 s-per-60-frames). Every measurement must
either keep the game window focused for the whole capture, or use a mode that
runs to completion in the foreground.

Ways to get a number, least → most rigorous:

- **`--show-fps` overlay.** `EngineDrawing.cpp:46-47` draws `iFPS`
  (`1000/last-frame-ms`) and `aFPS` (`1000/GetAvgFrameDuration`, an 8-frame
  average). Read-once, imprecise, focus-dependent. Fine for a glance, not for
  a 5%-level A/B.

- **`--render-frame-log` + log math.** Emits one `render frame:` line every
  *exactly* 60 frames (`WorldFrameObserver.cpp:196-203`, `s_statsCountdown=60`),
  each carrying a millisecond log timestamp. Exact average over a window is
  `60 × (N−1) / (t_last − t_first)` across N consecutive in-world lines. Filter
  out sparse menu/unfocused lines by inter-line gap:
  ```sh
  grep "render frame" cwr.log | sed -E 's/\x1b\[[0-9;]*m//g' | awk '
    { t=$2; gsub(/]/,"",t); split(t,a,":"); ts[NR]=a[1]*3600+a[2]*60+a[3] }
    END { n=NR; s=n; for(i=n;i>1;i--){ if(ts[i]-ts[i-1]<8) s=i-1; else break }
          d=ts[n]-ts[s]; if(d>0) printf "aFPS=%.3f over %d frames\n",(n-s)*60/d,(n-s)*60 }'
  ```
  Still focus-dependent — only valid if the window stayed focused throughout.

- **`-benchmark` mode — rigorous, deterministic, logged.** `--benchmark`
  auto-loads `Users\Test\Missions\Benchmark.Abel\mission.sqm`
  (`GameApplication.cpp:1684-1687`); once in gameplay (`GModeArcade`) it counts
  300 frames, logging `BENCHMARK: t=.. aFPS=..` each second and a final
  `BENCHMARK RESULT: {frames} frames in {s}s = {fps} avg FPS`
  (`GameApplication.cpp:1043,1059`), then exits. Parse `BENCHMARK RESULT` out of
  `--log-file` — no screen reading, fixed mission + fixed 300-frame count =
  reproducible. Caveats: (1) it only measures in `GModeArcade`, so the mission
  must reach gameplay with no blocking briefing; (2) wall-clock over 300 frames
  is still focus-sensitive, so keep the window focused for the (short) run.
  Setup (per the OFP wiki startup-parameters page): make a `Test` profile,
  build a mission on **Malden (= island "Abel")** in the editor, save it as
  `benchmark` so it lands at `Users/Test/Missions/Benchmark.Abel/mission.sqm`.
  A deterministic, no-combat, unit-heavy patrol scene (all one side, `CYCLE`
  waypoint loops — see `PERF-hotspot-profile.md`) makes it a stable CPU bench.

  **`--benchmark` was broken on POSIX by two bugs — fixed 2026-07-18 (branch
  `benchmark-posix-fix`, port `patch-apps_cwr_Game_GameApplication.cpp`):**
  1. The benchmark branch (`GameApplication.cpp:1684`) set `LoadFile` but not
     `AutoTest`, unlike the test-mission branch at :1681. Only
     `if (AutoTest) StartAutoTest()` (`WorldImpl.cpp:2235`) boots `LoadFile` into
     gameplay, so the mission never loaded — the game idled at the menu
     (`GModeIntro`) and the `GModeArcade`-gated FPS tracking never fired.
  2. The hardcoded path used Windows backslashes (`Users\Test\...`), which are
     not separator-normalized before `StartIntro`'s `FileExist()`
     (`WorldImpl.cpp:2219`) on POSIX, so the mission was never found (no "could
     not boot" error — the whole block is skipped). Use forward slashes.

  With both fixes, `--benchmark` boots `Users/Test/Missions/Benchmark.Abel/
  mission.sqm` (resolves under `user_dir`, e.g. `~/.config/CWR/Users/Test/...`),
  runs 300 frames in `GModeArcade`, and logs `BENCHMARK RESULT: N frames in Xs =
  Y avg FPS`. **It runs at full speed even when the window is unfocused** (not
  subject to the ~5 fps focus throttle), which makes it the rigorous, automatable
  FPS measurement: launch `--benchmark --log-file f`, grep `BENCHMARK RESULT`.
  The `Benchmark.Abel` mission must have units on valid Abel/Malden land
  (`draw > 0`) or the scene is empty and the number is meaningless.

  **Exact command (ser6, verified 2026-07-20) — copy this, do not improvise:**
  ```
  env DISPLAY=:0 XDG_RUNTIME_DIR=/tmp/xdg \
    PoseidonGame -C ~/.local/share/CWR/base --no-splash --benchmark \
    --test-mission ~/.config/CWR/Users/Test/Missions/Benchmark.Abel [--gpu-skinning]
  ```
  The load-bearing part is `--test-mission` pointing at the **Test-profile**
  mission `~/.config/CWR/Users/Test/Missions/Benchmark.Abel` (197 units,
  ~120 FPS). Pitfalls that wasted a whole session: `--benchmark` **alone** sits
  at the menu here; and `--test-mission ~/.local/share/Cold War Assault/missions/
  benchmark.abel` is the WRONG (empty) mission — renders ~1500 FPS, meaningless.
  `draw=0` is normal and does NOT mean nothing renders — it is `tp.drawMeshCalls`,
  a terrain-mesh-path counter; objects (soldiers, tanks, shadows) still render
  fully (see PERF-hotspot-profile.md:628). So this is a real rendered-scene
  benchmark, not CPU-sim-only. Frame count = `benchmarkMaxFrames` in the port
  patch (keep ~1000 ≈ 8 s; 10000 ≈ 83 s/run).

- **Script commands** (`GameStateExtTestAudio.cpp`): `triFps`
  (`1000/GetLastFrameDuration`), `triFrameCount`, `triMemoryMB` — callable from
  mission scripts for custom in-mission instrumentation.

## Visual A/B via screenshots (headless, reproducible)

Worked out doing the item-5e GPU-skinning visual check (a parachute canopy A/B).
The goal: render a specific thing and capture it to a PNG with no human at the
keyboard, on ser6. Artifacts from that session live in `~/cwr-5e-visual/`
(A/B pairs + the ready-to-use `paradrop_mission.sqm`).

### Use the engine's built-in screenshot, NOT scrot/xwd

`AppConfig.cpp` exposes a real capture path that reads the **GL framebuffer**
directly — reliable regardless of window stacking/focus:

- `--auto-screenshot "FRAME:PATH"` (`AppConfig.cpp:614`) — capture at gameplay
  frame FRAME, write PATH, then exit. **This is the one to use.** Log confirms
  `Auto-screenshot saved: frame=N t=Xs -> PATH`.
- `--screenshot-delay N` (`:622`, default 10) — gameplay frames to wait first.
- `--screenshot,-s PATH` (`:723`) — capture then exit (viewer/kit path).
- `--test-type screenshot` (`:640`) — with `--test-mission`, capture-and-exit.

Do **not** reach for `scrot`/`xwd` first: this host has **no `wmctrl`/`xdotool`**,
the game runs fullscreen-borderless by default (`--window` forces windowed,
`--display-mode windowed|borderless|exclusive`, `AppConfig.cpp:305-310`), and a
root-window `scrot` grabs whatever is on top — you get the desktop/terminal, not
an occluded game window. `xwd -id <win>` returned empty here. The framebuffer
capture sidesteps all of it. Capture resolution follows `graphics.cfg` (was
**800x600** here), not the desktop.

### Reproducibility notes

- **`--test-mission` copies the mission to a staging dir** each launch:
  `Test mission: <src> -> /tmp/cwr/mission-smoke/<hash>/Missions/<name>/mission.sqm`.
  So edits to the source `mission.sqm` ARE picked up per launch, and the log line
  tells you exactly which file ran.
- **Separate launches are NOT frame-deterministic.** Parachute sway, animated
  clouds, and small position drift mean base-vs-gpu at the same frame number are
  *not* pixel-aligned. A pixel diff / **`ffmpeg ... -lavfi ssim`** scored ~0.39
  here despite the render being visually identical — **SSIM is the wrong metric;
  judge these A/Bs visually.** (This is the same determinism residual documented
  in `PERF-multithread-scope.md`.)

### Recipe: a scripted paradrop A/B (what actually worked)

Make a *copy* of the benchmark mission (don't clobber `Benchmark.Abel` — the FPS
harness needs its 197-unit form) and give the **player** an `init` that boards a
parachute and sets up an external camera looking at the canopy. Ready-made
missions (top-down + side camera) are committed in `paradrop-mission/`; local PNG
evidence is in `~/cwr-5e-visual/`. The player `init` (one line in the
`mission.sqm`, `""` = literal quote):

```
this moveindriver ("ParachuteWest" createVehicle getpos this);
(vehicle this) setpos [getpos this select 0, getpos this select 1, 120];
pcam = "camera" camcreate [getpos this select 0, (getpos this select 1) - 22, 103];
pcam camsettarget (vehicle this); pcam cameraeffect ["internal","back"]; pcam camcommit 0
```

Capture the deployed canopy at **frame ~200** (t≈3.3 s):
```
env DISPLAY=:0 XDG_RUNTIME_DIR=/tmp/xdg PoseidonGame -C ~/.local/share/CWR/base \
  --no-splash --no-sound --fullscreen --test-mission <paradrop-mission-dir> \
  --auto-screenshot "200:/tmp/base.png" --timeout 35
# repeat with --gpu-skinning appended -> /tmp/gpu.png, compare the two by eye
```

### Scripting gotchas that cost time here (all real, all in the log)

- **Test mode aborts on any script ERROR** (`Script error ... — aborting`), so a
  broken `init` kills the whole run — no screenshot. Check the log first.
- **`_underscore` locals are rejected in global space in test mode**
  (`Local variable in global space`). Use a *global* var (no underscore, e.g.
  `pcam`) or nest the expression (`moveindriver ( ... createvehicle ... )`).
- **`createVehicle` ignores the Z you pass** — the parachute spawns on the
  ground, so a plain `moveInDriver` leaves the player standing. Lift it after
  boarding: `(vehicle this) setpos [... , 120]`.
- **The canopy takes ~3 s to deploy.** At t<1 s (`frame<~60`) it's still opening
  (folded, barely visible); it's fully open by frame ~200. Sample late.
- **Default parachute camera looks forward/down** — the canopy is above the
  frame. You need the scripted external camera (`camCreate`/`camSetTarget`/
  `cameraEffect`/`camCommit`, `GameStateExt.cpp:1339-1351`). `camSetTarget`
  tracks the object each frame (the camera *rotates* to keep the target framed),
  but the camera **position is static** — `camSetPos`/`camSetRelPos` are one-shot
  (`CamSetRelPos` = `SetPos(target.PositionRelToAbs(pos))` computed once at init,
  `GameStateExtUi.cpp:1496`), so the camera does **not** descend with the object.
  For a **side** view, place the camera to the side at a *fixed* altitude and
  capture at the frame the canopy falls level with it (here: `+30 m` offset,
  `z=96`, frame ~240 — see `paradrop-mission/paradrop-sideview-cam.sqm`); a
  **top-down** view falls out naturally at a higher fixed camera as the object
  drops below it.

## CLI arguments — full reference

Source of truth: `engine/Poseidon/Foundation/Platform/AppConfig.cpp` (98
`add_option`/`add_flag` calls). **Print it live:** `PoseidonGame --help-full`
(advanced user flags) and **`PoseidonGame --help --dev`** (the dev + test group —
this is where the automation/screenshot flags live; the plain `--help` hides
them). Four flags are hidden even from `--help --dev`: `--advertise-address`,
`--banner`/`--no-banner`, `--pid`, `--ranking`.

Help mode dispatch is at `AppConfig.cpp:143-164`.

### Highest-leverage flags (the ones worth memorizing)

- **`--viewer -m <model.p3d> -a <anim.rtm>`** — standalone **model + animation
  viewer**: skips splash + menu, loads one model with one RTM bound (data banks
  still mount, so textures/config resolve). Plus `--anim-speed <0..10>`,
  `--anim-loop none|repeat|ping-pong`, `--loose-textures` (accept `.png`/`.tga`
  beside expected `.paa`), `--no-help` (hide overlay). `-m`/`-a` need **loose
  files** (`CLI::ExistingFile`), so extract from PBOs first, e.g.
  `PoseidonTools pbo extract dta/Data3D.pbo out -f para.p3d` and
  `... dta/Anim.pbo out -f opened_para_stat.rtm`. Combine with `--auto-screenshot`
  for a headless isolated render — the clean way to eyeball a model/anim (see
  `~/cwr-5e-visual/viewer_parachute_canopy.png`).
  - **GPU-skinning A/B:** `--viewer --gpu-skinning` exercises the real GPU-skin
    path in isolation (no mission/scene/scripted camera). This required wiring the
    viewer's `AnimationRT::Prepare`/`Apply` to the `gpuSkin` seam
    (`Viewer.cpp:173/181`) — **before that, `--gpu-skinning` was a silent no-op in
    viewer mode** (the gpuSkin opt-in only lived in `ParachuteType::InitShape`),
    which is why the item-5e canopy A/B needed the scripted-paradrop mission
    instead. With the wiring, the viewer is now the preferred isolated skinning
    A/B tool.
- **`--auto-screenshot "FRAME:PATH"`** — GL-framebuffer capture at gameplay frame
  FRAME, then exit. The reliable headless screenshot (see "Visual A/B" above).
  Companions: `--screenshot-delay N` (frames to wait, default 10),
  `--screenshot`/`-s PATH` (capture+exit), `--test-type screenshot`.
- **`--auto-keys "FRAME:SCANCODE,FRAME:SCANCODE,..."`** — inject key events at
  specific frames. The scriptless way to drive the UI/camera headlessly (e.g.
  toggle external view, move, fire) before an `--auto-screenshot`.
- **`--test-mission,--test <dir|mission.sqm>`** — boot a mission straight into
  gameplay and exit. Copies the mission to `/tmp/cwr/mission-smoke/<hash>/` first
  (log prints the staged path), so source edits are picked up per launch.
- **`--strict` / `--no-strict`** — treat any ERROR log (**including SQF/SQS script
  errors**) as fatal → non-zero exit. **Default ON in Debug/RelWithDebInfo
  builds** (the shipped RelWithDebInfo package is strict), which is exactly why a
  broken mission `init` aborts a `--test-mission` run with no screenshot. Pass
  `--no-strict` to let a run survive script/asset errors.

### Automation / headless / self-tests

| Flag | Effect |
|------|--------|
| `--benchmark` | 300-frame FPS benchmark (needs `--test-mission`; see "Measuring frame rate") |
| `--timeout N` | Auto-exit after N seconds (0 = off) |
| `--check` | Init subsystems then exit — headless smoke test |
| `--simulate <mission>` `--duration N` `--stats N` `--time-scale 1..16` | Headless (no-render) mission simulation |
| `--harness [port]` | TCP harness server (0 = auto-assign) for external test drivers |
| `--ui-test <scenario>` | Run a UI test scenario and exit (e.g. `exit`) |
| `--confirm-revert-timeout N` | Shorten the display-revert modal for integration tests |
| `--{remount,mod-cycle,reload-clean,remount-sim,remount-fail,error-resilience}-selftest` | Mount/reload/error self-tests (boot, assert, exit) |
| `--audit-cfgvehicles-models` | Log ERROR for every editor-visible CfgVehicles class with a missing model (pair with `--strict` for CI) |

### Performance / rendering debug

| Flag | Effect |
|------|--------|
| `--gpu-skinning` | Experimental GPU vertex-shader skinning (infantry + parachute view LODs) |
| `--gpu-timing` | Per-pass GPU timestamp breakdown + present wait (real gameplay) |
| `--render-frame-log` | Per-frame pass/draw stats every ~60 frames |
| `--perf-trace <path>` | NDJSON of every `ScopedTimer` event → DuckDB `read_json_auto` / Perfetto |
| `--determinism-log` | Per-tick dynamic-entity transform checksum (determinism gate) |
| `--mt-lod` / `--mt-verify` | Parallel per-object draw-LOD selection / serial-reference verify |
| `--vd <100..100000>` | Override view distance (bypass the 5000 clamp) |
| `--maxmem MB` / `--max-threads N` | Memory hard cap / TaskPool worker cap (0 = auto ≤8) |
| `--notex` / `--noland` / `--no-terrain-cache` | Disable textures / landscape / terrain-segment cache |
| `--render dummy\|gl33\|auto` | Graphics backend (`dummy` = headless no-GL) |
| `--sw-tl` / `--tl` | Software vs hardware T&L |
| `--piii` | Pentium-III flush-to-zero float mode |

### Display / window

`--window`/`--fullscreen` (default fullscreen-borderless), `--display-mode
windowed|borderless|exclusive`, `-w`/`--width`, `-h`/`--height`, `--no-splash`,
`--no-menu-scene`, `--fps`/`--show-fps`, `--no-mouse-grab`, `--focus` (keep
rendering at full rate when unfocused — defeats the 5-fps focus throttle),
`--old-fonts`.

### Data / config / mods

`-C`/`--work-dir <data-root>` (launcher sets this), `--mod <p;p;...>` (boot with
mods, skip in-game Remount), `--mods-dir`, `--workshop-dir`, `--lang`,
`--oldpaths` (game-folder profile paths), `--encryption-required`.

### Multiplayer

`--host`, `--connect <ip>`, `--connect-port`, `--config <server.cfg>`, `--port`,
`--name`, `--password`, `--private`/`--lan`, `--master-server`, `--mp-auto-start
N`, `--mp-assign SIDE:SLOT`, `--force-jip`, `--write-mpreport`.

### Logging

`--log-level trace|debug|info|warn|error|critical|off`, `--log-categories <csv>`,
`--log-format text|jsonl`, `--log-file <path>`, `--app-tag <=10 chars>`,
`--legacy-logs`, `--logfiles` (file-ops), `--netlog`.

## Environment variables the engine reads

| Variable | Purpose | file:line |
|----------|---------|-----------|
| `POSEIDON_USER_DIR` | Root of user directory tree | `PlayerPrefs.cpp:17`, `GamePaths.cpp:91`, `AppConfig.cpp:222` |
| `POSEIDON_USER_CONTENT_DIR` | User content (mods, saves) | `GamePaths.cpp:90`, `AppConfig.cpp:218` |
| `POSEIDON_MODS_DIR` | Mods directory | `AppConfig.cpp:211` |
| `POSEIDON_TEST_MACHINE_ID` | Test env machine ID | `MultiplayerAuth.cpp:98` |
| `POSEIDON_TEST` | Suppress console output under test | `Logging.cpp:508` |
| `POSEIDON_TEST_LOG` | Re-enable logging in test mode | `Logging.cpp:508` |
| `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, `XDG_DATA_HOME` | POSIX dirs | `PlatformPaths_posix.cpp:21,51,58` |
| `HOME` | POSIX fallback | `PlatformPaths_posix.cpp:25` |
| `CWR_DATA` | (Launcher only, not engine) | `bin/cwr-ce` |

Base POSIX layout resolved by `PlatformPaths_posix.cpp:19-58`:
`$XDG_CONFIG_HOME/AppName` or `$HOME/.config/AppName` for config,
`$XDG_DATA_HOME` or `$HOME/.local/share` for data.

## Known gaps / things not present

- No `PoseidonAssert` / `DoAssert` macro found. Might live in
  `engine/Poseidon/Foundation/Common/Win.h` (not fully audited).
- No `RptF()` secondary log (that's the OFP/Arma legacy API — not carried
  over into Poseidon).
- No in-game debug console.
- No `POSEIDON_BUILD_FUZZERS` in the CMakeLists I sampled — though it's
  referenced in the port's `CMAKE_OFF`.
- No POSIX watchdog (Windows-only — `DebugTrap.cpp:23-136`).
- No Vulkan-context creation code fully mapped yet — the GL33 backend at
  `EngineGL33.cpp` is what the survey found; Vulkan usage in the tree is
  present but its init path is not yet documented here.

Extend this doc as you learn more.
