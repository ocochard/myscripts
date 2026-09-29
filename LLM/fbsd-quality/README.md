# fbsd-quality — can a local model write a FreeBSD kernel module?

An **objectively scored** agent benchmark: the model is asked to write a
loadable FreeBSD kernel module against the real `/usr/src`, and the module
either produces the expected observable behaviour in a throwaway bhyve VM or it
does not. No judge model, no rubric — unlike
`../benches.DaemonDocs-model-quality.md`, which counts violations found by a
fact-checker.

To run it, see [OPERATING.md](OPERATING.md).

## Results

One table, all models, best first. Rank is on tiers cleared, then pass rate,
then cost.

| # | model | quant | t1 | t2 | t3 | t4 | t5 | t6 | pass rate | median model_s | notes |
|--:|---|---|---|---|---|---|---|---|---|---:|---|
| 1 | claude-opus-4-5 | — | 1/1 | 1/1 | 1/1 | 1/1 | 1/1 | PASS | **6/6** | 99 | reference; 1 rep per tier |
| 2 | Qwen3.8-Flash-Next | UD-IQ3_XXS | 3/3 | 3/3 | 3/3 | 1/3 | 3/3 | PASS | **14/16** | 1 740 | best local; 17× Opus wall time |
| 3 | Qwen3.8-27B | Q8_0 MTP | 4/10 | 3/7 | 2/5 | 1/3 | 0/3 | PASS | **10/28** | 1 646 | fewest t6 steps of the locals (36) |
| 4 | Swift-Qwen3.8-27B-Uncensored | Q8_0 | 0/3 | 0/3 | 0/3 | — | — | — | **0/9** | — | abliterated; ignores the spec |
| 5 | Qwen3-Coder-Next 80B-A3B | UD-Q4_K_XL | 0/3 | 0/3 | 0/3 | — | — | — | **0/9** | — | fastest (0.7 h/sweep) and still zero |

Tier 6 is `--reps 1` for every model, so it is reported PASS/— rather than as a
rate.

**Reading.** Only the reference clears the ladder cheaply. Flash-Next is the
local pick: a 3-bit quant outscores the 8-bit dense model more than 2:1, and
clears t5 — the only asynchronous observable — which the 8-bit model never did.
Parse-error rate does not predict capability: Flash-Next pays a 3.5-5.6 %
turn-level format tax and still wins on verdicts, so a reader using it as a
proxy would rank these two backwards.

Both zero-scoring models fail on *autonomous tool use*, not kernel C. Their
modules compile and load; the marker never appears. Coder-Next additionally
stalls without writing a file at all in a third of runs. Neither is usable for
agent work.

Compare models on **`model_s`** and `tokens_out`, never on steps: a
`ToolCallingAgent` step is one tool call, a `CodeAgent` step is one Python block
that may invoke several tools.

### Tier 6 cost, the three that passed

All three independently produced the reference patch —
`crosslkflags |= LK_CANRECURSE` in `vfs_lookup_cross_mount()` — from a panic
message alone, and satisfied a hidden regression suite they never see.

| model | agent class | tokens_out | model_s | steps |
|---|---|---:|---:|---:|
| claude-opus-4-5 | `code` | 9 740 | 261 | 32 |
| Qwen3.8-27B Q8 MTP | `code` | 51 253 | 3 224 | 36 |
| Flash-Next IQ3_XXS | `toolcalling` | 61 265 | 4 310 | 96 |

12× and 17× the wall time, 5× and 6× the tokens, for the same fix.

Raw rows are in `results.jsonl`; per-run sources, guest consoles and traces in
`artifacts/<run_id>/`.

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

### Anti-faking checks

Markers alone are gameable: a `printf` of a literal satisfies any regex, and a
behaviour check that only requires the marker to recur on reload is satisfied
just as happily by a printf in the load handler. So three tiers additionally
require the built `.ko` to carry undefined references to the real API
(`required_syms_check()` in `tasks.py`):

| tier | required symbols |
|---|---|
| t2-osd | `osd_register`, `osd_set` |
| t3-unr | `new_unrhdr`, `alloc_unr`, `free_unr` |
| t4-hhook | `hhook_head_register`, `hhook_run_hooks` |

Each list is the intersection across legitimate API spellings —
`osd_get_unlocked` substitutes for `osd_get`, `hhook_add_hook_lookup` for
`hhook_add_hook` — so those names cannot be required without failing a correct
module. All three are verified in **both** directions: hand-built printf-only
fakes are rejected, and a real module written by a model is admitted through the
full harness. This does not stop a *deliberate* fake, which could call the API
and ignore the result.

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

Booting a guest rather than trusting `make` is load-bearing. Two models
independently wrote

```c
DECLARE_MODULE(fbsdq_hhook, fbsdq_modevent, SI_SUB_KLD, SI_ORDER_ANY);
                            ^^^^^^^^^^^^^^ the event function, where a
                                           moduledata_t belongs
```

`DECLARE_MODULE` casts internally, so both builds were clean and the error only
ever surfaces as a general protection fault at `kldload`. A compile-only check
would have scored both runs as successes.

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
- **Tier 6 is the case to watch**, since it asks the model to do the same job as
  `mkimage.sh`. Its prompt was checked against every trap discovered while
  writing that script — `/usr/obj`, `bsd.kmod.mk`, `SYSDIR`, `memstick`,
  `WITHOUT_*`, `GENERIC-NODEBUG`, `/rescue`, hardlinks, `nullfs`, `mdconfig` —
  and mentions **none** of them.
- The one thing tier 6 *does* state is that a module must match the kernel's
  `__FreeBSD_version`. That is stated on purpose: without it the task is unfair
  rather than hard, because a model could build a perfect image that fails for
  an invisible ABI reason.

## Caveats on the numbers

- **t6 is `--reps 1` for every model**, and Opus ran one rep per tier
  throughout. Single samples; MTP sampling moves them on its own.
- **`--seed` does not make these runs reproducible.** Two runs of the same seed
  and tier differed by 79 vs 32 iterations and 2806 s vs 693 s. Only aggregate
  rates over several reps carry meaning.
- **The `no_progress` threshold (40 steps without a source change) ends runs**,
  so a model that would have patched at step 45 scores the same as one that
  never would.
- **t2's marker cannot tell `OSD_THREAD` from `OSD_PROCESS`**, so a pass with
  the thread wrappers where the prompt asks for the process type is still
  scored a pass.

Full limitation list and the reasoning behind each harness choice are in
[OPERATING.md](OPERATING.md).
