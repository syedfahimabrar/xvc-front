#!/usr/bin/env python3
"""Phase-0 benchmark: can this GPU run X-VC streaming conversion in real time?

Times `run_stream_chunk_forward` over one CHUNK_MS window, exactly as the streaming
server calls it (see docs/reference/hearmeout-xvc-server.py, XVCStreamSession._forward).

The number that decides the product:

    per-window forward time  <  CURRENT_MS

because the server must finish converting window i before window i+1's audio has
accumulated. If it is even slightly over, delay grows for as long as the user keeps
talking. See the README

Per-window cost is set by CHUNK_MS (the fixed 2.4 s context the model runs over), not
by CURRENT_MS. CURRENT_MS only decides how often a window runs. So we time each
CHUNK_MS once and report the resulting GPU load fraction (p95 / CURRENT_MS) for every
candidate CURRENT_MS -- that is what tuning lever 1 buys.

Must run with the X-VC repo as cwd (it uses relative pretrained/ paths):

    cd "$XVC_DIR" && uv run --project <this-project> python server/bench.py

Examples:
    python bench.py                                  # defaults, 2.4 s window, fp32
    python bench.py --target-wav voice.wav           # real target speaker
    python bench.py --sweep                          # levers 1-3 results table
    python bench.py --dtype bf16 --dump-wav out.wav --source-wav speech.wav
"""
import argparse
import contextlib
import json
import os
import sys
import tempfile
import time
import wave

import numpy as np
import torch

# --- make the X-VC repo importable (same contract as the server) -------------
XVC_DIR = os.environ.get("XVC_DIR", os.getcwd())
if XVC_DIR not in sys.path:
    sys.path.insert(0, XVC_DIR)

from bins.infer_utils import (  # noqa: E402  (import after sys.path setup)
    load_xvc,
    precompute_conditions,
    run_stream_chunk_forward,
)
from models.codec.sac.utils import process_audio  # noqa: E402

DTYPES = {"fp32": None, "bf16": torch.bfloat16, "fp16": torch.float16}


# --- audio helpers -----------------------------------------------------------


def write_wav(path: str, pcm: np.ndarray, sr: int) -> None:
    ints = (np.clip(pcm, -1.0, 1.0) * 32767.0).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(ints.tobytes())


def read_wav_mono(path: str) -> tuple[np.ndarray, int]:
    with wave.open(path, "rb") as w:
        sr, n_ch, width = w.getframerate(), w.getnchannels(), w.getsampwidth()
        if width != 2:
            raise SystemExit(f"{path}: only 16-bit PCM WAV supported, got {width * 8}-bit")
        raw = w.readframes(w.getnframes())
    pcm = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    if n_ch > 1:
        pcm = pcm.reshape(-1, n_ch).mean(axis=1)
    return pcm, sr


def synth_voice_wav(path: str, sr: int, seconds: float = 6.0) -> None:
    """A voiced-speech-ish signal, for when no target WAV is supplied.

    Timing is data-independent (the model has no dynamic shapes or early exits), so
    this is fine for benchmarking. It is NOT a real voice -- the speaker embedding it
    produces is meaningless, so never judge conversion quality from it.
    """
    t = np.arange(int(sr * seconds)) / sr
    f0 = 110.0 + 20.0 * np.sin(2 * np.pi * 0.7 * t)
    phase = 2 * np.pi * np.cumsum(f0) / sr
    sig = np.zeros_like(t)
    for k in range(1, 12):
        sig += np.sin(k * phase) / k
    sig *= 0.2 + 0.8 * (0.5 * (1 + np.sin(2 * np.pi * 3.1 * t)))  # syllable envelope
    sig += 0.01 * np.random.randn(t.size)
    write_wav(path, (0.3 * sig / np.abs(sig).max()).astype(np.float32), sr)


# --- model setup -------------------------------------------------------------


def build_conditions(model, cfg, device, sr, target_wav_path, mask_target_condition):
    """Precompute speaker + frame conditions, exactly as load-target does."""
    target_np = process_audio(target_wav_path, cfg, int(cfg["latent_hop_length"]))
    target_wav = torch.from_numpy(target_np)[None, None].float().to(device)
    if mask_target_condition:
        pad = torch.zeros((1, 1, int(2.4 * sr)), device=device)
        target_wav_cond = torch.cat([target_wav, pad], dim=-1)
    else:
        target_wav_cond = target_wav
    return precompute_conditions(model, target_wav, target_wav_cond)


