#!/bin/env bash
# Build Linux-From-Scratch
# stable: https://www.linuxfromscratch.org/
# devel: https://www.linuxfromscratch.org/lfs/view/development/
# SystemD: https://www.linuxfromscratch.org/lfs/view/systemd/
# Todo: Need to add ZFS (initramfs) and docker

# To download the manuals for offline reading:
# mkdir lfs_devel
# cd lfs_devel
# wget --span-hosts --recursive --relative --no-parent --no-host-directories https://www.linuxfromscratch.org/lfs/view/development/

# Tested on: Linux Ubuntu 22.04 LTS
# Need to test on minimized install
#
#LIBC="glibc | musl"
#CC="gcc | clang"

set -eux

# Small modification with the LFS book
# LFS is still the rootfs directory, but it will not be used to store sources and obj directory (waste of space)
LFS=${LFS:="${HOME}/lfs"}
src="${LFS}/sources"
logs="${HOME}/lfs.log"

#curl_cmd_src="curl --output-dir ${LFS}/sources -LO"

# Default env var
# https://www.linuxfromscratch.org/lfs/view/stable/chapter04/settingenvironment.html
umask 022
LC_ALL=POSIX
LFS_TGT=$(uname -m)-lfs-linux-gnu
# aarch64-lfs-linux-gnu
PATH=/usr/bin
if [ ! -L /bin ]; then
	# If /bin is not a symbolic link, it must be added to the PATH variable.
	PATH=/bin:$PATH
fi
# Ensure $LFS/tools/bin is called first, to force cross-compiler to be used over the system's one
PATH=$LFS/tools/bin:$PATH
#  Override it to prevent potential contamination from the host.
CONFIG_SITE=$LFS/usr/share/config.site
#export LFS LC_ALL LFS_TGT PATH CONFIG_SITE

# In order to factorize build function, let's try to pass custom configure arguments
CONF_ARGS=""
CONF_ENV=""

nproc=$(nproc)
# glibc: smallest version of the Linux kernel the generated library is expected to support. The higher the version number is, the less compatibility code is added, and the faster the code gets.
## Sources Tools chain and all packages

die() {
	echo "FATAL: $1"
	exit 1
}

extract_file() {
	local name=$1
	n=$(find ${LFS}/sources -maxdepth 1 -type f -regex ".*/${name}.*tar.*" | wc -l)
	if [ "$n" -gt 1 ]; then
		die "Multiples matchs regarding source archive name for ${name}"
	elif [ "$n" -eq 0 ]; then
		die "Did not find ${name} file"
	fi
	file=$(find ${LFS}/sources -maxdepth 1 -type f -regex ".*/${name}.*tar.*")
	tar -C ${LFS}/sources -xf ${file}
}

get_source_dir() {
	name=$1
	n=$(find ${LFS}/sources -maxdepth 1 -type d -regex  ".*/${name}.*" | wc -l)
	if [ "$n" -gt 1 ]; then
		die "Multipe matchs regarding source directory for ${name}"
	elif [ "$n" -eq 0 ]; then
		extract_file ${name}
	fi
	dir=$(find ${LFS}/sources -maxdepth 1 -type d -regex ".*/${name}.*")
	echo $dir
}

fetch_extract() {
	die "NO MORE USED"
	url=$1
	filename=$(basename $url)
	if ! [ -r ${LFS}/sources/${filename} ]; then
		${curl_cmd_src} $url
	fi
	dirname=$(get_dir_tar ${url})
	if ! [ -d ${src}/${dirname} ]; then
		tar -C ${LFS}/sources -xf ${LFS}/sources/${filename}
	fi
}

git_clone() {
	die "NO MORE USED"
	# $1 ver
	# $2 url
	repo=$(echo $2 | awk -F/ '{print $NF}' | sed 's/.git$//')
	if ! [ -d ${src}/${repo} ]; then
		cd ${src}
		git clone --depth 1 --branch $1 $2
	fi
}

# Chapter 2
host_ver_check() {
	echo "DEBUG 1: $1 and 2: $2"
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter02/hostreqs.html
	# 'type -p' is a bash-only built-in
	if ! type -p $2 &>/dev/null ; then
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

host_ver_kernel() {
   	# https://www.linuxfromscratch.org/lfs/view/stable/chapter02/hostreqs.html
	# XXX NOT USED
	kver=$(uname -r | grep -E -o '^[0-9\.]+')
	if printf '%s\n' $1 $kver | sort --version-sort --check &>/dev/null; then
		printf "OK:    Linux Kernel $kver >= $1\n"; return 0;
	else
		printf "ERROR: Linux Kernel ($kver) is TOO OLD ($1 or later required)\n" "$kver";
		return 1;
	fi
}

host_syscheck() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter02/hostreqs.html

	echo "XXXX need to check sudo is working"
	echo "Checking if host system have tools to download and compile gcc"
	echo "XXX need git, gcc, etc."
	grep --version > /dev/null 2> /dev/null || die "grep does not work"
	sed '' /dev/null || die "sed does not work"
	sort   /dev/null || die "sort does not work"

	# Coreutils first because-sort needs Coreutils >= 8.1
	host_ver_check Coreutils	sort	8.1 || die "Coreutils too old, stop"
	host_ver_check Bash           bash     3.2
	host_ver_check Binutils       ld       2.13.1
	host_ver_check Bison          bison    2.7
	host_ver_check Diffutils      diff     2.8.1
	host_ver_check Findutils      find     4.2.31
	host_ver_check Gawk           gawk     4.0.1
	host_ver_check GCC            gcc      5.2
	host_ver_check "GCC (C++)"    g++      5.2
	host_ver_check Grep           grep     2.5.1a
	host_ver_check Gzip           gzip     1.3.12
	host_ver_check M4             m4       1.4.10
	host_ver_check Make           make     4.0
	host_ver_check Patch          patch    2.5.4
	host_ver_check Perl           perl     5.8.8
	host_ver_check Python         python3  3.4
	host_ver_check Sed            sed      4.1.5
	host_ver_check Tar            tar      1.22
	host_ver_check Texinfo        texi2any 5.0
	host_ver_check Xz             xz       5.0.0
	host_ver_check Wget           wget     1.0
	#host_ver_kernel ${linux_min_ver}

	if mount | grep -q 'devpts on /dev/pts' && [ -e /dev/ptmx ]; then
		echo "OK:    Linux Kernel supports UNIX 98 PTY"
	else
		echo "ERROR: Linux Kernel does NOT support UNIX 98 PTY"
	fi

	alias_check() {
		if $1 --version 2>&1 | grep -qi $2; then
			printf "OK:    %-4s is $2\n" "$1"
		else
			printf "ERROR: %-4s is NOT $2\n" "$1"
		fi
	}
	echo "Aliases:"
	alias_check awk GNU
	alias_check yacc Bison
	alias_check sh Bash

	echo "Compiler check:"
	if printf "int main(){}" | g++ -x c++ -; then
		echo "OK:    g++ works";
	else
		echo "ERROR: g++ does NOT work"
	fi
	rm -f a.out
}

# Chapter 3
host_build_deps_install() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter03/introduction.html
	echo "XXX Installing build dependencies on host..."
	#echo "sudo apt-get install build-essential autoconf automake libtool bison texinfo"
	echo "sudo apt-get install build-essential autoconf automake bison texinfo"
}

fetch_sources() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter03/introduction.html
	# Sticky mode: only the owner of a file can delete the file within a sticky directory
	chmod a+wt $LFS/sources
	echo "Fetching all sources files (about 500M)..."
	if [ ! -f $LFS/sources/wget-list ]; then
		wget --no-verbose --directory-prefix=$LFS/sources https://www.linuxfromscratch.org/lfs/view/development/wget-list-sysv
		mv $LFS/sources/wget-list-sysv $LFS/sources/wget-list
		wget --no-verbose --input-file=$LFS/sources/wget-list --continue --directory-prefix=$LFS/sources
	fi
	# Force known UID for this owner on $LFS filesystem
	# sudo chown root:root $LFS/sources/*
}

version_extract() {
	local name=$1
	local ver
	ver=$(find ${src} -maxdepth 1 -type f -regex ".*${name}.*xz" | cut -d '-' -f 2 | sed 's/.tar.xz//')
	if [ -z "${ver}" ]; then
		die "Couldn't extract version number for ${name}"
	else
		echo ${ver}
	fi
}

versions_set() {
	# From the list of downloaded archive sources, extract version number required to be passed as parameters later
	gcc_ver=$(version_extract gcc)
	glibc_ver=$(version_extract glibc)
	# Minimum Linux version to instruct glibc to be compliant with
	linux_min_ver=4.14
}

# chapter 5
cct_binutils_pass1() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter05/binutils-pass1.html
	# It is important that Binutils be the first package compiled because both
	# Glibc and GCC perform various tests on the available linker and assembler to
   	# determine which of their own features to enable.
	if [ ! -f $LFS/tools/${LFS_TGT}/bin/objdump ]; then
		echo "[Toolchain] Building and installing binutitls..."
		srcdir=$(get_source_dir binutils)
		cd ${srcdir}
		mkdir -p build_pass1
		cd build_pass1
		../configure --prefix=$LFS/tools \
			--with-sysroot=$LFS \
			--target=$LFS_TGT   \
			--disable-nls       \
			--enable-gprofng=no \
			--disable-werror > ${logs}/cct_binutils_pass1.log
		make -j ${nproc} >> ${logs}/cct_binutils_pass1.log
		make -j ${nproc} install >> ${logs}/cct_binutils_pass1.log
	fi
}

cct_gcc_pass1() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter05/gcc-pass1.html
	if [ ! -f $LFS/tools/bin/${LFS_TGT}-gcc ]; then
		echo "[Toolchain] Building and installing gcc (pass1)..."
		srcdir=$(get_source_dir gcc)
		cd ${srcdir}
		# Need to copy mpfr, gmp and mpc sources into gcc
		# XXX We don't move them, to avoid to extract it again
		if [ ! -d mpfr ]; then
			mpfr_dir=$(get_source_dir mpfr)
			cp -r ${mpfr_dir} mpfr
		fi
		if [ ! -d gmp ]; then
			gmp_dir=$(get_source_dir gmp)
			cp -r ${gmp_dir} gmp
		fi
		if [ ! -d mpc ]; then
			mpc_dir=$(get_source_dir mpc)
			cp -r ${mpc_dir} mpc
		fi
		# On x86_64 hosts, set the default directory name for 64-bit libraries to "lib"
		# XXX Did the same for aarch64
		case $(uname -m) in
		x86_64)
			sed -e '/m64=/s/lib64/lib/' \
				-i.orig gcc/config/i386/t-linux64
			;;
		aarch64)
			sed -e '/lp64=/s/lib64/lib/' \
				-i.orig gcc/config/aarch64/t-aarch64-linux
		esac
		mkdir -p build_pass1
		cd build_pass1
		../configure                  \
			--target=$LFS_TGT         \
			--prefix=$LFS/tools       \
			--with-glibc-version=${glibc_ver} \
			--with-sysroot=$LFS       \
			--with-newlib             \
			--without-headers         \
			--enable-default-pie      \
			--enable-default-ssp      \
			--disable-nls             \
			--disable-shared          \
			--disable-multilib        \
			--disable-threads         \
			--disable-libatomic       \
			--disable-libgomp         \
			--disable-libquadmath     \
			--disable-libssp          \
			--disable-libvtv          \
			--disable-libstdcxx       \
			--enable-languages=c,c++ > ${logs}/cct_gcc_pass1.log
		make -j ${nproc} >> ${logs}/cct_gcc_pass1.log
		make -j ${nproc} install >> ${logs}/cct_gcc_pass1.log
		# Generate full version of header limits.h (will be needed later)
		cd ..
		cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
		`dirname $($LFS_TGT-gcc -print-libgcc-file-name)`/include/limits.h
	fi
}

cct_linux_api_headers() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter05/linux-headers.html
	if [ ! -d $LFS/usr/include ]; then
		echo "[Toolchain] Building and installing linux API headers..."
		srcdir=$(get_source_dir '/linux')
		cd ${srcdir}
		# Make sure there are no stale files embedded in the package
		make -j ${nproc} mrproper > ${logs}/cct_linux_api_headers.log
		# Extract the user-visible kernel headers from the source
		make -j ${nproc} headers >> ${logs}/cct_linux_api_headers.log
		find usr/include -type f ! -name '*.h' -delete
		cp -r usr/include $LFS/usr
	fi
}

