#!/bin/sh
# QEMU UEFI boot testbed: two ways to get FreeBSD booted under EFI, one of
# which uses the network to reach the kernel and one of which does not.
# (Named qemu-uefi-ipxe.sh until the --mdroot mode, which involves no iPXE at
# all, grew into the bulk of the script.)
#
# VM setup:
# EFI boot method
# NIC with qemu as DHCP server serving a specific small-network-boot-file using TFTP
# Empty disk (to be used to test the installation of the small-network-boot-file)
#
# Modes:
#   (no argument)  iPXE from a local ESP, chainloading a PE payload over TFTP.
#                  This is the UEFI + iPXE netboot case.
#
#   --mdroot       build a kernel with the root filesystem embedded (MD_ROOT)
#                  and boot it from a local ESP. Strictly speaking this is
#                  NOT a netboot and NOT iPXE: the firmware LoadImage()s
#                  loader.efi from the local FAT ESP and iPXE is not in the
#                  path at all. It lives in this script because it is the
#                  answer to "how do I get HTTP into the FreeBSD boot path" -
#                  namely, you do not (the loader speaks only TFTP and NFS),
#                  you remove the boot-time network instead. Only applicable
#                  when you control local media: ESP, USB, OpenBMC virtual
#                  flash, iSCSI-attached firmware volume. A genuinely
#                  diskless machine still needs the two-stage TFTP miniroot.
#                  With --stage2 the network IS used, but only by userland
#                  after root mount - never to reach /sbin/init.
#                  See ~/myscripts/FreeBSD/iPXE.md section 8.

arch=x86_64

usage() {
  cat <<'EOF'
usage: qemu-uefi-boot.sh [--mdroot [--stage2] [--build-only|--boot-only]]
                         [--help]

  (default)     boot iPXE from a local ESP; iPXE chains PAYLOAD over TFTP.
                Override the payload with PAYLOAD=fbsd-loader.efi.

  --mdroot      MD_ROOT test: build a self-contained kernel (root filesystem
                embedded in the kernel image) and boot it from an ESP with no
                network device. Proves TFTP/NFS are not needed at all.
                Requires /usr/src, /usr/obj and root (for buildkernel).
     --stage2       stage 1 then goes on to: dhclient, read a UEFI variable
                    with efivar, HTTPS-fetch base.txz + kernel.txz and extract
                    them onto a swap-backed memory disk, then reroot into it.
                    Needs a working outbound network and downloads ~200MB.
     --build-only   build the image and kernel, do not boot
     --boot-only    boot an already-built kernel, do not rebuild

environment (--mdroot):
  KERNCONF   kernel config name              (default MDROOT)
  MDSIZE_KB  KB reserved by MD_ROOT_SIZE     (default 24576, auto-grown
                                             to fit the built image)
  JOBS       make -j value                   (default from hw.ncpu)
  WORKDIR    scratch directory               (default ./mdroot-work)
  MDROOT_EXTRA_BINS  extra binaries to add with their libraries
  FALLBACK_DNS  resolv.conf seed if DHCP gives none  (default 10.0.2.3,
                                             qemu's SLIRP resolver)
environment (--stage2):
  DIST_URL   release dir holding the .txz sets  (default 15.1-RELEASE/amd64)
  DIST_SETS  sets to extract                    (default "base kernel")
  VM_RAM     qemu RAM                        (default 4G, 8G with --stage2)
  STAGE2_MDSIZE  size of the md built into the new root  (default 2g;
                                    base+kernel extract to roughly 1.4G)
EOF
}

mode=ipxe
mdroot_stage=all
stage2=no
while [ $# -gt 0 ]; do
  case "$1" in
    --mdroot)     mode=mdroot ;;
    --stage2)     stage2=yes ;;
    --build-only) mdroot_stage=build ;;
    --boot-only)  mdroot_stage=boot ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

