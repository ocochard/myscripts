# llama.cpp

```
git clone https://github.com/ggerganov/llama.cpp.git
cd llama.cpp
make (Linux & MacOS) or gmake (FreeBSD)
curl --output-dir models -LO https://huggingface.co/TheBloke/Starling-LM-7B-alpha-GGUF/resolve/main/starling-lm-7b-alpha.Q4_K_M.gguf
./server --model models/starling-lm-7b-alpha.Q4_K_M.gguf
```
