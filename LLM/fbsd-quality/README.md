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
ran. That is fine for tiers 1-3 (a module builds in seconds) but would be
actively misleading for the tier-4 image task, where a build can be minutes and
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

**`ro` is the right default**: tiers 1-3 only ever *read* the tree (the agent
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
- **Tier 4 is the case to watch**, since it asks the model to do the same job as
  `mkimage.sh`. Its prompt was checked against every trap discovered while
  writing that script — `/usr/obj`, `bsd.kmod.mk`, `SYSDIR`, `memstick`,
  `WITHOUT_*`, `GENERIC-NODEBUG`, `/rescue`, hardlinks, `nullfs`, `mdconfig` —
  and mentions **none** of them.
- The one thing tier 4 *does* state is that a module must match the kernel's
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
separately (it would be badly misleading for tier 4).

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

| model | host | task | pass | iters | model_s | shell_s | tok_out | reparse |
|-------|------|------|------|------:|--------:|--------:|--------:|--------:|
| claude-opus-4-5 | proxy | t1-eventhandler | **yes** | 23 | 94.5 | 0.4 | 2 471 | 0 |
| claude-opus-4-5 | proxy | t2-osd | **yes** | 28 | 162.5 | 1.0 | 5 202 | 0 |
| claude-opus-4-5 | proxy | t3-unr | **yes** | 25 | 99.3 | 0.5 | 2 692 | 0 |
| Flash-Next IQ3_XXS | frwk-bsd | t1-eventhandler | **yes** | 49 | 2 118.3 | 5.0 | 39 065 | 0 |
| Flash-Next IQ3_XXS | frwk-bsd | t2-osd | **yes** | 49 | 2 463.8 | 132.8 | 50 840 | 0 |
| Flash-Next IQ3_XXS | frwk-bsd | t3-unr | **yes** | 58 | 1 381.2 | 1.6 | 27 236 | 8 |
| Flash-Next IQ3_XXS | frwk-linux | t1-eventhandler | **yes** | 41 | 1 833.9 | 5.4 | 35 641 | 0 |
| Flash-Next IQ3_XXS | frwk-linux | t2-osd | **yes** | 44 | 1 574.4 | 474.1 | 30 924 | 0 |
| Flash-Next IQ3_XXS | frwk-linux | t3-unr | **yes** | 49 | 1 645.3 | 5.5 | 31 700 | 0 |

**9/9 PASS.** Two things follow.

**1. Flash-Next solves all three tiers.** An earlier run scored it 0/3
(`no_files_written` / `context_exhausted` / `compile`), which was entirely the
`CTX=32768` clamp described below — a value derived for UD-IQ4_XS and carried
to IQ3_XXS without being re-derived. At 131072 the same quant passes every tier
on both hosts. A stale configuration value produced a completely wrong
conclusion about this model's capability, which is the main reason this doc
reports one harness only.

**2. The ladder is still discriminating.** The concern with adding `ENV_NOTE`
was that it might make the tasks easier. It did not: Opus still needs 23-28
steps per tier, and the two sandbox denials that remain are a model ignoring a
note it was given rather than a harness that never stated the rule.

Cost gap to the reference is the real result, and it is large:

| | Opus | Flash-Next (best host) | ratio |
|---|---:|---:|---:|
| median iters | 25 | 44 | 1.8x |
| median model_s | 99 | 1 645 | **17x** |
| median tok_out | 2 692 | 31 700 | 12x |

Same verdict, ~17x the wall time and ~12x the output tokens.

**Do not read frwk-linux's win as an OS effect.** It leads on every tier
(41/44/49 vs 49/49/58), but at `--reps 1` with MTP on that is one sample, and
the `reparse` column shows why that matters — see the next subsection.

#### The reparse asymmetry is noise — worked example of an n=1 trap

This one is recorded because it is the clearest available demonstration of why
`--reps 1` cannot support a claim, and the two runs involved are the evidence.

The first Flash-Next run split **Ubuntu 6, FreeBSD 0**. That looked
host-linked, and I proposed a mechanism — MTP draft acceptance perturbing token
choice at the tag boundary — noting both endpoints ran identical launch args
and the same GGUF template.

The repeat run split **FreeBSD 8, Ubuntu 0**: same asymmetry, opposite host.

A host-linked mechanism cannot switch hosts. It is run-to-run variance in one
model under unseeded-in-practice MTP sampling, and the first pattern was a
single-run artifact. The honest statement at n=1 was "could be noise";
proposing a mechanism gave it far more weight than one sample supports. Treat
every single-rep column in the table above the same way.

The failure mode itself is real and worth keeping counted: Flash-Next under
`--jinja` sometimes answers in Qwen native tool-call syntax
(`<tool_call><function=code>…`, occasionally with a stray `</parameter>`)
instead of `<code>…</code>`. smolagents raises `AgentParsingError`, feeds it
back, and the model retries. The Python inside is valid every time — the step
is lost to the envelope, not to capability. That is why `reparse` is reported
next to `iters`: t3 on frwk-bsd used 58 iterations, 8 of which produced nothing.

#### MTP behaviour under a real agent workload

`draft_mean_len` is **1.00** on all six Flash-Next tasks — exactly one accepted
token per draft, which is the `--spec-draft-n-max 2` setting in the `flashnext`
slot doing what the speed bench predicted. Acceptance is flat and host-agnostic:

| host | t1 | t2 | t3 |
|------|---:|---:|---:|
| frwk-bsd | 0.510 | 0.526 | 0.530 |
| frwk-linux | 0.543 | 0.525 | 0.531 |

0.51-0.54 on every task on both hosts. `qwen38-mtp` on the same hardware ranges
0.60-0.76, so acceptance is a property of the model and quant rather than of
the OS. (Acceptance is scraped from the endpoint's `/metrics` and does not
depend on the prompt harness, so that figure stays comparable even though the
run it came from is not.)

#### Still outstanding

`qwen38-mtp` (`Qwen3.8-27B-Q8_0-MTP`) has **not** completed a run under this
harness at the time of writing, so the comparison above is Opus vs Flash-Next
only. Its older rows are excluded for the reason given at the top of this
section.

One snippet still hit the raised 180 s budget (frwk-linux t2): a `grep -rl`
over `/root /home /usr/local /tmp`. That is an expensive search by choice, not
a too-strict limit — note `shell_s = 474 s` on that task, an order of magnitude
above every other row.

### Three ways this bench produced wrong answers before

Not results — **design constraints**, each one paid for with a run that
measured the harness instead of the model. They are why the current defaults
are what they are.

**1. Comparing across endpoints with different context sizes.** The first local
comparison ran `qwen38-mtp` at 131072 against `flashnext` at 32768, because
`llmsrv.sh` pinned a low `CTX` for the Flash-Next slot. This agent loop resends
its whole history each step, so context is a hard limiter, not a detail: the
32768 endpoint hit `exceed_context_size_error` at 37 856 tokens and the task
simply ended. Initially misfiled as `failure_class=harness`; it is now
`context_exhausted`, because a deployment limit is a finding about the
deployment, not a bug in the bench.

The `CTX=32768` was itself wrong — derived for UD-IQ4_XS (93.7 GB), where a
131072 KV genuinely overcommits, then carried to IQ3_XXS (82 GB) without being
re-derived. 131072 loads fine with MTP on (`n_ctx_slot = 131072`). Fixed in
`llmsrv.sh`. **Always read `n_ctx` off `/props` on both endpoints before
comparing them.**

**2. An arbitrary step cap silently converts "slow" into "failed".** With
`--max-steps 32`, every local-model run consumed exactly 32 steps and several
were scored as failures. The traces showed real waste — one run wrote no `.c`
file at all and spent its last three steps on `run_shell`, having already
stated it had the API details it needed — so I concluded the failure was
"behavioural, not capacity".

That was wrong. Re-run at `--max-steps 60`, the same model passed the same task
**one step past the old cap**. Both things were true, and the second mattered
more: it does waste steps on reconnaissance, *and* it was one step short. The
"local models score 0/3" framing was an artifact of the cap, not a measurement.

**3. Reading a single rep as a result.** See the reparse worked example above:
one run's host asymmetry reversed completely on the repeat. At `--reps 1` with
MTP on, any per-tier verdict is one sample.

Why a step cap exists at all: it bounds cost and stops runaway loops (Opus used
909 k input tokens on one task within 32 steps; unbounded that becomes
millions). But one global number conflates "looping" with "working steadily but
slowly", so the harness now has both:

* `--max-steps` (default 25) — the hard cost ceiling;
* `--no-progress-patience N` (default 8) — stop after N consecutive steps that
  create or modify **no source file**. Progress is defined narrowly and
  objectively: a `.c`/`.h`/`.mk`/`Makefile` appearing or changing in the
  workdir. Reading headers, grepping the tree and running `make` are all
  legitimate work but none is progress on its own, because the deliverable is
  source code.

A stop from the detector is recorded as `failure_class=no_progress` with the
reason in `stopped_early`, so it is distinguishable from genuine cap
exhaustion — which is exactly the distinction that was missing when the cap
alone produced a misleading verdict.

### Reproducibility: seeding works, but only under two conditions

`--seed N` (and `--temperature`) are wired through to the endpoint, because
`llmsrv.sh` sets **no seed** — llama-server then defaults to `-1`, a fresh
random seed per request, so two hosts running the identical model follow
different sampling paths. That is the most likely explanation for the early t1
divergence between the two hosts.

Measured on framework2, same seed (42), same host, `/v1/chat/completions`:

| configuration | identical outputs | verdict |
|---|---|---|
| MTP on (`--spec-type draft-mtp`), cold | 0 of 3 | not deterministic |
| MTP off, cold start | 2 of 3 | first request differs |
| **MTP off + one discarded warmup request** | **3 of 3** | **deterministic** |

So seeding genuinely works, but needs **both**:

1. **MTP off.** Speculative decoding accepts or rejects drafts based on batch
   composition that varies between runs, which changes token choices even with
   a fixed sampler seed. This is a real tradeoff, not a bug to fix:
   reproducibility *or* MTP's 2.2x speedup, not both.
2. **A warm cache.** The first request after model load diverges from
   subsequent ones; discard one response before measuring.

An earlier draft of this section claimed the seed was simply "not honoured",
based on the MTP-on result alone. That was wrong — the seed is honoured; MTP
and cold cache were masking it.

**Decision: keep MTP on and handle variance statistically.** This bench
measures speed and total token consumption alongside pass/fail, so an MTP-free
endpoint would be measuring a configuration nobody actually runs — the numbers
would be reproducible and useless. MTP stays enabled; reproducibility is the
lesser goal.

That has a hard consequence for how results may be read:

* **`--reps 1` cannot support a pass/fail claim.** With MTP on, the same model
  on the same host can pass or fail the same task. Use `--reps 3` or more and
  report the ratio (e.g. "2/3 passed"), never a single verdict.
* **A single differing verdict between hosts is variance, not an OS finding.**
  The early t1 split (ubuntu PASS / freebsd FAIL) is exactly this shape and
  should not be cited as a difference between the operating systems.
* **`--seed` is worth passing even with MTP on — measurably.** 4 seeded vs 4
  unseeded runs of the same prompt, MTP enabled, compared by pairwise text
  similarity rather than hash equality:

  | | mean similarity | min | identical pairs |
  |---|---:|---:|---:|
  | **seeded (42)** | **0.884** | 0.768 | **3 of 6** |
  | unseeded | 0.433 | 0.340 | 0 of 6 |

  A fixed seed roughly **doubles** run-to-run similarity and makes half the
  pairs bit-identical, even though MTP prevents full determinism. It removes
  the sampler-RNG source of variance and leaves only the MTP accept/reject
  source. Fewer reps are therefore needed for the same confidence — so always
  pass `--seed`.

  (An earlier read of this concluded the seed "buys nothing" under MTP, from a
  3-run test that only checked hash equality. That measure is binary and cannot
  distinguish "slightly different" from "completely different" — which is
  exactly the difference that matters here.)
* Timing and token counts are means over reps, so they tolerate this far better
  than pass/fail does; that is the part of the bench MTP is protecting.

Note also that a fixed seed could not guarantee bit-identical results *across*
the two hosts even with MTP off: Mesa 26.2.1 vs 26.0.8 and Clang 21 vs GCC 15
can differ in floating-point rounding, which can flip a token. Seeding removes
the dominant source of variance, not all of it.

### Thermals — checked, and one asymmetry you cannot check

Before attributing any `model_s` difference to the OS, rule out throttling.
Measured mid-run with both endpoints serving one request each and the GPU at
**97 % busy** (so these are loaded, comparable readings, not idle ones):

| | framework (FreeBSD) | framework2 (Ubuntu) |
|---|---:|---:|
| CPU | **68.6 °C** (`dev.amdtemp.0.core0.sensor0`) | **72 °C** (`k10temp`) |
| GPU | **not exposed** | **75 °C** (`amdgpu` edge) |

A ~3.4 °C CPU delta under equal load is small, and Strix Halo throttles around
95-100 °C, so thermal throttling is very unlikely to explain any timing
difference here.

**But FreeBSD exposes no GPU temperature at all.** `amdtemp0` gives CPU on-die
sensors; there is no `amdgpu` hwmon node under `sysctl`, so the sensor that
matters most for inference cannot be read on the host that runs it. That is a
gap in the FreeBSD drm-kmod port, not something this harness can work around —
so a cross-OS timing claim can never be fully thermally controlled on the
FreeBSD side. Treat GPU-thermal parity as an assumption, not a verified fact.

### Endpoint metrics per task

`/metrics` from llama-server is scraped before and after every task and the
**delta** recorded under `endpoint` (raw counters are cumulative across the
server's whole lifetime, so a bare reading conflates this task with everything
before it). Two uses:

* **health** — tell "the model is slow" apart from "the endpoint stalled or the
  draft head died"; a `draft_accept` of 0.0 with MTP configured means a dead
  head and the throughput for that task is void, not merely poor;
* **measurement** — MTP acceptance is a per-endpoint property and it differs
  measurably between hosts running the *same* model: observed mid-run,
  frwk-bsd **0.589** (33 560/56 984) vs frwk-linux **0.711** (42 670/60 028),
  both at `len 4.0`.

Endpoints without `/metrics` (an Anthropic or OpenAI proxy) simply yield `{}`,
so every key is optional.

The t1 divergence (ubuntu passed, freebsd did not) is **not** an OS finding:
frwk-bsd logged **0 dmesg GPU faults** and healthy MTP draft acceptance
(0.59-0.83), so the documented Mesa-26 CPC-write fault was not involved. With
`--reps 1` and sampling at temp 0.6, one differing verdict is run-to-run
variance. Both OSes then failed t2 the same way, which is the more informative
signal.

### Harness bugs this run found

All three were in the plumbing, none in scoring — and all three produced
*false failures*, which is the dangerous kind:

1. **Non-blocking read on a text-mode pipe** →
   `TypeError: can't concat NoneType to bytes`. Fixed by reading bytes and
   decoding explicitly. Earlier smoke tests used shell pipelines, so this path
   was never exercised.
2. That crash **leaked a running VM and a stray disk image**, because the
   exception bypassed teardown. `_drive()` is now wrapped so a console-loop
   failure cannot leak a VM.
3. **The prompt detector matched the kernel's own boot banner.** It searched
   for `root@`, and the banner contains
   `root@bigone:/usr/obj/usr/src/amd64.amd64/sys/GENERIC-NODEBUG`. Commands
   were typed before `/rescue/sh` existed and silently discarded, so only the
   tail of the script ran — reported as `FAIL (load)` with no `FBSDQ-MOUNTED`
   in the console. Now keyed on the `FBSDQ-GUEST-READY` handshake, which
   `/etc/rc` prints immediately before `exec /rescue/sh`.

Still not exercised: the panic path (no module has panicked yet, so `dump`/
`savecore`/`kgdb` are untested end-to-end) and tier 4.

### Harness bugs found by scanning ALL logs (what triggered the re-run)

The three above were found by watching runs. Grepping the **whole** log corpus
(13 runs, 75 k lines) found three more that no single run made obvious — and
one of them had been silently taxing every model, including the reference.

Census across the corpus at that point (13 runs, all pre-fix):

| class | count | runs | who |
|-------|------:|-----:|-----|
| sandbox denial (`import os`) | 13 | 8/13 | **every model, Opus included** |
| snippet timeout (30 s) | 11 | 6/13 | both hosts, both local models |
| reparse (`<code>` envelope) | 6 | 1/13 | Flash-Next (host asymmetry: noise) |
| context exhausted (HTTP 400) | 1 | 1/13 | Flash-Next at `CTX=32768` |
| real 5xx / 429 | **0** | — | endpoints were stable throughout |

1. **Sandbox denial — mine, and the costly one.** `CodeAgent` sandboxes imports
   and `bench.py` passed no `additional_authorized_imports`, so the allowlist
   was smolagents' default 11 stdlib modules. `import os` — the obvious way to
   list a directory — raised `InterpreterError` and burned a step. Models then
   fell back to `run_shell`, which works, so it changed no verdict but taxed
   every run.

   Deliberately **not** fixed by widening the sandbox: `bench.py` runs as root
   for bhyve, so in-process `os.*` would execute as root and bypass the
   `--agent-user` privilege separation that `run_shell` gets by dropping through
   `su`. That trades a real security property for a few steps. `ENV_NOTE` states
   the rule in the prompt instead.

2. **Snippet timeout.** smolagents' own
   `local_python_executor.MAX_EXECUTION_TIME_SECONDS = 30` bounds the *whole*
   `<code>` block, and is far tighter than this bench's `shell_timeout` (300 s,
   per subprocess) — so it always fires first and the bench's own limit never
   gets a chance. Raised to 180 s via `--snippet-timeout`, passed through
   `executor_kwargs` (a supported `LocalPythonExecutor` parameter, not a patch).

   Worth being precise, because the natural reading is wrong: **this budget
   does not cover inference.** It starts after the model's reply arrives.
   Measured steps of 87 s, 163 s and 80 s never tripped the 30 s limit, and
   `shell_s` is 0.0-6.3 % of run time (on one t3, 7.3 s of shell against
   9 059 s of inference). Raising it cannot compensate for a slow endpoint.
   What it does fix is a legitimate `grep -r` over `/usr/src/sys` (~90 k files)
   exceeding 30 s on a cold cache — losing a step for correct-but-slow work.

3. **`503` was a false positive I nearly reported as endpoint instability.**
   A bare-number grep for HTTP codes matched `503:` in *kernel source line
   numbers* the agent had printed. Checked before reporting: the whole corpus
   contains exactly one real API error (the `CTX=32768` 400). Endpoints never
   misbehaved.

All four counters (`parse_errors`, `timeout_errors`, `sandbox_errors`,
`step_errors`) are now written on the success **and** failure paths — a run that
dies mid-flight is exactly where the retry count matters most. `parse_errors` is
typed on `AgentParsingError` so a reworded message cannot silently stop the
count; the other two are message-matched because smolagents raises them as
generic execution errors with no class to type on.

Next: harder tiers (`khelp`/`hhook`, `epoch` read sections) are worth adding now
that 1-3 are known-passable — they were deferred only to avoid a bench that
floors out. And `qwen38-mtp` still needs a run under this harness.
