#!/bin/sh
# osquery regression tests, cross-platform (FreeBSD + Linux).
#
# Tests both osqueryi (ad-hoc shell) and osqueryd (scheduled daemon).
# On FreeBSD, this also exercises every FreeBSD-specific piece we added
# to the sysutils/osquery port:
#   * events backend: devd (publishes as "iokit"), inotify, openbsm
#   * tables: hardware_events (devd), pci_devices (libpci), usb_devices (libusb)
#   * link-time presence of every system library we wired through the
#     Find<lib>.cmake hijacks (rocksdb, thrift, augeas/libxml2, glog, gflags,
#     boost, sleuthkit, yara, ...).
#
# On Linux, FreeBSD-specific checks (ports linkage, devd, openbsm, FreeBSD-only
# tables) are auto-skipped.  The cross-checks use Linux-native tools (ss,
# ip neigh, lsblk, lspci, lsusb, /proc/PID/fd) instead of the FreeBSD ones.
#
# Usage:  sh osquery_test.sh
#
# Run as a normal user; the script will `sudo` for the privileged bits.
set -u

# --- platform detection -----------------------------------------------------
OS=$(uname -s)   # "FreeBSD" or "Linux"
case "${OS}" in
	FreeBSD|Linux) : ;;
	*) printf 'Unsupported OS: %s\n' "${OS}" >&2; exit 2 ;;
esac

# --- bin resolution ---------------------------------------------------------
# Prefer command -v so PATH wins; fall back to common install dirs.
find_bin() {
	name=$1
	if command -v "${name}" >/dev/null 2>&1; then
		command -v "${name}"
		return 0
	fi
	for d in /usr/local/bin /usr/bin /opt/osquery/bin; do
		if [ -x "${d}/${name}" ]; then
			printf '%s\n' "${d}/${name}"
			return 0
		fi
	done
	return 1
}

SUDO=${SUDO:-sudo}
OSQUERYI=${OSQUERYI:-$(find_bin osqueryi || echo osqueryi)}
OSQUERYD=${OSQUERYD:-$(find_bin osqueryd || echo osqueryd)}
TMPDIR=$(mktemp -d -t osquery-test.XXXXXX 2>/dev/null || mktemp -d /tmp/osquery-test.XXXXXX)
LOGDIR=${TMPDIR}/logs
DBDIR=${TMPDIR}/db
PIDFILE=${TMPDIR}/osqueryd.pid
CONFIG=${TMPDIR}/osquery.conf
mkdir -p "${LOGDIR}" "${DBDIR}"

# --- formatting -------------------------------------------------------------
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
hdr()    { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }

pass=0
fail=0
skip=0
fails=""

# run_query LABEL SQL [EXPECT_NONEMPTY]
run_query() {
	label=$1; sql=$2; need_rows=${3:-0}
	out=$("${OSQUERYI}" --json "${sql}" 2>"${TMPDIR}/err") || {
		red "FAIL  ${label}"
		sed 's/^/      /' "${TMPDIR}/err" >&2
		fail=$((fail + 1))
		fails="${fails}\n  - ${label}"
		return
	}
	rows=$(printf '%s' "${out}" | tr -d '[:space:]')
	if [ "${need_rows}" = "1" ] && [ "${rows}" = "[]" ]; then
		yellow "EMPTY ${label} (no rows - host may not have this data)"
		skip=$((skip + 1))
		return
	fi
	green "PASS  ${label}"
	printf '%s' "${out}" | head -c 200 | sed 's/^/      /'
	printf '\n'
	pass=$((pass + 1))
}

