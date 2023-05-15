# FreeBSD

To do: Convert my [Desktop install webpage tips](https://olivier.cochard.me/bidouillage/installation-et-configuration-de-freebsd-comme-poste-de-travail) here

## Build from a builder, clients on NFS

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

On a ZFS BE, it is resume as:
```
LD_PRELOAD=/usr/obj/usr/src/amd64.amd64/lib/libc/libc.so.7 tools/build/beinstall
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
