# llama.cpp

```
git clone https://github.com/ggerganov/llama.cpp.git
cd llama.cpp
make (Linux & MacOS) or gmake (FreeBSD)
cd models
fetch https://huggingface.co/TheBloke/openchat_3.5-GGUF/resolve/main/openchat_3.5.Q5_K_M.gguf
cd ..
./server --model models/openchat_3.5.Q5_K_M.gguf
```
