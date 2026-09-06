# fbsd-quality — can a local model write a FreeBSD kernel module?

An **objectively scored** agent benchmark: the model is asked to write a
loadable FreeBSD kernel module against the real `/usr/src`, and the module
either produces the expected observable behaviour in a throwaway bhyve VM or it
does not. No judge model, no rubric — unlike
`../benches.DaemonDocs-model-quality.md`, which counts violations found by a
fact-checker.

## Why kernel modules, and why these tasks

FreeBSD kernel internals are **thin in LLM training data** compared with Linux,
which is the point: a model cannot coast on recall. The tasks deliberately use
facilities with **no Linux analogue**, so Linux muscle memory is useless:

| tier | facility | why it defeats memorisation |
|-----:|----------|-----------------------------|
| 1 | `EVENTHANDLER` (`process_exit`) | FreeBSD-only hook pattern; needs the `exitlist_fn` signature and `EVENTHANDLER_REGISTER` arity from `sys/sys/eventhandler.h` |
| 2 | `osd` — Object-Specific Data | `sys/kern/kern_osd.c` is 457 lines with essentially no tutorials; needs `osd_register`/`osd_set`/`osd_get` semantics |
| 3 | `subr_unit` unit allocator | `new_unrhdr`/`alloc_unr`/`free_unr`; obscure, self-contained, and the allocation sequence is deterministic so it is trivially verifiable |
| 4 | `hhook` — helper hook points | the module must **both publish a hook point and consume it**, i.e. write the two halves of an API that in-tree are written by different subsystems (`hhook_head_register` by TCP/socket code, `hhook_add_hook` by a Khelp module). Also needs a struct filled in correctly and a constant found in a header the prompt does not name. |
| 5 | `epoch` — deferred reclamation | the only tier whose observable is **asynchronous**: `epoch_call()` defers to a grace period, so a model that reads it as "call this now" emits the two lines in the wrong order and fails on ordering alone. Also requires knowing that a *non*-preemptible epoch is needed for `in_epoch()` to report true. |
| 6 | `release(7)` / `src.conf` trimming | opt-in, different in kind: a long-horizon build-engineering task scored on whether the image boots, not on a dmesg marker. |

Tiers 1-3 are **saturated** — every model tested passes all three (see Results),
so they no longer discriminate on pass/fail. Tiers 4-5 exist because of that.

Deliberately **not** a hello-world module: that is ~15 lines and appears in
every driver tutorial, so it measures recall rather than engineering.

## What is measured

"Iterations to success" alone is a poor discriminator — it is coarse, quantised,
and capable models all finish in 1-2. So every run records:

- **`passed`** — did the expected marker appear? (the objective result)
- **`iterations`** — agent loop turns consumed
- **`wall_s`**, **`tokens_in`/`tokens_out`** — the *speed* half of the question
- **`failure_class`** per iteration — `compile` / `load` / `wrong_output` /
  `panic` / `harness` — because a model that writes good C but fumbles the
  agent loop is failing differently from one that writes broken C, and
  iteration counts alone conflate them
- **`tier_reached`** — the headline quality signal: how far up the ladder it got

### Build time is measured, but not charged to the model

`wall_s` covers the whole attempt, so it includes every `make(1)` the agent
ran. That is fine for tiers 1-5 (a module builds in seconds) but would be
actively misleading for the tier-6 image task, where a build can be minutes and
would swamp the number meant to describe the model.

So `run_shell` accumulates its own elapsed time and the results carry all three:

| field | meaning |
|---|---|
| `wall_s` | total attempt duration |
| `shell_s` | time inside `run_shell` — i.e. `make`, mostly |
| `model_s` | `wall_s − shell_s` — the model's own latency |

Compare models on **`model_s`** and `tokens_out`; use `shell_s` to see how much
compiling a model's approach cost, which is itself a quality signal (a model
that trims the build well finishes sooner).

## Scaffolding policy (deliberate)

The agent gets **no `Makefile` and no build recipe**. Discovering
`bsd.kmod.mk` and `SYSDIR` from `/usr/src` is part of the task, and is where
weaker models are expected to fail.

The agent does **not** have to know anything about bhyve or p9fs. That plumbing
is the harness's job — making the model invent bhyve flags would measure bhyve
trivia and fail every model for the same irrelevant reason.

