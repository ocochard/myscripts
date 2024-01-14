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

LFS=${LFS:="${HOME}/lfs"}

src="${LFS}/sources"
logs="${HOME}/lfs.log"

#curl_cmd_src="curl --output-dir ${LFS}/sources -LO"

# Default env var
# https://www.linuxfromscratch.org/lfs/view/stable/chapter04/settingenvironment.html
umask 022
LC_ALL=POSIX
LFS_TGT=$(uname -m)-lfs-linux-gnu
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

nproc=$(nproc)

## Sources Tools chain and all packages

die() {
	echo "FATAL: $1"
	exit 1
}

extract_file() {
	local name=$1
	n=$(find ${LFS}/sources -maxdepth 1 -type f -regex ".*${name}.*tar.*" | wc -l)
	if [ "$n" -gt 1 ]; then
		die "Multiples matchs regarding source archive name for ${name}"
	elif [ "$n" -eq 0 ]; then
		die "Did not find ${name} file"
	fi
	file=$(find ${LFS}/sources -maxdepth 1 -type f -regex ".*${name}.*tar.*")
	tar -C ${LFS}/sources -xf ${file}
}

get_source_dir() {
	name=$1
	n=$(find ${LFS}/sources -maxdepth 1 -type d -regex  ".*${name}.*" | wc -l)
	if [ "$n" -gt 1 ]; then
		die "Multipe matchs regarding source directory for ${name}"
	elif [ "$n" -eq 0 ]; then
		extract_file ${name}
	fi
	dir=$(find ${LFS}/sources -maxdepth 1 -type d -regex ".*${name}.*")
	echo $dir
}

fetch_extract() {
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
	host_ver_kernel 4.14

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
build_deps_install() {
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
binutils_build_pass1() {
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
			--disable-werror > ${logs}/binutils_build_pass1.log
		make -j ${nproc} >> ${logs}/binutils_build_pass1.log
		make -j ${nproc} install >> ${logs}/binutils_build_pass1.log
	fi
}

gcc_build_pass1() {
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
			--enable-languages=c,c++ > ${logs}/gcc_build_pass1.log
		make -j ${nproc} >> ${logs}/gcc_build_pass1.log
		make -j ${nproc} install >> ${logs}/gcc_build_pass1.log
		# Generate full version of header limits.h (will be needed later)
		cd ..
		cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
		`dirname $($LFS_TGT-gcc -print-libgcc-file-name)`/include/limits.h
	fi
}

linux_api_headers() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter05/linux-headers.html
	if [ ! -d $LFS/usr/include ]; then
		echo "[Toolchain] Building and installing linux API headers..."
		srcdir=$(get_source_dir '/linux')
		cd ${srcdir}
		make -j ${nproc} mrproper > ${logs}/linux_api_headers.log
		make -j ${nproc} headers >> ${logs}/linux_api_headers.log
		find usr/include -type f ! -name '*.h' -delete
		cp -r usr/include $LFS/usr
	fi
}

glibc_build() {
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
		mkdir -p build
		cd build
		echo "rootsbindir=/usr/sbin" > configparms
		../configure                         \
			--prefix=/usr                      \
		 	--host=$LFS_TGT                    \
		 	--build=$(../scripts/config.guess) \
		 	--enable-kernel=${linux_min_ver}               \
		 	--with-headers=$LFS/usr/include    \
		 	libc_cv_slibdir=/usr/lib > {logs}/glibc_build.log
		make -j ${nproc} >> ${logs}/glibc_build.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/glibc_build.log
		sed '/RTLDLIST=/s@/usr@@g' -i $LFS/usr/bin/ldd
		echo "Testing glibc install:"
		echo 'int main(){}' | $LFS_TGT-gcc -xc -
		readelf -l a.out | grep ld-linux
		rm a.out
	fi
}

libstdcpp_build() {
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
			--with-gxx-include-dir=/tools/$LFS_TGT/include/c++/${gcc_ver} > ${logs}/libstdpp_build.log
		make -j ${nproc} >> ${logs}/libstdpp_build.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/libstdpp_build.log
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
	# gcc -dumpmachine
	# echo "ld:"
	# readelf -l /bin/bash | grep interpreter
	#[Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]
	binutils_build_pass1
	# Build limited gcc (no Libstdc++ support, because no glibc)
	gcc_build_pass1
	linux_api_headers
	glibc_build
	libstdcpp_build
}

# chapter 6

cc_temp_build_ncurse() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter06/ncurses.html
	if [ ! -f $LFS/lib/libncurses.so ]; then
		echo "Building and installing ncurse..."
		srcdir=$(get_source_dir ncurse)
		cd ${srcdir}
		sed -i s/mawk// configure
		mkdir -p build
		cd build
		# tic build on host
		../configure > ${logs}/ncurse_build.log
		make -j ${nproc} -C include >> ${logs}/ncurse_build.log
		make -j ${nproc} -C progs tic >> ${logs}/ncurse_build.log
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
			--enable-widec >> ${logs}/ncurse_build.log
		make -j ${nproc} >> ${logs}/ncurse_build.log
		# need to pass the path of the newly built tic that runs on the building machine,
		# so the terminal database can be created without errors.
		make -j ${nproc} DESTDIR=$LFS TIC_PATH=$(pwd)/build/progs/tic install >> ${logs}/ncurse_build.log
		# The libncurses.so library is needed by a few packages we will build soon. We create this small linker script
		echo "INPUT(-lncursesw)" > $LFS/usr/lib/libncurses.so
	fi
}

