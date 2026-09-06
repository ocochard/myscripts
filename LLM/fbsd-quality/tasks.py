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

# Where the agent works. The harness creates this and shares it into the guest
# over virtio-9p; the agent only ever sees a plain directory.
WORK_SUBDIR = "work"

# Marker prefix. Tasks print "FBSDQ:<something>" so verification greps for a
# string no unrelated kernel message will produce.
MARKER_PREFIX = "FBSDQ"


TASKS = [
    {
        "id": "t1-eventhandler",
        "tier": 1,
        "facility": "EVENTHANDLER / process_exit",
        # Deterministic: the module must observe a process exiting. The harness
        # spawns `/bin/true` in the guest after load, so at least one exit fires.
        "marker_re": r"FBSDQ:exit:pid=\d+",
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
        # KNOWN LOOSENESS (observed with claude-opus-4-5, 2026-09-05): the
        # marker cannot distinguish WHICH osd object type was used. That run
        # passed using osd_thread_register()/osd_thread_set() — the OSD_THREAD
        # wrappers in sys/sys/osd.h — where the prompt asks for the *process*
        # type. The API use was genuine and the round-trip real, so it is a
        # legitimate pass; but if the process type specifically matters,
        # tighten this by having the module also print something only the
        # process path can produce (e.g. the pid whose osd slot was set).
        # `0x(?:0x)?` tolerates a doubled prefix from printf("...=0x%p", v):
        # %p sets sharpflag with no width (sys/kern/subr_prf.c:838) and that
        # prepends its own "0x" (line 937). SCORING CHANGE, 2026-09-06: the
        # Qwen3.8-27B frwk-linux run was scored wrong_output for printing
        # roundtrip=0x0xdeadbeef. Its OSD logic was correct and the round-trip
        # real; only the format string was off. Rejecting that measured printf
        # pedantry rather than kernel knowledge, so it is now accepted — which
        # means that one historical row would score differently today.
        "marker_re": r"FBSDQ:osd:slot=\d+:roundtrip=0x(?:0x)?deadbeef",
        "prompt": """Write a loadable FreeBSD kernel module.

The FreeBSD kernel has a facility called OSD ("object-specific data") that lets
code attach arbitrary per-object data to certain kernel objects at runtime,
using dynamically allocated slots.

Requirements, all performed when the module loads:
- Register an OSD slot for the *process* object type.
- Store the pointer value 0xdeadbeef into that slot for the currently running
  process.
- Read the value back out of the slot for the same process.
- Print exactly one line to the kernel message buffer, where <slot> is the slot
  number you were allocated and the third field is the value you read back:

      FBSDQ:osd:slot=<slot>:roundtrip=0x<value in lowercase hex>

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
# Tier 4 is a different KIND of task from 1-3: a long-horizon build-engineering
# problem rather than "write 40 lines of kernel C". It is kept separate (opt-in
# via --tasks) because:
#
#   * it takes minutes-to-an-hour, not seconds, so it needs its own timeout and
#     would otherwise dominate a tier-1..3 sweep's wall_s
#   * it is scored on a different observable (a bootable image + how much the
#     model managed to trim), not a dmesg marker
#   * "iterations" means something different when one iteration is a 10-minute
#     make(1) run
#
# It is also the task most likely to be genuinely hard for the right reason:
# knowing that release/ has cheaper targets than `memstick`, and which
# WITHOUT_* knobs are safe, is FreeBSD build knowledge with very little
# presence in training data.
#
# NOTE the harness does NOT depend on this succeeding — mkimage.sh builds the
# bench guest deterministically. This tier asks the model to do the same job.
IMAGE_TASK = {
    # Tier 6, above the kernel-API ladder (1-5), because it is a different KIND
    # of task and because tier_reached is max(tier) over passed tasks — two
    # tasks sharing a tier number would make that metric ambiguous.
    "id": "t6-diskimage",
    "tier": 6,
    "facility": "release(7) / src.conf build trimming",
    # Scored by the harness, not a dmesg marker: does the produced image boot
    # in bhyve and reach a shell? See bench.py verify_image().
    "marker_re": r"FBSDQ-GUEST-READY \d+",
    "timeout_s": 5400,
    "prompt": """Build the smallest bootable FreeBSD disk image you can, from
the source tree at /usr/src, suitable for booting under bhyve with UEFI.

Requirements:
- The image must boot to a usable root shell on the SERIAL console (com1) with
  no interactive input — no getty prompt to answer, no boot-menu delay.
- Once booted it must be able to load a kernel module from a virtio-9p share,
  so the p9fs and virtio_p9fs kernel modules must be present and loadable.
- It must run the kernel built from this same source tree. A module built
  against /usr/src will not load into a kernel of a different
  __FreeBSD_version.
- Print the image path you produced when you are done.

Constraints that matter:
- Optimise for BUILD TIME and IMAGE SIZE, not for completeness. Nothing in the
  image needs to serve users, run a network service, or compile anything.
  Aggressively disable everything you do not need.
- There is an existing object tree from a previous build; reuse it rather than
  rebuilding from scratch if you can work out how.
- You have 64 cores available.

Read /usr/src to work out which build targets exist and which build-time
options are available — do not guess target names or option names.""",
}


def by_id(task_id):
    if task_id == IMAGE_TASK["id"]:
        return IMAGE_TASK
    for t in TASKS:
        if t["id"] == task_id:
            return t
    raise KeyError(f"no such task: {task_id}")


def tiers():
    """Tasks in ascending tier order — the ladder the bench walks."""
    return sorted(TASKS, key=lambda t: t["tier"])
