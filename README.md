# koreader-gpt

GPT-2 running on a Kindle, inside KOReader. Nothing leaves the device: the model (GPT-2 small, 124M parameters, quantized to 4 bits) runs in a static build of llama.cpp's `llama-completion`, at about 13 tokens a second on a Kindle Scribe.

- **Continue a highlight:** tap a highlight → **…** → **Continue with GPT-2**
- **Continue the page:** Tools → GPT-2 → **Continue this page** (also a gesture action)
- **Write from a prompt:** Tools → GPT-2 → **Write from a prompt…** (works from the file browser too)

A GPT-2 window opens and fills in as the model writes, with your text in grey and GPT-2's in bold. **Stop** ends it early; afterwards **Try again** rerolls and **Keep going** writes more. Length (40/80/160 tokens) and temperature are in the same menu.

## Build

Needs git, cmake, ninja and [uv](https://docs.astral.sh/uv/) (Zig, the cross compiler, is fetched from PyPI):

```sh
scripts/build.sh
```

This builds `llama-completion` for 32-bit ARM hard-float (`arm-linux-musleabihf`, statically linked, so it doesn't depend on the Kindle's libc), downloads GPT-2 from Hugging Face, converts it to GGUF and quantizes it to Q4_0. Both land in `gpt2.koplugin/`.

## Install

On a jailbroken Kindle with KOReader, start KOReader's SSH server (Tools → Network → SSH server) with your key in `koreader/settings/SSH/authorized_keys`, then:

```sh
scripts/install.sh KINDLE_IP        # port 2222 unless given
```

Or copy the `gpt2.koplugin` folder into `koreader/plugins/` over USB. Restart KOReader.

## Notes

- **Memory.** A Kindle Scribe has 964 MB of RAM but only ~240 MB free with KOReader open. Q4_0 (85 MB) fits; Q8_0 (137 MB) thrashes and drops to one token every few seconds.
- **CPU target.** The Scribe's cores are Cortex-A53, but the userland is 32-bit, and targeting `cortex_a53` in 32-bit mode makes the compiler define NEON intrinsics that ggml also defines for ARMv7. The build targets `cortex_a7` (ARMv7 + NEON + VFPv4).
- **Converter patch.** `patches/llama-gpt2-convert.patch` fixes llama.cpp's GPT-2 converter (at the pinned commit), which tried to map the attention mask buffers it means to skip.
- GPT-2 is a 2019 base model: fluent, not instruction-following.
