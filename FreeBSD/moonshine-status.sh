#!/bin/sh
# Show the state of a Moonshine game streaming host from the client.
#
# moonlight-embedded has no status overlay: when the game hangs or crashes on
# the host, the client keeps showing the last frame.  This reports, over ssh:
#  - the last session event and launched application,
#  - the Windows processes running under Wine, with their CPU use (an Unreal
#    Engine CrashReportClient.exe means the game crashed),
#  - since the last launch: "No frames received" warnings (the game draws
#    nothing) and Vulkan device lost errors (vr -4, the GPU hung),
#  - amdgpu ring timeouts in the kernel message buffer (no timestamps there,
#    so they can be older than the current session).
#
# Usage: moonshine-status.sh [host]   (default 192.168.100.7)

set -eu

host=${1:-192.168.100.7}
log=/var/log/moonshine.log

ssh "$host" LOG="$log" sh -s <<'EOF'
set -u
start=$(grep -n "Launched application" "$LOG" | tail -1 | cut -d: -f1)
start=${start:-1}

echo "== Session"
tail -n "+$start" "$LOG" | grep -E "^[0-9T:.-]+Z +[A-Z]+ moonshine_core::session::(manager|application)" |
    tail -3 | sed -E 's/^([0-9-]+)T([0-9:]+)\.[0-9]+Z +[A-Z]+ moonshine_core::session::[a-z_:]+: /\1 \2 UTC  /'

echo "== Wine processes"
ps -axwwo pid,etime,%cpu,rss,command | grep -iE '\.exe \(wine\)$' | grep -v system32 |
    awk '{printf "%-7s %-9s %5s%% %6d MB  ", $1, $2, $3, $4/1024; $1=$2=$3=$4=""; sub(/^ +/, ""); n=split($0, p, /[\\\/]/); print p[n]}' |
    grep . || echo "none"

echo "== Since last launch"
nf=$(tail -n "+$start" "$LOG" | grep -c "No frames received")
dl=$(tail -n "+$start" "$LOG" | grep -c "vr -4")
echo "No frames received warnings: $nf"
[ "$nf" -gt 0 ] && tail -n "+$start" "$LOG" | grep "No frames received" | tail -1 | cut -c1-19 | sed 's/T/ /;s/$/ UTC (last)/'
echo "Vulkan device lost (vr -4):  $dl"

echo "== amdgpu ring timeouts (kernel buffer, may be old)"
dmesg | grep -E "ring .* timeout" | tail -3 | grep . || echo "none"
EOF
