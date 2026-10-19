#!/bin/sh
# amazon-efs-utils long-running soak test -- RUNS ON AN EC2 INSTANCE.
#
# Companion to amazon-efs-utils_test.sh (run that one first: it installs the
# package and proves a single mount works). This script tests the installed
# package over DAYS and looks for what a 2-minute test cannot see:
#
#   * leaks      -- efs-proxy / watchdog RSS, fds, threads, TCP sockets,
#                   watchdog child processes, zombies, kernel NFS client malloc,
#                   vnodes, state files, log growth (rotation must cap it)
#   * stability  -- efs-proxy must never be restarted unless we killed it;
#                   watchdog must stay alive; no hourly cert renewal (SIGHUP)
#                   may change the proxy pid
#   * wedges     -- every NFS operation runs in a background job with a
#                   deadline; a stalled job is reported, never waited on, and
#                   no new job is spawned while one is stuck (so the soak itself
#                   cannot pile up D-state processes, the old `df` bug)
#   * kernel     -- NFSv4.1 session recoveries (ExchangeId/CreateSess counters)
#                   and threads in `nfsbadse` (FreeBSD client wedge, see
#                   ~/myscripts/FreeBSD/nfsbug/)
#
# Workload (all files live in <mountpoint>/.efs-soak-<host>/):
#   every SAMPLE_INTERVAL  small write + read-back + READDIR + unlink
#   every BIG_EVERY        BIG_MB random file, fsync'd, checksum verified
#   every CYCLE_EVERY      mount a 2nd mountpoint, re-read the last big file
#                          through it (fresh client cache = data really comes
#                          from the server), umount, then assert the watchdog
#                          reaps its state file and efs-proxy (leak per cycle)
#   every KILL_PROXY_EVERY (opt-in) SIGKILL the main efs-proxy, assert the
#                          watchdog restarts it and I/O resumes
#
# Idle gaps between operations are intentional: they exercise the idle TCP
# path, lease renewal (nfsc_renew) and the hourly TLS cert renewal.
#
# Run detached, it must survive ssh disconnects:
#
#     scp amazon-efs-utils_soak.sh <instance>:/tmp/
#     ssh <instance>
#     sudo daemon -f -o /var/log/efs-soak.out -p /var/run/efs-soak.pid \
#         env EFS_FS_ID=fs-... SOAK_HOURS=72 sh /tmp/amazon-efs-utils_soak.sh
#
# Watch:   tail -f /var/log/efs-soak/<run>/events.log
#          cat /var/log/efs-soak/<run>/summary.txt   (refreshed hourly)
# Stop:    sudo kill $(cat /var/run/efs-soak.pid)    (clean teardown + verdict)
#
# Output (OUT_DIR): metrics.csv (one row per sample), events.log, summary.txt,
# snap-*.txt (system snapshot taken on every failure event).
#
# Coexists with other EFS mounts on the box; checks are scoped to its own two
# mountpoints.
#
# Verdict: FAIL on any hard event (unexpected restart, stall still stuck,
# nfsbadse, failed I/O, checksum mismatch, reap leak, watchdog death).
# WARN on recovered stalls and on resource growth over the warm-up baseline
# (heuristic: inspect metrics.csv before calling it a leak).
#
# Required:
#   EFS_FS_ID             filesystem id. No default (public repo).
# Optional:
#   SOAK_HOURS            run length                          (default 72)
#   EFS_MOUNTPOINT        main mount                          (/mnt/efs-soak)
#   EFS_CYCLE_MOUNTPOINT  mount/umount cycle target           (/mnt/efs-soak-cycle)
#   SAMPLE_INTERVAL       seconds between samples/probes      (60)
#   PROBE_TIMEOUT         small-I/O stall deadline, seconds   (120)
#   BIG_EVERY / BIG_MB    big transfer period s / size MiB    (3600 / 256)
#   CYCLE_EVERY           remount cycle period s, 0 = off     (1800)
#   KILL_PROXY_EVERY      fault injection period s, 0 = off   (0)
#   CERT_RENEWAL_MIN      override tls_cert_renewal_interval_min (unset = 60);
#                         efs-utils.conf is restored at exit
#   WARMUP                seconds before leak baseline is taken (3600)
#   OUT_DIR               results dir   (/var/log/efs-soak/<UTC timestamp>)
#
set -u

