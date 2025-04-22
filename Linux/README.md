# Scripts

 - [sysload](sysload/README.md): Display CPU/MEM/GPU (amd only) usage in CSV format
 - [lfs](lfs.sh): Build Linux From Scratch

# Notes

Simple note for a Linux newbie

## Base

### sudo

Prevent password request without modifying default configuration file:
```
echo "$USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/$USER
```

## Ubuntu

### SSHd
On desktop, sshd not installed by default:

```
sudo apt install openssh-server
sudo systemctl enable ssh
```

Viewing log:
```
sudo journalctl -u ssh --grep Accepted
```

### LVM

LVM concept in order:
1. File systems
2. Logical volumes (LVs)
3. Volume groups (VGs)
4. Physical volumes (PVs) (ie: usually same as partition)
5. Partitons
6. Disk

Install of Ubuntu server with default option on a 128G disk VM result in only
64G for the /, and missing 64G (lv* need lvm2 package):

```
$ df -h
Filesystem                         Size  Used Avail Use% Mounted on
tmpfs                              784M  700K  783M   1% /run
/dev/mapper/ubuntu--vg-ubuntu--lv   62G  6.6G   52G  12% /
tmpfs                              3.9G     0  3.9G   0% /dev/shm
tmpfs                              5.0M     0  5.0M   0% /run/lock
/dev/vda2                          2.0G  141M  1.7G   8% /boot
/dev/vda1                          1.1G  6.4M  1.1G   1% /boot/efi
tmpfs                              784M  4.0K  784M   1% /run/user/1000

$ lsblk
NAME                      MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
sda                         8:0    0   1.9G  1 disk
├─sda1                      8:1    0   1.9G  1 part
└─sda2                      8:2    0   5.8M  1 part
vda                       252:0    0   128G  0 disk
├─vda1                    252:1    0     1G  0 part /boot/efi
├─vda2                    252:2    0     2G  0 part /boot
└─vda3                    252:3    0 124.9G  0 part
  └─ubuntu--vg-ubuntu--lv 253:0    0  62.5G  0 lvm  /

$ sudo lvdisplay | grep Size
  LV Size                62.47 GiB

```

=> vda3 part is 125G, but lvm uses only 63G
Confirmed by the Volume group "Free space":
```
$ sudo vgdisplay | grep Free
  Free  PE / Size       15993 / 62.47 GiB
```

So need to extend it:
```
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
$ sudo lvdisplay | grep Size
  LV Size                <124.95 GiB
```

And the filesystem too:
```
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
$ df -h | grep ubuntu
/dev/mapper/ubuntu--vg-ubuntu--lv  123G  6.6G  111G   6% /
```
### Network

Warning: Ubuntu uses netplan and this mess uses:
- NetworkManager on Ubuntu Desktop
- (systemd) networkd on Ubuntu Server
So stick to netplan (/etc/netplan/01-netcfg.yaml) on those.
If this file is missing, create it:
```
netplan generate > /etc/netplan/01-netcfg.yaml
chmod 600 /etc/netplan/01-netcfg.yaml
```
And edit the renderer line to the installed API (switching back to networkd if
you’ve upgraded a server to desktop without installing NetworkManager as example).

A mess between the Network-manager (nmcli) and systemd-resolve.

Interface status:
```
nmcli device status
```

Displaying DHCP info:
```
nmcli -f DHCP4
nmcli device show enp2s0
```

What is the DHCP server IP address ?
```
nmcli -f DHCP4 connection show "Wired connection 1"
```

What is the DNS server ?
```
resolvectl status
```

Static IP configuration in `/etc/netplan/02-netconfig.yaml`

### Debian package creation

