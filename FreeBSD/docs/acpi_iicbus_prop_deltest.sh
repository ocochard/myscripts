#!/bin/sh
# iicdel.sh <cycles>: unload/reload ig4 (deletes and re-adds the acpi_iicbus
# children), filling the _DSD cache of cs35l540 with proptest each time.
n=${1:-20}
mem() { vmstat -m | awk '$1=="devbuf"||$1=="acpica"{printf "%s=%s ", $1, $2}'; echo; }
echo "before: $(mem)"
i=0
while [ $i -lt $n ]; do
	kldload /tmp/proptest.ko >/dev/null 2>&1 && kldunload proptest
	kldunload snd_cs35l54 2>/dev/null
	kldunload ig4 || { echo "unload failed at $i"; exit 1; }
	kldload ig4 || { echo "load failed at $i"; exit 1; }
	sleep 4
	i=$((i + 1))
done
kldstat -q -n snd_cs35l54 || kldload snd_cs35l54
sleep 3
echo "after $n cycles: $(mem)"
devinfo | grep -E 'iichid0|cs35l540' | tr -s ' ' | tr '\n' ' '; echo