PORT_NAME=amazon-efs-utils
FS_ID=${EFS_FS_ID:?required: export EFS_FS_ID=fs-0123456789abcdef0 (your EFS filesystem id)}
SOAK_HOURS=${SOAK_HOURS:-72}
MP=${EFS_MOUNTPOINT:-/mnt/efs-soak}
MPB=${EFS_CYCLE_MOUNTPOINT:-/mnt/efs-soak-cycle}
SAMPLE_INTERVAL=${SAMPLE_INTERVAL:-60}
PROBE_TIMEOUT=${PROBE_TIMEOUT:-120}
BIG_EVERY=${BIG_EVERY:-3600}
BIG_MB=${BIG_MB:-256}
BIG_TIMEOUT=${BIG_TIMEOUT:-1800}
CYCLE_EVERY=${CYCLE_EVERY:-1800}
CYCLE_TIMEOUT=${CYCLE_TIMEOUT:-900}
KILL_PROXY_EVERY=${KILL_PROXY_EVERY:-0}
RESTART_TIMEOUT=${RESTART_TIMEOUT:-120}
REAP_TIMEOUT=${REAP_TIMEOUT:-180}
WARMUP=${WARMUP:-3600}
SUMMARY_EVERY=${SUMMARY_EVERY:-3600}
CERT_RENEWAL_MIN=${CERT_RENEWAL_MIN:-}
OUT_DIR=${OUT_DIR:-/var/log/efs-soak/$(date -u +%Y%m%dT%H%M%SZ)}

STATE_DIR=/var/run/efs
WATCHDOG_RC=amazon-efs-mount-watchdog
WATCHDOG_PID=/var/run/amazon_efs_mount_watchdog.pid
WATCHDOG_LOG=/var/log/amazon/efs/mount-watchdog.log
EFS_CONF=/usr/local/etc/amazon/efs/efs-utils.conf
HOST=$(hostname -s)
SOAKREL=.efs-soak-${HOST}
SOAKDIR=${MP}/${SOAKREL}
CSV=${OUT_DIR}/metrics.csv
EVENTS=${OUT_DIR}/events.log

STOP=0
MOUNTED=0
CONF_BACKUP=""
SNAPS=0

now() { date +%s; }
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# event LEVEL message -- LEVEL is INFO, WARN or FAIL
event() {
	lvl=$1; shift
	echo "$(ts) ${lvl} $*" | tee -a "${EVENTS}"
	[ "${lvl}" = FAIL ] && snapshot "$*"
	return 0
}

snapshot() {
	[ ${SNAPS} -ge 500 ] && return 0
	SNAPS=$((SNAPS + 1))
	f="${OUT_DIR}/snap-$(date -u +%Y%m%dT%H%M%SZ)-${SNAPS}.txt"
	{
		echo "# $*"
		echo "## ps"; ps -axww -o pid,ppid,stat,wchan,rss,vsz,etime,command
		echo "## mount"; mount -t nfs
		echo "## state files"; ls -la "${STATE_DIR}"
		echo "## sockstat efs-proxy"; sockstat -4 -6 -P tcp | awk 'NR==1 || $2=="efs-proxy"'
		echo "## nfsstat -c -E"; nfsstat -c -E
		echo "## dmesg: $(dmesg | grep -c 'Initiate recovery') 'Initiate recovery' since boot"
		dmesg | tail -30
		for p in $(pgrep -x efs-proxy); do
			echo "## procstat -f ${p}"; procstat -f "${p}"
			echo "## procstat -kk ${p}"; procstat -kk "${p}"
		done
		echo "## procstat -kk of NFS D-state threads"
		ps -ax -o pid= -o stat= -o wchan= | awk '$2 ~ /^D/ && $3 ~ /nfs/ {print $1}' \
			| while read -r p; do procstat -kk "${p}"; done
		echo "## watchdog log tail"; tail -200 "${WATCHDOG_LOG}"
	} > "${f}" 2>&1
}

fail() {
	echo "FAIL  ${PORT_NAME} soak: $*"
	exit 1
}

# Mountpoint to state-file name component: /mnt/efs-soak -> mnt.efs-soak
safe_name() { echo "$1" | sed 's#/#.#g; s#^\.*##'; }
SAFE_A=$(safe_name "${MP}")
SAFE_B=$(safe_name "${MPB}")
FS_RE=$(echo "${FS_ID}" | sed 's/\./\\./g')

