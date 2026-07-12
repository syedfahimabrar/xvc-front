#!/usr/bin/env python3
"""X-VC streaming voice-conversion server — standalone, this project's own.

A trimmed copy of docs/reference/hearmeout-xvc-server.py: keeps `load-target` + `stream`,
drops `chat-proxy` (and with it sphn/Opus + PersonaPlex), adds bearer-token auth and a
startup warm-up. The streaming window math is copied verbatim from the reference — it is
proven, do not reinvent it (the README).

Two endpoints (the README):
    POST /api/meanvc/load-target   register a target voice, precompute conditions
    GET  /api/meanvc/stream        WebSocket: raw float32 PCM in -> converted PCM out

Auth (the README): if XVC_AUTH_TOKEN is set, load-target requires
`Authorization: Bearer <token>` and stream requires `?token=<token>` (browsers/URLSession
can't set WS headers reliably). If it is unset the server runs OPEN and says so loudly —
acceptable for a firewalled dev box, never for anything reachable.

Env: XVC_DIR, XVC_CONFIG, XVC_CKPT, XVC_DEVICE, XVC_EMA_LOAD,
XVC_CHUNK_MS/CURRENT_MS/SMOOTH_MS/FUTURE_MS, MEANVC_PORT, SSL_DIR, XVC_AUTH_TOKEN.
See the README
"""
import asyncio
import hmac
import logging
import os
import sys
import uuid

import numpy as np
import torch
import torchaudio
from aiohttp import web

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("xvc_server")

# --- make the X-VC repo importable -----------------------------------------
XVC_DIR = os.environ.get("XVC_DIR", os.getcwd())
if XVC_DIR not in sys.path:
    sys.path.insert(0, XVC_DIR)

from bins.infer_utils import (  # noqa: E402  (import after sys.path setup)
    load_xvc,
    precompute_conditions,
    run_stream_chunk_forward,
)
from models.codec.sac.utils import process_audio  # noqa: E402
from utils.audio import audio_highpass_filter  # noqa: E402

XVC_CONFIG = os.environ.get("XVC_CONFIG", os.path.join(XVC_DIR, "configs/xvc.yaml"))
XVC_CKPT = os.environ.get("XVC_CKPT", os.path.join(XVC_DIR, "ckpts/xvc.pt"))
XVC_DEVICE = int(os.environ.get("XVC_DEVICE", 0))
XVC_EMA_LOAD = os.environ.get("XVC_EMA_LOAD", "1") not in ("0", "false", "False")

CHUNK_MS = int(os.environ.get("XVC_CHUNK_MS", 2400))
CURRENT_MS = int(os.environ.get("XVC_CURRENT_MS", 240))
SMOOTH_MS = int(os.environ.get("XVC_SMOOTH_MS", 20))
FUTURE_MS = int(os.environ.get("XVC_FUTURE_MS", 100))

AUTH_TOKEN = os.environ.get("XVC_AUTH_TOKEN", "").strip()

# Globals populated on startup.
cfg: dict | None = None
model = None
device: torch.device | None = None
SR = 16000
HP_CUT = 0.0
MASK_TARGET_COND = True

# target_id -> (speaker_condition, frame_condition)
targets: dict[str, tuple[torch.Tensor, torch.Tensor]] = {}


def _token_ok(supplied: str) -> bool:
    """Constant-time compare. If no token is configured, the server is open."""
    if not AUTH_TOKEN:
        return True
    return hmac.compare_digest(supplied or "", AUTH_TOKEN)


class XVCStreamSession:
    """Online driver around X-VC's official per-window forward.

    Mirrors bins.infer_utils.run_streaming exactly, but pulls each window from a growing
    buffer (live mic) instead of a complete source array. Per-window work is stateless
    except the overlap cross-fade tail_buffer. Copied verbatim from the reference server —
    the README says port this, do not reinvent it.
    """

    def __init__(self, speaker_condition, frame_condition):
        self.spk = speaker_condition
        self.frame = frame_condition
        self.sr = SR
        self.current_ms = CURRENT_MS
        self.smooth_ms = SMOOTH_MS
        self.future_ms = FUTURE_MS
        self.history_ms = CHUNK_MS - CURRENT_MS - SMOOTH_MS - FUTURE_MS
        if self.history_ms < 0:
            raise ValueError("CHUNK_MS - CURRENT_MS - SMOOTH_MS - FUTURE_MS must be >= 0")
        self.overlap_len = SMOOTH_MS * SR // 1000
        if self.overlap_len > 0:
            self.fade_in = 0.5 * (
                1 - torch.cos(torch.pi * torch.linspace(0, 1, self.overlap_len, device=device))
            )
            self.fade_out = 1 - self.fade_in
            self.tail_buffer = torch.zeros(1, 1, self.overlap_len, device=device)
        else:
            self.fade_in = self.fade_out = self.tail_buffer = None
        self.buf = np.zeros(0, dtype=np.float32)
        self.i = 0

    def feed(self, pcm: np.ndarray) -> list[np.ndarray]:
        """Append incoming 16 kHz PCM, return any completed current-region chunks."""
        self.buf = np.concatenate([self.buf, pcm.astype(np.float32)])
        outs: list[np.ndarray] = []
        while True:
            start = (self.i * self.current_ms - self.history_ms) * self.sr // 1000
            end = (
                self.i * self.current_ms + self.current_ms + self.smooth_ms + self.future_ms
            ) * self.sr // 1000
            if len(self.buf) < end:
                break  # need more look-ahead audio before this window is ready
            left_pad = max(0, -start)
            seg = self.buf[max(0, start):end]
            if left_pad:
                seg = np.concatenate([np.zeros(left_pad, dtype=np.float32), seg])
            if HP_CUT:
                seg = audio_highpass_filter(seg, self.sr, HP_CUT).astype(np.float32)
            outs.append(self._forward(seg))
            self.i += 1
        return outs

    @torch.inference_mode()
    def _forward(self, seg_np: np.ndarray) -> np.ndarray:
        win = torch.from_numpy(seg_np)[None, None].float().to(device)
        out = run_stream_chunk_forward(model, win, self.spk, self.frame)
        cur_start = self.history_ms * self.sr // 1000
        cur_end = (self.history_ms + self.current_ms) * self.sr // 1000
        cur = out[:, :, cur_start:cur_end]
        if self.overlap_len > 0:
            if self.i > 0:
                head = cur[..., : self.overlap_len]
                head_sm = self.tail_buffer * self.fade_out + head * self.fade_in
                cur = torch.cat([head_sm, cur[..., self.overlap_len:]], dim=-1)
            tail_start = (self.history_ms + self.current_ms) * self.sr // 1000
            self.tail_buffer = out[:, :, tail_start: tail_start + self.overlap_len]
        return cur.squeeze().detach().cpu().numpy().astype(np.float32)


def _build_conditions(target_np: np.ndarray):
    """Precompute speaker + frame conditions from 16 kHz mono PCM, as load-target does."""
    target_wav = torch.from_numpy(target_np)[None, None].float().to(device)
    if MASK_TARGET_COND:
        pad = torch.zeros((1, 1, int(2.4 * SR)), device=device)
        target_wav_cond = torch.cat([target_wav, pad], dim=-1)
    else:
        target_wav_cond = target_wav
    return precompute_conditions(model, target_wav, target_wav_cond)


@web.middleware
async def cors_middleware(request: web.Request, handler):
    if request.method == "OPTIONS":
        resp = web.Response()
    else:
        resp = await handler(request)
    resp.headers["Access-Control-Allow-Origin"] = "*"
    resp.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    resp.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
    return resp


async def handle_load_target(request: web.Request) -> web.Response:
    """POST /api/meanvc/load-target - upload target WAV, precompute conditions."""
    auth = request.headers.get("Authorization", "")
    supplied = auth[7:] if auth.startswith("Bearer ") else ""
    if not _token_ok(supplied):
        return web.json_response({"error": "unauthorized"}, status=401)

    post = await request.post()
    field = post.get("wav")
    if field is None:
        return web.json_response({"error": "missing 'wav' file"}, status=400)

    target_id = uuid.uuid4().hex
    tmp_path = os.path.join("/tmp", f"xvc_target_{target_id}.wav")
    with open(tmp_path, "wb") as f:
        f.write(field.file.read())

    try:
        target_np = process_audio(tmp_path, cfg, int(cfg["latent_hop_length"]))
        spk, frame = _build_conditions(target_np)
        targets[target_id] = (spk, frame)
        duration = round(len(target_np) / SR, 2)
        logger.info(f"[xvc] loaded target {target_id} ({duration}s)")
        return web.json_response({"target_id": target_id, "duration_seconds": duration})
    except Exception as e:
        logger.exception("[xvc] load-target failed")
        return web.json_response({"error": str(e)}, status=500)
    finally:
        try:
            os.remove(tmp_path)
        except OSError:
            pass


def _maybe_resampler(source_sr: int):
    if source_sr == SR:
        return None
    return torchaudio.transforms.Resample(orig_freq=source_sr, new_freq=SR).to("cpu")


