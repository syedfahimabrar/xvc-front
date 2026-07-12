#!/usr/bin/env python3
"""Fetch X-VC's three model assets into $XVC_DIR. Idempotent — safe to re-run.

Snippets are verbatim from the README (the proven setup script).
"""
import os
import shutil
import sys

XVC_DIR = os.environ.get("XVC_DIR")
if not XVC_DIR:
    sys.exit("error: set XVC_DIR to the cloned X-VC repo")

ckpt = os.path.join(XVC_DIR, "ckpts", "xvc.pt")
eres2net = os.path.join(XVC_DIR, "pretrained", "speech_eres2net_sv_en_voxceleb_16k")

if os.path.exists(ckpt):
    print(f"[models] checkpoint present: {ckpt}")
else:
    print("[models] downloading xvc.pt (~1 GB) from chenxie95/X-VC ...")
    from huggingface_hub import hf_hub_download

    os.makedirs(os.path.dirname(ckpt), exist_ok=True)
    shutil.copy(hf_hub_download("chenxie95/X-VC", "xvc.pt"), ckpt)
    print(f"[models] wrote {ckpt}")

# Lives in the HF cache; snapshot_download is itself a no-op once cached. Pre-caching
# keeps it off the first inference's critical path.
print("[models] ensuring glm-4-voice-tokenizer is cached ...")
from huggingface_hub import snapshot_download  # noqa: E402

snapshot_download("zai-org/glm-4-voice-tokenizer")

if os.path.isdir(eres2net) and os.listdir(eres2net):
    print(f"[models] speaker encoder present: {eres2net}")
else:
    print("[models] downloading ERes2Net speaker encoder from ModelScope ...")
    from modelscope import snapshot_download as ms_snapshot_download

    src = ms_snapshot_download("iic/speech_eres2net_sv_en_voxceleb_16k")
    os.makedirs(eres2net, exist_ok=True)
    for name in os.listdir(src):
        s, d = os.path.join(src, name), os.path.join(eres2net, name)
        shutil.copytree(s, d, dirs_exist_ok=True) if os.path.isdir(s) else shutil.copy(s, d)
    print(f"[models] wrote {eres2net}")

print("[models] all assets ready")