def make_window(chunk_ms: int, sr: int, device, source_wav: str | None) -> torch.Tensor:
    n = chunk_ms * sr // 1000
    if source_wav:
        pcm, src_sr = read_wav_mono(source_wav)
        if src_sr != sr:
            raise SystemExit(f"--source-wav must be {sr} Hz, got {src_sr} Hz")
        if pcm.size < n:
            pcm = np.pad(pcm, (0, n - pcm.size))
        start = max(0, (pcm.size - n) // 2)  # middle slice: most likely to be speech
        seg = pcm[start : start + n]
    else:
        seg = 0.1 * np.random.randn(n).astype(np.float32)
    return torch.from_numpy(np.ascontiguousarray(seg))[None, None].float().to(device)


# --- timing ------------------------------------------------------------------


def autocast_ctx(dtype):
    return torch.autocast("cuda", dtype=dtype) if dtype is not None else contextlib.nullcontext()


@torch.inference_mode()
def time_forward(model, win, spk, frame, dtype, iters: int, warmup: int) -> list[float]:
    """Wall-clock ms per forward, GPU-synchronized on both sides."""
    times: list[float] = []
    for i in range(warmup + iters):
        torch.cuda.synchronize()
        t0 = time.perf_counter()
        with autocast_ctx(dtype):
            run_stream_chunk_forward(model, win, spk, frame)
        torch.cuda.synchronize()
        dt = (time.perf_counter() - t0) * 1000.0
        if i >= warmup:
            times.append(dt)
    return times


def verdict(p95_ms: float, current_ms: int) -> str:
    """the README, generalized past the CURRENT_MS=120 default."""
    load = p95_ms / current_ms
    if load < 0.67:
        return "comfortable"
    if load <= 1.0:
        return "fragile"
    return "CANNOT KEEP UP"


# --- offline streaming pass (for A/B listening after a tuning change) ---------


@torch.inference_mode()
def stream_convert(model, src, spk, frame, sr, chunk_ms, current_ms, smooth_ms, future_ms,
                   device, dtype) -> np.ndarray:
    """Mirror of XVCStreamSession over a complete source array, for --dump-wav.

    Levers 2 and 3 (shorter CHUNK_MS, fp16/bf16) trade quality for speed. The only
    honest test is listening, so make it easy to produce the file to listen to.
    """
    history_ms = chunk_ms - current_ms - smooth_ms - future_ms
    overlap = smooth_ms * sr // 1000
    if overlap > 0:
        fade_in = 0.5 * (1 - torch.cos(torch.pi * torch.linspace(0, 1, overlap, device=device)))
        fade_out = 1 - fade_in
        tail = torch.zeros(1, 1, overlap, device=device)
    outs, i = [], 0
    while True:
        start = (i * current_ms - history_ms) * sr // 1000
        end = (i * current_ms + current_ms + smooth_ms + future_ms) * sr // 1000
        if src.size < end:
            break
        seg = src[max(0, start) : end]
        if start < 0:
            seg = np.concatenate([np.zeros(-start, dtype=np.float32), seg])
        win = torch.from_numpy(np.ascontiguousarray(seg))[None, None].float().to(device)
        with autocast_ctx(dtype):
            out = run_stream_chunk_forward(model, win, spk, frame).float()
        cur = out[:, :, history_ms * sr // 1000 : (history_ms + current_ms) * sr // 1000]
        if overlap > 0:
            if i > 0:
                head = tail * fade_out + cur[..., :overlap] * fade_in
                cur = torch.cat([head, cur[..., overlap:]], dim=-1)
            tail_start = (history_ms + current_ms) * sr // 1000
            tail = out[:, :, tail_start : tail_start + overlap]
        outs.append(cur.squeeze().cpu().numpy().astype(np.float32))
        i += 1
    return np.concatenate(outs) if outs else np.zeros(0, dtype=np.float32)


# --- reporting ---------------------------------------------------------------


def print_table(rows, current_candidates):
    head = ["chunk_ms", "dtype", "p50 ms", "p95 ms", "peak VRAM"]
    head += [f"load @ {c} ms" for c in current_candidates]
    head += ["verdict @ default"]
    widths = [len(h) for h in head]
    body = []
    for r in rows:
        cells = [
            str(r["chunk_ms"]),
            r["dtype"],
            f"{r['p50_ms']:.1f}",
            f"{r['p95_ms']:.1f}",
            f"{r['peak_vram_gb']:.1f} GB",
        ]
        cells += [f"{r['p95_ms'] / c:.2f}x" for c in current_candidates]
        cells += [r["verdict"]]
        widths = [max(w, len(c)) for w, c in zip(widths, cells)]
        body.append(cells)
    fmt = lambda cs: "| " + " | ".join(c.ljust(w) for c, w in zip(cs, widths)) + " |"  # noqa: E731
    print(fmt(head))
    print("|" + "|".join("-" * (w + 2) for w in widths) + "|")
    for cells in body:
        print(fmt(cells))


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--config", default=os.environ.get("XVC_CONFIG", os.path.join(XVC_DIR, "configs/xvc.yaml")))
    p.add_argument("--ckpt", default=os.environ.get("XVC_CKPT", os.path.join(XVC_DIR, "ckpts/xvc.pt")))
    p.add_argument("--device", type=int, default=int(os.environ.get("XVC_DEVICE", 0)))
    p.add_argument("--no-ema", action="store_true", help="skip EMA weights (server loads them)")
    p.add_argument("--chunk-ms", type=int, default=int(os.environ.get("XVC_CHUNK_MS", 2400)))
    p.add_argument("--current-ms", type=int, default=int(os.environ.get("XVC_CURRENT_MS", 120)))
    p.add_argument("--smooth-ms", type=int, default=int(os.environ.get("XVC_SMOOTH_MS", 20)))
    p.add_argument("--future-ms", type=int, default=int(os.environ.get("XVC_FUTURE_MS", 100)))
    p.add_argument("--dtype", choices=list(DTYPES), default="fp32", help="autocast dtype (lever 3)")
    p.add_argument("--tf32", action="store_true", help="allow TF32 matmuls (free on Ampere+)")
    p.add_argument("--iters", type=int, default=50)
    p.add_argument("--warmup", type=int, default=5)
    p.add_argument("--target-wav", help="target speaker WAV; synthesized if omitted")
    p.add_argument("--source-wav", help="16 kHz source speech WAV; noise if omitted")
    p.add_argument("--sweep", action="store_true", help="grid over --sweep-chunk-ms x --sweep-dtypes")
    p.add_argument("--sweep-chunk-ms", default="2400,1600", help="comma-separated (lever 2)")
    p.add_argument("--sweep-dtypes", default="fp32,bf16", help="comma-separated (lever 3)")
    p.add_argument("--dump-wav", help="also stream --source-wav through and write the result here")
    p.add_argument("--json", help="write raw results to this path")
    args = p.parse_args()

    if not torch.cuda.is_available():
        print("error: X-VC requires a CUDA GPU. Run this on the GPU box, not the Mac.", file=sys.stderr)
        return 1

    if args.tf32:
        torch.backends.cuda.matmul.allow_tf32 = True
        torch.backends.cudnn.allow_tf32 = True

    chunk_list = [int(c) for c in args.sweep_chunk_ms.split(",")] if args.sweep else [args.chunk_ms]
    dtype_list = args.sweep_dtypes.split(",") if args.sweep else [args.dtype]
    for name in dtype_list:
        if name not in DTYPES:
            raise SystemExit(f"unknown dtype {name!r}; pick from {list(DTYPES)}")

    tail_ms = args.current_ms + args.smooth_ms + args.future_ms
    for chunk_ms in chunk_list:
        if chunk_ms - tail_ms < 0:
            raise SystemExit(
                f"chunk_ms={chunk_ms} leaves negative history: it must be >= "
                f"current+smooth+future = {tail_ms} ms"
            )

    print(f"[bench] loading model: config={args.config} ckpt={args.ckpt} device=cuda:{args.device}")
    cfg, model, device = load_xvc(args.config, args.ckpt, args.device, not args.no_ema)
    sr = int(cfg["sample_rate"])
    mask_target_condition = bool(cfg.get("dataloader", {}).get("mask_target_condition", True))

    with tempfile.TemporaryDirectory() as tmp:
        target_wav = args.target_wav
        if not target_wav:
            target_wav = os.path.join(tmp, "synth_target.wav")
            synth_voice_wav(target_wav, sr)
            print("[bench] no --target-wav: using a synthetic tone (timing is data-independent)")
        spk, frame = build_conditions(model, cfg, device, sr, target_wav, mask_target_condition)

        gpu = torch.cuda.get_device_name(args.device)
        print(f"[bench] gpu={gpu} torch={torch.__version__} cuda={torch.version.cuda} tf32={args.tf32}")
        print(f"[bench] {args.iters} iters + {args.warmup} warmup, history={args.chunk_ms - tail_ms} ms\n")

        rows = []
        for chunk_ms in chunk_list:
            win = make_window(chunk_ms, sr, device, args.source_wav)
            for dtype_name in dtype_list:
                torch.cuda.reset_peak_memory_stats(args.device)
                times = time_forward(model, win, spk, frame, DTYPES[dtype_name], args.iters, args.warmup)
                p50, p95 = float(np.percentile(times, 50)), float(np.percentile(times, 95))
                rows.append({
                    "chunk_ms": chunk_ms,
                    "dtype": dtype_name,
                    "p50_ms": p50,
                    "p95_ms": p95,
                    "mean_ms": float(np.mean(times)),
                    "max_ms": float(np.max(times)),
                    "peak_vram_gb": torch.cuda.max_memory_allocated(args.device) / 2**30,
                    "verdict": verdict(p95, args.current_ms),
                })

        current_candidates = sorted({args.current_ms, 120, 240})
        print_table(rows, current_candidates)
        print(
            f"\nload = p95 / CURRENT_MS: the fraction of real time the GPU is busy.\n"
            f"  < 0.67x  comfortable    0.67-1.0x  fragile (delay grows under bursts)"
            f"    > 1.0x  cannot keep up\n"
            f"'verdict' column uses the configured CURRENT_MS={args.current_ms} ms."
        )

        best = min(rows, key=lambda r: r["p95_ms"])
        if best["verdict"] == "CANNOT KEEP UP":
            print("\n=> Phase-0 gate FAILED at every setting tried. Raise CURRENT_MS (lever 1, "
                  "+120 ms latency), then shrink CHUNK_MS (lever 2), else use a faster GPU.")
        elif best["p95_ms"] >= 100:
            print("\n=> Phase-0 gate is p95 < 100 ms. Best here is "
                  f"{best['p95_ms']:.1f} ms -- apply a lever before Phase 1.")
        else:
            print(f"\n=> Phase-0 gate PASSED: best p95 {best['p95_ms']:.1f} ms "
                  f"(chunk_ms={best['chunk_ms']}, {best['dtype']}).")
        print("Record the table in the README. Levers 2 and 3 change the audio: "
              "confirm with --dump-wav before adopting.")

        if args.dump_wav:
            if not args.source_wav:
                raise SystemExit("--dump-wav needs --source-wav (a real 16 kHz speech file)")
            src, src_sr = read_wav_mono(args.source_wav)
            if src_sr != sr:
                raise SystemExit(f"--source-wav must be {sr} Hz, got {src_sr} Hz")
            out = stream_convert(model, src, spk, frame, sr, args.chunk_ms, args.current_ms,
                                 args.smooth_ms, args.future_ms, device, DTYPES[args.dtype])
            write_wav(args.dump_wav, out, sr)
            print(f"\n[bench] wrote {len(out) / sr:.1f}s of converted audio to {args.dump_wav}")
            if not args.target_wav:
                print("[bench] warning: target was synthetic, so this audio is not a real voice")

        if args.json:
            with open(args.json, "w") as f:
                json.dump({
                    "gpu": gpu,
                    "torch": torch.__version__,
                    "cuda": torch.version.cuda,
                    "tf32": args.tf32,
                    "sample_rate": sr,
                    "current_ms": args.current_ms,
                    "smooth_ms": args.smooth_ms,
                    "future_ms": args.future_ms,
                    "iters": args.iters,
                    "results": rows,
                }, f, indent=2)
            print(f"[bench] wrote {args.json}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