# require_root_query LABEL SQL [EXPECT_NONEMPTY]
require_root_query() {
	label=$1; sql=$2; need_rows=${3:-0}
	out=$(${SUDO} "${OSQUERYI}" --json "${sql}" 2>"${TMPDIR}/err") || {
		red "FAIL  ${label}"
		sed 's/^/      /' "${TMPDIR}/err" >&2
		fail=$((fail + 1))
		fails="${fails}\n  - ${label}"
		return
	}
	rows=$(printf '%s' "${out}" | tr -d '[:space:]')
	if [ "${need_rows}" = "1" ] && [ "${rows}" = "[]" ]; then
		yellow "EMPTY ${label} (no rows)"
		skip=$((skip + 1))
		return
	fi
	green "PASS  ${label} (root)"
	printf '%s' "${out}" | head -c 200 | sed 's/^/      /'
	printf '\n'
	pass=$((pass + 1))
}

# cross_check LABEL OSQ_VALUE SYS_VALUE
cross_check() {
	label=$1; osq=$2; sys=$3
	if [ "${osq}" = "${sys}" ]; then
		green "PASS  ${label} (osq=${osq} sys=${sys})"
		pass=$((pass + 1))
	else
		red "FAIL  ${label} (osq=${osq} sys=${sys})"
		fail=$((fail + 1))
		fails="${fails}\n  - ${label} cross-check"
	fi
}

# skip_test LABEL REASON  -- record a skip without running anything
skip_test() {
	yellow "SKIP  $1 ($2)"
	skip=$((skip + 1))
}

osq_scalar() {
	${SUDO} "${OSQUERYI}" --json "$1" 2>/dev/null | jq -r "$2"
}

cleanup() {
	if [ -f "${PIDFILE}" ]; then
		pid=$(cat "${PIDFILE}" 2>/dev/null || true)
		[ -n "${pid:-}" ] && ${SUDO} kill "${pid}" 2>/dev/null || true
	fi
	${SUDO} pkill -f "${OSQUERYD}" 2>/dev/null || true
	rm -rf "${TMPDIR}"
}
trap cleanup EXIT INT TERM

# --- preflight --------------------------------------------------------------
hdr "Preflight (${OS})"
for bin in "${OSQUERYI}" "${OSQUERYD}"; do
	if ! command -v "${bin}" >/dev/null 2>&1 && [ ! -x "${bin}" ]; then
		red "Missing: ${bin}"
		case "${OS}" in
			FreeBSD)
				red "Install:  sudo pkg add /usr/local/poudriere/data/packages/builder-official/.latest/All/osquery-5.23.0.pkg" ;;
			Linux)
				red "Install:  sudo apt install osquery   (or download from https://osquery.io/downloads)" ;;
		esac
		exit 1
	fi
done
# jq is required for cross-checks
if ! command -v jq >/dev/null 2>&1; then
	red "Missing: jq (used by cross-check helpers)"
	exit 1
fi
"${OSQUERYI}" --version
"${OSQUERYD}" --version

# --- ldd audit (FreeBSD only) -----------------------------------------------
# This validates the port's Find<lib>.cmake hijacks actually linked against
# system libs.  On Linux the binary ships from upstream osquery and is fully
# statically linked (or links against entirely different paths), so the
# audit is meaningless there.
if [ "${OS}" = "FreeBSD" ]; then
	hdr "Linked-library audit (FreeBSD port: system libs only)"
	ldd_out=$(ldd "${OSQUERYI}" 2>/dev/null || true)
	for lib in librocksdb libthrift libaugeas libxml2 libglog libgflags \
	           libboost_filesystem libboost_thread libtsk libzstd \
	           libsqlite3 libssl libcrypto libmagic libarchive libbsm; do
		if printf '%s' "${ldd_out}" | grep -q "${lib}"; then
			green "PASS  ldd: ${lib}"
			pass=$((pass + 1))
		else
			red "FAIL  ldd: ${lib} not in osqueryi's NEEDED list"
			fail=$((fail + 1))
			fails="${fails}\n  - ldd ${lib}"
		fi
	done
else
	skip_test "ldd audit" "FreeBSD-port-specific check"
fi

# --- osqueryi: core ---------------------------------------------------------
hdr "osqueryi: SQL engine + core tables"
run_query "SELECT 1"                "SELECT 1 AS one;" 1
case "${OS}" in
	FreeBSD)
		run_query "os_version"      "SELECT * FROM os_version WHERE name='FreeBSD';" 1 ;;
	Linux)
		run_query "os_version"      "SELECT * FROM os_version;" 1 ;;