## Architecture

Build on the **host**, load in a **VM**:

```
host                                    bhyve guest (minimal)
────                                    ─────────────────────
agent writes hello.c + Makefile
  into  $SHARE/                    ──►  mount -t p9fs bench /mnt
make (host toolchain, /usr/src)         kldload /mnt/<mod>.ko
  ──► <mod>.ko in $SHARE/               dmesg | grep <marker>
```

- Compile errors are caught on the host in **seconds**, without booting a VM.
- The VM stays **minimal** (kernel + userland, no toolchain, no `/usr/src`) —
  a full build environment inside the guest would need a multi-GB image and
  slow cold builds.
- `virtio-9p` shares the work directory, so **no image rebuild per iteration**.
- The VM is disposable: a kernel **panic is a legitimate result** (the model
  wrote unsafe code), recorded as `failure_class=panic`, and recovered by ZFS
  rollback rather than a rebuild.

## Running two endpoints in parallel

Safe by construction — each bench process isolates the three things that would
otherwise collide:

```sh
# framework (FreeBSD)
sudo python3 bench.py --model qwen38-mtp --api-base http://192.168.100.7:8080/v1 \
     --disk /zroot/vm/fbsdq.img --src /usr/src --agent-user olivier &

# framework2 (Ubuntu)
sudo python3 bench.py --model flashnext --api-base http://192.168.100.8:8080/v1 \
     --disk /zroot/vm/fbsdq.img --src /usr/src --agent-user olivier &
```

| shared resource | how it is isolated |
|---|---|
| scratch dir | per-run `/tmp/fbsd-quality/<model>-<pid>`; override with `--workdir` |
| VM name | `fbsdq-<uuid>`, and `_destroy()` **refuses** any name not matching `fbsdq-*`, so neither run — nor an unrelated bhyve guest on the host — can be torn down by the other |
| guest disk | each VM gets a **ZFS clone** of the base image (or a plain copy off ZFS); two guests writing one `virtio-blk` file would corrupt both |
| results file | `--out` appends are `O_APPEND` + flushed per record, so one shared JSONL is fine; `run_id` and `api_base` are recorded in every row |

### The source tree

**Don't expect the model to avoid conflicts by cloning the tree itself.** The
prompt never tells it another agent exists, so it has no reason to — and you
would not want it to: `/usr/src` here is 3.1 GB / 116k files, so a "helpful"
clone inside the agent loop would burn minutes and gigabytes and inflate
`wall_s`/`iterations` for reasons unrelated to kernel skill.

Instead the harness prepares the tree, via `--src-mode`. Costs measured on this
host (3.1 GB tree, 2.1 GB of it `.git`):

| `--src-mode` | cost per run | independent tree | writable |
|---|---|---|---|
| **`ro`** (default) | **~0 s, 0 bytes** — nullfs bind | no (shared) | **no** |
| `zfs-clone` | ~0 s, ~0 bytes (CoW) | yes | yes |
| `shallow` | **45 s, 1.3 GB** — `git clone --depth 1` | yes | yes |
| `none` | 0 | no | yes |

**`ro` is the right default**: tiers 1-5 only ever *read* the tree (the agent
builds in its own workdir with `SYSDIR` pointing at it), so writability buys
nothing and read-only makes mutation *impossible* rather than merely detected —
which matters because the bench runs as root for bhyve.

Use `zfs-clone` when a run needs a **different revision** (e.g. stable-14 vs
16-CURRENT) — that is the one case independence is genuinely useful.
`shallow` is the weakest option: the only one with a real time and space cost,
and it still leaves the tree writable. It exists for trees not on ZFS.

With `--src-mode=none` and two runs on one tree, `src_dirtied` cannot attribute
damage to either — both runs are contaminated.

## Privilege model — read this

The bench needs **root** for `bhyve`. Without `--agent-user`, the agent's
`run_shell` therefore also runs as root and can modify the source tree, the
host, anything. **Always pass `--agent-user <unprivileged user>`**: the agent
drops to that user and only the VM step stays privileged. The bench warns if
you run as root without it.

There is also a string-matching tripwire that refuses shell commands which
write into `--src`, and a post-task `git status` check that reports a dirtied
tree. Both are **accident detectors, not containment** — a root agent can defeat
either trivially. `--agent-user` is the actual boundary.

