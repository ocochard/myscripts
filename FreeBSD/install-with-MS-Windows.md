# Installing FreeBSD with Windows

## Concept

- EFI bootloader: refind (because native Windows 11 EFIboot loader to boot the FreeBSD’s EFI)
- Windows 11 on its shrinked partition
- FreeBSD ZFS installation

## Pre-requisit, from Windows

Windows 11 installed on fresh new PC.

### Disable bitlocker ?

Without, the disk shrinking and FreeBSD install will work, but once added the EFI entry, and selecting the FreeBSD entry in the EFI menu, it will request bitlocker unlock-crazy-stupid-long-number.
Once entered, it will ask again this crazy-long-number a second time.

### Prepare FreeBSD install media with refind

Download FreeBSD, dd (Windows equivalent) to USB stick
https://sourceforge.net/projects/refind/ and copy this zipped file into the FreeBSD USB stick EFI partiton
```
fetch -o refind-bin-0.14.2.zip https://sourceforge.net/projects/refind/files/0.14.2/refind-bin-0.14.2.zip/download
```
## FreeBSD manual installation

Boot the FreeBSD USB stick and select "live" mode.

First step, to add 2 partitions on this new free space:
- One swap partition (mainly for potential core dump), glabel: swap
- One ZFS partition, glabel: zroot

As booted from USB, display all available disks:
```
sysctl -n kern.disks
gpart add -t freebsd-swap -l swap -s 16G nda0
gpart add -t freebsd-zfs -l zroot -s 120G nda0
```

Now configuring a Boot Environment compliant ZFS layout, following the [installer script](usr.sbin/bsdinstall/scripts/zfsboot).
zpool name: zroot:
```
sysct vfs.zfs.vdev.min_auto_ashift=12
zpool create -f -o altroot=/mnt -O compress=lz4 -O atime=off -O canmount=off -m none zroot gpt/zroot
zfs create -o mountpoint=none zroot/ROOT
zfs create -o mountpoint=/ zroot/ROOT/default
zfs create -o mountpoint=/home zroot/home
zfs create -o mountpoint=/tmp -o exec=on -o setuid=off zroot/tmp
chmod 1777 /mnt/tmp
zfs create -o mountpoint=/usr -o canmount=off zroot/usr
zfs create -o setuid=off zroot/usr/ports
zfs create zroot/usr/src
zfs create -o sync=disabled zroot/usr/obj
zfs create -o mountpoint=/var -o canmount=off zroot/var
zfs create -o exec=off -o setuid=off zroot/var/audit
zfs create -o exec=off -o setuid=off zroot/var/crash
zfs create -o exec=off -o setuid=off zroot/var/log
zfs create -o atime=on zroot/var/mail
zfs create -o setuid=off zroot/var/tmp
chmod 1777 /mnt/var/tmp
zpool set bootfs=zroot/ROOT/default zroot
```

And installing the set:
For pre-16, using .txz it is very easy:
```
tar -C /mnt -xvJf /usr/freebsd-dist/base.txz
tar -C /mnt -xvJf /usr/freebsd-dist/kernel.txz
tar -C /mnt -xvJf /usr/freebsd-dist/lib32.txz
```
For 16 and later is is more complex due to setting up pkg repository:
```
mount -uw /
pkg add -y /usr/freebsd-packages/offline/pkg-*.pkg
mkdir -p /mnt/usr/local/etc/pkg
cp -r /usr/freebsd-packages/repos /mnt/usr/local/etc/pkg/
pkg --rootdir /mnt --repo-conf-dir /mnt/usr/local/etc/pkg/repos/ -o IGNORE_OSVERSION=yes install -y -r FreeBSD-base freebsd-set-base freebsd-kernel-generic-nodebug
-o ABI="$(pkg config abi)"
```

Export your ZFS:
```
zpool export zroot
```

And stays in the live mode for the next step.

## rEFInd Installation

Here we will:
- Mount the MS Windows EFI partition
- Install the FreeBSD efi loader into this partition
- Install rEFInd into this partition and enable it as the main boot manager (in place of the Windows one)

MS Windows usually is using the gpt label name `EFI%20system%20partition` for its EFI parttion, so let’s use that:

```
mkdir /tmp/efiwin
mkdir /tmp/efiusb
mount -t msdosfs /dev/gpt/EFI%20system%20partition /tmp/efiwin
mount -t msdosfs /dev/da0s1 /tmp/efiusb
mkdir /tmp/efiwin/EFI/FreeBSD
cp /boot/loader.efi /tmp/efiwin/EFI/FreeBSD/
unzip -d /tmp /tmp/efiusb/refind-bind-*.zip
cp -r /tmp/refind-bind-*/refind /tmp/efiwin/EFI/
rm -rf /tm/efiwin/EFI/refind/drivers_aa64
rm -rf /tm/efiwin/EFI/refind/drivers_ia32
rm -rf /tm/efiwin/EFI/refind/refind_ia32.efi
rm -rf /tm/efiwin/EFI/refind/refind_aa64.efi
rm -rf /tm/efiwin/EFI/refind/tools_ia32.efi
rm -rf /tm/efiwin/EFI/refind/tools_aa64.efi
cat <<EOF > /tmp/efiwin/EFI/refind/refind.conf
timeout 10
scanfor manual
menuentry "Windows 11" {
  icon /EFI/refind/icons/os_win8.png
  loader /EFI/Microsoft/Boot/bootmgfw.efi
}
menuentry "FreeBSD" {
  icon /EFI/refind/icons/os_freebsd.png
  loader /EFI/FreeBSD/loader.efi
}
EOF
umount /tmp/efiwin
umount /tmp/efiusb
```

Now we need to add this new rEFInd entry into your EFI, MS Windows should using a gpt label name `EFI%20system%20partition`:
```
efibootmgr --create --activate --label "rEFInd" --loader 'gpt/EFI%20system%20partition:/EFI/refind/refind_x64.efi'
reboot

```
Then it will reboot in Windows (refind installed but not enabled)
cmd in admin mode
```
bcdedit /set "{bootmgr}" path \EFI\refind\refind_x64.efi
bcdedit /set "{bootmgr}" description "rEFInd description"
```

### sources

https://forums.freebsd.org/threads/dual-boot-to-windows10-and-freebsd-in-uefi.79208/
https://vermaden.wordpress.com/2025/02/02/freebsd-alongside-windows/


