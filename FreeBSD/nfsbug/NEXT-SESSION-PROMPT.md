# Prompt for the next session

Written 2026-11-22 at the end of the session that rebased and pushed the
branches, added three test cases, squashed the tests into one commit, found
and fixed the nfscbd bugs #7 and #8 and the dying server jails #9 and #10,
and wrote their bug reports, ran the tests as installed by `make install`,
fixed the flaky `krb5p` capture, closed the last gap in #9 (an nfsd
stopped before its jail is removed), moved that hook's work to a task to
avoid a deadlock, added two tests that a removed server jail goes away,
rebased everything onto main 6edecf52def6, squashed #9 and #10 into one
commit, measured why NLM cannot run in a jail and added an NFSv3 case
without NLM, built each branch alone and ran all 13 cases on the final
heads, prepared the ron-dev `pr/*` branches and PR texts, and had every
commit reviewed at xhigh effort with the freebsd-src skill: 25 findings,
the real ones fixed and folded into their commits, retested (session
34d90969, 2026-11-21 to 11-24). Earlier sessions: 4a7ee611 (2026-11-02 to
11-18). The `nfsbug/` docs are committed and pushed in myscripts (last:
74a6dd7; its subject says "fix the 25 findings" but some are not fixed,
see `review-2026-11-24.md`). Copy the block below verbatim into
the fresh session as the first user message.

State at the end: no coding item left. Next steps are mine: file the
Bugzilla reports, add the `PR:` lines (and 07's PR number in 06's
`atf_expect_fail` message), then open the `pr/*` branches as ron-dev PRs in
the order below. Design questions for rmacklem: NLM and pNFS in jails, the
host-wide callback pool.

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
3. `review-2026-11-24.md`: the per-commit review (25 findings), what was
   fixed in which commit, and what remains untested.
4. Memory `project_freebsd_nfs_jail_limits.md` (jail limits of the NFS
   client, pNFS and nfscbd, the kgssapi bug, the dying-jail cycle and how
   to measure it with DDB, the TMPDIR and atf traps).

**Goal.** Make NFS regression tests easy to write by running both the NFS
server and the NFS clients in vnet jails on one machine.

**Patches** (numbering used in all docs). All branches are in `~/freebsd-src`
(one worktree each), based on `freebsd/main` 6edecf52def6 (rebased 2026-11-22), committed with
author `Olivier Cochard <olivier@FreeBSD.org>`, and pushed to my fork
(`origin`, github.com/ocochard/freebsd-src) at the same head. Each patch
file in `nfsbug/` is byte-identical to its commit's diff.

