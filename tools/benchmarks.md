# GPU benchmark

## [Blender](https://opendata.blender.org/)

```
wget https://download.blender.org/release/BlenderBenchmark2.0/launcher/benchmark-launcher-cli-3.1.0-linux.tar.gz
tar zxvf benchmark-launcher-cli-3.1.0-linux.tar.gz
./benchmark-launcher-cli authenticate (optional)
./benchmark-launcher-cli blender list
./benchmark-launcher-cli blender download 3.5.0
./benchmark-launcher-cli scenes --blender-version 3.5.0 list
./benchmark-launcher-cli scenes download --blender-version 3.5.0 monster monster classroom
./benchmark-launcher-cli devices -blender-version 3.5.0
DISPLAY=:0 ./benchmark-launcher-cli  benchmark --blender-version 3.5.0 --device-type CPU --json --submit monster monster classroom
```

## [Geekbench](https://www.geekbench.com/)

```
wget https://cdn.geekbench.com/Geekbench-6.1.0-Linux.tar.gz
tar jxvf Geekbench-6.1.0-Linux.tar.gz
cd Geekbench-6.1.0-Linux
./geekbench6 --sysinfo
./geekbench6 --gpu-list
./geekbench6
./geekbench6 --gpu Vulkan
```

## [GravityMark](https://gravitymark.tellusim.com/)


## [vkmark](https://github.com/vkmark/vkmark)

```
git clone git@github.com:vkmark/vkmark.git
cd vkmark
sudo apt install -y meson libvulkan-dev libglm-dev libassimp-dev libxcb1-dev libxcb-icccm4-dev libwayland-dev wayland-protocols libdrm-dev libgbm-dev cmake pkg-config
meson build
ninja -C build
build/src/vkmark --winsys-dir=build/src --data-dir=data -L
build/src/vkmark --winsys-dir=build/src --data-dir=data
```

