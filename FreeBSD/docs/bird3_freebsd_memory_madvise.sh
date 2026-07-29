#!/bin/sh
# bird3_freebsd_memory_madvise.sh
#
# Companion to bird3_freebsd_memory_madvise.md.
#
# Reproduces the "RSS >> `show memory` totals" behaviour of bird3 on FreeBSD
# and demonstrates that it is caused by MADV_FREE semantics rather than a
# memory leak.
#
# Runs read-only against net/bird3 with a private config in $WORKDIR — does
# not touch /usr/local/etc/bird.conf, /var/run/bird/, or the kernel FIB
# (kernel protocol disabled in the generated config).
#
# Usage:
#   sh bird3_freebsd_memory_madvise.sh              # steps 1 + 3, safe
#   sh bird3_freebsd_memory_madvise.sh --pressure   # + step 2 (needs SWAP + headroom)
#
# WARNING: --pressure allocates ~physmem*0.9 of anonymous memory. On a host
# without generous swap this WILL trigger the OOM reaper and may kill other
# processes. Do not run on a workstation you care about.

set -eu

WORKDIR=${WORKDIR:-/tmp/bird-repro}
BIRD=${BIRD:-/usr/local/sbin/bird}
BIRDC=${BIRDC:-/usr/local/sbin/birdc}
PRESSURE=0
[ "${1:-}" = "--pressure" ] && PRESSURE=1

command -v "$BIRD"  >/dev/null || { echo "bird not found: $BIRD"; exit 1; }
command -v "$BIRDC" >/dev/null || { echo "birdc not found: $BIRDC"; exit 1; }

mkdir -p "$WORKDIR"
cd "$WORKDIR"

banner() { printf '\n=== %s ===\n' "$*"; }

################################################################################
# Step 3 — compile-flag path (static + dynamic evidence)
################################################################################
banner "Step 3: which madvise flag does the installed bird3 actually use?"

# Static: MADV_FREE = 5, MADV_DONTNEED = 4 on FreeBSD.
# Find the immediate constant passed to %edx before every call to madvise@plt.
echo "-- static: constants passed to madvise() in the binary --"
objdump -d --disassemble-all "$BIRD" 2>/dev/null | awk '
  /call.*<madvise@plt>/ { print prev; count++ }
  { prev=$0 }
  END { if (!count) print "(no madvise call sites found)" }
' | grep -oE 'movl\s+\$0x[0-9]+,\s+%edx' | sort -u

echo "-- header cross-check --"
awk '/^#define[[:space:]]+MADV_(FREE|DONTNEED|NORMAL|WILLNEED)[[:space:]]/' \
  /usr/include/sys/mman.h

################################################################################
# Start bird3 with a synthetic route load big enough for a cold-page pool
################################################################################
banner "Generating configs (200k / 400k static routes)"

awk 'BEGIN {
  print "log stderr all;"
  print "router id 10.0.0.1;"
  print "protocol device {}"
  print "protocol static static_v4 { ipv4 { table master4; };"
  for (i = 0; i < 200000; i++) {
    a = 10 + int(i / 65536); b = int((i / 256) % 256); c = i % 256
    printf "  route %d.%d.%d.0/24 blackhole;\n", a, b, c
  }
  print "}"
}' > bird.conf
# Small config for reload churn
cat > bird-small.conf <<'EOF'
log stderr all;
router id 10.0.0.1;
protocol device {}
protocol static static_v4 { ipv4 { table master4; }; route 192.0.2.0/24 blackhole; }
EOF
# Big config: 400k routes
awk '
BEGIN {
  print "log stderr all;"
  print "router id 10.0.0.1;"
  print "protocol device {}"
  print "protocol static static_v4 { ipv4 { table master4; };"
  for (i = 0; i < 400000; i++) {
    a = 20 + int(i / 65536); b = int((i / 256) % 256); c = i % 256
    printf "  route %d.%d.%d.0/24 blackhole;\n", a, b, c
  }
  print "}"
}' > bird-big.conf

banner "Starting bird3 (no kernel protocol; own socket; own pidfile)"
"$BIRD" -c "$WORKDIR/bird.conf" -s "$WORKDIR/bird.ctl" -P "$WORKDIR/bird.pid" -f \
    > "$WORKDIR/bird.log" 2>&1 &
sleep 4
BIRDPID=$(cat "$WORKDIR/bird.pid")
echo "bird pid=$BIRDPID"
ps -o pid,vsz,rss -p "$BIRDPID"

################################################################################
# Step 1 — dynamic evidence: truss confirms MADV_FREE at runtime
################################################################################
banner "Step 1: truss bird during a reload cycle — capture madvise flag"

