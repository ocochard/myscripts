#!/bin/sh
# Fan check for monit: RPM of every connected fan, read from ithwm(4)
# (ITE IT8613E Super I/O, see FreeBSD/docs/ithwm_amdpower.md). Prints nothing
# and exits 0 while every fan spins; prints one short phrase per problem and
# exits 1 otherwise, so monit's alert mail carries the reason.
#
# fan3 is deliberately absent from the list: it reads 0 RPM, nothing is
# plugged into that header. There is no fan0 on the IT8613E.
#
# No "set -e" here: the point is to test every fan and report all problems
# at once.

PATH=/sbin:/bin:/usr/sbin:/usr/bin
export PATH

fans="fan1 fan2 fan4"

# Fans idle at 950-1450 RPM. A stalled fan reads 0; 300 only catches a dead
# or dying fan, not the BIOS curve slowing down.
rpm_floor=300

problems=""

note() {
	problems="${problems:+$problems; }$1"
}

if ! sysctl -n dev.ithwm.0.%desc >/dev/null 2>&1; then
	echo "ithwm not attached, fan speeds unavailable"
	exit 1
fi

for fan in $fans; do
	rpm=$(sysctl -n dev.ithwm.0.$fan 2>/dev/null)
	case "$rpm" in
	''|*[!0-9]*)
		note "$fan unreadable"
		;;
	*)
		[ "$rpm" -lt "$rpm_floor" ] && note "$fan at $rpm RPM"
		;;
	esac
done

if [ -n "$problems" ]; then
	echo "$problems"
	exit 1
fi
exit 0
