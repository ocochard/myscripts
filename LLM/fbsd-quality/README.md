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
| 6 | **fix a real kernel bug** (`vfs_lookup_cross_mount` / unionfs lock recursion) | opt-in, and different in kind: diagnosis from evidence rather than API discovery. A script panics a test machine; the model must reproduce it, localise it, patch `sys/`, rebuild and show the panic gone — while a hidden regression it never sees proves the fix generalises. |

Tiers 1-3 are **saturated** — every model tested passes all three (see Results),
so they no longer discriminate on pass/fail. Tiers 4-6 exist because of that.

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
actively misleading for tier 6, where each `buildkernel` is ~80 s and
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
| **`auto`** (default) | as `zfs-clone`, else `ro` | when on ZFS | when on ZFS |
| `zfs-clone` | **63 ms, ~0 bytes** (CoW) | yes | yes |
| `ro` | ~0 s, 0 bytes — nullfs bind | no (shared) | **no** |
| `shallow` | **45 s, 1.3 GB** — `git clone --depth 1` | yes | yes |
| `none` | 0 | no | yes |

**`auto` resolves to `zfs-clone` on ZFS and `ro` otherwise.** A CoW clone gives
every tier an independent *writable* tree for 63 ms and ~0 bytes, which removes
a class of harness bug: tier 6 needed two special cases (`write_file`'s workdir
check and the `_writes_into_src` tripwire) purely because the default tree was
read-only, and a model that cannot edit the tree cannot do that task at all.
It also stops any tier contaminating another.

`git clone` is deliberately **not** the uniform mechanism despite being the
obvious one: same properties, ~700x the time, 1.3 GB per run landing in
`wall_s`, it requires the tree to be a git repo, and the pinned tier-6 tree is
shallow with a single commit.

`ro` remains worth choosing explicitly: it is the only mode where mutation is
*impossible* rather than merely detected after the fact, which matters because
the bench runs as root for bhyve.

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
either trivially.

**`--agent-user` is NOT a security boundary on this host, and an earlier
version of this section wrongly said it was.** The agent user here
(`olivier`) has `NOPASSWD: ALL`, so the agent reaches root in one `sudo`. That
is not theoretical: models in earlier runs ran `sudo kldload` on the HOST and
it succeeded — one of them loaded a module built from the tree into the running
host kernel, which was refused only because the ABI happened to mismatch
(`KLD ...: depends on kernel - not available or version mismatch`). A matching
ABI would have loaded agent-written kernel code into `bigone`.

So the honest statement is: `--agent-user` demotes the agent's *default*
privilege, which stops careless writes, and nothing more. Real containment
would need a sudoers rule restricting that user to the commands the bench
actually needs (`bhyve`, `bhyvectl`, `mdconfig`, `kldload` of a guest image),
or running the bench under a user without blanket sudo. Until then, treat every
run as capable of touching the host, and do not run this on a machine you care
about.

The corollary for task design: a task may legitimately *require* privilege (an
agent that has to build its own guest image needs `mdconfig` and `mount`), so
the sudo access is load-bearing, not merely an oversight to be removed.

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

### Operational gotchas — each of these cost real time

**Verify a PASS against the guest console, not the verdict.**

```sh
grep -a '^FBSDQ:' artifacts/<run>/<task>-rep1/console.log
```

An unexpectedly *cheap* PASS on a hard tier is the shape a harness bug takes.
Three of the four defects listed under Results were found this way — by reading
output that a green verdict said was fine. Marker counts per console are not 1:
the guest script runs `dmesg` at the end, which replays every line the module
already printed, so a module that fired 3 times shows 6 matches in the raw
console. Count inside the live region, not over the whole file.

**Run the bench with `sudo`.** `/tmp/fbsd-quality` is root-owned; without it
every run dies instantly on `PermissionError` and a sweep "completes" in
seconds.

**Killing a run:** kill the sweep wrapper *first*, or it advances to the next
model. Then `sudo kill -9` the bench — plain `kill` does not land. Then clean
up: `zfs list | grep src-fbsdq` and destroy both the clone and its
`zroot/usr/src@fbsdq-<pid>` snapshot.

