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

Tuning NFSv4 server and client (here with a 100G link):

First TCP and NFS tuning on both client and servers:
```
cat >> /boot/loader.conf <<EOF
# Maximum size of a buffer cache block, default: 65536
# x 16
vfs.maxbcachebuf="1048576"
EOF
cat >> /etc/sysctl.conf <<EOF
# TCP x 16 all default values
# Maximum socket buffer size
kern.ipc.maxsockbuf=33554432
# Max size of automatic receive buffer
net.inet.tcp.recvbuf_max=33554432
# Max size of automatic send buffer
net.inet.tcp.sendbuf_max=33554432
# Initial receive socket buffer size
net.inet.tcp.recvspace=1048576
# Initial send socket buffer size
net.inet.tcp.sendspace=524288
EOF
shutdown -r now "Need a reboot to apply vfs.maxbcachebuf"
```

On the server side:
```
mkdir /tmp/nfs
chmod 777 /tmp/nfs/
cat > /etc/exports <<EOF
V4: /tmp
/tmp/nfs -network 1.1.1.0/24
EOF
cat >> /etc/sysctl.conf <<EOF
# Max number of nfsiod kthreads, default: 20
vfs.nfs.iodmax=64
EOF
sysrc nfs_server_enable=YES
sysrc nfsv4_server_enable=YES
sysrc nfsv4_server_only=YES
sysrc nfs_server_maxio=1048576
service nfsd start
```

Testing server local write speed, will be our reference value for the NFS client:
```
root@server:~ # dd if=/dev/zero of=/tmp/nfs/data bs=1M count=20480
20480+0 records in
20480+0 records out
21474836480 bytes transferred in 3.477100 secs (6176076082 bytes/sec)
root@server:~ # units -t '6176076082 bytes' gigabit
49.408609
```

The goal will be to reach about 49Gb/s (disk speed) on the NFS client.
About the maximum TCP speed between client and server:
```
root@client:~ # iperf3 -c 1.1.1.30 --parallel 16
[SUM]   0.00-10.00  sec  99.1 GBytes  85.1 Gbits/sec  81693  sender
```

Client setup with tunned NFS mount:
- nconnect=16 : Use 16 TCP sessions, to load-share them with the NIC multi-queue and CPU
- readahead=8 : determines how many blocks will be read ahead when a large file is being read sequentially
- nocto: Disable a safety by avoid purging the data cache if they do not match attributes cached by the client
- wcommitsize=67108864 (64MB): maximum amount of pending write data that the NFS client is willing to cache for each file
```
# mkdir /tmp/nfs
# sysrc nfs_client_enable=YES
# service nfsclient start
# mount -t nfs -o noatime,nfsv4,nconnect=16,wcommitsize=67108864,readahead=8,nocto 1.1.1.30:/nfs /tmp/nfs/
```

Now check the negociated rsize/wsize (depend of vfs.maxbcachebuf), nconnect, readahead and wcommitsize values
:
```
# nfsstat -m
1.1.1.30:/nfs on /tmp/nfs
nfsv4,minorversion=2,tcp,resvport,nconnect=16,hard,nocto,sec=sys,acdirmin=3,acdirmax=60,acregmin=5,acregmax=60,nametimeo=60,negnametimeo=60,rsize=1048576,wsize=1048576,readdirsize=1048576,readahead=8,wcommitsize=67108864,timeout=120,retrans=2147483647
# dd if=/dev/zero of=/tmp/nfs/data bs=1M count=20480
20480+0 records in
20480+0 records out
21474836480 bytes transferred in 7.574187 secs (2835266137 bytes/sec)
# units -t '2835266137 bytes' gigabit
22.682129
# umount /tmp/nfs/
# echo umounting to clear the buffer cache
# mount -t nfs -o noatime,nfsv4,nconnect=16,wcommitsize=67108864,readahead=8,nocto 1.1.1.30:/nfs /tmp/nfs/
root@client:~ # dd of=/dev/zero if=/tmp/nfs/data bs=1M count=20480
20480+0 records in
20480+0 records out
21474836480 bytes transferred in 4.168176 secs (5152094642 bytes/sec)
# units -t '5152094642 bytes' gigabit
41.216757
```

We reach 22Gb/s of writting speed and about 41Gb/s of reading speed.
There are still room for improvement.

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

# iPXE boot backup

```
mkdir /boot/efi/EFI/xyz
cd /boot/efi/EFI/xyz
fetch boot.netboot.xyz/ipxe/netboot.xyz.efi
efibootmgr --create --loader /boot/efi/EFI/netboot.xyz/netboot.xyz.efi --label "Netboot.xyz"
```