async def handle_stream(request: web.Request) -> web.StreamResponse:
    """GET /api/meanvc/stream - WebSocket: raw float32 PCM in, converted PCM out."""
    # Auth is checked BEFORE the WebSocket handshake: a bad token gets a plain HTTP 401,
    # which URLSession/browsers surface as a failed upgrade. Tokens travel in the query
    # string because WS clients can't set request headers reliably (the README).
    if not _token_ok(request.query.get("token", "")):
        return web.json_response({"error": "unauthorized"}, status=401)

    target_id = request.query.get("target_id", "")
    source_sr = int(request.query.get("source_sr", SR))
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    if target_id not in targets:
        await ws.send_json({"error": f"Unknown target_id: {target_id}"})
        await ws.close()
        return ws

    spk, frame = targets[target_id]
    session = XVCStreamSession(spk, frame)
    resampler = _maybe_resampler(source_sr)
    loop = asyncio.get_event_loop()
    await ws.send_json({"status": "ready"})

    async for msg in ws:
        if msg.type == web.WSMsgType.BINARY:
            incoming = np.frombuffer(msg.data, dtype=np.float32).copy()
            if resampler is not None:
                incoming = resampler(torch.from_numpy(incoming).unsqueeze(0)).squeeze(0).numpy()
            # GPU work runs in a thread executor so the event loop keeps serving frames
            # (the README) — keep this pattern.
            curs = await loop.run_in_executor(None, session.feed, incoming)
            for cur in curs:
                if not ws.closed:
                    await ws.send_bytes(cur.tobytes())
        elif msg.type in (web.WSMsgType.CLOSE, web.WSMsgType.ERROR):
            break
    return ws


def create_app() -> web.Application:
    app = web.Application(middlewares=[cors_middleware], client_max_size=10 * 1024 * 1024)
    app.router.add_post("/api/meanvc/load-target", handle_load_target)
    app.router.add_get("/api/meanvc/stream", handle_stream)
    app.on_startup.append(on_startup)
    return app


def _warmup() -> None:
    """Run the full pipeline once before serving.

    The first forward of a fresh process pays ~2.4 s of lazy CUDA/cuDNN + GLM-tokenizer
    init (measured, the README). Without this the first real user hears mangled
    audio. Exercise the exact serving path: build conditions from noise, then run one
    conversion window.
    """
    logger.info("[xvc] warming up ...")
    import time
    t0 = time.time()
    noise = (0.05 * np.random.randn(int(3.0 * SR))).astype(np.float32)
    spk, frame = _build_conditions(noise)
    session = XVCStreamSession(spk, frame)
    # One full CHUNK_MS window's worth of audio forces exactly one forward.
    need = (CHUNK_MS + CURRENT_MS) * SR // 1000
    session.feed(np.zeros(need, dtype=np.float32))
    if device is not None and device.type == "cuda":
        torch.cuda.synchronize()
    logger.info(f"[xvc] warmed up in {time.time() - t0:.1f}s")


async def on_startup(app: web.Application):
    global cfg, model, device, SR, HP_CUT, MASK_TARGET_COND
    logger.info(f"[xvc] loading model: config={XVC_CONFIG} ckpt={XVC_CKPT} device={XVC_DEVICE}")
    cfg, model, device = load_xvc(XVC_CONFIG, XVC_CKPT, XVC_DEVICE, XVC_EMA_LOAD)
    SR = int(cfg["sample_rate"])
    HP_CUT = float(cfg.get("highpass_cutoff_freq", 0.0))
    MASK_TARGET_COND = bool(cfg.get("dataloader", {}).get("mask_target_condition", True))
    logger.info(
        f"[xvc] model ready: sr={SR} hp_cut={HP_CUT} window(ms) chunk={CHUNK_MS} "
        f"current={CURRENT_MS} smooth={SMOOTH_MS} future={FUTURE_MS}"
    )
    # Warm up off the event loop so startup can't stall other init.
    await asyncio.get_event_loop().run_in_executor(None, _warmup)
    if AUTH_TOKEN:
        logger.info("[xvc] auth: bearer token REQUIRED")
    else:
        logger.warning("[xvc] auth: NO TOKEN SET — server is OPEN. Set XVC_AUTH_TOKEN.")


def main():
    import ssl

    port = int(os.environ.get("MEANVC_PORT", 5002))
    app = create_app()
    ssl_dir = os.environ.get("SSL_DIR", "/app/ssl")
    ssl_context = None
    cert_file = os.path.join(ssl_dir, "cert.pem")
    key_file = os.path.join(ssl_dir, "key.pem")
    if os.path.exists(cert_file) and os.path.exists(key_file):
        ssl_context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        ssl_context.load_cert_chain(cert_file, key_file)
        logger.info(f"[xvc] SSL enabled from {ssl_dir}")
    else:
        logger.warning(f"[xvc] no cert in {ssl_dir}: serving plain HTTP/ws (dev only)")
    logger.info(f"[xvc] starting on port {port} (ssl={ssl_context is not None})")
    web.run_app(app, port=port, ssl_context=ssl_context)


if __name__ == "__main__":
    main()