cc_temp_build_bash() {
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
			--without-bash-malloc > ${logs}/bash_build.log
		make -j ${nproc} >> ${logs}/bash_build.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/bash_build.log
		# Make a link for the programs that use sh for a shell
		ln -s bash $LFS/bin/sh
	fi
}

cc_temp_build_coreutils() {
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
			--enable-no-install-program=kill,uptime > ${logs}/coreutils_build.log
		make -j ${nproc} >> ${logs}/coreutils_build.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/coreutils_build.log
		# Move programs to their final expected locations.
		# Although this is not necessary in this temporary environment, we must do so because some programs hardcode executable locations
		mv $LFS/usr/bin/chroot $LFS/usr/sbin
		mkdir -v $LFS/usr/share/man/man8
		mv $LFS/usr/share/man/man1/chroot.1 $LFS/usr/share/man/man8/chroot.8
		sed -i 's/"1"/"8"/' $LFS/usr/share/man/man8/chroot.8
	fi
}

cc_temp_build_diffutils() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter06/diffutils.html
	if [ ! -f $LFS/usr/bin/cmp ]; then
		echo "Building and installing diffutils..."
		srcdir=$(get_source_dir diffutils)
		cd ${srcdir}
		./configure --prefix=/usr   \
			--host=$LFS_TGT \
			--build=$(./build-aux/config.guess) > ${logs}/diffutils_build.log
		make -j ${nproc} >> ${logs}/diffutils_build.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/diffutils_build.log
	fi
}

cc_temp_build_file() {
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
			--disable-zlib > ${logs}/file_build.log
		make -j ${nproc} >> ${logs}/file_build.log
		cd ..
		./configure --prefix=/usr --host=$LFS_TGT --build=$(./config.guess) >> ${logs}/file_build.log
		make FILE_COMPILE=$(pwd)/build/src/file >> ${logs}/file_build.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/file_build.log
		# Remove the libtool archive file because it is harmful for cross compilation:
		rm $LFS/usr/lib/libmagic.la
	fi
}

cc_temp_build_findutils() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter06/findutils.html
	if [ ! -f $LFS/usr/bin/find ]; then
		echo "Building and installing findutils..."
		srcdir=$(get_source_dir find)
		cd ${srcdir}
		./configure --prefix=/usr                   \
			--localstatedir=/var/lib/locate \
			--host=$LFS_TGT                 \
			--build=$(build-aux/config.guess) > ${logs}/findutils_build.log
		make -j ${nproc} >> ${logs}/findutils_build.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/findutils_build.log
	fi
}

cc_temp_build_gawk() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter06/gawk.html
	if [ ! -f $LFS/usr/bin/gawk ]; then
		echo "Building and installing gawk..."
		srcdir=$(get_source_dir gawk)
		cd ${srcdir}
		# First, ensure some unneeded files are not installed:
		sed -i 's/extras//' Makefile.in
		./configure --prefix=/usr   \
			--host=$LFS_TGT \
			--build=$(build-aux/config.guess) > ${logs}/gawk_build.log
		make -j ${nproc} >> ${logs}/gawk_build.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/gawk_build.log
	fi
}

cc_temp_build_gzip() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter06/gzip.html
	if [ ! -f $LFS/usr/bin/gzip ]; then
		echo "Building and installing gzip..."
		srcdir=$(get_source_dir gzip)
		cd ${srcdir}
		./configure --prefix=/usr   \
			--host=$LFS_TGT > ${logs}/gzip_build.log
		make -j ${nproc} >> ${logs}/gzip_build.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/gzip_build.log
	fi
}

cc_temp_build_make() {
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
			--build=$(build-aux/config.guess) > ${logs}/make_build.log
		make -j ${nproc} >> ${LFS}/make_build.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/make_build.log
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
			--build=$(build-aux/config.guess) > ${logs}/${name}_build.log
		make -j ${nproc} >> ${logs}/${name}_build.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/${name}_build.log
	fi
}

cc_temp_build_xz() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter06/xz.html
	if [ ! -f $LFS/usr/bin/xz ]; then
		echo "Building and installing xz..."
		srcdir=$(get_source_dir xz)
		cd ${srcdir}
		./configure --prefix=/usr   \
			--host=$LFS_TGT \
			--disable-static                  \
			--docdir=/usr/share/doc/xz-5.4.5 \
			--build=$(build-aux/config.guess) > ${logs}/patch_build.log
		make -j ${nproc} >> ${logs}/patch_build.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/patch_build.log
		# Remove the libtool archive file because it is harmful for cross compilation:
		rm -v $LFS/usr/lib/liblzma.la
	fi
}