state_file_for() {
	ls -1 "${STATE_DIR}" 2>/dev/null \
		| grep -E "^${FS_RE}\.$(echo "$1" | sed 's/\./\\./g')\.[0-9]+$" | head -1
}
# efs-proxy pid recorded by the watchdog/mount helper in the state file
proxy_pid_of() {
	sf=$(state_file_for "$1")
	[ -n "${sf}" ] || return 0
	sed -n 's/.*"pid": *\([0-9][0-9]*\).*/\1/p' "${STATE_DIR}/${sf}" | head -1
}
watchdog_pid() {
	sup=$(cat "${WATCHDOG_PID}" 2>/dev/null) || return 0
	[ -n "${sup}" ] && pgrep -P "${sup}" | head -1
}
count_lines() { awk 'NR>1' | wc -l | tr -d ' '; }

# --------------------------------------------------------- background jobs
# NFS operations never run in the foreground: a hung hard mount would freeze
# the soak. job_start runs a function in the background, its exit status lands
# in ${OUT_DIR}/<name>.rc and its output in <name>.msg. job_poll sets JOB_STATE
# to idle, running, stuck (past deadline), ok or fail.
job_start() {
	n=$1; shift
	rm -f "${OUT_DIR}/${n}.rc" "${OUT_DIR}/${n}.msg"
	( "$@" > "${OUT_DIR}/${n}.msg" 2>&1; echo $? > "${OUT_DIR}/${n}.rc" ) &
	eval "${n}_pid=$! ${n}_t0=$(now) ${n}_stuck=0"
}
job_poll() {
	n=$1; to=$2
	eval "jp=\${${n}_pid:-} jt0=\${${n}_t0:-0}"
	JOB_AGE=$(( $(now) - jt0 ))
	JOB_RC=""
	if [ -z "${jp}" ]; then
		JOB_STATE=idle
	elif [ -f "${OUT_DIR}/${n}.rc" ]; then
		JOB_RC=$(cat "${OUT_DIR}/${n}.rc")
		eval "${n}_pid="
		[ "${JOB_RC}" = 0 ] && JOB_STATE=ok || JOB_STATE=fail
	elif kill -0 "${jp}" 2>/dev/null; then
		[ ${JOB_AGE} -gt "${to}" ] && JOB_STATE=stuck || JOB_STATE=running
	else
		JOB_RC=killed
		eval "${n}_pid="
		JOB_STATE=fail
	fi
}
job_msg() { tr '\n' ' ' < "${OUT_DIR}/$1.msg" 2>/dev/null | cut -c1-300; }

# Report stalls once, and report recovery from them.
job_stall_check() {
	n=$1
	eval "st=\${${n}_stuck:-0}"
	if [ "${JOB_STATE}" = stuck ] && [ "${st}" = 0 ]; then
		eval "${n}_stuck=1"
		event WARN "${n} job stalled > ${JOB_AGE}s (NFS op blocked; not spawning more)"
		snapshot "${n} stall"
	elif [ "${st}" = 1 ] && { [ "${JOB_STATE}" = ok ] || [ "${JOB_STATE}" = fail ]; }; then
		event WARN "${n} job recovered from stall after ${JOB_AGE}s"
	fi
}

probe_job() {
	f="${SOAKDIR}/p.$1"
	tok="$1 $(ts) $$"
	printf '%s\n' "${tok}" > "${f}" || { echo "write failed"; return 10; }
	[ "$(cat "${f}")" = "${tok}" ] || { echo "read-back mismatch"; return 11; }
	ls -1 "${SOAKDIR}" | grep -qx "p.$1" || { echo "not in READDIR"; return 12; }
	rm -f "${f}" || { echo "unlink failed"; return 13; }
	[ ! -e "${f}" ] || { echo "still present after unlink"; return 14; }
}

big_job() {
	name="big.$(now)"
	src="${OUT_DIR}/big.src"
	dd if=/dev/random of="${src}" bs=1m count="${BIG_MB}" 2>/dev/null \
		|| { echo "local source create failed"; return 20; }
	sum=$(sha256 -q "${src}")
	t0=$(now)
	dd if="${src}" of="${SOAKDIR}/${name}" bs=1m conv=fsync 2>/dev/null \
		|| { rm -f "${src}"; echo "write to EFS failed"; return 21; }
	dt=$(( $(now) - t0 )); [ ${dt} -gt 0 ] || dt=1
	rm -f "${src}"
	rsum=$(sha256 -q "${SOAKDIR}/${name}") || { echo "read failed"; return 22; }
	[ "${sum}" = "${rsum}" ] || { echo "checksum mismatch ${name}"; return 23; }
	if [ -f "${OUT_DIR}/big.latest" ]; then
		read -r old _ < "${OUT_DIR}/big.latest"
		rm -f "${SOAKDIR}/${old}"
	fi
	echo "${name} ${sum}" > "${OUT_DIR}/big.latest"
	echo "${name} ${BIG_MB}MiB write+fsync ${dt}s ($((BIG_MB / dt)) MiB/s)"
}

