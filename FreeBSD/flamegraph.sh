#!/bin/sh
# Generate flamegraph
# Collect hw pmc and run flamegraph

set -eu

die() {
  echo -n "EXIT: " >&2
  echo "$@" >&2
  exit 1
}

if [ "$(id -u)" != "0" ]; then
  die "Need to be root for runnig pmcstat"
fi

cpu=$(sysctl -n hw.model | cut -d ' ' -f 1)
counter=""
seconds=20
graphdepth=32
case "${cpu}" in
  "AMD" )
    counter="ls_not_halted_cyc"
    ;;
  "ARM" )
    counter="CPU_CYCLES"
    ;;
  "Intel(R)" )
    counter="cpu_clk_unhalted.thread_p"
    ;;
  *)
    die "Unknow CPU (${cpu})"
esac

echo "${cpu} detected, using ${counter} PMC counter"

if ! kldstat -q -m hwpmc; then
  echo "Loading Hardware Peformance Monitoring Counter (hwpmc) kernel module..."
  kldload hwpmc
fi

tmpdir=$(mktemp -d -t flame)

echo "Collecting hwpmc for ${seconds} seconds..."
pmcstat -z ${graphdepth} -l ${seconds} -S ${counter} -O ${tmpdir}/pmc.raw.log
echo "Generate system-wide profile with callgraphs..."
pmcstat -z ${graphdepth} -R ${tmpdir}/pmc.raw.log -G /${tmpdir}/pmc.callgraph.log

whereis -q stackcollapse-pmc.pl || die "Missing benchmarks/flamegraph package"
echo "Fold stack samples into single lines..."
stackcollapse-pmc.pl ${tmpdir}/pmc.callgraph.log > ${tmpdir}/pmc.folded.log
echo "Generating flamegraph svg..."
flamegraph.pl --title "counter: ${counter}" ${tmpdir}/pmc.folded.log > ${tmpdir}/flamegraph.svg
echo "Done: flamegraph generated as ${tmpdir}/flamegraph.svg"
