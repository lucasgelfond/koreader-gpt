#!/bin/sh
# Copies gpt2.koplugin to a Kindle over SSH (KOReader's SSH server, port 2222 by default).
# usage: scripts/install.sh KINDLE_IP [PORT]
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOST=${1:?usage: scripts/install.sh KINDLE_IP [PORT]}
PORT=${2:-2222}

for f in llama-completion gpt2-Q4_0.gguf; do
    [ -f "$ROOT/gpt2.koplugin/$f" ] || { echo "gpt2.koplugin/$f is missing: run scripts/build.sh first" >&2; exit 1; }
done
COPYFILE_DISABLE=1 tar -C "$ROOT" -cf - gpt2.koplugin/_meta.lua gpt2.koplugin/main.lua \
    gpt2.koplugin/llama-completion gpt2.koplugin/gpt2-Q4_0.gguf |
    ssh -p "$PORT" "root@$HOST" 'tar -C /mnt/us/koreader/plugins -xf - && chmod +x /mnt/us/koreader/plugins/gpt2.koplugin/llama-completion'
echo "Installed. Restart KOReader to load it."
