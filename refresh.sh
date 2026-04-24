#!/usr/bin/env bash
# refresh.sh — Pull latest code, rebuild, and restart QB Engineer
#
# Bash equivalent of refresh.ps1 for Linux / macOS users.
# Auto-detects platform — works on x86_64, ARM, macOS, any Linux distro.
#
# Usage:
#   ./refresh.sh                   # Pull main, rebuild, start core services
#   ./refresh.sh --include-ai      # Also start Ollama AI assistant
#   ./refresh.sh --include-signing # Also start DocuSeal signing service
#   ./refresh.sh --recreate-db     # Wipe and reseed the database
#   ./refresh.sh --include-ai --include-signing

set -euo pipefail

INCLUDE_AI=false
INCLUDE_SIGNING=false
RECREATE_DB=false

for arg in "$@"; do
    case $arg in
        --include-ai)      INCLUDE_AI=true ;;
        --include-signing) INCLUDE_SIGNING=true ;;
        --recreate-db)     RECREATE_DB=true ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# ─────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────

step()  { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
ok()    { printf '    \033[32m[OK] %s\033[0m\n' "$1"; }
warn()  { printf '    \033[33m[!!] %s\033[0m\n' "$1"; }

# Helper: set or append a key=value in .env
set_env() {
    local key="$1" val="$2"
    if grep -q "^${key}=" .env 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" .env
    else
        echo "${key}=${val}" >> .env
    fi
}

# ─────────────────────────────────────────────────────────────
# Platform detection
# ─────────────────────────────────────────────────────────────

IS_MAC=false
IS_ARM=false
IS_LOW_RAM=false

if [[ "$(uname)" == "Darwin" ]]; then
    IS_MAC=true
fi

ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    IS_ARM=true
fi

if $IS_MAC; then
    TOTAL_MEM_MB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 ))
elif [[ -f /proc/meminfo ]]; then
    TOTAL_MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
else
    TOTAL_MEM_MB=0
fi

if (( TOTAL_MEM_MB > 0 && TOTAL_MEM_MB < 7500 )); then
    IS_LOW_RAM=true
fi

# ─────────────────────────────────────────────────────────────
# Pre-flight
# ─────────────────────────────────────────────────────────────

step "Pre-flight checks"

if ! command -v docker &>/dev/null; then
    echo "    Docker not found. Install Docker and try again."
    exit 1
fi

if ! docker info &>/dev/null 2>&1; then
    echo "    Docker daemon is not running. Start it and try again."
    exit 1
fi
ok "Docker is running"

if [[ ! -f "docker-compose.yml" ]]; then
    echo "    Run this script from the repo root (where docker-compose.yml lives)."
    exit 1
fi
ok "Working directory: $(pwd)"

$IS_ARM     && ok "Architecture: ARM ($ARCH)"
$IS_LOW_RAM && ok "Low-RAM mode: ${TOTAL_MEM_MB} MB"

# ─────────────────────────────────────────────────────────────
# Hosting mode (read-only — refresh.sh never re-detects)
# ─────────────────────────────────────────────────────────────
# setup.sh writes QBE_HOSTING_MODE to .env. Refresh always trusts that value so
# a fresh clone + git pull can't accidentally flip modes on a prod box.
HOSTING_MODE="standalone"
if [[ -f .env ]] && grep -q "^QBE_HOSTING_MODE=" .env 2>/dev/null; then
    HOSTING_MODE=$(grep "^QBE_HOSTING_MODE=" .env | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs)
fi
IS_COHOST=false
[[ "$HOSTING_MODE" == "cohost" ]] && IS_COHOST=true
ok "Hosting mode: ${HOSTING_MODE}"

# ─────────────────────────────────────────────────────────────
# Git pull main
# ─────────────────────────────────────────────────────────────

step "Pulling latest code from main"

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
if [[ "$CURRENT_BRANCH" != "main" ]]; then
    warn "Currently on branch '$CURRENT_BRANCH' — switching to main"
    git checkout main
fi

git pull origin main
ok "Pulled latest code"

# ─────────────────────────────────────────────────────────────
# Build version
# ─────────────────────────────────────────────────────────────

BUILD_VERSION=$(git rev-list --count HEAD 2>/dev/null || echo "0")
BUILD_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "dev")
export BUILD_VERSION BUILD_SHA
ok "Build version: $BUILD_VERSION ($BUILD_SHA)"

