#!/bin/sh
# Measure how much CPU time goes to the kernel's linear scans over GPU mappings
# while a game runs, to compare a kernel before and after a fix.
#
# Run with -h for the meaning of each value in the report.

set -eu

SCANS="linux_root_RB_NEXT vm_pager_object_lookup linux_file_mmap linux_cdev_pager_populate linux_cdev_pager_dtor"

usage() {
	cat <<USAGE
Usage: $(basename "$0") [-d seconds] [-f frames.csv] [-o report] pid|process-regex
       $(basename "$0") -c before-report after-report
       $(basename "$0") -h

Samples all CPUs with pmcstat while the given process runs, and writes a report.
Needs root, and loads hwpmc.ko if needed.  With Wine, target the game itself (for
example Win64-Shipping), not the "wine" launcher: a pid that uses no CPU is refused.

  -c  compare two reports
  -d  sampling time in seconds (default 60)
  -f  Mesa overlay frame log, to report the FPS during the sampling, created with:
      VK_INSTANCE_LAYERS=VK_LAYER_MESA_overlay \\
      VK_LAYER_MESA_OVERLAY_CONFIG=output_file=frames.csv,frame_timing,gpu_timing
  -h  show this help
  -o  report file (default amdgpu_map_cost-<date>.txt)
Environment: PMC_EVENT, the CPU cycles event for a CPU this script does not know
(see pmcstat -L)

Report values:
  kernel        running kernel version and build date
  osreldate     running kernel's __FreeBSD_version
  drm_module    path of the loaded amdgpu.ko
  drm_package   installed drm-kmod package; a locally built module may differ
  pid, command  the sampled process
  duration      sampling time in seconds
  event         CPU event counted, which is CPU cycles
  mappings      memory mappings of the process at the end of the sampling.
                All kinds are counted, but in a game most are GPU buffers.  The
                scans get longer as this grows.
  new_mappings_per_s
                growth of mappings per second.  Near zero, the game may be doing
                little of the work that triggers the scans, so a low scan share
                in that run does not show that a fix works.
  cpu_cores     CPUs used by the process on average; 1.00 is one CPU fully busy
  other_cores   CPUs used by everything else.  Above about 1, the machine is
                busy with something else (like a build), which lowers all the
                shares below and the FPS: such a run is not comparable.
  sys_pct       share of the process's CPU time spent in the kernel
  fps_median    frames per second: half of the overlay samples are above this
  fps_p10       10% of the overlay samples are below this: the slow moments
  discarded     pmcstat events lost.  A few hundred out of many samples is fine.
  samples       CPU samples taken on all CPUs
  scan_<function>_pct
                share of all samples spent in that function:
                  linux_root_RB_NEXT         GPU mapping search (amdgpu_vm_bo_map)
                  vm_pager_object_lookup     device memory object search (mmap)
                  linux_file_mmap            CPU mapping search (mmap)
                  linux_cdev_pager_populate  CPU mapping search (page fault)
                  linux_cdev_pager_dtor      CPU mapping search (object removal)
  scan_total_pct
                sum of the above, the main result.  It is expected to be close to
                zero with the fixes, in a run where the game creates mappings.
  top           the 10 functions with the most samples.  An address instead of a
                name is a function in a library without symbols.

Shares change a lot with what the game does: 20% in one minute and 0% in the next
was measured on the same kernel.  Compare the same scene, and repeat the runs.
USAGE
	exit "$1"
}

compare() {
	awk -F= '
	FNR == 1 { run++ }
	/^(scan_|fps_|sys_pct=|cpu_cores=|other_cores=|mappings=|new_mappings_per_s=|samples=|kernel=)/ {
		if (!($1 in seen)) { seen[$1] = 1; order[++n] = $1 }
		v[run, $1] = $2
	}
	END {
		printf "%-34s %14s %14s\n", "", "before", "after"
		for (i = 1; i <= n; i++) {
			k = order[i]
			if (k == "kernel") {
				printf "before: %s\nafter:  %s\n", v[1, k], v[2, k]
				continue
			}
			printf "%-34s %14s %14s\n", k, v[1, k], v[2, k]
		}
	}' "$1" "$2"
}

# Convert the ps time format ([hh:]mm:ss.cc) to seconds
cpu_seconds() {
	ps -o "$1=" -p "$2" | awk '{
		n = split($1, a, ":"); s = 0
		for (i = 1; i <= n; i++) s = s * 60 + a[i]
		print s
	}'
}

count_mappings() {
	procstat -v "$1" | awk 'NR > 1 { n++ } END { print n + 0 }'
}

find_cycles_event() {
	if [ -n "${PMC_EVENT:-}" ]; then
		echo "${PMC_EVENT}"
		return
	fi
	# ls_not_halted_cyc: AMD, cpu_clk_unhalted.*: Intel
	for e in ls_not_halted_cyc cpu_clk_unhalted.thread_p cpu_clk_unhalted.thread; do
		if pmcstat -L 2>/dev/null | grep -qwF "${e}"; then
			echo "${e}"
			return
		fi
	done
	echo "ERROR: unknown CPU cycles event, set PMC_EVENT (see pmcstat -L)" >&2
	exit 1
}

# The process matching the regex that uses the most CPU, as a game has helpers
find_target() {
	case $1 in
	*[!0-9]*)
		for p in $(pgrep -f "$1"); do
			[ "${p}" -ne $$ ] && echo "${p}"
		done | xargs -r ps -o pid= -o %cpu= -p | sort -k2 -rn | awk 'NR == 1 { print $1 }'
		;;
	*)
		echo "$1"
		;;
	esac
}