## Building the guest image

```sh
sudo ./mkimage.sh -S /usr/src -o /zroot/vm/fbsdq.img
```

Produces a ~150-200 MB UFS+UEFI image containing **only**: the kernel from the
source tree, `/rescue` (≈12 MB of static binaries — `sh`, `mount`, `kldload`,
`kldunload`, `dmesg`, `shutdown`), and a five-line `/etc/rc`. No `/lib`, no
`/usr`, no toolchain, no `/usr/src`: the guest never compiles anything, it only
`kldload`s what the host built and shares in over 9p.

It boots straight to a root shell on com1 — no getty, no login, no rc scripts,
`autoboot_delay=0` — because `vmrunner.py` drives that shell by typing at it.
`/etc/rc` prints `FBSDQ-GUEST-READY <version>` as the handshake.

### The version trap — read this before wondering why everything fails

**The guest kernel must match the SOURCE TREE, not the running host.** A `.ko`
only loads into a kernel with a compatible `__FreeBSD_version`; `kldload`
rejects a mismatch outright. If the guest is built from `/boot/kernel` while
the agent builds against a different tree, *every* task fails at load with a
`failure_class=load` that has nothing to do with the model.

This is not hypothetical — it was live on the development host:

```
source tree /usr/src : __FreeBSD_version 1600022
running host         : __FreeBSD_version 1600020   <- a git pull ahead
```

and it is the normal case if you run, say, 15.1-RELEASE with a 16-head
checkout. So `mkimage.sh` takes the kernel from **the tree's object directory**
(`/usr/obj<src>/<arch>/sys/<CONF>/kernel`, preferring `*-NODEBUG`), falls back
to `/boot/kernel` *only* when tree and host versions are equal, and otherwise
**refuses and tells you to `make buildkernel`** rather than silently producing
a useless image. `bench.py` prints the same warning at startup.

## Layout

```
tasks.py     tier definitions: prompt, expected marker, verification
vmrunner.py  bhyve lifecycle, p9fs share, kldload + dmesg capture
builder.py   host-side `make` of whatever the agent produced
bench.py     smolagents driver, per-iteration scoring, JSONL output
mkimage.sh   builds the minimal bhyve guest (run once, as root)
```

## Requirements

**To build the guest image** (`mkimage.sh`) — base system only, no Python:

- root (`mdconfig`/`gpart`/`newfs`/`mount`)
- a source tree, and a kernel built from it (see the version trap above)
- `/usr/local/share/uefi-firmware/BHYVE_UEFI.fd` (`pkg install uefi-edk2-bhyve`)

**To run the bench** (`bench.py`):

- `vmm` loaded, `bhyve`/`bhyvectl`, root for VM creation
- ZFS (optional but recommended: per-VM disk clones, cheap rollback)
- `pip install smolagents` — the agent framework that drives the model under
  test. Only `bench.py` needs it; the image builder does not.
- an OpenAI-compatible endpoint. Normally a local `llama-server` from
  `../llmsrv.sh`, e.g. `--api-base http://127.0.0.1:8080/v1`.

### What gets logged

Everything, in four layers — the summary table alone is useless for reviewing a
failure weeks later:

| where | what |
|---|---|
| `logs/bench-<stamp>.log` | full stdout+stderr, plus host version, python and smolagents versions, and the exact argv (`run.sh` tees it) |
| `results.jsonl` | one JSON row per (model, task, rep): `passed`, `failure_class`, `iterations`, `wall_s`/`shell_s`/`model_s`, tokens, `src_rev`, `run_id`, `backend` |
| `artifacts/<run_id>/<task>-rep<n>/` | **the C and Makefile the model wrote**, `build.log`, `console.log` (guest serial output), `trace.txt` |
| `trace.txt` | the agent's step-by-step reasoning — which header it read, what it concluded, where it went wrong |

`trace.txt` is the one to open first when a model fails: it shows whether it
looked in the right header, misread a signature, or never searched at all.
Disable archiving with `--artifacts none` if disk is tight.

### Calibrating the ladder

Worth doing before trusting a sweep: the stated risk is that tiers 1-3 prove
too *hard* rather than too easy, in which case every local model fails at tier 1
and the bench discriminates nothing.

