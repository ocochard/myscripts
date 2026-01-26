# FreeBSD

To do: Convert my [Desktop install webpage tips](https://olivier.cochard.me/bidouillage/installation-et-configuration-de-freebsd-comme-poste-de-travail) here

## Building

### Custom install media

Start to build world&kernel:
```
cd /usr/src
sudo make buildworld-jobs buildkernel-jobs update-packages-jobs
```
(add update-packages-jobs for pkgbase user)

The generate the release media:
```
sudo make -C release -DNOPORTS -DNODOC -DNOSRC -DNOPKGBASE -DNOPKG memstick -j $(nproc)
sudo dd if=/usr/obj/usr/src/amd64.amd64/release/memstick.img of=/dev/your-usb-stick bs=1M
```
(the -DNOPKGBASE is for traditionnal, no package base, installation type)

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

First: Do all your commmands from root (su) because using sudo, there is higher chance of it not working during the process.

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

In case of forcing some LD_PRELOAD, we can end-up in different state:
- No impact: Finish the upgrade with an `etcupdate -B`.
- Bad state: All commands end with "Bad system call", you’re good to force power cycle, to continue.
- Very bad state (libc upgrade): still problem after the reboot:
  - reboot in single-user mode (with lot of libc error)
  - from /rescue/sh copy the /root/libc.so.7 in /lib/
  - reboot
- Restart the `make installworld`
- `etcupdate -B`

On a ZFS BE, the upgrade command is:
```
sudo LD_PRELOAD=/usr/obj/usr/src/amd64.amd64/lib/libc/libc.so.7 tools/build/beinstall.sh
```

or with a missing libmd.so.7 and missing libutil.so.10 (from 14.3-RELEASE to 15):
```
sudo LD_PRELOAD="/usr/obj/usr/src/amd64.amd64/lib/libmd/libmd.so.7 \
/usr/obj/usr/src/amd64.amd64/lib/libutil/libutil.so.10" \
tools/build/beinstall.sh
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

## Installation

cf [Install with MS Windows](install-with-MS-Windows.md).

## ZFS

With SSD disks or all trim compliant (off by default):

```
zpool set autotrim=on $pool
```

### Expanding raidz

By replacing all existing disk, one by one by bigger disk, we can expand a raidz.

On this example:
- the zraid name is NAS
- created using RAW disk ada0 to ada4.
  Why RAW disk (no partition)?
  Because this pool is not used to boot the machine, so no need for GPT/UEFI boot partition.
  But if you need a partitionning scheme, you will have to create your partition before the replace
  command and using the correct partition name in place of disk name.

In all case, first enable auto expand feature on this zpool:
```
sudo zpool set autoexpand=on NAS
```

And check the current available space:
```
$ zfs list NAS
NAME   USED  AVAIL  REFER  MOUNTPOINT
NAS   25.7T  2.99T  25.7T  /NAS
```

Then we have multiple ways to replace the disk:

#### Safest

If you have a free disk slot and only one zpool (no danger of removing disk from another zpool),
insert one new bigger disk in this free slot (it will be named ada5 on our example).

Advantage: Your zpool will never be in degrated state during this operation.

And replace the first old-smaller disk (ada0 on this example) with a `zpool replace NAS ada0 ada5`.
Wait for the zpool to finish its resilvered, this task could takes hours/days depending the disk size.
For information it is about 12hours for a SATA 8TB HDD disk).
Once the zpool state back at "ONLINE" state, physically replace one old-small disk by a new-bigger one (power off before it no hot-swap support).
If all the disks in our machine are dedicated to this zpool, you don’t have to identify
the exact disk to remove (because all non-ada5 disks are to be replaced), so just physically replace another
disk with a new one and check the status of zpool status to detect which one is now missing.
As example, if you discover that it ada3 that is missing, a `zpool replace NAS ada3` will start
to resilver the zpool re-using the new disk that was replaced.
WAIT for the resilvering process, and repeat for all the other remaining disks using the same method.
If you have multiple pools, then you can not remove then without identifying the disk to remove
(using the blinking LED tips explained later).

#### Controlled

You don’t need a spare disk space here, but don’t made any mistake by replacing the wrong disk.

Identify the disk by triggering activity on it and looking which LED is blinking:
```
sudo dd if=/dev/ada0 of=/dev/null bs=1m
```

Once identified switch this identified disk offline:
```
sudo zpool offline NAS ada0
```

Physically replace this ada0 by a bigger new one, then double-check you have
unpluged the correct disk, here only ada0 should be in OFFLINE mode:
```
sudo zpool status NAS
```
To double check you are unpluging the good disk, you can try to trigger activity on
ALL others disks to monitor their LED activity while you are replacing it.
Once confirmed you've replaced the correct one, replace it (because the previous disk was ada0, you just need
to use one disk name):
```
sudo zpool replace NAS ada0
```

Wait for the end of resilvering (about 12 hours with 8TB SATA disk):
```
sudo zpool status NAS
$ sudo zpool status NAS
  pool: NAS
 state: DEGRADED
status: One or more devices is currently being resilvered.  The pool will
        continue to function, possibly in a degraded state.
action: Wait for the resilver to complete.
  scan: resilver in progress since Fri Jan 23 13:43:00 2026
        2.43T / 32.2T scanned at 6.56G/s, 282G / 32.2T issued at 762M/s
        56.4G resilvered, 0.86% done, 12:11:50 to go
config:

        NAME             STATE     READ WRITE CKSUM
        NAS              DEGRADED     0     0     0
          raidz1-0       DEGRADED     0     0     0
            replacing-0  DEGRADED     0     0     0
              ada0/old   OFFLINE      0     0     0
              ada0       ONLINE       0     0     0  (resilvering)
            ada2         ONLINE       0     0     0
            ada1         ONLINE       0     0     0
            ada3         ONLINE       0     0     0
            ada4         ONLINE       0     0     0
```
Then do the same for all others disks (ada1 to ada4 on this example).
Replacing five 8TB disk by five 14TB disks, will take here 12 hours x 5.

You can check that the new disk size are correctly detected by ZFS with a `zpool list -v -p NAS`.
Here is an example output while resilvering the last disk in the zpool:
```
$ zpool list -v -p NAS
NAME                       SIZE           ALLOC           FREE  CKPOINT        EXPANDSZ   FRAG    CAP  DEDUP    HEALTH  ALTROOT
NAS              39857296506880  35378596872192  4478699634688        -  29961691856896      6     88   1.00  DEGRADED  -
  raidz1-0       39857296506880  35378596872192  4478699634688        -  29961691856896      6     88      -  DEGRADED        -
    ada3         14000519643136      -      -        -         -      -      -      -    ONLINE        -
    ada2         14000519643136      -      -        -         -      -      -      -    ONLINE        -
    ada1         14000519643136      -      -        -         -      -      -      -    ONLINE        -
    ada0         14000519643136      -      -        -         -      -      -      -    ONLINE        -
    replacing-4      -      -      -        -         -      -      -      -  DEGRADED        -
      ada4/old   8001563131904      -      -        -         -      -      -      -   OFFLINE        -
      ada4       14000519643136      -      -        -         -      -      -      -    ONLINE        -
```

We notice all new disks are 14TB, and the EXPANDSZ column showing approx 27.2TB that will be added
once the sileviring process will finish that will become at the end:
```
$ zfs list NAS
NAME   USED  AVAIL  REFER  MOUNTPOINT
NAS   25.7T  24.8T  25.7T  /NAS
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

## Basic setup

### IPMI or serial

To enable serial output on physical port, IPMI and graphical:
Into /boot/loader.conf (or loader.conf.local):
```
boot_multicons="YES"
console="eficom,efi"
```

Some emulated serial port with IPMI SoL doesn’t use the default 0x3f8, so
search for the correct value with this command:
```
grep 'uart.*port' /var/run/dmesg.boot
uart0: <16550 or compatible> port 0x3f8-0x3ff irq 4 flags 0x10 on acpi0
uart1: <16550 or compatible> port 0x2f8-0x2ff irq 3 on acpi0
```
Here, the first (uart0) is the physical serial port and uart1 is the IPMI SoL.
So to use SoL as default console, add this line:
```
comconsole_port="0x2f8"
```

## NFS

### NFS client

Always mount NFS with:
- soft:Operations fail after timeout instead of hanging forever (default is hard)
- intr: Allow signals to interrupt hung operations
- timeo=10: Wait only 1 second per retry (10 × 0.1s)
- retrans=2: Only retry 2 times before failing
- bg: Retry mount in background if server is down at boot

Without the 2 first options, and with a GENERIC-DEBUG, it will trigger a panic
in case of a mounted NFS directory that is no more reachable (the deadlock resolver
can't distinguish NFS timeout from kernel deadlock).

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
- nconnect=16 : Use 16 TCP sessions, to load-share them with the NIC multi-queue and CPU
- readahead=8 : determines how many blocks will be read ahead when a large file is being read sequentially
- nocto: Disable a safety by avoid purging the data cache if they do not match attributes cached by the client
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
tar -x /tmp/pkg/usr/local/lib/libcbor.a
```

### Jails

[cf dedicated doc](jail/README.md)

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
mkdir /boot/efi/efi/xyz
cd /boot/efi/efi/xyz
fetch http://boot.netboot.xyz/ipxe/netboot.xyz.efi
efibootmgr --create --loader /boot/efi/efi/xyz/netboot.xyz.efi --label "Netboot.xyz"
```
And write down the boot entry number, but don’t use
`--activate` because it could replace your FreeBSD entry).

Test it as nexboot entry:
```
efibootmgr --bootnext --bootnum bootnum
```

Reboot, then show your boot menu (F12 on Dell) to double check you still have the FreeBSD menu and the new xyz entry.
