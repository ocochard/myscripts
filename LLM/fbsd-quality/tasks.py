"""Task ladder for fbsd-quality.

Each tier is a FreeBSD kernel facility with **no Linux analogue**, so a model
cannot coast on Linux recall — it has to read /usr/src. Tiers are ordered by
how much of the tree the model must actually understand.

Design rules for a tier:

  * The pass criterion must be OBJECTIVE — a marker string in dmesg, or a
    deterministic value the module computes. Never a judgement call.
  * The marker must be something the model cannot print by accident. Asking for
    "hello world" is guessable; asking it to print the *result* of an API call
    (an allocated unit number, an osd slot round-trip) is not.
  * No scaffolding: the prompt must not reveal bsd.kmod.mk, SYSDIR, or the
    header that declares the API. Finding those IS the task.
  * The prompt names the facility and the observable, nothing else.
"""

import os
import re
import subprocess

# Where the agent works. The harness creates this and shares it into the guest
# over virtio-9p; the agent only ever sees a plain directory.
WORK_SUBDIR = "work"

# Marker prefix. Tasks print "FBSDQ:<something>" so verification greps for a
# string no unrelated kernel message will produce.
MARKER_PREFIX = "FBSDQ"


# ---------------------------------------------------------------------------
# Behavioural checks (anti-hardcoding)
#
# Every marker_re below has FIXED expected values, and the prompt publishes the
# exact format — so all of them are satisfied by a `printf` of a literal, with
# no kernel API touched at all. The per-tier comments argue that faking is
# unattractive (t3's reuse=1 defeats a ++counter, t4's type/id must come from
# the callback), and those arguments are sound against a LAZY fake; none of
# them stops a deliberate one.
#
# A "behaviour" entry adds a second, format-independent question: did the
# module RESPOND to being loaded a second time? The harness loads, unloads and
# loads again at verify time (see vmrunner._guest_script(reload_cycle=True)).
# Real API use produces different output on the second load where the tier's
# semantics say it must; a hardcoded string reproduces byte-identically.
#
# A behaviour callable gets (regions, console) where regions is the console
# split per load with the dmesg replay removed, and returns (ok, detail).
# Returning ok=False fails the task with F_WRONG and detail is recorded.
#
# HONEST LIMITS, so no one reads more assurance into this than it carries:
#   * t3 is NOT defended. A fresh unrhdr legitimately returns 0,1,2,reuse=1 on
#     every load, so "identical on reload" is the CORRECT behaviour and cannot
#     distinguish a real allocator from a printf. Defending t3 needs a source
#     or symbol check, which is not implemented.
#   * t2, t3 and t4 add a host-side SYMBOL check (required_syms, checked by
#     required_syms_check before the VM boots): the built .ko must reference
#     the facility's API. Their console checks alone do not discriminate — a
#     printf-only module satisfies t2's and t4's marker AND their per-load
#     behaviour check, and only the symbol check rejects it. Verified by
#     building such a module for each tier (2026-09-11).
#   * t1 and t5 are genuinely defended by the console alone: t1 by distinct
#     PIDs, t5 because the deferred callback must fire again in the second
#     grace period. Neither needs required_syms.
# ---------------------------------------------------------------------------

def _t1_distinct_pids(regions, console):
    """t1: a real process_exit handler sees DIFFERENT pids over time.

    The handler fires per process exit, so across two loads the harness's
    post-load commands plus the shell's own children yield several distinct
    PIDs. A hardcoded `printf("FBSDQ:exit:pid=28")` yields exactly one value no
    matter how many processes exit or how often the module is loaded.

    Threshold is 2 distinct PIDs across all loads, not per load: the guest is
    /rescue-only and PID allocation there is sparse, so demanding a specific
    count per region would be brittle. Observed on a real passing module: 3
    distinct PIDs (28, 29, 30) in a single load.
    """
    pids = set()
    for reg in regions:
        pids.update(re.findall(r"FBSDQ:exit:pid=(\d+)", reg))
    # Sort NUMERICALLY (pids are captured as strings, so plain sorted() puts
    # '100' before '29') and show them all: a message that says "8 distinct
    # pids" and then lists 6 of them reads as a counting bug and costs a human
    # a round of investigation to rule out.
    shown = sorted(pids, key=int)
    if len(pids) >= 2:
        return True, f"{len(pids)} distinct pids: {shown}"
    return False, (f"only {len(pids)} distinct pid(s) {shown} across "
                   f"{len(regions)} load(s) — a real process_exit handler sees "
                   f"a different pid per exiting process, so a single repeated "
                   f"value indicates a hardcoded line rather than a handler")


