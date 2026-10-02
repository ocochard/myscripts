#!/bin/sh
# Disk health check for monit: SMART status of every real disk, plus ZFS pool
# state. Prints nothing and exits 0 while everything is healthy; prints one
# short phrase per problem and exits 1 otherwise, so monit's alert mail carries
# the reason.
#
# da0 is deliberately absent from the device lists: it is an empty USB card
# reader (Generic MassStorageClass, mediasize 0) behind a bridge smartctl
# cannot talk to. smartctl needs /dev/nvmeN for the NVMe pair, not /dev/ndaN.
#
# No "set -e" here: the point is to test every device and report all problems
# at once, so each check handles its own failure and the script runs to the end.

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

ata_disks="ada0 ada1 ada2 ada3 ada4"
nvme_disks="nvme0 nvme1"

# Drives idle at 38-40C and have never passed 51C; 55 leaves headroom for a
# summer transcode without crying wolf.
temp_limit=55

# Alert while an NVMe still has spare blocks left to lose, not once it is out.
spare_floor=10

healthy_line="SMART overall-health self-assessment test result: PASSED"
problems=""

note() {
	problems="${problems}${problems:+; }$1"
}

for d in ${ata_disks}; do
	out=$(smartctl -H -A "/dev/${d}" 2>&1)
	status=$?
	if [ ${status} -ne 0 ]; then
		note "${d}: smartctl exit ${status}"
		continue
	fi

	echo "${out}" | grep -q "^${healthy_line}\$" || note "${d}: health not PASSED"

	# Attributes 5/187/197/198 start moving long before -H trips, so any
	# nonzero raw value is the early warning worth mailing about.
	bad=$(echo "${out}" | awk '
		($1 == 5 || $1 == 187 || $1 == 197 || $1 == 198) && $10 + 0 > 0 {
			printf "%s%s=%s", sep, $2, $10
			sep = ","
		}')
	[ -n "${bad}" ] && note "${d}: ${bad}"

	temp=$(echo "${out}" | awk '$1 == 194 { print $10 + 0; exit }')
	if [ -n "${temp}" ] && [ "${temp}" -gt "${temp_limit}" ]; then
		note "${d}: ${temp}C"
	fi
done

for d in ${nvme_disks}; do
	out=$(smartctl -H -A "/dev/${d}" 2>&1)
	status=$?
	if [ ${status} -ne 0 ]; then
		note "${d}: smartctl exit ${status}"
		continue
	fi

	echo "${out}" | grep -q "^${healthy_line}\$" || note "${d}: health not PASSED"

	warn=$(echo "${out}" | awk -F': *' '/^Critical Warning:/ { print $2; exit }')
	if [ -n "${warn}" ] && [ "${warn}" != "0x00" ]; then
		note "${d}: critical warning ${warn}"
	fi

	errs=$(echo "${out}" | awk -F': *' '
		/^Media and Data Integrity Errors:/ { gsub(/[^0-9]/, "", $2); print $2 + 0; exit }')
	if [ -n "${errs}" ] && [ "${errs}" -gt 0 ]; then
		note "${d}: ${errs} media errors"
	fi

	spare=$(echo "${out}" | awk -F': *' '
		/^Available Spare:/ { gsub(/[^0-9]/, "", $2); print $2 + 0; exit }')
	if [ -n "${spare}" ] && [ "${spare}" -lt "${spare_floor}" ]; then
		note "${d}: spare ${spare}%"
	fi
done

# Catches what SMART cannot: checksum errors, a degraded vdev, a faulted disk.
pools=$(zpool status -x 2>&1)
if [ "${pools}" != "all pools are healthy" ]; then
	note "zfs: $(echo "${pools}" | tr '\n' ' ' | cut -c1-200)"
fi

if [ -n "${problems}" ]; then
	echo "${problems}"
	exit 1
fi

exit 0
