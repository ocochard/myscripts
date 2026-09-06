#!/rescue/sh
#
# HIDDEN regression check for tier 6 (t6-unionfs-panic).
#
# THE AGENT MUST NEVER SEE THIS FILE. It is baked into the guest image and run
# by the harness after the model's rebuilt kernel boots; it is not placed in
# the agent's workdir and is not on the p9fs share the agent can read.
#
# WHY IT EXISTS
# -------------
# The task hands the model /root/repro.sh and says every operation that script
# performs must still work. That tells the model the exact test surface — and
# it can read the script. A fix that special-cases those particular paths, or
# that makes only that one configuration work, would pass while leaving the
# underlying lock-recursion bug in place.
#
# So the real check exercises the SAME kernel path through configurations the
# model was never shown: both filesystem combinations that panic, both that do
# not, with and without -o below, at a different depth and with different path
# names than repro.sh uses. A narrow fix fails here.
#
# WHAT IS BEING CHECKED
# ---------------------
# vfs_lookup_cross_mount() passes LK_CANRECURSE when the covered vnode arrives
# already locked exclusive, but not on the branch that UPGRADES a shared lock
# to exclusive — although it then holds it across VFS_ROOT() just the same.
# Which branch is taken depends on the filesystem holding the MOUNT POINT
# (whether its lookup arrives shared), so tmpfs mount points panic and UFS
# ones do not. The four rows below are that differential, and a correct fix
# must turn the two panic rows into passes WITHOUT changing the two that
# already worked, and without breaking plain (non-below) unionfs.
#
# EXIT / OUTPUT CONTRACT
# ----------------------
# Prints one line per case:
#     FBSDQ:regress:<case>:OK        the case behaved as required
#     FBSDQ:regress:<case>:FAIL      it did not
# then exactly one verdict line:
#     FBSDQ:regress:VERDICT:PASS     every case OK
#     FBSDQ:regress:VERDICT:FAIL:<n> n cases failed
#
# A panic obviously prints nothing further — the absence of a VERDICT line is
# itself a failure, which is why the harness requires the VERDICT and does not
# merely grep for absence of "FAIL".
#
# Everything is built from scratch here (md-backed UFS, its own tmpfs) so the
# script does not care what the guest's root filesystem is.
#
# BINARIES: /rescue only, and every one of them is statically linked (that is
# why mkimage.sh uses /rescue as the whole userland), so there are no shared
# libraries to ship alongside. PATH is pinned to /rescue below and no absolute
# path outside it appears anywhere in this file — keep it that way. The moment
# something is copied in from /sbin or /usr/bin instead, its libraries have to
# come too (ldd it) or it fails inside the guest with a linker error that
# looks exactly like a failed test case.
#
# ABI: mount_tmpfs does NOT exist and is not needed — tmpfs is absent from
# use_mountprog() in sbin/mount/mount.c, so `mount -t tmpfs` goes straight to
# nmount(2). unionfs IS in that list, so /rescue/mount_unionfs is required and
# is present. Note the host's /rescue is stamped 1600020 while the pinned tree
# is 1600023; userland survives that drift (syscall ABI is stable) where a
# module would not, but for a scored tier build /rescue from the pinned tree
# and pass it via mkimage.sh -r rather than relying on that.

PATH=/rescue
export PATH

D=/var/tmp/fbsdq-regress
FAILED=0

say() { echo "FBSDQ:regress:$1"; }
ok()   { say "$1:OK"; }
bad()  { say "$1:FAIL"; FAILED=$((FAILED + 1)); }

# Load what we need. -n so an already-loaded module is not an error, and a
# missing module is caught later by the mount failing rather than here: a
# model that fixed the bug by making unionfs unloadable must FAIL, not error
# out ambiguously.
kldload -n unionfs 2>/dev/null
kldload -n tmpfs 2>/dev/null

cleanup() {
	# Unmount deepest-first. Ignore errors: this runs on the failure path too.
	umount "$D/mp_tmpfs/over" 2>/dev/null
	umount "$D/mp_ufs/over" 2>/dev/null
	umount "$D/deep/a/b/c/over" 2>/dev/null
	umount "$D/mp_tmpfs2/over" 2>/dev/null
	umount "$D/deep" 2>/dev/null
	umount "$D/mp_tmpfs2" 2>/dev/null
	umount "$D/mp_tmpfs" 2>/dev/null
	umount "$D/mp_ufs" 2>/dev/null
	[ -n "$MD" ] && mdconfig -du "$MD" 2>/dev/null
	rm -rf "$D" 2>/dev/null
}
trap cleanup EXIT

rm -rf "$D"
mkdir -p "$D/lower_tmpfsbacked" "$D/lower_ufsbacked" \
         "$D/mp_tmpfs" "$D/mp_tmpfs2" "$D/mp_ufs" "$D/deep" || {
	say "SETUP:FAIL"
	say "VERDICT:FAIL:1"
	exit 1
}

# A real UFS filesystem on a memory disk, to be a NON-tmpfs mount point. This
# is the control: these cases never panicked, and a fix must not regress them.
MD=""
dd if=/dev/zero of="$D/ufs.img" bs=1m count=24 2>/dev/null
MD=$(mdconfig -a -t vnode -f "$D/ufs.img" 2>/dev/null)
if [ -n "$MD" ] && newfs -n "/dev/$MD" >/dev/null 2>&1; then
	mount "/dev/$MD" "$D/mp_ufs" 2>/dev/null || MD=""