duration=60
frames=""
report=amdgpu_map_cost-$(date +%Y%m%d-%H%M%S).txt
cmp=false
while getopts "cd:f:ho:" opt; do
	case ${opt} in
	c) cmp=true ;;
	d) duration=${OPTARG} ;;
	f) frames=${OPTARG} ;;
	h) usage 0 ;;
	o) report=${OPTARG} ;;
	*) usage 1 ;;
	esac
done
shift $((OPTIND - 1))

if ${cmp}; then
	[ $# -eq 2 ] || usage 1
	compare "$1" "$2"
	exit 0
fi

[ $# -eq 1 ] || usage 1
if [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: needs root"
	exit 1
fi
kldload -n hwpmc
event=$(find_cycles_event)
pid=$(find_target "$1")
if [ -z "${pid}" ] || ! ps -p "${pid}" >/dev/null; then
	echo "ERROR: no process matches $1"
	exit 1
fi

tmp=$(mktemp -d -t amdgpu_map_cost)
trap 'rm -rf "${tmp}"' EXIT

frames_before=0
[ -z "${frames}" ] || frames_before=$(wc -l < "${frames}")
user_before=$(cpu_seconds usertime "${pid}")
sys_before=$(cpu_seconds systime "${pid}")
mappings_before=$(count_mappings "${pid}")
cp_before=$(sysctl -n kern.cp_time)

# Process mode (-P) was tried first, to ignore other load: on a 125-thread game
# it lost most samples, and sometimes all of them.
echo "Sampling all CPUs for ${duration} s with ${event}, target pid ${pid}"
pmcstat -N -n 400000 -S "${event}" -O "${tmp}/log" sleep "${duration}" \
    2>"${tmp}/pmcstat.err" || { cat "${tmp}/pmcstat.err"; exit 1; }

user_after=$(cpu_seconds usertime "${pid}")
sys_after=$(cpu_seconds systime "${pid}")
mappings_after=$(count_mappings "${pid}")
cp_after=$(sysctl -n kern.cp_time)
ncpu=$(sysctl -n hw.ncpu)
cores=$(echo "${user_before} ${user_after} ${sys_before} ${sys_after} ${duration}" |
    awk '{ printf "%.2f", (($2 - $1) + ($4 - $3)) / $5 }')

if [ "$(echo "${cores}" | awk '{ print ($1 < 0.05) }')" -eq 1 ]; then
	echo "ERROR: pid ${pid} used no CPU during the sampling, is it the game?"
	echo "Wine starts the game as another process, the busiest ones are:"
	ps -axo pid,%cpu,command | sort -k2 -rn | head -5 | cut -c1-100
	exit 1
fi
pmcstat -R "${tmp}/log" -z1 -G "${tmp}/graph" >/dev/null 2>&1

{
	echo "kernel=$(uname -v | awk '{ print $4, $5, $6, $7, $8, $9, $10 }')"
	echo "osreldate=$(sysctl -n kern.osreldate)"
	echo "drm_module=$(kldstat -v 2>/dev/null | awk '/amdgpu.ko/ { print $NF; exit }')"
	echo "drm_package=$(pkg query -g '%n-%v' 'drm*kmod' 2>/dev/null | tr '\n' ' ')"
	echo "pid=${pid}"
	echo "command=$(ps -o comm= -p "${pid}")"
	echo "duration=${duration}"
	echo "event=${event}"
	echo "mappings=${mappings_after}"
	echo "new_mappings_per_s=$(echo "${mappings_before} ${mappings_after} ${duration}" |
	    awk '{ printf "%.0f", ($2 - $1) / $3 }')"
	echo "cpu_cores=${cores}"
	# kern.cp_time holds the user, nice, system, interrupt and idle ticks
	echo "${cp_before} ${cp_after} ${ncpu} ${cores}" | awk '{
		busy = 0
		for (i = 1; i <= 4; i++) busy += $(i + 5) - $i
		total = busy + $10 - $5
		other = (total > 0 ? $11 * busy / total : 0) - $12
		printf "other_cores=%.2f\n", (other > 0 ? other : 0)
	}'
	echo "${user_before} ${user_after} ${sys_before} ${sys_after}" | awk '{
		c = ($2 - $1) + ($4 - $3)
		printf "sys_pct=%.1f\n", (c > 0 ? 100 * ($4 - $3) / c : 0)
	}'
	if [ -n "${frames}" ]; then
		tail -n +$((frames_before + 1)) "${frames}" |
		    awk -F, 'NF >= 3 && $3 + 0 > 0 { print $3 + 0 }' | sort -n |
		    awk '{ a[NR] = $1 } END {
			if (NR) printf "fps_median=%.1f\nfps_p10=%.1f\n", a[int(NR / 2) + 1], a[int(NR * .1) + 1]
		    }'
	fi
	echo "discarded=$(grep -o 'least [0-9]*' "${tmp}/pmcstat.err" | awk '{ print $2 + 0; f = 1 } END { if (!f) print 0 }')"
	awk -v scans="${SCANS}" '
	/^[0-9.]+%/ {
		n = $2
		gsub(/[][]/, "", n)
		s[$3] += n
		t += n
		next
	}
	END {
		printf "samples=%d\n", t
		c = split(scans, f, " ")
		for (i = 1; i <= c; i++) {
			printf "scan_%s_pct=%.2f\n", f[i], t ? 100 * s[f[i]] / t : 0
			sum += s[f[i]]
		}
		printf "scan_total_pct=%.2f\n", t ? 100 * sum / t : 0
		for (k in s)
			if (s[k] > 0)
				printf "top %6.2f%% %s\n", 100 * s[k] / t, k | "sort -k2 -rn | head -10"
	}' "${tmp}/graph"
} > "${report}"
cat "${report}"
echo "Report: ${report} (run with -h for the meaning of each value)"
