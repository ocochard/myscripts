"""Disposable bhyve VM that loads a .ko and reports what the kernel said.

Why a VM at all: a bad kernel module panics or wedges the machine. That is a
LEGITIMATE benchmark result (the model wrote unsafe code), so it must be
survivable and attributable rather than taking the host down.

Why p9fs instead of injecting the .ko into a disk image: the agent's working
directory is shared straight into the guest, so there is no image rebuild per
iteration. The guest needs no toolchain and no /usr/src — it only kldloads.

The guest is driven entirely over the serial console. That is deliberate: no
sshd, no network, no guest agent to install or keep in sync. A console
expect-loop is uglier than ssh but has far fewer moving parts, and works on a
guest that is little more than a kernel plus /rescue.
"""

import os
import re
import shutil
import signal
import subprocess
import time
import uuid

CONSOLE_IDLE_TIMEOUT = 20    # s of silence before we stop reading
BOOT_TIMEOUT = 180           # s to reach a usable prompt
SHARE_TAG = "fbsdqbench"     # 9p share name the guest mounts
GUEST_MNT = "/mnt"

# Every VM this module creates is named with this prefix plus a random suffix.
# _destroy() refuses anything not matching, so a parallel bench run — or any
# unrelated bhyve VM on the host — can never be torn down by us.
VM_PREFIX = "fbsdq-"

# A panic prints these; treat any as fatal-and-attributable.
PANIC_RE = re.compile(
    r"panic:|Fatal trap \d+|page fault while in kernel mode|"
    r"KDB: enter:|Sleeping thread .* owns a non-sleepable lock",
    re.I,
)


class VMResult:
    def __init__(self, console, panicked, timed_out, load_failed, reason=None,
                 dump_disk=None):
        self.console = console
        self.panicked = panicked
        self.timed_out = timed_out
        self.load_failed = load_failed
        self.reason = reason
        # Path to a preserved disk image holding a kernel dump, when the guest
        # panicked and keep_dumps was on. None otherwise.
        self.dump_disk = dump_disk

    def marker_found(self, marker_re):
        return re.search(marker_re, self.console) is not None


def _require_root():
    if os.geteuid() != 0:
        raise PermissionError(
            "bhyve needs root: run the bench under sudo, or pre-create the VM"
        )


def _destroy(vmname):
    """Destroy one of OUR VMs. Refuses any other name.

    Two bench runs (e.g. one per LLM endpoint) share the host, and the host may
    have unrelated bhyve guests running. Destroying by anything other than a
    name we generated would take down someone else's VM.
    """
    if not vmname.startswith(VM_PREFIX):
        raise ValueError(
            f"refusing to destroy {vmname!r}: not a {VM_PREFIX}* VM created by "
            f"this bench"
        )
    subprocess.run(["bhyvectl", "--destroy", f"--vm={vmname}"],
                   capture_output=True, text=True)


