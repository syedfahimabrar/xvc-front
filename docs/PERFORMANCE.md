# Performance — latency budget, GPU sizing, tuning levers

Latency is the product's #1 quality metric. This doc explains where every millisecond
goes, why the current 3090 deployment "struggles with some delay", and the levers to
fix it — so decisions are made from measurements, not guesses.

## 1. Why X-VC is compute-heavy (the core fact)

X-VC emits converted audio in **`CURRENT_MS` = 120 ms** pieces, but to produce each
piece it runs a full forward pass over a **`CHUNK_MS` = 2.4 s** window (history 2160 ms
+ current 120 ms + smooth 20 ms + future 100 ms). The per-window pass includes the
GLM-4-Voice semantic tokenizer — a Whisper-large-class encoder — plus the acoustic
encoder/quantizer, converter, and decoder.

Consequence: **for every 1 s of speech the GPU processes ~20 s of audio.** To keep up
in real time, the per-window forward must finish in **< `CURRENT_MS` (120 ms)** —
ideally ≤ 60–80 ms so bursts and OS jitter don't cause backlog.

**Failure mode to recognize:** if per-window time is only slightly over budget, the
server doesn't fail — it falls behind a little on every chunk, so **delay grows the
longer the user talks** within a turn. That is exactly the symptom observed on the
shared 3090. A dedicated GPU + tuning is the fix, not more RAM.

Measured 2026-07-09 (`docs/BENCHMARKS.md`): an idle **3080** runs the default window in
34 ms p95 — a 0.28x load fraction, with no jitter. Since that is slower silicon than the
3090, GPU speed cannot explain the shared box's delay; **contention (lever 4) is the
cause.** Tuning turned out to be unnecessary on a dedicated GPU.

VRAM is NOT the constraint: the full pipeline uses roughly 6–8 GB; a 3090 has 24 GB.
(Measured peak torch allocation is ~2.5 GB, so even this is generous.)

## 2. End-to-end latency budget (Mac mic → meeting app hears converted voice)

| Stage | Typical | Notes |
|---|---|---|
| Mac mic capture buffer | 5–20 ms | AVAudioEngine tap buffer size |
| Uplink network | ½ RTT | float32/16 kHz mono = 512 kbit/s — bandwidth is trivial; RTT is what matters |
| Algorithmic look-ahead | **240 ms fixed** | server can't emit window *i* until it has `current+smooth+future` = 240 ms of audio past the window start |
| GPU compute | 40–120 ms | the per-window forward; MUST be < 120 ms (see §1) |
| Downlink network | ½ RTT | converted PCM back |
| Jitter buffer + virtual-mic playout | 30–60 ms | output arrives in 120 ms bursts; buffer smooths it |

Totals: with a nearby server (RTT ≤ 20 ms) and a healthy GPU, **~350–450 ms** —
noticeable but fine for normal meeting turn-taking. RTT > ~150 ms (far cloud region)
pushes past 600 ms and feels laggy: **pick a GPU region close to the user.**

## 3. Tuning levers, in order of bang-for-buck

1. **`XVC_CURRENT_MS` 120 → 240.** Each window then emits twice the audio, halving
   windows/sec ⇒ ≈ **halves GPU load** (window cost is dominated by the fixed 2.4 s
   context). Cost: +120 ms latency. Usually the single change that turns "struggling"
   into "comfortable". Keep `CHUNK_MS` constraint in mind (see BACKEND.md §4).
2. **Shrink `XVC_CHUNK_MS`** (e.g. 2400 → 1600): shorter context ⇒ cheaper forward.
   Quality risk — the model was tuned with 2.4 s windows; A/B a few voices before adopting.
3. **fp16/bf16 inference + `torch.compile`** on the converter/decoder path: typically
   another 1.5–2× if not already active. Verify numerically (listen) after enabling.
4. **Dedicated GPU.** The reference deployment shares one GPU with a dialogue LLM;
   contention alone can push per-window time over budget. This project's box runs
   X-VC only.
5. **Faster GPU.** 4090 ≈ 1.5–2× a 3090 for this workload; L40S/A100 similar or
   better. Rented, an L40S/4090-class box is ~$0.5–1/h — only needed during meetings.

## 4. Phase 0 benchmark (do this before ANY client work)

Write `bench.py` on the GPU box: load the model exactly as the server does
(`load_xvc`), precompute conditions from any WAV, then time
`run_stream_chunk_forward` over a 2.4 s random/looped-speech window,
~50 iterations after 5 warm-ups, report p50/p95.

Verdict table:

| p95 per-window | Meaning |
|---|---|
| < 80 ms | comfortable — defaults fine |
| 80–120 ms | works but fragile — apply lever 1 |
| > 120 ms | cannot keep up at defaults — levers 1–3, else faster GPU |

Re-run the benchmark after every tuning change, and once more with the real streaming
server under a synthetic client (send a WAV at real-time pace, assert output cadence
keeps up and total drift stays ~0).

## 5. Client-side measurement (Phase 1 gate)

The CLI prototype must print a live end-to-end number: timestamp each sent chunk,
match against received samples (sample-count bookkeeping — the stream has no frame
IDs), report rolling p50/p95 mic-to-ear latency. Gate for proceeding to driver work:
**p95 < 500 ms sustained over 2 minutes of continuous speech** against the test server.
