#!/bin/sh
#
# monit check: Jellyfin inotify watch leak early warning.
#
# Jellyfin's LibraryMonitor leaks inotify watches on re-arm. Steady state on
# nas is ~20k; it reached the 362766 cap on 2026-08-24 and every library
# stopped auto-detecting new media with:
#
#   [ERR] LibraryMonitor: Error watching path: "/NAS/films"
#   System.IO.IOException: The configured user limit on the number of inotify
#   instances has been reached ...
#
# The cap was raised to 1000000 in /etc/sysctl.conf, which DELAYS the failure
# but does not fix the leak. This check warns while there is still headroom,
# so the fix (service jellyfin restart) happens before users notice.
#
# See jellyfin/vaapi-transcode-hang.md and jellyfin/jellyfin.md.
#
# Install:
#   cp monit_inotify.sh /usr/local/bin/
#   chmod +x /usr/local/bin/monit_inotify.sh
# Then in /usr/local/etc/monitrc, alongside the existing temperature check:
#
#   check program inotify with path /usr/local/bin/monit_inotify.sh
#       if status != 0 then alert
#
# Exit 0 = healthy, 1 = warning (alert), 2 = critical (alert).

set -u

WARN_PCT=50    # leak is well underway
CRIT_PCT=80    # library watching will break soon

watches=$(sysctl -n vfs.inotify.watches 2>/dev/null)
cap=$(sysctl -n vfs.inotify.max_user_watches 2>/dev/null)

case "$watches$cap" in
	''|*[!0-9]*)
		echo "inotify: cannot read vfs.inotify sysctls"
		exit 2
		;;
esac

[ "$cap" -gt 0 ] || { echo "inotify: max_user_watches is 0"; exit 2; }

pct=$((watches * 100 / cap))

if [ "$pct" -ge "$CRIT_PCT" ]; then
	echo "CRITICAL: inotify watches ${watches}/${cap} (${pct}%) - jellyfin leak, restart it: service jellyfin restart"
	exit 2
fi

if [ "$pct" -ge "$WARN_PCT" ]; then
	echo "WARNING: inotify watches ${watches}/${cap} (${pct}%) - jellyfin leaking, plan a restart"
	exit 1
fi

echo "OK: inotify watches ${watches}/${cap} (${pct}%)"
exit 0
