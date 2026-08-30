#!/usr/bin/env bash
# install-forge-agent.sh — install the headless deploy agent as a systemd service.
#
#   cd /opt/forge-deploy && bash scripts/install-forge-agent.sh
#
# The agent is the executor half of the in-app upgrade path: forge-api calls it,
# it runs the gated deploy CLI. It replaces forge-panel (which served its own
# UI); an existing panel install is stopped and its token reused so a box that
# had the panel keeps working without a new secret.
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "Run as your regular user (it sudos only where needed)." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER="${REPO_ROOT}/agent/server.mjs"
TOKEN_FILE="/etc/forge/agent.token"
PANEL_TOKEN_FILE="/etc/forge/panel.token"
STATE_HOME="/var/lib/forge-agent"
UNIT="/etc/systemd/system/forge-agent.service"
PORT="${FORGE_AGENT_PORT:-8484}"
ENV_FILE="${REPO_ROOT}/.env"

# forge-api reaches the agent from inside a container, so loopback is not a
# usable default here — it would be reachable only from the host. The docker
# bridge gateway is reachable from containers and from this host, and is not
# routable from the LAN the way 0.0.0.0 would be.
detect_bridge_ip() {
  docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true
}
BIND="${FORGE_AGENT_BIND:-$(detect_bridge_ip)}"
BIND="${BIND:-172.17.0.1}"

[[ -f "$SERVER" ]] || { echo "agent/server.mjs not found — refresh the deploy tree first." >&2; exit 1; }

NODE_BIN="$(command -v node || true)"
[[ -n "$NODE_BIN" ]] || { echo "Node.js is required: https://nodejs.org — then re-run." >&2; exit 1; }
NODE_MAJOR="$("$NODE_BIN" -e 'console.log(process.versions.node.split(".")[0])')"
(( NODE_MAJOR >= 22 )) || { echo "Node.js 22+ required (found $("$NODE_BIN" --version))." >&2; exit 1; }

# The panel and the agent both want :8484 — retire the panel first.
if systemctl list-unit-files forge-panel.service >/dev/null 2>&1 \
   && systemctl is-enabled --quiet forge-panel.service 2>/dev/null; then
  echo "Retiring forge-panel (superseded by forge-agent)..."
  sudo systemctl disable --now forge-panel.service || true
fi

sudo mkdir -p /etc/forge
if sudo test -s "$TOKEN_FILE"; then
  TOKEN="$(sudo cat "$TOKEN_FILE")"
  echo "Keeping existing agent token."
elif sudo test -s "$PANEL_TOKEN_FILE"; then
  TOKEN="$(sudo cat "$PANEL_TOKEN_FILE")"
  printf '%s\n' "$TOKEN" | sudo tee "$TOKEN_FILE" >/dev/null
  echo "Adopted the existing panel token."
else
  TOKEN="$(head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 40)"
  printf '%s\n' "$TOKEN" | sudo tee "$TOKEN_FILE" >/dev/null
fi
sudo chmod 640 "$TOKEN_FILE"
sudo chown "root:$(id -gn)" "$TOKEN_FILE"

sudo mkdir -p "${STATE_HOME}/jobs"
sudo chown -R "$USER:$(id -gn)" "$STATE_HOME"

sudo tee "$UNIT" >/dev/null <<UNITEOF
[Unit]
Description=Forge deploy agent
After=network.target docker.service

[Service]
Type=simple
User=$USER
WorkingDirectory=${REPO_ROOT}
Environment=FORGE_AGENT_PORT=${PORT}
Environment=FORGE_AGENT_BIND=${BIND}
ExecStart=${NODE_BIN} ${SERVER}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF

sudo systemctl daemon-reload
sudo systemctl enable --now forge-agent.service
sleep 1
if ! systemctl is-active --quiet forge-agent.service; then
  echo "forge-agent failed to start — check: journalctl -u forge-agent -n 30" >&2
  exit 1
fi

# Wire it into .env ourselves. Printing the values and trusting an operator to
# paste them correctly is how a feature ships that nobody can turn on.
if [[ -f "$ENV_FILE" ]]; then
  set_env() {
    local key="$1" val="$2" tmp
    tmp=$(mktemp)
    if grep -qE "^${key}=" "$ENV_FILE"; then
      awk -v k="$key" -v v="$val" 'BEGIN{FS=OFS="="} $1==k{print k "=" v; next} {print}' "$ENV_FILE" > "$tmp"
    else
      cp "$ENV_FILE" "$tmp"; printf '%s=%s\n' "$key" "$val" >> "$tmp"
    fi
    mv "$tmp" "$ENV_FILE"
  }
  set_env DEPLOY_AGENT_URL "http://${BIND}:${PORT}"
  set_env DEPLOY_AGENT_TOKEN "$TOKEN"
  echo "Wired into ${ENV_FILE} (DEPLOY_AGENT_URL, DEPLOY_AGENT_TOKEN)."

  # forge-api only reads these at container start.
  if command -v docker >/dev/null 2>&1; then
    echo "Recreating forge-api so it picks them up..."
    if (cd "$REPO_ROOT" && bash scripts/forge-deploy compose up -d forge-api >/dev/null 2>&1); then
      echo "forge-api restarted."
    else
      echo "Could not restart forge-api automatically — run: forge-deploy compose up -d forge-api"
    fi
  fi
else
  echo "No ${ENV_FILE} yet — after ./setup.sh, re-run this script to wire the agent in."
fi

echo
echo "=================================================================="
echo "  Forge deploy agent is running on ${BIND}:${PORT}."
echo
echo "  Upgrades now appear in Forge under Admin -> Updates."
echo "  ./forge-upgrade.sh still works and remains the recovery path."
echo
echo "  The agent has no web UI and no login. Do NOT expose this port"
echo "  through the public reverse proxy."
echo "=================================================================="
