# Backend — standalone X-VC GPU server

Everything needed to stand up the X-VC streaming server on a fresh GPU box, extracted
from the working Hear-Me-Out deployment (Ubuntu 22.04, CUDA). The server to build is a
**trimmed copy** of `docs/reference/hearmeout-xvc-server.py`: keep `load-target` +
`stream`, drop `chat-proxy` (and with it the sphn/Opus + PersonaPlex code), add
bearer-token auth (see `docs/PROTOCOL.md` §3).

## 1. X-VC source (run from source, not packaged)

```
git clone https://github.com/Jerrister/X-VC.git
cd X-VC && git checkout 49df8c591eafc48b096e466d96f9839f9c0dd739
mkdir -p ckpts pretrained
```

The server imports X-VC's official inference code by putting the repo on `sys.path`
(env `XVC_DIR`) and must run **with the X-VC repo as cwd** (it uses relative
`pretrained/` paths). Imports used:

```python
from bins.infer_utils import load_xvc, precompute_conditions, run_stream_chunk_forward
from models.codec.sac.utils import process_audio
from utils.audio import audio_highpass_filter
```

## 2. Model assets (three downloads)

| Asset | Source | Destination |
|---|---|---|
| main checkpoint `xvc.pt` | Hugging Face repo **`chenxie95/X-VC`**, file `xvc.pt` (via `hf_hub_download`) | `$XVC_DIR/ckpts/xvc.pt` |
| semantic tokenizer | HF **`zai-org/glm-4-voice-tokenizer`** (`snapshot_download`, stays in HF cache) | HF cache |
| speaker encoder (ERes2Net) | **ModelScope** `iic/speech_eres2net_sv_en_voxceleb_16k` (`modelscope.snapshot_download`, then copy) | `$XVC_DIR/pretrained/speech_eres2net_sv_en_voxceleb_16k/` |

Working download snippets (verbatim from the proven setup script):

```python
# xvc.pt
from huggingface_hub import hf_hub_download; import shutil
shutil.copy(hf_hub_download('chenxie95/X-VC', 'xvc.pt'), f'{XVC_DIR}/ckpts/xvc.pt')

# glm tokenizer (pre-cache; otherwise fetched at first run)
from huggingface_hub import snapshot_download
snapshot_download('zai-org/glm-4-voice-tokenizer')

# ERes2Net
import os, shutil
from modelscope import snapshot_download
p = snapshot_download('iic/speech_eres2net_sv_en_voxceleb_16k')
dst = f'{XVC_DIR}/pretrained/speech_eres2net_sv_en_voxceleb_16k'
os.makedirs(dst, exist_ok=True)
for n in os.listdir(p):
    s = os.path.join(p, n); d = os.path.join(dst, n)
    shutil.copytree(s, d, dirs_exist_ok=True) if os.path.isdir(s) else shutil.copy(s, d)
```

## 3. Python environment

**Python 3.10 only** (`requires-python = ">=3.10,<3.11"`). torch/torchvision/torchaudio
come from the **cu121** index (`https://download.pytorch.org/whl/cu121`). Use `uv`.

Full pin list (proven-compatible with the pinned X-VC commit):

```toml
requires-python = ">=3.10,<3.11"
dependencies = [
    # From X-VC requirements.txt (pinned).
    "torch==2.5.1",
    "torchvision==0.20.1",
    "torchaudio==2.5.1",
    "transformers==4.44.1",
    "deepspeed==0.14.4",
    "einops==0.8.0",
    "einx==0.3.0",
    "x-transformers==1.40.2",
    "hydra-core==1.3.2",
    "julius==0.2.7",
    "librosa==0.10.2",
    "matplotlib==3.7.5",
    "numpy==1.26.4",
    "omegaconf==2.3.0",
    "scipy==1.12.0",
    "soundfile==0.12.1",
    "soxr==0.3.7",
    "tqdm==4.66.5",
    "wandb==0.18.5",
    "torchmetrics==1.8.0",
    "torchcrepe==0.0.23",
    "ema-pytorch==0.7.7",
    "packaging==24.2",
    "lightning==2.2.4",
    "gdown==5.1.0",
    "tensorboard==2.20.0",
    "descript-audiotools==0.7.2",
    # Server deps.
    "aiohttp>=3.10",
    "huggingface-hub",
    "modelscope",
]

[[tool.uv.index]]
name = "pytorch-cu121"
url = "https://download.pytorch.org/whl/cu121"
explicit = true

[tool.uv.sources]
torch = { index = "pytorch-cu121" }
torchvision = { index = "pytorch-cu121" }
torchaudio = { index = "pytorch-cu121" }
```