# Fresh mount = cold client cache: the checksum proves the data the main mount
# wrote is really on the server, not just in the main mount's page cache.
cycle_job() {
	mkdir -p "${MPB}"
	mount_efs "${FS_ID}" "${MPB}" -o tls,iam > /dev/null \
		|| { echo "mount_efs failed"; umount "${MPB}" 2>/dev/null; return 30; }
	rc=0; name=""
	if [ -f "${OUT_DIR}/big.latest" ]; then
		read -r name sum < "${OUT_DIR}/big.latest"
		rsum=$(sha256 -q "${MPB}/${SOAKREL}/${name}") \
			|| { echo "read ${name} failed"; rc=31; }
		[ ${rc} -ne 0 ] || [ "${rsum}" = "${sum}" ] \
			|| { echo "cross-mount checksum mismatch ${name}"; rc=32; }
	else
		ls "${MPB}/${SOAKREL}" > /dev/null || { echo "READDIR failed"; rc=33; }
	fi
	umount "${MPB}" || { echo "umount failed"; return 34; }
	[ ${rc} -eq 0 ] && echo "cycle ok${name:+, verified ${name}}"
	return ${rc}
}

# ---------------------------------------------------------------- sampling
CSV_HDR="ts,elapsed_s,proxy_pid,proxy_rss_kb,proxy_vsz_kb,proxy_fds,proxy_threads,proxy_tcp,wd_pid,wd_rss_kb,wd_fds,wd_children,n_proxies,n_state_files,n_zombies,n_nfs_dstate,n_nfsbadse,nfscl_mem_b,numvnodes,wired_pages,exchid,createsess,log_kb,probe_ok,probe_fail"

LAST_PID=""
LAST_SESS=""
BADSE_SEEN=0
WEDGED=0
EXPECT_RESTART=0
INJECTED_AT=0
RESTARTS_INJ=0
CYCLE_REAP_DEADLINE=0
PROBE_OK=0
PROBE_FAIL=0