# EFI:
# This file could be anywere depending of the OS and qemu version
paths="
/opt/homebrew/Cellar/qemu/*/share/qemu/edk2-${arch}-code.fd
/Applications/UTM.app/Contents/Resources/qemu/edk2-${arch}-code.fd
/usr/local/share/qemu/edk2-${arch}-code.fd
/usr/share/qemu/edk2-${arch}-code.fd
"
efi=""
for path in ${paths}; do
  # Use ls to handle wildcards, suppress errors
  for found in $(ls $path 2>/dev/null); do
    if [ -f "$found" ]; then
      efi="$found"
    fi
  done
done

qefi="-drive if=pflash,readonly=on,format=raw,file=${efi}"

if [ -z "${efi}" ]; then
  echo "no edk2 firmware found; looked in:" >&2
  echo "${paths}" >&2
  exit 1
fi

# ---------------------------------------------------------------- --mdroot ---
# Build a kernel whose root filesystem is embedded inside the kernel image, so
# the loader has nothing left to fetch: no TFTP, no NFS, no network device.
#
# How it works (all in base, no patches):
#   sys/conf/options            defines MD_ROOT / MD_ROOT_SIZE / MD_ROOT_FSTYPE
#   sys/dev/md/md.c             reserves u_char mfs_root[MD_ROOT_SIZE*1024]
#                               in an ELF section named "oldmfs"
#   sys/conf/kern.post.mk       runs tools/embed_mfs.sh when MFS_IMAGE is set
#
# embed_mfs.sh writes INTO that reserved array, so MD_ROOT_SIZE must be >= the
# image; it cannot grow the kernel.
#
# The root must be fully self-contained: at mountroot time there is no network
# and no other filesystem, so every binary's shared libraries must be present.
# /rescue guarantees that for free - one statically linked crunched binary
# reached through ~150 hardlinks, containing init, sh, fetch, mdconfig, newfs,
# kenv and reboot. A root assembled from dynamic binaries instead fails with
# "ld-elf.so.1: Shared object libedit.so.8 not found, required by sh".
#
# Anything NOT in /rescue (efivar, for instance) is dynamic and must be added
# with its libraries - see add_binary() below.

# add_binary <path> [more...] - copy a binary into ${root} with every shared
# library it needs, preserving the original paths.
#
# FreeBSD's ldd output is already transitive (a dependency's own dependencies
# are listed too), so one pass is enough. Two things ldd never prints and that
# must be handled by hand:
#   ld-elf.so.1  the runtime linker itself - without it every dynamic binary
#                dies with "ELF interpreter /libexec/ld-elf.so.1 not found"
#   [vdso]       kernel-provided, not a file
# Libraries opened with dlopen() are also invisible to ldd; none of the
# binaries used here do that, but a NSS/PAM-using binary would need more.
add_binary() {
  for bin in "$@"; do
    if ! [ -f "${bin}" ]; then
      echo "add_binary: no such file: ${bin}" >&2; return 1
    fi
    mkdir -p "${root}$(dirname "${bin}")"
    cp "${bin}" "${root}${bin}"
    chmod u+rw,a+x "${root}${bin}"

    # static binaries need nothing further
    if ! file "${bin}" | grep -q 'dynamically linked'; then
      echo "  ${bin} (static)"
      continue
    fi

    echo "  ${bin}"
    # ldd columns: "libfoo.so.1 => /lib/libfoo.so.1 (0x...)"; keep field 3,
    # skipping [vdso] and any "not found" line.
    ldd "${bin}" 2>/dev/null | awk '/=>/ && $3 ~ /^\// {print $3}' | sort -u |
    while read -r lib; do
      [ -f "${lib}" ] || continue
      mkdir -p "${root}$(dirname "${lib}")"
      [ -f "${root}${lib}" ] || { cp "${lib}" "${root}${lib}"; chmod u+rw "${root}${lib}"; echo "    + ${lib}"; }
    done

    # the runtime linker, which ldd does not list
    if [ -f /libexec/ld-elf.so.1 ] && ! [ -f "${root}/libexec/ld-elf.so.1" ]; then
      mkdir -p "${root}/libexec"
      cp /libexec/ld-elf.so.1 "${root}/libexec/ld-elf.so.1"
      chmod u+rw,a+x "${root}/libexec/ld-elf.so.1"
      echo "    + /libexec/ld-elf.so.1 (ELF interpreter)"
    fi
  done
}

# check_missing_lib - same test as ~/myscripts/FreeBSD/check_missing_lib.sh,
# but aimed at the staged root instead of the live system: every dynamic
# binary must resolve all of its libraries INSIDE ${root}.
#
# ldd cannot be pointed at an alternate root, so use the runtime linker's own
# LD_LIBRARY_PATH plus a manual soname check - a copied library that pulls in
# something we forgot shows up here rather than as a boot failure.
check_missing_lib() {
  missing=""
  for f in $(find "${root}" -type f -perm +111 2>/dev/null); do
    file "${f}" | grep -q 'dynamically linked' || continue
    for soname in $(ldd "${f}" 2>/dev/null | awk '/=>/ && $1 !~ /vdso/ {print $1}'); do
      found=""
      for d in /lib /usr/lib /usr/local/lib; do
        [ -f "${root}${d}/${soname}" ] && { found=1; break; }
      done
      [ -n "${found}" ] || missing="${missing}${f}: ${soname}
"
    done
    [ -f "${root}/libexec/ld-elf.so.1" ] || missing="${missing}${f}: /libexec/ld-elf.so.1
"
  done
  if [ -n "${missing}" ]; then
    echo "ERROR: binaries with libraries missing from the root:" >&2
    printf '%s' "${missing}" >&2
    return 1
  fi
  echo "OK: no missing libraries in ${root}"
}

mdroot_build() {
  [ -d /usr/src/sys ] || { echo "--mdroot needs /usr/src" >&2; exit 1; }

  root="${workdir}/root"
  echo "=== building root filesystem in ${root} ==="
  rm -rf "${root}"
  mkdir -p "${root}"/dev "${root}"/etc/ssl "${root}"/tmp \
           "${root}"/var/run "${root}"/var/db "${root}"/var/empty \
           "${root}"/rescue "${root}"/bin "${root}"/sbin "${root}"/mnt

  # ln, NOT cp: makefs preserves hardlinks, so the ~20MB payload is stored
  # once. Copying would multiply it by the number of rescue tools.
  cp -p /rescue/rescue "${root}/rescue/rescue"
  for f in $(ls /rescue/); do
    [ "${f}" = rescue ] || ln "${root}/rescue/rescue" "${root}/rescue/${f}"
  done
  ln "${root}/rescue/rescue" "${root}/sbin/init"  # kernel execs /sbin/init by name
  ln "${root}/rescue/rescue" "${root}/bin/sh"

  # dhclient hardcodes the helper as an absolute path with no override:
  # sbin/dhclient/clparse.c:52 has
  #     static char client_script_name[] = "/sbin/dhclient-script";
  # so it MUST exist at /sbin/dhclient-script. Without it the lease is
  # OFFERed, the helper fails to exec, and dhclient DECLINEs and retries
  # forever:
  #     execve (/sbin/dhclient-script, ...): No such file or directory
  #     DHCPOFFER from 10.0.2.2 / DHCPDECLINE on vtnet0    (loops)
  for t in dhclient ifconfig route hostname; do
    [ -e "${root}/sbin/${t}" ] || ln "${root}/rescue/rescue" "${root}/sbin/${t}"
  done

  # dhclient-script is a /bin/sh SCRIPT, not a compiled tool, so it is NOT in
  # the crunched /rescue binary - hardlinking rescue to that name only yields
  #     rescue: dhclient-script not compiled in
  # followed by a usage dump, and dhclient silently never configures the
  # interface. Copy the real one and the helpers it shells out to.
  cp /sbin/dhclient-script "${root}/sbin/dhclient-script"
  chmod u+rw,a+x "${root}/sbin/dhclient-script"
  add_binary /usr/bin/logger /usr/bin/cmp /bin/chmod /usr/sbin/chown || exit 1

  # Tools that are NOT in /rescue, with their libraries.
  #   efivar    reads UEFI variables through /dev/efi (efirt is compiled into
  #             GENERIC - it is NOT a module, and nvdimm.ko is unrelated: that
  #             belongs to the /dev/pmem path, not to md_image).
  #   arp       called by dhclient-script, and absent from /rescue.
  #
  # /rescue is a crunched binary with a fixed tool list: sed, cat, head and
  # tail are in it, but grep, awk, wc, tr, stat, printf and mktemp are NOT.
  # A missing one fails as "/etc/rc: wc: not found" and silently empties any
  # $(...) that used it - which is exactly how an efivar read that actually
  # worked got misreported as returning nothing.
  echo "=== adding dynamic binaries and their libraries ==="
  add_binary /usr/bin/grep /usr/bin/awk /usr/bin/wc /usr/bin/tr \
             /usr/bin/stat /usr/bin/printf /usr/bin/mktemp \
             /usr/sbin/arp /usr/sbin/efivar || exit 1
  for extra in ${MDROOT_EXTRA_BINS:-}; do add_binary "${extra}" || exit 1; done

  # CA bundle: fetch(1) verifies peers by default, and without this every
  # HTTPS transfer fails with "Authentication error".
  cp /etc/ssl/cert.pem "${root}/etc/ssl/cert.pem"

  # dhclient drops privileges to _dhcp and chroots to /var/empty, so it needs
  # real passwd/group databases. Without them it prints
  #   "no such user: _dhcp, falling back to nobody" / "no such user: nobody"
  # and exits, leaving the interface unconfigured.
  #
  # Synthesised rather than copied from the host: pwd_mkdb needs
  # master.passwd format (10 fields, not the 7 of /etc/passwd), reading the
  # host's master.passwd needs root, and it would bake the host's password
  # hashes into the image. Locked accounts (*) are all stage 1 needs.
  cat > "${root}/etc/master.passwd" <<'PWEOF'
root:*:0:0::0:0:Charlie &:/root:/rescue/sh
_dhcp:*:65:65::0:0:dhcp programs:/var/empty:/usr/sbin/nologin
nobody:*:65534:65534::0:0:Unprivileged user:/nonexistent:/usr/sbin/nologin
PWEOF
  # operator (gid 5) is not decorative: newfs looks it up to own the device it
  # creates, and without it every memory-disk creation prints
  #     newfs: Cannot retrieve operator gid, using gid 0
  # Members are deliberately omitted - the host's operator line lists real host
  # usernames, which have no business in the image.
  cat > "${root}/etc/group" <<'GREOF'
wheel:*:0:root
operator:*:5:
_dhcp:*:65:
nobody:*:65534:
GREOF
  chmod 600 "${root}/etc/master.passwd"
  pwd_mkdb -p -d "${root}/etc" "${root}/etc/master.passwd" || exit 1
  # dhclient writes a lease database and a pidfile. The pidfile path is built
  # in dhclient.c:426 as "${_PATH_VARRUN}/dhclient/dhclient.<if>.pid", so the
  # dhclient SUBDIRECTORY must exist or it dies with
  #     Cannot open or create pidfile: No such file or directory
  mkdir -p "${root}/var/db" "${root}/var/run/dhclient" "${root}/var/empty"

  # Resolver configuration. Without nsswitch.conf the hosts lookup order is
  # undefined and name resolution fails even with a correct resolv.conf, so
  # fetch(1) reports failure with a valid address and default route - which
  # reads as "HTTPS is broken" when the real fault is DNS.
  # host.conf is the legacy fallback; services is needed to map "https" to 443.
  printf 'hosts: files dns\n' > "${root}/etc/nsswitch.conf"
  printf 'hosts\ndns\n' > "${root}/etc/host.conf"
  printf '::1 localhost\n127.0.0.1 localhost\n' > "${root}/etc/hosts"
  cp /etc/services "${root}/etc/services"
  # dhclient-script installs the real one from the lease; seed a resolver so a
  # DHCP failure does not also silently break name resolution. The default is
  # qemu's SLIRP resolver - override with FALLBACK_DNS on a real network.
  printf 'nameserver %s\n' "${FALLBACK_DNS:-10.0.2.3}" > "${root}/etc/resolv.conf"

  # login.conf.db, else init logs "login_getclass: unknown class 'daemon'"
  cp /etc/login.conf "${root}/etc/login.conf"
  cap_mkdb -f "${root}/etc/login.conf" "${root}/etc/login.conf"

  echo "=== checking for missing libraries ==="
  check_missing_lib || exit 1

  printf 'console="comconsole"\n' > "${root}/etc/rc.conf"

  # Stage 1 always proves the embedded root works. With --stage2 it goes on to
  # DHCP, read a UEFI variable, HTTPS-fetch the .txz sets, extract them onto a
  # swap-backed memory disk, and reroot into it.
  cat > "${root}/etc/rc" <<RCEOF
#!/rescue/sh
# Stage 1: the embedded root is live. Nothing was fetched to get here.
# /usr/bin matters: add_binary stages grep/awk/wc/tr/stat/printf/mktemp there,
# and leaving it off PATH reproduces the exact "grep: not found" that a missing
# binary would cause - staged but unreachable looks identical to absent.
PATH=/rescue:/bin:/sbin:/usr/bin:/usr/sbin; export PATH
# fetch(1) verifies peers; point it at the bundle we embedded.
SSL_CA_CERT_FILE=/etc/ssl/cert.pem; export SSL_CA_CERT_FILE
STAGE2="${stage2:-no}"
DIST_URL="${dist_url}"
DIST_SETS="${dist_sets}"
MDSIZE="${stage2_mdsize}"
RCEOF
  cat >> "${root}/etc/rc" <<'RCEOF'
say() { echo "STAGE1: $*"; }

echo "=========================================="
echo " MDROOT stage 1: embedded md root is live"
echo " root: $(kenv vfs.root.mountfrom 2>/dev/null)"
echo "=========================================="
mount -u -o rw / 2>/dev/null
mount
echo "--- MDROOT-STAGE1-OK ---"

[ "${STAGE2}" = yes ] || exec /rescue/sh

say "--- network: dhclient ---"
# dhclient forks, chroots to /var/empty and drops to _dhcp, and it writes a
# pidfile plus a lease database. Those paths must exist and be writable, and
# the root was mounted read-only until the mount -u above.
mkdir -p /var/run/dhclient /var/db /var/empty /tmp 2>/dev/null
for i in $(ifconfig -l); do
  [ "${i}" = lo0 ] && continue
  ifconfig "${i}" up
  # FreeBSD dhclient takes only [-bdnqu] (dhclient.c:389 getopt "bc:dl:np:qu")
  # - there is no -1/onetry as in the ISC and OpenBSD versions. -b backgrounds
  # instead of blocking until a lease, so a root that makes dhclient DECLINE
  # every offer cannot wedge stage 2 forever.
  # Not silenced: its own error text is the only useful diagnostic here.
  dhclient -b "${i}" && break
done

# Every tool this script needs must be REACHABLE, not merely present: fail
# loudly once instead of emitting "foo: not found" from inside a loop.
# Keep this list in sync with what the script actually calls - it was missing
# the one tool a later edit introduced (sort, absent from /rescue), which is
# exactly the failure it exists to catch. gpart/fsck_ffs/mount/umount are the
# reroot block's dependencies; sort is deliberately NOT used anywhere.
for t in grep awk wc stat ifconfig route fetch mdconfig newfs kenv reboot \
         gpart fsck_ffs mount umount ls; do
  command -v "${t}" >/dev/null || say "MISSING-TOOL ${t} (PATH=${PATH})"
done

# -b returns before the lease is bound, so wait for an actual address rather
# than racing straight into fetch(1) and blaming HTTPS for a missing route.
n=0
while [ "${n}" -lt 30 ]; do
  ifconfig | grep -q 'inet 1' 2>/dev/null && break
  sleep 1; n=$((n + 1))
done
ifconfig -a | grep -E '^[a-z]|inet '
route -n get default 2>&1 | head -3
if ifconfig | grep -q 'inet 1'; then
  say "DHCP-OK $(ifconfig | grep 'inet 1' | head -1)"
else
  say "DHCP-FAIL no address after ${n}s"
fi

say "--- UEFI environment variable (efivar, needs efirt in GENERIC) ---"
# PlatformLang lives in the EFI global variable GUID and is present on
# essentially every implementation, so it is a safe read-only probe.
efivar -p -n 8be4df61-93ca-11d2-aa0d-00e098032b8c-PlatformLang 2>&1 | head -2
say "efivar listed $(efivar -l 2>/dev/null | wc -l) variables"
# The loader also hands over its own view for free, no efivar needed:
say "loader kenv: efi-version=$(kenv efi-version 2>/dev/null) loader.efi=$(kenv loader.efi 2>/dev/null)"

say "--- HTTPS probe ---"
# Not -q and not silenced: when this fails the reason (DNS vs TLS vs route) is
# the whole point of the probe. Show what resolution has to work with first.
say "resolv.conf: $(cat /etc/resolv.conf 2>&1 | tr '\n' ';')"
if fetch -o /tmp/probe -T 30 https://download.freebsd.org/; then
  say "HTTPS-OK $(stat -f %z /tmp/probe) bytes"
else
  say "HTTPS-FAIL"; exec /rescue/sh
fi

say "--- memory disk for the new root ---"
# THE NEW ROOT'S DEVICE MUST NOT DEPEND ON THE OLD ROOT'S FILESYSTEM.
#
# The previous design fetched the memstick .img onto a swap md, attached it as a
# vnode md, and rerooted onto its partition. That cannot work: reboot -r
# unmounts the old root to mount the new one, but the vnode md's backing file
# lived on a filesystem mounted UNDER that old root, so the reroot destroyed the
# storage chain the new root stood on:
#     Trying to mount root from ufs:/dev/md2s2a []...
#     g_vfs_done():md2s2a[READ(offset=65536,length=8192)]error = 6   (ENXIO)
#     Attempted recovery for standard superblock: failed
#     panic: ffs_use_bread: non-NULL *bufp
# (the panic is a kernel bug of its own - ffs_use_bread asserts instead of
# returning the I/O error - but the ENXIO is the design fault).
#
# So: build the new root DIRECTLY on a swap-backed md and extract base.txz +
# kernel.txz into it. Swap-backed memory has no vnode and no parent filesystem,
# so it survives the old root going away. The tarballs are also 199MB total
# versus 647MB for the memstick, and are streamed through tar so the .txz is
# never stored at all.
#
# swap-backed md: pages are only committed as written, so this does not need
# MDSIZE of RAM up front.
mdconfig -a -t swap -s "${MDSIZE}" -u 1 || { say "MD-FAIL"; exec /rescue/sh; }
newfs -U /dev/md1 >/dev/null || { say "NEWFS-FAIL"; exec /rescue/sh; }
mount /dev/md1 /mnt || { say "MOUNT-FAIL"; exec /rescue/sh; }
say "md1 (${MDSIZE}) newfs'd and mounted on /mnt"

# Stream each tarball straight into tar: "fetch -o -" to stdout, tar reading
# stdin. Nothing is written to disk except the extracted tree, so /mnt only
# needs to hold the EXTRACTED size (~1.4G for base+kernel), not the tarballs
# too. tar and xz are both compiled into /rescue (verified), and tar detects
# the xz compression itself.
for comp in ${DIST_SETS:-base kernel}; do
  url="${DIST_URL}/${comp}.txz"
  say "extracting ${url} into /mnt"
  # pipefail is REQUIRED here, not decorative: without it the pipeline reports
  # only tar's status, so a truncated or failed download whose partial stream
  # still extracts cleanly would be recorded as EXTRACT-OK. Verified that
  # /rescue/sh supports "set -o pipefail" and that without it a failing left
  # side is invisible.
  set -o pipefail
  # Not silenced: a truncated transfer and a tar format error look identical
  # from the exit status alone, and this is the step most likely to fail.
  # -q: the progress meter is redrawn on a serial console with no carriage
  # returns, so it added thousands of "156 MB 1234 kBps" lines to the boot log
  # and buried the markers. Errors still print - only the meter is suppressed.
  if ! fetch -q -o - -T 900 "${url}" | tar -xpf - -C /mnt; then
    say "EXTRACT-FAIL ${comp}"
    exec /rescue/sh
  fi
  say "EXTRACT-OK ${comp}"
done

# Prove the extraction produced a root, before betting a reroot on it. These are
# the same two markers the old probe pass required of a candidate partition.
if [ -x /mnt/sbin/init ] && [ -f /mnt/boot/kernel/kernel ]; then
  say "NEWROOT-OK /mnt has /sbin/init + /boot/kernel/kernel"
else
  say "NEWROOT-BAD missing init or kernel after extract"
  exec /rescue/sh
fi

# The new root must be able to mount itself: without an fstab it comes up and
# then cannot find its own root read-write.
printf '/dev/md1\t/\tufs\trw\t1\t1\n' > /mnt/etc/fstab

# Keep the box reachable/quiet on the far side rather than blocking on config.
printf 'hostname="stage2"\nifconfig_DEFAULT="DHCP"\nsendmail_enable="NONE"\n' \
  >> /mnt/etc/rc.conf

# Proof-of-life from INSIDE the new root. rc.local runs late in the real
# multi-user boot, which cannot happen at all unless the root mounted and
# /sbin/init from the extracted tree took over - so this line appearing on the
# serial console is the difference between "reroot issued" and "reroot worked".
cat > /mnt/etc/rc.local <<'RCLEOF'
#!/bin/sh
echo "STAGE2-ROOT-LIVE $(uname -sr) root=$(mount | sed -n 's| on / .*||p')"
RCLEOF
chmod +x /mnt/etc/rc.local

say "--- rerooting into the extracted root ---"
# No partition probing here, and no GEOM tasting: md1 IS the filesystem. The
# extract already proved it carries /sbin/init + /boot/kernel/kernel, so there
# is exactly one candidate and it is already verified. (The probe pass the
# vnode design needed - enumerate /dev/mdN*, longest name first, test-mount
# each, require init+kernel so the 0xEF ESP is rejected - worked correctly and
# is preserved in the memory notes; it is simply unnecessary once the root is
# built directly on the md instead of being a disk image inside a file.)
#
# Unmount nothing else and destroy nothing else: md1 must stay attached, it is
# the device we are about to boot from. Sync first so the extracted tree is on
# the md and not sitting in the buffer cache when the old root goes away.
sync

# Flush the extracted tree, then hand the mount over to the kernel. /mnt itself
# is unmounted so the new root is not also mounted somewhere under the old one
# when reboot -r runs; md1 stays attached because it is the boot device.
umount /mnt || say "WARN: umount /mnt failed, rerooting anyway"

say "REROOT-INTO /dev/md1"
kenv vfs.root.mountfrom="ufs:/dev/md1"
# reboot -r needs tmpfs.ko: do not build with WITHOUT_MODULES=yes.
reboot -r
sleep 30
say "REROOT-FAILED: reboot -r did not take (tmpfs.ko missing?)"
sleep 30
say "REROOT-FAILED: reboot -r did not take (tmpfs.ko missing?)"
exec /rescue/sh
RCEOF
  chmod 755 "${root}/etc/rc"

  # Size the filesystem from what makefs actually needs, not from du: du
  # counts a hardlinked inode once, so it reports ~17k for the 20MB /rescue
  # tree and badly underestimates the image. Run makefs without -s to get its
  # own idea of the size, then add headroom and round up to a whole MB so
  # MD_ROOT_SIZE stays readable.
  rm -f "${workdir}/mdroot.img"
  makefs -t ffs -o version=2 "${workdir}/mdroot.img" "${root}" || exit 1
  natural_kb=$(( $(stat -f %z "${workdir}/mdroot.img") / 1024 ))
  want_kb=$(( natural_kb * 120 / 100 ))
  [ "${want_kb}" -lt "${mdsize_kb}" ] && want_kb="${mdsize_kb}"
  mdsize_kb=$(( (want_kb + 1023) / 1024 * 1024 ))

  echo "=== makefs -s ${mdsize_kb}k (natural size ${natural_kb}k) ==="
  rm -f "${workdir}/mdroot.img"
  makefs -t ffs -o version=2 -s "${mdsize_kb}k" \
    "${workdir}/mdroot.img" "${root}" || exit 1

  # MD_ROOT_SIZE must be >= the image, so derive the config from the image.
  echo "=== writing /usr/src/sys/${machine}/conf/${kernconf} ==="
  ${SUDO} sh -c "cat > /usr/src/sys/${machine}/conf/${kernconf}" <<EOF
include GENERIC
ident		${kernconf}

# Embedded memory-disk root: the kernel IS the whole system.
options 	MD_ROOT			# md device can be root
options 	MD_ROOT_SIZE=${mdsize_kb}	# KB reserved for the embedded image
options 	MD_ROOT_FSTYPE=ufs
options 	ROOTDEVNAME=\\"ufs:/dev/md0\\"
EOF

  echo "=== buildkernel KERNCONF=${kernconf} MFS_IMAGE=${workdir}/mdroot.img ==="
  # WITHOUT_CCACHE_BUILD=1: ccache can serve stale module .o files, giving
  # "KLD foo.ko: depends on kernel - not available or version mismatch".
  ( cd /usr/src && ${SUDO} make -j"${jobs}" buildkernel \
      KERNCONF="${kernconf}" \
      MFS_IMAGE="${workdir}/mdroot.img" \
      WITHOUT_CCACHE_BUILD=1 ) || exit 1

  # Prove the image really landed in the reserved section, rather than
  # trusting the build log.
  kern="/usr/obj/usr/src/${machine}.${machine}/sys/${kernconf}/kernel"
  [ -f "${kern}" ] || { echo "no kernel at ${kern}" >&2; exit 1; }
  echo "=== verifying embedded image ==="
  objdump -h "${kern}" | grep -i oldmfs
  objcopy -O binary --only-section=oldmfs "${kern}" "${workdir}/extracted.img"
  # objcopy dumps the whole reserved section, so trim to the source length
  # before comparing - otherwise cmp reports a harmless EOF on the shorter file.
  dd if="${workdir}/extracted.img" of="${workdir}/trimmed.img" \
     bs=1024 count="${mdsize_kb}" 2>/dev/null
  if cmp "${workdir}/trimmed.img" "${workdir}/mdroot.img"; then
    echo "OK: embedded bytes are identical to mdroot.img"
  else
    echo "FAIL: embedded image does not match mdroot.img" >&2
    exit 1
  fi
}

mdroot_boot() {
  kern="/usr/obj/usr/src/${machine}.${machine}/sys/${kernconf}/kernel"
  [ -f "${kern}" ] || {
    echo "no kernel at ${kern} - run without --boot-only first" >&2; exit 1; }

  # A plain ESP: the loader, the self-contained kernel, and nothing else.
  # Files must be readable by the user running qemu, or fat:rw: fails with
  # "Could not open ... (Permission denied, 13)" / "Error handling commits".
  esp="${workdir}/esp"
  rm -rf "${esp}"
  mkdir -p "${esp}/EFI/BOOT" "${esp}/boot/kernel" "${esp}/boot/defaults"
  cp /boot/loader.efi "${esp}/EFI/BOOT/BOOTX64.EFI"
  cp "${kern}" "${esp}/boot/kernel/kernel"
  cp /boot/defaults/loader.conf "${esp}/boot/defaults/loader.conf"
  cp -R /boot/lua "${esp}/boot/"
  printf 'autoboot_delay="0"\nconsole="comconsole"\n' > "${esp}/boot/loader.conf"
  chmod -R u+rw "${esp}"

  log="${workdir}/mdroot-boot.log"
  rm -f "${log}"

  if [ "${stage2}" = yes ]; then
    # Stage 2 needs outbound IP, so give the VM a NIC on SLIRP. Note this is
    # the guest's OWN network stack in userland - not a boot protocol. The
    # boot itself still used no network at all.
    qnet="-netdev user,id=net0 -device virtio-net-pci,netdev=net0"
    echo "=== booting WITH a NIC (stage 2 fetches over HTTPS) ==="
    echo "    dist: ${dist_url} [${dist_sets}]"
    # -no-reboot would kill the VM at reboot -r, which is exactly the step
    # being tested, so allow the reboot here.
    qreboot=""
  else
    qnet=""
    echo "=== booting with NO network device; serial -> ${log} ==="
    qreboot="-no-reboot"
  fi
  # With no --stage2 there is deliberately no -netdev and no -boot n: if this
  # boots, no network protocol was involved after the firmware handed over.
  timeout "${boot_timeout}" qemu-system-${arch} -m "${vm_ram}" -smp 2 ${qefi} \
    -drive "file=fat:rw:${esp},format=raw,if=virtio" \
    ${qnet} -display none -serial "file:${log}" ${qreboot}

  echo "=== result ==="
  grep -aE "Embedded image|Trying to mount root|MDROOT-STAGE1-OK|STAGE1:|on / \(ufs|ld-elf|panic" "${log}"
  if ! grep -aq -- "--- MDROOT-STAGE1-OK ---" "${log}"; then
    echo "FAIL: embedded root did not boot; see ${log}" >&2
    exit 1
  fi
  echo "PASS: booted from the embedded root with zero network transfers"

  if [ "${stage2}" = yes ]; then
    # "reroot issued" is NOT "reroot worked": an earlier run printed
    # REROOT-INTO and "Trying to mount root from ufs:/dev/md2s2a", then panicked
    # four lines later with ENXIO because the new root's backing file lived on
    # the old root. Check for the new root actually RUNNING (init started there,
    # which cannot happen unless the mount succeeded), and fail on the panic.
    for probe in \
      "HTTPS-OK:HTTPS fetch works from the embedded root" \
      "EXTRACT-OK base:base.txz extracted onto the swap-backed md" \
      "EXTRACT-OK kernel:kernel.txz extracted onto the swap-backed md" \
      "NEWROOT-OK:extracted tree has init + kernel" \
      "REROOT-INTO:reroot issued into the new root" \
      "STAGE2-ROOT-LIVE:the fetched root actually booted"
    do
      pat="${probe%%:*}"; desc="${probe#*:}"
      if grep -aq "${pat}" "${log}"; then
        echo "PASS: ${desc}"
      else
        echo "FAIL: ${desc} (no '${pat}' in ${log})" >&2
        exit 1
      fi
    done

    # A panic can leave the earlier markers intact, so check for it explicitly
    # instead of inferring health from the markers alone.
    if grep -aq '^panic:' "${log}"; then
      echo "FAIL: kernel panicked: $(grep -a -m1 '^panic:' "${log}")" >&2
      exit 1
    fi
    # After reboot -r the second root runs its own /etc/rc; that is the proof
    # the reroot actually took effect rather than merely being requested.
    # md1 is the new root (built directly on the swap-backed md). This grepped
    # for md2 until the vnode-image design was removed, so it reported "no
    # second mountroot seen" about a log that contained exactly that line.
    if grep -aq "Trying to mount root from ufs:/dev/md1" "${log}"; then
      echo "PASS: kernel remounted root from the extracted tree"
    else
      echo "NOTE: reroot was issued but no second mountroot seen; check ${log}"
    fi
  fi
}

if [ "${mode}" = mdroot ]; then
  kernconf="${KERNCONF:-MDROOT}"
  mdsize_kb="${MDSIZE_KB:-24576}"
  jobs="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
  workdir="${WORKDIR:-$(pwd)/mdroot-work}"
  machine="$(uname -m)"
  # base.txz + kernel.txz, not a memstick .img: the new root is built directly
  # on the md, so what is needed is a distribution tarball set, not a disk image.
  dist_url="${DIST_URL:-https://download.freebsd.org/ftp/releases/amd64/15.1-RELEASE}"
  dist_sets="${DIST_SETS:-base kernel}"
  # base+kernel extract to roughly 1.4G, so 1g silently ran out of space.
  stage2_mdsize="${STAGE2_MDSIZE:-2g}"
  if [ "${stage2}" = yes ]; then
    # The image is fetched into a swap-backed md, so RAM must hold it.
    # RAM must hold the swap-backed md: the extracted root (~1.4G) lives in
    # memory, so do not shrink this below STAGE2_MDSIZE plus headroom.
    vm_ram="${VM_RAM:-8G}"
    # Covers the ~200MB download, the extract, AND a full multi-user boot of the
    # new root on the far side of reboot -r.
    boot_timeout="${BOOT_TIMEOUT:-1200}"
  else
    vm_ram="${VM_RAM:-4G}"
    # The VM idles at a shell once stage 1 finishes, so it must be killed.
    boot_timeout="${BOOT_TIMEOUT:-100}"
  fi
  if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
  mkdir -p "${workdir}"

  case "${mdroot_stage}" in
    all)   mdroot_build; mdroot_boot ;;
    build) mdroot_build ;;
    boot)  mdroot_boot ;;
  esac
  exit 0
fi
# -------------------------------------------------------------- end --mdroot -

# Payload iPXE will chain to. Must be a PE image ("MZ"). Default is
# netboot.xyz.efi; override with e.g. PAYLOAD=fbsd-loader.efi.
#
# NOT usable here: memdisk (16-bit BIOS bzImage, no UEFI build - chaining it
# gives "Could not boot: Exec format error"), so the old
# "initrd memstick.img / chain memdisk harddisk raw" recipe is BIOS-only.
payload="${PAYLOAD:-netboot.xyz.efi}"

if ! [ -f "${payload}" ]; then
  for d in fetch wget curl; do
    which -s $d && { download=$d; break; }
  done
  [ -n "${download:-}" ] || { echo "no fetch/wget/curl found" >&2; exit 1; }
  case "${payload}" in
    netboot.xyz.efi) ${download} https://boot.netboot.xyz/ipxe/netboot.xyz.efi ;;
    *) echo "missing payload ${payload}" >&2; exit 1 ;;
  esac
fi

if [ "$(od -A n -c -N 2 "${payload}" | tr -d ' ')" != "MZ" ]; then
  echo "warning: ${payload} is not a PE image (no MZ header); chain will fail" >&2
fi

# iPXE script, fetched over TFTP by iPXE itself (see delivery method below).
# 10.0.2.2 is qemu SLIRP's gateway, which also serves TFTP from $(pwd).
cat <<EOF >boot.ipxe
#!ipxe
echo === qemu-uefi-boot.sh ===
dhcp || goto fail
echo Got \${net0/ip}
chain tftp://10.0.2.2/${payload} || goto fail
:fail
echo SCRIPT FAILED
shell
EOF

# Why iPXE boots from a local ESP and not over the network:
#
#  1. FreeBSD's packaged edk2 has no usable UEFI network stack, so "-boot n"
#     is a silent no-op that falls through to the EFI Shell. (Not detectable
#     by grepping the .fd - the DXE volume is LZMA-compressed. Verify by
#     running "ifconfig -l" in the EFI Shell: it prints nothing.)
#  2. Even with a working stack, SLIRP's single unconditional bootfile= would
#     hand iPXE back to iPXE forever - it cannot match DHCP option 77.
#
# Booting ipxe.efi from an ESP solves both. iPXE then runs its OWN DHCP,
# picks up bootfile=boot.ipxe, and needs no EMBED= rebuild.
# See ~/myscripts/FreeBSD/iPXE.md sections 5d, 8 and 9.
ipxe_efi="/usr/local/share/ipxe/ipxe.efi-${arch}"
if ! [ -f "${ipxe_efi}" ]; then
  echo "missing ${ipxe_efi} - install the ipxe package: pkg install ipxe" >&2
  exit 1
fi
mkdir -p esp/EFI/BOOT
cp "${ipxe_efi}" esp/EFI/BOOT/BOOTX64.EFI

qesp="-drive file=fat:rw:esp,format=raw,if=virtio"

# NIC: qemu SLIRP acts as DHCP + TFTP server for iPXE (not for the firmware)

qpxe="-netdev user,id=net0,tftp=$(pwd),bootfile=boot.ipxe -device virtio-net-pci,netdev=net0"

# Empty disk
if ! [ -f disk.img ]; then
  truncate -s 4G disk.img
fi

qdisk="-drive if=virtio,file=disk.img,format=raw,media=disk"

#qconsole="-display none -serial mon:stdio"
qconsole=""

# No "-boot n": the firmware boots the ESP, and iPXE does the networking.
qemu-system-${arch} -m 4G ${qefi} ${qesp} ${qpxe} ${qdisk} ${qconsole}