VERSION_DIR="qb-engineer-ui/public/assets"
if [[ -d "$VERSION_DIR" ]]; then
    echo -n "{\"version\":\"${BUILD_VERSION}\",\"sha\":\"${BUILD_SHA}\"}" > "${VERSION_DIR}/version.json"
    ok "Wrote ${VERSION_DIR}/version.json"
fi

# ─────────────────────────────────────────────────────────────
# Spin up maintenance page before tearing down the real site
# ─────────────────────────────────────────────────────────────

step "Swapping in maintenance page"

# Detect host port from the ACTUAL running UI container — whatever port the
# real UI is bound to, maintenance takes over. This avoids drift between
# .env, override YAML, and whatever's actually live (e.g. reverse-proxy setups,
# manually-edited compose, prior sessions with different UI_PORT values).
UI_HOST_PORT=""
UI_CONTAINER_PORT=""
if docker inspect qb-engineer-ui &>/dev/null; then
    # Parse "HostPort/ContainerPort" from the first published mapping.
    # Format: {"80/tcp": [{"HostIp":"0.0.0.0","HostPort":"443"}], ...}
    UI_PORT_LINE=$(docker inspect --format \
        '{{range $cp, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{.HostPort}}/{{$cp}} {{end}}{{end}}' \
        qb-engineer-ui 2>/dev/null | tr ' ' '\n' | grep -v '^$' | head -1 || true)
    if [[ -n "$UI_PORT_LINE" ]]; then
        # Format: "HOST/CONTAINER/tcp" — strip host prefix, then /tcp suffix
        UI_HOST_PORT="${UI_PORT_LINE%%/*}"
        UI_REMAINING="${UI_PORT_LINE#*/}"
        UI_CONTAINER_PORT="${UI_REMAINING%%/*}"
        ok "Detected live UI binding: ${UI_HOST_PORT} → container ${UI_CONTAINER_PORT}"
    fi
fi

# Fallback chain if no running container (fresh clone, crashed stack, etc.):
# override file → .env → default.
if [[ -z "$UI_HOST_PORT" ]]; then
    if [[ -f "docker-compose.override.yml" ]]; then
        # Match both quoted ("443:443") and unquoted (- 443:443) YAML array forms.
        OVERRIDE_PORT=$(grep -A20 'qb-engineer-ui' docker-compose.override.yml 2>/dev/null \
            | grep -oP '^\s*-\s*"?\K[0-9]+(?=:)' | head -1 || true)
    fi
    if [[ -n "${OVERRIDE_PORT:-}" ]]; then
        UI_HOST_PORT="$OVERRIDE_PORT"
    else
        UI_HOST_PORT="$(grep '^UI_PORT=' .env 2>/dev/null | cut -d= -f2 || echo '4200')"
    fi
    warn "No running UI container — falling back to detected port ${UI_HOST_PORT}"
fi

# Build the host port map. Maintenance nginx always listens on BOTH :80 and
# :443 internally (with a self-signed cert on :443), so a browser that does
# HTTPS-Only upgrade, cached HSTS, or just picks the wrong scheme still lands
# on the maintenance page instead of "can't connect".
#
# Standalone: when the real UI is on a standard port (80 or 443), publish BOTH
#   host ports — covers http:// and https:// regardless of what the browser
#   tries. For dev ports (4200 etc.) we publish only the one port (and also
#   tack on :443 since HTTPS-Only can still bite).
# Cohost: the host-level proxy owns :80 and :443 — publishing them here would
#   fail or silently steal traffic from the proxy. Bind to 127.0.0.1 on the
#   configured UI port only. The host proxy will see maintenance upstream
#   during the swap window exactly as it sees the real UI.
declare -a MAINT_PORT_MAPS=()
if $IS_COHOST; then
    MAINT_PORT_MAPS+=("127.0.0.1:${UI_HOST_PORT}:80")
elif [[ "$UI_HOST_PORT" == "80" || "$UI_HOST_PORT" == "443" ]]; then
    MAINT_PORT_MAPS+=("80:80" "443:443")
else
    # Dev port: publish that port -> container :80, plus try to also grab :443.
    MAINT_PORT_MAPS+=("${UI_HOST_PORT}:80" "443:443")
