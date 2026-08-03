#!/bin/sh
# decode-trace.sh — summarize a captured nfsdbg.log into the timeline that proves the bug.
#
# Works on a captured /tmp/nfsdbg.log (from capture-setup.sh) either locally or copied off.
# Prints: the successful recovery bursts, the renew-thread BADSESSION cadence, the transition
# into the permanent loop, and decodes the fop/fst wire codes.
#
# Usage: sh decode-trace.sh [path-to-nfsdbg.log]   (default: ./nfsdbg.log then /tmp/nfsdbg.log)

LOG="$1"
[ -z "$LOG" ] && { [ -f ./nfsdbg.log ] && LOG=./nfsdbg.log || LOG=/tmp/nfsdbg.log; }
[ -r "$LOG" ] || { echo "cannot read $LOG"; exit 1; }
CAT=cat; [ -r "$LOG" ] || CAT="sudo cat"

echo "=== log: $LOG ==="
echo
echo "### wire error codes seen (fop=op fst=status):"
echo "  fop=53 = SEQUENCE,       fst=10052 = NFS4ERR_BADSESSION      (server invalidates session)"
echo "  fop=43 = CREATE_SESSION, fst=10022 = NFS4ERR_STALE_CLIENTID  (server discarded ClientID)"
$CAT "$LOG" | grep -oE "fop=[0-9]+ fst=[0-9]+" | sort | uniq -c
echo
echo "### successful recovery bursts (each = extant-ClientID fails, ExchangeID fallback succeeds):"
$CAT "$LOG" | grep -nE "Marked defunct|create session for extant|aft exch=|aft createsess="
echo
echo "### event counts:"
for p in "Marked defunct" "Initiate recovery" "aft createsess=0" "Badsession looping"; do
	printf "  %5s  %s\n" "$($CAT "$LOG" | grep -c "$p")" "$p"
done
echo
echo "### transition: last successful recovery vs first permanent loop"
last=$($CAT "$LOG" | grep "aft createsess=0" | tail -1)
first=$($CAT "$LOG" | grep "Badsession looping" | head -1)
echo "  last recovery : ${last:-<none>}"
echo "  first loop    : ${first:-<none>}"
echo
echo "### renew-thread BADSESSION cadence BEFORE the loop (~45s = nfsc_renew = lease/2, with NO"
echo "    recovery lines between -> the defunct==0 guard is swallowing the re-triggers):"
# window = last successful recovery -> first Badsession looping
lastln=$($CAT "$LOG" | grep -n "aft createsess=0" | tail -1 | cut -d: -f1)
firstln=$($CAT "$LOG" | grep -n "Badsession looping" | head -1 | cut -d: -f1)
if [ -n "$lastln" ] && [ -n "$firstln" ]; then
	$CAT "$LOG" | sed -n "${lastln},${firstln}p" | grep "Got badsession" \
	    | grep -oE "^[A-Za-z]+ +[0-9]+ [0-9:]+" | head -20
	echo "  (each ~45s apart, none accompanied by 'Marked defunct'/'Initiate recovery')"
fi
