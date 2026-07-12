#!/usr/bin/env python3
"""Synthetic streaming client: feed a WAV at real-time pace, measure latency and drift.

The test the README asks for ("send a WAV at real-time pace, assert output
cadence keeps up and total drift stays ~0"), and the reference implementation of the
sample-count bookkeeping the Swift client needs.

Latency bookkeeping: the stream carries no frame IDs, but output sample k corresponds to
input sample k (the server emits the "current" region of each window in order). So we
timestamp each sent chunk, and when output sample k arrives we look up when input sample
k was sent. That difference is mic-to-ear latency minus the audio hardware at both ends.

    XVC_HOST=<gpu-box> uv run --with websockets python probe_stream.py \
        --target-wav target.wav --source-wav source.wav --out converted.wav

Dev only: this disables TLS verification, because the dev server has a self-signed cert
(the README). Never do this in the shipped app.
"""
import argparse
import asyncio
import json
import os
import ssl
import sys
import time
import urllib.request
import uuid
import wave

import numpy as np

try:
    import websockets
except ImportError:
    sys.exit("error: pip install websockets  (or: uv run --with websockets python probe_stream.py ...)")

SR = 16000


def read_wav_16k_mono(path: str) -> np.ndarray:
    with wave.open(path, "rb") as w:
        if w.getsampwidth() != 2:
            raise SystemExit(f"{path}: need 16-bit PCM")
        if w.getframerate() != SR:
            raise SystemExit(f"{path}: need {SR} Hz, got {w.getframerate()} Hz")
        pcm = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768.0
        if w.getnchannels() > 1:
            pcm = pcm.reshape(-1, w.getnchannels()).mean(axis=1)
    return pcm


def write_wav(path: str, pcm: np.ndarray, sr: int = SR) -> None:
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes((np.clip(pcm, -1, 1) * 32767).astype("<i2").tobytes())