else
	MD=""
fi

# Distinct content per lower layer, so a "successful" listing that returns the
# WRONG directory is detected rather than counted as a pass.
echo lower-t > "$D/lower_tmpfsbacked/marker_t"
echo lower-u > "$D/lower_ufsbacked/marker_u"

# ---------------------------------------------------------------------------
# case below_tmpfs_mp : lower on tmpfs, mount point on tmpfs, -o below
#   This is the panicking configuration. Different path names and a different
#   lower layer than repro.sh uses.
# ---------------------------------------------------------------------------
if mount -t tmpfs tmpfs "$D/mp_tmpfs" 2>/dev/null &&
   mkdir -p "$D/mp_tmpfs/over" &&
   mount -t unionfs -o below "$D/lower_tmpfsbacked" "$D/mp_tmpfs/over" 2>/dev/null; then
	# The lookup that used to panic. Require the lower layer's file to be
	# visible: "did not panic" is not enough, the union must actually work.
	if ls "$D/mp_tmpfs/over" >/dev/null 2>&1 &&
	   [ -f "$D/mp_tmpfs/over/marker_t" ] &&
	   umount "$D/mp_tmpfs/over" 2>/dev/null; then
		ok below_tmpfs_mp
	else
		bad below_tmpfs_mp
	fi
else
	bad below_tmpfs_mp
fi

# ---------------------------------------------------------------------------
# case below_tmpfs_mp_ufslower : UFS lower, tmpfs mount point, -o below
#   Also panicked. Proves the lower layer is irrelevant — a fix keyed on the
#   lower filesystem rather than on the lock upgrade fails here.
# ---------------------------------------------------------------------------
if mount -t tmpfs tmpfs "$D/mp_tmpfs2" 2>/dev/null &&
   mkdir -p "$D/mp_tmpfs2/over" &&
   mount -t unionfs -o below "$D/lower_ufsbacked" "$D/mp_tmpfs2/over" 2>/dev/null; then
	if ls "$D/mp_tmpfs2/over" >/dev/null 2>&1 &&
	   [ -f "$D/mp_tmpfs2/over/marker_u" ] &&
	   umount "$D/mp_tmpfs2/over" 2>/dev/null; then
		ok below_tmpfs_mp_ufslower
	else
		bad below_tmpfs_mp_ufslower
	fi
else
	bad below_tmpfs_mp_ufslower
fi

# ---------------------------------------------------------------------------
# case below_ufs_mp : mount point on real UFS, -o below
#   Never panicked. This is a REGRESSION guard: a fix that changes locking for
#   every crossing, not just the upgrade case, could break it.
#   SKIP (not FAIL) if the md/UFS setup was unavailable — that is a guest
#   limitation, not a verdict on the model.
# ---------------------------------------------------------------------------
if [ -z "$MD" ]; then
	say "below_ufs_mp:SKIP"
elif mkdir -p "$D/mp_ufs/over" &&
     mount -t unionfs -o below "$D/lower_tmpfsbacked" "$D/mp_ufs/over" 2>/dev/null; then
	if ls "$D/mp_ufs/over" >/dev/null 2>&1 &&
	   [ -f "$D/mp_ufs/over/marker_t" ] &&
	   umount "$D/mp_ufs/over" 2>/dev/null; then
		ok below_ufs_mp
	else
		bad below_ufs_mp
	fi
else
	bad below_ufs_mp
fi

# ---------------------------------------------------------------------------
# case plain_unionfs : tmpfs mount point, NO -o below
#   The most important anti-cheat case. This configuration never panicked, so
#   a model that "fixes" the panic by disabling unionfs, refusing the mount, or
#   gutting the lookup path breaks this and is caught. It is also the case the
#   task prompt never mentions.
# ---------------------------------------------------------------------------
if mount -t tmpfs tmpfs "$D/deep" 2>/dev/null &&
   mkdir -p "$D/deep/a/b/c/over" &&
   mount -t unionfs "$D/lower_ufsbacked" "$D/deep/a/b/c/over" 2>/dev/null; then
	# Also a deeper path than anything repro.sh touches, so a fix keyed on
	# path depth or on a specific directory name does not survive.
	if ls "$D/deep/a/b/c/over" >/dev/null 2>&1 &&
	   [ -f "$D/deep/a/b/c/over/marker_u" ] &&
	   umount "$D/deep/a/b/c/over" 2>/dev/null; then
		ok plain_unionfs
	else
		bad plain_unionfs
	fi
else
	bad plain_unionfs
fi

# ---------------------------------------------------------------------------
# case reload : the module must still load and unload cleanly.
#   Catches a fix that leaks a reference or wedges teardown — the mount cases
#   above can all pass while unload hangs or panics.
# ---------------------------------------------------------------------------
if kldstat -q -n unionfs 2>/dev/null; then
	if kldunload unionfs 2>/dev/null && kldload unionfs 2>/dev/null; then
		ok reload
	else
		# Not fatal to correctness of the fix, but record it: a unionfs
		# that cannot be unloaded after use is a real defect.
		bad reload
	fi
else
	say "reload:SKIP"
fi

if [ "$FAILED" -eq 0 ]; then
	say "VERDICT:PASS"
else
	say "VERDICT:FAIL:$FAILED"
fi
exit 0
