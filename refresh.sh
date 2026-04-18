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

# Detect SSL mode and port from UI_PORT
UI_HOST_PORT="$(grep '^UI_PORT=' .env 2>/dev/null | cut -d= -f2 || echo '4200')"
if [[ "$UI_HOST_PORT" == "443" ]]; then
    MAINT_SSL="true"
    MAINT_PORT_MAP="${UI_HOST_PORT}:443"
else
    MAINT_SSL="false"
    MAINT_PORT_MAP="${UI_HOST_PORT}:80"
fi

# Stop the real UI first to free the port
docker compose stop qb-engineer-ui 2>/dev/null || true
docker compose rm -sf qb-engineer-ui 2>/dev/null || true

# Build and start the maintenance container on the same port
docker build -q -t qb-maintenance maintenance/
docker rm -f qb-maintenance 2>/dev/null || true
docker run -d --name qb-maintenance \
    -p "${MAINT_PORT_MAP}" \
    -e SSL_MODE="${MAINT_SSL}" \
    --restart no \
    qb-maintenance

ok "Maintenance dragon is guarding port ${UI_HOST_PORT}"

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

# Detect scheme from .env
if grep -q "^UI_PORT=443" .env 2>/dev/null; then
    SCHEME="https"
    UI_URL="${SCHEME}://localhost"
elif grep -q "^UI_PORT=80" .env 2>/dev/null; then
    SCHEME="http"
    UI_URL="http://localhost"
else
    SCHEME="http"
    UI_URL="http://localhost:4200"
fi

HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")

echo ""
echo "  UI:      $UI_URL"
if [[ -n "${HOST_IP:-}" ]]; then
echo "  Network: ${SCHEME}://${HOST_IP}"
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
