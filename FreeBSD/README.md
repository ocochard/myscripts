# FreeBSD

To do: Convert my [Desktop install webpage tips](https://olivier.cochard.me/bidouillage/installation-et-configuration-de-freebsd-comme-poste-de-travail) here

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
