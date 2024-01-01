#!/bin/sh
# Build Linux-From-Scratch
# Bootloader: grub
# Kernel: Ubuntu real-time
# Userland: Busybox
# Todo: ZFS and docker

# Host used to build: Linux Ubuntu 22.04 LTS
#

set -eux

lfs_dir="${HOME}/lfs"
src_dir="${lfs_dir}/src"
nproc=$(nproc)
# Software version
# The original goal was to use only git repository, but the firt step by building
# grub was a failurue:
# grub 2.12 problem:
# git branch (2.12 or 2.06) doesn't contains same files like (missing configure) and
# as the tar.gz and no instruction of how to build the exact same configure script as in
# the archive.
# Then configure in the 2.12 requiere automake 1.15 only (no less, no more)
# So, us the older 2.06 branch
grub_url="ftp://ftp.gnu.org/gnu/grub/grub-2.06.tar.gz"
grub_dir="grub-2.06"
#grub_git="https://git.savannah.gnu.org/git/grub.git"

die() {
	echo "FATAL: $1"
	exit 1
}

fetch_extract() {
	url=$1
	dir=$2
	filename=$(basename $url)
	if ! [ -r ${src_dir}/${filename} ]; then
		curl --output-dir ${src_dir} -LO $url
	fi
	if ! [ -d ${src_dir}/$dir ]; then
		tar -C ${src_dir} -xf ${src_dir}/${filename}
	fi
}

git_clone() {
	# $1 ver
	# $2 url
	repo=$(echo $2 | awk -F/ '{print $NF}' | sed 's/.git$//')
	if ! [ -d ${src_dir}/${repo} ]; then
		cd ${src_dir}
		git clone --depth 1 --branch $1 $2
	fi
}

host_ver_check() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter02/hostreqs.html
	if ! type -p $2 &>/dev/null; then
		echo "ERROR: Cannot find $2 ($1)"
		return 1
	fi
	v=$($2 --version 2>&1 | grep -E -o '[0-9]+\.[0-9\.]+[a-z]*' | head -n1)
	if printf '%s\n' $3 $v | sort --version-sort --check &>/dev/null; then
		printf "OK:    %-9s %-6s >= $3\n" "$1" "$v"; return 0;
	else
		printf "ERROR: %-9s is TOO OLD ($3 or later required)\n" "$1"
		return 1
	fi
}

host_syscheck() {
	echo "XXX need git, gcc, etc."
	# git used to download sources
	# To build grub, host needs as minimal version:
   	#	gcc 5.1
	#	GNU binutils 2.9.1.0.23
	#	autoconf 2.59 (2.64 for gnulib)
	#	automake 1.111
	#	bison 2.3
	#	flex 2.5.35
	host_ver_check Curl			curl		7.0
	host_ver_check Tar			tar			1.0
	host_ver_check GCC			gcc			5.1
	host_ver_check Git		 	git			1.0
	host_ver_check Binutils 	ld			2.13.1
	host_ver_check Bison		bison		2.7
	host_ver_check Flex			flex		2.5.35
	host_ver_check Make			make		4.0
	host_ver_check autoconf		autoconf	2.59
	host_ver_check automake		automake	1.9
}

build_deps_install() {
	echo "Installing build dependencies on host..."
	mkdir -p ${src_dir}
	#sudo apt-get install build-essential autoconf automake libtool bison
}

fetch_sources() {
	fetch_sources_grub
}

fetch_sources_grub() {
	#git_clone ${gnulib_ver} ${gnulib_src}
	#git_clone ${grub_ver} ${grub_src}
	fetch_extract ${grub_url} ${grub_dir}
}

grub_build() {
	# https://www.linuxfromscratch.org/blfs/view/12.0/postlfs/grub-efi.html
	# https://github.com/jfdelnero/LinuxFromScratch/blob/master/scripts/bs_misc.sh
	if [ -r ${src_dir}/grub/grub-install ]; then
		echo "Already builded"
		return 0
	fi
	echo "Building grub..."
	cd ${src_dir}/${grub_dir}
	./configure --prefix=/usr	\
            --sysconfdir=/etc	\
            --disable-efiemu	\
            --with-platform=efi	\
            --target=x86_64		\
			--disable-nls		\
            --disable-werror
	make -j ${nproc} | tee ${lfs_dir}/grub_build.log
}

disk_image_create() {
	echo "XXX: create disk image"
}

grub_install() {
	echo "XXX: install grub"
	#grub-install --target=x86_64-efi --removable
}

#### Main ####

host_syscheck
build_deps_install
fetch_sources
grub_build
disk_image_create
grub_install