cc_temp_build_binutils() {
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
    		--enable-default-hash-style=gnu > ${logs}/binutils_build_pass2.log
		make -j ${nproc} >> ${logs}/binutils_build_pass2.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/binutils_build_pass2.log
		# Remove the libtool archive files because they are harmful for cross compilation, and remove unnecessary static libraries:
		rm $LFS/usr/lib/lib{bfd,ctf,ctf-nobfd,opcodes,sframe}.{a,la}
	fi
}

cc_temp_build_gcc() {
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
			--enable-languages=c,c++ > ${logs}/gcc_build_pass2.log
		make -j ${nproc} >> ${logs}/gcc_build_pass2.log
		make -j ${nproc} DESTDIR=$LFS install >> ${logs}/gcc_build_pass2.log
		ln -sv gcc $LFS/usr/bin/cc
	fi
}

cross_compil_temp_tools() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter06/introduction.html

	# stage 2 using cross toolchain builded at stage 1 to build several utilities
	# in a way that isolates them from the host distribution

	cc_temp_build m4
	cc_temp_build_ncurse
	cc_temp_build_bash
	cc_temp_build_coreutils
	cc_temp_build_diffutils
	cc_temp_build_file
	cc_temp_build_findutils
	cc_temp_build_gawk
	cc_temp_build grep
	cc_temp_build_gzip
	cc_temp_build_make
	cc_temp_build patch
	cc_temp_build sed
	cc_temp_build tar
	cc_temp_build_xz
 	cc_temp_build_binutils
	cc_temp_build_gcc
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

chroot_cc_temp_tools() {
	# https://www.linuxfromscratch.org/lfs/view/development/chapter07/introduction.html
	# Build the last missing bits of the temporary system:
	# the tools needed to build the various packages.
	# Now that all circular dependencies have been resolved, a “chroot” environment,
	# completely isolated from the host operating system (except for the running kernel),
   	# can be used for the build.

	# Stage 3: entering the chroot environment (which further improves host isolation) and constructing the remaining tools needed to build the final system

	#
	echo "DEBUG"
	sudo echo LFS: $LFS
	exit 1

	# https://www.linuxfromscratch.org/lfs/view/development/chapter07/changingowner.html
	sudo chown -R root:root $LFS/{usr,lib,var,etc,bin,sbin,tools}
	# XXX  But we instructed to use /lib in place of /lib64!?!?
	case $(uname -m) in
		x86_64) sudo chown -R root:root $LFS/lib64 ;;
	esac

	# https://www.linuxfromscratch.org/lfs/view/development/chapter07/kernfs.html

	# Preparing Virtual Kernel File Systems

	sudo mkdir -p $LFS/{dev,proc,sys,run}
	# xxx need to check if not mounted first
	# host-agnostic way to populate the $LFS/dev directory is by bind
	# mounting the host system's /dev directory and not using devtmpfs
	if !grep -q "${LFS}/dev" /proc/mounts; then
		sudo mount --bind /dev $LFS/dev
	fi

	if !grep -q "${LFS}/dev/pts" /proc/mounts; then
		sudo mount --bind /dev/pts $LFS/dev/pts
	fi
	if !grep -q "${LFS}/proc" /proc/mounts; then
		sudo mount -t proc proc $LFS/proc
	fi
	if !grep -q "${LFS}/sys" /proc/mounts; then
		sudo mount -t sysfs sysfs $LFS/sys
	fi
	if !grep -q "${LFS}/run" /proc/mounts; then
		sudo mount -t tmpfs tmpfs $LFS/run
	fi

	if [ -h $LFS/dev/shm ]; then
		(cd $LFS/dev; mkdir $(readlink shm))
	else
		sudo mount -t tmpfs -o nosuid,nodev tmpfs $LFS/dev/shm
	fi

	# https://www.linuxfromscratch.org/lfs/view/development/chapter07/chroot.html

	chroot "$LFS" /usr/bin/env -i   \
    HOME=/root                  \
    TERM="$TERM"                \
    PS1='(lfs chroot) \u:\w\$ ' \
    PATH=/usr/bin:/usr/sbin     \
    MAKEFLAGS="-j$(nproc)"      \
    TESTSUITEFLAGS="-j$(nproc)" \
    /bin/bash --login

}


build_user() {
	# https://www.linuxfromscratch.org/lfs/view/stable/chapter04/addinguser.html
	echo "XXX Need to use $USER"
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
build_deps_install
fetch_sources
versions_set
rootfs_populate
build_user
toolchain_build
cross_compil_temp_tools
# XXX chroot mean to cross-compil?!
chroot_cc_temp_tools
#grub_build
#disk_image_create
#grub_install
