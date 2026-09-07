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
import zlib
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


# Appended to every task prompt. This is ENVIRONMENT information, not
# scaffolding: it says nothing about the kernel task (no bsd.kmod.mk, no SYSDIR,
# no header names), only how to use this harness. tasks.py already states such
# facts ("source tree at /usr/src", "64 cores available").
#
# Measured need: `import os` was denied in 8 of 13 runs, hitting EVERY model
# including claude-opus-4-5. smolagents' CodeAgent sandboxes imports and its
# default allowlist is
#   collections datetime itertools math queue random re stat statistics time
#   unicodedata
# so `os` — the obvious way to list a directory — raises InterpreterError and
# the step is lost. Models then fall back to run_shell, which works, so this
# cost steps without changing any outcome.
#
# `os` is deliberately NOT added to additional_authorized_imports: bench.py
# runs as root for bhyve, and in-process os.* calls would execute as root,
# bypassing the --agent-user privilege separation that run_shell gets by
# dropping to an unprivileged user via su. Telling the model the rule is free;
# widening the sandbox is not.
ENV_NOTE = """

Notes on this environment (not hints about the task):
- Your Python runs in a sandbox that allows only these imports: collections,
  datetime, itertools, math, queue, random, re, stat, statistics, time,
  unicodedata. `import os`, `pathlib`, `glob` and `subprocess` will fail.
  To inspect or manipulate the filesystem use the run_shell tool (ls, find,
  grep, cat) or the read_file / write_file / grep_src tools.
- One code block must finish within its time budget, so avoid piling several
  slow commands into a single block. A tree-wide grep of the kernel source is
  slow: scope it to a subdirectory, or run it as its own step.
"""


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


def detect_agent_type(api_base, backend):
    """Pick the smolagents agent class the ENDPOINT'S MODEL is trained for.

    THE ROOT CAUSE THIS EXISTS TO FIX. bench.py hardcoded CodeAgent from its
    first commit — not as a decision between two options, but as the class
    smolagents leads with. That encodes an assumption about post-training that
    nothing validated per model, and it silently mismatched Flash-Next:

      * CodeAgent describes tools IN THE PROMPT as Python and sends NO `tools`
        array, so llama.cpp's Qwen3-Coder parser (auto-selected from the
        template, chat.cpp:3596) has nothing to attach to.
      * Flash-Next answers with a CANONICAL Qwen3-Coder tool call anyway —
        <tool_call><function=name><parameter=key>value — which then passes
        through as plain text and is rejected for lacking <code>.

    The model was behaving correctly; the harness asked the wrong question. It
    cost 13 of 42 steps on t6, and hid for five tiers because on short tasks
    the model complied often enough — the failure only compounds as context
    grows and the trained habit outweighs the system prompt.

    Detection uses the same three tokens llama.cpp keys on, read from the
    server's own advertised chat template. That is deliberate: if llama.cpp
    selects its Qwen3-Coder parser for this template, the model emits that
    format, and CodeAgent is the wrong class for it.

    Returns "toolcalling" or "code". Falls back to "code" whenever the
    template cannot be read (an Anthropic proxy exposes no /props, and Opus
    handles CodeAgent perfectly well), so this can only ever help.
    """
    if backend != "openai":
        return "code"
    root = api_base.rstrip("/")
    for suffix in ("/v1", "/v1/"):
        if root.endswith(suffix):
            root = root[: -len(suffix)]
            break
    try:
        r = subprocess.run(["curl", "-s", "-m", "10", f"{root}/props"],
                           capture_output=True, text=True, timeout=15)
        tmpl = json.loads(r.stdout).get("chat_template") or ""
    except Exception:                                # noqa: BLE001
        return "code"
    if all(tok in tmpl for tok in ("<tool_call>", "<function=", "<parameter=")):
        return "toolcalling"
    return "code"


def build_env():
    """Extra environment for the agent's shell: disable ccache, or {}.

    This host sets WITH_CCACHE_BUILD=yes globally in /etc/make.conf, so any
    `make buildkernel` the agent runs picks ccache up automatically. That is a
    real speedup (the cache here runs ~43 % hits) and worth keeping — but it
    has a documented failure mode on this machine that would silently corrupt
    a bug-fixing tier.

    The trap: ccache's default hash does not capture the kernel build-id, so
    after a kernel rebuild it can serve a module .o cached against an OLDER
    kernel. The resulting .ko then fails to load with

        KLD foo.ko: depends on kernel - not available or version mismatch

    Confirmed on this host 2026-05-26: a stale /boot/kernel/nmdm.ko of 28376
    bytes (cached February object) against 16064 bytes for a fresh
    non-cached build, and `buildkernel && installkernel` did NOT clear it.

    Why that is fatal specifically for the unionfs tier: the model patches
    sys/kern/vfs_lookup.c, rebuilds, and gets a kernel whose changed file
    recompiled but whose unionfs.ko came from cache. The reproducer still
    panics, and the model concludes ITS CORRECT PATCH DID NOT WORK. That is a
    false negative indistinguishable from a wrong fix — it would measure the
    harness's plumbing, not the model, and quietly poison the tier's results.

    CCACHE_BASEDIR folds the build root into the hash and CCACHE_NOHASHDIR
    stops the cwd being hashed away, so objects built against different trees
    or kernels stop colliding. Set for the agent's own shell, because that is
    where `make buildkernel` actually runs (builder.build() sets
    __MAKE_CONF=/dev/null and so never sees ccache at all).

    DECISION: ccache is DISABLED for bench builds rather than made safe.

    CCACHE_BASEDIR + CCACHE_NOHASHDIR should fold the build root into the hash
    and stop the collisions, and that is what this function did at first. But
    "should" is the problem: it was never validated by a real
    patch -> rebuild -> reproducer cycle, and the failure it guards against is
    SILENT and INDISTINGUISHABLE from a wrong answer. A tier that scores a
    correct patch as failed, for reasons in the build cache, produces
    confidently wrong results — far worse than a slower build. The speed was
    never the point of this bench either: model latency dominates
    (shell_s is 0-6 % of run time on tiers 1-3).

    WITH_CCACHE_BUILD=no is passed to the agent's shell, which is where
    `make buildkernel` runs. builder.build() already sets
    __MAKE_CONF=/dev/null and so never saw ccache at all.

    Returns {} when ccache is not installed, so a host without it gets no
    pointless CCACHE_* / WITH_CCACHE_BUILD noise in its logs. If you want the
    speed back, prove the BASEDIR/NOHASHDIR variant first: patch
    sys/kern/vfs_lookup.c, rebuild, and confirm the reproducer's behaviour
    actually changes.
    """
    if not shutil.which("ccache"):
        return {}
    return {
        # Belt and braces: the make knob stops bsd.*.mk routing the compiler
        # through ccache, and CCACHE_DISABLE stops ccache itself if something
        # invokes it directly anyway.
        #
        # It MUST be WITHOUT_CCACHE_BUILD=1, not WITH_CCACHE_BUILD=no. Read
        # share/mk/bsd.mkopt.mk:110-120: for a default-no option, `WITH_X=no`
        # is still *defined*, and with WITHOUT_X unset the .if takes the
        # MK_X:=yes branch — so WITH_CCACHE_BUILD=no ENABLES ccache. The build
        # even warns ("Use WITHOUT_CCACHE_BUILD=1 instead of
        # WITH_CCACHE_BUILD=no") and a buildkernel run with the wrong spelling
        # was observed still invoking /usr/local/bin/ccache. Only
        # CCACHE_DISABLE saved it, which is exactly why both are set.
        "WITHOUT_CCACHE_BUILD": "1",
        "CCACHE_DISABLE": "1",
    }


