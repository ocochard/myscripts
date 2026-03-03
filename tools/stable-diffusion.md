# ComfyUI

## Apple

[Need to install pytorch first](https://developer.apple.com/metal/pytorch/)

Some external module like reactor need a not so recent python version:
```
brew install python@3.12
python3.12 -m venv venv
```
## Linux

Ubuntu running on AMD Strix Halo.

```
sudo apt install python3-venv
```

## Generic instruction

```
git clone https://github.com/Comfy-Org/ComfyUI.git
cd ComfyUI
[ -d venv ] && python3 -m venv venv
source venv/bin/activate
# --upgrade
# For AMD ROCM:
pip3 install --pre torch torchvision torchaudio --index-url https://download.pytorch.org/whl/nightly/rocm7.0
# For Apple:
pip3 install --pre torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/nightly/cpu
pip3 install -r requirements.txt
pip3 install insightface
# Testing pytorch install
python -c "import torch" 2>nul && echo Success || echo Failure
# testing if CUDA available (Linux/AMD/NVidia)
python -c "import torch; print(torch.cuda.is_available())"
python -c "import torch; print(f'device name [0]:', torch.cuda.get_device_name(0))"
# testing if Metal (Apple) available:
python -c "import torch; print(f'MPS available: {torch.backends.mps.is_available()}'); print(f'Built with MPS: {torch.backends.mps.is_built()}')"
# Install ComfyUI Manager
cd custom_nodes
git clone https://github.com/ltdrdata/ComfyUI-Manager.git
cd ..
python main.py --listen 0.0.0.0 --front-end-version Comfy-Org/ComfyUI_frontend@latest
# For ROCM version < 7.2, add --fp32-vae on AMD Strix Halo (to avoid bf16/fp16 known to trigger HIP kernel failures)
```

Open the URL into your browser and as example load the image_qwen_image workflow, then manually download requested files:
```
cd ComfyUI/models/diffusion_models
wget https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/diffusion_models/qwen_image_fp8_e4m3fn.safetensors
cd ../loras
wget https://huggingface.co/lightx2v/Qwen-Image-Lightning/resolve/main/Qwen-Image-Lightning-8steps-V1.0.safetensors
cd ../vae
wget https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors
cd ../text_encoders
wget https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors
