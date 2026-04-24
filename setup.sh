#!/usr/bin/env bash
# setup.sh — First-time setup for QB Engineer (Linux / macOS)
#
# Bash equivalent of setup.ps1 for users who prefer a native shell.
# Auto-detects platform, architecture, and available resources.
# Applies memory tuning on low-RAM systems, offers SSL on headless/server installs.
#
# Run from the repo root after cloning:
#   chmod +x setup.sh
#   ./setup.sh
#
# Options:
#   --seeded             Seed demo data (users, jobs, customers, etc.)
#   --fresh              Wipe existing database and start over
#   --fresh --seeded     Wipe database and reseed with demo data
#   --include-ai         Also start Ollama AI assistant
#   --include-tts        Also start Coqui TTS for training video narration
#   --include-signing    Also start DocuSeal e-signature service
#   --include-all        All optional profiles
#   --ssl                Generate self-signed SSL cert and serve on 443
#   --no-ssl             Skip SSL even if auto-detected as headless
#   --cohost             Run behind an existing host-level reverse proxy
#                        (nginx, Caddy, cloudflared). Skip in-container TLS,
#                        keep UI on 127.0.0.1:4200.
#   --standalone         Own the full host (nginx + TLS inside the stack).

set -euo pipefail

SEED_DEMO=false
FRESH=false
INCLUDE_AI=false
INCLUDE_TTS=false
INCLUDE_SIGNING=false
SSL_FLAG=""   # "" = auto-detect, "force" = --ssl, "skip" = --no-ssl
MODE_FLAG=""  # "" = auto/use .env, "cohost" or "standalone" force

for arg in "$@"; do
    case $arg in
        --seeded)          SEED_DEMO=true ;;
        --fresh)           FRESH=true ;;
        --include-ai)      INCLUDE_AI=true ;;
        --include-tts)     INCLUDE_TTS=true ;;
        --include-signing) INCLUDE_SIGNING=true ;;
        --include-all)     INCLUDE_AI=true; INCLUDE_TTS=true; INCLUDE_SIGNING=true ;;
        --ssl)             SSL_FLAG="force" ;;
        --no-ssl)          SSL_FLAG="skip" ;;
        --cohost)          MODE_FLAG="cohost" ;;
        --standalone)      MODE_FLAG="standalone" ;;
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

bail() {
    echo ""
    fail "Missing prerequisite: $1"
    echo ""
    shift
    for line in "$@"; do
        info "$line"
    done
    echo ""
    info "After installing, close this terminal and re-run:"
    info "  ./setup.sh"
    echo ""
    exit 1
}

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
IS_LINUX=false
IS_ARM=false
IS_LOW_RAM=false
IS_HEADLESS=false
TOTAL_MEM_MB=0

if [[ "$(uname)" == "Darwin" ]]; then
    IS_MAC=true
else
    IS_LINUX=true
fi

ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    IS_ARM=true
fi

# Detect available RAM
if $IS_MAC; then
    TOTAL_MEM_MB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 ))
elif [[ -f /proc/meminfo ]]; then
    TOTAL_MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
fi

if (( TOTAL_MEM_MB > 0 && TOTAL_MEM_MB < 7500 )); then
    IS_LOW_RAM=true
fi