Running one strong reference model separates "the tasks are hard" from "the
harness is broken": if it clears all three, local failures are real signal; if
it also fails tier 1, fix the tasks or the harness first.

Against a frontier model on an Anthropic proxy:

```sh
sudo ./run.sh --backend anthropic \
     --api-base http://127.0.0.1:20000/proxy/ocochardclaude \
     --model claude-opus-4-5 \
     --disk /zroot/vm/fbsdq.img --agent-user olivier --reps 1
```

Note `--backend anthropic`: that proxy needs the **native** `/v1/messages` API.
Its `/v1/models` lists 1674 OpenAI ids and **zero** Anthropic ones, yet
`claude-opus-4-5` answers on `/v1/messages` — so discovering the model id by
listing does not work, and `OpenAIServerModel` cannot reach it at all.
Verified working ids on that proxy: `claude-opus-4-5`, `claude-sonnet-5`,
`claude-sonnet-4-5-20250929`.

## Kernel core dumps — available, not required

A panicking module is a legitimate result, and sometimes the console backtrace
is not enough to explain it. So the harness makes a real kernel dump available
to the agent, while never requiring it:

1. **The guest has a dump device.** The image carries a 640 MB
   `freebsd-swap` slice (`gpt/fbsdq-dump`) and `/etc/rc` runs `dumpon` before
   anything can panic — verified: `FBSDQ-DUMPDEV-ARMED`, and `dumpon -l`
   reports `gpt/fbsdq-dump`. Without this a panic has nowhere to write and
   `savecore(8)` finds nothing.
2. **A panic is not cut short.** On matching a panic the runner types `dump`
   then `reset` at the DDB prompt, so the core is actually written before the
   guest reboots; `/etc/rc` then `savecore`s it into `/var/crash`.
3. **The disk is preserved, not deleted.** Normally each VM's disk clone is
   destroyed after the run; on panic it is copied to `_dumps/` instead —
   otherwise the core would be thrown away with it.
4. **The core is extracted on the host.** `extract_core()` mounts the
   preserved image read-only and copies `/var/crash` out. Debugging has to
   happen host-side: `/rescue` has `savecore` but **no `kgdb`**, and the guest
   has no `/lib` for a dynamic one.
5. **The agent gets a `debug_last_panic` tool** that runs `kgdb` against the
   core with `kernel.debug` (located automatically — both the kernel and the
   modules are built unstripped, so symbols resolve). With no dump present the
   tool explains that rather than erroring.

**Why "not required" matters.** If a model had to learn `savecore`, extract a
dump and drive `kgdb` to pass tier 1, it could fail for *dump-plumbing* reasons
while having written perfectly good kernel C — which would invert what the
bench measures. For 20-50 line modules the console backtrace usually names the
faulting function anyway. The dump earns its cost on the deferred harder tiers
(`epoch`, `khelp`), where failures are lock-order reversals and
use-after-free that a backtrace alone will not explain.

## Is the harness "cheating"?

A fair question, and the line is drawn deliberately:

- **`mkimage.sh` is harness plumbing, not the task.** The bench measures whether
  a model can write a kernel module; the guest it loads into is scaffolding, in
  the same category as the bhyve command line. Making the guest work gives no
  model an advantage over another.
- **The task prompts leak nothing.** They name only the facility and the
  observable — never `bsd.kmod.mk`, `SYSDIR`, or the header that declares the
  API. Finding those is the test. (An early draft of this harness had a
  hand-written hello-world module lying around as a "reference"; it was deleted
  precisely because it would have leaked the answer.)
- **Tier 6 (the image task) is the case to watch**, since it asks the model to do the same job as
  `mkimage.sh`. Its prompt was checked against every trap discovered while
  writing that script — `/usr/obj`, `bsd.kmod.mk`, `SYSDIR`, `memstick`,
  `WITHOUT_*`, `GENERIC-NODEBUG`, `/rescue`, hardlinks, `nullfs`, `mdconfig` —
  and mentions **none** of them.
- The one thing tier 6 *does* state is that a module must match the kernel's
  `__FreeBSD_version`. That is stated on purpose: without it the task is unfair
  rather than hard, because a model could build a perfect image that fails for
  an invisible ABI reason.

## Status

**Guest image: built and verified end-to-end** (2026-09-05). The smoke test
confirmed the whole mechanism the bench depends on:

