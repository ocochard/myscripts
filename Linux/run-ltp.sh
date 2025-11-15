#!/usr/bin/env bash
# Install and run Linux Test Project
# https://github.com/linux-test-project/ltp
# The official debian ltp packages includes:
# - ltp-commands-test
# - ltp-tools
# - ltp-kernel-test
# - ltp-network-test
# - ltp-misc-test
# - ltp-disk-test

set -eu
ltp_version="20250930"
workdir="${HOME}/ltp"

die() {
	echo "FATAL: $1"
	exit 1
}

check_requirements() {
	echo "Checking system requirements..."

	# Check if running on Ubuntu/Debian
	if ! command -v dpkg >/dev/null 2>&1; then
		echo "Warning: This script is designed for Ubuntu/Debian systems"
	fi

	# List of required packages with their Ubuntu package names
	declare -A required_packages=(
		["git"]="git"
		["autoconf"]="autoconf"
		["automake"]="automake"
		["build-essential"]="build-essential"
		["m4"]="m4"
		["pkg-config"]="pkg-config"
		["linux-libc-dev"]="linux-libc-dev"
	)

	missing_packages=()

	# Check each required package
	for cmd in "${!required_packages[@]}"; do
		package_name="${required_packages[$cmd]}"

		# Special handling for different package types
		case "$cmd" in
			"build-essential"|"linux-libc-dev")
				# Check if meta-package or development headers are installed
				if ! dpkg -l | grep -q "^ii.*$package_name"; then
					missing_packages+=("$package_name")
				fi
				;;
			*)
				# Check if command exists
				if ! command -v "$cmd" >/dev/null 2>&1; then
					missing_packages+=("$package_name")
				fi
				;;
		esac
	done

	# Report results
	if [ ${#missing_packages[@]} -eq 0 ]; then
		echo "All required packages are installed"
	else
		echo "Missing required packages:"
		printf "  %s\n" "${missing_packages[@]}"
		echo ""
		echo "Installing missing packages..."
		sudo apt update && sudo apt install -y ${missing_packages[*]}
	fi
}

fetch_sources() {
	echo "Checking LTP sources..."

	# Check if source directory already exists
	if [ -d "${workdir}/src" ]; then
		echo "LTP source directory exists, checking version..."

		# Check if it's a git repository
		if [ -d "${workdir}/src/.git" ]; then
			# Get current version/tag
			current_version=$(git -C ${workdir}/src describe --tags --exact-match 2>/dev/null || echo "unknown")

			if [ "$current_version" = "$ltp_version" ]; then
				echo "LTP is already at version $ltp_version"
				return 0
			else
				echo "Current version: $current_version, required: $ltp_version"
				echo "Updating to version $ltp_version..."

				# Fetch latest tags and checkout the required version
				git -C ${workdir}/src fetch --tags
				if git -C ${workdir}/src checkout $ltp_version 2>/dev/null; then
					# Update submodules for the new version
					git -C ${workdir}/src submodule update --init --recursive
					echo "Updated to version $ltp_version"
					return 0
				else
					echo "Failed to checkout version $ltp_version, re-cloning..."
					rm -rf ${workdir}/src
				fi
			fi
		else
			echo "Source directory exists but is not a git repository, removing..."
			rm -rf ${workdir}/src
		fi
	fi

	# Clone fresh copy
	echo "Cloning LTP version $ltp_version..."
	mkdir -p $(dirname ${workdir}/src)
	if git clone --recurse-submodules --branch $ltp_version https://github.com/linux-test-project/ltp.git ${workdir}/src; then
		echo "Successfully cloned LTP version $ltp_version"
	else
		die "Failed to clone LTP"
	fi

}

build() {
    cd ${workdir}/src
    make autotools
    # install LTP inside /opt/ltp by default
    ./configure --prefix=${workdir}/bin
    make -j $(nproc)
}

install() {
	cd ${workdir}/src
	make install
}

run_tests() {
	cd ${workdir}/bin
	./kirk -U ltp:root=${workdir}/bin -f syscalls
}

check_requirements
fetch_sources
build
install
run_tests