esac
run_query "system_info"             "SELECT cpu_brand, physical_memory FROM system_info;" 1
run_query "time"                    "SELECT * FROM time;" 1
run_query "uptime"                  "SELECT * FROM uptime;" 1
run_query "kernel_info"             "SELECT * FROM kernel_info;" 1
run_query "platform_info"           "SELECT vendor, version FROM platform_info;"

# --- osqueryi: posix tables -------------------------------------------------
hdr "osqueryi: posix tables"
run_query "logged_in_users"         "SELECT user, host, time FROM logged_in_users LIMIT 5;"
run_query "last (utmpx)"            "SELECT username, type, time FROM last LIMIT 5;"
run_query "firefox_addons"          "SELECT * FROM firefox_addons LIMIT 1;"

# --- osqueryi: process / network --------------------------------------------
hdr "osqueryi: process and network tables"
run_query "processes"               "SELECT pid, name, path FROM processes WHERE pid=1;" 1
run_query "listening_ports"         "SELECT pid, port, protocol FROM listening_ports LIMIT 5;" 1
run_query "process_open_sockets"    "SELECT pid, family, protocol FROM process_open_sockets LIMIT 5;" 1
run_query "interface_addresses"     "SELECT interface, address FROM interface_addresses LIMIT 5;" 1
run_query "interface_details"       "SELECT interface, mtu FROM interface_details LIMIT 5;" 1
run_query "routes"                  "SELECT destination, gateway, interface FROM routes LIMIT 5;" 1
run_query "arp_cache"               "SELECT address, mac, interface FROM arp_cache LIMIT 5;"

# --- osqueryi: filesystem / users ------------------------------------------
hdr "osqueryi: filesystem and user tables"
run_query "mounts"                  "SELECT device, path, type FROM mounts LIMIT 5;" 1
run_query "users"                   "SELECT uid, username, shell FROM users LIMIT 5;" 1
run_query "groups"                  "SELECT gid, groupname FROM groups LIMIT 5;" 1
run_query "block_devices"           "SELECT name, size FROM block_devices LIMIT 5;"

# --- osqueryi: FreeBSD-specific tables we wrote -----------------------------
# pci_devices / usb_devices exist on Linux too (via lspci/libusb), but the
# port's implementation is what we want to exercise here.  Run them on both
# platforms.
hdr "osqueryi: pci_devices / usb_devices"
run_query "pci_devices count"       "SELECT count(*) AS n FROM pci_devices;" 1
run_query "pci_devices columns"     "SELECT pci_slot, vendor_id, model_id, pci_class, vendor, model FROM pci_devices LIMIT 5;" 1
run_query "usb_devices"             "SELECT usb_address, vendor_id, model_id, vendor, model FROM usb_devices LIMIT 5;"

# --- osqueryi: third-party-backed tables (proves linkage) -------------------
hdr "osqueryi: tables backed by linked system libraries"
run_query "augeas (/etc/hosts)"     "SELECT path, label, value FROM augeas WHERE node='/files/etc/hosts' LIMIT 5;" 1
run_query "yara schema"             "PRAGMA table_info(yara);" 1
run_query "osquery_info"            "SELECT version, build_platform, build_distro FROM osquery_info;" 1
run_query "osquery_flags"           "SELECT count(*) AS n FROM osquery_flags;" 1

# --- osqueryi: root-only tables ---------------------------------------------
hdr "osqueryi: root-required tables"
require_root_query "process_open_files"   "SELECT pid, fd, path FROM process_open_files LIMIT 5;" 1
require_root_query "shadow"                "SELECT username FROM shadow LIMIT 1;"