```
FBSDQ-GUEST-READY 1600022     <- boots to a root shell on com1, no input
FBSDQ-MOUNT-RC=0              <- mount -t p9fs -o trans=virtio
ls /mnt -> nullfs.ko          <- host files visible in the guest
FBSDQ-KLDLOAD-RC=0            <- module loaded FROM the share
kldstat -> 4 nullfs.ko        <- really resident, not a silent no-op
UNLOAD-RC=0                   <- clean unload
```

Image is 29 MB used in a 512 MB sparse file, boots in ~40 s.

Three bugs found and fixed by actually running it — all in the image builder,
none in the scoring:

1. `cp -Rp` of the obj kernel dir copied **1.5 GB of `.o`/`.meta`** into a
   512 MB image ("No space left on device"). An obj kernel dir is not shaped
   like `/boot/kernel`; only `kernel` + `*.ko` are wanted — 16 MB.
2. `cp -Rp /rescue` **broke its hardlinks**: `du` reports 12 MB, but those ~150
   names are links to one 20 MB static binary, so a naive copy writes
   **3.0 GB**. Fixed with `tar`, which preserves links (149 links verified
   intact in the image).
3. `/rescue` has **no `uname`**, so the handshake printed an empty version.
   Switched to `sysctl -n kern.osreldate` — which is also the exact number
   `kldload` compares, so it is the better value anyway.

### The ladder is calibrated

`claude-opus-4-5` passes all three tiers (numbers in the results table below),
verified by evidence rather than by the verdict alone:

```
t1: FBSDQ-MOUNTED -> FBSDQ-LOADED -> FBSDQ:exit:pid=28/29/30 -> FBSDQ-UNLOADED
t2: FBSDQ:osd:slot=2:roundtrip=0xdeadbeef      (real slot, real set->get)
t3: FBSDQ:unr:a=0:b=1:c=2:reuse=1              (real allocator; a faked
    counter would print reuse=3 — the anti-cheat worked)
```

**So tiers 1-3 are solvable with no scaffolding**, and a local model failing
them is real signal rather than a broken harness — which was the open question
the calibration run existed to answer. The agent discovered `bsd.kmod.mk`
unaided, e.g.:

```make
SRCS=	exit_monitor.c
KMOD=	exit_monitor
.include <bsd.kmod.mk>
```

Note `shell_s` is 0.3-0.8 s against 89-170 s of `model_s`: for these tiers the
build is negligible, which is exactly why the two clocks are reported
separately (it would be badly misleading for tier 6).

One caveat on t2, recorded in `tasks.py`: the model passed using
`osd_thread_register()`/`osd_thread_set()` — the `OSD_THREAD` wrappers — where
the prompt asks for the *process* type. The API use was genuine and the
round-trip real, so it is a legitimate pass, but the marker cannot tell the two
object types apart. Tighten it if that distinction matters.

### Results (2026-09-06)

Every model here ran under one identical harness. Earlier runs exist in
`results.jsonl` but were taken before the harness gained `ENV_NOTE` and the
raised snippet budget, so they are **not comparable and are not reported** —
including the earlier Opus reference, which was affected too (it also lost
steps to the import sandbox). That is why the reference was re-run rather than
reused: keeping it would have given the local models a hint the reference never
got.

Filter to the current harness with `run_id` prefix `v2-`; anything else in
`results.jsonl` predates it.

Config, identical across all runs: `--src-mode ro`, src `5b10c3c3e3d5`,
`--max-steps 60`, `--no-progress-patience 8`, `--reps 1`, `--seed 42` on the
local endpoints (omitted for Opus — the Anthropic API has no seed parameter,
so passing one would look reproducible without being so).

Columns:

| column | meaning |
|---|---|
| `iters` | agent loop turns consumed — one model call plus its tool call. Bounded by `--max-steps` (60 here). |
| `model_s` | `wall_s − shell_s`: the model's own latency. **Compare models on this.** |
| `shell_s` | time inside `run_shell`, i.e. mostly `make`. Charged to the approach, not the model. |
| `tok_out` | output tokens the endpoint actually delivered. From smolagents' counter, which matches llama-server's `tokens_predicted` exactly on every row here. Delivered, **not** drafted: `tokens_predicted` equals `n_decode + accepted drafts` to within 1 %, and is *smaller* than `spec_decode_num_draft_tokens_total`. |
| `tok/dec` | `tok_out ÷ n_decode` — delivered tokens per decode step, i.e. the MTP payoff. 1.00 means speculation buys nothing; higher is better. Blank where the endpoint exposes no `/metrics` (the Anthropic proxy). |
| `reparse` | steps whose reply was not wrapped in `<code>…</code>`, so smolagents raised `AgentParsingError` before running anything. **These steps are counted in `iters` but produced nothing** — subtract them to compare capability rather than format compliance. Explained below. |