def _t5_reclaim_per_load(regions, console):
    """t5: the deferred callback must fire on EVERY load.

    epoch_call() defers to a grace period that elapses once per load, so a real
    module prints inside=1 and reclaimed=1 in each region. This is the
    strongest check available anywhere in the ladder, because the observable is
    asynchronous: faking it means faking an ordering the module does not
    control.
    """
    bad = [i for i, reg in enumerate(regions, 1)
           if not re.search(r"FBSDQ:epoch:inside=1\b[\s\S]*"
                             r"FBSDQ:epoch:reclaimed=1", reg)]
    if not bad:
        return True, f"inside+reclaimed in all {len(regions)} load(s)"
    return False, (f"load(s) {bad} did not show inside=1 then reclaimed=1; a "
                   f"real epoch_call fires its callback once per load")


def required_syms_check(ko_path, required):
    """Host-side: does the built .ko actually REFERENCE the tier's API?

    Complements the console-based behaviour checks, which can only see what the
    module printed. A hardcoded printf reproduces any fixed marker byte for
    byte; it cannot reproduce an undefined reference to a function it never
    calls. `nm -u` lists exactly those: symbols the module needs the kernel to
    resolve at load time.

    Verified on this tree by building both cases (2026-09-11):
      * real allocator module -> U alloc_unr, delete_unrhdr, free_unr,
        new_unrhdr (plus module_register_init, printf)
      * printf-only module passing t3's marker -> none of the four

    WHAT THIS DOES NOT PROVE, stated plainly: a reference is not a use. A
    module could call alloc_unr(), discard the result and print literals, and
    this check would pass it. It raises the cost of faking from "one printf" to
    "call the API and then deliberately ignore it", which is no longer a lazy
    fake but a deliberate one. The ladder has no defence against a deliberate
    fake and does not claim one.

    Returns (ok, detail). ok=True when every required symbol is present.
    """
    try:
        out = subprocess.run(["nm", "-u", ko_path], capture_output=True,
                             text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as e:
        # Never fail a model for a broken host toolchain — the caller maps
        # this to a harness fault, not to wrong output.
        return None, f"could not run nm on {os.path.basename(ko_path)}: {e}"
    if out.returncode != 0:
        return None, (f"nm -u {os.path.basename(ko_path)} exited "
                      f"{out.returncode}: {out.stderr.strip()[:200]}")

    # `nm -u` lines are "<spaces>U name" / "w name"; take the last field.
    found = set()
    for line in out.stdout.splitlines():
        parts = line.split()
        if parts:
            found.add(parts[-1])
    missing = sorted(s for s in required if s not in found)
    if not missing:
        return True, f"all {len(required)} required symbols referenced"
    return False, (
        f"the built module references none of: {missing} — a module that "
        f"really used this facility would carry an undefined reference to "
        f"each. Present undefined symbols: {sorted(found)}"
        if len(missing) == len(required) else
        f"missing undefined reference(s) to {missing}; the module must "
        f"actually call the facility's API, not print the expected values")


def _marker_each_load(marker_re):
    """Weak check: the tier's marker must appear in every load region.

    Used for t2/t4, whose observables are printed once at load with fixed
    values. It catches a module that only works the first time (a real bug the
    prompts all forbid) but does NOT catch a hardcoded printf, which recurs
    just as happily. Kept because it is nearly free and closes the
    load-once-only failure mode.
    """

    def _check(regions, console):
        bad = [i for i, reg in enumerate(regions, 1)
               if not re.search(marker_re, reg)]
        if not bad:
            return True, f"marker in all {len(regions)} load(s)"
        return False, (f"marker missing from load(s) {bad} — the module must "
                       f"work on reload, not only on first load")
    return _check


TASKS = [
    {
        "id": "t1-eventhandler",
        "tier": 1,
        "facility": "EVENTHANDLER / process_exit",
        # Deterministic: the module must observe a process exiting. The harness
        # spawns `/bin/true` in the guest after load, so at least one exit fires.
        "marker_re": r"FBSDQ:exit:pid=\d+",
        # Anti-hardcoding: >=2 distinct PIDs. See _t1_distinct_pids.
        "behaviour": _t1_distinct_pids,
        "prompt": """Write a loadable FreeBSD kernel module.

Requirements:
- It must register a handler on the kernel's `process_exit` event so it is
  called every time a process exits.
- Each time the handler fires, it must print exactly one line to the kernel
  message buffer in this form, where <pid> is the PID of the exiting process:

      FBSDQ:exit:pid=<pid>

- The handler must be deregistered cleanly when the module is unloaded, so that
  unloading and reloading the module does not panic the machine.

You are writing against the FreeBSD source tree at /usr/src. Read whatever
headers you need from it to get the event-handler registration function and its
callback signature exactly right — do not guess them.

Produce the C source and whatever build file is needed so that running `make`
in your working directory produces a loadable `.ko`. Write all files into your
working directory.""",
    },
    {
        "id": "t2-osd",
        "tier": 2,
        "facility": "osd (Object-Specific Data)",
        # Round-trip proves real osd use: a model that fakes it with a global
        # cannot produce a slot number, and the value must survive set->get.
        #
        # THE TASK WAS IMPOSSIBLE UNTIL 2026-09-09. It asked for a slot on the
        # "*process* object type". FreeBSD has no such type: sys/sys/osd.h
        # defines exactly OSD_THREAD(0), OSD_JAIL(1), OSD_KHELP(2), with
        # OSD_FIRST=OSD_THREAD and OSD_LAST=OSD_KHELP. There is no OSD_PROCESS
        # and no osd_process_* wrapper anywhere in the tree.
        #
        # This scored backwards for 45+ runs and the failure is instructive:
        #   * claude-opus-4-5 substituted osd_thread_register() and commented
        #     it "the thread (process) object type" — PASS, because the marker
        #     never checked which type was used.
        #   * Qwen3.8-27B searched for the process type, reported correctly
        #     that "the tree only defines THREAD/JAIL/KHELP", refused to fake
        #     it, and burned 65 steps / 3.1 h / 105k tokens looking for a
        #     premise that does not exist — FAIL(no_progress), no .c written.
        # The bench rewarded ignoring the spec and punished reading the source,
        # which inverts what this tier exists to measure.
        #
        # An earlier note here saw Opus's substitution, called it "a legitimate
        # pass" and suggested printing a pid to tighten it. That rationalised
        # the symptom without checking whether the requested type existed —
        # the cheap check (grep OSD_ osd.h) would have settled it immediately.
        #
        # FIXED by naming the type FreeBSD actually has (thread). This is not
        # retrofitting the spec to Opus's answer: the tier's purpose is reading
        # osd.h for the wrapper names, argument order and slot lifecycle, and
        # that is unchanged. The marker now also requires the pid whose slot
        # was set, so the module has to touch the real object rather than print
        # a constant. ALL PRE-2026-09-09 t2 ROWS ARE VOID — including Opus's
        # passes; nobody keeps a score earned under the broken version.
        #
        # `0x(?:0x)?` tolerates a doubled prefix from printf("...=0x%p", v):
        # %p sets sharpflag with no width (sys/kern/subr_prf.c:838) and that
        # prepends its own "0x" (line 937). SCORING CHANGE, 2026-09-06: the
        # Qwen3.8-27B frwk-linux run was scored wrong_output for printing
        # roundtrip=0x0xdeadbeef. Its OSD logic was correct and the round-trip
        # real; only the format string was off. Rejecting that measured printf
        # pedantry rather than kernel knowledge, so it is now accepted — which
        # means that one historical row would score differently today.
        "marker_re": r"FBSDQ:osd:slot=\d+:pid=\d+:roundtrip=0x(?:0x)?deadbeef",
        # Weak (marker must recur per load) — see _marker_each_load's docstring.
        "behaviour": _marker_each_load(
            r"FBSDQ:osd:slot=\d+:pid=\d+:roundtrip=0x(?:0x)?deadbeef"),
        # The osd_thread_* names the prompt leads to are MACROS (sys/sys/osd.h
        # :73-85) that expand to the generic osd_* functions, so those are the
        # symbols that reach the object file — requiring the wrapper names
        # would fail every correct module. Verified by building one.
        #
        # osd_get is deliberately absent: osd_get_unlocked is an equally valid
        # read-back (osd.h:67) and a module using it emits only that symbol.
        # Requiring both names is not possible with a plain all-of list, and
        # requiring either alone would fail one correct variant. register+set
        # is the intersection that every genuine solution must contain.
        "required_syms": ["osd_register", "osd_set"],
        "prompt": """Write a loadable FreeBSD kernel module.

The FreeBSD kernel has a facility called OSD ("object-specific data") that lets
code attach arbitrary per-object data to certain kernel objects at runtime,
using dynamically allocated slots.

Requirements, all performed when the module loads:
- Register an OSD slot for the *thread* object type.
- Store the pointer value 0xdeadbeef into that slot for the currently running
  thread.
- Read the value back out of the slot for the same thread.
- Print exactly one line to the kernel message buffer, where <slot> is the slot
  number you were allocated, <pid> is the process id owning the current thread,
  and the last field is the value you read back:

      FBSDQ:osd:slot=<slot>:pid=<pid>:roundtrip=0x<value in lowercase hex>

- Release the slot when the module unloads, so load/unload/reload does not
  panic the machine.

You are writing against the FreeBSD source tree at /usr/src. The OSD
implementation and its public interface live in that tree — read them to get
the function names, argument order and slot lifecycle right. Do not guess.

Produce the C source and whatever build file is needed so that running `make`
in your working directory produces a loadable `.ko`. Write all files into your
working directory.""",
    },
    {
        "id": "t3-unr",
        "tier": 3,
        "facility": "subr_unit unit-number allocator",
        # Verified against sys/kern/subr_unit.c (alloc_unrl): the allocation
        # point is `x = uh->low + uh->first` and the ideal-split path bumps
        # `first`, so a fresh [0,1023] header yields 0,1,2 in order. After
        # free_unr(1), unit 1 is again the lowest free, so the 4th allocation
        # returns 1.
        #
        # The `reuse=1` field is what gives this tier its teeth: a model that
        # fakes the API with `static int counter++` prints reuse=3 and fails.
        # Only real allocator use reproduces the free-then-reuse behaviour.
        "marker_re": r"FBSDQ:unr:a=0:b=1:c=2:reuse=1",
        # NO behaviour check, deliberately. A fresh unrhdr returns
        # 0,1,2,reuse=1 on every load, so "identical output on reload" is the
        # CORRECT result here and proves nothing about whether the allocator is
        # real. Do not add _marker_each_load here and call it defended.
        #
        # Defended instead by a HOST-SIDE SYMBOL CHECK (2026-09-11), which is
        # what closes the console's blind spot: `nm -u` on the built .ko must
        # show undefined references to the allocator API. A printf-only module
        # carries none of them. See required_syms_check() for what this does
        # and does not prove — a reference is not a use.
        #
        # The alternative considered was varying the demanded sequence per run
        # so the answer is not knowable from the prompt. Rejected as the larger
        # change: the prompt must state the marker format, so it means
        # generating prompt and marker together for every tier.
        #
        # delete_unrhdr is deliberately NOT required: the prompt says "destroy
        # the allocator", and clear_unrhdr/delete_unrhdr are both defensible
        # readings. Requiring it would fail a correct module on a word choice.
        "required_syms": ["new_unrhdr", "alloc_unr", "free_unr"],
        "prompt": """Write a loadable FreeBSD kernel module.

The FreeBSD kernel has a unit-number allocator that hands out small integers
from a range and lets you return them for reuse.

Requirements, all performed when the module loads:
- Create a unit-number allocator covering the range 0 through 1023 inclusive.
- Allocate three unit numbers in a row; call them a, b and c.
- Free unit b, then allocate one more unit; call it `reuse`.
- Print exactly one line to the kernel message buffer with the four values:

      FBSDQ:unr:a=<a>:b=<b>:c=<c>:reuse=<reuse>

- Destroy the allocator when the module unloads, so load/unload/reload does not
  panic the machine.

You are writing against the FreeBSD source tree at /usr/src. Read the tree to
find the allocator's creation, allocation, free and destroy functions and their
exact signatures — do not guess them.

Produce the C source and whatever build file is needed so that running `make`
in your working directory produces a loadable `.ko`. Write all files into your
working directory.""",
    },
    {
        "id": "t4-hhook",
        "tier": 4,
        "facility": "hhook (helper hook points)",
        # WHY THIS IS HARDER THAN 1-3: the module must both PROVIDE a hook point
        # and CONSUME it, so it has to understand two halves of the API that are
        # normally written by different subsystems (hhook_head_register is
        # called by TCP/socket code; hhook_add_hook by a khelp module).
        #
        # ANTI-CHEAT, verified against sys/kern/kern_hhook.c:120 —
        #     hhk->hhk_func(hhh->hhh_type, hhh->hhh_id, hhk->hhk_udata,
        #                   ctx_data, ...)
        # the callback's type and id come from the HEAD THE KERNEL STORED, not
        # from anything the module passes at call time. So printing them from
        # inside the callback proves a real hhook_run_hooks() dispatch happened.
        # Calling the function directly would mean hand-supplying all four
        # values, and the udata pointer round-trip (0xfeedface) additionally
        # proves the registration carried the module's own data through.
        #
        # Type 2 == HHOOK_TYPE_SOCKET in sys/sys/hhook.h. The task deliberately
        # does NOT say that: finding the constant is part of the work. id=42 is
        # arbitrary and chosen to not collide with anything in-tree.
        # `0x(?:0x)?` tolerates a doubled prefix. In the kernel printf, %p sets
        # sharpflag when no width is given (sys/kern/subr_prf.c:838) and that
        # prepends its own "0x" (line 937), so the natural
        #     printf("...udata=0x%p...", udata)
        # emits udata=0x0xfeedface. That is a format slip, not a kernel-API
        # error — the pointer value is right and the hhook dispatch really
        # happened — and this bench measures kernel knowledge, not printf
        # pedantry. A local model already lost t2 to exactly this.
        "marker_re": r"FBSDQ:hhook:type=2:id=42:udata=0x(?:0x)?feedface:ran=1",
        # Weak (marker must recur per load) — see _marker_each_load's docstring.
        "behaviour": _marker_each_load(
            r"FBSDQ:hhook:type=2:id=42:udata=0x(?:0x)?feedface:ran=1"),
        # Only the two calls with no alternative spelling. hhook_add_hook and
        # hhook_remove_hook each have a _lookup twin (hhook.h:113,117) that a
        # correct module may use instead — verified by building both variants,
        # where the _lookup build emits hhook_add_hook_lookup and NOT
        # hhook_add_hook. Requiring the plain names would fail that solution.
        #
        # hhook_run_hooks is safe to require despite the HHOOKS_RUN_IF and
        # HHOOKS_RUN_LOOKUP_IF macros (hhook.h:138,150): both expand to a call
        # to it, so the symbol is emitted either way. Confirmed in the variant
        # build, which uses the macro and still shows U hhook_run_hooks.
        "required_syms": ["hhook_head_register", "hhook_run_hooks"],
        "prompt": """Write a loadable FreeBSD kernel module.

The FreeBSD kernel has a "helper hook" facility that lets one subsystem publish
a named hook point which other code can then attach callback functions to. It
is the mechanism the Khelp framework is built on.

Requirements, all performed when the module loads:
- Register a new hook point of the SOCKET hook type, with hook id 42, that is
  not virtualised (not per-vnet).
- Attach one callback function to that hook point, passing the pointer value
  0xfeedface as the callback's private data.
- Invoke the hook point so your callback actually runs.
- From INSIDE the callback, print exactly one line to the kernel message
  buffer, using the hook type and hook id the callback is handed and the
  private-data pointer it receives:

      FBSDQ:hhook:type=<type>:id=<id>:udata=0x<pointer in lowercase hex>:ran=1

- Detach the callback and deregister the hook point when the module unloads, so
  load/unload/reload does not panic the machine.

You are writing against the FreeBSD source tree at /usr/src. Read the tree for
the hook-type constants, the registration and invocation functions, the
callback's exact signature, and the struct you must fill in to attach a
callback — do not guess any of them.

Produce the C source and whatever build file is needed so that running `make`
in your working directory produces a loadable `.ko`. Write all files into your
working directory.""",
    },
    {
        "id": "t5-epoch",
        "tier": 5,
        "facility": "epoch (deferred reclamation)",
        # WHY THIS IS THE HARDEST TIER: it is the only task whose observable is
        # produced ASYNCHRONOUSLY. epoch_call() defers the callback to a grace
        # period, so the module must wait for it rather than print inline — and
        # a model that treats epoch_call() as "call this now" produces the two
        # lines in the wrong order and fails on ordering alone.
        #
        # ANTI-CHEAT: in_epoch() reads curthread's epoch record
        # (sys/kern/subr_epoch.c:938), so inside=1 cannot be produced by a
        # global flag. Note the epoch must be NON-preemptible: the preempt path
        # (in_epoch_verbose_preempt) returns 0 when THREAD_CAN_SLEEP(), which
        # would make a correct module print inside=0. The prompt therefore says
        # "does not allow sleeping", which is the observable property rather
        # than the flag name.
        #
        # The two lines must appear in this order; the runner greps for the
        # second, which cannot be reached until the grace period elapses.
        "marker_re": r"FBSDQ:epoch:inside=1\b[\s\S]*FBSDQ:epoch:reclaimed=1",
        # Strongest check in the ladder — see _t5_reclaim_per_load.
        "behaviour": _t5_reclaim_per_load,
        "prompt": """Write a loadable FreeBSD kernel module.

The FreeBSD kernel has an epoch-based reclamation facility: readers enter a
short section, and memory that readers might still be looking at is freed only
after every reader that could see it has finished.

Requirements, all performed when the module loads:
- Create your own epoch that does NOT allow a reader to sleep while inside it.
- Enter a reader section, and while inside it ask the kernel whether the
  current thread really is inside that epoch. Print exactly one line with the
  answer as 1 or 0:

      FBSDQ:epoch:inside=<1 or 0>

- Leave the reader section.
- Allocate a small object, then schedule it for DEFERRED reclamation via the
  epoch facility, so that a callback of yours runs once the grace period has
  passed. Do not free it directly.
- From INSIDE that deferred callback, free the object and print exactly one
  line:

      FBSDQ:epoch:reclaimed=1

- Make sure the deferred callback has actually run before the module finishes
  loading, so both lines are in the message buffer in the order shown above.
- Destroy the epoch when the module unloads, so load/unload/reload does not
  panic the machine.

You are writing against the FreeBSD source tree at /usr/src. Read the tree for
the epoch creation flags, the reader-section calls, the deferred-call function,
its callback signature, and how a callback recovers the object it was given —
do not guess any of them.

Produce the C source and whatever build file is needed so that running `make`
in your working directory produces a loadable `.ko`. Write all files into your
working directory.""",
    },
]


# ---------------------------------------------------------------------------
# Tier 6 — fix a REAL kernel bug.
#
# A different KIND of task from 1-5, and the first that is not "write a module
# against an API you looked up". The model is handed a command line that panics
# the kernel and must reproduce it, work out why from the panic and the source,
# patch the kernel, rebuild, and show the panic is gone. Diagnosis from
# evidence, not API discovery.
#
# Kept opt-in (name it with --tasks) because it is in a different cost class:
# every attempt needs `make buildkernel`, minutes to tens of minutes each,
# against seconds for a module. A tier-1..5 sweep would be swamped by it.
#
# THE BUG (found in the wild, BSD Router Project, 2026-09):
#   mount -t unionfs -o below onto a mount point that lives on tmpfs, then look
#   the mount point up -> panic:
#     lockmgr_xlock_hard: recursing on non recursive lockmgr
#     @ sys/fs/unionfs/union_vnops.c:2257
#   namei -> vfs_lookup -> vfs_lookup_cross_mount -> unionfs_root ->
#   _vn_lock, re-locking a vnode this thread already holds exclusively.
#
#   vfs_lookup_cross_mount() passes LK_CANRECURSE when the covered vnode
#   arrives already exclusive, but NOT on the branch that upgrades a shared
#   lock to exclusive — although it then holds it across VFS_ROOT() just the
#   same. Which branch is taken depends on the filesystem holding the mount
#   point, which is why tmpfs panics and UFS does not.
#
# REQUIRES the pinned tree (see README): sys/kern/vfs_lookup.c must still lack
# the LK_CANRECURSE on the upgrade branch, and the guest kernel must be built
# from that same tree. On a tree where the fix has landed there is no bug and
# the task is unpassable-by-construction.
#
# SCORING IS BEHAVIOURAL, NOT DIFF-MATCHING. A reference patch exists and is
# developer-reviewed, but the reporter's own analysis says allowing the
# recursion may be papering over an invariant that belongs in unionfs instead
# (which locks the covered vnode in unionfs_lock() because in `below` mode
# um_uppervp IS the covered vnode, and which does not set MNTK_LOOKUP_SHARED so
# the crossing is always forced exclusive). A model that fixes it there could
# be MORE right. So the patch is a reference, not an answer key — exactly the
# role claude-opus-4-5 plays for tiers 1-5.
#
# ANTI-CHEAT is mandatory here, unlike tiers 1-5. "The reproducer stops
# panicking" is trivially satisfiable by breaking the feature: return an error
# from unionfs_mount, delete the `below` handling, refuse to load the module.
# The marker chain therefore requires the mount to SUCCEED, the lookup to
# return real directory content, and the unmount to be clean — and the harness
# additionally re-checks the documented differential (a non-`below` unionfs
# mount must still work) so a fix cannot pass by disabling unionfs.
BUGFIX_TASK = {
    "id": "t6-unionfs-panic",
    "tier": 6,
    "facility": "vfs_lookup_cross_mount / unionfs lock recursion",
    # Ordered chain, all three required:
    #   STEP1-OK - the mount still works (not disabled to dodge the panic)
    #   STEP2-OK - the lookup that used to panic now returns real content
    #   STEP3-OK - teardown is clean, so the fix did not leak or wedge
    # Scored by verify_kernel_fix(), NOT by verify()'s marker match: this tier
    # never builds a .ko, so it takes its own build -> image -> boot -> hidden
    # regression path. The string below is what that path requires, printed by
    # regress-t6.sh (baked into the guest image, never visible to the model).
    # Kept as marker_re for consistency with the other tiers, but note that a
    # panicking kernel prints NO verdict at all, so absence of this string is
    # the failure condition rather than presence of any "FAIL".
    "marker_re": r"FBSDQ:regress:VERDICT:PASS",
    "timeout_s": 5400,
    "needs_kernel_build": True,
    "repro_script": "repro-t6.sh",
    # repro.sh is copied into the agent's workdir by run_one(); the agent runs
    # it on a disposable VM via the test_kernel tool, which builds the current
    # tree and boots it. Deliberately NOT told which subsystem, which file, or
    # what the panic says — reproducing and localising it is the task.
    "prompt": """The script repro.sh in your working directory panics a
machine.

Fix the FreeBSD kernel so it does not, by patching the source tree at /usr/src
and rebuilding. Every operation the script performs must still work afterwards
— making the panic go away by disabling something does not count.

Use the test_kernel tool to run it: that builds the kernel from the tree and
runs the script on a disposable test machine, so crashing it is safe.

The tree is unmodified upstream FreeBSD at a real commit. Nothing has been
planted or injected for this exercise, so there is no diff-against-pristine
shortcut — the bug is genuine and has to be found by reading the code.""",
}


def by_id(task_id):
    if task_id == BUGFIX_TASK["id"]:
        return BUGFIX_TASK
    for t in TASKS:
        if t["id"] == task_id:
            return t
    raise KeyError(f"no such task: {task_id}")


def tiers():
    """Tasks in ascending tier order — the ladder the bench walks."""
    return sorted(TASKS, key=lambda t: t["tier"])