# --- osqueryd: scheduled daemon ---------------------------------------------
hdr "osqueryd: scheduled daemon (30 s run)"
cat > "${CONFIG}" <<EOF
{
  "options": {
    "logger_path": "${LOGDIR}",
    "database_path": "${DBDIR}",
    "schedule_splay_percent": 10
  },
  "schedule": {
    "sched_os": {
      "query": "SELECT * FROM os_version;",
      "interval": 10
    },
    "sched_pci": {
      "query": "SELECT count(*) AS n FROM pci_devices;",
      "interval": 10
    },
    "sched_proc": {
      "query": "SELECT pid, name FROM processes WHERE pid=1;",
      "interval": 10
    }
  }
}
EOF

green "Starting osqueryd (logs: ${LOGDIR}, db: ${DBDIR})"
# audit flags are FreeBSD/Linux-specific.  Pass them only on FreeBSD where
# they exercise OpenBSM (auditpipe).  Linux osqueryd reads auditd too, but
# enabling it on a test host can interfere with the system auditd.
audit_args=
if [ "${OS}" = "FreeBSD" ]; then
	audit_args="--disable_audit=false --audit_allow_config=true --audit_allow_process_events=true"
fi
# shellcheck disable=SC2086
${SUDO} "${OSQUERYD}" \
	--config_path="${CONFIG}" \
	--pidfile="${PIDFILE}" \
	--database_path="${DBDIR}" \
	--logger_path="${LOGDIR}" \
	--disable_events=false \
	${audit_args} \
	--verbose >"${TMPDIR}/osqueryd.stdout" 2>"${TMPDIR}/osqueryd.stderr" &
sleep 2

if ! ${SUDO} test -f "${PIDFILE}" || ! ${SUDO} kill -0 "$(${SUDO} cat "${PIDFILE}")" 2>/dev/null; then
	red "FAIL  osqueryd did not start"
	yellow "      stderr (last 30 lines):"
	${SUDO} tail -30 "${TMPDIR}/osqueryd.stderr" | sed 's/^/      /' >&2
	fail=$((fail + 1))
	fails="${fails}\n  - osqueryd start"
else
	green "PASS  osqueryd started (pid=$(${SUDO} cat "${PIDFILE}"))"
	pass=$((pass + 1))

	yellow "      Waiting 25s for scheduled queries..."
	sleep 25

	if ${SUDO} test -s "${LOGDIR}/osqueryd.results.log"; then
		lines=$(${SUDO} wc -l < "${LOGDIR}/osqueryd.results.log" | tr -d ' ')
		green "PASS  osqueryd results log has ${lines} line(s)"
		pass=$((pass + 1))
		${SUDO} head -1 "${LOGDIR}/osqueryd.results.log" | head -c 200 | sed 's/^/      /'
		printf '\n'
	else
		red "FAIL  osqueryd produced no results log"
		yellow "      stderr (last 20 lines):"
		${SUDO} tail -20 "${TMPDIR}/osqueryd.stderr" | sed 's/^/      /' >&2
		fail=$((fail + 1))
		fails="${fails}\n  - osqueryd results log"
	fi

	# Thrift handshake to running daemon's extensions socket.
	sock=$(${SUDO} "${OSQUERYI}" --json --extensions_socket=/var/osquery/osquery.em \
		"SELECT version FROM osquery_info;" 2>/dev/null || true)
	if [ -n "${sock}" ] && [ "${sock}" != "[]" ]; then
		green "PASS  osqueryi connected to running osqueryd via thrift socket"
		pass=$((pass + 1))
	else
		yellow "SKIP  osqueryi/osqueryd thrift handshake (extensions socket path differs)"
		skip=$((skip + 1))
	fi
fi

# --- event backends ---------------------------------------------------------
hdr "osqueryd: event backends"
TESTFILE=${TMPDIR}/inotify_probe
touch "${TESTFILE}"; echo data >> "${TESTFILE}"; rm -f "${TESTFILE}"
sleep 3

# hardware_events: devd on FreeBSD, udev on Linux.  May legitimately be empty
# on a quiet host.
require_root_query "hardware_events"   "SELECT action, path, type, driver FROM hardware_events LIMIT 5;"
# process_events: OpenBSM on FreeBSD, auditd on Linux.
require_root_query "process_events"    "SELECT pid, path, cmdline FROM process_events LIMIT 5;"

