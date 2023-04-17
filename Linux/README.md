# Notes

Simple note for a Linux newbie

# Ubuntu

# After install

## Remove snap

```
snap list
snap remove --purge packages-in-the-list
apt remove snapd
```


# Drivers

```
ubuntu-drivers devices
```

## Nvidia Tesla
-------------

If already installed by `ubuntu-drivers autoinstall`:
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