| # | patch | branch (worktree) | commit | filed |
|---|---|---|---|---|
| 1 | `badsession.patch`: recovery skipped on a defunct session (permanent hang) | in main | 5ab48fb9f7ac | PR 297252 |
| 2 | `staleclientid.patch`: STALE_CLIENTID in the renew window (45 s stall) | in main | 7a0021a0988f | PR 299221 |
| 3 | `nfscl_jail.patch`: `VFCF_JAIL` on the NFS client + `NFSSVC_DUMPMNTOPTS` without `PRIV_NFS_DAEMON` | `nfscl-jail` (`~/freebsd-src-nfscljail`) | d3fc593d5ba1 | policy change, no PR; needs rmacklem's agreement |
| 4 | `kgss_vnet.patch`: gssd state per vnet + per-call timeouts on the shared netlink handle | `kgss-vnet` (`~/freebsd-src-kgssvnet`) | 48ececba446d | no; text in `bugreport_kgss_vnet_upcall.md` |
| 5 | `nfs_vnet_tests.patch`: `tests/sys/fs/nfs`, 13 cases (`session_leak` with expect_fail until #6), one commit (the four earlier ones squashed 2026-11-22) | `nfs-vnet-tests` (`~/freebsd-src-nfstest`) | 4e1da3c09443 | not a bug |
| 6 | `session-leak.patch`: sessions replaced by recovery never freed; also removes the `session_leak` expect_fail | `session-leak` (`~/freebsd-src-sessleak`), on top of `nfs-vnet-tests` | 66594a2d11eb | no; text in `BUGREPORT-session-leak.txt` |
| 7 | `nfscbd_jail.patch`: nfscbd in a jail serves no callbacks (program registered only with the UDP socket, which a jail cannot add) | `nfscbd-jail` (`~/freebsd-src-nfscbdjail`) | b2016b20d2a9 | no; text in `BUGREPORT-nfscbd-jail.txt` |
| 8 | `svc_backchannel.patch`: after an nfscbd restart, `svcpool_close()` had dropped the mounts' backchannels: recalls lost, 255 s stall | `nfscbd-jail`, after #7 | a55296b95d25 | no; text in `BUGREPORT-svc-backchannel.txt` |
| 9 | `nfsd_jail_state.patch`: a dying server jail with any client record (NFSv4.0, or a client gone without DESTROY_CLIENTID) stayed dying forever; throw the state away when its last nfsd exits | `nfsd-jail-dying` (`~/freebsd-src-nfsddying`) | 9b8e54c993f0 (one commit with #10) | no; text (with #10) in `BUGREPORT-nfsd-jail-dying.txt` |
| 10 | same commit as #9 (squashed 2026-11-22): the same cycle with the RPCSEC_GSS server contexts (Kerberos); write-up `gss_jail_remove.md` | `nfsd-jail-dying` | 9b8e54c993f0 | same report as #9 |

The branches track `upstream/main` (the GitHub mirror): never use a bare
`git push`; always `git push origin <branch>`.

**ron-dev PR branches** in `~/freebsd-official/src` (local, not pushed; I
run `git switch pr/<name> && git pr main` myself), on freebsd/main
a82c04293ecc, each identical (`git range-diff`) to the commit above:
`pr/nfscl-jail` 29e572c16e30, `pr/kgss-vnet` d6dbcc74bc50,
`pr/nfscbd-jail` 970a790fe602, `pr/svc-backchannel` cddcdd7a71ef (#8 alone),
`pr/nfsd-jail-dying` 9d3c2c573350, `pr/nfs-vnet-tests` 2b68ed9fc4f4,
`pr/nfscl-session-leak` 167bf7d61803 (tests commit + #6). PR texts:
`nfsbug/pr/01-07*.md`. Update these branches only with `git branch -f
pr/<name> <explicit hash>` from a scratch worktree, never by switching the
tree, which holds my other work.

**Review order** I gave (I create the reviews and push upstream myself):
#3, #4, #7, #8, #9+#10 (no code dependency, can run in parallel), then the
tests 4e1da3c09443 (needs #3, #4, #7, #9 and #10), then #6 66594a2d11eb (removes the
`session_leak` expect_fail). File the PRs first (#9 and #10 share one), then
add `PR:` lines to the commits and the #6 PR number to the
`atf_expect_fail` message in the tests commit. One diff per review:
`git diff -U999999 <c>~1 <c>`.

**Tested** (bhyve VM, GENERIC-NODEBUG and GENERIC with WITNESS):
- 2026-11-22, kernel = main 6dc19a71f70c + #3 #4 #5 #7 #8 #9 #10: all 10
  cases passed (`session_leak`: its expected failure), and after the suite
  plus 70 s no jail was left dying (7 before #9, 3 Kerberos ones with #9
  alone). The #9 checks passed too: NFSv4.0, client gone, server removed
  while mounted, and an nfsd restart in a live jail keeping its state.
- 2026-11-21, with #6 instead of the expect_fail: `session_leak` passed.
- WITNESS: only `ifnet_sx` -> `in_control` and `ufs` -> `tmpfs`, both
  unrelated to RPC/NFS. No panic, no KASSERT.
- 2026-11-22, installed tests: `make install` of `tests/sys/fs/nfs` into a
  staging root, unpacked over the VM's `/usr/tests`, then
  `kyua test -k /usr/tests/sys/fs/nfs/Kyuafile` (what `make check` runs):
  10/10 in 300 s. `kyua list -v` gives the combined `is_exclusive = true`
  (`kyua report` prints only the case's own metadata, `false`).
- 2026-11-22, the `krb5p` flake ("no NFS packet captured"): tcpdump `-w`
  without `--immediate-mode` holds packets up to the 1 s BPF timeout, and
  the test killed it after 1 s; on lo0, a kill within 0.5 s lost 10/10
  captures. Fixed in the tests commit with `--immediate-mode`: krb5p and
  krb5i 15/15 each.
- 2026-11-22, #9 with its jail removal hook and start guard: same suite and
  checks passed on both kernels; an NFSv4.0 server jail whose nfsd was
  stopped before `jail -r` went away at 0 s (before: never). With nfsd
  stopped while an NFSv4.1 client is still mounted, the jail went away
  after 598 s: TCP `FIN_WAIT_2` of the server's socket, no NFS state.
  The start guard is untested (it needs a process left in a dying jail).
- 2026-11-22, the hook's work moved to a task, and the two jail-freed
  cases added: same suite and checks passed on both kernels;
  `v40_server_freed` and `server_freed` pass with #9 and #10 and fail
  without ("jail srv still dying 10s after its removal").
- 2026-11-22, after the rebase onto main 6edecf52def6 (one conflict in
  `nfsd_modevent()`, both lines kept) and the #9+#10 squash: one kernel
  with all 8 commits, #6 included, NODEBUG and WITNESS: all 12 cases
  passed, `session_leak` included, nothing dying, no panic.
- 2026-11-23, each branch built alone on main 6edecf52def6: kernel plus
  the nfscommon, nfscl, nfsd, krpc, kgssapi and nfslockd modules, and the
  nfscbd userland for `nfscbd-jail`: all built, no compiler warning.
- 2026-11-23, local review pass (the 7 checks of
  `.agents/skills/freebsd-src/review.md`) found 2 design bugs, both fixed
  in their commits: F1, #10's hook freed GSS contexts with
  `allprison_lock` held although a context still in setup calls gssd (now
  a task); F2, #8 kept every socketless transport on close, which would
  also keep nfsd's RDMA transports (now an explicit `xp_backchannel`
  mark). Retested: 13 cases on NODEBUG and WITNESS, and #8's restart
  experiment (0 s / +10 s / 0 s).
- 2026-11-24, after the xhigh per-commit review and its fixes (all folded
  into their commits, see `review-2026-11-24.md`): 13 cases on NODEBUG and
  WITNESS, no jail dying; S1 (non-vnet jail mount) EPERM; S2 (jailed NFSv3
  lock) ENOLCK; #9 scenarios and #8 restart as before. Not testable here:
  the ~27s gssd upcall, pNFS, the GSS refusal in a dying jail, the nfsd
  teardown race.
- 2026-11-23, final heads together (main 6edecf52def6 + the 7 commits,
  `n291531-ed0a6ec4666b`): all 13 cases passed on NODEBUG and WITNESS,
  `session_leak` and `v3_basic` included; nothing dying after the suite
  plus 70 s; no panic; WITNESS showed only the two unrelated LORs.

**Open items** (pick with me first):
- Reviews and PRs as above; rebase the branches if main moves first
  (check with `git fetch upstream` and `git range-diff`, then build all 7
  commits together, run the 13 cases, then force-push and move the
  `pr/*` branches with `git branch -f`).
- Review findings not fixed (`review-2026-11-24.md`): NFSv4 owner strings
  of a jailed mount are mapped in the vnet of the thread parsing the reply
  (nfsiod: the host's tables); `tlscertname` accepts `../` (pre-existing,
  not verified); NFSv4.0 keeps one nfsclds per SETCLIENTID until unmount
  (pre-existing). Fixes resting on code reading only: the ~27s gssd upcall
  (#4), pNFS (#6), the GSS refusal in a dying jail and the nfsd teardown
  race (#9 + #10).
- Dying server jails: fixed by #9 and #10, including an nfsd stopped
  before the removal (#9's jail removal hook and start guard, folded in
  2026-11-22). The hook does its work in
  a task: waiting for the exclusive `nfsv4rootfs_lock` with
  `allprison_lock` held could deadlock with an nfsd thread mounting a ZFS
  snapshot (`vfs_exjail_clone()`); found by reading, not reproduced. The
  tests check it: `basic_test:v40_server_freed` and
  `krb5_test:server_freed` fail without #9 / #10.
- pNFS tests are blocked: the MDS refuses to run in a jail
  (`nfsrv_setdsserver()`), the DS list is a kernel global, and the MDS needs
  NFS client mounts (#3).
- Cosmetic: each cleanup prints "ifconfig: interface epairNa does not
  exist", from the shared `vnet.subr` (destroying the jail's end already
  destroys the pair). Common to all network tests; not a failure.
- Design limits, not bugs: `nfscbd_pool` and `vfs.nfsd.issue_delegations`
  are host-wide globals (one nfscbd serves every vnet; the test sets and
  restores the sysctl); NFSv4.0 gets no delegations since 71ac1ec5c9d9; a
  jailed client's RPC counters go to the vnet of the process doing the I/O.
- NLM (NFSv3 locking) cannot work in jails, measured 2026-11-22:
  `PRIV_NFS_LOCKD` is `#ifdef notyet` for jails, so `rpc.lockd` dies in
  one, and the kernel NLM state is host-wide (`nlm_is_running`, sockets,
  statd client, host list; the client names itself with the host's
  hostname). Making it per vnet would be a large `sys/nlm` change: ask
  rmacklem first, as for pNFS. The tests cover NFSv3 with `nolockd`
  (`v3_basic`).

**How the tests are run** (bhyve VM, since a client bug can hang the host):
- The last full test kernel is in `/tmp/kobj-final-NODEBUG` and
  `/tmp/kobj-final-DBG`, built from `/tmp/nfsfinal-src`: upstream/main
  6edecf52def6 with the 7 final commits cherry-picked, in this order:
  `nfscl-jail`, `kgss-vnet`, `upstream/main..nfscbd-jail`,
  `upstream/main..nfsd-jail-dying`, `upstream/main..session-leak` (the
  last range holds the tests and #6); #6's last amend (a prototype in
  `nfs_commonkrpc.c`) was copied in as a file, so that tree's `git log`
  is one step behind its contents. Do the same for a fresh one; with #6
  in, take the test files from `session-leak`, where `session_leak` has no
  `atf_expect_fail`.
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
  Use `sudo sh /tmp/runvm-stdio.sh /zroot/vm/kern-test.img X 2400` (the full
  suite takes 10 to 11 minutes plus boot; `server_reset_twice` and
  `session_leak` are 6 of them), then read `/tmp/kt2-X.log` and
  `/tmp/kt2-X.steps`.
- Payload `/tmp/nfstest-vm/`: `run.sh` (below), `vnet.subr` from
  `tests/sys/common`, `nfs/` with the test files copied from the branch
  (`basic_test.sh`, `recovery_test.sh`, `krb5_test.sh`,
  `delegation_test.sh`, `nfs.subr`, `nfs_reset_proxy.py`), the patched
  `nfscbd`, and `python.tgz` built with
  `cd /usr/local && tar -czf /tmp/nfstest-vm/python.tgz --exclude 'lib/python3.12/site-packages/*' --exclude 'lib/python3.12/test' --exclude '__pycache__' bin/python3.12 bin/python3 lib/libpython3.12.so.1.0 lib/libpython3.12.so lib/libintl.so.8 lib/libintl.so.8.* lib/python3.12`.
- To run the tests as a release installs them (what reviewers will do):
  `mtree -deU -f etc/mtree/BSD.tests.dist -p $R/usr/tests`, then in
  `tests/sys/fs/nfs` `MAKEOBJDIRPREFIX=/tmp/nfstests-obj make` and
  `make install DESTDIR=$R INSTALL="install -U -M /tmp/nfstests.meta -D $R"`
  (unprivileged), add `tests/sys/common/vnet.subr`, tar `usr/tests` into the
  payload, unpack it over `/` in the VM and run
  `kyua test -k /usr/tests/sys/fs/nfs/Kyuafile` (what `make check` runs).
  The VM image does not copy the host's `/usr/tests` (`mkvm.sh` copies
  only part of the base system), so ship `vnet.subr` too. Check the
  exclusivity kyua uses with `kyua list -v`, not `kyua report`.
- `/tmp` may be gone after a reboot; recreate both scripts from below. The
  scratch worktrees `/tmp/nfsall-src`, `/tmp/nfscbd-src`, `/tmp/nfsleak-src`,
  `/tmp/nfsnew-src`, `/tmp/nfsfinal-src` are then stale entries: `git -C ~/freebsd-src worktree prune`. The
  experiment scripts of this session were in `/tmp/delegexp`,
  `/tmp/dyingexp` and `/tmp/delegexp-tools/rpcdump.py` (prints every RPC
  call and reply of a port 2049 pcap).

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
for t in delegation_test:recall krb5_test:krb5 krb5_test:krb5i krb5_test:krb5p krb5_test:server_freed basic_test:basic basic_test:v3_basic basic_test:v40_basic basic_test:v40_server_freed basic_test:two_clients recovery_test:server_reset recovery_test:server_reset_twice recovery_test:session_leak; do
	step "test $t"
	timeout -s KILL 400 kyua debug -k Kyuafile $t 2>&1 | grep -v '^Executing command' | tee -a /root/steps.log
	sync
done
step done
sleep 70	# let the client jails' TCP TIME_WAIT end
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
- In an experiment, destroying a client jail's interface before a plain
  `umount` hangs it for good ("not responding"): use `umount -f` under
  `timeout`.
- To see what holds a dying jail: `ddb script kdb.enter.sysctl="show prison; c"`
  then `sysctl debug.kdb.enter=1` (NODEBUG has DDB); `ref`/`uref` land on
  the console log.
- A rebase or cherry-pick makes the global identity the committer: amend
  with `-c user.email=olivier@FreeBSD.org` and check `%cn <%ce>`.
- In atf, a failing cleanup makes the result "broken", not "failed": put
  a check that must fail the test in the body (as `nfs_jail_remove` does).
- To update a scratch build tree with a changed branch, copy the changed
  files from the branch worktree (`cmp` them) after checking that no other
  scratch patch touches them; `git checkout` plus `git apply` there lost
  #9 once, and the kernels built without it.
- My git diffs have no `a/` `b/` prefix: `git apply -p0`.
- ccache on this host has served stale objects before: build kernels with
  `CCACHE_DISABLE=1` and check new symbols with `nm`.

**Conventions:** NFS patches and write-ups go in `~/myscripts/FreeBSD/nfsbug/`
(not `docs/`). Every patch gets a student-level write-up (background,
measured problem, fix and alternatives, tested table). Never claim an
untested result. Do not commit or push without asking.
