#!/bin/sh
# From a git cloned repos, generate FreeBSD port Makefile GH_TUPLE=
# git clone git@github.com:pytorch/pytorch.git
# git submodule update --init --recursive
# git submodule status
#
# Almost related, plist update
# grep 'Error: Orphaned: ' build.log | sed 's/Error: Orphaned: //' > to-be-added.txt
# grep 'Error: Missing: ' build.log | sed 's/Error: Missing: //'> to-be-removed.txt
# grep -F -x -v -f /root/To-remove.txt pkg-plist > pkg-plist.new
# cat to-be-added.txt >> pkg-plist.new

set -eu

die () {
	echo $1
	exit 1
}

if [ ! -r .gitmodules ]; then
	die "no .gitmodules"
fi

path=""
fullhash=""
hash=""
url=""
account=""
tag=""
project=""
gl=""

while read -r line; do
	if echo "${line}" | grep -q '\[submodule'; then
		continue
	elif echo "${line}" | grep -q 'ignore = '; then
		continue
	elif echo "${line}" | grep -q 'path = '; then
		if [ -n "${path}" ]; then
			die "BUG: path could not be already filled with ${path}"
		fi
		path=$(echo "$line" | cut -d ' ' -f 3)
		if [ -z "${path}" ]; then
			die "BUG: path could not be empty, line is ${line}"
		fi
		if [ -n "${hash}" ]; then
			die "BUG: hash could not be already filled with ${hash}"
		fi
		fullhash=$(git submodule status "${path}" | cut -d ' ' -f 2)
		hash=$(echo "${fullhash}" head -c 8)
		if [ -z "${hash}" ]; then
			die "BUG: hash could not be empty, line is ${line}"
		fi
	elif echo "${line}" | grep -q 'url = '; then
		if [ -n "${url}" ]; then
			die "BUG: url could not be already filled with ${url}"
		fi
		url=$(echo "$line" | cut -d ' ' -f 3)
		if [ -z "${url}" ]; then
			die "BUG: url could not be empty, line is $line"
		fi
		# Warning of gitlab
		if echo "${url}" | grep -q 'gitlab.com'; then
			gl="GL_TUPLE="
			# gitlab doesn't support shorthash
			hash="${fullhash}"
		fi
		if [ -n "${account}" ]; then
			die "BUG: account could not be already filled with ${account}"
		fi
		account=$(echo "${url}" | cut -d '/' -f 4)
		if [ -z "${account}" ]; then
			die "BUG: account could not be empty, line is $line"
		fi
		if [ -n "${project}" ]; then
			die "BUG: account could not be already filled with ${project}"
		fi
		project=$(echo "${url}" | cut -d '/' -f 5 | cut -d '.' -f 1)
		if [ -z "${project}" ]; then
			die "BUG: project could not be empty, line is $line"
		fi
	fi
	if [ -n "${account}" ] && [ -n "${project}" ] && [ -n "${hash}" ]; then
		# Tag is project with '-' replaced by '_'
		if [ -n "${tag}" ]; then
			die "BUG: tag could not be already filled with ${tag}"
		fi
		tag=$(echo "${project}" | tr '-' '_')
		if [ -z "${tag}" ]; then
			die "BUG: tag could not be empty, project is $project"
		fi
		echo "${gl}${account}:${project}:${hash}:${tag}/${path} \\"
		gl=""
		path=""
		fullhash=""
		hash=""
		url=""
		account=""
		tag=""
		project=""

	fi
done < .gitmodules