_HOST_KLD_RE = None


def _loads_module_on_host(command):
    """Return the offending fragment if `command` would (un)load a module in
    the HOST kernel, else None.

    Measured motivation: across every run in this repo's logs, ALL 53 uses of
    sudo were host module manipulation — kldload 21, kldstat 12, kldunload 10,
    dmesg 9, strings 1. Not one was a legitimate need. The harness already
    loads the module in a throwaway guest and hands back its console, so a
    model doing it on the host is testing its work in the wrong kernel.

    Why refuse rather than merely warn: a module built from --src carries the
    TREE's __FreeBSD_version, and this host routinely runs a slightly older
    kernel, so kldload is usually rejected with "depends on kernel - not
    available or version mismatch". That rejection is luck, not safety. When
    the versions match, an agent-written module loads into the running host
    kernel. The unionfs bug tier makes that concrete: its whole point is code
    that panics a kernel, and the guest is disposable while the host is not.

    kldstat is included, which is NOT obvious — it is read-only and cannot
    hurt the host. It is refused because every one of its 12 uses in the logs
    was checking whether the model's OWN module had loaded into the host
    kernel, either in the same command as a kldload or immediately after one
    (`kldstat | grep fbsdq`, `kldstat -q -n fbsdq.ko && echo STILL LOADED`).
    Allowing it would leave the model a probe that answers the wrong question:
    with kldload refused, `kldstat | grep fbsdq` finds nothing and reads as
    "my module is broken" when it was never meant to load there. Refusing it
    with a pointer to the guest console is more useful than a truthful but
    misleading empty result.

    dmesg is included for the same reason, and it is the most misleading of
    the three. All 9 of its uses grep the HOST message buffer for the model's
    own marker (`dmesg | grep FBSDQ:exit:pid=`, "dmesg tail after failed
    load"), always alongside a kldload. With the load refused,
    `dmesg | grep -ac 'FBSDQ:exit:pid='` returns 0 — which reads as "my
    event handler never fired", pointing the model at its handler logic when
    the real answer is that the module never ran in this kernel. A refusal
    naming the guest console is strictly more useful than that.

    This is not a sandbox (see the comment in run_shell: agent_user can sudo,
    so real containment needs a sudoers rule); it removes the foot-guns that
    models demonstrably reach for.
    """
    global _HOST_KLD_RE
    if _HOST_KLD_RE is None:
        # Anchored at a word start but require the command position: a bare
        # mention inside a path or filename (grep kldload sys/kern/...) should
        # not be refused, so require the token to be followed by end-of-string,
        # whitespace-then-a-flag/argument, or a shell separator — and NOT by a
        # path-like argument that names the source tree.
        _HOST_KLD_RE = re.compile(r"(?:^|[;&|]\s*|\bsudo\s+(?:-n\s+)?)"
                                  r"(kldload|kldunload|kldstat|dmesg)\b")
    m = _HOST_KLD_RE.search(command)
    return m.group(1) if m else None


