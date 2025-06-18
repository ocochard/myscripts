# Stable diffusion with A1111

First, must read the [beginer guide](https://stable-diffusion-art.com/beginners-guide/).
[Official instruction to install automatic1111 on MacOS](https://github.com/AUTOMATIC1111/stable-diffusion-webui/wiki/Installation-on-Apple-Silicon)

```
brew install cmake protobuf rust python@3.10 git wget
git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui
cd stable-diffusion-webui
curl -LO stable-diffusion-webui/models/Stable-diffusion/Protogen_Infinity.ckpt "https://huggingface.co/darkstorm2150/Protogen_Infinity_Official_Release/resolve/main/model.ckpt?download=true"
./webui.sh
```

## Models

[Models guide for beginers](https://stable-diffusion-art.com/models/).
Some [populars list](https://openaijourney.com/best-stable-diffusion-models/).

## ControlNet extension

Allows to :
- Specify human poses;
- Copy the composition from another image;
- Generate a similar image.

[Some tutorial about it](https://stable-diffusion-art.com/controlnet/#Installing_Stable_Diffusion_ControlNet).
Need to install:
1. [Controlnet](https://github.com/Mikubill/sd-webui-controlnet)
2. [controlnet model](https://github.com/Mikubill/sd-webui-controlnet/wiki/Model-download), specialy the [Openpose model](https://huggingface.co/lllyasviel/ControlNet-v1-1/blob/main/control_v11p_sd15_openpose.pth), to be installed in  stable-diffusion-webui/models/ControlNet
3. [Dynamic poses packages](https://civitai.com/models/87024/dynamic-poses-100), to be use as pose reference, this is not a model

### IP Adapter

Add-on for using images as prompts.

To be downloaded in `stable-diffusion-webui/extensions/sd-webui-controlnet/models`, because with A1111 it is managed by ControlNet extension.
The guides:
- [How to use image prompt in Stable Diffusion](https://stable-diffusion-art.com/image-prompt/)

## Ultimate SD upscale

Extension -> Available -> Load From (to update the list) -> Go to Ultimate SD upscale and click install -> Installed -> Apply and reload

## ComfyUI

Extension -> Available -> ComfyUI

ComfyUI -> install comfyui

Extension -> Available -> Apply and reload
Allows to create 
