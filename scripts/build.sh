#!/bin/sh
# Builds a static llama-completion for Kindle (32-bit ARM, hard float) and GPT-2 small quantized to 4 bits,
# and puts both in gpt2.koplugin/. Needs git, cmake, ninja and uv; Zig comes from PyPI.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD="$ROOT/build"
LLAMA_COMMIT=f1168ac417f1b09af0846d042a12c577b0ffc7ca
mkdir -p "$BUILD"
cd "$BUILD"

if [ ! -d llama.cpp ]; then
    git clone -q https://github.com/ggml-org/llama.cpp
    git -C llama.cpp checkout -q "$LLAMA_COMMIT"
    git -C llama.cpp apply "$ROOT/patches/llama-gpt2-convert.patch"
fi

# Zig as the cross compiler. cortex_a7 rather than the Scribe's actual cortex_a53: in 32-bit mode an ARMv8 target
# makes the compiler define NEON intrinsics that ggml also defines for ARMv7.
[ -d zenv ] || { uv venv -q zenv && uv pip install -q --python zenv ziglang; }
Z="$BUILD/zenv/bin/python"
for tool in cc c++; do
    printf '#!/bin/sh\nexec %s -m ziglang %s -target arm-linux-musleabihf -mcpu=cortex_a7 "$@"\n' "$Z" "$tool" > "z$tool"
done
for tool in ar ranlib; do
    printf '#!/bin/sh\nexec %s -m ziglang %s "$@"\n' "$Z" "$tool" > "z$tool"
done
chmod +x zcc zc++ zar zranlib

cmake -S llama.cpp -B arm -G Ninja -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=armv7 \
    -DCMAKE_C_COMPILER="$BUILD/zcc" -DCMAKE_CXX_COMPILER="$BUILD/zc++" \
    -DCMAKE_AR="$BUILD/zar" -DCMAKE_RANLIB="$BUILD/zranlib" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
    -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF \
    -DCMAKE_EXE_LINKER_FLAGS="-static -s" > /dev/null
ninja -C arm llama-completion

# The model: convert with the host's tools, then quantize. Q4_0, because Q8_0 doesn't fit in the ~240 MB
# a Kindle has free with KOReader open.
cmake -S llama.cpp -B host -G Ninja -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF > /dev/null
ninja -C host llama-quantize
if [ ! -f gpt2-f16.gguf ]; then
    [ -d cenv ] || { uv venv -q cenv && uv pip install -q --python cenv \
        -r llama.cpp/requirements/requirements-convert_hf_to_gguf.txt huggingface_hub; }
    cenv/bin/hf download openai-community/gpt2 config.json model.safetensors tokenizer.json tokenizer_config.json \
        vocab.json merges.txt generation_config.json --local-dir hf-gpt2 > /dev/null
    cenv/bin/python llama.cpp/convert_hf_to_gguf.py hf-gpt2 --outtype f16 --outfile gpt2-f16.gguf
fi
host/bin/llama-quantize gpt2-f16.gguf gpt2-Q4_0.gguf Q4_0 > /dev/null 2>&1

cp arm/bin/llama-completion gpt2-Q4_0.gguf "$ROOT/gpt2.koplugin/"
ls -la "$ROOT/gpt2.koplugin"