truss -p "$BIRDPID" -f -o "$WORKDIR/truss.out" 2>/dev/null &
TRUSSPID=$!
sleep 1
# Force a cold-page churn by reloading twice
"$BIRDC" -s "$WORKDIR/bird.ctl" configure \"$WORKDIR/bird-small.conf\" >/dev/null
sleep 1
"$BIRDC" -s "$WORKDIR/bird.ctl" configure \"$WORKDIR/bird-big.conf\" >/dev/null
sleep 3
kill $TRUSSPID 2>/dev/null || true
wait $TRUSSPID 2>/dev/null || true

echo "-- unique 3rd-arg values seen in madvise() calls --"
grep -oE 'madvise\([^)]*\)' "$WORKDIR/truss.out" | awk -F, '{print $NF}' | sort -u
echo "-- total madvise() calls captured --"
grep -c 'madvise(' "$WORKDIR/truss.out" || true

################################################################################
# Build a cold-page pool by cycling reloads, then compare RSS to show memory
################################################################################
banner "Churn to grow the cold-page pool"
for i in 1 2 3 4; do
  "$BIRDC" -s "$WORKDIR/bird.ctl" configure \"$WORKDIR/bird-small.conf\" >/dev/null
  sleep 1
  "$BIRDC" -s "$WORKDIR/bird.ctl" configure \"$WORKDIR/bird-big.conf\" >/dev/null
  sleep 2
  RSS=$(ps -o rss= -p "$BIRDPID" | tr -d ' ')
  VSZ=$(ps -o vsz= -p "$BIRDPID" | tr -d ' ')
  echo "cycle $i: VSZ=${VSZ}kB RSS=${RSS}kB"
done

banner "Steady state after churn"
ps -o pid,vsz,rss -p "$BIRDPID"
"$BIRDC" -s "$WORKDIR/bird.ctl" show memory
"$BIRDC" -s "$WORKDIR/bird.ctl" show route count

################################################################################
# Step 2 — memory pressure (optional, dangerous)
################################################################################
if [ "$PRESSURE" = 1 ]; then
  banner "Step 2: force reclaim with an anonymous-memory hog"
  cat > hog2.c <<'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
volatile unsigned long sink;
int main(int argc, char **argv) {
    if (argc < 2) return 1;
    size_t gb = strtoull(argv[1], NULL, 10);
    size_t sz = gb * (size_t)1024 * 1024 * 1024;
    size_t pg = 4096;
    fprintf(stderr, "mallocing %zu GB...\n", gb);
    volatile char *p = malloc(sz);
    if (!p) { perror("malloc"); return 1; }
    fprintf(stderr, "malloc ok, touching pages...\n");
    for (size_t i = 0; i < sz; i += pg) {
        p[i] = (char)i;
        sink += (unsigned char)p[i];  /* defeat DCE */
    }
    fprintf(stderr, "touched %zu GB, sleeping\n", gb);
    sleep(atoi(argv[2] ? argv[2] : "20"));
    return 0;
}
CEOF
  cc -O2 -o hog2 hog2.c
  # allocate ~80 % of physmem to avoid OOM roulette
  PHYSMEM_GB=$(( $(sysctl -n hw.physmem) / 1024 / 1024 / 1024 ))
  HOG_GB=$(( PHYSMEM_GB * 8 / 10 ))
  echo "physmem=${PHYSMEM_GB}GB, hog=${HOG_GB}GB"

  ./hog2 "$HOG_GB" 30 > hog.log 2>&1 &
  HOGPID=$!
  for i in $(seq 1 30); do
    sleep 5
    BRSS=$(ps -o rss= -p "$BIRDPID" 2>/dev/null | tr -d ' ')
    HRSS=$(ps -o rss= -p "$HOGPID" 2>/dev/null | tr -d ' ')
    FREE=$(sysctl -n vm.stats.vm.v_free_count)
    LAST=$(tail -1 hog.log 2>/dev/null)
    printf "t=%3ds bird=%skB hog=%skB free=%spg |%s|\n" \
      $((i*5)) "$BRSS" "${HRSS:-DEAD}" "$FREE" "$LAST"
    [ -z "$HRSS" ] && [ $i -gt 2 ] && break
  done
  wait $HOGPID 2>/dev/null || true

  banner "After pressure released"
  sleep 3
  ps -o pid,vsz,rss -p "$BIRDPID"
  "$BIRDC" -s "$WORKDIR/bird.ctl" show memory
fi

banner "Stopping bird"
kill "$BIRDPID" 2>/dev/null || true
sleep 1
echo "Done. Artifacts in $WORKDIR:"
ls "$WORKDIR"
