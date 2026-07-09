#!/usr/bin/env bash
# Phase-0 bootstrap: get a fresh GPU box to the point where bench.py can run.
#
# Idempotent — re-run it freely. This is steps 1-4 of the setup.sh described in
# docs/BACKEND.md §7; the TLS certs, auth token and systemd unit come in Phase 3,
# when there is a server to run.
#
#   XVC_DIR=~/X-VC ./bootstrap.sh
#
# Assumes Ubuntu 22.04 with an NVIDIA driver already installed (`nvidia-smi` works).
set -euo pipefail

XVC_COMMIT=49df8c591eafc48b096e466d96f9839f9c0dd739
SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XVC_DIR="${XVC_DIR:-$HOME/X-VC}"

command -v nvidia-smi >/dev/null || {
    echo "error: no nvidia-smi. X-VC needs a CUDA GPU." >&2
    exit 1
}
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader

if ! command -v uv >/dev/null; then
    echo "[bootstrap] installing uv ..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi

# librosa/audiotools shell out to ffmpeg at runtime.
if ! command -v ffmpeg >/dev/null; then
    echo "[bootstrap] installing ffmpeg (needs sudo) ..."
    sudo apt-get update -qq && sudo apt-get install -y ffmpeg
fi

if [ ! -d "$XVC_DIR/.git" ]; then
    echo "[bootstrap] cloning X-VC into $XVC_DIR ..."
    git clone https://github.com/Jerrister/X-VC.git "$XVC_DIR"
fi
git -C "$XVC_DIR" checkout --quiet "$XVC_COMMIT"
mkdir -p "$XVC_DIR/ckpts" "$XVC_DIR/pretrained"
echo "[bootstrap] X-VC at $XVC_DIR (pinned $XVC_COMMIT)"

echo "[bootstrap] syncing python env (torch cu121, ~5 GB on first run) ..."
uv sync --project "$SERVER_DIR"

XVC_DIR="$XVC_DIR" uv run --project "$SERVER_DIR" python "$SERVER_DIR/download_models.py"

cat <<EOF

[bootstrap] done. Run the Phase-0 benchmark (X-VC must be the cwd):

    cd "$XVC_DIR"
    XVC_DIR="$XVC_DIR" uv run --project "$SERVER_DIR" \\
        python "$SERVER_DIR/bench.py" --sweep --tf32 --json "$SERVER_DIR/bench.json"

EOF
