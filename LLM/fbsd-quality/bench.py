#!/usr/bin/env python3
"""fbsd-quality — measure whether a local model can write a working FreeBSD
kernel module, and how much work it takes.

Objective scoring: the module either produces its expected marker in the guest
dmesg, or it does not. See README.md for the design rationale.

Usage:
  sudo python3 bench.py --model qwen38-mtp --api-base http://127.0.0.1:8080/v1 \\
       --disk /path/to/guest.img [--tasks t1-eventhandler,t2-osd] [--reps 3]

Output: one JSON object per (model, task, rep) to --out (default
results.jsonl), plus a summary table on stdout.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

import tasks as tasklib
import builder
import vmrunner

# Failure taxonomy. Iteration counts alone conflate "wrote bad C" with
# "fumbled the agent loop", so every failure gets a class.
F_COMPILE = "compile"
F_LOAD = "load"
F_WRONG = "wrong_output"
F_PANIC = "panic"
F_TIMEOUT = "vm_timeout"
F_NOFILES = "no_files_written"
F_HARNESS = "harness"
# The endpoint ran out of context. NOT a harness bug and NOT bad kernel code:
# this agent loop resends its whole history each step, so a small --ctx-size
# ends the task regardless of how good the model is. Observed on the
# Flash-Next slot, which pins CTX=32768 because IQ3_XXS cannot hold more
# alongside its weights, while the dense-Q8 endpoint offers 131072 — a 4x
# asymmetry that makes cross-endpoint comparison meaningless unless reported.
F_CONTEXT = "context_exhausted"
# Stopped by the no-progress detector: the agent kept taking steps but stopped
# creating or changing any source file. Distinct from no_files_written (which
# may simply mean the step cap ran out mid-work) because it identifies a model
# that is investigating instead of producing.
F_NOPROGRESS = "no_progress"


_SRC_WRITE_RE = None


def _writes_into_src(command, src_root):
    """Cheap tripwire for commands that would modify the source tree.

    NOT a security boundary. The bench needs root for bhyve, so unless the
    agent is dropped to an unprivileged user (--agent-user, strongly
    recommended) its shell is root and can do anything it likes to the host.
    This only catches the careless cases — an agent that decides to build
    inside sys/modules, or redirect output into a header. check_src_clean()
    is the backstop that notices when something got through.
    """
    global _SRC_WRITE_RE
    if _SRC_WRITE_RE is None:
        _SRC_WRITE_RE = re.compile(
            r"(?:>|>>|\btee\b|\bcp\b|\bmv\b|\brm\b|\bmkdir\b|\btouch\b|"
            r"\bsed\s+-i|\binstall\b|\bchmod\b|\bchown\b|\bpatch\b|\bmake\b[^|;]*\b(?:install|depend)\b)"
        )
    if not _SRC_WRITE_RE.search(command):
        return False
    # Only object if the tree is actually named. Building in the workdir with
    # redirects is fine and common.
    real = os.path.realpath(src_root)
    return real in command or src_root in command


def check_src_clean(src_root):
    """Did the previous task modify the source tree? Returns a short
    description of the damage, or None.

    Caveat for parallel runs: the tree is SHARED state. If two bench processes
    point at the same --src, this cannot attribute a modification to one of
    them — either may report the other's damage. That is still the right
    behaviour (both runs are contaminated), but give each endpoint its own
    tree if you need clean attribution.
    """
    r = subprocess.run(["git", "-C", src_root, "status", "--porcelain"],
                       capture_output=True, text=True)
    if r.returncode == 0:
        dirty = [ln for ln in r.stdout.splitlines() if ln.strip()]
        if dirty:
            return f"{len(dirty)} modified path(s), e.g. " + \
                   "; ".join(d.strip()[:60] for d in dirty[:3])
        return None
    return None


def src_abi_version(src_root):
    """__FreeBSD_version of the TREE — the value stamped into every .ko built
    from it, and therefore the version the guest kernel must match."""
    try:
        with open(os.path.join(src_root, "sys/sys/param.h")) as fh:
            m = re.search(r"^#define\s+__FreeBSD_version\s+(\d+)", fh.read(), re.M)
            return int(m.group(1)) if m else None
    except OSError:
        return None


def check_abi(src_root):
    """Warn when the running host differs from the tree.

    Host and tree routinely diverge — 15.1-RELEASE with a 16-head checkout, or
    simply a `git pull` ahead of the installed kernel (observed on this host:
    running 1600020, tree at 1600022). This matters because the GUEST kernel
    must match the TREE, not the host; an image built from /boot/kernel in that
    situation rejects every module the bench produces, and every task then
    fails with failure_class=load for a reason that has nothing to do with the
    model.
    """
    src_v = src_abi_version(src_root)
    host_v = None
    r = subprocess.run(["sysctl", "-n", "kern.osreldate"],
                       capture_output=True, text=True)
    if r.returncode == 0 and r.stdout.strip().isdigit():
        host_v = int(r.stdout.strip())
    return src_v, host_v


def prepare_src(src_root, mode, run_dir):
    """Give this run a tree the agent cannot damage, or its own copy.

    Returns (path_to_use, cleanup_callable).

    Cost, measured on a 3.1 GB /usr/src (116k files, 2.1 GB of it .git):

      ro (nullfs)  ~0 s, 0 bytes   shared, READ-ONLY — mutation impossible
      clone (zfs)  ~0 s, ~0 bytes  independent + writable (CoW)
      shallow      ~45 s, 1.3 GB   independent + writable
      (none)       0               shared + writable — only safe with
                                   --agent-user and a clean tree

    "shallow" is the weakest of the three: it is the only one that costs real
    time and space, and it still leaves the tree writable. Prefer ro, or zfs
    clone when the run genuinely needs a different revision.
    """
    if mode == "none":
        return src_root, None

    if mode == "ro":
        if os.geteuid() != 0:
            sys.exit("--src-mode=ro needs root (nullfs mount)")
        mnt = os.path.join(run_dir, "src-ro")
        os.makedirs(mnt, exist_ok=True)
        r = subprocess.run(["mount", "-t", "nullfs", "-o", "ro",
                            src_root, mnt], capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(f"nullfs mount failed: {r.stderr.strip()}")

        def _umount():
            subprocess.run(["umount", mnt], capture_output=True, text=True)
        return mnt, _umount

    if mode == "zfs-clone":
        ds = _zfs_dataset_for(src_root)
        if not ds:
            sys.exit(f"--src-mode=zfs-clone: {src_root} is not on ZFS")
        tag = f"fbsdq-{os.getpid()}"
        snap = f"{ds}@{tag}"
        clone = f"{ds}-{tag}"
        if subprocess.run(["zfs", "snapshot", snap],
                          capture_output=True, text=True).returncode != 0:
            sys.exit(f"zfs snapshot {snap} failed")
        r = subprocess.run(["zfs", "clone", snap, clone],
                           capture_output=True, text=True)
        if r.returncode != 0:
            subprocess.run(["zfs", "destroy", snap], capture_output=True)
            sys.exit(f"zfs clone failed: {r.stderr.strip()}")
        mp = subprocess.run(["zfs", "get", "-H", "-o", "value", "mountpoint",
                             clone], capture_output=True, text=True).stdout.strip()

        def _destroy_clone():
            subprocess.run(["zfs", "destroy", "-r", clone], capture_output=True)
            subprocess.run(["zfs", "destroy", snap], capture_output=True)
        if not mp or mp == "-" or not os.path.isdir(mp):
            _destroy_clone()
            sys.exit(f"zfs clone {clone} has no usable mountpoint")
        return mp, _destroy_clone

    if mode == "shallow":
        dst = os.path.join(run_dir, "src-shallow")
        shutil.rmtree(dst, ignore_errors=True)
        print(f"shallow-cloning {src_root} -> {dst} "
              f"(~45 s, ~1.3 GB; --src-mode=ro is free)", file=sys.stderr)
        r = subprocess.run(["git", "clone", "--depth", "1", "--no-hardlinks",
                            "--quiet", f"file://{os.path.realpath(src_root)}",
                            dst], capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(f"shallow clone failed: {r.stderr.strip()[:300]}")

        def _rm():
            shutil.rmtree(dst, ignore_errors=True)
        return dst, _rm

    sys.exit(f"unknown --src-mode: {mode}")


# ZFS dataset lookup lives in vmrunner (it needs it for per-VM disk clones);
# reuse it rather than keeping two copies that can drift.
_zfs_dataset_for = vmrunner._zfs_dataset_for


def src_revision(src_root):
    """Record which tree the model was writing against — the tasks depend on
    real APIs, and those move between branches and across time."""
    r = subprocess.run(["git", "-C", src_root, "rev-parse", "--short", "HEAD"],
                       capture_output=True, text=True)
    if r.returncode == 0:
        return r.stdout.strip()
    # Not a git checkout (release tarball / NFS export): fall back to the
    # branch+version the tree declares, which is still enough to compare runs.
    try:
        with open(os.path.join(src_root, "sys/conf/newvers.sh")) as fh:
            txt = fh.read()
        b = re.search(r'^BRANCH="?([^"\n]+)', txt, re.M)
        v = re.search(r'^REVISION="?([^"\n]+)', txt, re.M)
        if v or b:
            return f"{(v.group(1) if v else '?')}-{(b.group(1) if b else '?')}"
    except OSError:
        pass
    return "unknown"


def make_agent(model_id, api_base, api_key, workdir, max_steps, src_root,
               agent_user=None, shell_timeout=300, shell_clock=None,
               backend="openai", panic_state=None, progress=None,
               seed=None, temperature=None):
    """A smolagents CodeAgent with filesystem + shell tools, rooted at workdir.

    Tool surface is deliberately small and generic: read/write files, run a
    shell command, grep the source tree. Nothing bhyve- or p9fs-aware — the
    model is being tested on kernel knowledge, not on our plumbing.

    src_root is exposed to the agent read-only via read_file/grep_src so the
    same harness can bench against 16-CURRENT, a stable branch, or a pinned
    checkout without editing the tasks.
    """
    from smolagents import CodeAgent, tool

    # Shared with run_one so it can subtract tool time from wall_s.
    _shell_clock = shell_clock if shell_clock is not None else {
        "seconds": 0.0, "calls": 0, "grep_seconds": 0.0}
    # Filled in by verify() when a panic leaves a core; debug_last_panic reads
    # it. Empty on the first iteration, which is why the tool explains itself
    # rather than erroring.
    _panic_state = panic_state if panic_state is not None else {}

    @tool
    def write_file(path: str, content: str) -> str:
        """Write a file into the working directory.

        Args:
            path: Filename relative to the working directory.
            content: Full file contents.
        """
        full = os.path.realpath(os.path.join(workdir, path))
        if not full.startswith(os.path.realpath(workdir)):
            return "ERROR: path escapes the working directory"
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as fh:
            fh.write(content)
        return f"wrote {path} ({len(content)} bytes)"

    @tool
    def read_file(path: str) -> str:
        """Read a file. Absolute paths are allowed so the FreeBSD source tree
        can be inspected.

        Args:
            path: Absolute path, or a path relative to the working directory.
        """
        full = path if os.path.isabs(path) else os.path.join(workdir, path)
        try:
            with open(full, "r", errors="replace") as fh:
                data = fh.read(200_000)
            return data
        except OSError as e:
            return f"ERROR: {e}"

    @tool
    def grep_src(pattern: str, path_glob: str = "sys") -> str:
        """Search the FreeBSD source tree for a regular expression. Use this to
        locate kernel functions, macros and their declarations.

        Args:
            pattern: Extended regular expression to search for.
            path_glob: Subdirectory of the source tree to search, e.g.
                "sys/kern" or "sys/sys". Defaults to "sys".
        """
        target = os.path.realpath(os.path.join(src_root, path_glob))
        if not target.startswith(os.path.realpath(src_root)):
            return "ERROR: path escapes the source tree"
        try:
            p = subprocess.run(
                ["grep", "-rnE", "--include=*.c", "--include=*.h",
                 pattern, target],
                capture_output=True, text=True, timeout=120)
            out = p.stdout or ""
            if not out.strip():
                return "(no matches)"
            lines = out.splitlines()
            head = "\n".join(lines[:200])
            more = f"\n... ({len(lines) - 200} more matches)" if len(lines) > 200 else ""
            return head + more
        except subprocess.TimeoutExpired:
            return "ERROR: grep timed out"

    @tool
    def debug_last_panic(gdb_commands: str = "bt") -> str:
        """Inspect the kernel core dump from the most recent panic, if there is
        one. Optional: use it only when a module you loaded panicked the test
        machine and the console backtrace is not enough.

        Args:
            gdb_commands: newline-separated kgdb commands to run against the
                core, e.g. "bt" or "bt\\ninfo locals\\nlist". Defaults to "bt".
        """
        state = _panic_state
        core = state.get("core")
        kern = state.get("kernel_debug")
        if not core:
            return ("No kernel core dump is available. Dumps only exist after a "
                    "panic; if the module loaded cleanly there is nothing to "
                    "debug. The console output from the test machine is in the "
                    "error message you already received.")
        if not kern:
            return (f"Core found at {core} but no kernel.debug was located, so "
                    f"kgdb cannot resolve symbols.")
        kgdb = shutil.which("kgdb") or "/usr/local/bin/kgdb"
        if not os.path.exists(kgdb):
            return "kgdb is not installed on this host; cannot inspect the core."
        script = (gdb_commands or "bt").replace("\\n", "\n")
        try:
            p = subprocess.run(
                [kgdb, "-batch", "-ex", "set pagination off",
                 *[a for c in script.splitlines() if c.strip()
                   for a in ("-ex", c.strip())],
                 kern, core],
                capture_output=True, text=True, timeout=180)
            out = (p.stdout or "") + (p.stderr or "")
            return out[-20_000:] or "(kgdb produced no output)"
        except subprocess.TimeoutExpired:
            return "ERROR: kgdb timed out after 180s"

    @tool
    def run_shell(command: str) -> str:
        """Run a shell command in the working directory. Use this to build.

        Args:
            command: Shell command line.
        """
        # Time spent in make(1) is NOT model latency. Accumulate it separately
        # so the bench can report model_s = wall_s - shell_s; otherwise a
        # 10-minute build swamps the number that is supposed to measure the
        # model (fatal for the tier-4 image task, where the build dominates).
        _shell_clock["calls"] += 1
        _t_shell = time.time()
        # The source tree is normally NOT read-only, so nothing at the
        # filesystem level stops an agent from writing into it. Refuse the
        # obvious cases: a command that redirects or writes under src_root
        # would corrupt the user's tree and contaminate later repetitions.
        # This is a guard-rail, not a sandbox — see check_src_clean(), which
        # detects mutation after the fact regardless of what slipped through.
        if _writes_into_src(command, src_root):
            return (f"ERROR: refusing to run a command that writes into the "
                    f"source tree ({src_root}). Build in your working "
                    f"directory instead; the tree is for reading only.")
        argv = command
        use_shell = True
        if agent_user:
            # Real privilege separation: the bench itself needs root for
            # bhyve, but the agent's shell does not and must not have it.
            argv = ["su", "-m", agent_user, "-c", command]
            use_shell = False
        try:
            p = subprocess.run(argv, shell=use_shell, cwd=workdir,
                               capture_output=True, text=True,
                               timeout=shell_timeout)
            out = (p.stdout or "") + (p.stderr or "")
            return f"exit={p.returncode}\n{out[-20_000:]}"
        except subprocess.TimeoutExpired:
            return f"ERROR: command timed out after {shell_timeout}s"
        finally:
            _shell_clock["seconds"] += time.time() - _t_shell

    model = _build_model(model_id, api_base, api_key, backend, seed,
                         temperature)
    return CodeAgent(tools=[write_file, read_file, grep_src, run_shell,
                            debug_last_panic],
                     model=model, max_steps=max_steps, add_base_tools=False,
                     step_callbacks=([progress] if progress else None))


def endpoint_metrics(api_base):
    """Scrape llama-server's /metrics for this endpoint.

    Two uses:

      1. HEALTH — distinguish "the model is slow" from "the endpoint stalled or
         the draft head died". Without this a wedged server looks identical to
         a thinking one, and the bench just waits.
      2. MEASUREMENT — MTP draft acceptance is a per-endpoint property and it
         differs measurably between hosts running the SAME model: observed
         mid-run, frwk-bsd 33 560/56 984 = 0.589 vs frwk-linux
         42 670/60 028 = 0.711. Sampling that by hand is unreliable; recording
         it per task makes it comparable.

    Returns {} when the endpoint does not expose /metrics (llama-server needs
    --metrics; llmsrv.sh passes it, other endpoints may not) or is an
    Anthropic/OpenAI proxy, so callers must treat every key as optional.
    """
    root = api_base.rstrip("/")
    for suffix in ("/v1", "/v1/"):
        if root.endswith(suffix):
            root = root[: -len(suffix)]
            break
    try:
        r = subprocess.run(["curl", "-s", "-m", "10", f"{root}/metrics"],
                           capture_output=True, text=True, timeout=15)
    except subprocess.TimeoutExpired:
        return {}
    if r.returncode != 0 or not r.stdout.strip():
        return {}

    vals = {}
    for line in r.stdout.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        key = parts[0].replace("llamacpp:", "")
        try:
            vals[key] = float(parts[1])
        except ValueError:
            pass

    out = {}
    for k in ("prompt_tokens_total", "tokens_predicted_total",
              "n_decode_total", "requests_processing", "requests_deferred"):
        if k in vals:
            out[k] = vals[k]
    for k in ("spec_decode_num_draft_tokens_total",
              "spec_decode_num_accepted_tokens_total",
              "spec_decode_num_drafts_total"):
        if k in vals:
            out[k] = vals[k]
    d, a, n = (out.get("spec_decode_num_draft_tokens_total"),
               out.get("spec_decode_num_accepted_tokens_total"),
               out.get("spec_decode_num_drafts_total"))
    if d:
        out["draft_accept"] = round(a / d, 5) if a is not None else None
        out["draft_mean_len"] = round(d / n, 2) if n else None
    return out


def metrics_delta(before, after):
    """What this task consumed, not the endpoint's lifetime totals.

    /metrics counters are cumulative across every request the server has
    handled, so a raw reading conflates this task with everything before it.
    Acceptance is recomputed from the DIFFERENCE in counters.
    """
    if not before or not after:
        return after or {}
    out = {}
    for k in ("prompt_tokens_total", "tokens_predicted_total", "n_decode_total"):
        if k in after and k in before:
            out[k.replace("_total", "")] = after[k] - before[k]
    dd = (after.get("spec_decode_num_draft_tokens_total", 0)
          - before.get("spec_decode_num_draft_tokens_total", 0))
    da = (after.get("spec_decode_num_accepted_tokens_total", 0)
          - before.get("spec_decode_num_accepted_tokens_total", 0))
    dn = (after.get("spec_decode_num_drafts_total", 0)
          - before.get("spec_decode_num_drafts_total", 0))
    if dd > 0:
        out["draft_accept"] = round(da / dd, 5)
        out["draft_mean_len"] = round(dd / dn, 2) if dn else None
        # 0.0 here with MTP configured means a DEAD draft head — the
        # throughput for this task is then void, not merely poor.
    return out


class NoProgressDetector:
    """Stop an agent that has stopped making progress, rather than letting it
    burn the whole step budget on reconnaissance.

    Motivation, measured: on t1 the local qwen38-mtp model reached step 31
    saying "I now have all the API details I need", then spent its remaining
    steps running more shell commands and never wrote a single .c file. Its
    last three steps were nothing but run_shell (eight calls in step 32
    alone). A global --max-steps cannot tell that apart from a model that is
    working steadily and simply needs more turns.

    "Progress" is defined narrowly and objectively: a file the task needs was
    created or changed in the working directory. Reading headers, grepping the
    tree and running make are all necessary work, but none of them is progress
    on their own — the deliverable is source code.

    Note this is a DIAGNOSTIC stop, not a verdict: the task still gets scored
    on whatever was produced, and the stop reason is recorded so a
    no_progress failure is distinguishable from a genuine step-cap exhaustion.
    """

    def __init__(self, workdir, patience=8):
        self.workdir = workdir
        self.patience = patience
        self.stale = 0
        self.steps = 0
        self.last_sig = None
        self.stopped_reason = None

    def _signature(self):
        """(name, size, mtime) of every source-ish file the agent may write."""
        sig = []
        try:
            for name in sorted(os.listdir(self.workdir)):
                if not name.endswith((".c", ".h", ".mk")) and name not in (
                        "Makefile", "makefile", "BSDmakefile"):
                    continue
                p = os.path.join(self.workdir, name)
                try:
                    st = os.stat(p)
                    sig.append((name, st.st_size, int(st.st_mtime)))
                except OSError:
                    pass
        except OSError:
            pass
        return tuple(sig)

    def __call__(self, memory_step, agent=None, **_kw):
        self.steps += 1
        cur = self._signature()
        if cur != self.last_sig:
            self.last_sig = cur
            self.stale = 0
            return
        self.stale += 1
        if self.stale < self.patience:
            return
        # Interrupt by shrinking the agent's own budget: smolagents checks
        # max_steps between steps, so this ends the loop cleanly at the next
        # boundary without raising through the middle of a tool call.
        if agent is not None and getattr(agent, "max_steps", None):
            if agent.max_steps > self.steps:
                self.stopped_reason = (
                    f"no file created or modified in {self.stale} consecutive "
                    f"steps (stopped at step {self.steps})")
                agent.max_steps = self.steps


def _build_model(model_id, api_base, api_key, backend, seed=None,
                 temperature=None):
    """Pick a smolagents model class for the endpoint.

    Two backends are needed because the endpoints differ in protocol, not just
    URL:

      openai    — llama-server (../llmsrv.sh) and anything else speaking
                  /v1/chat/completions.
      anthropic — a proxy exposing the native Anthropic API at /v1/messages.
                  OpenAIServerModel CANNOT talk to this: the corporate proxy
                  used for calibration lists 1674 OpenAI model ids and zero
                  Anthropic ones, yet serves claude-opus-4-5 fine on
                  /v1/messages. Probing /v1/models would find nothing.
    """
    from smolagents import OpenAIServerModel

    if backend == "anthropic":
        try:
            from smolagents import AnthropicModel  # newer smolagents
        except ImportError:
            AnthropicModel = None
        if AnthropicModel is not None:
            return AnthropicModel(model_id=model_id, api_key=api_key or "none",
                                  base_url=api_base)
        # Fall back to LiteLLM, which routes anthropic/* to /v1/messages.
        from smolagents import LiteLLMModel
        return LiteLLMModel(model_id=f"anthropic/{model_id}",
                            api_base=api_base, api_key=api_key or "none")

    # Pin sampling for a REPRODUCIBLE cross-host comparison.
    #
    # llmsrv.sh sets --temperature 0.6 --top-p 0.95 --top-k 20 and NO seed, so
    # llama-server defaults to seed=-1 — a fresh random seed per request. Two
    # hosts running the identical model then follow different sampling paths,
    # which is the most likely explanation for the observed t1 divergence
    # (ubuntu PASS, freebsd FAIL at the same step cap). Passing a fixed seed
    # removes that variable; temperature=0 additionally makes decoding greedy,
    # which is stricter but drifts from the production sampling the DaemonDocs
    # bench uses, so it is opt-in rather than the default.
    kw = {}
    if seed is not None:
        kw["seed"] = seed
    if temperature is not None:
        kw["temperature"] = temperature
    return OpenAIServerModel(model_id=model_id, api_base=api_base,
                             api_key=api_key or "none", **kw)


def find_kernel_debug(src_root):
    """Locate kernel.debug for the tree, so kgdb can resolve symbols.

    Both the kernel and the modules are built unstripped ("not stripped" per
    file(1)) and a kernel.debug sits beside the kernel in the obj tree, so
    backtraces are genuinely useful — worth wiring up rather than assuming a
    NODEBUG kernel has nothing.
    """
    obj = os.environ.get("MAKEOBJDIRPREFIX", "/usr/obj") + os.path.realpath(src_root)
    for root, _dirs, files in os.walk(obj):
        if "kernel.debug" in files:
            return os.path.join(root, "kernel.debug")
        if root.count(os.sep) - obj.count(os.sep) > 4:
            _dirs[:] = []
    return None


def verify(task, workdir, disk, share_dir, ko_path, panic_state=None,
           src_root="/usr/src", artifact_dir=None):
    """Build already succeeded; now load in the VM and check the marker."""
    ko_name = os.path.basename(ko_path)
    # The share IS the workdir, so the .ko the agent built is already visible
    # to the guest — nothing to copy.
    post = None
    if task["id"] == "t1-eventhandler":
        # Guarantee at least one process exit for the hook to observe.
        post = "/usr/bin/true; /bin/sh -c 'exit 0'"

    dump_dir = os.path.join(artifact_dir or workdir, "_dumps")
    runner = vmrunner.BhyveRunner(disk_img=disk, share_dir=share_dir,
                                  dump_dir=dump_dir)
    res = runner.run_module(ko_name, post_load_cmd=post)

    if res.panicked:
        # Optional debugging aid: pull the core out so debug_last_panic() can
        # work. Best-effort — a failure here must not change the verdict, which
        # is already "panic" from the console.
        if panic_state is not None and res.dump_disk:
            try:
                cores = runner.extract_core(res.dump_disk, dump_dir)
                if cores:
                    vmcore = next((c for c in cores if "vmcore" in
                                   os.path.basename(c)), cores[0])
                    panic_state["core"] = vmcore
                    panic_state["kernel_debug"] = find_kernel_debug(src_root)
                    panic_state["disk"] = res.dump_disk
            except Exception:
                pass
        return False, F_PANIC, res.console
    if res.timed_out:
        return False, F_TIMEOUT, res.console
    if res.load_failed or "FBSDQ-LOADED" not in res.console:
        return False, F_LOAD, res.console
    if not res.marker_found(task["marker_re"]):
        return False, F_WRONG, res.console
    return True, None, res.console


def run_one(task, model_id, api_base, api_key, disk, root_dir, max_steps,
            src_root, agent_user=None, backend="openai", artifact_dir=None,
            rep=1, no_progress_patience=8, seed=None, temperature=None):
    """One attempt at one task. Returns a result dict."""
    workdir = os.path.join(root_dir, task["id"])
    shutil.rmtree(workdir, ignore_errors=True)
    os.makedirs(workdir, exist_ok=True)
    if agent_user:
        # The agent writes here as an unprivileged user.
        shutil.chown(workdir, user=agent_user)

    rec = {
        "task": task["id"], "tier": task["tier"], "facility": task["facility"],
        "model": model_id, "src_root": src_root, "src_rev": src_revision(src_root),
        "passed": False, "failure_class": None, "failure_detail": None,
        "iterations": 0, "wall_s": 0.0, "shell_s": 0.0, "model_s": 0.0,
        "shell_calls": 0, "tokens_in": 0, "tokens_out": 0,
        "src_dirtied": None, "rep": rep, "seed": seed,
        "temperature": temperature,
    }

    # Tool time is tracked separately so `make` never counts as model latency.
    clock = {"seconds": 0.0, "calls": 0, "grep_seconds": 0.0}
    # Populated by verify() if the guest panics; read by the agent's
    # debug_last_panic tool. Empty means "no dump", which the tool explains.
    panic_state = {}
    progress = NoProgressDetector(workdir, patience=no_progress_patience)
    shell_timeout = task.get("timeout_s", 300)

    def _finish_timing(t0):
        rec["wall_s"] = round(time.time() - t0, 1)
        rec["shell_s"] = round(clock["seconds"], 1)
        rec["shell_calls"] = clock["calls"]
        rec["model_s"] = round(max(0.0, rec["wall_s"] - rec["shell_s"]), 1)

    m_before = endpoint_metrics(api_base)
    t0 = time.time()
    agent = None
    try:
        agent = make_agent(model_id, api_base, api_key, workdir, max_steps,
                           src_root, agent_user, shell_timeout, clock,
                           backend, panic_state, progress, seed, temperature)
        agent.run(task["prompt"].replace("/usr/src", src_root))
    except Exception as e:                      # noqa: BLE001
        msg = f"{type(e).__name__}: {e}"
        # Distinguish "the endpoint could not hold the conversation" from a
        # real harness fault: the former says something about the model's
        # deployed configuration and belongs in the results, the latter is our
        # bug. Misfiling a context overflow as "harness" hides a genuine
        # finding.
        low = msg.lower()
        if ("exceed_context_size" in low or "context size" in low
                or "context length" in low or "too many tokens" in low):
            rec["failure_class"] = F_CONTEXT
        else:
            rec["failure_class"] = F_HARNESS
        rec["failure_detail"] = msg[:300]
        _finish_timing(t0)
        _archive(rec, workdir, None, None, artifact_dir, agent)
        return rec

    _finish_timing(t0)
    rec["iterations"] = _agent_steps(agent)
    rec["stopped_early"] = progress.stopped_reason
    rec["endpoint"] = metrics_delta(m_before, endpoint_metrics(api_base))
    tin, tout = _agent_tokens(agent)
    rec["tokens_in"], rec["tokens_out"] = tin, tout

    # The tree is normally writable and the bench may be running as root, so
    # verify the agent did not modify it. A dirtied tree invalidates every
    # later repetition, so this is recorded loudly rather than ignored.
    rec["src_dirtied"] = check_src_clean(src_root)

    b = builder.build(workdir, src_root=src_root)
    if not b.ok:
        if "no .c" in (b.reason or ""):
            # Distinguish "gave up without writing code" from "ran out of
             # budget while still working" — the detector knows which.
            rec["failure_class"] = (F_NOPROGRESS if progress.stopped_reason
                                    else F_NOFILES)
        else:
            rec["failure_class"] = F_COMPILE
        rec["failure_detail"] = b.reason
        _archive(rec, workdir, b, None, artifact_dir, agent)
        return rec

    ok, fclass, console = verify(task, workdir, disk, workdir, b.ko_path,
                                 panic_state, src_root, artifact_dir)
    rec["passed"] = ok
    rec["failure_class"] = fclass
    if not ok:
        rec["failure_detail"] = _console_tail(console)

    # Keep the full artifacts next to the JSONL row. The summary line and the
    # truncated failure_detail are not enough to review a run later: to judge
    # WHY a model failed you need the C it wrote, the build log, and the guest
    # console. Small enough to keep for every attempt.
    _archive(rec, workdir, b, console, artifact_dir, agent)
    return rec


def _dump_trace(agent, path):
    """Write the agent's step-by-step reasoning to a file.

    This is the single most useful artifact when reviewing a failure: it shows
    whether the model looked in the right header, misread a signature, or never
    searched at all. smolagents renames its history attribute across versions,
    so probe rather than pin.
    """
    steps = None
    for attr in ("memory", "logs"):
        obj = getattr(agent, attr, None)
        cand = getattr(obj, "steps", obj) if obj is not None else None
        if isinstance(cand, list):
            steps = cand
            break
    if not steps:
        return False
    try:
        with open(path, "w") as fh:
            for i, st in enumerate(steps, 1):
                fh.write(f"\n{'=' * 70}\nSTEP {i}\n{'=' * 70}\n")
                for field in ("model_output", "code_action", "action_output",
                              "observations", "error", "task"):
                    val = getattr(st, field, None)
                    if val:
                        fh.write(f"\n--- {field} ---\n{str(val)[:20000]}\n")
                if not any(hasattr(st, f) for f in
                           ("model_output", "observations", "task")):
                    fh.write(f"{str(st)[:20000]}\n")
        return True
    except OSError:
        return False


def _archive(rec, workdir, build_result, console, artifact_dir, agent=None):
    """Save sources, build log, guest console and reasoning for one attempt."""
    if not artifact_dir:
        return
    dest = os.path.join(artifact_dir,
                        f"{rec['task']}-rep{rec.get('rep', 0)}")
    try:
        os.makedirs(dest, exist_ok=True)
        # Whatever the agent wrote (.c/.h/Makefile) — the primary evidence.
        for name in os.listdir(workdir):
            src = os.path.join(workdir, name)
            if os.path.isfile(src) and name.split(".")[-1] in (
                    "c", "h", "mk", "conf") or name in (
                    "Makefile", "makefile", "BSDmakefile"):
                shutil.copy2(src, os.path.join(dest, name))
        if build_result is not None and build_result.log:
            with open(os.path.join(dest, "build.log"), "w") as fh:
                fh.write(build_result.log)
        if console:
            with open(os.path.join(dest, "console.log"), "w") as fh:
                fh.write(console)
        if agent is not None:
            _dump_trace(agent, os.path.join(dest, "trace.txt"))
        rec["artifacts"] = dest
    except OSError as e:
        rec.setdefault("notes", []).append(f"archive failed: {e}")


def _agent_steps(agent):
    """smolagents exposes step history under different names across versions;
    take whichever is present rather than pinning to one."""
    for attr in ("memory", "logs"):
        obj = getattr(agent, attr, None)
        steps = getattr(obj, "steps", obj) if obj is not None else None
        if isinstance(steps, list):
            return len(steps)
    return 0


def _agent_tokens(agent):
    mon = getattr(agent, "monitor", None)
    if mon is not None:
        return (getattr(mon, "total_input_token_count", 0) or 0,
                getattr(mon, "total_output_token_count", 0) or 0)
    return 0, 0


def _console_tail(console, n=1200):
    if not console:
        return None
    return console[-n:]


def summarise(records):
    by_model = {}
    for r in records:
        m = by_model.setdefault(r["model"], [])
        m.append(r)

    print()
    print(f"{'model':<22} {'task':<18} {'pass':<7} {'iter':>5} "
          f"{'model_s':>8} {'shell_s':>8} {'tok_out':>8}  failure")
    print("-" * 104)
    for model, recs in by_model.items():
        # Group reps of the same task: with MTP enabled the same model can pass
        # or fail the same task run-to-run (speculative decoding is not
        # deterministic even with a fixed seed), so a single verdict is not a
        # result. Report the ratio and let the reader see the sample size.
        by_task = {}
        for r in recs:
            by_task.setdefault(r["task"], []).append(r)
        for task in sorted(by_task, key=lambda t: by_task[t][0]["tier"]):
            rs = by_task[task]
            npass = sum(1 for r in rs if r["passed"])
            n = len(rs)
            verdict = f"{npass}/{n}" if n > 1 else ("YES" if npass else "no")
            fails = sorted({r["failure_class"] for r in rs if r["failure_class"]})
            mean = lambda k: sum(r.get(k, 0) or 0 for r in rs) / n
            print(f"{model:<22} {task:<18} {verdict:<7} "
                  f"{mean('iterations'):>5.0f} {mean('model_s'):>8.1f} "
                  f"{mean('shell_s'):>8.1f} {mean('tokens_out'):>8.0f}  "
                  f"{','.join(fails)}")
        if any(len(v) == 1 for v in by_task.values()):
            print(f"{'':<22} (single rep: pass/fail is not reliable with MTP "
                  f"on — use --reps 3+)")
        passed = [r for r in recs if r["passed"]]
        reached = max((r["tier"] for r in passed), default=0)
        print(f"{'':<24} {'-> tier_reached':<18} {reached}")
    print()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True,
                    help="model id / alias as the endpoint reports it")
    ap.add_argument("--api-base", default="http://127.0.0.1:8080/v1")
    ap.add_argument("--api-key", default=os.environ.get("OPENAI_API_KEY", "none"))
    ap.add_argument("--backend", default="openai",
                    choices=("openai", "anthropic"),
                    help="endpoint protocol. openai: /v1/chat/completions "
                         "(llama-server via llmsrv.sh). anthropic: native "
                         "/v1/messages — required for an Anthropic proxy, "
                         "whose /v1/models listing may not mention Claude at "
                         "all yet still serve it.")
    ap.add_argument("--artifacts", default=None, metavar="DIR",
                    help="save each attempt's sources, build log, guest console "
                         "and reasoning trace here (default: alongside --out, "
                         "in artifacts/<run_id>/). Pass 'none' to disable.")
    ap.add_argument("--disk", required=True, help="bhyve guest disk image")
    ap.add_argument("--src", default="/usr/src", metavar="DIR",
                    help="FreeBSD source tree the model reads (default /usr/src). "
                         "The tasks target real kernel APIs, which move between "
                         "branches, so the tree used is recorded in the results.")
    ap.add_argument("--src-mode", default="ro",
                    choices=("ro", "zfs-clone", "shallow", "none"),
                    help="how to give this run its tree. "
                         "ro (default): nullfs read-only bind — free, and makes "
                         "mutation impossible; the tasks only read. "
                         "zfs-clone: free CoW clone, independent and writable — "
                         "use when a run needs a different revision. "
                         "shallow: git clone --depth 1 (~45 s, ~1.3 GB) for "
                         "non-ZFS trees. "
                         "none: use --src directly (shared + writable; only "
                         "safe with --agent-user).")
    ap.add_argument("--agent-user", default=None, metavar="USER",
                    help="run the agent's shell as this unprivileged user. "
                         "STRONGLY RECOMMENDED: the bench needs root for bhyve, "
                         "and without this the agent's shell is root and can "
                         "modify the source tree or anything else on the host.")
    ap.add_argument("--tasks", default="",
                    help="comma-separated task ids (default: all tiers, ascending)")
    ap.add_argument("--reps", type=int, default=1,
                    help="repetitions per task; >1 recommended, results are noisy")
    ap.add_argument("--max-steps", type=int, default=25)
    ap.add_argument("--seed", type=int, default=None,
                    help="fixed RNG seed for the endpoint's sampler. Use this "
                         "for any cross-host comparison: llmsrv.sh sets no "
                         "seed, so llama-server picks a random one per "
                         "request and two hosts running the SAME model "
                         "diverge for reasons unrelated to the OS.")
    ap.add_argument("--temperature", type=float, default=None,
                    help="override sampling temperature (llmsrv.sh serves "
                         "0.6). Pass 0 for greedy decoding — maximally "
                         "reproducible, but no longer the production sampling "
                         "the DaemonDocs bench uses.")
    ap.add_argument("--no-progress-patience", type=int, default=8,
                    metavar="N",
                    help="stop the agent after N consecutive steps that "
                         "create or modify no source file (0 disables). "
                         "Catches a model that has the knowledge but keeps "
                         "investigating instead of writing code, which a "
                         "global --max-steps cannot distinguish from working "
                         "steadily.")
    ap.add_argument("--workdir", default=None, metavar="DIR",
                    help="scratch dir for the agent (default: a per-run dir "
                         "under /tmp keyed by model + pid, so two bench "
                         "processes never share one)")
    ap.add_argument("--run-id", default=None,
                    help="label for this run, used in the workdir and recorded "
                         "in results (default: model + pid)")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__),
                                                  "results.jsonl"))
    ap.add_argument("--stop-on-fail", action="store_true",
                    help="stop climbing tiers once one fails (saves time)")
    args = ap.parse_args()

    if not os.path.exists(args.disk):
        sys.exit(f"guest image not found: {args.disk}")
    if not os.path.isdir(os.path.join(args.src, "sys")):
        sys.exit(f"not a FreeBSD source tree (no sys/): {args.src}")
    if os.geteuid() == 0 and not args.agent_user:
        print("WARNING: running as root without --agent-user. The agent's "
              "shell will be root and can modify the source tree or the host. "
              "Pass --agent-user <unprivileged user>.", file=sys.stderr)
    dirty = check_src_clean(args.src)
    if dirty:
        print(f"WARNING: source tree already dirty before the run: {dirty}",
              file=sys.stderr)

    src_v, host_v = check_abi(args.src)
    if src_v is None:
        print(f"WARNING: cannot read __FreeBSD_version from {args.src}",
              file=sys.stderr)
    elif host_v is not None and src_v != host_v:
        print(f"NOTE: source tree is __FreeBSD_version {src_v}, running host is "
              f"{host_v}.\n"
              f"      Modules built here will only load into a kernel built "
              f"from {args.src}.\n"
              f"      Make sure {args.disk} was built with "
              f"'mkimage.sh -S {args.src}' and NOT from the host's "
              f"/boot/kernel, or every task fails at kldload.",
              file=sys.stderr)

    selected = ([tasklib.by_id(t.strip()) for t in args.tasks.split(",") if t.strip()]
                if args.tasks else tasklib.tiers())

    # Parallel-safety: two bench processes (one per LLM endpoint) must not
    # share a scratch directory, or they overwrite each other's sources and
    # .ko files and both results become meaningless.
    run_id = args.run_id or f"{re.sub(r'[^A-Za-z0-9._-]', '_', args.model)}-{os.getpid()}"
    workdir = args.workdir or os.path.join("/tmp/fbsd-quality", run_id)
    os.makedirs(workdir, exist_ok=True)

    if args.artifacts == "none":
        artifact_dir = None
    else:
        artifact_dir = args.artifacts or os.path.join(
            os.path.dirname(os.path.abspath(args.out)), "artifacts", run_id)
        os.makedirs(artifact_dir, exist_ok=True)
        print(f"artifacts={artifact_dir}", file=sys.stderr)

    src_used, src_cleanup = prepare_src(args.src, args.src_mode, workdir)
    print(f"run_id={run_id}  workdir={workdir}\n"
          f"src={src_used} (mode={args.src_mode}, rev={src_revision(src_used)})",
          file=sys.stderr)

    records = []
    # Appends are line-buffered and flushed per record; O_APPEND keeps
    # concurrent writers from interleaving partial lines, so two runs may
    # safely share one results file.
    try:
        with open(args.out, "a") as out:
            for rep in range(args.reps):
                for task in selected:
                    print(f"[rep {rep+1}/{args.reps}] {args.model} :: {task['id']} "
                          f"(tier {task['tier']}, {task['facility']})",
                          file=sys.stderr, flush=True)
                    rec = run_one(task, args.model, args.api_base, args.api_key,
                                  args.disk, workdir, args.max_steps,
                                  src_used, args.agent_user, args.backend,
                                  artifact_dir, rep + 1,
                                  args.no_progress_patience, args.seed,
                                  args.temperature)
                    rec["rep"] = rep + 1
                    rec["run_id"] = run_id
                    rec["api_base"] = args.api_base
                    rec["src_mode"] = args.src_mode
                    rec["backend"] = args.backend
                    records.append(rec)
                    out.write(json.dumps(rec) + "\n")
                    out.flush()
                    print(f"    -> {'PASS' if rec['passed'] else 'FAIL'} "
                          f"({rec['failure_class'] or 'ok'}) "
                          f"iters={rec['iterations']} {rec['wall_s']}s",
                          file=sys.stderr, flush=True)
                    if rec.get("src_dirtied"):
                        print(f"    !! SOURCE TREE MODIFIED: {rec['src_dirtied']}\n"
                              f"       Later reps are contaminated. Use "
                              f"--src-mode=ro to make this impossible.",
                              file=sys.stderr, flush=True)
                    if args.stop_on_fail and not rec["passed"]:
                        break
    finally:
        # Always tear down the nullfs mount / zfs clone, including on Ctrl-C —
        # a leaked mount blocks the next run and a leaked clone wastes a
        # dataset.
        if src_cleanup:
            src_cleanup()

    summarise(records)


if __name__ == "__main__":
    main()
