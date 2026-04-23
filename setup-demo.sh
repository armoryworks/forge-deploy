#!/usr/bin/env bash
# setup-demo.sh — First-time deployment of the static demo site
#
# Walks through:
#   1. Docker prerequisite check
#   2. Build + start the demo container (static nginx serving Angular bundle)
#   3. (Optional) Cloudflare Tunnel setup for a public subdomain
#      — installs cloudflared
#      — prompts for subdomain + tunnel name
#      — creates/reuses a tunnel
#      — writes config + DNS route
#      — installs systemd service
#
# The demo has no database, no API, no secrets. All interaction is client-side
# synthesis against static JSON fixtures in /demo-data/. Safe to expose publicly.
#
# Usage:
#   ./setup-demo.sh
#   ./setup-demo.sh --container-only        # Skip Cloudflare Tunnel setup
#   ./setup-demo.sh --tunnel-only           # Skip container start (already running)

set -euo pipefail

CONTAINER_ONLY=false
TUNNEL_ONLY=false

for arg in "$@"; do
    case $arg in
        --container-only) CONTAINER_ONLY=true ;;
        --tunnel-only)    TUNNEL_ONLY=true ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# ─────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────

step()  { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
ok()    { printf '    \033[32m[OK] %s\033[0m\n' "$1"; }
warn()  { printf '    \033[33m[!!] %s\033[0m\n' "$1"; }
fail()  { printf '    \033[31m[X]  %s\033[0m\n' "$1"; }
info()  { printf '         %s\n' "$1"; }

ask() {
    # ask "prompt" "default_value" → sets REPLY to the answer (default on empty)
    local prompt="$1"
    local default="${2:-}"
    local answer
    if [[ -n "$default" ]]; then
        read -r -p "    $prompt [$default]: " answer
        REPLY="${answer:-$default}"
    else
        read -r -p "    $prompt: " answer
        REPLY="$answer"
    fi
}

confirm() {
    # confirm "question" → returns 0 for yes, 1 for no (default yes)
    local answer
    read -r -p "    $1 [Y/n]: " answer
    [[ -z "$answer" || "$answer" =~ ^[Yy] ]]
}

PROJECT="qb-engineer-demo"
COMPOSE_FILE="docker-compose.demo.yml"

if [[ ! -f "$COMPOSE_FILE" ]]; then
    fail "Run this from the repo root. $COMPOSE_FILE not found."
    exit 1
fi

# ─────────────────────────────────────────────────────────────
# Phase 1: Docker container
# ─────────────────────────────────────────────────────────────

if ! $TUNNEL_ONLY; then
    step "Pre-flight: Docker"
    if ! command -v docker &>/dev/null; then
        fail "Docker is not installed."
        info "Install: https://docs.docker.com/engine/install/"
        exit 1
    fi
    if ! docker compose version &>/dev/null; then
        fail "Docker Compose v2 is not available."
        info "Install: https://docs.docker.com/compose/install/"
        exit 1
    fi
    ok "Docker + Compose present"

    step "Building and starting demo container"
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" up -d --build
    ok "Container up"

    step "Waiting for health check (up to 60s)"
    STATUS=""
    for _ in {1..30}; do
        STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$PROJECT" 2>/dev/null || echo "starting")
        if [[ "$STATUS" == "healthy" ]]; then
            ok "Container healthy"
            break
        fi
        sleep 2
    done
    if [[ "$STATUS" != "healthy" ]]; then
        warn "Container did not report healthy. Status: $STATUS"
        warn "Check: docker compose -p $PROJECT -f $COMPOSE_FILE logs"
    fi

    HOST_PORT=$(docker compose -p "$PROJECT" -f "$COMPOSE_FILE" port qb-engineer-demo 80 2>/dev/null | sed 's/.*://')
    if [[ -n "${HOST_PORT:-}" ]]; then
        ok "Demo serving on http://localhost:${HOST_PORT}/"
    fi
fi

if $CONTAINER_ONLY; then
    step "Done (container only)"
    info "Skipped Cloudflare Tunnel setup. Demo is running locally."
    info "Run without --container-only to expose it at a public subdomain."
    exit 0
fi

# ─────────────────────────────────────────────────────────────
# Phase 2: Cloudflare Tunnel (optional but prompted)
# ─────────────────────────────────────────────────────────────

step "Cloudflare Tunnel setup"
info "Exposes the demo on a public subdomain (e.g. demo.yourdomain.com)"
info "with TLS handled by Cloudflare — no port forwarding, no certificates."
info "Requires: the zone (e.g. yourdomain.com) already added to your Cloudflare account."
echo ""
if ! confirm "Configure Cloudflare Tunnel now?"; then
    info "Skipped. Demo is still running locally on port ${HOST_PORT:-4203}."
    info "Re-run with --tunnel-only later to set up the tunnel."
    exit 0
fi

# ---- Install cloudflared if missing ----

step "Installing cloudflared"
if command -v cloudflared &>/dev/null; then
    ok "cloudflared already installed ($(cloudflared --version | head -1))"
else
    ARCH=$(uname -m)
    case $ARCH in
        aarch64|arm64) DEB_ARCH="arm64" ;;
        armv7l|armhf)  DEB_ARCH="armhf" ;;
        x86_64|amd64)  DEB_ARCH="amd64" ;;
        *) fail "Unsupported architecture: $ARCH"; exit 1 ;;
    esac
    URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${DEB_ARCH}.deb"
    info "Downloading: $URL"
    TMP_DEB=$(mktemp --suffix=.deb)
    curl -fsSL "$URL" -o "$TMP_DEB"
    sudo dpkg -i "$TMP_DEB"
    rm -f "$TMP_DEB"
    ok "cloudflared installed"