fi

# Stop the real UI first to free the port(s)
docker compose stop qb-engineer-ui 2>/dev/null || true
docker compose rm -sf qb-engineer-ui 2>/dev/null || true

# Always rebuild the maintenance image — Dockerfile copies are fast when the
# nginx:alpine base is cached, and this ensures config changes land reliably
# without requiring a manual rebuild.
echo "    Building maintenance image..."
docker build -q -t qb-maintenance maintenance/ >/dev/null
docker rm -f qb-maintenance 2>/dev/null || true

# Detect the compose network name so maintenance can register as a
# `qb-engineer-ui` alias — any reverse proxy (Nginx Proxy Manager, Traefik,
# Caddy) that points at the compose hostname continues to resolve during
# refresh instead of hitting a dead upstream.
COMPOSE_NETWORK=$(docker network ls --format '{{.Name}}' | grep -E '^qb-engineer-wrapper_' | head -1 || true)

# Assemble the `docker run` invocation — try dual-port first, fall back to
# single-port if :443 is already taken by something else on the host.
build_run_args() {
    local -n arr=$1
    arr=(-d --name qb-maintenance --restart no)
    if [[ -n "$COMPOSE_NETWORK" ]]; then
        arr+=(--network "$COMPOSE_NETWORK" --network-alias qb-engineer-ui)
    fi
    # Mount the same cert the real UI uses (Cloudflare Origin Cert, Let's
    # Encrypt, etc.) so CF Full-strict and strict reverse proxies accept
    # the maintenance page during refresh. Falls through to self-signed
    # inside the container if ./certs doesn't exist.
    if [[ -f ./certs/selfsigned.crt && -f ./certs/selfsigned.key ]]; then
        arr+=(-v "$(pwd)/certs:/etc/nginx/certs:ro")
    fi
    for map in "${MAINT_PORT_MAPS[@]}"; do
        arr+=(-p "$map")
    done
    arr+=(qb-maintenance)
}

declare -a RUN_ARGS
build_run_args RUN_ARGS

if ! docker run "${RUN_ARGS[@]}" &>/dev/null; then
    warn "Dual-port bind failed (likely :443 occupied) — retrying with primary port only"
    docker rm -f qb-maintenance 2>/dev/null || true
    if $IS_COHOST; then
        MAINT_PORT_MAPS=("127.0.0.1:${UI_HOST_PORT}:80")
    else
        MAINT_PORT_MAPS=("${UI_HOST_PORT}:80")
        [[ "$UI_HOST_PORT" == "443" ]] && MAINT_PORT_MAPS=("443:443")
    fi
    build_run_args RUN_ARGS
    docker run "${RUN_ARGS[@]}" >/dev/null
fi

ok "Maintenance dragon is guarding ports: ${MAINT_PORT_MAPS[*]}"
[[ -n "$COMPOSE_NETWORK" ]] && ok "  attached to ${COMPOSE_NETWORK} as qb-engineer-ui"

# ─────────────────────────────────────────────────────────────
# Remove running app containers (preserve db + storage volumes)
# ─────────────────────────────────────────────────────────────

step "Removing app containers"
docker compose rm -sf qb-engineer-api 2>/dev/null || true
ok "Removed API container"

# ─────────────────────────────────────────────────────────────
# Check for dependency changes
# ─────────────────────────────────────────────────────────────

step "Checking for dependency changes"
PKG_CHANGED=$(git diff 'HEAD@{1}' --name-only 2>/dev/null | grep "qb-engineer-ui/package" || true)
if [[ -n "$PKG_CHANGED" ]]; then
    warn "package.json changed — recreating node_modules volume"
    docker volume rm -f qb-engineer-wrapper_ui_node_modules 2>/dev/null || true
else
    ok "No package.json changes detected"
fi

# ─────────────────────────────────────────────────────────────
# Build images
# ─────────────────────────────────────────────────────────────

step "Building images (no cache)"
$IS_ARM && warn "ARM builds are slower — this may take a few minutes"

echo "    Building API image..."
docker compose build --no-cache qb-engineer-api
ok "API image built"

echo "    Building UI image..."
docker compose build --no-cache qb-engineer-ui
ok "UI image built"

