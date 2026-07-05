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

## CLI flags reference (diagnostics)

From `engine/Poseidon/Foundation/Platform/AppConfig.cpp`. Not exhaustive
— run `PoseidonGame --help-full` (and `--help --dev` in non-release
builds) for the full list.

| Flag | Effect | Line |
|------|--------|------|
| `--check` | Init subsystems then exit — headless smoke test | 475-476 |
| `--timeout N` | Auto-exit after N seconds | 590-593 |
| `--strict` / `--no-strict` | ERROR log = exit 1 | 520-524 |
| `--dev` | Enable dev panel (non-release only) | 560-562 |
| `--log-level ...` | Verbosity | 655-657 |
| `--log-categories ...` | Category filter | 659-662 |
| `--log-format text\|jsonl` | Log output format | 668-672 |
| `--log-file <path>` | Write to file | 677 |
| `--logfiles` | Log file-ops | 569-570 |
| `--netlog` | Log network | 572-573 |
| `--max-threads N` | TaskPool worker count (0 = auto, cap 8) | 548-551 |
| `--no-sound` | Skip audio init | 425 |
| `--audio auto\|OpenAL\|dummy` | Force backend | 428 |
| `--no-splash` | Skip splash screens | 319 |
| `--width, --height` | Window size | 312-316 |
| `-C <data-root>` | Data directory (launcher sets this) | — |
| `--mod <path>[;<path>...]` | Boot with mods active, skip in-game Remount | 428 |
| `--help`, `--help-full` | Basic / advanced usage | 267 |

Help modes detected at `AppConfig.cpp:143-164`:
- `--help` — basic flags
- `--help-full` — advanced
- `--help --dev` — developer + test options (release builds hide `--dev`).

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
