#!/usr/bin/env bash
# install-forge-panel.sh — install the local web panel as a systemd service.
#
#   cd /opt/forge-deploy && bash scripts/install-forge-panel.sh
#
# Generates a token, writes /etc/forge/panel.token, installs + starts
# forge-panel.service running panel/server.mjs as the invoking user, and
# prints the URL + token for the operator's browser. Re-run safe: keeps the
# existing token, refreshes the unit.
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "Run as your regular user (it sudos only where needed)." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER="${REPO_ROOT}/panel/server.mjs"
TOKEN_FILE="/etc/forge/panel.token"
UNIT="/etc/systemd/system/forge-panel.service"
PORT="${PANEL_PORT:-8484}"

[[ -f "$SERVER" ]] || { echo "panel/server.mjs not found — refresh the deploy tree first." >&2; exit 1; }

NODE_BIN="$(command -v node || true)"
[[ -n "$NODE_BIN" ]] || { echo "Node.js is required: https://nodejs.org — then re-run." >&2; exit 1; }
NODE_MAJOR="$("$NODE_BIN" -e 'console.log(process.versions.node.split(".")[0])')"
(( NODE_MAJOR >= 22 )) || { echo "Node.js 22+ required (found $("$NODE_BIN" --version))." >&2; exit 1; }

sudo mkdir -p /etc/forge
if sudo test -s "$TOKEN_FILE"; then
  TOKEN="$(sudo cat "$TOKEN_FILE")"
  echo "Keeping existing panel token."
else
  TOKEN="$(head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 40)"
  printf '%s\n' "$TOKEN" | sudo tee "$TOKEN_FILE" >/dev/null
  sudo chmod 640 "$TOKEN_FILE"
  sudo chown "root:$(id -gn)" "$TOKEN_FILE"
fi

sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=Forge local deploy panel
After=network.target docker.service

[Service]
Type=simple
User=$USER
WorkingDirectory=${REPO_ROOT}
Environment=PANEL_PORT=${PORT}
ExecStart=${NODE_BIN} ${SERVER}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now forge-panel.service
sleep 1
if ! systemctl is-active --quiet forge-panel.service; then
  echo "forge-panel failed to start — check: journalctl -u forge-panel -n 30" >&2
  exit 1
fi

HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
echo
echo "=================================================================="
echo "  Forge Panel is running."
echo
echo "  Open:   http://${HOST_IP:-<this-box>}:${PORT}"
echo "  Token:  ${TOKEN}"
echo
echo "  The browser asks for the token once and remembers it."
echo "  Do NOT expose this port through the public reverse proxy."
echo "=================================================================="