**Do not build a kernel module directly in `/tmp`.** A stale `/tmp/Makefile.inc`
(unrelated to this project) is auto-included by BSD `make` from the parent
directory and injects bhyve's `SRCS`, giving `make: don't know how to make
atkbdc.c`. The bench itself is unaffected — its workdirs are one level deeper —
but ad-hoc reference modules must be built under `/var/tmp`.

**Anchor any monitor/grep filter you use to watch a run.** The agent echoes its
own shell output into the log, so `grep -E "=== "` matches the agent's
`echo '=== ... ==='` and fires false events; `not found` matches the model's
prose as readily as a guest error. Use start-anchored patterns:

```sh
grep -E "^ *-> (PASS|FAIL)|^    behaviour\(|^=== (starting|finished)"
```

A pattern that also matches `tail` itself will kill the monitor.

**Watch for leaked object trees.** Old t6 runs left 16
`/usr/obj/usr/src-unionfs-fbsdq-<pid>` dirs, 23 GB, which made every tree-wide
search in the agent's shell traverse 16 stale copies — `shell_s` 232 s against
3-24 s once cleared. Check `ls -d /usr/obj/usr/src-*-fbsdq-*` before a sweep;
they are safe to remove when no matching PID is alive and nothing is mounted.

**Host load distorts two columns, not the verdicts.** `shell_s` and `wall_s`
cover the agent's shell calls, `make`, and the guest boot, all on the build
host; an unrelated buildworld inflates them. `model_s` is remote endpoint time
and stays clean. Record the load if a sweep ran alongside other work — and note
that a *badly* starved guest can trip `vmrunner`'s idle timeout and score
`timed_out`, which is a harness artefact, not a model failure. Re-run that rep.

**A second builder needs a matching tree.** ser6 was evaluated and rejected:
its `/usr/src` is `__FreeBSD_version` 1600012 against bigone's 1600022, so
modules would compile against different kernel internals and a failure could
not be attributed to the model. It would need a tree sync plus its own
`fbsdq.img`.

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

### Results — t1-t5, v27 (2026-09-10)

First valid t1-t5 sweep. Everything before it is void; see the superseded
section below for what was wrong and why.

Config, identical across all three: src `5b10c3c3e3d5`, `--src-mode auto`
(per-tier ZFS clone), `--agent-type code`, `--max-steps 100`, `--seed 42`.
Three reps for the local models, one for the reference. 35 runs, 18.2 h of
model time.

| model | quant | t1 | t2 | t3 | t4 | t5 | total | parse err | model time |
|---|---|---|---|---|---|---|---|---|---|
| claude-opus-4-5 | — | 1/1 | 1/1 | 1/1 | 1/1 | 1/1 | **5/5** | 0 / 120 | 0.1 h |
| Qwen3.8-Flash-Next | UD-IQ3_XXS | 3/3 ᵃ | 3/3 | 3/3 | 1/3 | 3/3 | **13/15** | 49 / 876 | 10.6 h |
| Qwen3.8-27B | Q8_0 | 1/3 | 2/3 | 1/3 | 1/3 | 0/3 | **5/15** | 1 / 642 | 7.5 h |

ᵃ **t1 is 5/6, not 3/3, over all clean-harness runs.** A later 3-rep re-run of
this exact tier (v29) scored 2/3: one rep hit the `DECLARE_MODULE` panic
described below, its third independent occurrence and first outside t4. The
3/3 is what v27 measured and is left as measured; the pooled figure is the one
to quote. Three reps resolve "never" from "sometimes" — they do not pin a rate.

Per-tier `model_s`, passing runs only, for the cost picture: Opus 88-129 s;
Flash-Next 620-5836 s; qwen38 748-2729 s. The reference is 20-40× faster on
tiers all three can pass.

**The 3-bit model beat the 8-bit one, 13/15 to 5/15.** It also cleared t5 —
the hardest tier, the only one whose observable is asynchronous — 3/3, where
qwen38 went 0/3. Its 49 parse errors (5.59 % of turns) are refunded steps, so
they cost wall time rather than verdicts. `--agent-type code` was later
measured to be the *best* available class for this model by 17× (v28), so
those 49 are not a harness misconfiguration to be recovered — see the
reverted-detector note.

**t4-hhook is the wall for both local models**, 1/3 each. The two rep1
failures are the same bug, independently:

```c
DECLARE_MODULE(fbsdq_hhook, fbsdq_modevent, SI_SUB_KLD, SI_ORDER_ANY);
                            ^^^^^^^^^^^^^^ the event function, where a
                                           moduledata_t belongs
```

Neither file declared a `moduledata_t` at all. `module_register()` then reads
`moduledata_t.name`, gets the first bytes of the function's machine code, and
`strcmp()` dereferences it — a general protection fault at `kldload`, with a
byte-identical backtrace in both runs (`strcmp` → `module_register` →
`linker_file_register_modules` → `kern_kldload`). Both builds were clean:
`DECLARE_MODULE` casts internally, so the type error is invisible to the
compiler and only ever surfaces as a kernel panic. Two independent models
making the same mistake on the same tier is the single most reproducible
finding in this sweep.

This is also the clearest justification for booting a guest rather than
trusting `make`: a compile-only check would have scored both of those runs as
successes.

**Failures are not uniform, and the classes matter more than the totals.**
qwen38: 9 `no_progress` + 1 panic. Flash-Next: 1 `no_progress` + 1 panic.
`no_progress` means the model explored the tree and never committed to writing
a file — qwen38's t5 runs made 157-261 `run_shell` calls and produced no `.c`
at all, three times. That is a different failure from writing code that is
wrong, and reporting it as "failed t5" flattens the distinction.

**Every PASS in this table was checked against the guest console, not the
verdict**, and the source was read for the tiers where faking is possible:
t3's passes use real `new_unrhdr`/`alloc_unr`/`free_unr` with the marker
printed from variables; t5's use `epoch_alloc(name, 0)` (non-preemptible, which
the tier requires), `in_epoch()` for the printed value, `epoch_call` with
`__containerof` recovery in the callback; Opus's t2 uses real
`osd_thread_register`/`set`/`get`/`deregister` with `pid` from
`td->td_proc->p_pid`. No hardcoded markers were found.

Caveats, stated rather than buried:

- **Opus ran one rep.** Its 5/5 with zero parse errors and no instability is
  consistent with low variance but does not measure it. The sweep script
  records this as an assumption. Any future Opus failure needs 3 reps before
  it means anything.
- **`shell_s` and `wall_s` are contaminated** for qwen38's t1-t3, which ran
  while the host was doing an unrelated buildworld at load ~73. `model_s` is
  remote endpoint time and is clean throughout. The affected runs never
  reached build or boot, so no verdict is in question.
- **`agent_type` was not recorded in `results.jsonl`** for v27 (the rows show
  `None`), which is exactly the wrong column to be missing given what v28 then
  measured. Fixed: every row now carries `agent_type`.
- **t3 remains gameable in principle** — a hardcoded printf would pass it. Its
  passes were verified by reading the source, not by the harness. See
  `TODO(t3-gameable)` in `tasks.py`.
- **`--seed` does not make these runs reproducible.** MTP speculative decoding
  is nondeterministic, and two runs of the *same* seed and tier (v27 vs v29,
  Flash-Next t1 rep2) differed by 79 vs 32 iterations, 2806 s vs 693 s, and 5
  vs 0 parse errors. So a seed-matched pair of single runs is not a controlled
  experiment here; only aggregate rates over several reps carry meaning. The
  seed is still passed because it costs nothing and removes one source of
  variance, not because it pins the outcome.
- **Flash-Next's t1 pooled rate is 5/6**, not the 3/3 this sweep measured —
  see note ᵃ on the table.

### Results (2026-09-06) — SUPERSEDED, do not cite

> **Every t1-t5 number below is void** (noted 2026-09-09). Three harness
> defects and one impossible task were found afterwards, each of which
> changed verdicts:
>
> 1. **`_writes_into_src` refused read-only commands** (fixed `25ea839`).
>    The guard treated "a write-ish token appears" and "the tree path
>    appears" as independent conditions, with bare `>` in the token list, so
>    `grep -ri foo /usr/src-.../sys/conf/files 2>/dev/null` was refused as a
>    write into the tree. Live for the whole history of the bench; refusals
>    in **44 archived runs** across every model and tier. Models could not
>    work around it because the stated reason was wrong, and it biased
>    against models that explore before writing.
> 2. **t2-osd was impossible** (fixed `9b8b41c`). It required an OSD slot on
>    a "process object type"; `sys/sys/osd.h` defines only `OSD_THREAD`,
>    `OSD_JAIL`, `OSD_KHELP`. All 15 t2 rows recorded before the fix are
>    void — the
>    tier scored *backwards*, passing a model that ignored the spec and
>    failing one that read the source and correctly refused to fake it.
> 3. **Markers were gameable** (fixed `206b173`). Verification was a single
>    `re.search` over the console, so every tier was satisfiable by a
>    `printf` of a literal. Demonstrated, not theorised: a module whose
>    entire body is `printf("FBSDQ:exit:pid=28")` builds, loads, and PASSES
>    t1 under the old check.
> 4. **t1's guaranteed process exit never ran** (fixed `4e7723b`). The
>    post-load command was `/usr/bin/true`, which does not exist in the
>    guest's `/rescue`-only userland, so the exit the tier depended on was
>    incidental for the tier's whole history.
>
> Additionally, ~23 GB of leaked `/usr/obj/usr/src-unionfs-fbsdq-*` object
> trees from old t6 runs were present during the `v22-`/`v23-` rows. They
> inflated agent shell time ~40× (`shell_s` 232 s vs 3-24 s once cleared) by
> making every tree-wide search traverse 16 stale copies.
>
> A replacement sweep (`v27-*`, three reps for the local models) is in
> progress. Until it completes, **t1-t5 results are unreported** rather than
> restated: the earlier numbers measured the harness, not the models.
>
> The t6 (bug-fix tier) sections further down are **not** affected by
> defects 2-4, which are t1-t5 specific.

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

### Tier 6 — bug-fix tier, reference calibration (2026-09-06)

`claude-opus-4-5` **PASSES**: 40 iters, 330 s model / 110 s shell, 13 046
tok_out, and `src_patched` records `M sys/kern/vfs_lookup.c`.

**It independently reproduced the reference patch** — same file, same function,
same fix (`LK_CANRECURSE` after the shared->exclusive upgrade in
`vfs_lookup_cross_mount()`) — from a panic message alone. The prompt is five
lines and names no subsystem, file or symptom; the reproducer is bare commands.

The trace shows the intended workflow, not a lucky guess: `test_kernel` twice
(reproduce -> PANICKED, verify after patching -> completed), 34 `grep_src` and
18 `read_file` calls in between, zero errors, no `run_shell` at all. It read
the panic, localised to `union_vnops.c:2257`, then followed the lock path up
into `vfs_lookup_cross_mount()` rather than patching where the panic fired.

Scored behaviourally: it had to satisfy the hidden `regress-t6.sh` (5 cases,
baked into the guest image, never visible to the agent), which the reference
patch also passes and the unpatched control fails by panicking with no verdict.

**Getting here took seven harness bugs, every one of which produced a wrong
verdict rather than an error.** Recorded because they are the failure modes
this kind of tier invites:

| bug | symptom | why it was wrong |
|---|---|---|
| reproducer carried the reporter's comments | model read panic, file:line and the tmpfs/UFS table in step 1 | everything stripped from the prompt was sitting in the file handed over |
| no-progress detector watched the workdir | interrupted at step 41 while correctly patching `sys/kern/` | a kernel tier's deliverable is a modified TREE |
| unbooted VM reported as "completed" | model told its reproducer ran fine; never saw the panic | empty console scored as success |
| `virtio-9p` attached unconditionally | bhyve refuses to start when the sharepath is missing, exits with zero console | root cause of the above |
| `write_file` + `_writes_into_src` blocked tree writes | model structurally unable to patch anything | both guards are right for tiers 1-5, wrong here |
| `tmpfs.ko` shipped though tmpfs is in GENERIC | `Module tmpfs failed to register: 17` on a console the model reads | alarming non-problem |
| DDB tunables added to tidy panic teardown | guest went silent after the handshake, never ran its script | my own regression; reverted, root cause unestablished |

Two of those were mine-fixing-mine, and one diagnosis (a send-timing race) was
simply wrong — the 1.5 s pause it produced is kept because it is correct on its
own terms, but labelled as not being the fix. The lesson worth carrying: on
this tier a harness fault and a failed fix look identical from the outside, so
every t6 verdict needs the console checked, not just the pass/fail.

#### Local models on tier 6 (2026-09-07)

| model | pass | iters | reparse | model_s | shell_s | src_patched | outcome |
|-------|------|------:|--------:|--------:|--------:|---|---|
| claude-opus-4-5 | **yes** | 40 | 0 | 330 | 110 | `M sys/kern/vfs_lookup.c` | fixed it |
| Qwen3.8-27B Q8 MTP | no | 42 | 0 | 5 390 | 92 | none | `no_progress` at step 41 |
| Flash-Next IQ3_XXS | no | 42 | **13** | 682 | 89 | none | `no_progress`; 13 of 42 steps lost to the `<code>` envelope |

**Neither local model wrote a single byte to the tree.** `write_file` was called
zero times by either, and the harness blocked nothing — no `escapes the working
directory`, no `refusing to run`, no errors. Both reproduced the panic once via
`test_kernel` and then investigated until the no-progress detector stopped them.
This is a capability result, not a harness artifact.

The interesting part is that qwen38 **got there and did not act**: 11 mentions
of `vfs_lookup_cross_mount` and 64 of `LK_CANRECURSE` in its trace — the right
function and the right flag — with no patch. Diagnosis without commitment is a
distinct failure from not knowing, and only the trace separates them.

The three work very differently, and only two of the three failures are about
capability.

Opus used 34 `grep_src` + 18 `read_file` and **no** `run_shell`. qwen38 used
**98 `run_shell`** (60 `grep`, 26 `sed`) and never touched the source-reading
tools at all — so its gap is not reading, it read plenty, but converting a
diagnosis into an edit.

**Flash-Next's failure is largely the harness's format, not its reasoning.**
13 of its 42 steps were `parse_errors` — the `<code>` envelope failure — against
only 11 successful `code_action`s. More than half its productive attempts were
discarded before running. It emits Qwen native tool-call syntax instead:

```
<tool_call>
<function=read_file>
<parameter=path>
</parameter>
```

which smolagents rejects with `AgentParsingError`. Its median `model_output` is
174 chars (max 352) against Opus's 306/2352, so it is also producing far less
per step. The counters make the distinction visible — `parse=13` for
Flash-Next, `parse=0` for both Opus and qwen38 — and an earlier version of this
section wrongly read its low activity as doing "least work", when it was
largely being *prevented* from working.

That is a real cost of running a Qwen-template model under `CodeAgent`, and it
inflates `iterations` while deflating everything the model achieves. A
`ToolCallingAgent` run would measure its kernel ability more honestly, at the
price of no longer being the same harness the other rows used.

So tier 6 discriminates sharply where tiers 1-3 saturated: reference passes,
both local models fail, and the traces say why.

Caveats: `--reps 1`, so a single sample per model; and the `no_progress`
threshold (40 steps without a source change) is what ended both runs, so a
model that would have patched at step 45 is scored the same as one that never
would. Both figures are the defaults, unchanged from the Opus run that passed
at 40 iterations.

#### Flash-Next under `ToolCallingAgent` — the harness was half the problem

Run as a separate row (`--agent-type toolcalling`), **not** a replacement: that
class issues one tool call per step by construction, so its iteration counts are
not comparable with the `CodeAgent` rows above.

| harness | successful actions | parse failures | success rate | patched? |
|---|---:|---:|---:|---|
| `CodeAgent` | 11 | 13 | 46 % | no |
| `ToolCallingAgent` | 25 | 17 | **60 %** | no |

Matching the harness to the model **more than doubled the work it completed**
(11 -> 25 successful actions) and it used the source-reading tools it never
touched under `CodeAgent`. So a real part of the earlier result was harness
mismatch, and the `CodeAgent` row understates this model.

But it still **failed the tier, and still never patched the tree** — same
`no_progress` stop at step 41 as before. The agent class was necessary, not
sufficient.

**The residual failure is context-sensitive**, which is the more useful finding.
Errors by step bucket:

| steps | 1-10 | 11-20 | 21-30 | 31-40 |
|---|---:|---:|---:|---:|
| parse failures | 2 | 5 | 6 | 4 |

A fixed per-call failure probability would stay flat. Rising with context —
80 % success at step 10, 72 % by step 18, 60 % overall — means the model
reaches for its trained format more often as the system prompt recedes.

**Not truncation, and not corrupted output.** Each failure is a COMPLETE,
well-formed reply in the wrong format — a canonical Qwen3-Coder tool call, 104
characters, opening and closing `<tool_call>` correctly. In all 13 CodeAgent
failures the opening `<code>` is missing and the closing `</code>` is present,
which is the opposite of what a truncated response looks like (a cut-off reply
loses its tail, not its head). The trailing `</code>` is not even the model's:
`agents.py:1654` passes it as a stop sequence and llama.cpp echoes the matched
stop string back. Probed directly, the endpoint returns `finish_reason: stop`
with complete JSON at 274 tokens, and still `stop` with ~10 k and ~25 k context
prefixes — no truncation at any size.

Leading suspicion is the quantisation: Flash-Next runs **UD-IQ3_XXS** (~3
bits/weight) against qwen38's **Q8_0** (~8). Across every run in this repo the
gap is stark — Flash-Next 28 parse failures in 583 iterations (4.8 %), qwen38 1
in 917 (0.1 %), Opus 0 in 351 — while both serve near-identical Qwen templates
containing the same `<function>`/`<parameter>` constructs, so the template does
not explain it.

This is a claim about **output format only**. Do not read it as a capability
ranking: on the t1-t5 sweep the IQ3_XXS model outscored the Q8_0 one more than
2:1 while parsing worse. See the v27 update below.

**That hypothesis is not testable on this hardware, and is recorded as
unproven.** The only heavier quant available, UD-IQ4_XS (93.7 GB), needs a
raised GTT aperture, takes ~18 min to load, has *worse* draft acceptance
(0.68 vs 0.76-0.80), and on Linux that aperture panicked the kernel. So "use a
heavier quant for agentic work" is a plausible reading, not a demonstrated one.

#### Root cause: the harness assumed a post-training style, and never checked

The parse failures were never a model defect. `CodeAgent` was hardcoded in this
bench's **first commit** — `git log -S ToolCallingAgent` shows that class never
appeared in `bench.py` until the day this was diagnosed — so it was not a choice
between two options. It was the class smolagents leads with, adopted without
asking which post-training the benchmarked models had.

The two classes make opposite assumptions:

| | tools described | suits models trained to |
|---|---|---|
| `CodeAgent` | in the prompt, as Python | write code |
| `ToolCallingAgent` | in the API `tools` array | emit structured tool calls |

Flash-Next is the second kind. Asked for Python it replied with a **canonical**
Qwen3-Coder tool call — the exact format
[SGLang's `qwen3_coder_detector`](https://github.com/sgl-project/sglang/blob/main/python/sglang/srt/function_call/qwen3_coder_detector.py)
parses, and the one llama.cpp auto-selects a parser for by sniffing
`<tool_call>` + `<function=` + `<parameter=` in the template
(`common/chat.cpp:3596`). That parser was already active on our endpoint. It had
nothing to attach to only because `CodeAgent` sends **no `tools` array**, so the
reply passed through as plain text and smolagents rejected it for lacking
`<code>`.

Two dead ends worth recording, both tested rather than assumed:

* **Retagging `code_block_tags` to Qwen's tags does not work.** It parses, then
  fails one layer down: the extracted payload is
  `<function=read_file><parameter=path>` — XML, not Python — so a `SyntaxError`
  replaces the parse error and nothing is gained.
* **`--tool-call-parser` is not a llama-server flag.** It is vLLM/SGLang;
  `llama-server --help` has zero matches. llama.cpp infers the format from the
  template, so the equivalent levers are `--chat-template-file`,
  `--chat-template-kwargs` and `--reasoning-preserve` — the last of which this
  build already enables by default.

**Why it hid for five tiers.** Flash-Next passed t1-t5 under `CodeAgent`,
because on short tasks it complied often enough. The mismatch only became
visible on t6, where 40+ steps of accumulating context let the trained habit
outweigh the system prompt. A defect that degrades with task length is far
harder to spot than one that fails outright — which is why it was first
misattributed to quantisation.

**The fix** is `--agent-type auto` (now the default): read the endpoint's
advertised chat template and select `toolcalling` when it carries those three
tokens, else `code`. Deliberately the same test llama.cpp uses — if llama.cpp
picks its Qwen3-Coder parser for a template, `CodeAgent` is wrong for that
model. It falls back to `code` whenever the template cannot be read (an
Anthropic proxy exposes no `/props`, and Opus handles `CodeAgent` fine), so it
can only help. Verified live: Flash-Next -> `toolcalling`, Opus -> `code`,
loading endpoint -> `code`, dead endpoint -> `code`.

> **REVERTED (v28, 2026-09-10). "It can only help" was false, by 17×.**
> The detector answered *"what dialect does this model speak?"* when the
> question that decides the outcome is *"which dialect does it get RIGHT more
> often?"* — and it only ever counted `parse_errors`, so it could not see the
> failure mode it was trading them for. Controlled comparison, Flash-Next
> IQ3_XXS on t1, 3 reps, same seed and endpoint, only the agent class changing:
>
> | agent class | parse_err | no_toolcall | bad turns | iters |
> |---|---|---|---|---|
> | `code` | 6 | 0 | **6/171 = 3.5 %** | 171 |
> | `toolcalling` | 0 | 194 | **194/331 = 58.6 %** | 331 |
>
> Parse errors did go to zero — and were replaced wholesale. Both configs
> still passed 3/3, so the cost is wall time and tokens, not verdicts, but
> 58.6 % of turns produced no usable action. The errors the model was shown
> say why:
>
> ```
> Error while parsing tool call from model output: The JSON blob you used is
> invalid ... Expecting ',' delimiter: line 1 column 202
> ```
>
> **What that error is NOT.** It is tempting to read it as "the model emits
> malformed JSON", and an earlier version of this section said so. The raw
> responses say otherwise. Across the three reps only **51 turns came back
> `finish_reason='tool_calls'` against 277 `finish_reason='stop'`**, and only
> 38 produced a JSON error at all:
>
> | rep | `tool_calls` | `stop` | `tool_calls=None` | JSON errors |
> |---|---|---|---|---|
> | 1 | 24 | 98 | 185 | 21 |
> | 2 | 19 | 122 | 218 | 12 |
> | 3 | 8 | 57 | 68 | 5 |
>
> So llama.cpp's own template parser — the same one that turns native
> `<tool_call>` syntax into structured `tool_calls` server-side, and which
> works on a short probe — **failed to recognise the model's output in about
> 80 % of turns**, returning it as plain text with `tool_calls=None`.
> smolagents then tried to JSON-parse the prose left in `content`, which is
> where `Expecting ',' delimiter` comes from. The JSON error is a downstream
> symptom, not the fault.
>
> Why the server's parser fails is not established here. The probe that works
> carries a one-line shell command; the failing turns carry multi-line C
> source. A plausible reading is that the payload complexity breaks the
> template parser's expectations, but that is a hypothesis, not a measurement.
>
> What IS established: `ToolCallingAgent` loses ~59 % of turns for this model
> and `CodeAgent` loses ~3.5 %, and the trace shows the model burning turns
> trying to reverse-engineer the parser — *"maybe the parser requires the
> message to contain BOTH…"*, *"my message must not have any trailing text
> after…"* — the same shape as the old `_writes_into_src` bug: a rejection
> whose stated reason does not tell the model what to change.
>
> **The evidence was already in this file.** The `v13` row two sections down
> records 16 `no_toolcall` and a 62 % failure rate under auto-selected
> `toolcalling`. It was read as a property of t6's harder prompt rather than
> as the agent class costing more than it saved.
>
> `detect_agent_type` now returns `code` unconditionally and its template
> probe is removed (recoverable from `c645693`). If a model is later found
> that genuinely does better under `ToolCallingAgent`, prove it the way v28
> did — same tier, several reps, both classes, counting `parse_errors` **and**
> `no_toolcall` — and put the evidence in the docstring. Counting one of two
> failure modes is what produced this bug.
>
> **The real fix (v29): translate, don't refund.** The mismatch that made
> agent-class switching look necessary is now handled directly.
> `_translate_tool_call()` converts a native emission into the `<code>` block
> it meant, so the turn executes instead of being thrown away:
>
> ```
> <tool_call><function=python_interpreter><parameter=code>
> print(run_shell("make 2>&1 | tail -6"))          ->   <code>
> </parameter></function></tool_call></code>              print(run_shell(...))
>                                                      </code>
> ```
>
> Verified by replaying all 43 `<tool_call>` emissions captured from the v27
> traces through the installed wrapper: 41 recovered, 39 valid Python
> (`ast.parse`), 0 invalid, and the non-recovered ones are prose *about* tool
> calls plus one empty `<function=print>` — which should fail, since a turn
> with no action really is a failed turn.
>
> **Not yet observed working in production.** Across 3 live reps (v29) the
> model emitted zero native tool calls, so the translator never fired. That is
> expected — the 43 captures come from ~1 800 turns of the v27 sweep — but it
> means the evidence is replay-based, not live.
>
> Widening `code_block_tags` to accept `<tool_call>` is the obvious
> alternative and does not work: the payload inside is
> `<function=>`/`<parameter=>` XML, so it parses and then fails at execution.
> Tested before v29 and noted in the `ToolCallingAgent` branch.
>
> Grammar-constrained decoding was considered as the root-cause fix and
> rejected. It is available on this build (`response_format` `json_schema`
> returns conforming JSON first try), but a JSON-Schema grammar makes every
> token sequence outside the grammar unreachable, XML tool-call tags included
> — [Constraint Tax in Open-Weight LLMs](https://arxiv.org/pdf/2606.25605)
> documents this exact tension for agent systems — so it would suppress the
> format this model is best at rather than repair it. Grammar sampling in
> `json_schema` mode is also
> [reported to hang past ~10 k prompt tokens](https://arxiv.org/pdf/2604.18566)
> where these runs sit at 25-30 k, and per-token overhead applied to one model
> and not the reference would distort `model_s`, the column the bench compares
> on. A GBNF grammar matching the native syntax would be the principled
> version; it needs `llmsrv.sh` work plus a decode re-benchmark.

The `parse_errors` / `no_toolcall` split exists so this is visible on run
one for the next model, instead of after a trace dive. v28 is the case for
why both counters matter: either one alone points the wrong way.

#### The quantisation hypothesis is unproven, and untestable here

Flash-Next shows 28 parse failures in 583 iterations (4.8 %) against qwen38's 1
in 917 (0.1 %) and Opus's 0 in 351, while both Qwen models serve near-identical
templates carrying the same `<function>`/`<parameter>` constructs — so the
template does not explain the gap and quantisation (IQ3_XXS ~3 bit vs Q8_0 ~8
bit) was the obvious suspect.

It cannot be tested on this hardware. `QUANT=UD-IQ4_XS` wedges at
`common_speculative_init_result: loading draft model .../mtp-...-shared-Q8_0.gguf`
and spins at 99 % CPU in state `R` with no further output — killed at **41
minutes** against the ~18 min a successful load is documented to take, and CPU
time advanced 1:1 with wall clock throughout, so it is compute-bound rather than
deadlocked. Not an aperture shortfall: 87.2 GB model + 2.6 GB head = 89.8 GB
against a 117.2 GB GTT aperture. This confirms the warning already in the
`flashnext` slot's help text — *"IQ4_XS cannot load the draft head at all"*.

For contrast, IQ3_XXS reloads in **~43 seconds**.

The question is also moot in practice: with the agent class detected correctly,
the model is no longer asked for a format it was not trained to emit.

**Update (v27, 2026-09-10) — the parse-rate gap is real and persistent, and it
does not predict capability.** The t1-t5 sweep, three reps per tier, both local
models on the fixed harness:

| model | quant | parse errors | iters | rate | tiers passed |
|---|---|---|---|---|---|
| Qwen3.8-27B | Q8_0 (~8 bit) | 1 | 642 | 0.16 % | **5/15** |
| Flash-Next | UD-IQ3_XXS (~3 bit) | 49 | 876 | 5.59 % | **13/15** |

Two things follow, and they point in opposite directions:

1. **The parse gap is NOT quantisation damage — it is a format tug-of-war, and
   the harness caused it.** Inspecting the failures (rather than inferring from
   the rate, which is how this was first written up) every one of the 17 errors
   in `t5-epoch-rep1` is the same message — "the regex pattern `(.*?)</code>`
   was not found" — and the output that triggered it is not corrupt at all:

   ```
   <tool_call>
   <function=run_shell>
   <parameter=command>
   sed -n '420,520p' /usr/src/sys/conf/kmod.mk
   </parameter>
   </function>
   </tool_call></code>
   ```

   Well-formed native tool-call syntax, valid tool name, sensible argument,
   coherent reasoning behind it. It fails only because this sweep ran
   `--agent-type code`, which requires a `<code>`…`</code>` Python block. Note
   the trailing `</code>`: the model is trying to satisfy both formats at once,
   and the next step's reasoning says *"Let me continue with proper format"* —
   it knows. `no_toolcall` is 0 because it always emits a tool call, just in
   the wrong wrapper.

   This explains both things that did not fit the quantisation story: the
   errors are **lumpy** (17, 16, then 1-5 per run) where per-token
   quantisation noise would be roughly uniform, and the rate **rose** after
   agent-class detection was fixed, because `code` is the format this model is
   least inclined to emit. `detect_agent_type` exists to prevent exactly this,
   and it gets this model right — recorded further up this file as *"Verified
   live: Flash-Next -> `toolcalling`"*. v27 overrode that with a hardcoded
   `--agent-type code`, justified by qwen38's pe=0: a per-sweep decision
   applied to what is a per-model property. The detector was correct and the
   sweep ignored it.

   Quantisation is therefore **not** supported as the cause of the v27 gap. The
   earlier 4.8 % figure was measured under a different harness and is not
   re-examined here; the IQ4_XS control remains unloadable on this hardware, so
   nothing here proves quantisation is harmless either — it is simply not the
   explanation for these errors.

   > **Corrected again (v28). The paragraph above overreached, and
   > quantisation is back.** Reading one trace showed well-formed
   > `<tool_call>` output under `code` mode and I generalised from it to "the
   > harness caused the whole gap", without checking what the *other* mode's
   > failures looked like. They look completely different: under
   > `toolcalling` this model emits **malformed JSON** — `Expecting ','
   > delimiter` at varying offsets — 194 times in 331 turns (58.6 %), against
   > 6 in 171 (3.5 %) under `code`. See the reverted-detector note above for
   > the full table.
   >
   > So the honest summary is: `code` mode is the *better* configuration for
   > this model by 17×, not the wrong one, and the v27 sweep's hardcoded
   > `--agent-type code` was right for a reason the sweep did not know.
   >
   > On quantisation itself this leaves **less** than the paragraph above
   > claimed. I attributed the `toolcalling` failures to the model botching
   > character-exact JSON escaping — the thing low-bit quantisation would
   > plausibly damage — and that turned out to be wrong: ~80 % of those turns
   > were llama.cpp's parser not recognising the output, with the JSON error
   > arising downstream in smolagents. So that 58.6 % is not evidence about
   > the model's string accuracy, and cannot be used to support a
   > quantisation hypothesis.
   >
   > Standing position: the residual ~3.5-5.6 % under `code` is now explained
   > mechanically and without reference to quantisation — the model emits
   > native `<tool_call>` syntax, which v29 handles by translating instead of
   > refunding. Quantisation is neither supported nor excluded as a cause of
   > anything measured here. The IQ4_XS control still will not load, so it
   > stays untestable on this hardware.
   >
   > What generalises past this bench: I inspected 17 errors from one run of
   > nine and treated them as representative of the model's format behaviour.
   > They were representative of one mode only.
2. **The low-bit model is not weaker at the task.** The
   3-bit model outscored the 8-bit one more than 2:1, and cleared t5 — the
   hardest tier, whose observable is asynchronous — which the 8-bit model
   failed 0/3. Its per-tier record was 3/3 on t1, t2 and t3.

So "moot in practice" was the wrong conclusion to draw, in a way worth naming:
format compliance and kernel-API competence are separate axes here, and this
bench measures the second. Flash-Next pays a steady tax in retried steps (the
harness refunds them, so they cost wall time rather than verdicts) and still
wins on verdicts. A reader who used the parse rate as a proxy for capability
would have ranked these two models backwards.

Flash-Next's 13/15 stands as scored, with a 3.5 % turn-level tax under `code`.
The follow-up that was pending here has run (v28): `--agent-type toolcalling`
made things **17× worse**, not better, so the sweep's hardcoded `code` was the
right configuration and the "floor, not ceiling" framing was wrong — there is
no cheap format change that recovers those steps. See the reverted-detector
note above.

The 5/15-vs-13/15 comparison is a fair one — same harness, same tasks, same
three reps, same `--agent-type code`, both sweeps complete — but neither
model's failures are uniform: qwen38's are 9 `no_progress` and 1 panic (it
explores and never commits to writing a file), while Flash-Next's two are one
guest panic and one `no_progress`, both on t4.

#### Auto-detection works; the model still fails, for a different reason

`v13`, Flash-Next IQ3_XXS on t6 with `--agent-type auto`. The harness selected
the class by itself — the run log opens with

```
agent-type=auto -> toolcalling (from the endpoint's chat template)
```

so the root-cause fix operates without the operator knowing anything about
Qwen tool-call formats.

| run | agent class | successful calls | failures | rate | patched? |
|---|---|---:|---:|---:|---|
| v10 | `code` (hardcoded) | 11 | 13 `parse_errors` | 46 % | no |
| v11 | `toolcalling` (manual) | 25 | 17 | 60 % | no |
| v13 | `toolcalling` (**auto**) | 26 | 16 `no_toolcall` | 62 % | no |

The formatting failure is **gone**: `parse_errors=0` in v13, against 13 in v10.
The model no longer emits `<tool_call>` XML where Python was wanted, because it
is no longer asked for Python.

What remains is a different failure, and the counter rename records it:
`no_toolcall` fires when the reply carries **no structured tool call at all**
and the text fallback finds no JSON either. `agents.py` only reaches that
fallback when `chat_message.tool_calls` is already empty, so these are turns
where the model produced content and never called anything. The machinery is
demonstrably fine — probed directly with a real `tools` array the same endpoint
returns `finish_reason: tool_calls` with a clean structured call and empty
content.

So Flash-Next's t6 failure is now the same shape as qwen38's: it investigates,
it does not commit. Neither model ever wrote a byte to the tree.

**An instrumentation gap this exposed.** What those 16 turns actually contained
could not be recovered: smolagents leaves `ActionStep.model_output` unset on a
rejected step, and `_dump_trace` only saved that field, so the rejected reply
was captured nowhere. It now also saves `model_output_message`, which survives
rejection — the evidence needed to distinguish "reasoned instead of acting"
from "emitted the wrong shape" will exist on the next run rather than having to
be inferred.

Note `v13`'s row records `no_toolcall=None` because the run started before the
rename landed; the 16 are in `step_errors`, and the figures above come from the
log.

#### Why some models produce `no_toolcall` turns and others never do

The difference is **turn structure**, not capability. Worth knowing before
reading a high `no_toolcall` count as a weak model.

`claude-opus-4-5` reasons on 38 of its 40 t6 steps, and every one of those
messages carries the reasoning *and* the action together:

```
Thought: The panic occurs in unionfs_lock at line 2257 ... Let me look at
         the unionfs source.
<code>
result = grep_src("unionfs_lock", "sys/fs/unionfs")
</code>
```

Its `reasoning_content` is empty on every step — the Anthropic proxy has no
separate thinking field — so everything lands in `content`, where smolagents
reads it. Reasoning and action are inseparable.

A Qwen-family thinking model instead emits a `<think>` block that llama.cpp
routes into `reasoning_content`, and treats it as a **separate turn phase**. On
many turns it ends after the thinking, having stated an intention without
carrying it out. All 22 captured failures ended on exactly that shape — *"Let
me call test_kernel first."* — every one with `finish_reason='stop'`, so
nothing was truncated and no budget was exhausted. It handed back to the caller
the way a chat assistant would.

Two things that follow:

* **Promoting `reasoning_content` into `content` does not fix it.**
  `parse_tool_calls()` wants a JSON blob and reasoning is prose, so the same
  error is raised one layer later. Tried; the failure rate did not move.
* **The rate scales with how much the model must decide**, not with context or
  task length. Across Flash-Next runs: 0 % on t1/t2 (the prompt names the
  facility and the exact marker), 3-6 % on t3/t4/t5, and 31 % on t6 — whose
  prompt is the *shortest* of the six precisely because it withholds the
  subsystem, the file and the symptom.

Upstream smolagents already recovers from these (it records the error and
iterates; 11 of 23 were followed immediately by a successful call), so they cost
wall time and tokens. The step refund stops them also costing budget and
patience.

#### Flash-Next PASSES tier 6 once the harness stops charging it for turn structure

`v18`, with all four harness defects fixed:

| | Opus | Flash-Next (v18) |
|---|---:|---:|
| result | **PASS** | **PASS** |
| productive steps | 40 | 96 |
| no-action turns | 0 | 58 (all refunded) |
| model_s | 330 | 4 310 |
| tokens_out | 13 046 | 61 265 |
| patch | `M sys/kern/vfs_lookup.c` | `M sys/kern/vfs_lookup.c` |

It **independently reproduced the reference patch** — `crosslkflags |=
LK_CANRECURSE` in `vfs_lookup_cross_mount()`, the same statement in the same
file — and satisfied the hidden regression it never sees.

**Every previous t6 failure for this model was a harness artifact.** Four
separate defects, each of which alone produced a confident wrong verdict:

| defect | what it did |
|---|---|
| `CodeAgent` hardcoded | asked a tool-call-trained model for Python in `<code>` tags |
| steps charged for no-action turns | 58 refunded here; without it the model dies at ~40 |
| detector counted them as stalls | v17 got its budget back and was killed by the patience check anyway |
| prompt implied a planted bug | model hunted a non-existent injected diff (15 mentions, now 1) |

The cost gap is the real result, and it is large: **13× the wall time, 4.7× the
tokens, 2.4× the steps** for the same fix. But "cannot do it" and "needs 13×
longer" are different findings, and the bench reported the first for four runs
because of the harness rather than the model.

Caveat: `--reps 1`. One sample, and with MTP on the same run can go either way.

#### Qwen3.8-27B also PASSES t6 — and needs the fewest steps of the two locals

`v20`, `--agent-type code` (its original class, deliberately not `auto` — see
the detector's known limitation: it complies with `CodeAgent` 99.35 % of the
time, so switching it would confound the comparison).

| | Opus | Qwen3.8-27B Q8 | Flash-Next IQ3_XXS |
|---|---:|---:|---:|
| result | PASS | **PASS** | PASS |
| steps | 40 | **36** | 96 |
| model_s | 330 | 3 224 | 4 310 |
| tokens_out | 13 046 | 51 253 | 61 265 |
| parse failures | 0 | **0** | 58 (refunded) |
| patch | `vfs_lookup.c` | `vfs_lookup.c` | `vfs_lookup.c` |

All three produced `crosslkflags |= LK_CANRECURSE` in
`vfs_lookup_cross_mount()` — the reference patch, independently.

qwen38 took **fewer steps than the reference model** (36 vs 40) at ~10x the
wall time. Its earlier t6 failure was, like Flash-Next's, an artifact: it had
reached `LK_CANRECURSE` in its trace and simply run out of budget under the
60-step cap and the pre-refund accounting.

**So tier 6 no longer discriminates on pass/fail either — 3/3.** What it now
measures is cost: 10-13x the wall time and 4-4.7x the tokens for the same fix.
That is a real and useful result, but the ladder needs a harder rung again if
pass/fail is wanted.

#### Control: Opus re-run on the fixed harness (no regression)

Every t6 result above was produced on a harness that was being changed between
runs. Opus is the one model that passed under the ORIGINAL harness, so
re-running it checks whether the four fixes broke anything for a model that
already worked.

| | v8 (original harness) | v21 (current) |
|---|---:|---:|
| result | PASS | **PASS** |
| steps | 40 | **32** |
| model_s | 330 | 261 |
| tokens_out | 13 046 | 9 740 |
| patch | `vfs_lookup.c` | `vfs_lookup.c` |

No regression, and it needed 8 fewer steps and 25 % fewer tokens. Since Opus
had 0 parse failures and 0 refunds in both runs, the accounting fixes cannot
explain the improvement — the only change that reaches it is the prompt now
stating the bug is genuine upstream rather than planted.

That is the same change that most plausibly explains qwen38's flip from FAIL to
PASS, which makes two independent models improving on the one fix. Still not
proof — `--reps 1` and MTP sampling mean single runs move on their own — but it
is the strongest signal available without a dedicated A/B.

Final tier-6 standing. 3/3 pass, all three producing
`crosslkflags |= LK_CANRECURSE` in `vfs_lookup_cross_mount()`.

| model | agent class | tokens_out | model_s | steps |
|---|---|---:|---:|---:|
| claude-opus-4-5 | `code` | 9 740 | 261 | 32 |
| Qwen3.8-27B Q8 MTP | `code` | 51 253 | 3 224 | 36 |
| Flash-Next IQ3_XXS | `toolcalling` | 61 265 | 4 310 | 96 |

**Compare on tokens and wall time, not on steps.** The agent classes differ,
and a "step" is not the same unit in each: a `ToolCallingAgent` step is exactly
one tool call by construction, while a `CodeAgent` step is one Python block
that may invoke several tools. Flash-Next's 96 and qwen38's 36 therefore count
different things. Tokens and seconds are unit-independent, and on those the
ordering is stable: **12x and 17x the wall time, 5x and 6x the tokens** for the
same fix.

Re-running Flash-Next under `code` would NOT make this comparable — it would
just re-measure the harness mismatch, which is already known: 46 % action rate,
13 parse failures, no patch. Asking a tool-call-trained model for Python in
`<code>` tags is the unfair run, not the fair one. The class asymmetry is
inherent to comparing these models honestly, not an artifact to be removed.