class BhyveRunner:
    """One VM per module test. Named uniquely so a leaked VM from a previous
    run can never be reused with stale state."""

    def __init__(self, disk_img, share_dir, memory="512M", cpus=1,
                 bootrom=None, keep_dumps=True, dump_dir=None):
        self.disk_img = disk_img
        self.share_dir = share_dir
        self.memory = memory
        self.cpus = cpus
        # On panic, keep the disk (and therefore the kernel dump on its swap
        # slice) instead of deleting the clone. Optional: nothing requires it.
        self.keep_dumps = keep_dumps
        self.dump_dir = dump_dir or os.path.join(share_dir, "_dumps")
        # UEFI is the least surprising boot path on 16-CURRENT; grub-bhyve and
        # userboot both add dependencies we do not need.
        self.bootrom = bootrom or "/usr/local/share/uefi-firmware/BHYVE_UEFI.fd"

    def _argv(self, vmname, disk):
        return [
            "bhyve",
            "-c", str(self.cpus),
            "-m", self.memory,
            "-A", "-H", "-P",
            "-l", f"bootrom,{self.bootrom}",
            "-s", "0,hostbridge",
            "-s", f"1,virtio-blk,{disk}",
            # ro=1: the guest only needs to READ the .ko the host built. This
            # also stops a misbehaving guest from corrupting the agent's
            # working directory mid-run.
            "-s", f"2,virtio-9p,{SHARE_TAG}={self.share_dir},ro",
            "-s", "31,lpc",
            "-l", "com1,stdio",
            vmname,
        ]

    def _private_disk(self, vmname):
        """Give this VM its own copy of the base image.

        Two bench processes booting the same virtio-blk file would corrupt it,
        so parallel runs need isolation. A ZFS clone is near-free; otherwise
        fall back to a plain copy.

        Returns (path, needs_cleanup_kind).
        """
        base_ds = _zfs_dataset_for(self.disk_img)
        if base_ds:
            snap = f"{base_ds}@fbsdq-base"
            # One shared read-only base snapshot; each VM clones from it.
            subprocess.run(["zfs", "snapshot", snap],
                           capture_output=True, text=True)  # ok if it exists
            clone = f"{base_ds}-{vmname}"
            r = subprocess.run(["zfs", "clone", snap, clone],
                               capture_output=True, text=True)
            if r.returncode == 0:
                mp = subprocess.run(["zfs", "get", "-H", "-o", "value",
                                     "mountpoint", clone],
                                    capture_output=True, text=True).stdout.strip()
                rel = os.path.relpath(self.disk_img,
                                      _zfs_mountpoint(base_ds) or "/")
                cand = os.path.join(mp, rel) if mp and mp != "-" else None
                if cand and os.path.exists(cand):
                    return cand, ("zfs", clone)
                # Clone exists but we could not locate the image inside it.
                subprocess.run(["zfs", "destroy", "-r", clone],
                               capture_output=True, text=True)

        tmp = f"{self.disk_img}.{vmname}"
        try:
            shutil.copyfile(self.disk_img, tmp)
        except OSError:
            return None, None
        return tmp, ("file", tmp)

    def _release_disk(self, disk, cleanup):
        if not cleanup:
            return
        kind, target = cleanup
        if kind == "zfs":
            subprocess.run(["zfs", "destroy", "-r", target],
                           capture_output=True, text=True)
        elif kind == "file":
            try:
                os.unlink(target)
            except OSError:
                pass

    def _preserve_disk(self, disk, vmname):
        """Keep a panicked guest's disk so its kernel dump survives.

        The dump lives on the swap slice inside the image, so preserving the
        image preserves the core. Returns the kept path, or None.

        The image is copied out rather than left as a ZFS clone: a clone holds
        a dependency on the base snapshot, which would block later cleanup and
        accumulate silently across runs.
        """
        try:
            os.makedirs(self.dump_dir, exist_ok=True)
            dest = os.path.join(self.dump_dir, f"{vmname}.img")
            shutil.copyfile(disk, dest)
            return dest
        except OSError:
            return None

    def extract_core(self, dump_disk, out_dir):
        """Pull /var/crash out of a preserved guest image onto the host.

        Runs on the host because the guest cannot debug itself: /rescue has
        savecore(8) but no kgdb, and there is no /lib for a dynamic one. The
        guest's rc already ran savecore into /var/crash on the reboot after the
        panic, so this only has to mount and copy.

        Returns a list of extracted file paths (possibly empty).
        """
        if not dump_disk or not os.path.exists(dump_disk):
            return []
        md = None
        mnt = None
        found = []
        try:
            r = subprocess.run(["mdconfig", "-a", "-t", "vnode", "-f", dump_disk],
                               capture_output=True, text=True)
            if r.returncode != 0:
                return []
            md = r.stdout.strip()
            mnt = os.path.join(out_dir, f"_mnt-{md}")
            os.makedirs(mnt, exist_ok=True)
            # p3 is the root filesystem (p1 ESP, p2 swap/dump) — see mkimage.sh.
            if subprocess.run(["mount", "-o", "ro", f"/dev/{md}p3", mnt],
                              capture_output=True, text=True).returncode != 0:
                return []
            crash = os.path.join(mnt, "var/crash")
            if os.path.isdir(crash):
                for name in os.listdir(crash):
                    src = os.path.join(crash, name)
                    if os.path.isfile(src):
                        dst = os.path.join(out_dir, name)
                        shutil.copyfile(src, dst)
                        found.append(dst)
        except OSError:
            pass
        finally:
            if mnt:
                subprocess.run(["umount", mnt], capture_output=True, text=True)
                try:
                    os.rmdir(mnt)
                except OSError:
                    pass
            if md:
                subprocess.run(["mdconfig", "-du", md], capture_output=True,
                               text=True)
        return found


    def run_module(self, ko_name, post_load_cmd=None):
        """Boot, mount the share, kldload ko_name, run an optional command,
        dump dmesg, power off. Returns VMResult.

        ko_name is a bare filename inside the share, not a host path — the
        guest sees it under GUEST_MNT.

        Safe to run concurrently with other bench processes: the VM name is
        unique, and the disk image is copied per-VM so two guests never write
        the same virtio-blk backing file (which would corrupt both).
        """
        _require_root()
        if not os.path.exists(self.bootrom):
            return VMResult("", False, False, False,
                            reason=f"bootrom missing: {self.bootrom}")

        vmname = f"{VM_PREFIX}{uuid.uuid4().hex[:8]}"
        script = self._guest_script(ko_name, post_load_cmd)

        disk, disk_tmp = self._private_disk(vmname)
        if disk is None:
            return VMResult("", False, False, False,
                            reason="could not create a private disk copy")

        try:
            # BINARY mode, not text=True. _drive() sets the pipe non-blocking,
            # and a non-blocking *text* stream raises
            #   TypeError: can't concat NoneType to bytes
            # inside the codec when no data is ready. Read bytes and decode
            # explicitly instead. (Console output is also not guaranteed to be
            # valid UTF-8 — a panic can emit partial/garbled bytes — so decode
            # with errors="replace".)
            p = subprocess.Popen(
                self._argv(vmname, disk),
                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, bufsize=0,
            )
        except FileNotFoundError as e:
            self._release_disk(disk, disk_tmp)
            return VMResult("", False, False, False, reason=str(e))

        # _drive() must never be able to leak a running VM or a disk copy. A
        # bug in the console loop previously raised straight past the teardown
        # below, leaving a live bhyve process and a stray disk image behind for
        # a human to find with `ls /dev/vmm`.
        drive_error = None
        try:
            console, panicked, timed_out = self._drive(p, script)
        except Exception as e:                      # noqa: BLE001
            console, panicked, timed_out = "", False, True
            drive_error = f"{type(e).__name__}: {e}"

        try:
            p.send_signal(signal.SIGTERM)
            p.wait(timeout=15)
        except Exception:
            try:
                p.kill()
            except Exception:
                pass
        _destroy(vmname)

        # PRESERVE THE EVIDENCE on a panic. Releasing the disk would delete the
        # clone/copy and with it the kernel dump written to the swap slice —
        # exactly what is needed to debug the failure. Optional feature: the
        # dump is kept when it exists, and nothing depends on it.
        dump_path = None
        if (panicked or timed_out) and self.keep_dumps:
            dump_path = self._preserve_disk(disk, vmname)
        else:
            self._release_disk(disk, disk_tmp)

        load_failed = bool(re.search(r"kldload:.*(?:Exec format|No such|error)",
                                     console, re.I))
        return VMResult(console, panicked, timed_out, load_failed,
                        reason=drive_error, dump_disk=dump_path)

    def _guest_script(self, ko_name, post_load_cmd):
        """Commands typed at the guest console once it is up.

        Kept to /rescue-safe basics so the guest image can be tiny. Markers
        bracket the interesting region so parsing does not depend on boot
        chatter.
        """
        lines = [
            f"kldload p9fs || kldload virtio_p9fs",
            f"mkdir -p {GUEST_MNT}",
            f"mount -t p9fs -o trans=virtio {SHARE_TAG} {GUEST_MNT}",
            "echo FBSDQ-MOUNTED",
            f"kldload {GUEST_MNT}/{ko_name}",
            "echo FBSDQ-LOADED",
        ]
        if post_load_cmd:
            lines.append(post_load_cmd)
        lines += [
            # Unload too: a module that panics on unload is broken, and every
            # task explicitly requires clean unload.
            f"kldunload {os.path.splitext(ko_name)[0]} || true",
            "echo FBSDQ-UNLOADED",
            "dmesg",
            "echo FBSDQ-DONE",
            "shutdown -p now",
        ]
        return lines

    def _drive(self, proc, script):
        """Feed the script to the console, then read until DONE/panic/idle."""
        console = []
        panicked = False
        timed_out = False
        deadline = time.time() + BOOT_TIMEOUT
        sent = False
        last_output = time.time()

        os.set_blocking(proc.stdout.fileno(), False)

        while True:
            if proc.poll() is not None:
                break
            chunk = proc.stdout.read()
            if chunk:
                console.append(chunk.decode("utf-8", "replace"))
                last_output = time.time()
                joined = "".join(console)
                if PANIC_RE.search(joined) and not panicked:
                    panicked = True
                    # A panic drops into the DDB prompt with the core NOT yet
                    # written. Ask DDB to dump and reboot so the core lands on
                    # the swap slice and survives — otherwise the preserved
                    # disk holds nothing and debug_last_panic has no core.
                    # Best-effort: if DDB is absent or wedged the loop still
                    # exits below on idle timeout, and the verdict is already
                    # "panic" from the console text.
                    try:
                        proc.stdin.write(b"dump\n")
                        proc.stdin.flush()
                        time.sleep(2)
                        proc.stdin.write(b"reset\n")
                        proc.stdin.flush()
                    except (BrokenPipeError, OSError):
                        pass
                    # Keep reading a little longer to capture "Dumping N MB"
                    # and the post-reboot savecore line.
                    panic_deadline = time.time() + 90
                    while time.time() < panic_deadline:
                        if proc.poll() is not None:
                            break
                        more = proc.stdout.read()
                        if more:
                            console.append(more.decode("utf-8", "replace"))
                            if "FBSDQ-CORE-SAVED" in "".join(console):
                                break
                        else:
                            time.sleep(0.3)
                    break
                if "FBSDQ-DONE" in joined:
                    break
                # Type the script only once the SHELL is genuinely up.
                #
                # Do NOT match a bare "# " or "root@": the kernel's own boot
                # banner contains "root@bigone:/usr/obj/..." (the build host),
                # which fires this trigger while the console is still the
                # kernel's. Everything typed then is discarded, and the guest
                # silently runs only the tail of the script — observed as a
                # bench "FAIL (load)" where no FBSDQ-MOUNTED ever appeared.
                #
                # /etc/rc prints FBSDQ-GUEST-READY immediately before
                # `exec /rescue/sh`, so that marker is the reliable handshake.
                if not sent and "FBSDQ-GUEST-READY" in joined:
                    for ln in script:
                        try:
                            proc.stdin.write((ln + "\n").encode())
                            proc.stdin.flush()
                        except (BrokenPipeError, OSError):
                            break
                        time.sleep(0.3)
                    sent = True
            else:
                time.sleep(0.2)

            now = time.time()
            if not sent and now > deadline:
                timed_out = True
                break
            if sent and (now - last_output) > CONSOLE_IDLE_TIMEOUT:
                # Guest went quiet after we typed — wedged, or it panicked
                # without printing something PANIC_RE matched.
                timed_out = True
                break

        return "".join(console), panicked, timed_out


def zfs_snapshot(dataset, snap):
    return subprocess.run(["zfs", "snapshot", f"{dataset}@{snap}"],
                          capture_output=True, text=True).returncode == 0


def zfs_rollback(dataset, snap):
    """Cheap recovery after a panic: roll the guest image back instead of
    rebuilding it."""
    return subprocess.run(["zfs", "rollback", "-r", f"{dataset}@{snap}"],
                          capture_output=True, text=True).returncode == 0


def _zfs_dataset_for(path):
    r = subprocess.run(["df", "-t", "zfs", path], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    lines = r.stdout.strip().splitlines()
    if len(lines) < 2:
        return None
    return lines[1].split()[0]


def _zfs_mountpoint(dataset):
    r = subprocess.run(["zfs", "get", "-H", "-o", "value", "mountpoint", dataset],
                       capture_output=True, text=True)
    mp = r.stdout.strip()
    return mp if mp and mp != "-" else None
