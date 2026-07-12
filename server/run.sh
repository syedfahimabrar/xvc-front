#!/usr/bin/env bash
# Launch the XVC server with tunable streaming parameters (docs/PERFORMANCE.md §3,
# docs/BACKEND.md §4). Override any of them via env — everything else has a safe default:
#
#   ./run.sh                        # defaults: CURRENT_MS=120 (balanced)
#   XVC_CURRENT_MS=60  ./run.sh     # low latency  (~-82 ms end-to-end, ~2x GPU load)
#   XVC_CURRENT_MS=240 ./run.sh     # low GPU load (~+120 ms latency, ~0.5x load)
#   XVC_CHUNK_MS=1600  ./run.sh     # cheaper forward, quality risk — A/B by ear first
#
# Constraint (enforced by the server): CHUNK - CURRENT - SMOOTH - FUTURE >= 0.
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export XVC_DIR="${XVC_DIR:-$HOME/X-VC}"
export SSL_DIR="${SSL_DIR:-$HOME/xvc-ssl}"
export MEANVC_PORT="${MEANVC_PORT:-5002}"
export XVC_AUTH_TOKEN="${XVC_AUTH_TOKEN:-$(cat "$HOME/xvc-token" 2>/dev/null || true)}"

# --- the tunables ---
export XVC_CHUNK_MS="${XVC_CHUNK_MS:-2400}"     # context window the model runs over
export XVC_CURRENT_MS="${XVC_CURRENT_MS:-120}"  # emitted per window — the main latency lever
export XVC_SMOOTH_MS="${XVC_SMOOTH_MS:-20}"     # cross-fade between windows
export XVC_FUTURE_MS="${XVC_FUTURE_MS:-100}"    # look-ahead

# Perceived latency floor (a window's average sample): current/2 + smooth + future.
FLOOR=$(( XVC_CURRENT_MS/2 + XVC_SMOOTH_MS + XVC_FUTURE_MS ))
echo "[run] CHUNK=$XVC_CHUNK_MS CURRENT=$XVC_CURRENT_MS SMOOTH=$XVC_SMOOTH_MS FUTURE=$XVC_FUTURE_MS" \
     "→ ~${FLOOR} ms look-ahead + GPU + network"

cd "$XVC_DIR"   # X-VC resolves pretrained/ relatively
exec "${UV:-$HOME/.local/bin/uv}" run --project "$SERVER_DIR" python "$SERVER_DIR/xvc_server.py"