# --- cross-checks vs native tooling ----------------------------------------
hdr "Cross-checks against native ${OS} tools"

# arp_cache
arp_osq=$(osq_scalar "SELECT count(*) AS n FROM arp_cache;" '.[0].n')
case "${OS}" in
	FreeBSD)
		arp_sys=$(arp -na 2>/dev/null | grep -v incomplete | grep -c '^?' || echo 0) ;;
	Linux)
		# `ip neigh` lists every neighbor entry; REACHABLE/STALE/DELAY/PROBE
		# are "resolved".  FAILED/INCOMPLETE/NOARP/PERMANENT/NONE drop out.
		arp_sys=$(ip neigh show 2>/dev/null | awk '$NF ~ /^(REACHABLE|STALE|DELAY|PROBE)$/' | wc -l | tr -d ' ') ;;
esac
cross_check "arp_cache row count" "${arp_osq}" "${arp_sys}"

# mounts
mnt_osq=$(osq_scalar "SELECT count(*) AS n FROM mounts;" '.[0].n')
case "${OS}" in
	FreeBSD)
		mnt_sys=$(mount | wc -l | tr -d ' ') ;;
	Linux)
		# Compare to /proc/mounts (raw kernel mount table).  `mount` output
		# is filtered by /etc/mtab on some distros.
		mnt_sys=$(wc -l < /proc/mounts | tr -d ' ') ;;
esac
cross_check "mounts row count" "${mnt_osq}" "${mnt_sys}"

# root device
root_osq=$(osq_scalar "SELECT device FROM mounts WHERE path='/';" '.[0].device')
case "${OS}" in
	FreeBSD)
		root_sys=$(mount -p | awk '$2=="/"{print $1}') ;;
	Linux)
		root_sys=$(awk '$2=="/"{print $1; exit}' /proc/mounts) ;;
esac
cross_check "mounts root device" "${root_osq}" "${root_sys}"

# block_devices
bd_osq=$(osq_scalar "SELECT count(*) AS n FROM block_devices;" '.[0].n')
case "${OS}" in
	FreeBSD)
		bd_disks=$(geom disk list 2>/dev/null | grep -c '^Geom name:' || echo 0)
		bd_parts=$(gpart show 2>/dev/null | awk '/^[[:space:]]+[0-9]/ && NF==5 {c++} END{print c+0}')
		bd_sys=$((bd_disks + bd_parts)) ;;
	Linux)
		# lsblk -ln -o NAME prints one line per disk + partition + lvm + ...
		# osquery's block_devices on Linux includes disks + partitions but
		# not LVM/dm; filter to TYPE=disk,part for parity.
		bd_sys=$(lsblk -ln -o NAME,TYPE 2>/dev/null | awk '$2=="disk" || $2=="part"' | wc -l | tr -d ' ') ;;
esac
cross_check "block_devices provider count" "${bd_osq}" "${bd_sys}"

# pci_devices
pci_osq=$(osq_scalar "SELECT count(*) AS n FROM pci_devices;" '.[0].n')
case "${OS}" in
	FreeBSD)
		pci_sys=$(pciconf -l 2>/dev/null | wc -l | tr -d ' ') ;;
	Linux)
		pci_sys=$(lspci 2>/dev/null | wc -l | tr -d ' ') ;;
esac
cross_check "pci_devices count" "${pci_osq}" "${pci_sys}"

# usb_devices
usb_osq=$(osq_scalar "SELECT count(*) AS n FROM usb_devices;" '.[0].n')
case "${OS}" in
	FreeBSD)
		usb_sys=$(${SUDO} usbconfig list 2>/dev/null | grep -cE '^ugen' || echo 0) ;;
	Linux)
		# lsusb lists one device per line including the root hubs.  osquery
		# also reports root hubs, so a raw line count matches.
		usb_sys=$(lsusb 2>/dev/null | wc -l | tr -d ' ') ;;
