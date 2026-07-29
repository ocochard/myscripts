#!/bin/sh
# Self-healing vendor-driver 2.5G test, v2: polls re0 link across the whole
# hold window so we see whether multi-gig training ever converges.
# Auto-reverts to rge no matter what.
LOG=/tmp/re_swap_test.log
exec >"$LOG" 2>&1
echo "=== START $(date) ==="

PCI=pci0:191:0:0
IP=192.168.100.7/24
GW=192.168.100.254

revert() {
	echo "=== REVERT $(date) ==="
	ifconfig re0 down 2>/dev/null
	devctl set driver -f re0 rge 2>/dev/null || \
	    devctl set driver -f "$PCI" rge 2>/dev/null
	sleep 3
	ifconfig rge0 inet "$IP" up 2>/dev/null
	route add default "$GW" 2>/dev/null
	sleep 8
	echo "--- after revert (rge should re-train, give it time) ---"
	ifconfig rge0 2>&1 | grep -E "media|status|inet "
	kldunload if_re 2>/dev/null && echo "if_re unloaded" || echo "if_re unload skipped"
	echo "=== END $(date) ==="
}
trap revert EXIT INT TERM

echo "--- load vendor if_re (idempotent) ---"
if kldstat -q -n if_re; then
	echo "if_re already loaded"
else
	kldload /tmp/revendor/if_re.ko && echo "if_re loaded" || { echo "LOAD FAIL"; exit 1; }
fi

echo "--- rebind rge0 -> re ---"
devctl set driver -f rge0 re && echo "rebind ok" || { echo "REBIND FAIL"; exit 1; }
sleep 4

echo "--- bring up re0 ---"
ifconfig re0 inet "$IP" up
route add default "$GW" 2>/dev/null

echo "=== POLL re0 link for up to 60s (2.5G training can take several s) ==="
i=0
best="none"
while [ $i -lt 30 ]; do
	m=$(ifconfig re0 2>/dev/null | grep media)
	s=$(ifconfig re0 2>/dev/null | grep -o 'status: [a-z ]*')
	echo "t=$((i*2))s  $m  [$s]"
	echo "$m" | grep -q 2500 && { best="2500"; }
	echo "$m" | grep -q 5000 && { best="5000"; }
	echo "$m" | grep -qi active && echo "$m" | grep -q 1000 && [ "$best" = "none" ] && best="1000"
	i=$((i+1))
	sleep 2
done
echo "=== re0 BEST OBSERVED SPEED: $best ==="
echo "=== dmesg re0 ==="
dmesg | grep -iE "re0" | tail -20
# EXIT trap reverts to rge