Notes:
- `pesq` (X-VC eval-only) is deliberately omitted — Cython ext needing `python3.10-dev`;
  the streaming path doesn't use it.
- The Hear-Me-Out server also pins `sphn>=0.1.4,<0.2` for Opus — **only needed by
  `chat-proxy`**, which this project drops. Leave it out unless Opus transport is added
  later (and if so, stay `<0.2`: 0.2 removed `OpusStreamWriter.read_bytes`).

## 4. Server environment variables

| Var | Default | Meaning |
|---|---|---|
| `XVC_DIR` | cwd | path to the cloned X-VC repo (added to `sys.path`; must also be cwd) |
| `XVC_CONFIG` | `$XVC_DIR/configs/xvc.yaml` | model config |
| `XVC_CKPT` | `$XVC_DIR/ckpts/xvc.pt` | checkpoint |
| `XVC_DEVICE` | `0` | CUDA device index |
| `XVC_EMA_LOAD` | `1` | load EMA weights |
| `XVC_CHUNK_MS` | `2400` | full window size (history+current+smooth+future) |
| `XVC_CURRENT_MS` | `120` | emitted audio per window — **main throughput/latency lever** |
| `XVC_SMOOTH_MS` | `20` | cross-fade overlap |
| `XVC_FUTURE_MS` | `100` | look-ahead |
| `MEANVC_PORT` | `5002` | listen port |
| `SSL_DIR` | `/app/ssl` | dir with `cert.pem`/`key.pem`; if present the server serves wss/https |
| `XVC_AUTH_TOKEN` | — | **new in this project**: bearer token required on all endpoints |

Constraint enforced by the session driver: `CHUNK_MS - CURRENT_MS - SMOOTH_MS - FUTURE_MS >= 0`.

Model-derived runtime values (read from `configs/xvc.yaml` at startup): `sample_rate`
(16000), `highpass_cutoff_freq`, `dataloader.mask_target_condition` (when true,
`load-target` pads the target with 2.4 s of silence before `precompute_conditions` —
keep this behavior, it matches training).

## 5. How the streaming session works (port this, don't reinvent)

`XVCStreamSession` in the reference file is the heart of the server. Per window `i`:

- window `[i*current - history, i*current + current + smooth + future]` is cut from the
  live input buffer (left-padded with zeros at stream start — no 2.4 s warm-up wait);
- `run_stream_chunk_forward(model, window, spk_cond, frame_cond)` converts it;
- only the "current" region is emitted, cross-faded with the previous window's tail
  over `smooth_ms` (raised-cosine `fade_in`/`fade_out`, `tail_buffer` carried across
  windows — the only inter-window state);
- speaker/frame conditions are **precomputed once per target** at `load-target`
  (`precompute_conditions`) and shared read-only across sessions.

GPU work runs in a thread executor (`loop.run_in_executor(None, session.feed, pcm)`) so
the event loop keeps serving frames — keep that pattern.

## 6. Reference deployment shape (Hear-Me-Out, for orientation)

- the KTH GPU box, Docker container, ports published directly on the host
  IP (no nginx/domain), self-signed TLS generated at launch
  (`openssl req -x509 ... -subj "/CN=*"`).
- X-VC service launched as:
  `( cd "$XVC_DIR" && uv run --project <xvc-project> python server.py )`
- That box is **shared** with other GPU services (PersonaPlex dialogue model) — one of
  the reasons for this project's dedicated box. When sizing the new box, see
  `docs/PERFORMANCE.md`.

## 7. setup.sh to write (one command, fresh Ubuntu 22.04 + NVIDIA driver)

1. Install `uv` if missing; `apt-get install -y ffmpeg` (librosa/audiotools runtime).
2. Clone X-VC at the pinned commit; `mkdir ckpts pretrained`.
3. `uv sync` the project env (pins above).
4. Run the three model downloads (§2), idempotently (skip if files exist).
5. Generate self-signed certs into `$SSL_DIR` if none provided.
6. Print the launch command + a systemd unit (or `tmux`) example with the env table (§4)
   and a generated `XVC_AUTH_TOKEN`.
7. Finish by running the Phase-0 benchmark (see `docs/PERFORMANCE.md`) and printing the
   per-window forward time verdict.