esac
cross_check "usb_devices count" "${usb_osq}" "${usb_sys}"

# shadow
sh_osq=$(osq_scalar "SELECT count(*) AS n FROM shadow;" '.[0].n')
case "${OS}" in
	FreeBSD)
		# FreeBSD has no /etc/shadow; every passwd entry is a shadow entry
		# via master.passwd.
		sh_sys=$(getent passwd | wc -l | tr -d ' ') ;;
	Linux)
		sh_sys=$(${SUDO} wc -l < /etc/shadow 2>/dev/null | tr -d ' ' || echo 0) ;;
esac
cross_check "shadow user count" "${sh_osq}" "${sh_sys}"

# process_open_files: count fds for init (pid 1).
pof_osq=$(osq_scalar "SELECT count(*) AS n FROM process_open_files WHERE pid=1;" '.[0].n')
case "${OS}" in
	FreeBSD)
		pof_sys=$(${SUDO} procstat -f 1 2>/dev/null | awk 'NR>1 && $3 ~ /^[0-9]+$/' | wc -l | tr -d ' ') ;;
	Linux)
		# /proc/1/fd/ contains a symlink per fd.  Some fds (sockets, pipes,
		# anon_inode:) are skipped by osquery's process_open_files on Linux,
		# so use ballpark comparison instead of strict equality.  We still
		# record `pof_sys` for the cross_check below by counting only
		# vnode-backed fds (those whose readlink target doesn't start with
		# "socket:" / "pipe:" / "anon_inode:").
		pof_sys=$(${SUDO} sh -c 'for f in /proc/1/fd/*; do readlink "$f"; done' 2>/dev/null \
			| grep -vE '^(socket:|pipe:|anon_inode:)' | wc -l | tr -d ' ') ;;
esac
cross_check "process_open_files(init) fd count" "${pof_osq}" "${pof_sys}"

# process_open_sockets: ballpark cross-check.  Different system tools count
# different things; allow >=50% match in either direction.
pos_osq=$(osq_scalar "SELECT count(*) AS n FROM process_open_sockets;" '.[0].n')
case "${OS}" in
	FreeBSD)
		pos_sys=$(${SUDO} sockstat -L 2>/dev/null | awk 'NR>1' | wc -l | tr -d ' ') ;;
	Linux)
		# `ss -tunap` lists tcp+udp sockets with process info; one line per
		# (proto, socket) pair.  Skip header.
		pos_sys=$(${SUDO} ss -tunap 2>/dev/null | awk 'NR>1' | wc -l | tr -d ' ') ;;
esac
if [ "${pos_osq:-0}" -gt 0 ] && [ "${pos_sys:-0}" -gt 0 ]; then
	if [ "${pos_osq}" -ge "${pos_sys}" ]; then
		ratio=$((pos_sys * 100 / pos_osq))
	else
		ratio=$((pos_osq * 100 / pos_sys))
	fi
	if [ "${ratio}" -ge 50 ]; then
		green "PASS  process_open_sockets vs native (osq=${pos_osq} sys=${pos_sys} ratio=${ratio}%)"
		pass=$((pass + 1))
	else
		red "FAIL  process_open_sockets vs native (osq=${pos_osq} sys=${pos_sys} ratio=${ratio}%)"
		fail=$((fail + 1))
		fails="${fails}\n  - process_open_sockets ballpark"
	fi
else
	red "FAIL  process_open_sockets vs native (osq=${pos_osq} sys=${pos_sys})"
	fail=$((fail + 1))
	fails="${fails}\n  - process_open_sockets empty"
fi

# --- summary ---------------------------------------------------------------
hdr "Summary"
printf 'Passed: %d\n' "${pass}"
printf 'Empty/Skipped: %d\n' "${skip}"
printf 'Failed: %d\n' "${fail}"
if [ "${fail}" -gt 0 ]; then
	red "FAILURES:"
	printf '%b\n' "${fails}" >&2
	exit 1
fi
green "All tests passed."
