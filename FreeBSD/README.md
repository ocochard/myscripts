# FreeBSD

To do: Convert my [Desktop install webpage tips](https://olivier.cochard.me/bidouillage/installation-et-configuration-de-freebsd-comme-poste-de-travail) here

## ZFS

With SSD disks or all trim compliant (off by default):

```
zpool set autotrim=on $pool
```
