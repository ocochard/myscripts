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

# Load Hardware Performance Monitoring Counter module
kldstat -q -m hwpmc || kldload hwpmc

# Delete existing log files
for f in /tmp/pmc.*.log /tmp/flamegraph.svg; do
  rm -rf "${f}"
done

# Collect system stats
pmcstat -z ${graphdepth} -l ${seconds} -S ${counter} -O /tmp/pmc.raw.log
# Generate system-wide profile with callgraphs
pmcstat -z ${graphdepth} -R /tmp/pmc.raw.log -G /tmp/pmc.callgraph.log

whereis -q stackcollapse-pmc.pl || die "Missing flamegraph package"
# fold stack samples into single lines.
stackcollapse-pmc.pl /tmp/pmc.callgraph.log > /tmp/pmc.folded.log
# Generate flamegraph
flamegraph.pl --title "counter: ${counter}" /tmp/pmc.folded.log > flamegraph.svg
echo "Done: flamegraph generated as /tmp/flamegraph.svg"
