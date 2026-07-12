#!/usr/bin/env bash
# Restart the server with different tuning, detached, and wait until it's ready.
# Run this ON the GPU box.
#
#   ./restart.sh                     # restart with current defaults (CURRENT_MS=120)
#   XVC_CURRENT_MS=60  ./restart.sh  # switch to low-latency and restart
#
# After it prints "ready", reconnect the Mac app (toggle Convert off/on) and compare the
# latency readout — and listen, since CHUNK/quality levers change how it sounds.
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HOME/xvc-server.log"
PORT="${MEANVC_PORT:-5002}"

echo "[restart] stopping any running server …"
pkill -f "xvc_server.py" 2>/dev/null || true
# Wait for the port to free.
for _ in $(seq 1 15); do ss -tln | grep -q ":$PORT " || break; sleep 1; done

echo "[restart] launching (CURRENT_MS=${XVC_CURRENT_MS:-120}) …"
# Pass the tuning env through to the detached process.
setsid env \
    XVC_CHUNK_MS="${XVC_CHUNK_MS:-}" XVC_CURRENT_MS="${XVC_CURRENT_MS:-}" \
    XVC_SMOOTH_MS="${XVC_SMOOTH_MS:-}" XVC_FUTURE_MS="${XVC_FUTURE_MS:-}" \
    bash "$SERVER_DIR/run.sh" >"$LOG" 2>&1 </dev/null &
disown || true

echo "[restart] waiting for the model to load + warm up …"
for _ in $(seq 1 60); do
    if grep -q "warmed up" "$LOG" 2>/dev/null; then
        grep -E "\[run\]|window\(ms\)|warmed up|auth:" "$LOG" | tail -4
        echo "[restart] ready on port $PORT"
        exit 0
    fi
    sleep 2
done
echo "[restart] did not report ready in time — check $LOG" >&2
tail -5 "$LOG" >&2
exit 1