Official docs:

 - [Chapter 4. Required files under the debian directory](https://www.debian.org/doc/manuals/maint-guide/dreq.en.html)
 - [Chapter 6. Building the package](https://www.debian.org/doc/manuals/maint-guide/build.en.html)

#### Global concept

A debian packages is build with 3 files:
- name_version.dsc (description text file)
- name_version.orig.tar.xz (original sources archives)
- name_version.debian.tar.xz (debian patches and build scripts, to be untar into the sources dir)

Generic linux tooling needed:
- build-essential (compilers)
- devscript (packages build tools, like dpkg-depcheck)
- packages listed in Build-Depends field
- packages listed in the Build-Depends-indep field of debian/control

About the package build dependencies, file debian/control should be the one, but the dpkg-buildpackage will display
all missings deps.

#### Example by rebuilding existing util-linux packages

Do not (download original sources)[https://www.kernel.org/pub/linux/utils/util-linux/], but the Ubuntu repository fork.

```
git clone -b ubuntu/jammy --single-branch https://git.launchpad.net/ubuntu/+source/util-linux
cd util-linux
=> Install build-deps from debian/control
DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage -b
```

==== 2. Install build dependencies

Reading the debian/control file gives more clue:
sudo apt install bison libaudit-dev libcap-ng-dev libcrypt-dev libcryptsetup-dev libncurses5-dev libncursesw5-dev libpam0g-dev libreadline-dev libselinux1-dev libsystemd-dev libtool libudev-dev zlib1g-dev libaudit-dev

Then running (it will display the exact list of missing build dependencies too):

```
DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage -b
DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage -us -uc -b
-us, --unsigned-source      unsigned source package.
-uc, --unsigned-changes     unsigned .buildinfo and .changes file.
-b, --build=binary          binary-only, no source files.
env nocheck: avoid running regression test
```

Other:
```
# uncommented the relevant deb-src lines in /e/a/sources.list
apt update
apt install dpkg-dev
apt source ipmitool
apt build-dep ipmitool
cd ipmitool-1.8.18
debuild -us -uc
```

# Remove Ubuntu apt SPAM and closed-source snap

Ubuntu is [no more 'clean' and adding crap like ESM](https://github.com/Skyedra/UnspamifyUbuntu) and snap.

So, a lot of work need to be done:
- Replace ubuntu-advantage-tools with a fake package
- Disable ESM motd spam
- Disable dynamic motd spam

```
sudo pro config set apt_news=false
```

```
wget -q --content-disposition https://github.com/Skyedra/UnspamifyUbuntu/blob/master/fake-ubuntu-advantage-tools/fake-ubuntu-advantage-tools.deb?raw=true
sudo apt install ./fake-ubuntu-advantage-tools.deb
```

## disable Expanded Security Maintenance spam message

Hidden repo (not showed with add-apt-repository --list), that need to be manually disabled
```
sed -i 's/^deb/#deb/g' /var/lib/ubuntu-advantage/apt-esm/etc/apt/sources.list.d/ubuntu-esm-apps.list
```

## Remove snap

[Best doc about](https://haydenjames.io/remove-snap-ubuntu-22-04-lts/)
```
snap list
snap remove --purge packages-in-the-list
apt remove snapd
apt purge snapd
```

## Network

Disable privacy address:
- Replace net.ipv6.conf.*.use_tempaddr = 2 in /etc/sysctl.d/10-ipv6-privacy.conf buy = 0

Display DNS parameters:
```
resolvectl
```

Flush DNS cache:
```
sudo resolvectl flush-caches
```

# Drivers

## Hardware inventory

```
lsblk
sudo lshw
lshw -c video
lspci
```

listing devices that need a drivers:
```
ubuntu-drivers devices
```

If error:
```
$ ubuntu-drivers devices
ERROR:root:aplay command not found
```
Then install alsa-utils:
```
sudo apt-get install -y alsa-utils
```

## Drivers in use (mesa)

```
sudo apt install -y mesa-utils
DISPLAY=:0 glxinfo -B
```

If error:
```
Error: unable to open display :0
```
## Intel GPU

[Official Intel doc](https://dgpu-docs.intel.com/driver/client/overview.html)

```
$ sudo apt-get install -y libze-intel-gpu1 libze1 intel-ocloc intel-opencl-icd clinfo
$ clinfo -l
Platform #0: Intel(R) OpenCL Graphics
 `-- Device #0: Intel(R) Graphics [0x7d55]
```

## AMD proprietary GPU drivers

```
$ lshw -c video
74:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Rembrandt (rev 0a)
$ sudo dmesg | egrep 'drm|radeon'
(etc.)
[    2.317230] [drm] Initialized amdgpu 3.48.0 20150101 for 0000:74:00.0 on minor 0
(etc)
```

Binary from [AMD website](https://www.amd.com/en/support/linux-drivers) and [install doc](https://amdgpu-install.readthedocs.io/en/latest/).
Check on the [repository](https://repo.radeon.com/amdgpu-install/) the latest version
```
curl -O https://repo.radeon.com/amdgpu-install/23.10.2/ubuntu/jammy/amdgpu-install_5.5.50502-1_all.deb
sudo apt-get install ./amdgpu-install_5.4.50502-1_all.deb
sudo amdgpu-install --usecase=graphics --vulkan=amdvlk --opencl=rocr
sudo usermod -a -G render $LOGNAME
sudo usermod -a -G video $LOGNAME
echo "VK_ICD_FILENAMES=/etc/alternatives/amd_icd64.json" | sudo tee -a /etc/environment
sudo reboot
```

If proprietary drivers needed, replace amdgpu by this line:
```
sudo amdgpu-install --usecase=graphics --vulkan=pro --opencl=rocr
```

Need to test Vulkan API with vkcube tool:
```
sudo apt-get install vulkan-tools
vulkaninfo
vkcube
```

Use [radeontop](https://github.com/clbr/radeontop) to see GPU usage

## Nvidia Tesla
-------------

If already installed by `ubuntu-drivers autoinstall`, need to be removed first:
```
apt remove nvidia-headless-525-server nvidia-dkms-525-server nvidia-headless-no-dkms-525-server  nvidia-kernel-common-525
wget https://us.download.nvidia.com/XFree86/aarch64/530.41.03/NVIDIA-Linux-aarch64-530.41.03.run
sh ./NVIDIA-Linux-aarch64-530.41.03.run
```

Warning: CUDA version MUST match minimum drivers version following [CUDA Install guide](https://docs.nvidia.com/cuda/cuda-installation-guide-linux/)
Testing:
```
$ nvidia-smi
+---------------------------------------------------------------------------------------+
| NVIDIA-SMI 530.41.03              Driver Version: 530.41.03    CUDA Version: 12.1     |
|-----------------------------------------+----------------------+----------------------+
| GPU  Name                  Persistence-M| Bus-Id        Disp.A | Volatile Uncorr. ECC |
| Fan  Temp  Perf            Pwr:Usage/Cap|         Memory-Usage | GPU-Util  Compute M. |
|                                         |                      |               MIG M. |
|=========================================+======================+======================|
|   0  Tesla T4                        Off| 00000000:01:00.0 Off |                    0 |
| N/A   58C    P8               10W /  70W|      2MiB / 15360MiB |      0%      Default |
|                                         |                      |                  N/A |
+-----------------------------------------+----------------------+----------------------+
|   1  Tesla T4                        Off| 00000001:01:00.0 Off |                    0 |
| N/A   63C    P8               11W /  70W|      2MiB / 15360MiB |      0%      Default |
|                                         |                      |                  N/A |
+-----------------------------------------+----------------------+----------------------+
|   2  Tesla T4                        Off| 00000007:01:00.0 Off |                    0 |
| N/A   56C    P8               11W /  70W|      2MiB / 15360MiB |      0%      Default |
|                                         |                      |                  N/A |
+-----------------------------------------+----------------------+----------------------+

+---------------------------------------------------------------------------------------+
| Processes:                                                                            |
|  GPU   GI   CI        PID   Type   Process name                            GPU Memory |
|        ID   ID                                                             Usage      |
|=======================================================================================|
|  No running processes found                                                           |
+---------------------------------------------------------------------------------------+
```

Running hascat in bench mode (-b):

```
$ nvidia-smi
+---------------------------------------------------------------------------------------+
| NVIDIA-SMI 530.41.03              Driver Version: 530.41.03    CUDA Version: 12.1     |
|-----------------------------------------+----------------------+----------------------+
| GPU  Name                  Persistence-M| Bus-Id        Disp.A | Volatile Uncorr. ECC |
| Fan  Temp  Perf            Pwr:Usage/Cap|         Memory-Usage | GPU-Util  Compute M. |
|                                         |                      |               MIG M. |
|=========================================+======================+======================|
|   0  Tesla T4                        Off| 00000000:01:00.0 Off |                    0 |
| N/A   70C    P0               72W /  70W|   2984MiB / 15360MiB |     99%      Default |
|                                         |                      |                  N/A |
+-----------------------------------------+----------------------+----------------------+
|   1  Tesla T4                        Off| 00000001:01:00.0 Off |                    0 |
| N/A   71C    P0               71W /  70W|   2984MiB / 15360MiB |     99%      Default |
|                                         |                      |                  N/A |
+-----------------------------------------+----------------------+----------------------+
|   2  Tesla T4                        Off| 00000007:01:00.0 Off |                    0 |
| N/A   65C    P0               75W /  70W|   2984MiB / 15360MiB |    100%      Default |
|                                         |                      |                  N/A |
+-----------------------------------------+----------------------+----------------------+

+---------------------------------------------------------------------------------------+
|7 Processes:                                                                            |
|  GPU   GI   CI        PID   Type   Process name                            GPU Memory |
|        ID   ID                                                             Usage      |
|=======================================================================================|
|    0   N/A  N/A     12914      C   hashcat                                    2980MiB |
|    1   N/A  N/A     12914      C   hashcat                                    2980MiB |
|    2   N/A  N/A     12914      C   hashcat                                    2980MiB |
+---------------------------------------------------------------------------------------+
```

# Base

## initramfs

### ALERT! UUID=1db6b810-d625-4e9a-aced-32b48f6a8d5b does not exist

Last action: shrink the Windows NTFS volume, and expanded the Linux ext4fs rootfs volume.
System was working great, but after the first reboot it refuse to boot.

```
(initramfs) blkid
/dev/nvme0n1p3: UUID=xxxx TYPE="ntfs" PARTLABEL="Basic data partiton"
/dev/nvme0n1p1: UUID=yyyy LABEL="SYSTEM" TYPE="vfat" PARTLABEL="EFI"
/dev/nvme0n1p4: UUID=zzzz LABEL="Recovery" TYPE="nts"
/dev/nvme0n1p2: UUID=wwww, PARTLABEL="Microsotf reserver partition"
```

(same for an `ls /dev/disk/by-uuid/`)

Here, it is a dual boot Windows/Ubuntu, but where is my extfs partition ??
```
(initramfs) ls /dev/nvme0n"*
/dev/nvme0n1
/dev/nvme0n1p1
/dev/nvme0n1p2
/dev/nvme0n1p3
/dev/nvme0n1p4
/dev/nvme0n1p5
```

Partition 5 is missing from the blkid output, let’s force an fsck:
```
fsck.ext4 /dev/nvme0n1p5
```
fsck doesn’t report any errror, but why no UUID displayed by blkid ?
Let’s try to run tunefs, but it is on the broken partition:
```
(initramfs) mkdir /mnt
(initramfs) mount /dev/nvme0n1p5 /mnt
(initramfs) /mnt/sbin/tune2fs -l /dev/nvme0n1p5 | grep UUID
Filesystem UUID:	1db6b810-d625-4e9a-aced-32b48f6a8d5
```

What ?? It is here!
Ok, let’s replace the UUID usage by the disk name in /etc/fstab:
```
(initramfs) mount --bind /dev /mnt/dev
(initramfs) mount --bind /proc /mnt/proc
(initramfs) chroot /mnt
root@(none):/# vi /etc/fstab
```

Here I’ve replaced the entry `/dev/disk/by-uuid/1dd...` by `/dev/nvme0n1p5`
Now upgrading all bootloader and initramfs then reboot:
```
root@(none):/# update-grub
root@(none):/# update-initramfs -u
root@(none):/# exit
(initramfs) umount /mnt/proc
(initramfs) umount /mnt/dev
(initramfs) umount /mnt
(initramfs) reboot -f
```

And still not able to find the now /dev/nvme0n1p5 during boot.
Let’s try to pass a longer rootdelay in Linux kernel by updating grub.
Remount and re-chroot into your rootfs, then set a 10 seconds delay to wait to detect this disk:

```
vi /etc/default/grub
GRUB_CMDLINE_LINUX="rootdelay=10"
```

Then redo the same update-grub+exit+umount+reboot steps as previously.
But... still nothing. So booting with an USB live CD:

```
fdisk -l /dev/nvme0n1
```
All partitons display, including p5 as "Linux filesystem" type
```
blkid /dev/nvme0n1p5
```
Empty reply, let’s probe it:
```
sudo blkid --probe --match-types ext4 /dev/nvme0n1p5
/dev/nvme0n1p5: UUID="1dd..."
```

Let’s check if partprobe error:
```
sudo partprobe /dev/nvme0n1p5
```
No error displayed but still nothing, so let’s change the UUID:
```
sudo tune2fs -U random /dev/nvme0n1p5
Setting the UUID on this filesystem could take some time.
Proceed anyway (or wait 5 seconds to proceed) ? (y,N)
```

Still not fix, so let’s change the disk partition number (p4 position if after p5, so should change p5 as p4 and p4 as p5):
```
sudo fdisk /dev/nvme0n1
p (print partition table)
x (extra functionnality)
f (fix partition order)
r (return to main menu)
p (print partition table to check new order)
w (write and exit)
```

Now time to mount disk and chroot into it to update /etc/fstab with new partition id.
While here I’ve noticed this error message "couldn’t identify filesystem type for fsck hook, ignoring" from update-initramfs.
It was not able to automatically detected this partition.
Solution: reformating.

## swap

It creates a swap file in the /:
```
ubuntu:/# swapon -show
Filename				Type		Size		Used		Priority
/swap.img                               file		8388604		0		-2
```

To disable it:
```
swapoff /swap.img
rm /swap.img
sed -i '/swap.img/d' /etc/fstab
```

## Systemd

### journalctl
----------
[command comprehensive guide](https://www.linuxjournal.com/content/mastering-journalctl-command-comprehensive-guide)

reverse mode:
```
sudo journalctl -r
```

Kernel, show the boot list:
```
journalctl --list-boots
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
 -3 8726d12ba21a4b32bf07154da5ad82f1 Mon 2025-03-31 21:39:44 UTC Mon 2025-03-31 21:50:23 UTC
 -2 9364d619961c49c2ba39096ae4dcd59c Mon 2025-03-31 21:50:47 UTC Mon 2025-04-21 14:28:34 UTC
 -1 e7ae7ed5387f416b98a35c7809061c8a Mon 2025-04-21 17:16:54 UTC Mon 2025-04-21 18:05:59 UTC
  0 c0e214ddf10b43708e990088bb531f7f Mon 2025-04-21 18:06:22 UTC Tue 2025-04-22 12:55:01 UTC
```

Then display the messages from boot session you are looking for:
```
journalctl -k -b -3
```

# Packages management

### dpkg

Options:
  -i install
  -r remove
  -P purge (remove config file)
  -l list
  --force-all

From which package this file belong to ?
```
dpkg -S /usr/bin/m4
```

### Alternatives

If need multiples compilers:

```
update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-10 10
update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-10 10
update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-11 11
update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 11
```

Now to select them:
```
update-alternatives --config g++
update-alternatives --config gcc
```

### Disabling autoupgrade

#### apt

Switch the 1 to 0 here:
```
sudo vi /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
```

#### snap
```
sudo snap refresh --hold
```

# Tooling

## Profiling

```
apt-get install linux-tools-common linux-tools-generic linux-tools-`uname -r`
perf record -f -g -a
```

## Docker

[Install instruction on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)

```
sudo usermod -aG docker $USER
newgrp docker
docker run hello-world
```

Where are image stored:
```
$ docker info
...
Storage Driver: overlay2
 Docker Root Dir: /var/lib/docker
```

Customize a docker image:

```
olivier@host:~$ docker run -it ubuntu bash
root@f18e5dff2f03:/# lsb_release -a
bash: lsb_release: command not found
root@f18e5dff2f03:/# apt update && apt install lsb-core
(etc.)
root@f18e5dff2f03:/# lsb_release -a
LSB Version:    core-11.1.0ubuntu4-noarch:security-11.1.0ubuntu4-noarch
Distributor ID: Ubuntu
Description:    Ubuntu 22.04.2 LTS
Release:        22.04
=> on other terminal
olivier@host~$ docker ps
CONTAINER ID   IMAGE     COMMAND   CREATED          STATUS          PORTS     NAMES
f18e5dff2f03   ubuntu    "bash"    6 minutes ago    Up 6 minutes              goofy_almeida
olivier@host:~$ docker images
REPOSITORY      TAG       IMAGE ID       CREATED         SIZE
ubuntuwithlsb   latest    bae41ca408fc   7 seconds ago   586MB
hello-world     latest    9c7a54a9a43c   2 weeks ago     13.3kB
ubuntu          latest    3b418d7b466a   3 weeks ago     77.8MB
olivier@host:~$ docker run -it ubuntuwithlsb bash
root@d781574512cd:/# lsb_release -a
LSB Version:    core-11.1.0ubuntu4-noarch:security-11.1.0ubuntu4-noarch
Distributor ID: Ubuntu
Description:    Ubuntu 22.04.2 LTS
Release:        22.04
Codename:       jammy
```

Persisting data folder:
```
sudo docker run -ti --rm -v ~/Docker_Share:/data ubuntu /bin/bash
```

```
docker container ls
docker ps --no-trunc
```

Copying files:
```
docker cp ./some_file CONTAINER:/work
```

Open shell inside:
```
docker exec -it CONTAINER sh
```

System stat:
```
docker stats
```

Cleaning docker layer cache (can be in weird buggy state):
```
yes | docker system prune -a
```

## Perf

```
sudo apt install linux-tools-generic
```

Example:
```
olivier@ryzen7:~$ sudo perf record --call-graph dwarf /usr/bin/radeontop -d - -i 15 -t 20
Dumping to -, until termination.
1683580703.217021: bus 74, gpu 0.00%, ee 0.00%, vgt 0.00%, ta 0.00%, sx 0.00%, sh 0.00%, spi 0.00%, sc 0.00%, pa 0.00%, db 0.00%, cb 0.00%, vram 2.97% 242.41mb, gtt 0.06% 17.50mb, mclk 43.61% 1.047ghz, sclk 18.18% 0.400ghz
1683580718.217399: bus 74, gpu 0.00%, ee 0.00%, vgt 0.00%, ta 0.00%, sx 0.00%, sh 0.00%, spi 0.00%, sc 0.00%, pa 0.00%, db 0.00%, cb 0.00%, vram 2.97% 242.41mb, gtt 0.06% 17.50mb, mclk 43.61% 1.047ghz, sclk 18.18% 0.400ghz
1683580733.217864: bus 74, gpu 0.00%, ee 0.00%, vgt 0.00%, ta 0.00%, sx 0.00%, sh 0.00%, spi 0.00%, sc 0.00%, pa 0.00%, db 0.00%, cb 0.00%, vram 2.97% 242.41mb, gtt 0.06% 17.50mb, mclk 42.06% 1.009ghz, sclk 18.18% 0.400ghz
1683580748.218396: bus 74, gpu 0.00%, ee 0.00%, vgt 0.00%, ta 0.00%, sx 0.00%, sh 0.00%, spi 0.00%, sc 0.00%, pa 0.00%, db 0.00%, cb 0.00%, vram 2.97% 242.41mb, gtt 0.06% 17.50mb, mclk 43.42% 1.042ghz, sclk 18.18% 0.400ghz
1683580763.218933: bus 74, gpu 0.00%, ee 0.00%, vgt 0.00%, ta 0.00%, sx 0.00%, sh 0.00%, spi 0.00%, sc 0.00%, pa 0.00%, db 0.00%, cb 0.00%, vram 2.97% 242.41mb, gtt 0.06% 17.50mb, mclk 42.64% 1.023ghz, sclk 18.18% 0.400ghz
^C1683580765.868285: bus 74, gpu 0.00%, ee 0.00%, vgt 0.00%, ta 0.00%, sx 0.00%, sh 0.00%, spi 0.00%, sc 0.00%, pa 0.00%, db 0.00%, cb 0.00%, vram 2.97% 242.41mb, gtt 0.06% 17.50mb, mclk 42.44% 1.019ghz, sclk 18.18% 0.400ghz
[ perf record: Woken up 36 times to write data ]
[ perf record: Captured and wrote 9.256 MB perf.data (1136 samples) ]
```

## Wayland

### Default graphical mode

```
systemctl get-default
```
If it displays multi-user.target (text) switch it to graphical:
```
sudo systemctl set-default graphical.target
```

### Disabling

```
sudo sed -i 's/#WaylandEnable/WaylandEnable/' /etc/gdm3/custom.conf
sudo systemctl restart gdm3
```

### Start local graphical from SSH
To be able to start graphical software from SSH, need to export XAUTHORITY and DISPLAY.
Your user need to be locally logged on the wayland/xorg (to create the XAUTH token file), then from SSH session:
```
export XAUTHORITY=$(ls /run/user/$(id -u)/.* | grep auth)
export DISPLAY=:0
```
Then try to run simple app:
```
xcalc
```