cct_glibc() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter05/glibc.html
	if [ ! -f ${LFS}/usr/lib/libc.so  ]; then
		echo "[Toolchain] Building and installing glibc..."
		srcdir=$(get_source_dir glibc)
		cd ${srcdir}
		case $(uname -m) in
			i?86)		ln -sfv ld-linux.so.2 $LFS/lib/ld-lsb.so.3
						;;
			 x86_64)	ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64
						ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64/ld-lsb-x86-64.so.3
						;;
		esac
		if ! grep -q '/var/lib/nss_db' nss/db-Makefile;	then
			patch -Np1 -i ../glibc-${glibc_ver}-fhs-1.patch
		fi
		mkdir -p cct_build
		cd cct_build
		echo "rootsbindir=/usr/sbin" > configparms
		# https://www.gnu.org/software/autoconf/manual/autoconf-2.69/html_node/Hosts-and-Cross_002dCompilation.html
		../configure                         \
			--prefix=/usr                      \
		 	--host=$LFS_TGT                    \
		 	--build=$(../scripts/config.guess) \
		 	--enable-kernel=${linux_min_ver}               \
		 	--with-headers=$LFS/usr/include    \
		 	libc_cv_slibdir=/usr/lib > {logs}/cct_glibc.log
		make -j ${nproc} >> ${logs}/cct_glibc.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/cct_glibc.log
		sed '/RTLDLIST=/s@/usr@@g' -i $LFS/usr/bin/ldd
		echo "Testing glibc install:"
		echo 'int main(){}' | $LFS_TGT-gcc -xc -
		readelf -l a.out | grep ld-linux
		rm a.out
	fi
}

cct_libstdcpp() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter05/gcc-libstdc++.html
	if [ ! -d ${LFS}/tools/${LFS_TGT}/include/c++ ]; then
		echo "[Toolchain] Building and installing libstdc++..."
		srcdir=$(get_source_dir gcc)
		cd ${srcdir}/
		mkdir -p build_libstdcpp
		cd build_libstdcpp
		# The C++ compiler will prepend the sysroot path $LFS (specified when building GCC-pass1)
		../libstdc++-v3/configure           \
			--host=$LFS_TGT                 \
			--build=$(../config.guess)      \
			--prefix=/usr                   \
			--disable-multilib              \
			--disable-nls                   \
			--disable-libstdcxx-pch         \
			--with-gxx-include-dir=/tools/$LFS_TGT/include/c++/${gcc_ver} > ${logs}/cct_libstdpp.log
		make -j ${nproc} >> ${logs}/cct_libstdpp.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/cct_libstdpp.log
		rm $LFS/usr/lib/lib{stdc++,stdc++fs,supc++}.la
	fi
}

toolchain_build() {
	# https://www.linuxfromscratch.org/lfs/view/stable/partintro/toolchaintechnotes.html

	# Stage	Build	Host	Target	Action
	# 1		pc		pc		lfs		Build cross-compiler cc1 using cc-pc on pc.
	# 2		pc		lfs		lfs		Build compiler cc-lfs using cc1 on pc.
	# 3		lfs		lfs		lfs		Rebuild and test cc-lfs using cc-lfs on lfs.

	# pc: is the host default-cc

	# Stage 1:  building a cross compiler and its associated libraries

	# echo "Host:"
	# XXX need to check all binaries installed first
	# Displaying host triplet
	# gcc -dumpmachine
	# echo "ld:"
	# readelf -l /bin/bash | grep interpreter
	#[Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]
	# How to know if already installed bin is a temp|stage1 or a final stage3?
	# reatelf -a:
	# Section headers name? .hash vs .gnu.hash
	# Segments section ? .note.gnu
	# Dynamic section ? Flags: PIE
	# Version symbols section '.gnu.version' contains 125
	# Displaying notes found in: .note.gnu.build-id
	# OS: Linux, ABI: 3.7.0  vs ABI: 4.14.0
	cct_binutils_pass1
	# Build limited gcc (no Libstdc++ support, because no glibc)
	cct_gcc_pass1
	cct_linux_api_headers
	cct_glibc
	cct_libstdcpp
}

# chapter 6

cc_temp_ncurse() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter06/ncurses.html
	if [ ! -f $LFS/lib/libncurses.so ]; then
		echo "Building and installing ncurse..."
		srcdir=$(get_source_dir ncurse)
		cd ${srcdir}
		sed -i s/mawk// configure
		mkdir -p build
		cd build
		# tic build on host
		../configure > ${logs}/cc_temp_ncurse.log
		make -j ${nproc} -C include >> ${logs}/cc_temp_ncurse.log
		make -j ${nproc} -C progs tic >> ${logs}/cc_temp_ncurse.log
		cd ..
		./configure --prefix=/usr                \
			--host=$LFS_TGT              \
			--build=$(./config.guess)    \
			--mandir=/usr/share/man      \
			--with-manpage-format=normal \
			--with-shared                \
			--without-normal             \
			--with-cxx-shared            \
			--without-debug              \
			--without-ada                \
			--disable-stripping          \
			--enable-widec >> ${logs}/cc_temp_ncurse.log
		make -j ${nproc} >> ${logs}/cc_temp_ncurse.log
		# need to pass the path of the newly built tic that runs on the building machine,
		# so the terminal database can be created without errors.
		make -j ${nproc} DESTDIR=$LFS TIC_PATH=$(pwd)/build/progs/tic install >> ${logs}/cc_temp_ncurse.log
		# The libncurses.so library is needed by a few packages we will build soon. We create this small linker script
		echo "INPUT(-lncursesw)" > $LFS/usr/lib/libncurses.so
	fi
}

cc_temp_bash() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter06/bash.html
	if [ ! -f $LFS/usr/bin/bash ]; then
		echo "Building and installing bash..."
		srcdir=$(get_source_dir bash)
		cd ${srcdir}
		# turns off the use of Bash's memory allocation (malloc) function which is known to cause segmentation faults.
		# By turning this option off, Bash will use the malloc functions from Glibc which are more stable.
		./configure --prefix=/usr                      \
			--build=$(sh support/config.guess) \
			--host=$LFS_TGT                    \
			--without-bash-malloc > ${logs}/cc_temp_bash.log
		make -j ${nproc} >> ${logs}/cc_temp_bash.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/cc_temp_bash.log
		# Make a link for the programs that use sh for a shell
		ln -s bash $LFS/bin/sh
	fi
}

cc_temp_coreutils() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter06/coreutils.html
	if [ ! -f $LFS/usr/bin/hostname ]; then
		echo "Building and installing coreutils..."
		srcdir=$(get_source_dir coreutils)
		cd ${srcdir}
		#  enables the hostname binary to be built and installed – it is disabled by default but is required by the Perl test suite.
		./configure --prefix=/usr                     \
			--host=$LFS_TGT                   \
			--build=$(build-aux/config.guess) \
			--enable-install-program=hostname \
			--enable-no-install-program=kill,uptime > ${logs}/cc_temp_coreutils.log
		make -j ${nproc} >> ${logs}/cc_temp_coreutils.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/cc_temp_coreutils.log
		# Move programs to their final expected locations.
		# Although this is not necessary in this temporary environment, we must do so because some programs hardcode executable locations
		mv $LFS/usr/bin/chroot $LFS/usr/sbin
		mkdir -v $LFS/usr/share/man/man8
		mv $LFS/usr/share/man/man1/chroot.1 $LFS/usr/share/man/man8/chroot.8
		sed -i 's/"1"/"8"/' $LFS/usr/share/man/man8/chroot.8
	fi
}