fi

# ---- Authenticate (only if no cert.pem) ----

step "Cloudflare authentication"
CERT_PATH="$HOME/.cloudflared/cert.pem"
if [[ -f "$CERT_PATH" ]]; then
    ok "Existing cert found at $CERT_PATH"
    info "If this cert is for the wrong zone, move it aside first:"
    info "  mv $CERT_PATH $CERT_PATH.old"
    info "Then re-run this script."
    if ! confirm "Continue with existing cert?"; then
        exit 0
    fi
else
    info "A browser window will open to authorize cloudflared."
    info "Select the zone that matches the subdomain you'll set below."
    cloudflared tunnel login
    ok "Authenticated"
fi

# ---- Prompt for subdomain + tunnel name ----

step "Configuration"
ask "Public subdomain for the demo (e.g. demo.example.com)" ""
SUBDOMAIN="$REPLY"
if [[ -z "$SUBDOMAIN" ]]; then
    fail "Subdomain is required."
    exit 1
fi

ask "Tunnel name" "qb-engineer-demo"
TUNNEL_NAME="$REPLY"

ask "Host port the demo container binds (leave as-is unless you changed it)" "${HOST_PORT:-4203}"
PORT="$REPLY"

# ---- Create or reuse tunnel ----

step "Creating tunnel: $TUNNEL_NAME"
if cloudflared tunnel list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$TUNNEL_NAME"; then
    ok "Tunnel '$TUNNEL_NAME' already exists — reusing"
else
    cloudflared tunnel create "$TUNNEL_NAME"
    ok "Tunnel created"
fi

TUNNEL_UUID=$(cloudflared tunnel list 2>/dev/null | awk -v n="$TUNNEL_NAME" '$2 == n {print $1}')
if [[ -z "$TUNNEL_UUID" ]]; then
    fail "Could not determine tunnel UUID."
    exit 1
fi
ok "Tunnel UUID: $TUNNEL_UUID"

# ---- Write /etc/cloudflared/config.yml ----

step "Writing tunnel config to /etc/cloudflared/"
sudo mkdir -p /etc/cloudflared
sudo cp "$HOME/.cloudflared/${TUNNEL_UUID}.json" /etc/cloudflared/
sudo chown -R root:root /etc/cloudflared

CONFIG_PATH="/etc/cloudflared/config.yml"
if [[ -f "$CONFIG_PATH" ]]; then
    warn "Existing $CONFIG_PATH found."
    info "Current contents:"
    sudo cat "$CONFIG_PATH" | sed 's/^/      /'
    echo ""
    if ! confirm "Overwrite with fresh config for tunnel '$TUNNEL_NAME' routing '$SUBDOMAIN' → localhost:$PORT?"; then
        info "Skipped config write. You can merge manually and restart cloudflared."
        SKIP_CONFIG=true
    fi
fi

if [[ "${SKIP_CONFIG:-false}" != "true" ]]; then
    sudo tee "$CONFIG_PATH" >/dev/null <<YAML
tunnel: $TUNNEL_UUID
credentials-file: /etc/cloudflared/${TUNNEL_UUID}.json

ingress:
  - hostname: $SUBDOMAIN
    service: http://localhost:$PORT
  - service: http_status:404
YAML
    ok "Wrote $CONFIG_PATH"
fi

# ---- Create DNS route ----

step "Creating DNS route"
if cloudflared tunnel route dns "$TUNNEL_NAME" "$SUBDOMAIN" 2>&1 | tee /tmp/route-dns-output; then
    ok "DNS route created (or already existed)"
else
    fail "DNS route creation failed. See above for details."
    info "Common cause: the zone for '$SUBDOMAIN' isn't in the account your cert"
    info "was issued for. Move cert.pem aside and re-authenticate picking the"
    info "correct zone, then re-run this script."
    exit 1
fi

# ---- Install systemd service ----

step "Installing systemd service"
if systemctl list-unit-files cloudflared.service &>/dev/null && systemctl is-enabled --quiet cloudflared; then
    ok "cloudflared.service already installed — restarting to pick up new config"
    sudo systemctl restart cloudflared
else
    sudo cloudflared service install
    sudo systemctl start cloudflared
    sudo systemctl enable cloudflared
    ok "Service installed and started"
fi

sleep 2
if systemctl is-active --quiet cloudflared; then
    ok "cloudflared is running"
else
    fail "cloudflared is not running. Check: sudo journalctl -u cloudflared -n 30"
    exit 1
fi

# ---- Final verify ----

step "Done"
info "The demo should be live at: https://$SUBDOMAIN/"
info ""
info "DNS may take ~30s to propagate. Test from a device outside this network"
info "(e.g. your phone on cellular) for the fastest confirmation."
info ""
info "Future updates: ./refresh-demo.sh"
