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
[ -d venv ] || python3 -m venv venv
source venv/bin/activate
# --upgrade
# For AMD ROCM (wheel bundles ROCm userspace, no system ROCm needed):
# Check torch.__version__ ends in +rocm7.14 after requirements.txt: a +cu130 torch means PyPI CUDA build replaced it
pip3 install torch torchvision --index-url https://download.pytorch.org/whl/rocm7.14
# torchaudio has no rocm7.14 build for Python 3.14. ComfyUI-Manager needs it anyway: without it logs
# "PyTorch is not installed" and skips restoring torch after a custom node replaces it.
# --no-deps keeps pip from swapping torch; abi3 extension loads fine with torch 2.14.
pip3 install --no-deps torchaudio==2.11.0 --index-url https://download.pytorch.org/whl/rocm7.2
# For Apple:
pip3 install --pre torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/nightly/cpu
pip3 install -r requirements.txt
pip3 install insightface
# Testing pytorch install
python -c "import torch" 2>/dev/null && echo Success || echo Failure
# testing if CUDA available (Linux/AMD/NVidia)
python -c "import torch; print(torch.cuda.is_available())"
python -c "import torch; print(f'device name [0]:', torch.cuda.get_device_name(0))"
# testing if Metal (Apple) available:
python -c "import torch; print(f'MPS available: {torch.backends.mps.is_available()}'); print(f'Built with MPS: {torch.backends.mps.is_built()}')"
# Install ComfyUI Manager
cd custom_nodes
git clone https://github.com/ltdrdata/ComfyUI-Manager.git
cd ..
# AMD Strix Halo: no memory flags needed, ComfyUI detects the integrated GPU
# (log: "DynamicVRAM support detected and enabled", pinned memory off, pytorch attention on).
# Avoid --highvram: it disables DynamicVRAM. Avoid --disable-smart-memory: offloads to the same physical RAM.
# Measured 2026-10-26 on framework2 (Qwen-Image 2.1 t2i, 1024x1024, 25 steps euler, enhancer off, torch 2.14.1+rocm7.14):
#   no flags:                          cold 66.4s, warm 60.9s, 2.13-2.35 s/it, GPU mem peak 17.8GiB
#   --highvram --disable-smart-memory: cold 74.7s, warm 64.7s, 2.39-2.51 s/it, GPU mem peak 11.7GiB
#   old flags reload diffusion model + VAE every image; they only save ~5GiB of GPU memory.
# expandable_segments: set in both runs above, its own effect not measured
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
python main.py --listen 0.0.0.0 --front-end-version Comfy-Org/ComfyUI_frontend@latest

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

The "Download" button in the missing-models dialog saves to the browser's machine, not the ComfyUI server: run the downloads on the server.
Use `/resolve/` URLs: a `/blob/` URL saves the HuggingFace HTML page (check with `file`, it must say `data`, not `HTML document`).

Qwen-Image 2.1 (templates image_qwen_image_2_1_t2i and image_qwen_image_2_1_turbo_t2i, ~34GB for both):
```
cd ComfyUI/models
base=https://huggingface.co/Comfy-Org/Qwen-Image-2.1/resolve/main
for f in \
  diffusion_models/qwen_image_2.1_int8_convrot.safetensors \
  diffusion_models/qwen_image_2.1_turbo_int8_convrot.safetensors \
  text_encoders/qwen3vl_8b_int8_convrot.safetensors \
  text_encoders/qwen3.5_9b_qwen_image_2.1_pe_t2i.int8_convrot.safetensors \
  vae/qwen_image_2.1_vae_bf16.safetensors; do
  wget -c -O "$f" "$base/$f"
done
file */qwen*.safetensors
```

### Generate an image (Qwen-Image 2.1)

1. Open `http://<server>:8188/` in a browser.
2. Load a template: "Templates" in the left sidebar (or Workflow menu > Browse Templates, label depends on frontend version), search "Qwen Image 2.1":
   - Text to Image (`image_qwen_image_2_1_t2i`): best quality, 25 steps, ~61s per 1024x1024 on Strix Halo.
   - Turbo Text to Image (`image_qwen_image_2_1_turbo_t2i`): fewer steps (fixed inside the subgraph), faster; not timed.
3. Edit the "Text to Image (Qwen Image 2.1)" subgraph node:
   - `prompt`: long, specific descriptions work best.
   - `negative_prompt`: no effect while `cfg` is 1 (default).
   - `refine_prompt` + `thinking`: prompt enhancer (Qwen 3.5 9B rewrites the prompt first); turn both on together, richer result, slower.
   - `seed`: change for another image from the same prompt.
   - Size: on the `ResolutionSelector` node; 1 MP = 1024x1024, 4 MP = native 2048x2048 (~4x slower).
   - `steps` (standard template only): 25 by default, official pipeline uses 40-50.
4. Run (Ctrl+Enter). First run is slower: models load from disk (~66s vs ~61s).
5. Result: shown in the save node (right-click to save to the browser's machine), stored on the server in `ComfyUI/output/Qwen_image_2.1_*.png`.
   The PNG embeds the workflow: drag it back into ComfyUI to restore the exact settings.
