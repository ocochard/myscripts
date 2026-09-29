# fbsd-quality — operating the bench

How to run it and what will bite you. For what it found, see `README.md`.

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
- a source tree, and a kernel built from it (see the version trap below)
- `/usr/local/share/uefi-firmware/BHYVE_UEFI.fd` (`pkg install uefi-edk2-bhyve`)

**To run the bench** (`bench.py`):

- `vmm` loaded, `bhyve`/`bhyvectl`, root for VM creation
- ZFS (optional but recommended: per-VM disk clones, cheap rollback)
- `pip install smolagents` — the agent framework that drives the model under
  test. Only `bench.py` needs it; the image builder does not.
- an OpenAI-compatible endpoint. Normally a local `llama-server` from
  `../llmsrv.sh`, e.g. `--api-base http://127.0.0.1:8080/v1`.

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
`/etc/rc` prints `FBSDQ-GUEST-READY <version>` as the handshake. Image is 29 MB
used in a 512 MB sparse file, boots in ~40 s.

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

## Running against an Anthropic proxy

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

**`--agent-user` is NOT a security boundary on this host.** The agent user here
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

## What gets logged

Everything, in four layers — the summary table alone is useless for reviewing a
failure weeks later:

| where | what |
|---|---|
| `logs/bench-<stamp>.log` | full stdout+stderr, plus host version, python and smolagents versions, and the exact argv (`run.sh` tees it) |
| `results.jsonl` | one JSON row per (model, task, rep): `passed`, `failure_class`, `iterations`, `wall_s`/`shell_s`/`model_s`, tokens, `src_rev`, `run_id`, `backend`, `agent_type` |
| `artifacts/<run_id>/<task>-rep<n>/` | **the C and Makefile the model wrote**, `build.log`, `console.log` (guest serial output), `trace.txt` |
| `trace.txt` | the agent's step-by-step reasoning — which header it read, what it concluded, where it went wrong |

`trace.txt` is the one to open first when a model fails: it shows whether it
looked in the right header, misread a signature, or never searched at all.
Disable archiving with `--artifacts none` if disk is tight.

### Failure counters

Two counters, not one. Counting either alone points the wrong way — that is
what produced the reverted agent-type detector:

| counter | fires when |
|---|---|
| `parse_errors` | the reply was not wrapped in `<code>…</code>`, so smolagents raised `AgentParsingError` before running anything |
| `no_toolcall` | the reply carried no structured tool call at all, and the text fallback found no JSON either — the model reasoned and never acted |

Both are refunded steps: they cost wall time and tokens, not budget or
verdicts.

### Agent class is `code`, unconditionally

A template-sniffing detector that selected `toolcalling` for Qwen-family models
was measured and **reverted**: on Flash-Next t1, 3 reps, same seed and
endpoint, `code` lost 6 of 171 turns (3.5 %) while `toolcalling` lost 194 of
331 (58.6 %) — llama.cpp's own template parser failed to recognise the model's
output in ~80 % of turns, returning it as plain text, and smolagents then
JSON-parsed the prose. If a model is later found that genuinely does better
under `ToolCallingAgent`, prove it the same way — same tier, several reps, both
classes, counting **both** counters.

Instead of switching classes, `_translate_tool_call()` converts a native Qwen
emission into the `<code>` block it meant, so the turn executes:

```
<tool_call><function=python_interpreter><parameter=code>
print(run_shell("make 2>&1 | tail -6"))          ->   <code>
</parameter></function></tool_call></code>              print(run_shell(...))
                                                     </code>
```

Verified by replay: 41 of 43 captured emissions recovered, 39 valid Python
(`ast.parse`), 0 invalid. Replay-based, not yet observed firing live.

Two alternatives tested and rejected: widening `code_block_tags` to accept
`<tool_call>` parses and then fails at execution (the payload is
`<function=>`/`<parameter=>` XML, not Python); grammar-constrained decoding
makes every sequence outside the grammar unreachable, XML tool-call tags
included, and would suppress the format the model is best at rather than repair
it.

## Operational gotchas — each of these cost real time

**Verify a PASS against the guest console, not the verdict.**

```sh
grep -a '^FBSDQ:' artifacts/<run>/<task>-rep1/console.log
```

An unexpectedly *cheap* PASS on a hard tier is the shape a harness bug takes.
Most defects ever found in this harness were found this way — by reading output
that a green verdict said was fine. Marker counts per console are not 1: the
guest script runs `dmesg` at the end, which replays every line the module
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

**`--seed` does not make these runs reproducible.** MTP speculative decoding is
nondeterministic: two runs of the same seed and tier differed by 79 vs 32
iterations, 2806 s vs 693 s, and 5 vs 0 parse errors. Only aggregate rates over
several reps carry meaning. The seed is still passed because it costs nothing
and removes one source of variance, not because it pins the outcome.

**A second builder needs a matching tree.** ser6 was evaluated and rejected:
its `/usr/src` is `__FreeBSD_version` 1600012 against bigone's 1600022, so
modules would compile against different kernel internals and a failure could
not be attributed to the model. It would need a tree sync plus its own
`fbsdq.img`.

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
faulting function anyway. The dump earns its cost on the harder tiers
(`epoch`, `hhook`), where failures are lock-order reversals and use-after-free
that a backtrace alone will not explain.

## Known limitations

- **t2's marker cannot tell `OSD_THREAD` from `OSD_PROCESS`.** A model that
  passes with `osd_thread_register()`/`osd_thread_set()` where the prompt asks
  for the process type is scored as a pass. The API use is genuine and the
  round-trip real, so it is legitimate, but tighten the marker if the
  distinction matters. Recorded in `tasks.py`.
- **t6 is `--reps 1` for every model.** One sample each, and MTP sampling moves
  single runs on its own.
- **Opus ran one rep per tier.** Its 6/6 is consistent with low variance but
  does not measure it. Any future Opus failure needs 3 reps before it means
  anything.
- **The `no_progress` threshold (40 steps without a source change) ends runs.**
  A model that would have patched at step 45 scores the same as one that never
  would.
- **The IQ4_XS control will not load on this hardware**, so "does a heavier
  quant parse better" stays untestable here. `QUANT=UD-IQ4_XS` wedges at
  `common_speculative_init_result` loading the draft head and spins at 99 % CPU
  — killed at 41 minutes against the ~18 min a successful load takes. Not an
  aperture shortfall: 87.2 GB model + 2.6 GB head against a 117.2 GB GTT
  aperture. IQ3_XXS reloads in ~43 s.