# Detect headless (no display server)
if $IS_LINUX && [[ -z "${DISPLAY:-}" ]] && [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
    IS_HEADLESS=true
fi

# ─────────────────────────────────────────────────────────────
# Hosting mode resolution (cohost vs standalone)
# ─────────────────────────────────────────────────────────────
# Precedence:
#   1. --cohost / --standalone CLI flag
#   2. QBE_HOSTING_MODE in existing .env
#   3. Auto-detect: nginx vhost for qb-engineer, or active cloudflared
#   4. Default: standalone
HOSTING_MODE=""
MODE_SOURCE=""

if [[ -n "$MODE_FLAG" ]]; then
    HOSTING_MODE="$MODE_FLAG"
    MODE_SOURCE="CLI flag"
elif [[ -f .env ]] && grep -q "^QBE_HOSTING_MODE=" .env 2>/dev/null; then
    HOSTING_MODE=$(grep "^QBE_HOSTING_MODE=" .env | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs)
    MODE_SOURCE=".env"
fi

if [[ -z "$HOSTING_MODE" ]]; then
    # Auto-detect: host-level nginx vhost or active cloudflared
    if ls /etc/nginx/sites-enabled/qb-engineer*.conf &>/dev/null 2>&1 || \
       ls /etc/nginx/conf.d/qb-engineer*.conf &>/dev/null 2>&1; then
        HOSTING_MODE="cohost"
        MODE_SOURCE="detected host nginx vhost"
    elif command -v systemctl &>/dev/null && systemctl is-active --quiet cloudflared 2>/dev/null; then
        HOSTING_MODE="cohost"
        MODE_SOURCE="detected active cloudflared"
    elif [[ -f /etc/cloudflared/config.yml ]] || [[ -f /etc/cloudflared/config.yaml ]]; then
        HOSTING_MODE="cohost"
        MODE_SOURCE="detected cloudflared config"
    else
        HOSTING_MODE="standalone"
        MODE_SOURCE="default"
    fi
fi

IS_COHOST=false
[[ "$HOSTING_MODE" == "cohost" ]] && IS_COHOST=true

# Resolve SSL mode — cohost never enables in-container SSL (host proxy terminates TLS)
ENABLE_SSL=false
if $IS_COHOST; then
    ENABLE_SSL=false
elif [[ "$SSL_FLAG" == "force" ]]; then
    ENABLE_SSL=true
elif [[ "$SSL_FLAG" == "skip" ]]; then
    ENABLE_SSL=false
elif $IS_HEADLESS; then
    # Auto-enable SSL for headless servers (accessed over network)
    ENABLE_SSL=true
fi

# ─────────────────────────────────────────────────────────────
# Banner
# ─────────────────────────────────────────────────────────────

echo ""
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║        QB Engineer — First-Time Setup        ║"
echo "  ╚══════════════════════════════════════════════╝"
echo ""

# ─────────────────────────────────────────────────────────────
# 1. System check
# ─────────────────────────────────────────────────────────────

step "Checking system"

ok "Platform: $(uname -s) ($ARCH)"

if $IS_ARM; then
    # Warn on 32-bit ARM (unsupported by .NET 9)
    if [[ "$ARCH" != "aarch64" && "$ARCH" != "arm64" ]]; then
        warn "32-bit ARM detected — .NET 9 requires 64-bit. This may not work."
    else
        ok "Architecture: 64-bit ARM"
    fi
fi

if (( TOTAL_MEM_MB > 0 )); then
    if (( TOTAL_MEM_MB < 3500 )); then
        warn "Only ${TOTAL_MEM_MB} MB RAM. Minimum recommended: 4 GB."
        warn "The stack may run but could be slow or OOM-kill containers."
    elif $IS_LOW_RAM; then
        ok "${TOTAL_MEM_MB} MB RAM (memory tuning will be applied)"
    else
        ok "${TOTAL_MEM_MB} MB RAM"
    fi
fi

$IS_HEADLESS && ok "Headless server detected"
$ENABLE_SSL  && ok "SSL will be configured"
if $IS_COHOST; then
    ok "Hosting mode: cohost (${MODE_SOURCE}) — host-level proxy terminates TLS"
else
    ok "Hosting mode: standalone (${MODE_SOURCE})"
fi

# ─────────────────────────────────────────────────────────────
# 2. Prerequisites
# ─────────────────────────────────────────────────────────────

step "Checking prerequisites"

# --- Git ---
if ! command -v git &>/dev/null; then
    if $IS_MAC; then
        bail "Git" \
            "Install via Homebrew:  brew install git" \
            "Or install Xcode CLI:  xcode-select --install"
    else
        bail "Git" \
            "Install via your package manager:" \
            "  Ubuntu/Debian:  sudo apt install git" \
            "  Fedora/RHEL:    sudo dnf install git" \
            "  Arch:           sudo pacman -S git"
    fi
fi
ok "Git $(git --version 2>/dev/null)"

# --- Docker ---
if ! command -v docker &>/dev/null; then
    if $IS_MAC; then
        bail "Docker" \
            "Download Docker Desktop from: https://www.docker.com/products/docker-desktop/" \
            "Or install via Homebrew:  brew install --cask docker" \
            "Then launch Docker Desktop and wait for it to finish starting."
    else
        bail "Docker" \
            "Install Docker Engine:" \
            "  https://docs.docker.com/engine/install/" \
            "" \
            "Quick install (Ubuntu/Debian):" \
            "  curl -fsSL https://get.docker.com | sudo sh" \
            "" \
            "Then add your user to the docker group:" \
            "  sudo usermod -aG docker \$USER" \
            "  Log out and back in for this to take effect."
    fi
fi

# --- Docker daemon ---
if ! docker info &>/dev/null 2>&1; then
    if docker info 2>&1 | grep -qi "permission denied"; then
        bail "Docker (permissions)" \
            "Docker is installed but your user cannot access it." \
            "" \
            "Add your user to the docker group:" \
            "  sudo usermod -aG docker \$USER" \
            "" \
            "Then log out and back in (or run: newgrp docker)."
    else
        if $IS_MAC; then
            bail "Docker (daemon)" \
                "Docker is installed but not running." \
                "Open Docker Desktop and wait for it to show 'Docker Desktop is running'."
        else
            bail "Docker (daemon)" \
                "Docker is installed but the daemon is not running." \
                "" \
                "Start it:" \
                "  sudo systemctl start docker" \
                "" \
                "Enable on boot:" \
                "  sudo systemctl enable docker"
        fi
    fi
fi
ok "Docker $(docker --version 2>/dev/null)"

# --- Docker Compose ---
if ! docker compose version &>/dev/null 2>&1; then
    bail "Docker Compose" \
        "Docker Compose v2 is required." \
        "" \
        "Docker Desktop includes Compose v2 by default." \
        "On Linux, install the compose plugin:" \
        "  sudo apt install docker-compose-plugin" \
        "" \
        "Verify: docker compose version"
fi
ok "$(docker compose version 2>/dev/null)"

# --- Disk space ---
if $IS_MAC; then
    FREE_GB=$(df -g . 2>/dev/null | tail -1 | awk '{print $4}')
else
    FREE_GB=$(df --output=avail -BG . 2>/dev/null | tail -1 | tr -dc '0-9')
fi
if [[ -n "${FREE_GB:-}" ]] && (( FREE_GB < 10 )); then
    warn "Only ${FREE_GB} GB free. Recommended: 20+ GB."
    $IS_ARM && warn "Consider using a USB SSD instead of the SD card for Docker storage."
elif [[ -n "${FREE_GB:-}" ]]; then
    ok "${FREE_GB} GB free disk space"
fi

# --- Port check ---
# In cohost mode, all services bind 127.0.0.1 — conflict only if another local
# process holds the same port. In standalone+SSL, we bind 80/443 on 0.0.0.0.
CONFLICTS=""
CHECK_PORTS="4200 5000 5432 9000 9001"
if $ENABLE_SSL && ! $IS_COHOST; then
    CHECK_PORTS="80 443 5000 5432 9000 9001"
fi
for PORT in $CHECK_PORTS; do
    if $IS_MAC; then
        if lsof -iTCP:"$PORT" -sTCP:LISTEN &>/dev/null 2>&1; then
            CONFLICTS="$CONFLICTS $PORT"
        fi
    else
        if ss -tlnp 2>/dev/null | grep -q ":${PORT} " 2>/dev/null; then
            CONFLICTS="$CONFLICTS $PORT"
        fi
    fi
done
if [[ -n "$CONFLICTS" ]]; then
    warn "Ports already in use:$CONFLICTS"
    warn "You can change ports in .env after setup."
    read -rp "    Continue anyway? (y/N) " yn
    [[ "$yn" =~ ^[Yy]$ ]] || exit 1
else
    ok "Required ports are available ($CHECK_PORTS)"
fi

# --- openssl (only needed if SSL enabled) ---
if $ENABLE_SSL && ! command -v openssl &>/dev/null; then
    bail "openssl" \
        "openssl is required to generate the self-signed SSL certificate." \
        "" \
        "Install it:" \
        "  Ubuntu/Debian:  sudo apt install openssl" \
        "  Fedora/RHEL:    sudo dnf install openssl" \
        "  macOS:          brew install openssl"
fi

echo ""
ok "All prerequisites met!"

# ─────────────────────────────────────────────────────────────
# 3. Project files
# ─────────────────────────────────────────────────────────────

step "Verifying project files"

if [[ ! -f "docker-compose.yml" ]]; then
    fail "docker-compose.yml not found."
    info "Run this script from the repo root:"
    info "  cd qb-engineer-wrapper && ./setup.sh"
    exit 1
fi

if [[ ! -f ".env.example" ]]; then
    fail ".env.example not found — the repo may be incomplete."
    info "Try a fresh clone:"
    info "  git clone https://github.com/danielhokanson/qb-engineer-wrapper.git"
    exit 1
fi

ok "Project files found"

# ─────────────────────────────────────────────────────────────
# 4. Create .env
# ─────────────────────────────────────────────────────────────

step "Configuring environment"

if [[ -f ".env" ]]; then
    ok ".env already exists — skipping creation"
    warn "To regenerate, delete .env and re-run setup.sh"
else
    cp .env.example .env

    # Generate random JWT key
    JWT_KEY=$(head -c 256 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 48 || true)
    sed -i "s|JWT_KEY=dev-secret-key-change-in-production-min-32-chars!!|JWT_KEY=${JWT_KEY}|" .env

    # For headless/server installs, configure network access.
    # In cohost mode the host-level proxy owns 80/443 + the public hostname, so
    # we keep UI on 127.0.0.1:4200 and leave URL env vars alone (user edits .env
    # manually to set FRONTEND_BASE_URL / CORS_ORIGINS to the external hostname).
    if ( $IS_HEADLESS || $ENABLE_SSL ) && ! $IS_COHOST; then
        HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

        if $ENABLE_SSL; then
            SCHEME="https"
            sed -i "s|^UI_PORT=4200|UI_PORT=443|" .env
        else
            SCHEME="http"
            sed -i "s|^UI_PORT=4200|UI_PORT=80|" .env
        fi

        if [[ -n "${HOST_IP:-}" ]]; then
            sed -i "s|^FRONTEND_BASE_URL=http://localhost:4200|FRONTEND_BASE_URL=${SCHEME}://${HOST_IP}|" .env
            sed -i "s|^CORS_ORIGINS=http://localhost:4200|CORS_ORIGINS=${SCHEME}://${HOST_IP},${SCHEME}://localhost,http://${HOST_IP},http://localhost|" .env
            sed -i "s|^MINIO_PUBLIC_ENDPOINT=localhost:9000|MINIO_PUBLIC_ENDPOINT=${HOST_IP}:9000|" .env
            ok "Detected host IP: $HOST_IP"
        else
            warn "Could not detect IP — you may need to edit CORS_ORIGINS in .env"
        fi

        # Server installs default to production-ish settings
        sed -i "s|^MOCK_INTEGRATIONS=true|MOCK_INTEGRATIONS=false|" .env
    fi

    if $IS_COHOST; then
        # In cohost mode, the host-level proxy controls the public URL. The
        # user must edit FRONTEND_BASE_URL / CORS_ORIGINS / MINIO_PUBLIC_ENDPOINT
        # in .env to match the external hostname (e.g. https://qb-engineer.com).
        sed -i "s|^MOCK_INTEGRATIONS=true|MOCK_INTEGRATIONS=false|" .env
        warn "Cohost mode: edit .env to set FRONTEND_BASE_URL, CORS_ORIGINS, and"
        warn "MINIO_PUBLIC_ENDPOINT to the hostname served by your reverse proxy."
        warn "See docs/cohosting.md for the full walkthrough."
    fi

    # Demo data — only seeded with --seeded flag
    if $SEED_DEMO; then
        sed -i "s|^SEED_DEMO_DATA=true|SEED_DEMO_DATA=true|" .env
        ok "Demo data will be seeded (users, jobs, customers, etc.)"
    else
        sed -i "s|^SEED_DEMO_DATA=true|SEED_DEMO_DATA=false|" .env
        ok "Clean install — no demo data (setup wizard creates your admin account)"
    fi

    ok "Created .env with random JWT key"
fi

# Prompt for seed user password when seeding demo data
if $SEED_DEMO; then
    step "Demo data user password"
    echo ""
    echo "    Demo data includes 9 test users (admin@qbengineer.local, etc.)"
    echo "    You must set a temporary password for these accounts."
    echo "    Requirements: 8+ chars, uppercase, lowercase, digit, special char"
    echo ""
    while true; do
        read -rsp "    Enter password for demo users: " SEED_PASSWORD
        echo ""
        if [[ ${#SEED_PASSWORD} -lt 8 ]]; then
            warn "Password must be at least 8 characters"
        elif [[ ! "$SEED_PASSWORD" =~ [A-Z] ]]; then
            warn "Password must contain an uppercase letter"
        elif [[ ! "$SEED_PASSWORD" =~ [a-z] ]]; then
            warn "Password must contain a lowercase letter"
        elif [[ ! "$SEED_PASSWORD" =~ [0-9] ]]; then
            warn "Password must contain a digit"
        elif [[ ! "$SEED_PASSWORD" =~ [^A-Za-z0-9] ]]; then
            warn "Password must contain a special character"
        else
            break
        fi
    done
    set_env "SEED_USER_PASSWORD" "$SEED_PASSWORD"
    ok "Seed user password set"
fi

# Apply --fresh and --seeded flags (works on both new and existing .env)
if $FRESH; then
    set_env "RECREATE_DB" "true"
    if $SEED_DEMO; then
        set_env "SEED_DEMO_DATA" "true"
    fi
    warn "--fresh: database will be wiped and recreated on next start"
fi

# Persist the resolved hosting mode so future runs (including refresh.sh)
# pick it up without re-detecting.
set_env "QBE_HOSTING_MODE" "$HOSTING_MODE"

# Bind addresses: the base docker-compose.yml defaults every *_BIND var to
# 127.0.0.1 (loopback) so cohost mode is safe out of the box. In standalone
# mode, we restore the pre-cohost-refactor behavior (all services on
# 0.0.0.0) so existing workflows — hitting Postgres from DBeaver over LAN,
# MinIO console on port 9001, the API directly from a mobile test device,
# etc. — keep working exactly as they did. Users who want tighter binds
# can override any individual *_BIND in .env after setup.
if $IS_COHOST; then
    # Remove any stale 0.0.0.0 binds from a previous standalone run so
    # the compose-level 127.0.0.1 default takes over.
    for v in UI_BIND API_BIND POSTGRES_BIND MINIO_BIND AI_BIND TTS_BIND DOCUSEAL_BIND DEMO_BIND; do
        if grep -q "^${v}=" .env 2>/dev/null; then
            sed -i "/^${v}=/d" .env
        fi
    done
else
    set_env "UI_BIND" "0.0.0.0"
    set_env "API_BIND" "0.0.0.0"
    set_env "POSTGRES_BIND" "0.0.0.0"
    set_env "MINIO_BIND" "0.0.0.0"
    set_env "AI_BIND" "0.0.0.0"
    set_env "TTS_BIND" "0.0.0.0"
    set_env "DOCUSEAL_BIND" "0.0.0.0"
    set_env "DEMO_BIND" "0.0.0.0"
fi

# ─────────────────────────────────────────────────────────────
# 5. Write version.json
# ─────────────────────────────────────────────────────────────

step "Writing build version"

BUILD_VERSION=$(git rev-list --count HEAD 2>/dev/null || echo "0")
BUILD_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "dev")
export BUILD_VERSION BUILD_SHA

VERSION_DIR="qb-engineer-ui/public/assets"
if [[ -d "$VERSION_DIR" ]]; then
    echo -n "{\"version\":\"${BUILD_VERSION}\",\"sha\":\"${BUILD_SHA}\"}" > "${VERSION_DIR}/version.json"
    ok "Build ${BUILD_VERSION} (${BUILD_SHA})"
else
    warn "UI assets directory not found — skipping version.json"
fi

# ─────────────────────────────────────────────────────────────
# 6. Resource tuning (low-RAM / SSL)
# ─────────────────────────────────────────────────────────────

NEEDS_OVERRIDE=false

# ── SSL certificate ──
# Cohost mode skips in-container cert generation — the host-level proxy
# (nginx+LE, Caddy, cloudflared tunnel) terminates TLS.
if $ENABLE_SSL && ! $IS_COHOST; then
    step "Configuring SSL"
    CERT_DIR="./certs"
    if [[ -f "${CERT_DIR}/selfsigned.crt" && -f "${CERT_DIR}/selfsigned.key" ]]; then
        ok "SSL certificate already exists in ${CERT_DIR}/"
    else
        mkdir -p "$CERT_DIR"
        HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
        openssl req -x509 -nodes -days 3650 \
            -newkey rsa:2048 \
            -keyout "${CERT_DIR}/selfsigned.key" \
            -out "${CERT_DIR}/selfsigned.crt" \
            -subj "/CN=qb-engineer" \
            -addext "subjectAltName=IP:${HOST_IP:-127.0.0.1},IP:127.0.0.1,DNS:localhost" \
            2>/dev/null
        ok "Generated self-signed SSL certificate (valid 10 years)"
    fi
    NEEDS_OVERRIDE=true
fi

# ── Memory tuning ──
if $IS_LOW_RAM; then
    step "Applying memory tuning"
    ok "Low-RAM detected (${TOTAL_MEM_MB} MB) — applying container memory limits"
    ok "API: 1 GB, DB: 512 MB"
    NEEDS_OVERRIDE=true

    # Warn against heavy profiles
    if $INCLUDE_AI; then
        warn "AI profile enabled on a low-RAM system — Ollama needs ~4 GB RAM"
        warn "Consider disabling AI (remove --include-ai) if you experience OOM issues"
    fi
fi

# ── Generate compose override if needed ──
if $NEEDS_OVERRIDE; then
    step "Generating docker-compose.override.yml"

    {
        echo "# Auto-generated by setup.sh — resource tuning + SSL"
        echo "services:"

        # SSL: UI ports + cert volume
        if $ENABLE_SSL; then
            cat <<'SSLBLOCK'
  qb-engineer-ui:
    ports:
      - "443:443"
      - "80:80"
    volumes:
      - ./certs:/etc/nginx/certs:ro
      - ./qb-engineer-ui/nginx-ssl.conf:/etc/nginx/conf.d/default.conf:ro
SSLBLOCK
        fi

        # Memory limits for low-RAM systems
        if $IS_LOW_RAM; then
            cat <<'MEMBLOCK'
  qb-engineer-api:
    deploy:
      resources:
        limits:
          memory: 1G
  qb-engineer-db:
    deploy:
      resources:
        limits:
          memory: 512M
    command: >
      postgres
        -c shared_buffers=128MB
        -c effective_cache_size=256MB
        -c work_mem=4MB
        -c maintenance_work_mem=64MB
        -c max_connections=50
MEMBLOCK
        fi
    } > docker-compose.override.yml

    ok "Created docker-compose.override.yml"
fi

# ─────────────────────────────────────────────────────────────
# 6b. Manage COMPOSE_FILE based on resolved overlays
# ─────────────────────────────────────────────────────────────
# Rules:
#   standalone + no override:     unset COMPOSE_FILE (auto-load override.yml)
#   standalone + override:        unset COMPOSE_FILE (auto-load override.yml)
#   cohost + no override:         docker-compose.yml:docker-compose.cohost.yml
#   cohost + override:            docker-compose.yml:docker-compose.cohost.yml:docker-compose.override.yml
# Setting COMPOSE_FILE disables auto-loading of override.yml, so cohost must
# explicitly list it when one was generated.
if $IS_COHOST; then
    CF="docker-compose.yml:docker-compose.cohost.yml"
    if $NEEDS_OVERRIDE; then
        CF="${CF}:docker-compose.override.yml"
    fi
    set_env "COMPOSE_FILE" "$CF"
    ok "COMPOSE_FILE = ${CF}"
else
    # Strip any lingering COMPOSE_FILE (e.g. from a prior cohost or pi config)
    if grep -q "^COMPOSE_FILE=" .env 2>/dev/null; then
        sed -i "/^COMPOSE_FILE=/d" .env
        ok "Removed COMPOSE_FILE from .env (override.yml auto-loads)"
    fi
fi

# ─────────────────────────────────────────────────────────────
# 7. Build and start
# ─────────────────────────────────────────────────────────────

step "Building Docker images"
if $IS_ARM; then
    warn "First build on ARM can take 10-20 minutes — go grab a coffee"
else
    info "This may take several minutes on first run"
fi
echo ""

echo "    Building API image..."
docker compose build qb-engineer-api
ok "API image built"

echo "    Building UI image..."
docker compose build qb-engineer-ui
ok "UI image built"

step "Configuring git hooks"
git config core.hooksPath .githooks
ok "Pre-commit hook enabled (runs tests before commit)"

step "Starting core services (db, storage, backup, api, ui)"

docker compose up -d --remove-orphans \
    qb-engineer-db \
    qb-engineer-storage \
    qb-engineer-backup \
    qb-engineer-api \
    qb-engineer-ui

# --- Optional: AI ---
if $INCLUDE_AI; then
    step "Starting AI service (Ollama)"
    warn "First run downloads AI models (~4 GB) — this can take several minutes"
    docker compose --profile ai up -d qb-engineer-ai qb-engineer-ai-init
fi

# --- Optional: TTS ---
if $INCLUDE_TTS; then
    step "Starting TTS service (Coqui)"
    warn "First run downloads the VCTK voice model (~500 MB)"
    docker compose --profile tts up -d qb-engineer-tts
fi

# --- Optional: Signing ---
if $INCLUDE_SIGNING; then
    step "Starting DocuSeal signing service"
    docker compose --profile signing up -d qb-engineer-signing
fi

# ─────────────────────────────────────────────────────────────
# 8. Wait for API health
# ─────────────────────────────────────────────────────────────

step "Waiting for API to become healthy (first start includes database migration)"

# Longer timeout for ARM / low-RAM systems
if $IS_ARM || $IS_LOW_RAM; then
    MAX_WAIT=180
else
    MAX_WAIT=120
fi

ELAPSED=0
HEALTHY=false

while (( ELAPSED < MAX_WAIT )); do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' qb-engineer-api 2>/dev/null || echo "unknown")
    if [[ "$STATUS" == "healthy" ]]; then
        HEALTHY=true
        break
    fi
    printf "\r    Waiting... %s (%ds / %ds)" "$STATUS" "$ELAPSED" "$MAX_WAIT"
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done
echo ""

if $HEALTHY; then
    ok "API is healthy and accepting requests"
else
    warn "API health check timed out after ${MAX_WAIT}s"
    warn "This is normal on first start while migrations run."
    warn "Check progress: docker compose logs -f qb-engineer-api"
fi

# Reset RECREATE_DB so next restart doesn't wipe again
if $FRESH; then
    set_env "RECREATE_DB" "false"
    ok "Reset RECREATE_DB=false (database won't be wiped on next restart)"
fi

# ─────────────────────────────────────────────────────────────
# 9. Final status
# ─────────────────────────────────────────────────────────────

step "Container status"
docker compose ps

HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")

if $IS_COHOST; then
    SCHEME="https"
    UI_URL="(your public hostname via host-level proxy)"
elif $ENABLE_SSL; then
    SCHEME="https"
    UI_URL="${SCHEME}://localhost"
else
    SCHEME="http"
    UI_URL="http://localhost:4200"
fi

echo ""
echo "  ╔══════════════════════════════════════════════╗"
printf "  ║          \033[32mSetup complete!\033[0m                     ║\n"
echo "  ╚══════════════════════════════════════════════╝"
echo ""
if $IS_COHOST; then
echo "  Cohost mode active. The stack is running on 127.0.0.1 only."
echo "  Point your host-level reverse proxy at http://127.0.0.1:4200"
echo "  (see docs/cohosting.md for nginx and cloudflared examples)."
else
echo "  Open in your browser:"
echo ""
echo "    $UI_URL"
if [[ -n "${HOST_IP:-}" ]]; then
echo "    ${SCHEME}://${HOST_IP}  (network access)"
fi
if $ENABLE_SSL; then
echo ""
echo "    Your browser will show a certificate warning because the"
echo "    cert is self-signed. Click 'Advanced' > 'Proceed' to continue."
echo "    This is expected and safe on your own network."
fi
fi
echo ""
echo "  A setup wizard will guide you through creating"
echo "  your admin account and company profile."
echo ""
echo "  ─── Service URLs ───"
echo ""
echo "  API:          http://localhost:5000"
echo "  API Health:   http://localhost:5000/api/v1/health"
echo "  MinIO:        http://localhost:9001  (minioadmin / minioadmin)"
$INCLUDE_AI      && echo "  Ollama:       http://localhost:11434"
$INCLUDE_TTS     && echo "  Coqui TTS:    http://localhost:5002"
$INCLUDE_SIGNING && echo "  DocuSeal:     http://localhost:3000"
echo ""

# Server access instructions (headless standalone only — cohost uses the host proxy)
if $IS_HEADLESS && ! $IS_COHOST && [[ -n "${HOST_IP:-}" ]]; then
    EXT_PORT=$($ENABLE_SSL && echo "443" || echo "80")
    echo "  ─── Public Access ───"
    echo ""
    echo "  To make this accessible from the internet:"
    echo ""
    echo "    1. Log into your router (usually http://192.168.1.1)"
    echo "    2. Find 'Port Forwarding' (may be under Advanced or NAT)"
    echo "    3. Forward external port ${EXT_PORT} → ${HOST_IP} port ${EXT_PORT}"
    if $ENABLE_SSL; then
    echo "    4. Also forward external port 80 → ${HOST_IP} port 80 (auto-redirects to HTTPS)"
    echo "    5. Find your public IP: curl -4 ifconfig.me"
    else
    echo "    4. Find your public IP: curl -4 ifconfig.me"
    fi
    echo ""
fi

echo "  ─── Useful Commands ───"
echo ""
echo "  View logs:    docker compose logs -f qb-engineer-api"
echo "  Stop all:     docker compose stop"
echo "  Start all:    docker compose up -d"
echo "  Update:       ./refresh.sh"
echo "  DB shell:     docker compose exec qb-engineer-db psql -U postgres -d qb_engineer"
echo ""

# Performance tips for constrained systems
if $IS_ARM || $IS_LOW_RAM; then
    echo "  ─── Performance Tips ───"
    echo ""
    $IS_ARM && echo "  - Use a USB 3.0 SSD instead of the SD card for Docker storage"
    $IS_LOW_RAM && echo "  - Skip AI and TTS profiles on devices with < 8 GB RAM"
    echo "  - The first page load after a restart is slow (JIT warmup)"
    echo ""
fi
