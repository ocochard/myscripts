# fbsd-quality — continuation instructions

Written 2026-09-09. Nothing is running; the tree is clean apart from an
unrelated `FreeBSD/packages.list` edit.

**Read this before running any bench.** Two harness bugs and one impossible
task were found *during* a sweep, by watching runs fail. A sweep launched
without knowing them produces confident wrong numbers — this bench has done
that eight times.

---

## 1. Where the numbers stand

Only these rows ran on the current harness. Everything else in
`results.jsonl` (78 rows total) is superseded — see §4.

| run | tier | verdict | iters | `pe` | `nt` | model_s |
|---|---|---|---|---|---|---|
| v23-opus-t15 | t1-eventhandler | PASS | 19 | 0 | 0 | 84 |
| v23-opus-t15 | t2-osd | PASS | 29 | 0 | 0 | 166 |
| v23-opus-t15 | t3-unr | PASS | 26 | 0 | 0 | 106 |
| v23-opus-t15 | t4-hhook | PASS | 22 | 0 | 0 | 107 |
| v23-opus-t15 | t5-epoch | PASS | 25 | 0 | 0 | 113 |
| v23-q38-t15 (`toolcalling`) | t1-eventhandler | FAIL | 74 | 0 | 32 | 1 132 |
| v23-q38-t15 (`toolcalling`) | t2-osd | FAIL | 65 | 0 | 23 | 11 256 |
| v23-q38-code (`code`) | t1-eventhandler | FAIL | 42 | 0 | 0 | 962 |

`pe` = parse_errors, `nt` = no_toolcall.

Opus: 5/5 clean, all markers verified in the guest console. Its **t2 row is
void** (ran under the broken task, see §2). Flash-Next has no rows on this
harness — it was never reached.

---

## 2. Fixed and committed

### `_writes_into_src` refused read-only commands — `25ea839`

The guard tested "a write-ish token appears anywhere" AND "the tree path
appears anywhere" as independent conditions, with bare `>` in the token list.
So this was refused as a write into the source tree:

```sh
grep -ri foo /usr/src-fbsdq-N/sys/conf/files 2>/dev/null
```

`2>/dev/null` supplied the `>`, the path supplied the name, and the two were
unrelated. Suppressing stderr while reading the tree is the commonest shell
idiom there is.

Live for the whole history of the bench; refusals in **44 archived runs** across
every model and tier (up to 16 in one). Models could not work around it because
the stated reason was wrong. One qwen38 t1 run spent 36 shell calls, wrote
nothing, scored FAIL — while correctly diagnosing the guard in its own
reasoning. Biased against models that explore before writing.

Now requires the write's *target* to be in the tree. Verified 35/35 hand cases
plus all 56 tree-naming commands replayed from archived traces.

### t2-osd was impossible — `9b8b41c`

The prompt required an OSD slot on the "*process* object type". **No such type
exists**: `sys/sys/osd.h` defines exactly `OSD_THREAD(0)`, `OSD_JAIL(1)`,
`OSD_KHELP(2)`.

It scored backwards for all 15 t2 rows ever recorded:

| model | behaviour | scored |
|---|---|---|
| claude-opus-4-5 | substituted `osd_thread_register()`, commented it "the thread (process) object type" | **PASS** |
| Qwen3.8-27B | searched, reported correctly that only THREAD/JAIL/KHELP exist, refused to fake it, spent 65 steps / 3.1 h / 105k tokens | **FAIL** |

The bench rewarded ignoring the spec and punished reading the source.

Fixed by naming the type FreeBSD has (thread) and requiring a `pid` field so
the module must reach the real object:

```
FBSDQ:osd:slot=\d+:pid=\d+:roundtrip=0x(?:0x)?deadbeef
```

Verified end-to-end — reference module built and booted, clean
load/unload/reload, no panic:

```
FBSDQ:osd:slot=2:pid=28:roundtrip=0xdeadbeef
MARKER MATCH: True
```

Marker unit-tested 5/5: old pid-less format now fails, doubled `0x%p` prefix
still passes, wrong value and uppercase hex fail.

---

## 3. Open questions, in priority order

### 3a. FIRST: does `--src-mode auto`'s ZFS clone break qwen38? (test ready)

This is the highest-value next experiment. qwen38 fails t1 identically under
*both* agent types, always with "no .c file written", and the source path is
what changed since it last passed:

| run | agent sees | verdict |
|---|---|---|
| `v2-q38mtp-freebsd` t1 | `/usr/src` | PASS (wrote `fbsdq_exit.c`) |
| `np-q38mtp-freebsd` t1 | `/usr/src` | PASS (wrote `fbsdq.c`) |
| `v23-q38-code` t1 | `/usr/src-fbsdq-95579` | FAIL, no file |

Under `code` mode with *perfect* formatting (`pe=0`, `nt=0`), qwen38 issued
**160 `run_shell` calls in 42 iterations**, re-running identical commands —
four consecutive repetitions of:

```sh
cat /usr/src-fbsdq-95579/sys/modules/Makefile 2>/dev/null | head -60
```

Confirmed on disk: `/usr/obj/usr/` contains `src` and `src-unionfs*` but **no**
`src-fbsdq-*`. The object directory the model kept probing for cannot exist for
a fresh clone, and the trace shows it looping on those probes.

NOT proven — Opus passed all five tiers against the same clone, and a model
should not loop regardless. Run the test:

```sh
sudo .venv/bin/python -u bench.py --model Qwen3.8-27B-Q8_0-MTP \
  --api-base http://192.168.100.8:8080/v1 --backend openai \
  --disk /zroot/vm/fbsdq.img --src /usr/src --agent-user olivier \
  --run-id v24-q38-srcnone --agent-type code --src-mode none \
  --tasks t1-eventhandler --seed 42 --reps 1
```

If it writes a file, the clone is the trigger: `--src-mode auto` must either
provide a matching `/usr/obj` or state in `ENV_NOTE` that no prebuilt object
tree exists. If it loops again, the repetition is the model's.

### 3b. SETTLED: the agent type was never the problem

`v23-q38-code` gave qwen38 **perfect** format compliance (`pe=0`, `nt=0`) and
t1 failed identically to `toolcalling`. So `--agent-type auto` is exonerated
and `detect_agent_type`'s existing judgement stands: `toolcalling` is
unnecessary for qwen38 but not broken.

**Do not** add a model-name rule or adaptive mid-run switching — its docstring
warns against both, and this experiment says the agent class was never the
cause. The `no_toolcall` errors under `toolcalling` were a symptom layered on
the real failure.

### 3c. Every marker is gameable — not fixed

All five t1-t5 markers have fully fixed values and are satisfied by a bare
`printf`. There is **no source-level, symbol-level or behavioural check anywhere
in `bench.py`** (verified by grep).

No model has been caught doing this — t2's substitution is the only spec
deviation found, and it was reasoned, not faked. But the bench has no defence.

Protection varies:

- **t1 is naturally protected**: the handler fires per process exit, so a real
  module prints several lines with distinct PIDs (observed: 6 lines, 3 PIDs). A
  hardcoded printf gives one line, one PID — detectable, but nothing checks it.
- **t2/t3/t4/t5 print once at load.** A hardcoded line is indistinguishable
  from real work. t3's marker fixes `a=0:b=1:c=2:reuse=1`, which is both what a
  correct allocator returns and what a guesser would write.

Fix following t6's hidden-regression pattern: a per-tier check baked into the
guest image (never on the p9fs share) — t1 require ≥2 distinct PIDs; t3
load/unload/reload with a fresh allocator sequence; t4/t5 verify from the
callback side.

### 3d. Step refunds let a failing run burn hours

Refunds (parse failures not charged against `--max-steps`) work mechanically
but interact badly with the no-progress detector: instead of failing fast,
qwen38's t2 ran **11 256 s (3.1 h)** and 105k tokens. Consider a wall-clock or
token ceiling independent of step count.

### 3e. Tier audit — t1/t3/t4/t5 are sound

Checked 2026-09-09. All name real facilities, and all four passing solutions
used the correct APIs with no substitution:

| tier | facility | in tree | solution used |
|---|---|---|---|
| t1 | `process_exit` | `eventhandler.h:251` | `EVENTHANDLER_REGISTER(process_exit,...)` |
| t3 | `new_unrhdr`/`alloc_unr`/`free_unr` | `systm.h:558-567` | correct, incl. `delete_unrhdr` |
| t4 | `HHOOK_TYPE_SOCKET`=2 | `hhook.h:67` | `hhook_head_register(...SOCKET, 42...)` |
| t5 | `epoch_alloc`/`in_epoch`/`epoch_call` | `epoch.h:70-77` | `epoch_alloc(name,0)`, `epoch_call` |