sample() {
	pp=$(proxy_pid_of "${SAFE_A}")
	if [ -n "${pp}" ] && kill -0 "${pp}" 2>/dev/null; then
		set -- $(ps -o rss= -o vsz= -p "${pp}")
		prss=${1:-}; pvsz=${2:-}
		pfd=$(procstat -f "${pp}" 2>/dev/null | count_lines)
		pth=$(procstat -t "${pp}" 2>/dev/null | count_lines)
		ptcp=$(sockstat -4 -6 -c -P tcp 2>/dev/null | awk -v p="${pp}" '$3 == p' | wc -l | tr -d ' ')
	else
		prss=""; pvsz=""; pfd=""; pth=""; ptcp=""
	fi

	# Main-mount proxy identity: a change is a restart.
	if [ -n "${pp}" ] && [ -n "${LAST_PID}" ] && [ "${pp}" != "${LAST_PID}" ]; then
		if [ ${EXPECT_RESTART} -eq 1 ]; then
			event INFO "efs-proxy restarted by watchdog ${LAST_PID} -> ${pp}, $(( $(now) - INJECTED_AT ))s after injected kill"
			RESTARTS_INJ=$((RESTARTS_INJ + 1))
			EXPECT_RESTART=0
		else
			event FAIL "UNEXPECTED efs-proxy restart ${LAST_PID} -> ${pp}"
		fi
	fi
	[ -n "${pp}" ] && LAST_PID=${pp}
	if [ ${EXPECT_RESTART} -eq 1 ] && [ $(( $(now) - INJECTED_AT )) -gt "${RESTART_TIMEOUT}" ]; then
		event FAIL "watchdog did not restart efs-proxy within ${RESTART_TIMEOUT}s of injected kill"
		EXPECT_RESTART=0
	fi
	if [ ${EXPECT_RESTART} -eq 0 ] && [ -z "${prss}" ]; then
		event WARN "main efs-proxy (pid ${pp:-none}) not running"
	fi

	wd=$(watchdog_pid)
	if [ -n "${wd}" ]; then
		set -- $(ps -o rss= -p "${wd}")
		wrss=${1:-}
		wfd=$(procstat -f "${wd}" 2>/dev/null | count_lines)
		wch=$(pgrep -P "${wd}" | wc -l | tr -d ' ')
	else
		wrss=""; wfd=""; wch=""
		[ "${WD_DEAD:-0}" -eq 0 ] && event FAIL "watchdog is not running"
		WD_DEAD=1
	fi

	nprox=$(pgrep -x efs-proxy | wc -l | tr -d ' ')
	nstate=$(ls -1 "${STATE_DIR}" 2>/dev/null | grep -cE '^fs-.*\.[0-9]+$')
	nzomb=$(ps -axo stat= | grep -c '^Z')
	ndst=$(ps -ax -o stat= -o wchan= | awk '$1 ~ /^D/ && $2 ~ /nfs/' | wc -l | tr -d ' ')
	nbad=$(ps -axo wchan= | grep -c 'nfsbadse')
	nfsmem=$(vmstat -m | awk '/NFS/ && !/NFSD/ {s += $(NF-2)} END {print s+0}')
	nvn=$(sysctl -n vfs.numvnodes)
	wired=$(sysctl -n vm.stats.vm.v_wire_count)
	set -- $(nfsstat -c -E 2>/dev/null | awk '/ExchangeId/ {getline; print $1, $2; exit}')
	exch=${1:-}; csess=${2:-}
	logkb=$(du -sk /var/log/amazon/efs 2>/dev/null | awk '{print $1}')

	# Each new mount does its own ExchangeId/CreateSession, so a change during
	# a cycle job is expected. Any other change is a session recovery.
	if [ -n "${LAST_SESS}" ] && [ "${exch}/${csess}" != "${LAST_SESS}" ]; then
		if [ -n "${cycle_pid:-}" ]; then
			event INFO "cycle mount session: ExchangeId/CreateSess ${LAST_SESS} -> ${exch}/${csess}"
		else
			event WARN "NFSv4.1 session recovery: ExchangeId/CreateSess ${LAST_SESS} -> ${exch}/${csess}"
			snapshot "session recovery ${LAST_SESS} -> ${exch}/${csess}"
		fi
	fi
	LAST_SESS="${exch}/${csess}"

	# nfsbadse on two consecutive samples = the known kernel wedge.
	if [ "${nbad}" -gt 0 ]; then
		BADSE_SEEN=$((BADSE_SEEN + 1))
		if [ ${BADSE_SEEN} -eq 2 ] && [ ${WEDGED} -eq 0 ]; then
			WEDGED=1
			event FAIL "WEDGE: ${nbad} thread(s) in nfsbadse on consecutive samples"
		fi
	else
		BADSE_SEEN=0
	fi

	# Cycle mount must be fully reaped REAP_TIMEOUT after its umount.
	if [ ${CYCLE_REAP_DEADLINE} -gt 0 ] && [ "$(now)" -ge ${CYCLE_REAP_DEADLINE} ]; then
		CYCLE_REAP_DEADLINE=0
		left_sf=$(state_file_for "${SAFE_B}")
		left_px=$(pgrep -f "efs-proxy .*\.${SAFE_B}\.[0-9]" | tr '\n' ' ')
		if [ -n "${left_sf}" ] || [ -n "${left_px}" ]; then
			event FAIL "LEAK: cycle mount not reaped ${REAP_TIMEOUT}s after umount (state=${left_sf:-none} proxy=${left_px:-none})"
		fi
	fi

	echo "$(ts),$(( $(now) - START )),${pp},${prss},${pvsz},${pfd},${pth},${ptcp},${wd},${wrss},${wfd},${wch},${nprox},${nstate},${nzomb},${ndst},${nbad},${nfsmem},${nvn},${wired},${exch},${csess},${logkb},${PROBE_OK},${PROBE_FAIL}" >> "${CSV}"
}

