#!/usr/bin/env python3
"""Phase-0 benchmark on Apple Silicon: can an M-series GPU run X-VC in real time?

Same measurement as server/bench.py (time run_stream_chunk_forward over one CHUNK_MS
window, p50/p95 after warm-up), with the CUDA specifics swapped for MPS. The verdict
threshold is identical: per-window p95 must be < CURRENT_MS (120 ms) or delay grows for
as long as the user talks.

Run with PYTORCH_ENABLE_MPS_FALLBACK=1 so ops MPS lacks fall back to CPU (slower but
honest: that is what a shipped Mac build would do).
"""
import argparse
import os
import sys
import time
import wave

import numpy as np
import torch

XVC_DIR = os.environ["XVC_DIR"]
if XVC_DIR not in sys.path:
    sys.path.insert(0, XVC_DIR)
os.chdir(XVC_DIR)  # X-VC resolves pretrained/ relatively

import bins.infer_utils as iu  # noqa: E402
from models.codec.sac.utils import process_audio  # noqa: E402


def synth_voice_wav(path: str, sr: int, seconds: float = 6.0) -> None:
    t = np.arange(int(sr * seconds)) / sr
    f0 = 110.0 + 20.0 * np.sin(2 * np.pi * 0.7 * t)
    phase = 2 * np.pi * np.cumsum(f0) / sr
    sig = np.zeros_like(t)
    for k in range(1, 12):
        sig += np.sin(k * phase) / k
    sig *= 0.2 + 0.8 * (0.5 * (1 + np.sin(2 * np.pi * 3.1 * t)))
    sig += 0.01 * np.random.randn(t.size)
    pcm = (0.3 * sig / np.abs(sig).max()).astype(np.float32)
    ints = (np.clip(pcm, -1, 1) * 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
        w.writeframes(ints.tobytes())


def sync(device: torch.device) -> None:
    if device.type == "mps":
        torch.mps.synchronize()


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--device", choices=["mps", "cpu"], default="mps")
    p.add_argument("--chunk-ms", type=int, default=2400)
    p.add_argument("--current-ms", type=int, default=120)
    p.add_argument("--iters", type=int, default=20)
    p.add_argument("--warmup", type=int, default=5)
    args = p.parse_args()

    device = torch.device(args.device)
    iu._to_device = lambda _i: device  # the only CUDA assumption in the load path

    print(f"[mps-bench] loading model on {device} ...")
    t0 = time.time()
    cfg, model, dev = iu.load_xvc(
        os.path.join(XVC_DIR, "configs/xvc.yaml"),
        os.path.join(XVC_DIR, "ckpts/xvc.pt"),
        0, True)
    print(f"[mps-bench] loaded in {time.time()-t0:.1f}s on {dev}")
    sr = int(cfg["sample_rate"])

    target = "/tmp/mps_target.wav"
    synth_voice_wav(target, sr)
    target_np = process_audio(target, cfg, int(cfg["latent_hop_length"]))
    target_wav = torch.from_numpy(target_np)[None, None].float().to(device)
    if bool(cfg.get("dataloader", {}).get("mask_target_condition", True)):
        pad = torch.zeros((1, 1, int(2.4 * sr)), device=device)
        target_cond = torch.cat([target_wav, pad], dim=-1)
    else:
        target_cond = target_wav
    t0 = time.time()
    spk, frame = iu.precompute_conditions(model, target_wav, target_cond)
    sync(device)
    print(f"[mps-bench] precompute_conditions (= load-target cost): {time.time()-t0:.1f}s")

    n = args.chunk_ms * sr // 1000
    win = torch.from_numpy(0.1 * np.random.randn(n).astype(np.float32))[None, None].to(device)

    times = []
    with torch.inference_mode():
        for i in range(args.warmup + args.iters):
            sync(device)
            t0 = time.perf_counter()
            iu.run_stream_chunk_forward(model, win, spk, frame)
            sync(device)
            dt = (time.perf_counter() - t0) * 1000
            if i >= args.warmup:
                times.append(dt)
            label = "warm" if i < args.warmup else "iter"
            print(f"  {label} {i:2d}  {dt:7.1f} ms", flush=True)

    p50, p95 = np.percentile(times, 50), np.percentile(times, 95)
    print(f"\n[mps-bench] {args.device} p50 {p50:.1f} ms  p95 {p95:.1f} ms  "
          f"(budget: < {args.current_ms} ms; load {p95/args.current_ms:.2f}x)")
    if device.type == "mps":
        print(f"[mps-bench] mps allocated: {torch.mps.current_allocated_memory()/2**30:.2f} GB "
              f"(driver {torch.mps.driver_allocated_memory()/2**30:.2f} GB)")
    if p95 < args.current_ms:
        print("=> could keep up in real time on this Mac")
    else:
        print(f"=> CANNOT keep up: delay would grow ~{(p95/args.current_ms - 1)*1000:.0f} ms "
              f"per second of speech (see the README)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