t2 was the only broken task.

---

## 4. Re-runs needed

Every t1-t5 row except the six valid `v23` ones is superseded, for three
independent reasons:

- **`v2-` rows (17)**: `--no-progress-patience 8` was set while the detector
  was inert (mutating `agent.max_steps` is silently ignored), so their
  `stopped_early` flags are unreliable.
- **`v22-` rows (11)** and everything older: ran under the broken
  `_writes_into_src`.
- **All 15 t2 rows ever recorded**: ran under the impossible task.

Order:

1. **Run 3a** (one tier, ~20 min). It may explain qwen38 entirely, and running
   a full sweep before knowing wastes hours.
2. **Re-run the full sweep** — all three models, t1-t5, sequential, with
   whatever 3a implies for `--src-mode`.
3. **Re-run Opus t2** if not covered by step 2 (its only void tier).
4. Flash-Next has never run on this harness at all.

Sweep script is `/tmp/t15-sweep.sh` (edit `run_id` to `v24-*` first):

```sh
sudo nohup /tmp/t15-sweep.sh > /tmp/t15-sweep.out 2>&1 &
```

Keep it **sequential**. bigone builds every module and boots every guest;
parallel runs contend for CPU and distort `shell_s`, and two runs against the
same llama-server also distort `model_s` — the column models are compared on.

ser6 was evaluated as a second builder and rejected: its `/usr/src` is
`__FreeBSD_version` **1600012** against bigone's **1600022**, so modules would
compile against different kernel internals and a failure could not be
attributed to the model. It would need a tree sync plus its own `fbsdq.img`.

---

## 5. Gotchas that cost time

**Run the bench with `sudo`.** `/tmp/fbsd-quality` is root-owned; without it
every run dies instantly on `PermissionError` and a sweep "completes" in
seconds.

**`--src /usr/src`, not `/usr/src-unionfs`.** `fbsdq.img` is
`__FreeBSD_version` **1600022** and `/usr/src` matches. The pinned t6 tree is
**1600023** — modules built there will not load in this image.

**Ignore the "running host is 1600020" warning for t1-t5.** The host kernel is
irrelevant: modules are built against the tree and loaded in the *guest*. Guest
and tree are both 1600022 (verified from `FBSDQ-GUEST-READY 1600022` in every
console). The warning is worded for a different misconfiguration.

**Killing a run:** kill the sweep wrapper *first* or it advances to the next
model, then `sudo kill -9` the bench (plain `kill` does not land). Then clean
up — `zfs list | grep src-fbsdq` and destroy both the clone and its
`zroot/usr/src@fbsdq-<pid>` snapshot.

**Do not build a kernel module directly in `/tmp`.** A stale
`/tmp/Makefile.inc` (Feb 2026, unrelated to this project) is auto-included by
BSD `make` from the parent directory and injects bhyve's `SRCS`, giving
`make: don't know how to make atkbdc.c`. The bench is unaffected (workdirs are
one level deeper). Build ad-hoc modules under `/var/tmp`.

**Monitor filters need anchoring.** `grep -E "=== "` matches the agent's own
`echo '=== ... ==='` shell output and fires false events; a pattern matching
`tail` itself will kill the monitor. Use
`^ *-> (PASS|FAIL)|^=== (starting|finished)`.

**Verify a PASS against the guest console, not the verdict.**
`grep -a '^FBSDQ:' artifacts/<run>/<task>-rep1/console.log`. An unexpectedly
*cheap* PASS on a hard tier is the shape a harness bug takes.

**Marker counts per console are not 1.** t1 emits 6 (several process exits), t5
emits 4 — by design, plus kernel/serial interleaving. Not duplicate loads.

**Housekeeping:** `/usr/obj/usr/` holds 16 leaked `src-unionfs-fbsdq-<pid>`
object dirs from old t6 runs, **23 GB total**. Harmless but worth reclaiming.

---

## 6. Docs

`README.md` has **not** been touched. Its t1-t5 tables still present `v2-` rows
as current. Do not update it until a valid sweep exists — publishing now would
report two harness bugs and a broken task as model results.

When updating: mark `v2-`/`v22-` superseded with the reasons in §4, state that
all historical t2 rows are void, and note that Opus's t2 needs re-running.