Two further counters are in `results.jsonl` but omitted from the table because
they are 0 or 1 on nearly every row: `timeout_errors` (a code block exceeding
`--snippet-timeout`) and `sandbox_errors` (a denied `import`). Both are
surfaced as footnotes under the summary table `bench.py` prints.

| model | host | task | pass | iters | model_s | shell_s | tok_out | tok/dec | reparse |
|-------|------|------|------|------:|--------:|--------:|--------:|--------:|--------:|
| claude-opus-4-5 | proxy | t1-eventhandler | **yes** | 23 | 94.5 | 0.4 | 2 471 | — | 0 |
| claude-opus-4-5 | proxy | t2-osd | **yes** | 28 | 162.5 | 1.0 | 5 202 | — | 0 |
| claude-opus-4-5 | proxy | t3-unr | **yes** | 25 | 99.3 | 0.5 | 2 692 | — | 0 |
| Flash-Next IQ3_XXS | frwk-bsd | t1-eventhandler | **yes** | 49 | 2 118.3 | 5.0 | 39 065 | 1.50 | 0 |
| Flash-Next IQ3_XXS | frwk-bsd | t2-osd | **yes** | 49 | 2 463.8 | 132.8 | 50 840 | 1.52 | 0 |
| Flash-Next IQ3_XXS | frwk-bsd | t3-unr | **yes** | 58 | 1 381.2 | 1.6 | 27 236 | 1.52 | 8 |
| Flash-Next IQ3_XXS | frwk-linux | t1-eventhandler | **yes** | 41 | 1 833.9 | 5.4 | 35 641 | 1.53 | 0 |
| Flash-Next IQ3_XXS | frwk-linux | t2-osd | **yes** | 44 | 1 574.4 | 474.1 | 30 924 | 1.51 | 0 |
| Flash-Next IQ3_XXS | frwk-linux | t3-unr | **yes** | 49 | 1 645.3 | 5.5 | 31 700 | 1.52 | 0 |
| Qwen3.8-27B Q8 MTP | frwk-bsd | t1-eventhandler | **yes** | 53 | 1 559.4 | 0.9 | 20 165 | 3.81 | 0 |
| Qwen3.8-27B Q8 MTP | frwk-bsd | t2-osd | **yes** | 62 | 4 261.9 | 12.9 | 54 750 | 3.36 | 0 |
| Qwen3.8-27B Q8 MTP | frwk-bsd | t3-unr | **yes** | 42 | 819.6 | 0.7 | 11 042 | 3.66 | 0 |
| Qwen3.8-27B Q8 MTP | frwk-linux | t1-eventhandler | **yes** | 57 | 3 130.3 | 2.6 | 37 693 | 3.46 | 0 |
| Qwen3.8-27B Q8 MTP | frwk-linux | t2-osd | **yes** | 28 | 1 731.6 | 1.3 | 25 363 | 3.39 | 0 |
| Qwen3.8-27B Q8 MTP | frwk-linux | t3-unr | **yes** | 46 | 516.8 | 1.6 | 5 468 | 3.58 | 0 |

**15/15 PASS** on tiers 1-3. Three things follow.

**1. Tiers 1-3 no longer discriminate on pass/fail.** Every model passed every
tier on both hosts. Earlier "0/3" and "2/3" scores were harness artifacts — the
`CTX=32768` clamp and an over-tight step cap, both described below — not model
limits. Flash-Next in particular went from 0/3 to 3/3 with no change to the
model, only to its context size.

That is the most important finding here and it is a **limitation of the
ladder**: as a quality gate these three tiers are now saturated, and only cost
separates the models. Adding the harder tiers already sketched below
(`khelp`/`hhook`, `epoch` read sections) is the obvious next step — they were
deferred precisely to avoid a bench that floors out, and the opposite happened.

