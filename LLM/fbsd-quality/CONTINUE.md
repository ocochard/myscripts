# fbsd-quality — continuation instructions

Written 2026-09-09. State of play after finding two harness bugs and one
broken task mid-sweep.

**Read this before running any bench.** Two of the three problems below were
found only because a run was watched while it failed; a sweep launched without
knowing them will produce confident wrong numbers.

---

## 1. What is fixed (committed)

### `_writes_into_src` refused read-only commands — commit `25ea839`

The guard tested "a write-ish token appears anywhere" AND "the tree path
appears anywhere" as independent conditions, with bare `>` in the token list.
So this was refused as a write into the source tree:

```sh
grep -ri foo /usr/src-fbsdq-N/sys/conf/files 2>/dev/null
```

`2>/dev/null` supplied the `>`, the path supplied the name, and the two were
unrelated. Suppressing stderr while reading the tree is the commonest shell
idiom there is.

Impact: live for the whole history of the bench, refusals in **44 archived
runs** across every model and tier (up to 16 in one run). Models could not work
around it because the stated reason was wrong. One qwen38 t1 run spent 36 shell
calls, wrote nothing, scored FAIL — while correctly diagnosing the guard in its
own reasoning. Biased against models that explore before writing.

Now requires the write's *target* to be in the tree. Verified 35/35 hand cases
and all 56 tree-naming commands replayed from archived traces.

### t2-osd was impossible — `tasks.py` (uncommitted)

The prompt asked for an OSD slot on the "*process* object type". **FreeBSD has
no such type.** `sys/sys/osd.h` defines exactly `OSD_THREAD(0)`, `OSD_JAIL(1)`,
`OSD_KHELP(2)`.

It scored backwards for 45+ runs:

| model | behaviour | scored |
|---|---|---|
| claude-opus-4-5 | substituted `osd_thread_register()`, commented it "the thread (process) object type" | **PASS** |
| Qwen3.8-27B | searched, reported correctly that only THREAD/JAIL/KHELP exist, refused to fake it, burned 65 steps / 3.1 h / 105k tokens | **FAIL** |

The bench rewarded ignoring the spec and punished reading the source.

Fix: prompt now names the *thread* type, and the marker requires a `pid` field
so the module must touch the real object rather than print a constant.

```
FBSDQ:osd:slot=\d+:pid=\d+:roundtrip=0x(?:0x)?deadbeef
```

Validated end-to-end — reference module built and booted in the guest:

```
FBSDQ:osd:slot=2:pid=28:roundtrip=0xdeadbeef
MARKER MATCH: True
```

Marker unit-tested 5/5: old pid-less format now fails, doubled `0x%p` prefix
still passes, wrong value and uppercase hex fail.

**Every pre-2026-09-09 t2 row is void, including Opus's passes.**

---

## 2. What is still open

### The agent-type question (experiment running)

`v23-q38-code` is running now: qwen38 under `--agent-type code`, everything
else identical to the failing `toolcalling` run. Output `/tmp/q38-code-control.out`.

At the time of writing it is on t1 with **0 parse failures**, against 32 on the
`toolcalling` run. Early, not conclusive.

Its **t2 row will be void** (started before the t2 fix). t1/t3/t4/t5 remain
valid — the agent-type question is independent of t2.

How to read it:

| outcome | conclusion |
|---|---|
| t1 passes under `code` | `--agent-type auto` is breaking a model that worked. `detect_agent_type`'s "KNOWN LIMITATION" is a real bug needing a per-model override. Re-run everything under `code`. |
| t1 fails the same way | the never-writes behaviour is the model's, `auto` is exonerated. Flash-Next should still get a `code` control before any `toolcalling` row is trusted. |

Context: qwen38's parse-failure rate under `code` was **1/875 iterations**, so
`auto` may be "fixing" a problem this model does not have. Its older `code`-mode
rows passed t1-t3.

### Every marker is gameable — not fixed

All five t1-t5 markers have fully fixed values and are satisfied by a bare
`printf`. There is **no source-level, symbol-level or behavioural check
anywhere in `bench.py`**.

No model has been caught doing this — t2's substitution is the only spec
deviation found, and it was reasoned, not faked. But the bench has no defence.

Protection varies by tier:

- **t1 is naturally protected**: the handler fires per process exit, so a real
  module prints several lines with distinct PIDs (observed: 6 lines, 3 PIDs). A
  hardcoded printf gives one line, one PID — detectable, but nothing checks it.
- **t2/t3/t4/t5 print once at load.** A hardcoded line is indistinguishable
  from real work. t3's marker fixes `a=0:b=1:c=2:reuse=1`, which is both what a
  correct allocator returns and what a guesser would write.

Suggested fix, following t6's existing hidden-regression pattern: a per-tier
hidden check baked into the guest image (never on the p9fs share) — t1 require
≥2 distinct PIDs; t3 load/unload/reload and require a fresh allocator sequence;
t4/t5 verify from the callback side.

### The audit result for the other tiers

Checked 2026-09-09 — all four name real facilities, and all four passing
solutions used the correct APIs with no substitution:

| tier | facility | in tree | solution used |
|---|---|---|---|
| t1 | `process_exit` | `eventhandler.h:251` | `EVENTHANDLER_REGISTER(process_exit,...)` |
| t3 | `new_unrhdr`/`alloc_unr`/`free_unr` | `systm.h:558-567` | correct, incl. `delete_unrhdr` |
| t4 | `HHOOK_TYPE_SOCKET`=2 | `hhook.h:67` | `hhook_head_register(...SOCKET, 42...)` |
| t5 | `epoch_alloc`/`in_epoch`/`epoch_call` | `epoch.h:70-77` | `epoch_alloc(name,0)`, `epoch_call` |

t2 was the only broken task.

### Step refunds let a failing run continue for hours

The refund fix (parse failures not charged against `--max-steps`) works
mechanically, but interacts badly with the no-progress detector: instead of
failing fast, qwen38's t2 ran **11 256 s (3.1 h)** and 105k tokens before
stopping. Consider a wall-clock or token ceiling independent of step count.

---

## 3. Re-runs needed

All t1-t5 rows in `results.jsonl` are superseded. Two independent reasons:

- **`v2-` rows (17)**: ran with `--no-progress-patience 8` set while the
  detector was inert (mutating `agent.max_steps` was silently ignored), so
  their `stopped_early` flags are unreliable.
- **`v22-` rows (11)** and everything older: ran under the broken
  `_writes_into_src`.
- **All 15 t2 rows ever recorded**: ran under the impossible task.

The only rows on the current harness are `v23-opus-t15` (5/5 PASS, 0 errors of
any kind) — but its t2 is void, so Opus needs t2 re-run too.

Order I would use:

1. **Wait for `v23-q38-code` to finish.** Do not start anything on
   `192.168.100.8` before it does — same endpoint, and a parallel run distorts
   `model_s`, the column models are compared on.
2. **Decide the agent type from its t1/t3/t4/t5 result** (table above).
3. **Re-run the full sweep** on the chosen agent type, all three models, t1-t5,
   sequential.
4. **Re-run Opus t2** (its only void tier) if not covered by step 3.

Command shape — the sweep script is `/tmp/t15-sweep.sh`, needs `sudo`:

```sh
sudo nohup /tmp/t15-sweep.sh > /tmp/t15-sweep.out 2>&1 &
```

Per-run form:

```sh
.venv/bin/python -u bench.py --model <name> --api-base <url> --backend <openai|anthropic> \
  --disk /zroot/vm/fbsdq.img --src /usr/src --agent-user olivier \
  --run-id <id> --agent-type <auto|code|toolcalling> \
  --tasks t1-eventhandler,t2-osd,t3-unr,t4-hhook,t5-epoch --seed 42 --reps 1
```

---

## 4. Gotchas that cost time

**Run the bench with `sudo`.** `/tmp/fbsd-quality` is root-owned; without it
every run dies instantly on `PermissionError` and the sweep "completes" in
seconds.

**`--src /usr/src`, not `/usr/src-unionfs`.** `fbsdq.img` is
`__FreeBSD_version` **1600022** and `/usr/src` matches. The pinned t6 tree is
**1600023** — modules built there will not load in this image.

**Ignore the "running host is 1600020" warning for t1-t5.** The host kernel is
irrelevant: modules are built against the tree and loaded in the *guest*. Guest
and tree are both 1600022 (verified from `FBSDQ-GUEST-READY 1600022` in every
console). The warning is worded for a different misconfiguration.

**Killing a run needs `sudo kill -9`,** and the sweep wrapper must die first or
it advances to the next model. Then clean up: `zfs list | grep src-fbsdq` and
destroy leftovers plus their `zroot/usr/src@fbsdq-<pid>` snapshots.

**Do not build a kernel module directly in `/tmp`.** A stale
`/tmp/Makefile.inc` (Feb 2026, not part of this project) is auto-included by
BSD `make` from the parent directory and injects bhyve's `SRCS`, giving
`make: don't know how to make atkbdc.c`. The bench is unaffected (its workdirs
are one level deeper). Build ad-hoc modules under `/var/tmp`.

**`tail -f /tmp/t15-sweep.out` is Rich-formatted** and repaints step counters.
Filter it:

```sh
tail -f /tmp/t15-sweep.out | grep --line-buffered -E "^ *-> (PASS|FAIL)|=== |JSON blob"
```

**Verify a PASS against the guest console, not the verdict.** This bench has
produced eight confident wrong verdicts. `grep -a '^FBSDQ:' artifacts/<run>/<task>-rep1/console.log`.
An unexpectedly *cheap* PASS on a hard tier is the shape a harness bug takes.

**Marker counts per console are not 1.** t1 emits 6 (several process exits), t5
emits 4 — by design, plus kernel/serial interleaving. Not duplicate loads.

---

## 5. Docs not yet updated

`README.md` has **not** been touched. Its t1-t5 tables still show `v2-` rows as
current. Do not update it until a valid sweep exists — writing up qwen38's
failures now would publish two harness bugs and a broken task as model results.

When updating: mark `v2-`/`v22-` superseded with the reasons above, and state
that all historical t2 rows are void.