# ----------------------------------------------------------------- summary
summary() {
	{
		echo "${PORT_NAME} ${VER} soak on ${HOST} ($(uname -r) $(uname -m)), ${FS_ID}"
		echo "started $(date -u -r ${START} +%Y-%m-%dT%H:%M:%SZ), elapsed $(( ($(now) - START) / 3600 ))h$(( ($(now) - START) % 3600 / 60 ))m"
		echo "probes ok=${PROBE_OK} fail=${PROBE_FAIL}; injected restarts=${RESTARTS_INJ}"
		echo "events: FAIL=$(grep -c ' FAIL ' "${EVENTS}") WARN=$(grep -c ' WARN ' "${EVENTS}") INFO=$(grep -c ' INFO ' "${EVENTS}")"
		echo
		# Baseline = first sample after WARMUP (or the first sample if the
		# run is shorter). proxy_* metrics reset on a restart, so compare
		# only rows of the last proxy pid for those.
		awk -F, -v warm="${WARMUP}" '
		NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
		{ rows[++n] = $0 }
		END {
			split("proxy_rss_kb proxy_fds proxy_threads proxy_tcp wd_rss_kb wd_fds wd_children n_proxies n_state_files n_zombies n_nfs_dstate nfscl_mem_b numvnodes wired_pages log_kb", m, " ")
			split(rows[n], last, ",")
			lastpid = last[col["proxy_pid"]]
			printf "%-15s %12s %12s %12s  %s\n", "metric", "baseline", "last", "max", "flag"
			for (k = 1; k in m; k++) {
				c = col[m[k]]; base = ""; max = ""
				for (r = 1; r <= n; r++) {
					split(rows[r], f, ",")
					if (m[k] ~ /^proxy_/ && f[col["proxy_pid"]] != lastpid) continue
					if (f[c] == "") continue
					if (base == "" && (f[col["elapsed_s"]] >= warm || r == n)) base = f[c]
					if (max == "" || f[c] + 0 > max + 0) max = f[c]
				}
				if (base == "") { split(rows[1], f, ","); base = f[c] }
				l = last[c]; flag = ""
				if (m[k] ~ /rss_kb$/ && l > base * 1.5 && l - base > 20480) flag = "WARN growth"
				if (m[k] ~ /fds$|_tcp$|threads$|children$/ && l > base + 10) flag = "WARN growth"
				if (m[k] == "n_zombies" && l > 2) flag = "WARN"
				if (m[k] ~ /^n_(state_files|proxies)$/ && l > base) flag = "WARN leftover"
				if (m[k] == "log_kb" && l > 12288) flag = "WARN rotation?"
				if (flag ~ /WARN/) warns++
				printf "%-15s %12s %12s %12s  %s\n", m[k], base, l, max, flag
			}
			print warns + 0 > "/dev/stderr"
		}' "${CSV}" 2> "${OUT_DIR}/.growth_warns"
		echo
		echo "last events:"
		tail -15 "${EVENTS}"
	} > "${OUT_DIR}/summary.txt.new"
	mv "${OUT_DIR}/summary.txt.new" "${OUT_DIR}/summary.txt"
}

verdict() {
	summary
	nfail=$(grep -c ' FAIL ' "${EVENTS}")
	nwarn=$(( $(grep -c ' WARN ' "${EVENTS}") + $(cat "${OUT_DIR}/.growth_warns" 2>/dev/null || echo 0) ))
	if [ "${nfail}" -gt 0 ]; then
		V=FAIL
	elif [ "${nwarn}" -gt 0 ]; then
		V=WARN
	else
		V=PASS
	fi
	echo "verdict: ${V} (FAIL events=${nfail}, warnings=${nwarn})" >> "${OUT_DIR}/summary.txt"
	cat "${OUT_DIR}/summary.txt"
	echo "${V}  ${PORT_NAME} ${VER} soak: $(( ($(now) - START) / 3600 ))h, results in ${OUT_DIR}"
}

# ---------------------------------------------------------------- teardown
restore_conf() {
	if [ -n "${CONF_BACKUP}" ]; then
		mv "${CONF_BACKUP}" "${EFS_CONF}"
		CONF_BACKUP=""
		service ${WATCHDOG_RC} onestatus > /dev/null 2>&1 && service ${WATCHDOG_RC} onerestart > /dev/null
		echo "restored ${EFS_CONF}"
	fi
}

# Wait up to $2 seconds for job $1; never blocks on a wedged job.
job_drain() {
	i=0
	while [ ${i} -lt "$2" ]; do
		job_poll "$1" 999999
		case ${JOB_STATE} in idle|ok|fail) return 0 ;; esac
		i=$((i + 1)); sleep 1
	done
	return 1
}

