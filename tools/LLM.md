# llama.cpp

```
git clone https://github.com/ggerganov/llama.cpp.git
cd llama.cpp
make (Linux & MacOS) or gmake (FreeBSD)
curl --output-dir models -LO https://huggingface.co/TheBloke/Starling-LM-7B-alpha-GGUF/resolve/main/starling-lm-7b-alpha.Q4_K_M.gguf
./server --model models/starling-lm-7b-alpha.Q4_K_M.gguf
```

For big (32G) unsencored model:
```
curl --output-dir models -LO https://huggingface.co/TheBloke/Mixtral-8x7B-v0.1-GGUF/resolve/main/mixtral-8x7b-v0.1.Q5_K_M.gguf
```
