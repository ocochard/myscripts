# Notes

Simple note for a Linux newbie

# Ubuntu

# Cleaning dirty ads and closed-source snap

Ubuntu is no more 'clean' and adding crap like ESM and snap.

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
```


# Drivers

listing devices and drivers:
```
ubuntu-drivers devices
```

## AMD GPU

```
$ lspci | grep VGA
74:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Rembrandt (rev 0a)
$ sudo dmesg | egrep 'drm|radeon'
(etc.)
[    2.317230] [drm] Initialized amdgpu 3.48.0 20150101 for 0000:74:00.0 on minor 0
(etc)
```

Binary from [AMD website](https://www.amd.com/en/support/linux-drivers) and [install doc](https://amdgpu-install.readthedocs.io/en/latest/):
```
curl -O https://repo.radeon.com/amdgpu-install/22.40.3/ubuntu/jammy/amdgpu-install_5.4.50403-1_all.deb
sudo apt-get install ./amdgpu-install_5.4.50403-1_all.deb
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
| Processes:                                                                            |
|  GPU   GI   CI        PID   Type   Process name                            GPU Memory |
|        ID   ID                                                             Usage      |
|=======================================================================================|
|    0   N/A  N/A     12914      C   hashcat                                    2980MiB |
|    1   N/A  N/A     12914      C   hashcat                                    2980MiB |
|    2   N/A  N/A     12914      C   hashcat                                    2980MiB |
+---------------------------------------------------------------------------------------+
```


# Systemd

## journalctl
----------
[command comprehensive guide](https://www.linuxjournal.com/content/mastering-journalctl-command-comprehensive-guide)

# Packages management

## dpkg

Options:
  -i install
  -r remove
  -P purge (remove config file)
  -l list
  --force-all

## Alternatives

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

# Docker

```
docker container ls
docker ps
````

Copying files:
```
docker cp ./some_file CONTAINER:/work
```

Open shell inside:
```
docker exec -it CONTAINER sh
```