def _src_dirty_set(src_root):
    """Set of `git status --porcelain` lines for the tree, or None on error."""
    r = subprocess.run(["git", "-C", src_root, "status", "--porcelain"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    return {ln.strip() for ln in r.stdout.splitlines() if ln.strip()}


def check_src_clean(src_root, baseline=None):
    """Did THIS RUN modify the source tree? Returns a description, or None.

    `baseline` is the dirty-set captured before the run started; anything in it
    is pre-existing and not attributable to the agent. Pass it always — without
    it this reports the user's own untracked files as damage.

    Why that matters (bug fixed 2026-09-06): /usr/src here carries two
    untracked files of the user's, sys/amd64/conf/MDR1 and MDROOT, dated well
    before any bench run. Every task therefore ended with

        !! SOURCE TREE MODIFIED: 2 modified path(s) ...
           Later reps are contaminated. Use --src-mode=ro to make this
           impossible.

    on all 16 runs — while ALREADY running --src-mode=ro, which nullfs-mounts
    the tree read-only so the agent physically cannot write to it. A warning
    that fires on every run and recommends the mode already in use trains the
    reader to ignore it, which would mask a real mutation. Diffing against the
    baseline makes a report mean something.

    Caveat for parallel runs: the tree is SHARED state. If two bench processes
    point at the same --src, this cannot attribute a modification to one of
    them — either may report the other's damage. That is still the right
    behaviour (both runs are contaminated), but give each endpoint its own
    tree if you need clean attribution.
    """
    now = _src_dirty_set(src_root)
    if now is None:
        return None
    new = now - (baseline or set())
    if not new:
        return None
    out = sorted(new)
    return f"{len(out)} modified path(s), e.g. " + \
           "; ".join(d[:60] for d in out[:3])


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

    mode="auto" (the default) resolves to zfs-clone when src_root is on ZFS,
    else ro. Rationale: a CoW clone gives EVERY tier an independent writable
    tree for 63 ms and ~0 bytes, which removes a class of harness bug — the t6
    tier needed two special cases (write_file's workdir check and the
    _writes_into_src tripwire) purely because the default tree was read-only —
    and stops any tier contaminating another. It falls back to ro rather than
    exiting so the bench still runs on a host whose tree is not on ZFS, where
    an explicit --src-mode=zfs-clone is a hard error.
    """
    if mode == "auto":
        mode = "zfs-clone" if _zfs_dataset_for(src_root) else "ro"

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
               seed=None, temperature=None, snippet_timeout=180,
               kernel_tier=False, artifact_dir=None,
               agent_type="code"):
    """A smolagents CodeAgent with filesystem + shell tools, rooted at workdir.

    Tool surface is deliberately small and generic: read/write files, run a
    shell command, grep the source tree. Nothing bhyve- or p9fs-aware — the
    model is being tested on kernel knowledge, not on our plumbing.

    src_root is exposed to the agent read-only via read_file/grep_src so the
    same harness can bench against 16-CURRENT, a stable branch, or a pinned
    checkout without editing the tasks.
    """
    from smolagents import CodeAgent, ToolCallingAgent, tool

    # Shared with run_one so it can subtract tool time from wall_s.
    _shell_clock = shell_clock if shell_clock is not None else {
        "seconds": 0.0, "calls": 0, "grep_seconds": 0.0}
    # Filled in by verify() when a panic leaves a core; debug_last_panic reads
    # it. Empty on the first iteration, which is why the tool explains itself
    # rather than erroring.
    _panic_state = panic_state if panic_state is not None else {}
    # Only the kernel-patching tier gets test_kernel; for tiers 1-5 the
    # harness loads the module itself and a VM tool would be noise.
    _kernel_tier = kernel_tier

    @tool
    def write_file(path: str, content: str) -> str:
        """Write a file into the working directory.

        Args:
            path: Filename relative to the working directory.
            content: Full file contents.
        """
        full = os.path.realpath(os.path.join(workdir, path))
        # On a kernel-patching tier the deliverable IS an edit to the source
        # tree, so the tree is a legitimate write target alongside the
        # workdir. Without this the model cannot do the task at all: in the
        # v7 calibration all three write_file calls to
        # sys/fs/unionfs/union_vnops.c were rejected as "path escapes the
        # working directory", and its `patch` fallback was then refused by the
        # _writes_into_src tripwire, so it was structurally unable to patch
        # anything and was interrupted for making no progress.
        allowed = [os.path.realpath(workdir)]
        if _kernel_tier:
            allowed.append(os.path.realpath(src_root))
        if not any(full.startswith(a) for a in allowed):
            return ("ERROR: path escapes the working directory"
                    + (" and the source tree" if _kernel_tier else ""))
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
    def test_kernel(script: str = "repro.sh") -> str:
        """Build the kernel from the source tree and run a script on a test
        machine booted with it. Use this to reproduce a crash, and again after
        changing the source, to see whether your change worked.

        The test machine is disposable and separate from this one: crashing it
        is safe and expected. Its console output, including any panic and
        backtrace, is returned to you. If it panics, the crash dump is kept and
        debug_last_panic can inspect it.

        Building takes about a minute. Nothing you do here can affect the
        machine you are working on.

        Args:
            script: name of a shell script in your working directory to run on
                the test machine. Defaults to "repro.sh".
        """
        if not _kernel_tier:
            return ("ERROR: this task does not use a test kernel; build a "
                    "module and the harness will load it for you.")
        path = os.path.join(workdir, os.path.basename(script))
        if not os.path.exists(path):
            return f"ERROR: no such script in your working directory: {script}"
        _t = time.time()
        try:
            out = _run_candidate_kernel(src_root, path, panic_state,
                                        artifact_dir or workdir)
        finally:
            _shell_clock["seconds"] += time.time() - _t
        return out

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
        # The tripwire protects tiers 1-5, where touching the tree is always a
        # mistake. On a kernel-patching tier it is the POINT, so it is off.
        if not _kernel_tier and _writes_into_src(command, src_root):
            return (f"ERROR: refusing to run a command that writes into the "
                    f"source tree ({src_root}). Build in your working "
                    f"directory instead; the tree is for reading only.")
        bad_kld = _loads_module_on_host(command)
        if bad_kld:
            return (f"ERROR: refusing `{bad_kld}` — that would load or unload "
                    f"a kernel module in the HOST kernel, not the test VM. "
                    f"The harness loads your module in a throwaway bhyve "
                    f"guest and returns its console output; you do not need "
                    f"to (and must not) load it here. Just build the .ko.")
        argv = command
        use_shell = True
        if agent_user:
            # Drop the agent's shell to an unprivileged user. The bench itself
            # needs root for bhyve; the agent's own commands do not.
            #
            # NOT a security boundary, despite what an earlier version of this
            # comment claimed. If agent_user can sudo, the agent is one hop
            # from root and nothing here stops it: the only command filter is
            # _writes_into_src(), which matches redirects/cp/rm against the
            # SOURCE TREE path, so `sudo kldload ./foo.ko` matches nothing and
            # passes straight through. Observed in real runs — models ran
            # `sudo kldload` on the HOST and it succeeded; one loaded a module
            # built from the tree into the running host kernel, refused only
            # because the ABI happened to mismatch. With a matching ABI that is
            # agent-written kernel code in the host kernel.
            #
            # This is deliberate as far as it goes: some tasks legitimately
            # need privilege (building a guest image needs mdconfig/mount), so
            # the fix is a sudoers rule scoping agent_user to the commands the
            # bench actually needs — not removing sudo. Until that exists,
            # treat every run as able to touch the host.
            argv = ["su", "-m", agent_user, "-c", command]
            use_shell = False
        # ccache correctness, not speed: see build_env(). `su -m` preserves
        # the environment, so these reach the agent's own `make`. Empty dict
        # on a host without ccache, so nothing is exported there.
        shell_env = dict(os.environ)
        shell_env.update(build_env())
        try:
            p = subprocess.run(argv, shell=use_shell, cwd=workdir,
                               capture_output=True, text=True,
                               timeout=shell_timeout, env=shell_env)
            out = (p.stdout or "") + (p.stderr or "")
            return f"exit={p.returncode}\n{out[-20_000:]}"
        except subprocess.TimeoutExpired:
            return f"ERROR: command timed out after {shell_timeout}s"
        finally:
            _shell_clock["seconds"] += time.time() - _t_shell

    model = _build_model(model_id, api_base, api_key, backend, seed,
                         temperature)
    # snippet_timeout raises smolagents' own executor budget, which defaults to
    # local_python_executor.MAX_EXECUTION_TIME_SECONDS = 30 and bounds the whole
    # <code> block. 30 s is too tight HERE for a reason specific to this bench:
    # the tasks require exploring /usr/src, and one legitimate `grep -r` over
    # sys/ (~90k files) can exceed it on a cold cache — costing a step for work
    # that was correct, just slow.
    #
    # This is NOT about model or GPU speed. Inference happens before the
    # snippet runs and is not covered by this budget: measured steps of 87 s,
    # 163 s and 80 s never tripped the 30 s limit, and shell_s is 0.0-6.3% of
    # total run time (on one t3, 7.3 s of shell against 9059 s of inference).
    # Raising this cannot speed up a slow endpoint.
    #
    # Passed via executor_kwargs, which agents.create_python_executor merges
    # into LocalPythonExecutor(**...) — a supported parameter, not a patch.
    _tools = [write_file, read_file, grep_src, run_shell, debug_last_panic]
    if kernel_tier:
        _tools.append(test_kernel)
    if agent_type == "toolcalling":
        # ToolCallingAgent asks for STRUCTURED TOOL CALLS instead of Python in
        # <code> tags. Use it for a model whose post-training pulls it toward
        # native tool-call syntax: Flash-Next lost 13 of 42 t6 steps to
        # AgentParsingError, every one of them emitting <tool_call>...</tool_call>
        # and closing with </code> while never opening one — half-complying with
        # the CodeAgent contract while reaching for the form it was trained on.
        #
        # Widening code_block_tags to accept <tool_call> does NOT fix that: the
        # payload inside is <function=...><parameter=...> XML, not Python, so it
        # parses and then fails at execution. Tested.
        #
        # NOT comparable with CodeAgent rows: one tool call per step by
        # construction, so iteration counts mean something different. Record it
        # as its own row, never as a replacement.
        #
        # executor_kwargs/snippet_timeout do not apply — there is no Python
        # executor. The tools and the no-progress detector transfer unchanged.
        return ToolCallingAgent(tools=_tools, model=model,
                                max_steps=max_steps, add_base_tools=False,
                                step_callbacks=([progress] if progress else None))
    return CodeAgent(tools=_tools,
                     model=model, max_steps=max_steps, add_base_tools=False,
                     executor_kwargs={"timeout_seconds": snippet_timeout},
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

    def __init__(self, workdir, patience=40, src_root=None):
        self.workdir = workdir
        self.patience = patience
        # For a kernel-patching tier the deliverable is a MODIFIED SOURCE TREE,
        # not a file in the workdir. Without this the detector watched the
        # wrong directory: in the first t6 calibration the model was editing
        # sys/kern/vfs_lookup.c and was interrupted at step 41 for "no file
        # created or modified in 40 consecutive steps".
        self.src_root = src_root
        self.stale = 0
        self.steps = 0
        self.last_sig = None
        self.stopped_reason = None
        # Steps lost to a malformed reply or a blown snippet budget rather
        # than to the task itself. See _count_error for why these are counted.
        self.parse_errors = 0
        self.no_toolcall = 0
        self.timeout_errors = 0
        self.sandbox_errors = 0
        self.step_errors = 0

    def _signature(self):
        """(name, size, mtime) of every source-ish file the agent may write.

        With src_root set, the tree's dirty set is included: `git status
        --porcelain` is cheap (it does not walk 116k files the way an os.walk
        would) and changes the moment a source file is edited, so patching the
        kernel counts as progress.
        """
        sig = []
        if self.src_root:
            try:
                r = subprocess.run(["git", "-C", self.src_root, "status",
                                    "--porcelain"], capture_output=True,
                                   text=True, timeout=60)
                if r.returncode == 0:
                    # zlib.crc32, not hash(): PYTHONHASHSEED is randomised per
                    # process, so hash() would make signatures
                    # incomparable across a restart.
                    sig.append(("__tree__", len(r.stdout),
                                zlib.crc32(r.stdout.encode())))
            except Exception:                        # noqa: BLE001
                pass
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

    def _count_error(self, memory_step):
        """Count steps that failed before any code ran.

        A CodeAgent step is only useful if the model wrapped its Python in
        <code>...</code>. Some models answer in their own native tool-call
        syntax instead — observed with Qwen3.8-Flash-Next under --jinja, which
        emits

            <tool_call><function=code>print(run_shell(...))</function></tool_call>

        (sometimes with a stray </parameter>). smolagents matches
        <code>(.*?)</code>, finds nothing, and raises AgentParsingError; the
        error is fed back as an observation and the model retries.

        This matters for the numbers, not for correctness: the Python inside
        those replies was valid every time, so the model knew the answer and
        lost the step to the envelope. Left uncounted it silently inflates
        iterations / wall_s / tokens_in and makes a format mismatch look like
        weaker capability. Counted separately, a reader can subtract it.

        Typed on AgentParsingError rather than grepped from the message, so a
        reworded smolagents error does not silently stop counting.

        timeout_errors counts a second, unrelated way a step dies before
        producing anything: smolagents' own
        local_python_executor.MAX_EXECUTION_TIME_SECONDS = 30, which bounds the
        WHOLE <code> snippet. That is far tighter than this bench's
        shell_timeout (300 s, per subprocess), so on a slow snippet the
        smolagents limit always fires first and the bench's own limit never
        gets a chance. Observed when a model put a tree-wide grep of
        /usr/src/sys and a second command in one snippet: the grep alone ate
        the 30 s. Not a model error in the same sense as a parse failure — the
        code was valid and simply too slow — so it is counted apart from both
        parse_errors and the task's own outcome.
        """
        err = getattr(memory_step, "error", None)
        if err is None:
            return
        self.step_errors += 1
        name = type(err).__name__
        msg = str(err)
        if name == "AgentParsingError":
            # smolagents raises AgentParsingError for BOTH agent classes, but
            # the two mean different things and a single counter hides which
            # harness is mismatched to which model. Split them:
            #
            #   no_toolcall — the reply carried NO structured tool call, and
            #     the text fallback then found no JSON blob either. Named for
            #     what it MEANS, not for the exception: agents.py only calls
            #     parse_tool_calls() when chat_message.tool_calls is empty, so
            #     this fires when the model reasoned or narrated instead of
            #     committing to a call. It is NOT a malformed call and NOT a
            #     broken parser — probed with a real tools array the same
            #     endpoint returns finish_reason=tool_calls with a clean
            #     structured call, so the machinery works.
            #
            #   parse_errors — CodeAgent could not find <code>...</code>.
            #     Observed with Qwen-template models emitting native
            #     <tool_call><function=...> instead, closing </code> without
            #     ever opening one.
            #
            # A model failing BOTH ways is telling you something different
            # from one that fails only under the agent class it was not
            # trained for, and that is the distinction worth having when a new
            # model is dropped in.
            if "tool call" in msg.lower() or "json blob" in msg.lower():
                self.no_toolcall += 1
            else:
                self.parse_errors += 1
        elif "maximum execution time" in str(err):
            # Matched on the message: smolagents raises this as a generic
            # execution error, so there is no dedicated class to type on.
            self.timeout_errors += 1
        elif "InterpreterError" in str(err) or "unauthorized import" in str(err):
            # Sandbox denial (usually `import os`). ENV_NOTE now warns about
            # this, so a nonzero count means the model ignored the note —
            # itself worth knowing.
            self.sandbox_errors += 1

    def __call__(self, memory_step, agent=None, **_kw):
        self.steps += 1
        self._count_error(memory_step)
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
        # Interrupt via agent.interrupt(), which sets interrupt_switch —
        # checked by _run_stream at the top of EVERY iteration.
        #
        # BUG FIXED 2026-09-06: this used to do `agent.max_steps = self.steps`,
        # which never worked. MultiStepAgent.run() evaluates
        #     max_steps = max_steps or self.max_steps
        # ONCE and then loops on that LOCAL variable in _run_stream, so
        # lowering the attribute mid-run is not observed. The detector fired
        # and recorded a stopped_reason, the agent carried on regardless, and
        # 26 of 38 result rows claimed an early stop while demonstrably
        # running past it (e.g. "stopped at step 9" on a run that reached 62).
        # Only --max-steps ever bounded anything, and one row was classed
        # failure_class=no_progress purely because the reason string was set.
        #
        # interrupt() raises AgentError("Agent interrupted.") out of run(),
        # which run_one() catches; stopped_reason is what distinguishes that
        # from a real harness fault, so it must stay set before interrupting.
        if agent is not None and hasattr(agent, "interrupt"):
            self.stopped_reason = (
                f"no file created or modified in {self.stale} consecutive "
                f"steps (stopped at step {self.steps})")
            agent.interrupt()


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


HERE = os.path.dirname(os.path.abspath(__file__))


def _build_candidate_kernel(src_root, extra_root_files=None, artifact_dir=None):
    """buildkernel from src_root, then bake a bootable image from it.

    Returns (image_path, None) or (None, error_string). Shared by the agent's
    test_kernel tool and by verify_kernel_fix so the model is scored on exactly
    the pipeline it was iterating against — if these diverged, a model could
    pass its own testing and fail scoring for reasons that are ours.
    """
    obj = os.environ.get("MAKEOBJDIRPREFIX", "/usr/obj") + os.path.realpath(src_root)
    kern_dir = os.path.join(obj, "amd64.amd64/sys/GENERIC")
    env = dict(os.environ)
    env.update({"__MAKE_CONF": "/dev/null", "SRCCONF": "/dev/null"})
    env.update(build_env())
    try:
        p = subprocess.run(["make", "-C", src_root, "-j",
                            str(os.cpu_count() or 8),
                            "buildkernel", "KERNCONF=GENERIC"],
                           capture_output=True, text=True, timeout=3600,
                           env=env)
    except subprocess.TimeoutExpired:
        return None, "buildkernel timed out after 3600s"
    if p.returncode != 0:
        tail = ((p.stdout or "") + (p.stderr or ""))[-2500:]
        return None, f"buildkernel failed:\n{tail}"

    img = os.path.join(artifact_dir or "/tmp", "t6-candidate.img")
    ienv = dict(env)
    # unionfs only. mkimage.sh ships just p9fs/virtio_* by default, so unionfs
    # would otherwise be silently absent (kldload -n exits 0 on a missing
    # module, so nothing would report it). tmpfs is deliberately NOT listed:
    # it is compiled into GENERIC, and shipping tmpfs.ko makes the guest try to
    # load a duplicate —
    #   module_register: cannot register tmpfs from tmpfs.ko; already loaded
    #   Module tmpfs failed to register: 17
    # which is harmless (EEXIST) but looks alarming on a console the model
    # reads, and could cost it steps chasing a non-problem.
    ienv["EXTRA_MODULES"] = "unionfs"
    if extra_root_files:
        ienv["EXTRA_ROOT_FILES"] = extra_root_files
    try:
        m = subprocess.run([os.path.join(HERE, "mkimage.sh"),
                            "-o", img, "-s", "2g", "-S", src_root,
                            "-k", kern_dir],
                           capture_output=True, text=True, timeout=1800,
                           env=ienv)
    except subprocess.TimeoutExpired:
        return None, "mkimage.sh timed out"
    if m.returncode != 0:
        return None, f"mkimage.sh failed: {(m.stderr or '')[-500:]}"
    return img, None


def _run_candidate_kernel(src_root, host_script, panic_state, artifact_dir):
    """Agent-facing: build the kernel, boot it, run the agent's own script.

    The script comes from the agent's workdir and is copied into the image, so
    it is the agent's to change — unlike the hidden regression, which the agent
    never sees and which only verify_kernel_fix runs.
    """
    img, err = _build_candidate_kernel(src_root,
                                       extra_root_files=host_script,
                                       artifact_dir=artifact_dir)
    if err:
        return f"BUILD FAILED\n{err}"
    dump_dir = os.path.join(artifact_dir, "_dumps")
    runner = vmrunner.BhyveRunner(disk_img=img, share_dir=dump_dir,
                                  dump_dir=dump_dir)
    res = runner.run_script("/root/" + os.path.basename(host_script))
    if res.panicked and panic_state is not None and res.dump_disk:
        try:
            core, kern = runner.extract_core(res.dump_disk, src_root)
            if core:
                panic_state["core"] = core
                panic_state["kernel"] = kern
        except Exception:                            # noqa: BLE001
            pass
    console = res.console or ""
    # A boot that produced NOTHING must never be reported as success. In the
    # first t6 calibration this returned "test machine completed" with an empty
    # console on every attempt, so the model was told its reproducer ran fine
    # and never saw the panic it was asked to fix — while the same image, driven
    # by hand, booted and panicked correctly. Require the guest's own readiness
    # handshake as proof it got as far as a shell.
    if "FBSDQ-GUEST-READY" not in console:
        return ("ERROR: the test machine did not reach a shell — no "
                f"FBSDQ-GUEST-READY handshake in {len(console)} bytes of "
                f"console. This is a harness fault, not your code.\n"
                f"{console[-4000:]}")
    tail = console[-12000:]
    status = ("PANICKED" if res.panicked else
              "TIMED OUT" if res.timed_out else "completed")
    return f"test machine {status}\n{tail}"


def verify_kernel_fix(task, src_root, artifact_dir=None, jobs=None):
    """Score the t6 bug-fix tier: rebuild the model's kernel, boot it, run the
    HIDDEN regression, and require its verdict.

    Returns (passed, failure_class, detail).

    Three deliberate properties:

    * The model patched the TREE, not a workdir, so there is no .ko to build
      and builder.build() does not apply — that is why this is a separate path
      rather than a branch inside verify().

    * The regression script is baked INTO the image (mkimage.sh copies it to
      /root/regress.sh) and is never placed on the p9fs share. If it were
      shared, the agent could read it and satisfy it narrowly, which is the
      whole reason it exists. run_script() mounts no share at all.

    * A panic during regression is a FAIL, not a harness error: the model's
      kernel crashed. The script's contract makes that unambiguous — a
      panicking kernel prints no VERDICT line, so absence of VERDICT:PASS is
      the failure condition rather than the presence of any "FAIL" string.

    Validated end to end before any model ran it: the reference patch yields
    5/5 OK + VERDICT:PASS, and the unpatched control panics at
    union_vnops.c:2257 with zero VERDICT lines.
    """
    regress = os.path.join(HERE, "regress-t6.sh")
    if not os.path.exists(regress):
        return False, F_HARNESS, f"missing regression script: {regress}"

    # Same builder the agent's test_kernel tool uses, so the model is scored on
    # exactly the pipeline it iterated against.
    img, err = _build_candidate_kernel(src_root, extra_root_files=regress,
                                       artifact_dir=artifact_dir)
    if err:
        cls = F_COMPILE if "buildkernel" in err else F_HARNESS
        return False, cls, err

    # Boot it and run the hidden regression.
    dump_dir = os.path.join(artifact_dir or "/tmp", "_dumps")
    runner = vmrunner.BhyveRunner(disk_img=img, share_dir=dump_dir,
                                  dump_dir=dump_dir)
    res = runner.run_script("/root/regress.sh")
    console = res.console or ""

    if "FBSDQ:regress:VERDICT:PASS" in console:
        return True, None, None
    if res.panicked:
        return False, F_PANIC, _console_tail(console)
    if "SETUP:MISSING-FS" in console or "VERDICT:FAIL:setup" in console:
        # The guest could not run the test at all — our fault, not the model's.
        return False, F_HARNESS, _console_tail(console)
    if "FBSDQ-GUEST-READY" not in console:
        # Never score a model on a VM that never booted. The first t6
        # calibration returned F_WRONG with an EMPTY failure_detail for exactly
        # this reason, which reads as "the fix did not work" when in fact
        # nothing was ever tested.
        return False, F_HARNESS, (
            f"test VM never reached a shell (no FBSDQ-GUEST-READY in "
            f"{len(console)} bytes) — harness fault, verdict not attributable "
            f"to the model\n{console[-2000:]}")
    if res.timed_out:
        return False, F_TIMEOUT, _console_tail(console)
    return False, F_WRONG, _console_tail(console)


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
            rep=1, no_progress_patience=40, seed=None, temperature=None,
            snippet_timeout=180, src_baseline=None, agent_type="code"):
    """One attempt at one task. Returns a result dict."""
    workdir = os.path.join(root_dir, task["id"])
    shutil.rmtree(workdir, ignore_errors=True)
    os.makedirs(workdir, exist_ok=True)
    if agent_user:
        # The agent writes here as an unprivileged user.
        shutil.chown(workdir, user=agent_user)

    # The bug-fix tier hands the agent a reproducer to run. It goes in the
    # WORKDIR (the agent's own directory) — unlike the hidden regression, which
    # is baked into the guest image precisely so the agent cannot read it.
    if task.get("repro_script"):
        src_repro = os.path.join(HERE, task["repro_script"])
        if os.path.exists(src_repro):
            dst = os.path.join(workdir, "repro.sh")
            shutil.copyfile(src_repro, dst)
            os.chmod(dst, 0o755)
            if agent_user:
                shutil.chown(dst, user=agent_user)

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
    progress = NoProgressDetector(
        workdir, patience=no_progress_patience,
        # Only the kernel-patching tier: for tiers 1-5 the deliverable is in
        # the workdir and watching the tree would call a stale change progress.
        src_root=src_root if task.get("needs_kernel_build") else None)
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
                           backend, panic_state, progress, seed, temperature,
                           snippet_timeout,
                           bool(task.get("needs_kernel_build")), artifact_dir,
                           agent_type)
        agent.run(task["prompt"].replace("/usr/src", src_root) + ENV_NOTE)
    except Exception as e:                      # noqa: BLE001
        msg = f"{type(e).__name__}: {e}"
        # Distinguish "the endpoint could not hold the conversation" from a
        # real harness fault: the former says something about the model's
        # deployed configuration and belongs in the results, the latter is our
        # bug. Misfiling a context overflow as "harness" hides a genuine
        # finding.
        low = msg.lower()
        # Our own no-progress detector calls agent.interrupt(), which raises
        # out of run(). That is neither a harness fault nor a verdict: fall
        # THROUGH to the build + VM steps so whatever the model did write is
        # still scored. A model that produced a working module and then idled
        # must be judged on the module, not on the interrupt.
        if not (progress.stopped_reason and "interrupt" in low):
            if ("exceed_context_size" in low or "context size" in low
                    or "context length" in low or "too many tokens" in low):
                rec["failure_class"] = F_CONTEXT
            else:
                rec["failure_class"] = F_HARNESS
            rec["failure_detail"] = msg[:300]
            _finish_timing(t0)
            # Also on the failure path: a run that died mid-flight is exactly
            # where knowing how many steps went to retries matters.
            rec["parse_errors"] = progress.parse_errors
            rec["timeout_errors"] = progress.timeout_errors
            rec["sandbox_errors"] = progress.sandbox_errors
            rec["step_errors"] = progress.step_errors
            _archive(rec, workdir, None, None, artifact_dir, agent)
            return rec

    _finish_timing(t0)
    rec["iterations"] = _agent_steps(agent)
    rec["stopped_early"] = progress.stopped_reason
    # Steps the model lost to a malformed reply or a blown snippet budget.
    # Subtract from iterations to compare capability rather than format
    # compliance under this harness.
    rec["parse_errors"] = progress.parse_errors
    rec["no_toolcall"] = progress.no_toolcall
    rec["timeout_errors"] = progress.timeout_errors
    rec["sandbox_errors"] = progress.sandbox_errors
    rec["step_errors"] = progress.step_errors
    rec["endpoint"] = metrics_delta(m_before, endpoint_metrics(api_base))
    tin, tout = _agent_tokens(agent)
    rec["tokens_in"], rec["tokens_out"] = tin, tout

    # The tree is normally writable and the bench may be running as root, so
    # verify the agent did not modify it. A dirtied tree invalidates every
    # later repetition, so this is recorded loudly rather than ignored.
    # src_baseline excludes dirt that was already there before the run — see
    # check_src_clean(). On a kernel-patching tier a modified tree is the
    # DELIVERABLE, not damage, so record it as the model's diff instead of
    # flagging it: reporting "SOURCE TREE MODIFIED" for the patch the task
    # asked for would be the same cried-wolf problem the baseline fixed.
    if task.get("needs_kernel_build"):
        rec["src_patched"] = check_src_clean(src_root, src_baseline)
        rec["src_dirtied"] = None
    else:
        rec["src_dirtied"] = check_src_clean(src_root, src_baseline)

    # The bug-fix tier patches the SOURCE TREE, not the workdir: there is no
    # .c and no Makefile for builder.build() to find, so it takes its own
    # build -> image -> boot -> hidden-regression path instead.
    if task.get("needs_kernel_build"):
        ok, fclass, detail = verify_kernel_fix(task, src_root, artifact_dir)
        rec["passed"] = ok
        rec["failure_class"] = fclass
        rec["failure_detail"] = detail
        _archive(rec, workdir, None, detail, artifact_dir, agent)
        return rec

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

    NOT a token-accounting record — do not sum it to audit tokens_out. It keeps
    one final `model_output` per RETAINED memory step, so it omits retried calls
    and anything memory trimming dropped. Summing this trace for one task gave
    ~7 400 tokens against a true 54 750 (7.4x), which looked like a metering bug
    and was not: tokens_out matches the endpoint's tokens_predicted exactly on
    every recorded task, and tokens_predicted equals n_decode + accepted drafts
    to within 1%, so it counts DELIVERED output, not rejected drafts. For token
    questions use rec["tokens_out"] or the endpoint's /metrics.
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
          f"{'reparse':>7} {'model_s':>8} {'shell_s':>8} {'tok_out':>8} "
          f"{'tok/dec':>8}  failure")
    print("-" * 122)
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
            # tok/dec = delivered output tokens per decode step. With MTP on
            # this is the speculation payoff (>1 means drafts are landing);
            # 1.00 means every token cost a full decode. Blank for endpoints
            # that expose no /metrics, e.g. the Anthropic proxy.
            dec = sum((r.get("endpoint") or {}).get("n_decode") or 0 for r in rs)
            out = sum(r.get("tokens_out", 0) or 0 for r in rs)
            tpd = f"{out / dec:.2f}" if dec else "-"
            print(f"{model:<22} {task:<18} {verdict:<7} "
                  f"{mean('iterations'):>5.0f} {mean('parse_errors'):>7.0f} "
                  f"{mean('model_s'):>8.1f} "
                  f"{mean('shell_s'):>8.1f} {mean('tokens_out'):>8.0f} "
                  f"{tpd:>8}  {','.join(fails)}")
        if any(len(v) == 1 for v in by_task.values()):
            print(f"{'':<22} (single rep: pass/fail is not reliable with MTP "
                  f"on — use --reps 3+)")
        # 'reparse' = steps where the model's reply was not wrapped in
        # <code>...</code>, so smolagents raised before running anything. The
        # Python inside is usually fine; the step is lost to the envelope. A
        # nonzero column means iterations/model_s/tok_out overstate the real
        # cost of solving the task by that many steps.
        if any((r.get("parse_errors") or 0) for r in recs):
            print(f"{'':<22} (reparse > 0: reply not in <code> tags — native "
                  f"tool-call syntax; retried steps inflate iter/model_s)")
        if any((r.get("no_toolcall") or 0) for r in recs):
            n = sum((r.get("no_toolcall") or 0) for r in recs)
            print(f"{'':<22} ({n} step(s) produced NO tool call at all — "
                  f"the model reasoned instead of acting)")
        if any((r.get("timeout_errors") or 0) for r in recs):
            n = sum((r.get("timeout_errors") or 0) for r in recs)
            print(f"{'':<22} ({n} step(s) hit the per-snippet time budget "
                  f"(--snippet-timeout); code was valid but too slow)")
        if any((r.get("sandbox_errors") or 0) for r in recs):
            n = sum((r.get("sandbox_errors") or 0) for r in recs)
            print(f"{'':<22} ({n} step(s) lost to a denied import despite the "
                  f"prompt naming the allowlist)")
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
    ap.add_argument("--src-mode", default="auto",
                    choices=("auto", "ro", "zfs-clone", "shallow", "none"),
                    help="how to give this run its tree. "
                         "auto (default): zfs-clone when --src is on ZFS, else "
                         "ro — so every tier gets an independent WRITABLE tree "
                         "where that is free, without breaking a non-ZFS host. "
                         "zfs-clone: CoW clone, independent and writable; "
                         "measured at 63 ms and ~0 bytes on this host, against "
                         "45 s and 1.3 GB for a git clone of the same tree, "
                         "which is why ZFS is the mechanism rather than git. "
                         "ro: nullfs read-only bind — also free, and the only "
                         "mode where mutation is IMPOSSIBLE rather than merely "
                         "detected after the fact; use it to hold a tier-1..5 "
                         "run to reading only. "
                         "shallow: git clone --depth 1 for non-ZFS trees that "
                         "must be writable. "
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
    ap.add_argument("--agent-type", default="auto",
                    choices=("auto", "code", "toolcalling"),
                    help="smolagents agent class. auto (default): read the "
                         "endpoint's chat template and pick toolcalling when "
                         "it advertises Qwen3-Coder XML tool calls, else code "
                         "— so a tool-call-trained model is not silently asked "
                         "to write Python in <code> tags, which cost "
                         "Flash-Next 13 of 42 steps on t6. "
                         "code: the model "
                         "writes Python in <code> tags. toolcalling: the model "
                         "emits structured tool calls instead — use it for a "
                         "model whose training pulls it toward native "
                         "tool-call syntax, which under CodeAgent shows up as "
                         "parse_errors (Flash-Next lost 13 of 42 t6 steps that "
                         "way). NOT comparable with code rows: one tool call "
                         "per step by construction, so iteration counts differ "
                         "in kind. Record it as a separate row.")
    ap.add_argument("--snippet-timeout", type=int, default=180, metavar="SEC",
                    help="wall-clock budget for ONE <code> snippet "
                         "(smolagents' executor limit, default there is 30 s). "
                         "Raised because a legitimate grep -r over /usr/src/sys "
                         "can exceed 30 s on a cold cache and lose a step for "
                         "correct-but-slow work. This does NOT bound model "
                         "inference — that happens before the snippet runs — so "
                         "raising it cannot compensate for a slow endpoint; "
                         "shell time is 0-6%% of a run. Per-subprocess limits "
                         "come from each task's timeout_s instead.")
    ap.add_argument("--no-progress-patience", type=int, default=40,
                    metavar="N",
                    help="stop the agent after N consecutive steps that "
                         "create or modify no source file (0 disables). "
                         "Catches a model that has the knowledge but keeps "
                         "investigating instead of writing code, which a "
                         "global --max-steps cannot distinguish from working "
                         "steadily. Default 40, set from measurement: in runs "
                         "that PASSED, the first source file appeared at step "
                         "22 (opus t4), 14 (opus t5) and 29 (flash t4), so "
                         "reading 20-30 steps of kernel source before writing "
                         "anything is normal work on the harder tiers, not a "
                         "stall. The old default of 8 was set while the "
                         "detector was inert (it mutated agent.max_steps, "
                         "which smolagents ignores) and so was never "
                         "calibrated; once the detector actually worked it cut "
                         "every tier-4/5 run at 10 iterations, including a "
                         "configuration that had passed at 62.")
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
    # Snapshot pre-existing dirt ONCE, before any task runs, and diff every
    # later check against it so only this run's damage is reported.
    if args.agent_type == "auto":
        args.agent_type = detect_agent_type(args.api_base, args.backend)
        print(f"agent-type=auto -> {args.agent_type} "
              f"(from the endpoint's chat template)", file=sys.stderr)

    src_baseline = _src_dirty_set(args.src) or set()
    if src_baseline:
        preview = "; ".join(sorted(src_baseline)[:3])
        print(f"NOTE: source tree already has {len(src_baseline)} modified "
              f"path(s) before the run, e.g. {preview[:120]}\n"
              f"      These are excluded from per-task src_dirtied reporting.",
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

    # A tier that patches the kernel needs a WRITABLE tree. The default
    # --src-mode=ro nullfs-mounts it read-only, so the model's first edit
    # fails and the tier becomes unpassable-by-construction — which would read
    # as a model failure, not a misconfiguration. Refuse up front rather than
    # burn an hour of buildkernel discovering it.
    #
    # Why not a writable unionfs overlay on the read-only tree, which would
    # cost only the changed files and make the model's diff trivial to extract
    # from the upper layer? Because the t6 bug IS a unionfs bug, and THIS HOST
    # RUNS THE BUGGY KERNEL (bigone is 1600020; sys/kern/vfs_lookup.c has no
    # LK_CANRECURSE on the upgrade branch). Hosting the source tree on unionfs
    # would drive the panicking code path on the machine running the bench,
    # with the panic's occurrence depending on whether the mount point sits on
    # tmpfs — precisely the fragile distinction under test. The model also
    # patches and rebuilds that code mid-run, so the filesystem holding its
    # sources could change semantics underneath it, and a build failure would
    # be impossible to attribute between a bad patch and a broken overlay.
    # zfs-clone gives the same independence for ~8 KB with none of that.
    if any(t.get("needs_kernel_build") for t in selected):
        if args.src_mode in ("ro", "none"):
            sys.exit(
                f"--tasks includes a kernel-patching tier, which must modify "
                f"the source tree, but --src-mode={args.src_mode} "
                f"{'mounts it read-only' if args.src_mode == 'ro' else 'shares the real tree'}.\n"
                f"Use --src-mode=zfs-clone (free CoW, independent, writable) "
                f"with --src pointing at a tree that still HAS the bug.")

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
                                  args.temperature, args.snippet_timeout,
                                  src_baseline, args.agent_type)
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
