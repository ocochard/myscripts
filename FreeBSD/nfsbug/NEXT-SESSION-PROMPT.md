# Prompt for the next session

Written 2026-11-21 at the end of the session that rebased and pushed the
branches, added three test cases, and found and fixed the nfscbd bugs #7
and #8 (session 34d90969, 2026-11-21). Earlier sessions: 4a7ee611
(2026-11-02 to 11-18). Copy the block below verbatim into the fresh session
as the first user message.

---

I'm continuing work on FreeBSD NFS regression tests with the NFS client and
server in vnet jails, and the kernel fixes they need. Read these first:

1. `~/myscripts/FreeBSD/nfsbug/README.md`: the goal, the table of all ten
   patches in commit order, and a plain explanation of each bug.
2. The write-up next to each patch in the same directory (`badsession.md`,
   `staleclientid.md`, `nfscl_jail.md`, `bugreport_kgss_vnet_upcall.md`,
   `nfs_vnet_tests.md`, `session-leak.md`, `nfscbd_jail.md`,
   `svc_backchannel.md`, `nfsd_jail_state.md`, `gss_jail_remove.md`), and the
   Bugzilla texts `BUGREPORT-*.txt` (one for #9 and #10 together).
3. Memory `project_freebsd_nfs_jail_limits.md` (jail limits of the NFS
   client, pNFS and nfscbd, the kgssapi bug, the TMPDIR and atf traps).

**Goal.** Make NFS regression tests easy to write by running both the NFS
server and the NFS clients in vnet jails on one machine.

**Patches** (numbering used in all docs). All branches are in `~/freebsd-src`
(one worktree each), based on `freebsd/main` 6dc19a71f70c, committed with
author `Olivier Cochard <olivier@FreeBSD.org>`, and pushed to my fork
(`origin`, github.com/ocochard/freebsd-src) at the same head. Each patch
file in `nfsbug/` is byte-identical to its commit's diff.

| # | patch | branch (worktree) | commit | filed |
|---|---|---|---|---|
| 1 | `badsession.patch`: recovery skipped on a defunct session (permanent hang) | in main | 5ab48fb9f7ac | PR 297252 |
| 2 | `staleclientid.patch`: STALE_CLIENTID in the renew window (45 s stall) | in main | 7a0021a0988f | PR 299221 |
| 3 | `nfscl_jail.patch`: `VFCF_JAIL` on the NFS client + `NFSSVC_DUMPMNTOPTS` without `PRIV_NFS_DAEMON` | `nfscl-jail` (`~/freebsd-src-nfscljail`) | 5fdb198e1994 | policy change, no PR; needs rmacklem's agreement |
| 4 | `kgss_vnet.patch`: gssd state per vnet + per-call timeouts on the shared netlink handle | `kgss-vnet` (`~/freebsd-src-kgssvnet`) | e75a5c761d5c | no; text in `bugreport_kgss_vnet_upcall.md` |
| 5 | `nfs_vnet_tests.patch`: `tests/sys/fs/nfs`, 10 cases (`session_leak` with expect_fail until #6), one commit (the four earlier ones squashed 2026-11-22) | `nfs-vnet-tests` (`~/freebsd-src-nfstest`) | 91d6b85cea18 | not a bug |
| 6 | `session-leak.patch`: sessions replaced by recovery never freed; also removes the `session_leak` expect_fail | `session-leak` (`~/freebsd-src-sessleak`), on top of `nfs-vnet-tests` | 6eb294be11ba | no; text in `BUGREPORT-session-leak.txt` |
| 7 | `nfscbd_jail.patch`: nfscbd in a jail serves no callbacks (program registered only with the UDP socket, which a jail cannot add) | `nfscbd-jail` (`~/freebsd-src-nfscbdjail`) | 9fe410604812 | no; text in `BUGREPORT-nfscbd-jail.txt` |
| 8 | `svc_backchannel.patch`: after an nfscbd restart, `svcpool_close()` had dropped the mounts' backchannels: recalls lost, 255 s stall | `nfscbd-jail`, after #7 | 537a6cdcd3c4 | no; text in `BUGREPORT-svc-backchannel.txt` |
| 9 | `nfsd_jail_state.patch`: a dying server jail with any client record (NFSv4.0, or a client gone without DESTROY_CLIENTID) stayed dying forever; throw the state away when its last nfsd exits | `nfsd-jail-dying` (`~/freebsd-src-nfsddying`) | b214c7f03b3b | no; text (with #10) in `BUGREPORT-nfsd-jail-dying.txt` |
| 10 | `gss_jail_remove.patch`: same cycle with the RPCSEC_GSS server contexts (Kerberos); `PR_METHOD_REMOVE` hook | `nfsd-jail-dying`, after #9 | 716fc04e72e6 | no; same report as #9 |

The branches track `upstream/main` (the GitHub mirror): never use a bare
`git push`; always `git push origin <branch>`.

**Review order** I gave (I create the reviews and push upstream myself):
#3, #4, #7, #8, #9, #10 (no code dependency, can run in parallel), then the
tests 91d6b85cea18 (needs #3, #4 and #7), then #6 6eb294be11ba (removes the
`session_leak` expect_fail). File the PRs first (#9 and #10 share one), then
add `PR:` lines to the commits and the #6 PR number to the
`atf_expect_fail` message in the tests commit. One diff per review:
`git diff -U999999 <c>~1 <c>`.

**Tested on 2026-11-21** (bhyve VM, kernel = main 6dc19a71f70c + #3 + #4 +
#5 + #7 + #8, GENERIC-NODEBUG and GENERIC with WITNESS): all 10 cases passed,
`session_leak` reported its expected failure; with #6 instead, `session_leak`
passed. WITNESS showed two LORs unrelated to RPC/NFS (`ifnet_sx` ->
`in_control`, `ufs` -> `tmpfs`). The #6 branch itself (tests + #6 without
#3/#4) was not built; its kernel diff equals the tested one.

**Open items** (pick with me first):
- Reviews and PRs as above; rebase the branches if main moves first.
- Dying server jails: fixed by #9 and #10 (measured 2026-11-22: 7 left
  after the suite before, 0 with both). Gap in #9: an nfsd stopped before
  the jail is removed keeps the state. NFSv3/NLM not checked.
- `krb5p` failed once with "no NFS packet captured", then passed 5 reruns:
  the tcpdump capture check is flaky. Not investigated.
- `make check` from an installed `/usr/tests` never run: the VM installs the
  test files by hand, so the `Makefile` entries (including
  `delegation_test`) are untested.
- pNFS tests are blocked: the MDS refuses to run in a jail
  (`nfsrv_setdsserver()`), the DS list is a kernel global, and the MDS needs
  NFS client mounts (#3).
- NFSv3 NLM fails for jailed clients ("No locks available"); not audited.
- Design limits, not bugs: `nfscbd_pool` and `vfs.nfsd.issue_delegations`
  are host-wide globals (one nfscbd serves every vnet; the test sets and
  restores the sysctl); NFSv4.0 gets no delegations since 71ac1ec5c9d9; a
  jailed client's RPC counters go to the vnet of the process doing the I/O.

**How the tests are run** (bhyve VM, since a client bug can hang the host):
- Kernel: `include GENERIC-NODEBUG` (or `GENERIC` for WITNESS) plus
  `ident NFSTEST`, `device epair`, `device if_bridge`, `options NULLFS`,
  `options KGSSAPI`. The VM loads no modules. Build in a scratch worktree
  (`git worktree add --detach /tmp/X-src <base>`, then cherry-pick or
  `git apply -p0`) with
  `cd sys/amd64/conf && config -d /tmp/kobj-X NFSTEST && cd /tmp/kobj-X && CCACHE_DISABLE=1 MODULES_OVERRIDE= make -j64`,
  then delete the `NFSTEST` file. Check a new symbol with `nm` or `objdump`.
- The VM image copies the host's userland: a userland change (the #7
  `nfscbd`) must go into the payload. Build it with
  `cd usr.sbin/nfscbd && MAKEOBJDIRPREFIX=/tmp/nfscbd-obj make obj && MAKEOBJDIRPREFIX=/tmp/nfscbd-obj make`
  and copy the binary to `/tmp/nfstest-vm/nfscbd`; `run.sh` installs it.
  Without it, `delegation_test:recall` fails on any kernel.
- Image: `sudo ~/myscripts/FreeBSD/kern-test-vm/mkvm.sh -k /tmp/kobj-X/kernel:X [-k ...] -t /tmp/nfstest-vm`.
  Do not boot it with `bootvm.sh`: its nmdm console hangs intermittently.
  Use `sudo sh /tmp/runvm-stdio.sh /zroot/vm/kern-test.img X 2700` (the full
  suite takes about 20 minutes), then read `/tmp/kt2-X.log` and
  `/tmp/kt2-X.steps`.
- Payload `/tmp/nfstest-vm/`: `run.sh` (below), `vnet.subr` from
  `tests/sys/common`, `nfs/` with the test files copied from the branch
  (`basic_test.sh`, `recovery_test.sh`, `krb5_test.sh`,
  `delegation_test.sh`, `nfs.subr`, `nfs_reset_proxy.py`), the patched
  `nfscbd`, and `python.tgz` built with
  `cd /usr/local && tar -czf /tmp/nfstest-vm/python.tgz --exclude 'lib/python3.12/site-packages/*' --exclude 'lib/python3.12/test' --exclude '__pycache__' bin/python3.12 bin/python3 lib/libpython3.12.so.1.0 lib/libpython3.12.so lib/libintl.so.8 lib/libintl.so.8.* lib/python3.12`.
- `/tmp` may be gone after a reboot; recreate both scripts from below. The
  scratch worktrees `/tmp/nfsall-src`, `/tmp/nfscbd-src`, `/tmp/nfsleak-src`
  are then stale entries: `git -C ~/freebsd-src worktree prune`.

`/tmp/runvm-stdio.sh`:

```sh
#!/bin/sh
# usage: runvm-stdio.sh img kernel-name timeout-seconds
IMG=$1 K=$2 TMO=$3
M=$(mktemp -d)
MD=$(mdconfig -a -t vnode -f $IMG)
mount /dev/${MD}p2 $M
sed -i '' "s/^kernel=.*/kernel=\"$K\"/" $M/boot/loader.conf
rm -f $M/root/results $M/root/steps.log $M/root/ps.log
umount $M; mdconfig -du $MD
bhyvectl --destroy --vm=kt2 2>/dev/null
timeout -s KILL $TMO bhyve -c 4 -m 4G -A -H -P -u \
    -l bootrom,/usr/local/share/uefi-firmware/BHYVE_UEFI.fd \
    -s 0:0,hostbridge -s 1:0,lpc -s 4:0,virtio-blk,$IMG -l com1,stdio kt2 \
    < /dev/null > /tmp/kt2-$K.log 2>&1
echo "bhyve exit $?"
bhyvectl --destroy --vm=kt2 2>/dev/null
MD=$(mdconfig -a -t vnode -f $IMG)
fsck -y /dev/${MD}p2 > /dev/null 2>&1
mount -o ro /dev/${MD}p2 $M
cp $M/root/steps.log /tmp/kt2-$K.steps 2>/dev/null
cp $M/root/ps.log /tmp/kt2-$K.ps 2>/dev/null
chmod 644 /tmp/kt2-$K.* 2>/dev/null
umount $M; mdconfig -du $MD; rmdir $M
```

`/tmp/nfstest-vm/run.sh` (edit the second `for t in` list to choose the
cases):

```sh
#!/bin/sh
# Install the NFS tests, python3 and nfscbd, run them with kyua, print the
# report.  A watchdog logs ps and nfsd kernel stacks to /root/ps.log, synced.
export PATH=$PATH:/usr/local/bin:/usr/local/sbin
[ -f nfscbd ] && install -m 0555 nfscbd /usr/sbin/nfscbd
( while :; do { date; ps -axo pid,ppid,stat,wchan,etime,command; for p in $(pgrep -f "nfsd: server"); do procstat -kk $p; done; } >> /root/ps.log; sync; sleep 5; done ) > /dev/null 2>&1 &
WD=$!
step() { echo "STEP $*" | tee -a /root/steps.log; sync; }
step untar
tar -xzf python.tgz -C /usr/local
ldconfig -m /usr/local/lib
python3 -c 'print("python ok")'
mkdir -p /usr/tests/sys/common && install -m 0444 vnet.subr /usr/tests/sys/common/
D=/usr/tests/sys/fs/nfs
mkdir -p $D
install -m 0555 nfs/nfs_reset_proxy.py $D/
install -m 0444 nfs/nfs.subr $D/
for t in basic_test recovery_test krb5_test delegation_test; do
	{ echo '#! /usr/libexec/atf-sh'; cat nfs/$t.sh; } > $D/$t
	chmod 0555 $D/$t
done
cat > $D/Kyuafile <<'KF'
syntax(2)
test_suite("FreeBSD")
atf_test_program{name="basic_test", is_exclusive=true}
atf_test_program{name="recovery_test", is_exclusive=true}
atf_test_program{name="krb5_test", is_exclusive=true}
atf_test_program{name="delegation_test", is_exclusive=true}
KF
cd $D
for t in delegation_test:recall krb5_test:krb5 krb5_test:krb5i krb5_test:krb5p basic_test:basic basic_test:v40_basic basic_test:two_clients recovery_test:server_reset recovery_test:server_reset_twice recovery_test:session_leak; do
	step "test $t"
	timeout -s KILL 400 kyua debug -k Kyuafile $t 2>&1 | grep -v '^Executing command' | tee -a /root/steps.log
	sync
done
step done
jls -d -h jid path dying | tee -a /root/steps.log
sysctl vfs.nfsd.issue_delegations | tee -a /root/steps.log
kill $WD
```

For a one-off experiment, run a plain sh script from `run.sh` with an
absolute path (`P=$(pwd)` before `cd $D`), write its output under `/root`,
and fetch it from the image afterwards (mdconfig + `mount -o ro`).

**Traps already hit** (details in the write-ups):
- Jail roots: tmpfs + read-only nullfs + a writable copy of `/etc`; the
  export must be on the jail root (`enforce_statfs=2`).
- Jailed nfsd needs `vfs.nfsd.nfs_privport=0` set by hand; `mountd -R` does
  not clear it.
- Under kyua, `jexec` passes `TMPDIR`; start Kerberos daemons with
  `env -u TMPDIR`.
- gssd and nfscbd need `PRIV_NFS_DAEMON`: such a client jail needs
  `allow.nfsd`.
- NFSv4 exclusive locks need `lockf -w`.
- atf-sh: define `X_cleanup` after `atf_test_case X "cleanup"`, or the empty
  default replaces it and nothing is cleaned up.
- nfscbd ignores SIGTERM: stop it with SIGUSR1.
- A test whose cleanup leaves jails or mounts breaks every later case
  ("jail: ... already exists"); judge only the first failure.
- `timeout` waits for the jailed daemons it reaped: a short body can still
  take the whole timeout.
- My git diffs have no `a/` `b/` prefix: `git apply -p0`.
- ccache on this host has served stale objects before: build kernels with
  `CCACHE_DISABLE=1` and check new symbols with `nm`.

**Conventions:** NFS patches and write-ups go in `~/myscripts/FreeBSD/nfsbug/`
(not `docs/`). Every patch gets a student-level write-up (background,
measured problem, fix and alternatives, tested table). Never claim an
untested result. Do not commit or push without asking.