teardown() {
	echo "$(ts) teardown"
	stuck=0
	for j in probe big cycle; do
		job_drain ${j} 300 || { event FAIL "${j} job still blocked at teardown"; stuck=1; }
	done
	if [ ${stuck} -eq 1 ] || [ ${WEDGED} -eq 1 ]; then
		# umount on a wedged hard mount blocks forever; leave the box as-is
		# for kernel debugging (see ~/myscripts/FreeBSD/nfsbug/).
		event FAIL "mount wedged: NOT unmounting ${MP}; reboot to clear"
		restore_conf
		verdict
		return
	fi
	mount -t nfs | grep -q " on ${MPB} " && umount "${MPB}"
	job_start cleanup rm -rf "${SOAKDIR}"
	job_drain cleanup 600 || event WARN "removing ${SOAKDIR} did not finish"
	if [ ${MOUNTED} -eq 1 ]; then
		umount "${MP}" || event FAIL "umount ${MP} failed"
		MOUNTED=0
		i=0
		while [ ${i} -lt "${REAP_TIMEOUT}" ]; do
			[ -z "$(state_file_for "${SAFE_A}")" ] && ! kill -0 "${LAST_PID}" 2>/dev/null && break
			i=$((i + 1)); sleep 1
		done
		if [ -n "$(state_file_for "${SAFE_A}")" ] || kill -0 "${LAST_PID}" 2>/dev/null; then
			event FAIL "LEAK: main mount not reaped ${REAP_TIMEOUT}s after final umount"
		else
			event INFO "main mount reaped ${i}s after final umount"
		fi
		service ${WATCHDOG_RC} onestatus > /dev/null 2>&1 \
			|| event FAIL "watchdog exited after last unmount"
	fi
	restore_conf
	verdict
}

on_signal() { STOP=1; }

# ---------------------------------------------------------------- preflight
[ "$(id -u)" -eq 0 ] || fail "must run as root"
[ "$(uname -s)" = "FreeBSD" ] || fail "this test is FreeBSD-only"
fetch -qo /dev/null -T 5 http://169.254.169.254/latest/meta-data/ 2>/dev/null \
	|| fail "instance metadata service unreachable (not EC2, or IMDS blocked)"
VER=$(pkg query %v ${PORT_NAME} 2>/dev/null) \
	|| fail "${PORT_NAME} not installed (run amazon-efs-utils_test.sh first)"
# Other EFS mounts may coexist: every check is scoped to this soak's two
# mountpoints, and the global counters are compared against their baseline.
mount -t nfs | grep -qE " on (${MP}|${MPB}) " && fail "${MP} or ${MPB} already mounted"
[ -n "$(state_file_for "${SAFE_A}")$(state_file_for "${SAFE_B}")" ] \
	&& fail "stale state files for ${MP} or ${MPB} in ${STATE_DIR}"
[ -f "${EFS_CONF}" ] || cp "${EFS_CONF}.sample" "${EFS_CONF}"
mkdir -p "${OUT_DIR}" "${MP}" "${MPB}" || fail "cannot create ${OUT_DIR}"
: > "${EVENTS}"

# The watchdog reads its config only at start, so restart it after the edit.
if [ -n "${CERT_RENEWAL_MIN}" ]; then
	CONF_BACKUP="${EFS_CONF}.soak-backup"
	cp -p "${EFS_CONF}" "${CONF_BACKUP}"
	sed -i '' "s/^tls_cert_renewal_interval_min *=.*/tls_cert_renewal_interval_min = ${CERT_RENEWAL_MIN}/" "${EFS_CONF}"
	grep -q "^tls_cert_renewal_interval_min = ${CERT_RENEWAL_MIN}$" "${EFS_CONF}" \
		|| { restore_conf; fail "could not set tls_cert_renewal_interval_min"; }
	service ${WATCHDOG_RC} onestatus > /dev/null 2>&1 && service ${WATCHDOG_RC} onerestart > /dev/null
fi

START=$(now)
END=$((START + SOAK_HOURS * 3600))
trap on_signal INT TERM HUP

echo "${PORT_NAME} ${VER} soak: ${SOAK_HOURS}h on ${FS_ID}, results in ${OUT_DIR}"
PRE_MOUNTS=$(mount -t nfs | awk '{print $3}' | tr '\n' ' ')
event INFO "pre-existing NFS mounts: ${PRE_MOUNTS:-none} ($(pgrep -x efs-proxy | wc -l | tr -d ' ') efs-proxy)"
event INFO "start: ${PORT_NAME} ${VER}, $(uname -r) $(uname -m), ${SOAK_HOURS}h, sample=${SAMPLE_INTERVAL}s big=${BIG_MB}MiB/${BIG_EVERY}s cycle=${CYCLE_EVERY}s kill=${KILL_PROXY_EVERY}s cert=${CERT_RENEWAL_MIN:-60}min"

# -------------------------------------------------------------------- mount
mount_efs "${FS_ID}" "${MP}" -o tls,iam || { restore_conf; fail "mount_efs failed"; }
MOUNTED=1
event INFO "mounted: $(mount -t nfs | grep " on ${MP} ")"
i=0
while [ ${i} -lt 15 ] && [ -z "$(watchdog_pid)" ]; do i=$((i + 1)); sleep 1; done
[ -n "$(watchdog_pid)" ] || event FAIL "watchdog did not auto-start"
mkdir -p "${SOAKDIR}" || event FAIL "cannot create ${SOAKDIR}"