cc_temp_diffutils() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter06/diffutils.html
	if [ ! -f $LFS/usr/bin/cmp ]; then
		echo "Building and installing diffutils..."
		srcdir=$(get_source_dir diffutils)
		cd ${srcdir}
		./configure --prefix=/usr   \
			--host=$LFS_TGT \
			--build=$(./build-aux/config.guess) > ${logs}/cc_temp_diffutils.log
		make -j ${nproc} >> ${logs}/cc_temp_diffutils.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/cc_temp_diffutils.log
	fi
}

cc_temp_file() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter06/file.html
	if [ ! -f $LFS/usr/bin/file ]; then
		echo "Building and installing file..."
		srcdir=$(get_source_dir file)
		cd ${srcdir}

		# The file command on the build host needs to be the same version as the one we are building
		# in order to create the signature file. Run the following commands to make a temporary copy of the file command:
		mkdir build
		cd build
		# The configuration script attempts to use some packages from the host distribution
		# if the corresponding library files exist. It may cause compilation failure if a library file exists,
		# but the corresponding header files do not. These options prevent using these unneeded capabilities from the host.
		../configure --disable-bzlib      \
			--disable-libseccomp \
			--disable-xzlib      \
			--disable-zlib > ${logs}/cc_temp_file.log
		make -j ${nproc} >> ${logs}/cc_temp_file.log
		cd ..
		./configure --prefix=/usr --host=$LFS_TGT --build=$(./config.guess) >> ${logs}/cc_temp_file.log
		make FILE_COMPILE=$(pwd)/build/src/file >> ${logs}/cc_temp_file.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/cc_temp_file.log
		# Remove the libtool archive file because it is harmful for cross compilation:
		rm $LFS/usr/lib/libmagic.la
	fi
}

cc_temp_findutils() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter06/findutils.html
	if [ ! -f $LFS/usr/bin/find ]; then
		echo "Building and installing findutils..."
		srcdir=$(get_source_dir find)
		cd ${srcdir}
		./configure --prefix=/usr                   \
			--localstatedir=/var/lib/locate \
			--host=$LFS_TGT                 \
			--build=$(build-aux/config.guess) > ${logs}/cc_temp_findutils.log
		make -j ${nproc} >> ${logs}/cc_temp_findutils.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/cc_temp_findutils.log
	fi
}

cc_temp_gawk() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter06/gawk.html
	if [ ! -f $LFS/usr/bin/gawk ]; then
		echo "Building and installing gawk..."
		srcdir=$(get_source_dir gawk)
		cd ${srcdir}
		# First, ensure some unneeded files are not installed:
		sed -i 's/extras//' Makefile.in
		./configure --prefix=/usr   \
			--host=$LFS_TGT \
			--build=$(build-aux/config.guess) > ${logs}/cc_temp_gawk.log
		make -j ${nproc} >> ${logs}/cc_temp_gawk.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/cc_temp_gawk.log
	fi
}

cc_temp_gzip() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter06/gzip.html
	if [ ! -f $LFS/usr/bin/gzip ]; then
		echo "Building and installing gzip..."
		srcdir=$(get_source_dir gzip)
		cd ${srcdir}
		./configure --prefix=/usr   \
			--host=$LFS_TGT > ${logs}/cc_temp_gzip.log
		make -j ${nproc} >> ${logs}/cc_temp_gzip.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/cc_temp_gzip.log
	fi
}

cc_temp_make() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter06/make.html
	if [ ! -f $LFS/usr/bin/make ]; then
		echo "Building and installing make..."
		srcdir=$(get_source_dir /make)
		cd ${srcdir}
		# Although we are cross-compiling, configure tries to use guile from
		# the build host if it finds it. This makes compilation fail, so this switch prevents using it
		./configure --prefix=/usr   \
			--without-guile \
			--host=$LFS_TGT \
			--build=$(build-aux/config.guess) > ${logs}/cc_temp_make.log
		make -j ${nproc} >> ${LFS}/cc_temp_make.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/cc_temp_make.log
	fi
}

