"""Host-side build of whatever the agent wrote.

Deliberately dumb: run `make` in the agent's working directory and report what
happened. The harness supplies NO Makefile — discovering bsd.kmod.mk and SYSDIR
is part of the task, so a missing or broken build file is a real result
(failure_class="compile"), not a harness problem.

Building on the host rather than in the guest keeps the VM image minimal (no
toolchain, no /usr/src) and catches compile errors in seconds without booting.
"""

import os
import re
import subprocess
import glob

BUILD_TIMEOUT = 300  # a kernel module is small; 5 min is already generous


class BuildResult:
    def __init__(self, ok, ko_path, stdout, stderr, reason=None):
        self.ok = ok
        self.ko_path = ko_path
        self.stdout = stdout
        self.stderr = stderr
        self.reason = reason  # short human-readable why-it-failed

    @property
    def log(self):
        return (self.stdout or "") + (self.stderr or "")


def _find_ko(workdir):
    """A .ko anywhere under workdir. bsd.kmod.mk may build in-place or in a
    subdir depending on how the agent wrote the Makefile."""
    hits = glob.glob(os.path.join(workdir, "**", "*.ko"), recursive=True)
    # Prefer the shallowest, then newest — an agent may leave stale artifacts.
    hits.sort(key=lambda p: (p.count(os.sep), -os.path.getmtime(p)))
    return hits[0] if hits else None


def _sources_present(workdir):
    return bool(glob.glob(os.path.join(workdir, "*.c")))


def _makefile_present(workdir):
    return any(
        os.path.exists(os.path.join(workdir, n))
        for n in ("Makefile", "makefile", "BSDmakefile")
    )


def build(workdir, src_root="/usr/src", env_extra=None):
    """Build in workdir. Returns BuildResult.

    Cleans stale .ko first so a previous iteration's artifact can never be
    mistaken for this iteration's output — that would silently turn a compile
    failure into a false pass.
    """
    for stale in glob.glob(os.path.join(workdir, "**", "*.ko"), recursive=True):
        try:
            os.unlink(stale)
        except OSError:
            pass

    if not _sources_present(workdir):
        return BuildResult(False, None, "", "", reason="no .c file written")
    if not _makefile_present(workdir):
        return BuildResult(False, None, "", "",
                           reason="no Makefile written (agent must supply one)")

    env = dict(os.environ)
    # Keep the build hermetic-ish and quiet. SYSDIR is deliberately NOT set:
    # if the agent's Makefile needs it, the agent has to say so.
    env.update({
        "__MAKE_CONF": "/dev/null",
        "SRCCONF": "/dev/null",
        "MAKEOBJDIRPREFIX": os.path.join(workdir, "obj"),
    })
    if env_extra:
        env.update(env_extra)

    try:
        p = subprocess.run(
            ["make", "-C", workdir],
            capture_output=True, text=True, timeout=BUILD_TIMEOUT, env=env,
        )
    except subprocess.TimeoutExpired as e:
        return BuildResult(False, None, e.stdout or "", e.stderr or "",
                           reason=f"build timed out after {BUILD_TIMEOUT}s")

    ko = _find_ko(workdir)
    if p.returncode != 0:
        return BuildResult(False, ko, p.stdout, p.stderr,
                           reason=_summarise_error(p.stdout + p.stderr))
    if not ko:
        return BuildResult(False, None, p.stdout, p.stderr,
                           reason="make succeeded but produced no .ko")
    return BuildResult(True, ko, p.stdout, p.stderr)


_ERR_PATTERNS = [
    (r"don't know how to make (\S+)", "missing build dependency: {0}"),
    (r"cannot open (\S*bsd\.kmod\.mk)", "bsd.kmod.mk not found: {0}"),
    (r"(\S+\.[ch]):(\d+):\d+: error: (.+)", "{0}:{1}: {2}"),
    (r"error: (.+)", "{0}"),
    (r"undefined (?:reference|symbol)[: ]+(\S+)", "undefined symbol: {0}"),
]


def _summarise_error(log):
    """First meaningful compiler/make error, for the per-iteration record.

    The full log is kept separately; this is the one line that goes in the
    JSONL so failure modes can be counted across runs.
    """
    for pat, fmt in _ERR_PATTERNS:
        m = re.search(pat, log)
        if m:
            try:
                return fmt.format(*m.groups())
            except (IndexError, KeyError):
                return m.group(0)
    tail = [ln for ln in log.strip().splitlines() if ln.strip()]
    return tail[-1][:200] if tail else "build failed with no output"