# ─────────────────────────────────────────────────────────────
# Start services
# ─────────────────────────────────────────────────────────────

step "Starting core services"

if $RECREATE_DB; then
    set_env "RECREATE_DB" "true"
    warn "RECREATE_DB=true — database will be wiped and reseeded"
fi

# Start everything except UI — maintenance container holds the port
docker compose up -d --force-recreate --remove-orphans \
    qb-engineer-db \
    qb-engineer-storage \
    qb-engineer-backup \
    qb-engineer-api

# --- Optional: AI ---
if $INCLUDE_AI; then
    step "Starting AI service (Ollama)"
    warn "First run pulls gemma3:4b + all-minilm:l6-v2 — this can take several minutes"
    docker compose --profile ai up -d qb-engineer-ai qb-engineer-ai-init
else
    warn "Skipping AI service. Add --include-ai to include Ollama."
fi

# --- Optional: Signing ---
if $INCLUDE_SIGNING; then
    step "Starting DocuSeal signing service"
    docker compose --profile signing up -d qb-engineer-signing
else
    warn "Skipping signing service. Add --include-signing to include DocuSeal."
fi

# ─────────────────────────────────────────────────────────────
# Wait for API health
# ─────────────────────────────────────────────────────────────

step "Waiting for API to become healthy"

# Longer timeout for ARM / low-RAM systems
if $IS_ARM || $IS_LOW_RAM; then
    MAX_WAIT=120
else
    MAX_WAIT=60
fi

ELAPSED=0
HEALTHY=false

while (( ELAPSED < MAX_WAIT )); do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' qb-engineer-api 2>/dev/null || echo "unknown")
    if [[ "$STATUS" == "healthy" ]]; then
        HEALTHY=true
        break
    fi
    printf "\r    API status: %s (%ds / %ds)" "$STATUS" "$ELAPSED" "$MAX_WAIT"
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done
echo ""

if $HEALTHY; then
    ok "API is healthy"
else
    warn "API health check timed out after ${MAX_WAIT}s — check logs: docker compose logs -f qb-engineer-api"
fi

# ─────────────────────────────────────────────────────────────
# Swap maintenance container → real UI
# ─────────────────────────────────────────────────────────────

step "Swapping maintenance page for real UI"
docker rm -f qb-maintenance 2>/dev/null || true
docker compose up -d --force-recreate qb-engineer-ui
ok "Real UI is live — dragon dismissed"

# Reset RECREATE_DB so next restart doesn't wipe again
if $RECREATE_DB; then
    set_env "RECREATE_DB" "false"
    ok "Reset RECREATE_DB=false"
fi

# ─────────────────────────────────────────────────────────────
# Status
# ─────────────────────────────────────────────────────────────

step "Container status"
docker compose ps

# Detect scheme — reuse UI_HOST_PORT detected earlier
if [[ "$UI_HOST_PORT" == "443" ]]; then
    SCHEME="https"
    UI_URL="${SCHEME}://localhost"
elif [[ "$UI_HOST_PORT" == "80" ]]; then
    SCHEME="http"
    UI_URL="http://localhost"
else
    SCHEME="http"
    UI_URL="http://localhost:${UI_HOST_PORT}"
fi

HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")

echo ""
if $IS_COHOST; then
echo "  UI (internal):  $UI_URL  (served via host-level proxy)"
echo "  Public URL:     whatever your reverse proxy is configured to serve"
else
echo "  UI:      $UI_URL"
if [[ -n "${HOST_IP:-}" ]]; then
echo "  Network: ${SCHEME}://${HOST_IP}"
fi
fi
echo "  API:     http://localhost:5000"
echo "  MinIO:   http://localhost:9001  (minioadmin / minioadmin)"
$INCLUDE_AI      && echo "  Ollama:  http://localhost:11434"
$INCLUDE_SIGNING && echo "  DocuSeal: http://localhost:3000"
echo ""
echo "  Logs:    docker compose logs -f qb-engineer-api"
echo "  Stop:    docker compose stop"
echo "  DB CLI:  docker compose exec qb-engineer-db psql -U postgres -d qb_engineer"
echo ""
echo "  IMPORTANT: Hard-refresh your browser (Ctrl+Shift+R / Cmd+Shift+R)"
echo "             to pick up the latest UI changes."
echo ""