cc_temp_build() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter06/*.html
	# Generic version
	name=$1
	if [ ! -f $LFS/usr/bin/${name} ]; then
		echo "Building and installing ${name}..."
		srcdir=$(get_source_dir ${name})
		cd ${srcdir}
		./configure --prefix=/usr   \
			--host=$LFS_TGT \
			--build=$(build-aux/config.guess) > ${logs}/cc_temp_${name}.log
		make -j ${nproc} >> ${logs}/cc_temp_${name}.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/cc_temp_${name}.log
	fi
}

cc_temp_xz() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter06/xz.html
	if [ ! -f $LFS/usr/bin/xz ]; then
		echo "Building and installing xz..."
		srcdir=$(get_source_dir xz)
		cd ${srcdir}
		./configure --prefix=/usr   \
			--host=$LFS_TGT \
			--disable-static                  \
			--docdir=/usr/share/doc/xz-5.4.5 \
			--build=$(build-aux/config.guess) > ${logs}/cc_temp_xz.log
		make -j ${nproc} >> ${logs}/cc_temp_xz.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/cc_temp_xz.log
		# Remove the libtool archive file because it is harmful for cross compilation:
		rm -v $LFS/usr/lib/liblzma.la
	fi
}

cc_temp_binutils() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter06/binutils-pass2.html
	if [ ! -d $LFS/usr/${LFS_TGT}/lib/ldscripts ]; then
		echo "Building and installing binutils (pass2)..."
		srcdir=$(get_source_dir binutils)
		cd ${srcdir}
		mkdir build_pass2
		cd build_pass2
		../configure                   \
	    	--prefix=/usr              \
			--build=$(../config.guess) \
		    --host=$LFS_TGT            \
	  		--disable-nls              \
	  		--enable-shared            \
		    --enable-gprofng=no        \
		    --disable-werror           \
    		--enable-64-bit-bfd        \
    		--enable-default-hash-style=gnu > ${logs}/cc_temp_binutils_pass2.log
		make -j ${nproc} >> ${logs}/cc_temp_binutils_pass2.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/cc_temp_binutils_pass2.log
		# Remove the libtool archive files because they are harmful for cross compilation, and remove unnecessary static libraries:
		rm $LFS/usr/lib/lib{bfd,ctf,ctf-nobfd,opcodes,sframe}.{a,la}
	fi
}

cc_temp_gcc() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter06/gcc-pass2.html
	if [ ! -f $LFS/usr/bin/gcc ]; then
		echo "Building and installing gcc (pass2)..."
		srcdir=$(get_source_dir gcc)
		cd ${srcdir}
		# Need to copy mpfr, gmp and mpc sources into gcc
		# XXX We don't move them, to avoid to extract it again
		if [ ! -d mpfr ]; then
			mpfr_dir=$(get_source_dir mpfr)
			cp -r ${mpfr_dir} mpfr
		fi
		if [ ! -d gmp ]; then
			gmp_dir=$(get_source_dir gmp)
			cp -r ${gmp_dir} gmp
		fi
		if [ ! -d mpc ]; then
			mpc_dir=$(get_source_dir mpc)
			cp -r ${mpc_dir} mpc
		fi
		# On x86_64 hosts, set the default directory name for 64-bit libraries to “lib”
		# XXX Did the same for aarch64
		case $(uname -m) in
		x86_64)
			sed -e '/m64=/s/lib64/lib/' \
				-i.orig gcc/config/i386/t-linux64
			;;
		aarch64)
			sed -e '/lp64=/s/lib64/lib/' \
				-i.orig gcc/config/aarch64/t-aarch64-linux
		esac
		# Override the building rule of libgcc and libstdc++ headers, to allow building
	   	# these libraries with POSIX threads support:
		sed '/thread_header =/s/@.*@/gthr-posix.h/' \
			-i libgcc/Makefile.in libstdc++-v3/include/Makefile.in
		mkdir -p build_pass2
		cd build_pass2
		../configure                  \
			--build=$(../config.guess)  \
			--host=$LFS_TGT			\
			--target=$LFS_TGT         \
			LDFLAGS_FOR_TARGET=-L$PWD/$LFS_TGT/libgcc	\
			--prefix=/usr			\
			--with-build-sysroot=$LFS \
			--enable-default-pie      \
			--enable-default-ssp      \
			--disable-nls             \
			--disable-multilib        \
			--disable-libatomic       \
			--disable-libgomp         \
			--disable-libquadmath     \
			--disable-libsanitizer	\
			--disable-libssp          \
			--disable-libvtv          \
			--enable-languages=c,c++ > ${logs}/cc_temp_gcc_pass2.log
		make -j ${nproc} >> ${logs}/cc_temp_gcc_pass2.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/cc_temp_gcc_pass2.log
		ln -sv gcc $LFS/usr/bin/cc
	fi
}

cross_compil_temp_tools() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter06/introduction.html

	# stage 2 using cross toolchain builded at stage 1 to build several utilities
	# in a way that isolates them from the host distribution

	cc_temp_build m4
	cc_temp_ncurse
	cc_temp_bash
	cc_temp_coreutils
	cc_temp_diffutils
	cc_temp_file
	cc_temp_findutils
	cc_temp_gawk
	cc_temp_build grep
	cc_temp_gzip
	cc_temp_make
	cc_temp_build patch
	cc_temp_build sed
	cc_temp_build tar
	cc_temp_xz
 	cc_temp_binutils
	cc_temp_gcc

}

grub_build() {
	# https://www.linuxfromscratch.org/blfs/view/12.0/postlfs/grub-efi.html
	# https://github.com/jfdelnero/LinuxFromScratch/blob/master/scripts/bs_misc.sh
	if [ -r ${src}/grub/grub-install ]; then
		echo "Already builded"
		return 0
	fi
	echo "Building grub..."
	cd ${src}/${grub_dir}
	./configure --prefix=/usr	\
            --sysconfdir=/etc	\
            --disable-efiemu	\
            --with-platform=efi	\
            --target=x86_64		\
			--disable-nls		\
            --disable-werror
	make -j ${nproc} | tee ${LFS}/grub_build.log
}

disk_image_create() {
	echo "XXX: create disk image"
}

grub_install() {
	echo "XXX: install grub"
	#grub-install --target=x86_64-efi --removable
}

rootfs_populate() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter04/creatingminlayout.html
	mkdir -pv $LFS/{etc,var} $LFS/usr/{bin,lib,sbin}

	for i in bin lib sbin; do
		if ! [ -L $LFS/$i ]; then
			ln -sv usr/$i $LFS/$i
		fi
	done

	case $(uname -m) in
	  x86_64) mkdir -pv $LFS/lib64 ;;
	esac

	# cross-compiler
	mkdir -pv $LFS/tools
}

CR() {
	# Run in chroot
	sudo chroot "$LFS" /usr/bin/env -i   \
		HOME=/root                  \
		TERM="$TERM"                \
		PS1='(lfs chroot) \u:\w\$ ' \
		PATH=/usr/bin:/usr/sbin     \
		MAKEFLAGS="-j $nproc"      \
		TESTSUITEFLAGS="-j$nproc" \
		/bin/bash -xc "$*"
}

cc_temp_build_chroot_gettext() {
	# https://www.linuxfromscratch.org/lfs/view/development/chapter07/gettext.html

	# We do not need to install any of the shared Gettext libraries at this time, therefore there is no need to build them.
	if ! [ -f ${LFS}/usr/bin/xgettext ]; then
		src=$(get_source_dir gettext)
		src_rel=${src/#$LFS}
		cat << EOF | sudo tee ${LFS}/build.sh
#!/bin/bash
set -eux
cd ${src_rel}
./configure --disable-shared
make
cp -v gettext-tools/src/{msgfmt,msgmerge,xgettext} /usr/bin
EOF
		CR "bash ./build.sh" > ${logs}/cc_temp_chroot_gettext.log
	fi
}

cc_temp_build_chroot() {
	# https://www.linuxfromscratch.org/lfs/view/development/chapter07/*.html
	name=$1
	if ! [ -e ${LFS}/usr/bin/$name -o -e ${LFS}/usr/lib/$name -o -e ${LFS}/usr/share/$name ]; then
		src=$(get_source_dir $name)
		src_rel=${src/#$LFS}
		cat << EOF | sudo tee ${LFS}/build.sh
#!/bin/bash
set -eux
cd ${src_rel}
./configure --prefix=/usr
make
make install
EOF
		if [ "${name}" = "texinfo" ]; then
			# It seems texinfo doesn’t fully install, but not a problem
			sed -i 's/install/install | true/' ${LFS}/build.sh
		fi
		CR "bash ./build.sh" > ${logs}/cc_temp_chroot_$name.log 2>&1
	fi
}

cc_temp_build_chroot_perl() {
	# https://www.linuxfromscratch.org/lfs/view/development/chapter07/perl.html

	if ! [ -e ${LFS}/usr/bin/perl ]; then
		src=$(get_source_dir perl)
		src_rel=${src/#$LFS}
		cat << EOF | sudo tee ${LFS}/build.sh
#!/bin/bash
set -eux
cd ${src_rel}
sh Configure -des                                        \
             -Dprefix=/usr                               \
             -Dvendorprefix=/usr                         \
             -Duseshrplib                                \
             -Dprivlib=/usr/lib/perl5/5.38/core_perl     \
             -Darchlib=/usr/lib/perl5/5.38/core_perl     \
             -Dsitelib=/usr/lib/perl5/5.38/site_perl     \
             -Dsitearch=/usr/lib/perl5/5.38/site_perl    \
             -Dvendorlib=/usr/lib/perl5/5.38/vendor_perl \
             -Dvendorarch=/usr/lib/perl5/5.38/vendor_perl
make
make install
EOF
		CR "bash ./build.sh" > ${logs}/cc_temp_chroot_perl.log 2>&1
	fi
}

cc_temp_build_chroot_python() {
	# https://www.linuxfromscratch.org/lfs/view/development/chapter07/python.html

	if ! [ -e ${LFS}/usr/bin/python3 ]; then
		src=$(get_source_dir Python)
		src_rel=${src/#$LFS}
		cat << EOF | sudo tee ${LFS}/build.sh
#!/bin/bash
set -eux
cd ${src_rel}
./configure --prefix=/usr   \
            --enable-shared \
            --without-ensurepip
make
make install
EOF
		CR "bash ./build.sh" > ${logs}/cc_temp_chroot_python.log 2>&1
	fi
}
cc_temp_build_chroot_util-linux () {
	# https://www.linuxfromscratch.org/lfs/view/development/chapter07/util-linux.html
	if ! [ -e ${LFS}/usr/bin/mount ]; then
		src=$(get_source_dir util-linux)
		src_rel=${src/#$LFS}
		cat << EOF | sudo tee ${LFS}/build.sh
#!/bin/bash
set -eux
mkdir -p /var/lib/hwclock
cd ${src_rel}
./configure --libdir=/usr/lib	\
	--runstatedir=/run			\
	--disable-chfn-chsh			\
	--disable-login				\
	--disable-nologin			\
	--disable-su				\
	--disable-setpriv			\
	--disable-runuser			\
	--disable-pylibmount		\
	--disable-static			\
	--without-python			\
	ADJTIME_PATH=/var/lib/hwclock/adjtime \
	--docdir=/usr/share/doc/util-linux-2.39.3
make
make install
EOF
		CR "bash ./build.sh" > ${logs}/cc_temp_chroot_util-linux.log 2>&1
	fi


}

mount_vfs() {

	# Preparing Virtual Kernel File Systems
	if ! [ -d  ${LFS}/dev ]; then
		sudo mkdir -p ${LFS}/{dev,proc,sys,run}
	fi
	# host-agnostic way to populate the $LFS/dev directory is by bind
	# mounting the host system's /dev directory and not using devtmpfs
   	mountpoint -q ${LFS}/dev || sudo mount --bind /dev $LFS/dev
	mountpoint -q ${LFS}/dev/pts || sudo mount --bind /dev/pts $LFS/dev/pts
	mountpoint -q ${LFS}/proc || sudo mount -t proc proc $LFS/proc
	mountpoint -q ${LFS}/sys || sudo mount -t sysfs sysfs $LFS/sys
	mountpoint -q ${LFS}/run || sudo mount -t tmpfs tmpfs $LFS/run

	if [ -h $LFS/dev/shm ]; then
		(cd $LFS/dev; mkdir $(readlink shm))
	else
		sudo mount -t tmpfs -o nosuid,nodev tmpfs $LFS/dev/shm
	fi
}

umount_vfs() {
	# Umount VFS
	sudo mountpoint -q $LFS/dev/shm && sudo umount $LFS/dev/shm
	sudo umount $LFS/dev/pts
	sudo umount $LFS/{sys,proc,run,dev}
}

chroot_cc_temp_tools() {
	# https://www.linuxfromscratch.org/lfs/view/development/chapter07/introduction.html
	# Build the last missing bits of the temporary system:
	# the tools needed to build the various packages.
	# Now that all circular dependencies have been resolved, a “chroot” environment,
	# completely isolated from the host operating system (except for the running kernel),
   	# can be used for the build.

	# Stage 3: entering the chroot environment (which further improves host isolation) and constructing the remaining tools needed to build the final system

	#

	# https://www.linuxfromscratch.org/lfs/view/development/chapter07/changingowner.html
	sudo chown -R root:root $LFS/{usr,lib,var,etc,bin,sbin,tools}
	# XXX  But we instructed to use /lib in place of /lib64!?!?
	case $(uname -m) in
		x86_64) sudo chown -R root:root $LFS/lib64 ;;
	esac

	# https://www.linuxfromscratch.org/lfs/view/development/chapter07/kernfs.html
	mount_vfs

	# https://www.linuxfromscratch.org/lfs/view/development/chapter07/chroot.html
	# cf CR()

	# https://www.linuxfromscratch.org/lfs/view/development/chapter07/creatingdirs.html

	CR "mkdir -p /{boot,home,mnt,opt,srv}"
	CR "mkdir -p /etc/{opt,sysconfig}"
	CR "mkdir -p /lib/firmware"
	CR "mkdir -p /media/{floppy,cdrom}"
	CR "mkdir -p /usr/{,local/}{include,src}"
	CR "mkdir -p /usr/local/{bin,lib,sbin}"
	CR "mkdir -p /usr/{,local/}share/{color,dict,doc,info,locale,man}"
	CR "mkdir -p /usr/{,local/}share/{misc,terminfo,zoneinfo}"
	CR "mkdir -p /usr/{,local/}share/man/man{1..8}"
	CR "mkdir -p /var/{cache,local,log,mail,opt,spool}"
	CR "mkdir -p /var/lib/{color,misc,locate}"

	CR "ln -sf /run /var/run"
	CR "ln -sf /run/lock /var/lock"

	CR "install -d -m 0750 /root"
	CR "install -d -m 1777 /tmp /var/tmp"

	# https://www.linuxfromscratch.org/lfs/view/development/chapter07/createfiles.html

	CR "ln -fs /proc/self/mounts /etc/mtab"

	cat << EOF | sudo tee ${LFS}/etc/hosts
127.0.0.1  localhost $(hostname)
::1        localhost
EOF

	cat << "EOF" | sudo tee ${LFS}/etc/passwd
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOF

	cat << "EOF" | sudo tee ${LFS}/etc/group
root:x:0:
bin:x:1:daemon
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:
video:x:12:
utmp:x:13:
cdrom:x:15:
adm:x:16:
messagebus:x:18:
input:x:24:
mail:x:34:
kvm:x:61:
uuidd:x:80:
wheel:x:97:
users:x:999:
nogroup:x:65534:
EOF

	if ! grep -q tester ${LFS}/etc/passwd; then
		CR "echo 'tester:x:101:101::/home/tester:/bin/bash' >> /etc/passwd"
		CR "echo 'tester:x:101:' >> /etc/group"
		CR "install -o tester -d /home/tester"
	fi

	CR "touch /var/log/{btmp,lastlog,faillog,wtmp}"
	CR "chgrp -v utmp /var/log/lastlog"
	CR "chmod -v 664  /var/log/lastlog"
	CR "chmod -v 600  /var/log/btmp"

	cc_temp_build_chroot_gettext
	cc_temp_build_chroot bison
	cc_temp_build_chroot_perl
	cc_temp_build_chroot_python
	cc_temp_build_chroot texinfo
	cc_temp_build_chroot_util-linux

	# https://www.linuxfromscratch.org/lfs/view/development/chapter07/cleanup.html

	# Cleaning

	CR 'rm -rf /usr/share/{info,man,doc}/*'
	CR 'find /usr/{lib,libexec} -name \*.la -delete'
	CR 'rm -rf /tools'

	rm ${LFS}/build.sh

	# Backup
	if ! [ -f $HOME/lfs-temp-tools-r12.0-139.tar.xz ]; then
		umount_vfs
		cd $LFS
		tar -cJpf $HOME/lfs-temp-tools-r12.0-139.tar.xz .
	fi
}

host_add_user() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter04/addinguser.html
	echo "XXX Need to use $USER"
}

build_chroot() {
	# https://www.linuxfromscratch.org/lfs/view/development/chapter08/*.html
	name=$1
	file_already_installed=$2
	if [ -e ${LFS}${file_already_installed} ]; then
		return 0
	fi
	src=$(get_source_dir $name)
	src_rel=${src/#$LFS}
	cat << EOF | sudo tee ${LFS}/build.sh
#!/bin/bash
set -eux
cd ${src_rel}
if [ -x configure ]; then
	${CONF_ENV} ./configure --prefix=/usr ${CONF_ARGS}
fi
make
make install
EOF
	CR "bash ./build.sh" > ${logs}/build_chroot_$name.log 2>&1
}

install_chroot() {
	# https://www.linuxfromscratch.org/lfs/view/development/chapter08/*.html
	local name=$1
	local src=$(get_source_dir $name)
	local src_rel=${src/#$LFS}
	cat << EOF | sudo tee ${LFS}/build.sh
#!/bin/bash
set -eux
cd ${src_rel}
make prefix=/usr install
EOF
	CR "bash ./build.sh" > ${logs}/install_chroot_$name.log 2>&1
}

build_chroot_glibc() {
	# https://www.linuxfromscratch.org/lfs/view/development/chapter08/glibc.html
	if [ -e ${LFS}/usr/lib/libnss_files.so.2 ]; then
		return 0
	fi
	name=glibc
	src=$(get_source_dir $name)
	src_rel=${src/#$LFS}
	cd ${src}
	if patch --dry-run -Np1 -i ../glibc-${glibc_ver}-upstream_fixes-3.patch; then
		patch -Np1 -i ../glibc-${glibc_ver}-upstream_fixes-3.patch
	fi
	mkdir -p build
	cd build
	cat << EOF | sudo tee ${LFS}/build.sh
#!/bin/bash
set -eux
cd ${src_rel}/build
echo "rootsbindir=/usr/sbin" > configparms
../configure --prefix=/usr                            \
             --disable-werror                         \
             --enable-kernel=${linux_min_ver}          \
             --enable-stack-protector=strong          \
             --with-headers=/usr/include              \
             --disable-nscd                           \
             libc_cv_slibdir=/usr/lib
make
touch /etc/ld.so.conf
sed '/test-installation/s@\$(PERL)@echo not running@' -i ../Makefile
make install
sed '/RTLDLIST=/s@/usr@@g' -i /usr/bin/ldd
mkdir -pv /usr/lib/locale
localedef -i C -f UTF-8 C.UTF-8
localedef -i en_GB -f ISO-8859-1 en_GB
localedef -i en_GB -f UTF-8 en_GB.UTF-8
localedef -i en_US -f ISO-8859-1 en_US
localedef -i en_US -f UTF-8 en_US.UTF-8
EOF
	CR "bash ./build.sh" > ${logs}/build_chroot_$name.log 2>&1

	# Configuring Glibc
	cat << "EOF" | sudo tee ${LFS}/etc/nsswitch.conf
# Begin /etc/nsswitch.conf

passwd: files
group: files
shadow: files

hosts: files dns
networks: files

protocols: files
services: files
ethers: files
rpc: files

# End /etc/nsswitch.conf
EOF

	# Adding Time Zone Data
	# Will be to just afte as another package

	# Configuring the Dynamic Loader
	cat << "EOF" | sudo tee ${LFS}/etc/ld.so.conf
# Begin /etc/ld.so.conf
/usr/local/lib
/opt/lib
# Add an include directory
include /etc/ld.so.conf.d/\*.conf
EOF

	sudo mkdir -p ${LFS}/etc/ld.so.conf.d
}

build_chroot_tzdata() {
	# https://www.linuxfromscratch.org/lfs/view/development/chapter08/*.html
	if [ -d ${LFS}/usr/share/zoneinfo ]; then
		return 0
	fi
	name=tzdata
	src=$(get_source_dir $name)
	src_rel=${src/#$LFS}
	cat << "EOF" | sudo tee ${LFS}/build.sh
#!/bin/bash
set -eux
ZONEINFO=/usr/share/zoneinfo
mkdir -p \${ZONEINFO}/{posix,right}

for tz in etcetera southamerica northamerica europe africa antarctica  \
          asia australasia backward; do
    zic -L /dev/null   -d \${ZONEINFO}       \${tz}
    zic -L /dev/null   -d \${ZONEINFO}/posix \${tz}
    zic -L leapseconds -d \${ZONEINFO}/right \${tz}
done

cp zone.tab zone1970.tab iso3166.tab \${ZONEINFO}
zic -d \${ZONEINFO} -p America/New_York
EOF

	CR "bash ./build.sh" > ${logs}/build_chroot_$name.log 2>&1
}

build_chroot_bzip2() {
	# https://www.linuxfromscratch.org/lfs/view/development/chapter08/bzip2.html
	if [ -e ${LFS}/usr/bin/bzip2 ]; then
		return 0
	fi
	name=bzip2
	src=$(get_source_dir $name)
	src_rel=${src/#$LFS}
	cd ${src}
	if patch --dry-run -Np1 -i ../bzip2-1.0.8-install_docs-1.patch; then
		patch -Np1 -i ../bzip2-1.0.8-install_docs-1.patch
	fi
	sed -i 's@\(ln -s -f \)$(PREFIX)/bin/@\1@' Makefile
	sed -i "s@(PREFIX)/man@(PREFIX)/share/man@g" Makefile
	cat << EOF | sudo tee ${LFS}/build.sh
#!/bin/bash
set -eux
cd ${src_rel}
make -f Makefile-libbz2_so
make clean
make
make PREFIX=/usr install
cp -a libbz2.so.* /usr/lib
ln -s libbz2.so.1.0.8 /usr/lib/libbz2.so
cp bzip2-shared /usr/bin/bzip2
for i in /usr/bin/{bzcat,bunzip2}; do
  ln -sf bzip2 \$i
done
rm -fv /usr/lib/libbz2.a
EOF
	CR "bash ./build.sh" > ${logs}/build_chroot_$name.log 2>&1
}

build_chroot_zstd() {
	# https://www.linuxfromscratch.org/lfs/view/development/chapter08/zstd.html
	name=zstd
	file_already_installed=/usr/bin/zstd
	if [ -e ${LFS}${file_already_installed} ]; then
		return 0
	fi
	src=$(get_source_dir $name)
	src_rel=${src/#$LFS}
	cat << EOF | sudo tee ${LFS}/build.sh
#!/bin/bash
set -eux
cd ${src_rel}
make prefix=/usr
make prefix=/usr install
rm /usr/lib/libzstd.a
EOF
	CR "bash ./build.sh" > ${logs}/build_chroot_$name.log 2>&1
}

build_chroot_readline() {
	# https://www.linuxfromscratch.org/lfs/view/development/chapter08/readline.html
	name=readline
	file_already_installed=/usr/lib/libreadline.so
	if [ -e ${LFS}${file_already_installed} ]; then
		return 0
	fi
	src=$(get_source_dir $name)
	src_rel=${src/#$LFS}
	cat << EOF | sudo tee ${LFS}/build.sh
#!/bin/bash
set -eux
cd ${src_rel}
# Prevent the old libraries to be moved to <libraryname>.old
sed -i '/MV.*old/d' Makefile.in
sed -i '/{OLDSUFF}/c:' support/shlib-install
# fix a problem identified upstream
patch -Np1 -i ../readline-8.2-upstream_fixes-2.patch
./configure --prefix=/usr    \
            --disable-static \
            --with-curses    \
            --docdir=/usr/share/doc/readline-8.2
# forces Readline to link against the libncursesw library
make SHLIB_LIBS="-lncursesw"
make SHLIB_LIBS="-lncursesw" install
install -m644 doc/*.{ps,pdf,html,dvi} /usr/share/doc/readline-8.2
EOF
	CR "bash ./build.sh" > ${logs}/build_chroot_$name.log 2>&1
}

system_build() {
	# https://www.linuxfromscratch.org/lfs/view/development/part4.html
	# https://www.linuxfromscratch.org/lfs/view/development/chapter08/introduction.html

	mount_vfs

	# https://www.linuxfromscratch.org/lfs/view/development/chapter08/man-pages.html
	if ! [ -e ${LFS}/usr/share/man/man2/inl.2 ]; then
		rm -f ${LFS}/man3/crypt*
		install_chroot man-pages
	fi

	# https://www.linuxfromscratch.org/lfs/view/development/chapter08/iana-etc.html
	local src=$(get_source_dir iana-etc)
	sudo cp ${src}/services ${src}/protocols ${LFS}/etc

	# https://www.linuxfromscratch.org/lfs/view/development/chapter08/glibc.html

	build_chroot_glibc
	build_chroot_tzdata
	build_chroot zlib /usr/lib/libz.so
	sudo rm -f ${LFS}/usr/lib/libz.a

	build_chroot_bzip2

	# xz was already builded and install during "Cross Compiling Temporary Tools" step (with a specific --host)
	# The difference is tempo binary doesn't have '.hash' or (HASH) in its Segment section
	if ! readelf -l ${LFS}/usr/bin/xz | grep ' \.hash'; then
		CONF_ARGS="--disable-static --docdir=/usr/share/doc/xz-5.4.5"
		build_chroot xz /usr/bin/xz
		CONF_ARGS=""
	fi

	build_chroot_zstd /usr/bin/zstd

	# Here only the tempo binary has the .hash (XXX: opposite to xz????)
	if readelf -l ${LFS}/usr/bin/file | grep ' \.hash'; then
		build_chroot file /usr/bin/file
	fi

	build_chroot_readline

	build_chroot m4 /usr/bin/m4

	# https://www.linuxfromscratch.org/lfs/view/development/chapter08/bc.html
	CONF_ARGS="-G -O3 -r"
	CONF_ENV="CC=gcc"
	build_chroot bc /usr/bin/bc
	CONF_ARGS=""
	CONF_ENV=""

	# https://www.linuxfromscratch.org/lfs/view/development/chapter08/flex.html
	CONF_ARGS="--disable-static --docdir=/usr/share/doc/flex-2.6.4"
	build_chroot flex /usr/bin/flex
	CONF_ARGS=""
	if ! [ -L ${LFS}/usr/bin/lex ]; then
		ln -s flex ${LFS}/usr/bin/lex
		ln -s flex.1 ${LFS}/usr/share/man/man1/lex.1
	fi


	echo EXPECTED END
	exit 1

}
#### Main ####

# Building the LFS Cross Toolchain and Temporary Tools
# Building the LFS System
#  Installing Basic System Software
#  System Configuration
#  Making the LFS System Bootable
# The End

mkdir -p ${src}
mkdir -p ${logs}

# Preparing for the Build
# Do we have all requiered tools on the host ?
host_syscheck
# Fetching sources
host_build_deps_install
fetch_sources
# Extract some important version from the downloaded sources
versions_set
rootfs_populate
host_add_user
toolchain_build
cross_compil_temp_tools
system_build
#grub_build
#disk_image_create
#grub_install