**2. The tasks were not trivialised by `ENV_NOTE`.** The concern with adding it
was that it might hand models the answer. It did not: Opus still needs 23-28
steps per tier, unchanged from before the note, and the local models still need
28-62. What vanished was the wasted retries, not the difficulty.

**3. Cost is what separates the models now**, and the gap is large. Medians
over all six runs per local model, against Opus's three:

| | median iters | median model_s | median tok_out |
|---|---:|---:|---:|
| claude-opus-4-5 | 25 | **99** | 2 692 |
| Flash-Next IQ3_XXS | 49 (2.0x) | 1 740 (**18x**) | 33 670 (13x) |
| Qwen3.8-27B Q8 MTP | 50 (2.0x) | 1 646 (**17x**) | 22 764 (8x) |

Both local models need almost exactly **twice** the agent steps and roughly
**17-18x** the wall time for the same verdict. The two are near-identical on
steps and time; Qwen3.8-27B is the more economical on tokens.

Why the wall-clock gap is so much larger than the step gap: decode dominates.
Measured live on frwk-bsd mid-run, prefill ran at 132.6 tok/s but decode at
**16.6 tok/s**, and decode was 84 % of elapsed time. At that rate ~900 tokens
of output *is* ~54 s, so a model's cost here is set by how many tokens it emits
per step, not by how many steps it takes.

**The two local models get very different value from MTP**, and the `tok/dec`
column is where it shows:

| model | tok/dec | draft acceptance |
|---|---:|---:|
| Qwen3.8-27B Q8 MTP | **3.4-3.8** | 0.60-0.75 |
| Flash-Next IQ3_XXS | 1.50-1.53 | 0.51-0.54 |

Qwen3.8-27B extracts more than twice as many tokens per decode step. That is
the `qwen38-mtp` slot's `--spec-draft-n-max 4` against the `flashnext` slot's
`2`, compounded by higher acceptance — and it is why a dense 27B stays
competitive on wall time with a 125B MoE that has far more raw throughput.

**Do not read frwk-linux's lead as an OS effect.** It totals less time than
frwk-bsd for both models (Flash-Next 5 054 s vs 5 963 s; Qwen3.8-27B 5 379 s vs
6 641 s), which looks systematic — but at `--reps 1` these are single samples,
the two hosts contended for this machine while running in parallel, and the
`reparse` column swings far enough on one sample to show why.

### Tiers 4-5 — reference calibration only (2026-09-06)

Added because tiers 1-3 saturated. Reference model only so far, to settle
whether they are solvable at all: a task no model can pass is broken, not hard.

| model | task | pass | iters | model_s | shell_s | tok_out |
|-------|------|------|------:|--------:|--------:|--------:|
| claude-opus-4-5 | t4-hhook | **yes** | 32 | 157.7 | 1.0 | 5 370 |
| claude-opus-4-5 | t5-epoch | **yes** | 19 | 94.0 | 0.4 | 3 164 |

Verified from the guest console, not the verdict: t4 printed
`type=2:id=42:udata=0xfeedface:ran=1` (type and id come from the kernel's
stored hook head, so a real dispatch happened), t5 printed `inside=1` then
`reclaimed=1` in that order (the deferred callback really ran later). The t4
trace shows discovery, not recall: it read `hhook.h` and `kern_hhook.c`, then
used `HHOOK_TYPE_SOCKET` — a constant the prompt never names.

Both cost the reference *less* than tier 2 (28 iters / 162 s), so "harder" here
means more API surface to discover, not more turns. No local model has
attempted them; that is the next run.

**Marker fix these tiers exposed.** In `sys/kern/subr_prf.c`, `%p` sets
`sharpflag` when given no width (line 838) and that prepends its own `0x`
(line 937), so `printf("...=0x%p", p)` emits `0x0xfeedface`. That is why the
Qwen3.8-27B frwk-linux t2 row was scored `wrong_output` earlier — correct OSD
logic, real round-trip, doubled prefix. t2/t4/t5 now accept `0x(?:0x)?`, still
rejecting a triple prefix, wrong hook type, wrong id and a lost `udata`. That
historical t2 row would score differently today; a rescore is in flight, and
the 15/15 table above is as measured under the old marker.