def upload_target(base_url: str, wav_path: str, insecure: bool, token: str) -> str:
    """POST /load-target as multipart/form-data with the single field 'wav'."""
    with open(wav_path, "rb") as f:
        payload = f.read()
    boundary = uuid.uuid4().hex
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="wav"; filename="target.wav"\r\n'
        f"Content-Type: audio/wav\r\n\r\n"
    ).encode() + payload + f"\r\n--{boundary}--\r\n".encode()

    headers = {"Content-Type": f"multipart/form-data; boundary={boundary}"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(
        f"{base_url}/api/meanvc/load-target",
        data=body,
        headers=headers,
        method="POST",
    )
    ctx = ssl._create_unverified_context() if insecure else None
    with urllib.request.urlopen(req, context=ctx) as resp:
        out = json.load(resp)
    if "error" in out:
        raise SystemExit(f"load-target failed: {out['error']}")
    print(f"[probe] target_id={out['target_id']} ({out['duration_seconds']}s)")
    return out["target_id"]


async def run(args) -> int:
    src = read_wav_16k_mono(args.source_wav)
    if args.duration:
        reps = int(np.ceil(args.duration * SR / src.size))
        src = np.tile(src, reps)[: int(args.duration * SR)]
        print(f"[probe] looping source to {args.duration:.0f}s")
    scheme_http = "http" if args.no_tls else "https"
    scheme_ws = "ws" if args.no_tls else "wss"
    base = f"{scheme_http}://{args.host}:{args.port}"

    target_id = args.target_id or upload_target(base, args.target_wav, args.insecure, args.token)

    ssl_ctx = None
    if not args.no_tls:
        ssl_ctx = ssl.create_default_context()
        if args.insecure:
            ssl_ctx.check_hostname = False
            ssl_ctx.verify_mode = ssl.CERT_NONE

    # WS clients can't set request headers reliably, so the token rides in the query
    # string (the README).
    token_qs = f"&token={args.token}" if args.token else ""
    url = f"{scheme_ws}://{args.host}:{args.port}/api/meanvc/stream?target_id={target_id}&source_sr={SR}&steps=2{token_qs}"
    chunk = args.chunk_ms * SR // 1000

    async with websockets.connect(url, ssl=ssl_ctx, max_size=None) as ws:
        hello = json.loads(await ws.recv())
        if hello.get("status") != "ready":
            raise SystemExit(f"server refused the session: {hello}")
        print(f"[probe] ready: {hello}")

        send_ts: list[float] = []          # send_ts[j] = when chunk j left, monotonic
        out_frames: list[np.ndarray] = []
        lat_ms: list[tuple[float, float]] = []  # (elapsed_s, latency_ms)
        done = asyncio.Event()

        async def receiver():
            out_count = 0
            async for msg in ws:
                if isinstance(msg, str):
                    print(f"[probe] server said: {msg}")   # {"error": ...} is fatal per the README
                    break
                now = time.monotonic()
                pcm = np.frombuffer(msg, dtype="<f4")
                out_frames.append(pcm)
                out_count += pcm.size
                j = (out_count - 1) // chunk        # chunk holding the matching input sample
                if j < len(send_ts):
                    lat_ms.append(((now - send_ts[0]), (now - send_ts[j]) * 1000.0))
            done.set()

        rx = asyncio.create_task(receiver())
        t0 = time.monotonic()
        for j in range(0, len(src) // chunk):
            # Real-time pace: chunk j is "captured" by t0 + (j+1)*chunk/SR.
            target_t = t0 + (j + 1) * chunk / SR
            if (sleep := target_t - time.monotonic()) > 0:
                await asyncio.sleep(sleep)
            send_ts.append(time.monotonic())
            await ws.send(src[j * chunk : (j + 1) * chunk].astype("<f4").tobytes())

        sent_s = len(send_ts) * chunk / SR
        print(f"[probe] sent {sent_s:.1f}s of audio in {time.monotonic() - t0:.1f}s wall")

        # Drain the pipeline: look-ahead means the tail is still in flight.
        try:
            await asyncio.wait_for(asyncio.shield(done.wait()), timeout=2.0)
        except asyncio.TimeoutError:
            pass
        rx.cancel()

    if not lat_ms:
        print("[probe] no audio came back — check target_id and server logs")
        return 1

    out = np.concatenate(out_frames)
    elapsed = np.array([e for e, _ in lat_ms])
    all_lat = np.array([m for _, m in lat_ms])

    # The first forward of a session pays lazy CUDA/cuDNN init — seconds, not ms. It is
    # a real product problem (the app must pre-warm), but it is not steady-state
    # latency, so keep the two numbers apart instead of letting it poison p95.
    warm = elapsed >= args.skip_seconds
    if warm.sum() < 10:
        print(f"[probe] only {warm.sum()} frames after --skip-seconds={args.skip_seconds}; "
              f"run longer with --duration")
        return 1
    lat = all_lat[warm]
    p50, p95 = np.percentile(lat, 50), np.percentile(lat, 95)

    cold = all_lat[~warm]
    if cold.size:
        print(f"\n[probe] cold start: first frame {all_lat[0]:.0f} ms, max {cold.max():.0f} ms, "
              f"{cold.size} frames discarded from the first {args.skip_seconds:.0f}s")
    else:
        print("\n[probe] no frames in the cold-start window")

    # Drift: if the GPU can't keep up, latency climbs monotonically. Compare the first
    # and last thirds rather than fitting a line — it's the shape we care about.
    third = max(1, len(lat) // 3)
    drift = float(np.median(lat[-third:]) - np.median(lat[:third]))

    print(f"\n[probe] steady-state latency over {len(lat)} output frames ({elapsed[warm][-1]:.0f}s)")
    print(f"  p50 {p50:6.1f} ms    p95 {p95:6.1f} ms    min {lat.min():6.1f} ms    max {lat.max():6.1f} ms")
    print(f"  drift (last third - first third): {drift:+.1f} ms")
    print(f"  audio in {sent_s:.1f}s -> out {out.size / SR:.1f}s  (gap = look-ahead + tail in flight)")
    print("\n  Measured at each frame's LAST sample, which waits smooth+future = 120 ms of")
    print("  look-ahead. The frame's first sample waits the full 240 ms, so what a listener")
    print("  perceives spans roughly [p50, p50 + 120] ms, plus the client's jitter buffer.")

    if drift > 50:
        print("\n=> LATENCY IS GROWING. The server is falling behind real time; delay will")
        print("   keep climbing for as long as someone talks. See the README")
    elif p95 < 500:
        print(f"\n=> Phase-1 gate PASSED on this path: p95 {p95:.0f} ms < 500 ms, drift flat.")
    else:
        print(f"\n=> p95 {p95:.0f} ms exceeds the 500 ms gate. Check RTT and GPU load before Swift.")

    if args.out:
        write_wav(args.out, out)
        print(f"\n[probe] wrote {args.out} — listen to it: does it sound like the target speaker?")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", default=os.environ.get("XVC_HOST"),
                   help="server host; defaults to $XVC_HOST")
    p.add_argument("--port", type=int, default=5002)
    p.add_argument("--target-wav", help="target speaker WAV (uploaded via load-target)")
    p.add_argument("--target-id", help="reuse an existing target_id instead of uploading")
    p.add_argument("--source-wav", required=True, help="16 kHz 16-bit mono speech to convert")
    p.add_argument("--chunk-ms", type=int, default=20, help="send cadence, matches the Mac tap")
    p.add_argument("--duration", type=float, help="loop the source to this many seconds (gate: 120)")
    p.add_argument("--skip-seconds", type=float, default=3.0,
                   help="exclude this much of the run from stats (session cold start)")
    p.add_argument("--out", help="write the converted audio here")
    p.add_argument("--token", default=os.environ.get("XVC_TOKEN", ""),
                   help="bearer token; defaults to $XVC_TOKEN (omit for an open server)")
    p.add_argument("--insecure", action="store_true", help="skip TLS verification (self-signed dev cert)")
    p.add_argument("--no-tls", action="store_true", help="plain ws:// (local server without SSL_DIR)")
    args = p.parse_args()
    if not args.host:
        p.error("no server host: pass --host or set XVC_HOST")
    if not args.target_wav and not args.target_id:
        p.error("need --target-wav or --target-id")
    return asyncio.run(run(args))


if __name__ == "__main__":
    sys.exit(main())
