# Trained HDR10-to-SDR tonemap models

The three filters of [../README.md](../README.md) section 8.5, as used by the
live demo ([FreeBSD/netint_demo](../../../FreeBSD/netint_demo/README.md)).

| File | What it is |
|---|---|
| `tonemap_w48_int16_1920x1080.nb` | quality filter: width 48, depth 2, int16, fused graph |
| `tonemap_w32_int16_1920x1080.nb` | speed filter: width 32, depth 2, int16, fused graph |
| `tonemap_w48_uint8_1920x1080.nb` | width 48 with uint8 inner layers (`HYBRID=2`), int16 inputs and outputs |
| `tonemap_w48d2.pt`, `tonemap_w32d2.pt` | trained weights (PyTorch state dict of the first graph, `Tonemap` in `train_tonemap.py`) |
| `tonemap_w48d2_1920x1080.onnx`, `tonemap_w32d2_1920x1080.onnx` | the fused-graph ONNX export the `.nb` files were compiled from |

The `.nb` files run on a Quadra with firmware `5906tFr1` (libxcoder of the
same release). Inputs and outputs: three int16 planes of a 1920x1080
`yuv420p10le` frame (Y `1x1920x1080x1`, U and V `1x960x540x1`),
`fixed_point_pos=0`. Use them with the generic filter:

    ffmpeg -c:v h265_ni_quadra_dec -xcoder-params out=hw -i hdr10_1080p.mkv \
        -vf ni_quadra_ai_pre=nb=tonemap_w48_int16_1920x1080.nb,... 

or with [../tonemap/encode_sdr.sh](../tonemap/encode_sdr.sh) for the whole
HDR10-to-SDR encode.

## How they were made

- Training set (section 6 and 8.1): 1780 pairs, 960 pixels wide. 800 from 22
  live-action HDR10 films, 680 from 17 animation films, 300 synthetic
  color-block frames. Targets: libplacebo BT.2390 with perceptual gamut
  mapping, fixed 1000-nit source peak, no dithering. Validation: 80 pairs
  from two other films.
- Training: `train_tonemap.py pl_pairs OUT --iters 30000 --width W --depth 2
  --export-fused` (first graph trained, weights converted exactly to the
  fused graph for export).
- Compile: `convert_tonemap.sh 1920 1080` (int16), and `HYBRID=2
  convert_tonemap.sh 1920 1080` on the width-48 ONNX for the uint8 file.

The weights hold no film frames. The training frames themselves are not in
git (commercial films).

## Measured (section 8.1 and 8.5)

PSNR against libplacebo, dB, Y plane; fps is decode plus network for one
stream on the card (the card runs two streams of each).

| Model | Validation | Event Horizon | Sol Levante | fps |
|---|---|---|---|---|
| width 48 int16 | 47.81 | 49.80 | 41.71 | 27 |
| width 32 int16 | 43.56 | 45.94 | 38.26 | 37 |
| width 48 uint8 inside | | 40.90 | 35.63 | 40 |

To re-export from the weights, for example after a toolkit update:

    python3 train_tonemap.py pl_pairs out --iters 0 --width 48 --depth 2 \
        --load ../models/tonemap_w48d2.pt --export-fused

(`--iters 0` with `--load` skips training; `pl_pairs` is only read when
training.)
