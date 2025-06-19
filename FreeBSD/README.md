# FreeBSD

To do: Convert my [Desktop install webpage tips](https://olivier.cochard.me/bidouillage/installation-et-configuration-de-freebsd-comme-poste-de-travail) here

## Building

### Custom install media

Start to build world&kernel:
```
cd /usr/src
make buildworld-jobs buildkernel-jobs
```

The generate the release media:
```
cd /usr/src/release
make -DNOPORTS -DNODOC -DNOSRC memstick
dd if=/usr/obj/usr/src/amd64.amd64/release/memstick.img of=/dev/your-usb-stick bs=1M
```

Or VM image:
```
make WITH_VMIMAGES=yes VMFORMATS=raw VMSIZE=6g vm-image
```

### Build from a builder, clients on NFS

Process:
- Builder is buildworld buildkernel, beinstall, testing
- if okay, all other servers NFS read-only mount the builder's /usr/src and /usr/obj (their /etc/src\*.conf and /etc/make.conf are in sync)

To avoid all "Read-only file system" message, don't forget to set MAKE_OBJDIR_CHECK_WRITABLE=0 in your env

But in case of libc upgrade, the clients can't upgrade.
Example on old-way that doesn't support ZFS BE:
```
make installkernel
/usr/obj/../make: Undefined symbol "__libc_start1@FBSD_1.7
```

Then we can install the new kernel with:
```
LD_PRELOAD=/usr/obj/usr/src/amd64.amd64/lib/libc/libc.so.7 make -j 4 installkernel
etcupdate -p
```

And the `make buildworld` will start working too, but as soon as it will replace your /lib/libc.so.7,
there is a risk it will crash your system :-(
So to prepare to ease the rescue by copy localy the new libc:
```
cp /usr/obj/usr/src/amd64.amd64/lib/libc/libc.so.7 /root
LD_PRELOAD=/usr/obj/usr/src/amd64.amd64/lib/libc/libc.so.7 make -j 4 installworld
```

If still alive, finish it with an `etcupdate -B`, if not:
- It will reboot in single-user mode (with lot of libc error)
- from /rescue/sh copy the /root/libc.so.7 in /lib/
- reboot
- Restart the `make installworld`
- `etcupdate -B`

On a ZFS BE, the upgrade command is:
```
LD_PRELOAD=/usr/obj/usr/src/amd64.amd64/lib/libc/libc.so.7 tools/build/beinstall.sh
```

or with a missing libmd.so.7:
```
LD_PRELOAD=/usr/obj/usr/src/amd64.amd64/lib/libmd/libmd.so.7 tools/build/beinstall.sh
```

### Build from MacOS (ARM M3 pro)

Great [user guide](https://docs.freebsd.org/en/books/handbook/cutting-edge/#building-on-non-freebsd-hosts).

```
brew install llvm
git clone https://git.freebsd.org/src.git freebsd
mkdir ~/freebsd.obj
cd freebsd
tools/build/make.py --help
MAKEOBJDIRPREFIX=~/freebsd.obj tools/build/make.py -j $(sysctl -n hw.ncpu) TARGET=arm64 TARGET_ARCH=aarch64 buildworld buildkernel
```

## ZFS

With SSD disks or all trim compliant (off by default):

```
zpool set autotrim=on $pool
```

### Boot Environment (BE)

Fixing mess with broken snapshot:
1. Reboot, and in loader screen, choose previous be
2. mount and fix your mess

Example:
- Broken "14.0-CURRENT-20230116.182721" (broken libc)
- So on the FreeBSD loader boot screen, selected previous BE

```
root@broken:~ # bectl list
BE                           Active Mountpoint Space Created
14.0-CURRENT-20220222.111913 -      -          118M  2022-02-23 16:37
14.0-CURRENT-20221031.035546 N      /          70.1M 2022-11-01 20:08
14.0-CURRENT-20230116.182721 R      -          477G  2023-01-16 23:35
default                      -      -          6.42G 2018-03-29 14:44
root@broken:~ # bectl mount 14.0-CURRENT-20230116.182721 /mnt/
Successfully mounted 14.0-CURRENT-20230116.182721 at /mnt/
root@broken:~ # cp /mnt/lib/libc.so.7.bak /mnt/lib/libc.so.7
root@broken:~ # bectl umount 14.0-CURRENT-20230116.182721
root@broken:~ # shutdown -r now "I've fixed my mess!"
```

To cleanup all unused BE (warning: Try no destructive method first):
```
bectl list | grep -v 'NR\|default\|BE' | cut -d ' ' -f 1 | xargs -L1 bectl destroy
```

### Encrypted dataset

Create a dataset named 'work' of your 'zroot' pool, mount it in /work, enable compression and encryption using a passphrase:
```
zfs create -o encryption=on -o compression=zstd keyformat=passphrase -o mountpoint=/work zroot/work
```

After a reboot to mount it:
```
zfs mount -l zroot/work
```
To unmount and unload the key:
```
zfs unmount -u /work
```

## NFS

### NFSv4

Example with 100G link between server and client:

On server:
```
mkdir /tmp/nfs
mount -t tmpfs tmpfs /tmp/nfs
chmod 777 /tmp/nfs/
cat > /etc/exports <<EOF
V4: /tmp
/tmp/nfs -network 1.1.1.0/24
EOF
sysrc nfs_server_enable=YES
sysrc nfsv4_server_enable=YES
sysrc nfsv4_server_only=YES
service nfsd start
```

On client, don’t forget the nconnect=16 option:
```
# mkdir /tmp/nfs
# sysrc nfs_client_enable=YES
# service nfsclient start
# mount -t nfs -o noatime,nfsv4 1.1.1.30:/nfs /tmp/nfs/
# netstat -an -f inet -p tcp | grep 2049 | wc -l
       1
# dd if=/dev/zero of=/tmp/nfs/test bs=1G count=10
10+0 records in
10+0 records out
10737418240 bytes transferred in 8.526794 secs (1259256159 bytes/sec)
# rm /tmp/nfs/test
# umount /tmp/nfs
# mount -t nfs -o noatime,nfsv4,nconnect=16 1.1.1.30:/nfs /tmp/nfs/
# dd if=/dev/zero of=/tmp/nfs/test bs=1G count=10
10+0 records in
10+0 records out
10737418240 bytes transferred in 8.633871 secs (1243638980 bytes/sec)
# netstat -an -f inet -p tcp | grep 2049 | wc -l
      16
```

## Ports

### Build with DEBUG symbols

```
echo 'WITH_DEBUG_PORTS=devel/clinfo' >> /etc/make.conf
```
Or if using poudriere with jail named 'builder':
```
echo 'WITH_DEBUG_PORTS=devel/clinfo' >> /usr/local/etc/poudriere.d/builder-make.conf
```

### Build cmake with DEBUG symbols

```
~/ipc-bench $ mkdir debug
~/ipc-bench $ cd debug/
~/ipc-bench/debug $ cmake -DCMAKE_BUILD_TYPE=Debug ..
~/ipc-bench/debug $ make
```
### Pkg

From which package this file came from ?
```
pkg which /usr/local/lib/libtinfo.so.6
```

Which are the run dependencies of this package:
```
pkg info -dF ../locust/py311-pyzmq-25.0.2_2.pkg
```

Manually extracting the content of a pkg file:
```
mkdir /tmp/pkg
tar -C /tmp/pkg -xvf libcbor-0.12.0.pkg
mkdir /tmp/libcbor
cd /tmp/libcbor
ar -x /tmp/pkg/usr/local/lib/libcbor.a
```
## Extra

### dmesgd.nycbug.org

```
curl -v -d "nickname=$USER" -d "email=$USER@$(hostname)" -d "description=FreeBSD/$(uname -m) on $(kenv smbios.system.maker) $(kenv smbios.system.product)" -d "do=addd" --data-urlencode 'dmesg@/var/run/dmesg.boot' http://dmesgd.nycbug.org/index.cgi
```

### date

Convert time zone, with 06:15 UTC, which hours in Los Angeles:
```
TZ=UTC date -z America/Los_Angeles -j 0615
```