echo "${CSV_HDR}" > "${CSV}"
SEQ=0
NEXT_BIG=$((START + 300))
NEXT_CYCLE=$((START + 600))
NEXT_KILL=$((START + KILL_PROXY_EVERY))
NEXT_SUMMARY=$((START + SUMMARY_EVERY))

# ---------------------------------------------------------------- main loop
while [ ${STOP} -eq 0 ] && [ "$(now)" -lt ${END} ]; do
	sample
	t=$(now)

	job_poll probe "${PROBE_TIMEOUT}"; job_stall_check probe
	case ${JOB_STATE} in
	ok) PROBE_OK=$((PROBE_OK + 1)) ;;
	fail) PROBE_FAIL=$((PROBE_FAIL + 1)); event FAIL "probe failed rc=${JOB_RC}: $(job_msg probe)" ;;
	esac
	probe_state=${JOB_STATE}
	case ${probe_state} in
	idle|ok|fail) SEQ=$((SEQ + 1)); job_start probe probe_job ${SEQ} ;;
	esac

	job_poll big "${BIG_TIMEOUT}"; job_stall_check big
	big_state=${JOB_STATE}
	case ${big_state} in
	ok) event INFO "big: $(job_msg big)" ;;
	fail) event FAIL "big transfer failed rc=${JOB_RC}: $(job_msg big)" ;;
	esac

	job_poll cycle "${CYCLE_TIMEOUT}"; job_stall_check cycle
	cycle_state=${JOB_STATE}
	case ${cycle_state} in
	ok) event INFO "$(job_msg cycle)"; CYCLE_REAP_DEADLINE=$((t + REAP_TIMEOUT)) ;;
	fail) event FAIL "cycle failed rc=${JOB_RC}: $(job_msg cycle)"; CYCLE_REAP_DEADLINE=$((t + REAP_TIMEOUT)) ;;
	esac

	# Big transfer and cycle never overlap: the cycle reads the file big_job
	# replaces.
	big_idle=0; cycle_idle=0
	case ${big_state} in idle|ok|fail) big_idle=1 ;; esac
	case ${cycle_state} in idle|ok|fail) cycle_idle=1 ;; esac
	if [ ${WEDGED} -eq 0 ] && [ ${t} -ge ${NEXT_BIG} ] && [ ${big_idle} -eq 1 ] && [ ${cycle_idle} -eq 1 ]; then
		job_start big big_job
		NEXT_BIG=$((t + BIG_EVERY)); big_idle=0
	fi
	if [ ${WEDGED} -eq 0 ] && [ "${CYCLE_EVERY}" -gt 0 ] && [ ${t} -ge ${NEXT_CYCLE} ] \
	    && [ ${big_idle} -eq 1 ] && [ ${cycle_idle} -eq 1 ] && [ ${CYCLE_REAP_DEADLINE} -eq 0 ]; then
		job_start cycle cycle_job
		NEXT_CYCLE=$((t + CYCLE_EVERY))
	fi

	# Kill only when the main mount is otherwise quiet, to keep the injected
	# fault separate from in-flight I/O.
	if [ "${KILL_PROXY_EVERY}" -gt 0 ] && [ ${t} -ge ${NEXT_KILL} ] && [ ${WEDGED} -eq 0 ] \
	    && [ ${EXPECT_RESTART} -eq 0 ] && [ ${big_idle} -eq 1 ] && [ ${cycle_idle} -eq 1 ]; then
		kp=$(proxy_pid_of "${SAFE_A}")
		if [ -n "${kp}" ] && kill -9 "${kp}" 2>/dev/null; then
			event INFO "injected SIGKILL into efs-proxy ${kp}"
			EXPECT_RESTART=1; INJECTED_AT=${t}
		fi
		NEXT_KILL=$((t + KILL_PROXY_EVERY))
	fi

	if [ ${t} -ge ${NEXT_SUMMARY} ]; then
		summary
		NEXT_SUMMARY=$((t + SUMMARY_EVERY))
	fi

	# Backgrounded sleep: a signal ends the wait at once instead of after
	# a full SAMPLE_INTERVAL.
	sleep "${SAMPLE_INTERVAL}" &
	wait $! 2>/dev/null
done

trap - INT TERM HUP
[ ${STOP} -eq 1 ] && event INFO "stopped by signal" || event INFO "duration reached"
teardown
grep -q '^verdict: FAIL' "${OUT_DIR}/summary.txt" && exit 1
exit 0
