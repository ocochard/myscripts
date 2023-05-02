#!/bin/sh
# Check for dynamic binaries with missing libs
set -e
dirs="/usr/local/lib /usr/local/libexec /usr/local/bin /usr/local/sbin /usr/bin /usr/sbin"

files=""
for dir in ${dirs}; do
	if [ -d "${dir}" ]; then
		for filename in $(find -L ${dir} -type f -perm +111); do
			if file ${filename} | grep -q 'dynamically linked'; then
				if ldd ${filename} 2>&1 | grep -q "not found"; then
					files=${files}"${filename}\n"
				fi
			fi
		done
	fi
done

if [ "${files}" = "" ];then
	echo "No missing lib found"
	exit 0
else
	echo "ERROR, list of binaries with missing libs:"
	echo "${files}"
	exit 1
fi
