#!/usr/bin/env bash
# One-command provisioning for the dedicated X-VC box (the README).
#
# Superset of bootstrap.sh: gets the environment + models in place (that script), then
# adds TLS certs, an auth token, a systemd unit, and a Phase-0 benchmark run.
#
#   XVC_DIR=~/X-VC ./setup.sh
#
# Fresh Ubuntu 22.04 with an NVIDIA driver (`nvidia-smi` works). Idempotent.
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XVC_DIR="${XVC_DIR:-$HOME/X-VC}"
SSL_DIR="${SSL_DIR:-$HOME/xvc-ssl}"
TOKEN_FILE="${TOKEN_FILE:-$HOME/xvc-token}"
PORT="${MEANVC_PORT:-5002}"
PUBLIC_HOST="${XVC_PUBLIC_HOST:-}"     # a DNS name enables Let's Encrypt; else self-signed

# 1-4. Environment + X-VC + models (idempotent).
XVC_DIR="$XVC_DIR" "$SERVER_DIR/bootstrap.sh"

# 5. TLS. A real hostname gets Let's Encrypt; otherwise a pinned self-signed cert.
mkdir -p "$SSL_DIR"
if [ -n "$PUBLIC_HOST" ] && command -v certbot >/dev/null; then
    echo "[setup] obtaining Let's Encrypt cert for $PUBLIC_HOST ..."
    sudo certbot certonly --standalone -d "$PUBLIC_HOST" --non-interactive --agree-tos \
        -m "admin@$PUBLIC_HOST" || echo "[setup] certbot failed; falling back to self-signed"
    LE="/etc/letsencrypt/live/$PUBLIC_HOST"
    [ -f "$LE/fullchain.pem" ] && sudo cp "$LE/fullchain.pem" "$SSL_DIR/cert.pem" \
        && sudo cp "$LE/privkey.pem" "$SSL_DIR/key.pem" && sudo chown "$USER" "$SSL_DIR"/*.pem
fi
if [ ! -f "$SSL_DIR/cert.pem" ]; then
    echo "[setup] generating a 10-year self-signed cert in $SSL_DIR ..."
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -keyout "$SSL_DIR/key.pem" -out "$SSL_DIR/cert.pem" \
        -subj "/CN=${PUBLIC_HOST:-xvc-live-mic}" 2>/dev/null
    echo "[setup] self-signed — clients must pin this cert or bypass validation (dev)."
    echo "[setup] SHA-256 fingerprint (pin this in the app):"
    openssl x509 -in "$SSL_DIR/cert.pem" -noout -fingerprint -sha256 | sed 's/^/  /'
fi

# 6. Auth token — generated once and reused.
if [ ! -f "$TOKEN_FILE" ]; then
    openssl rand -hex 32 > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    echo "[setup] generated a new auth token in $TOKEN_FILE"
fi
TOKEN="$(cat "$TOKEN_FILE")"

# Launch mechanism. systemd needs root; many GPU boxes are rootless (shared, or a
# container). Write a plain launch script always, and install a systemd unit only if we
# actually have sudo. The server must run with the X-VC repo as cwd (relative pretrained/).
UV="$(command -v uv || echo "$HOME/.local/bin/uv")"
LAUNCH="$HOME/xvc-run.sh"
cat > "$LAUNCH" <<LAUNCH
#!/usr/bin/env bash
# Start the XVC server. Env chosen by setup.sh; tuning per the README.
cd "$XVC_DIR" || exit 1
export XVC_DIR="$XVC_DIR" SSL_DIR="$SSL_DIR" MEANVC_PORT=$PORT
export XVC_AUTH_TOKEN="\$(cat "$TOKEN_FILE")"
export XVC_CHUNK_MS=\${XVC_CHUNK_MS:-2400} XVC_CURRENT_MS=\${XVC_CURRENT_MS:-240}
exec "$UV" run --project "$SERVER_DIR" python "$SERVER_DIR/xvc_server.py"
LAUNCH
chmod +x "$LAUNCH"

if sudo -n true 2>/dev/null; then
    UNIT=/etc/systemd/system/xvc-server.service
    echo "[setup] sudo available — installing systemd unit $UNIT ..."
    sudo tee "$UNIT" >/dev/null <<UNIT
[Unit]
Description=XVC Live Mic streaming server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$XVC_DIR
EnvironmentFile=-$HOME/xvc.env
ExecStart=$LAUNCH
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    LAUNCH_HINT="sudo systemctl enable --now xvc-server   # survives reboot"
else
    echo "[setup] no sudo — skipping systemd. Run the server yourself (no root needed):"
    LAUNCH_HINT="nohup $LAUNCH > ~/xvc-server.log 2>&1 &   # then: tail -f ~/xvc-server.log"
fi

# 7. Phase-0 benchmark on this box, so tuning decisions are made from its numbers.
echo
echo "[setup] running the Phase-0 benchmark on this GPU ..."
( cd "$XVC_DIR" && XVC_DIR="$XVC_DIR" "$(command -v uv)" run --project "$SERVER_DIR" \
    python "$SERVER_DIR/bench.py" --tf32 || echo "[setup] bench failed; run it manually" )

cat <<EOF

[setup] done.

  Server host : ${PUBLIC_HOST:-<this box's IP>}:$PORT   (wss)
  Auth token  : $TOKEN_FILE  (give this to the Mac client as XVC_TOKEN)
  TLS         : $SSL_DIR/cert.pem

  Start it:   $LAUNCH_HINT
  Wait for:   "[xvc] warmed up" in the log before connecting

  Point the Mac client at it:
    export XVC_HOST=${PUBLIC_HOST:-<ip>} XVC_TOKEN=\$(cat $TOKEN_FILE)
EOF
