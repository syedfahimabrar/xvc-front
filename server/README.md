# server/

The X-VC GPU server and its tooling. Nothing here runs on the Mac — X-VC needs CUDA.

| File | Phase | What it is |
|---|---|---|
| `bootstrap.sh` | 0 | get a fresh GPU box to where `bench.py` can run (BACKEND.md §§1–3) |
| `download_models.py` | 0 | the three model assets, idempotent (BACKEND.md §2) |
| `pyproject.toml` | 0 | pinned env, shared by benchmark and server (BACKEND.md §3) |
| `bench.py` | 0 | per-window forward-time benchmark; decides whether a GPU can keep up |
| `xvc_server.py` | 3 | trimmed streaming server (`load-target` + `stream` + token auth + startup warm-up) |
| `setup.sh` | 3 | one-command provisioning, superset of `bootstrap.sh` |

## Standing up the dedicated server (Phase 3)

On a fresh Ubuntu 22.04 box with an NVIDIA driver:

```bash
XVC_DIR=~/X-VC ./setup.sh          # env + models + TLS cert + token + systemd unit + bench
sudo systemctl enable --now xvc-server
journalctl -u xvc-server -f        # wait for "[xvc] warmed up"
```

`setup.sh` generates a self-signed cert (prints its SHA-256 to pin) and an auth token in
`~/xvc-token`. Give the token to clients as `XVC_TOKEN`; point them at the box with
`XVC_HOST`. A DNS name in `XVC_PUBLIC_HOST` makes it try Let's Encrypt instead.

The server **warms the model at startup** (one full conversion of noise) before accepting
connections — otherwise the first user pays the ~2.4 s lazy-init cost as mangled audio
(`docs/BENCHMARKS.md`). Auth is enforced only when `XVC_AUTH_TOKEN` is set; unset means the
server runs open and logs a warning.

## Running the Phase-0 benchmark

On a fresh Ubuntu 22.04 box with an NVIDIA driver (`nvidia-smi` works):

```bash
XVC_DIR=~/X-VC ./bootstrap.sh
```

That clones X-VC at the pinned commit, syncs the env, and fetches the model assets
(~6 GB total, mostly torch + `xvc.pt`). It prints the benchmark command when it's done.

The benchmark imports X-VC's own inference code and must run **with the X-VC repo as
cwd** — X-VC resolves `pretrained/` relatively:

```bash
cd ~/X-VC
XVC_DIR=~/X-VC uv run --project /path/to/xvc-live-mic/server \
    python /path/to/xvc-live-mic/server/bench.py
```

Useful flags:

```bash
# Full lever sweep (CHUNK_MS x dtype) -> the table for docs/BENCHMARKS.md
python bench.py --sweep --tf32 --json bench.json

# Real voices. Without these, timing is still valid but the audio is meaningless.
python bench.py --target-wav target.wav --source-wav speech16k.wav

# A/B a tuning change by ear before adopting it (levers 2 and 3 alter the audio)
python bench.py --dtype bf16 --target-wav t.wav --source-wav s.wav --dump-wav bf16.wav
```

`--source-wav` must be 16 kHz 16-bit mono; `--target-wav` is resampled by X-VC itself.

## Reading the result

The gate is **p95 per-window < 100 ms**, but the number that actually governs the
product is the load fraction `p95 / CURRENT_MS` — the share of real time the GPU is
busy. Above 1.0 the server falls a little further behind on every window, so delay
grows the longer someone talks. `bench.py` prints the fraction for `CURRENT_MS` of 120
(default) and 240 (lever 1) side by side.

Per-window cost is set by `CHUNK_MS`, the fixed 2.4 s context; `CURRENT_MS` only sets
how often a window runs. That is why raising `CURRENT_MS` to 240 nearly halves GPU
load for +120 ms of latency, and why the sweep varies `CHUNK_MS` rather than
`CURRENT_MS`.

Tuning levers, in order, live in `docs/PERFORMANCE.md` §3. Levers 2 (shorter
`CHUNK_MS`) and 3 (fp16/bf16) trade quality for speed — always listen to `--dump-wav`
output before adopting one. Lever 3's `torch.compile` half is not covered here: it
needs the compile applied inside X-VC's converter/decoder modules, so measure it with
this script after making that change.

Record every run in `docs/BENCHMARKS.md`.
