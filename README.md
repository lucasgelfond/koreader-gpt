# koreader-gpt

Run GPT-2 on a KOReader-jailbroken Kindle.

<img src="docs/demo.gif" alt="GPT-2 writing on a Kindle Scribe" width="440">

This plugin lets you run GPT-2 inference on a Kindle. Tested on my Kindle Scribe, running ~13 tok/sec at 4-bit quantization.

Can open this on a highlight (tap highlighted text --> Continue with GPT-2) or as a standalone chat (Tools --> GPT-2 --> Write from a prompt).

To install, first use another tutorial to install KOReader on the Kindle. Then, start KOReader's SSH server first without password protection. Basically, click Tools --> Network --> SSH Server --> click "Login without password (DANGEROUS)" and then enable the SSH server. When on your laptop, find the device, and add your laptop's public key to the `koreader/settings/SSH/authorized_keys` path. Then turn off the SSH server on the Kindle, uncheck "Login without password", check "Login with key only", and then turn the SSH server back on.

After that, simply run `scripts/install.sh` to install the plugin. It should be

```
scripts/install.sh KINDLE_IP # port 2222 unless changed
```

You can also copy the `gpt2.koplugin` into `koreader/plugins` over USB but that's more annoying.

Once you've installed you'll need to restart KOReader to see the changes (right corner hamburger menu --> Exit --> Restart KOReader).
