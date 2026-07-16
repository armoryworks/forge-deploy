#!/usr/bin/env bash
# setup.sh — First-time setup for Forge (Linux / macOS)
#
# Two paths:
#
#   ./setup.sh                 # default: GHCR-pull. Pulls prebuilt images
#                              # from ghcr.io/armoryworks/forge-{server,ui,test}
#                              # and brings the stack up. Requires only this
#                              # repo (forge-deploy) cloned. This is
#                              # the production / tester path.
#
#   ./setup.sh --source        # developer mode. Builds images locally from
#                              # source. Requires forge-api,
#                              # forge-ui, forge-test cloned as
#                              # siblings of forge-deploy.
#
# Auto-detects platform, architecture, and available resources. Applies
# memory tuning on low-RAM systems, offers SSL on headless/server installs.
#
# Multi-arch GHCR images (linux/amd64 + linux/arm64) are published from
# the source repos, so both x86_64 and arm64 hosts can pull and run.
#
# Run from the repo root after cloning:
#   chmod +x setup.sh
#   ./setup.sh           # GHCR-pull (production / tester)
#   ./setup.sh --source  # local source build (developer)
#
# Options:
#   --source             Build images locally from source. Requires sibling
#                        forge-api / forge-ui / forge-test
#                        repos. Default is GHCR-pull (no source needed).
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
#   --public             One-command "expose this server to the network with
#                        HTTPS, do whatever's needed" macro. Implies
#                        --standalone --ssl, and runs system-side preflight
#                        (detects/offers to stop conflicting services on
#                        80/443, opens UFW rules, picks cert hostname).
#                        Incompatible with --cohost.
#   --no-public-preflight  Skip the system-side preflight (assume user has
#                        nginx/ufw/etc handled). --public still implies
#                        --standalone --ssl.
#   --hostname <fqdn>    Explicit hostname for the self-signed cert CN/SAN.
#                        Otherwise auto-detected via `hostname -f` (with a
#                        prompt to confirm).
#   --skip-host-watchdog Skip installing the host network watchdog (Linux
#                        only). The watchdog runs every minute, restarts
#                        networking on persistent failure, and reboots
#                        the box if the network stays dead — recovers a
#                        wedged Pi NIC without a physical button press.
#                        Installed by default on Linux; no-op on macOS.
#   -h / --help          Show this help.

set -euo pipefail

SOURCE_BUILD=false
SEED_DEMO=false
FRESH=false
INCLUDE_AI=false
INCLUDE_TTS=false
INCLUDE_SIGNING=false
SSL_FLAG=""   # "" = auto-detect, "force" = --ssl, "skip" = --no-ssl
MODE_FLAG=""  # "" = auto/use .env, "cohost" or "standalone" force
PUBLIC=false
PUBLIC_PREFLIGHT=true
PUBLIC_HOSTNAME=""
# Host network watchdog (Linux/systemd only — silently no-op on macOS).
# Env override: SKIP_HOST_WATCHDOG=1 ./setup.sh
SKIP_HOST_WATCHDOG=${SKIP_HOST_WATCHDOG:-false}

show_help() {
    sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

while (( $# > 0 )); do
    case "$1" in
        --source)               SOURCE_BUILD=true ;;
        --seeded)               SEED_DEMO=true ;;
        --fresh)                FRESH=true ;;
        --include-ai)           INCLUDE_AI=true ;;
        --include-tts)          INCLUDE_TTS=true ;;
        --include-signing)      INCLUDE_SIGNING=true ;;
        --include-all)          INCLUDE_AI=true; INCLUDE_TTS=true; INCLUDE_SIGNING=true ;;
        --ssl)                  SSL_FLAG="force" ;;
        --no-ssl)               SSL_FLAG="skip" ;;
        --cohost)               MODE_FLAG="cohost" ;;
        --standalone)           MODE_FLAG="standalone" ;;
        --public)               PUBLIC=true ;;
        --no-public-preflight)  PUBLIC_PREFLIGHT=false ;;
        --hostname)
            shift
            if [[ $# -eq 0 || -z "${1:-}" ]]; then
                echo "Error: --hostname requires a value (e.g. --hostname qb.example.com)"
                exit 1
            fi
            PUBLIC_HOSTNAME="$1"
            ;;
        --hostname=*)           PUBLIC_HOSTNAME="${1#--hostname=}" ;;
        --skip-host-watchdog)   SKIP_HOST_WATCHDOG=true ;;
        -h|--help)              show_help; exit 0 ;;
        *) echo "Unknown option: $1"; echo "Run './setup.sh --help' for usage."; exit 1 ;;
    esac
    shift
done

# --public implies --standalone --ssl unless explicitly contradicted.
# --cohost is incompatible.
if $PUBLIC; then
    if [[ "$MODE_FLAG" == "cohost" ]]; then
        echo "Error: --public is incompatible with --cohost."
        echo "       --public means 'this stack owns the host's 80/443'; cohost means"
        echo "       'a host-level reverse proxy owns 80/443'. Pick one."
        exit 1
    fi
    if [[ "$SSL_FLAG" == "skip" ]]; then
        echo "Error: --public implies --ssl, but --no-ssl was also passed."
        echo "       --public is a network-reachable HTTPS macro; HTTPS is not optional."
        exit 1
    fi
    MODE_FLAG="standalone"
    SSL_FLAG="force"
fi

# ─────────────────────────────────────────────────────────────
# Deprecation notice for direct invocation
# ─────────────────────────────────────────────────────────────
# setup.sh is now the internal bootstrapper behind the forge-deploy CLI,
# which adds state detection, recovery (--recover), fresh-start, version
# pinning, and health-gated upgrades on top. The CLI sets
# FORGE_DEPLOY_CALLER=1 when it invokes us; direct runs get a pointer.
if [[ -z "${FORGE_DEPLOY_CALLER:-}" ]]; then
    echo ""
    echo "NOTE: the supported way to install and manage Forge is the forge-deploy CLI:"
    echo ""
    echo "        sudo bash scripts/install-forge-deploy.sh"
    echo "        forge-deploy"
    echo ""
    echo "      It runs this bootstrapper for you and adds recovery, version pinning,"
    echo "      and health-gated upgrades. Running setup.sh directly still works"
    echo "      (dev workstations, --source builds) but is no longer the documented path."
    if [[ -t 0 ]]; then
        read -rp "      Press Enter to continue anyway (Ctrl-C to abort)... " _ || true
    fi
    echo ""
fi

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

# Per-box component scope: services this box must NOT run (forge-deploy --wizard
# writes FORGE_SCOPED_OUT to .env). Lets the installer drop e.g. forge-ui on an
# API box instead of bringing the whole stack up everywhere.
scoped_out_list() {
    grep '^FORGE_SCOPED_OUT=' .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'\'
}
is_scoped_out() {
    printf '%s\n' $(scoped_out_list) | grep -qx "$1"
}
# Echo only the args that are NOT scoped out (preserves order).
keep_unscoped() {
    local svc
    for svc in "$@"; do is_scoped_out "$svc" || printf '%s\n' "$svc"; done
}

# Helper: append a line to the rollback script. Creates the file (with header)
# on first call. Used by --public preflight to record reversal commands so the
# operator can `bash setup-public-rollback.sh` to undo what setup did.
ROLLBACK_SCRIPT="setup-public-rollback.sh"
ROLLBACK_INITIALIZED=false
rollback_add() {
    if ! $ROLLBACK_INITIALIZED; then
        cat > "$ROLLBACK_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# setup-public-rollback.sh — auto-generated by setup.sh --public
#
# Reverses the system-side changes made by `setup.sh --public` on this host.
# Run with: bash setup-public-rollback.sh
#
# This does NOT stop or remove the forge Docker stack. To do that:
#   docker compose down
#
# Generated: $(date -Iseconds 2>/dev/null || date)
set -e
echo "Rolling back setup.sh --public system changes..."
EOF
        # Substitute the date placeholder (heredoc was 'EOF' so $(date) didn't expand)
        sed -i "s|Generated: \$(date -Iseconds 2>/dev/null || date)|Generated: $(date -Iseconds 2>/dev/null || date)|" "$ROLLBACK_SCRIPT"
        chmod +x "$ROLLBACK_SCRIPT" 2>/dev/null || true
        ROLLBACK_INITIALIZED=true
    fi
    printf '%s\n' "$1" >> "$ROLLBACK_SCRIPT"
}

# Helper: identify what (if anything) is listening on a TCP port.
# Echoes "PID NAME" or empty string if nothing is listening.
# Caller must have ss installed (Linux) — falls back to lsof on macOS.
port_listener() {
    local port="$1"
    if $IS_MAC; then
        # macOS: lsof
        if command -v lsof &>/dev/null; then
            lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $2, $1; exit}'
        fi
    else
        # Linux: ss preferred, fall back to lsof, then netstat
        if command -v ss &>/dev/null; then
            # ss output: e.g. users:(("nginx",pid=1234,fd=6),("nginx",pid=1235,fd=6))
            local line pid name
            line=$(ss -tlnpH "sport = :${port}" 2>/dev/null | head -1)
            if [[ -n "$line" ]]; then
                pid=$(echo "$line" | grep -oP 'pid=\K[0-9]+' | head -1)
                name=$(echo "$line" | grep -oP '"\K[^"]+' | head -1)
                if [[ -n "$pid" && -n "$name" ]]; then
                    echo "$pid $name"
                fi
            fi
        elif command -v lsof &>/dev/null; then
            lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $2, $1; exit}'
        fi
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
#   3. Auto-detect: nginx vhost for forge, or active cloudflared
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
    if ls /etc/nginx/sites-enabled/forge*.conf &>/dev/null 2>&1 || \
       ls /etc/nginx/conf.d/forge*.conf &>/dev/null 2>&1; then
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
echo "  ║        Forge — First-Time Setup        ║"
echo "  ╚══════════════════════════════════════════════╝"
echo ""
if $SOURCE_BUILD; then
    echo "  Mode: SOURCE BUILD (developer)"
    echo "        Builds images locally from sibling repos."
else
    echo "  Mode: GHCR-PULL (production / tester) [default]"
    echo "        Pulls prebuilt images from ghcr.io. No source code needed."
    echo "        Pass --source to build locally instead."
fi
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
$PUBLIC && ok "--public macro: standalone + ssl, with system preflight"

# ─────────────────────────────────────────────────────────────
# 1b. --public preflight (system-side prep)
# ─────────────────────────────────────────────────────────────
# Detects and (with consent) resolves the most common Ubuntu/Debian gotchas
# when a fresh tester wants to expose the stack on 80/443:
#   1. System nginx / apache holding port 80 → offer to stop+disable
#   2. UFW blocking 80/443 → offer to allow
#   3. Self-signed cert hostname → use --hostname, else prompt
# Skipped entirely with --no-public-preflight.
PUBLIC_HOSTNAME_RESOLVED=""

if $PUBLIC && $PUBLIC_PREFLIGHT; then
    step "Public-deploy preflight"

    if $IS_MAC; then
        warn "macOS detected — preflight skips Linux-only system service handling."
        warn "You'll need to manually free 80/443 and configure your firewall."
    fi

    # ── 1. Port 80 / 443 conflicts ──
    for PUBPORT in 80 443; do
        LISTENER=$(port_listener "$PUBPORT" 2>/dev/null || echo "")
        if [[ -z "$LISTENER" ]]; then
            ok "Port ${PUBPORT}: free"
            continue
        fi

        LIS_PID=$(echo "$LISTENER" | awk '{print $1}')
        LIS_NAME=$(echo "$LISTENER" | awk '{print $2}')

        # Identify the systemd unit (if any) so we can offer the right action.
        # docker-proxy means Docker is already binding it (probably from a
        # previous run of this stack) — skip; the new compose up will reuse.
        if [[ "$LIS_NAME" == "docker-proxy" ]]; then
            ok "Port ${PUBPORT}: already bound by docker-proxy (PID ${LIS_PID}) — assumed OK"
            continue
        fi

        warn "Port ${PUBPORT}: held by ${LIS_NAME} (PID ${LIS_PID})"

        case "$LIS_NAME" in
            nginx)
                if command -v systemctl &>/dev/null && systemctl list-unit-files nginx.service &>/dev/null; then
                    info "System nginx is running and would block the forge UI container."
                    read -rp "    Stop and disable system nginx (sudo systemctl stop nginx && sudo systemctl disable nginx)? (y/N) " yn
                    if [[ "$yn" =~ ^[Yy]$ ]]; then
                        if sudo systemctl stop nginx && sudo systemctl disable nginx; then
                            ok "Stopped and disabled system nginx"
                            rollback_add "echo '  -> re-enabling nginx'"
                            rollback_add "sudo systemctl enable nginx || true"
                            rollback_add "sudo systemctl start nginx || true"
                        else
                            fail "Failed to stop nginx — sudo may have failed. Free port ${PUBPORT} manually and re-run."
                            exit 1
                        fi
                    else
                        fail "Port ${PUBPORT} still held by nginx. Aborting."
                        info "Either stop nginx manually, pass --no-public-preflight to skip this check,"
                        info "or use --cohost so nginx can reverse-proxy to forge."
                        exit 1
                    fi
                else
                    fail "Port ${PUBPORT} held by an nginx process not managed by systemd."
                    info "Stop it manually (kill ${LIS_PID} or its parent) and re-run."
                    exit 1
                fi
                ;;
            apache2|httpd)
                local_unit="apache2"
                [[ "$LIS_NAME" == "httpd" ]] && local_unit="httpd"
                if command -v systemctl &>/dev/null && systemctl list-unit-files "${local_unit}.service" &>/dev/null; then
                    info "System ${local_unit} is running and would block the forge UI container."
                    read -rp "    Stop and disable system ${local_unit} (sudo systemctl stop ${local_unit} && sudo systemctl disable ${local_unit})? (y/N) " yn
                    if [[ "$yn" =~ ^[Yy]$ ]]; then
                        if sudo systemctl stop "$local_unit" && sudo systemctl disable "$local_unit"; then
                            ok "Stopped and disabled system ${local_unit}"
                            rollback_add "echo '  -> re-enabling ${local_unit}'"
                            rollback_add "sudo systemctl enable ${local_unit} || true"
                            rollback_add "sudo systemctl start ${local_unit} || true"
                        else
                            fail "Failed to stop ${local_unit}. Free port ${PUBPORT} manually and re-run."
                            exit 1
                        fi
                    else
                        fail "Port ${PUBPORT} still held by ${local_unit}. Aborting."
                        info "Either stop ${local_unit} manually or pass --no-public-preflight."
                        exit 1
                    fi
                else
                    fail "Port ${PUBPORT} held by an ${local_unit} process not managed by systemd."
                    info "Stop it manually and re-run."
                    exit 1
                fi
                ;;
            *)
                fail "Port ${PUBPORT} is held by ${LIS_NAME} (PID ${LIS_PID})."
                info "Auto-handled processes: nginx, apache2/httpd, docker-proxy."
                info "Anything else: stop it manually and re-run, or pass --no-public-preflight"
                info "to skip the preflight check entirely."
                exit 1
                ;;
        esac
    done

    # ── 2. UFW firewall ──
    if command -v ufw &>/dev/null; then
        if sudo ufw status 2>/dev/null | head -1 | grep -qi "Status: active"; then
            UFW_NEEDS_80=true
            UFW_NEEDS_443=true
            if sudo ufw status 2>/dev/null | grep -qE '^(80(/tcp)?|80\b)\s'; then
                UFW_NEEDS_80=false
            fi
            if sudo ufw status 2>/dev/null | grep -qE '^(443(/tcp)?|443\b)\s'; then
                UFW_NEEDS_443=false
            fi
            if $UFW_NEEDS_80 || $UFW_NEEDS_443; then
                info "UFW is active. Ports needing rules:"
                $UFW_NEEDS_80  && info "  - 80/tcp"
                $UFW_NEEDS_443 && info "  - 443/tcp"
                read -rp "    Allow these ports through UFW (sudo ufw allow ...)? (y/N) " yn
                if [[ "$yn" =~ ^[Yy]$ ]]; then
                    if $UFW_NEEDS_80; then
                        sudo ufw allow 80/tcp >/dev/null && ok "ufw allow 80/tcp"
                        rollback_add "sudo ufw delete allow 80/tcp || true"
                    fi
                    if $UFW_NEEDS_443; then
                        sudo ufw allow 443/tcp >/dev/null && ok "ufw allow 443/tcp"
                        rollback_add "sudo ufw delete allow 443/tcp || true"
                    fi
                else
                    warn "Skipped UFW rules — the stack may be unreachable from outside this host."
                fi
            else
                ok "UFW: 80/tcp and 443/tcp already allowed"
            fi
        else
            ok "UFW: inactive — no rules needed"
        fi
    else
        info "UFW not installed — if you use a different firewall (firewalld, iptables,"
        info "cloud security groups), verify TCP 80 and 443 are allowed manually."
    fi

    # ── 3. Self-signed cert hostname ──
    if [[ -n "$PUBLIC_HOSTNAME" ]]; then
        PUBLIC_HOSTNAME_RESOLVED="$PUBLIC_HOSTNAME"
        ok "Cert hostname (from --hostname): $PUBLIC_HOSTNAME_RESOLVED"
    else
        DETECTED_HOST=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "forge")
        echo ""
        info "Self-signed cert will be issued for a hostname/CN."
        read -rp "    Use detected hostname '${DETECTED_HOST}'? [Y/n/<custom>] " hn
        if [[ -z "$hn" || "$hn" =~ ^[Yy]$ ]]; then
            PUBLIC_HOSTNAME_RESOLVED="$DETECTED_HOST"
        elif [[ "$hn" =~ ^[Nn]$ ]]; then
            fail "Aborted — re-run with --hostname <fqdn> or accept the detected name."
            exit 1
        else
            PUBLIC_HOSTNAME_RESOLVED="$hn"
        fi
        ok "Cert hostname: $PUBLIC_HOSTNAME_RESOLVED"
    fi

    if $ROLLBACK_INITIALIZED; then
        echo ""
        info "Rollback script written: ./${ROLLBACK_SCRIPT}"
        info "Run it to revert the system-side changes (re-enable nginx, close UFW rules)."
    else
        ok "No system changes were needed — no rollback script generated."
    fi
elif $PUBLIC && ! $PUBLIC_PREFLIGHT; then
    step "Public-deploy preflight"
    warn "--no-public-preflight: skipping system service / firewall checks."
    warn "You are responsible for ensuring nothing else holds 80/443 and your"
    warn "firewall allows them. Setup will still configure standalone+SSL."
    if [[ -n "$PUBLIC_HOSTNAME" ]]; then
        PUBLIC_HOSTNAME_RESOLVED="$PUBLIC_HOSTNAME"
    fi
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

# --- Docker packaging: reject the snap build on cgroup v2 (breaks container teardown) ---
# The snap-packaged daemon runs under an AppArmor profile that can't write the container's
# cgroup-v2 `cgroup.kill`, so `docker stop/rm` and `compose up --build` on a running container
# fail with "could not kill container: permission denied". The project standard is apt Docker.
if ! $IS_MAC && docker info &>/dev/null 2>&1; then
    DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
    if [[ "$DOCKER_ROOT" == /var/snap/docker/* ]]; then
        CGROUP_VER="$(docker info --format '{{.CgroupVersion}}' 2>/dev/null)"
        CGROUP_DRV="$(docker info --format '{{.CgroupDriver}}' 2>/dev/null)"
        if [[ "$CGROUP_VER" == "2" && "$CGROUP_DRV" == "systemd" ]]; then
            bail "Docker (snap build on cgroup v2)" \
                "This host runs the SNAP-packaged Docker ($DOCKER_ROOT) on cgroup v2 + the systemd driver." \
                "That combination is broken: 'docker stop/rm' and 'compose up --build' on a running" \
                "container fail with 'could not kill container: permission denied' — container teardown/" \
                "recreate (the core of the dev + deploy loop) will not work." \
                "See docs/TROUBLESHOOTING.md > Host setup for the full explanation." \
                "" \
                "Fix — use the apt Docker packages (the project standard), not the snap:" \
                "  # back up any data volumes first — 'snap remove' deletes everything under /var/snap/docker" \
                "  sudo snap remove docker" \
                "  sudo apt update && sudo apt install -y docker.io docker-compose-v2" \
                "  sudo usermod -aG docker \$USER   # then log out and back in" \
                "" \
                "(Docker CE from docs.docker.com/engine/install/ubuntu is equally fine — any apt/unconfined" \
                "daemon works. The only thing to avoid is the snap.)"
        else
            warn "Docker is the snap build ($DOCKER_ROOT); the project standard is apt Docker (docker.io / docker-ce)."
            info "The snap breaks container teardown on cgroup v2 — switch when convenient:"
            info "  sudo snap remove docker && sudo apt install -y docker.io docker-compose-v2   (back up volumes first)"
        fi
    else
        ok "Docker is an apt/unconfined build ($DOCKER_ROOT)."
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

# On Ubuntu 24.04 the compose-plugin name is docker-compose-v2, and buildx is
# a separate package. Missing buildx is non-fatal — compose falls back to the
# classic builder for the one locally-built sidecar (forge-backup) — but it
# prints a scary "configured to build using Bake, but buildx isn't installed"
# warning. Surface the fix once, quietly.
if ! docker buildx version &>/dev/null 2>&1; then
    info "docker buildx not installed — builds fall back to the classic builder (fine)."
    info "To silence compose's Bake warning:  sudo apt install -y docker-buildx"
fi

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
# process holds the same port. In standalone mode, the UI binds 0.0.0.0 on
# 80 (or 443 with SSL), so we check those publicly-exposed ports too.
CONFLICTS=""
CHECK_PORTS="4200 5000 5432 9000 9001"
if $ENABLE_SSL && ! $IS_COHOST; then
    # SSL enabled standalone: UI binds 80 + 443
    CHECK_PORTS="80 443 5000 5432 9000 9001"
elif ! $IS_COHOST && ( $PUBLIC || [[ "$MODE_FLAG" == "standalone" ]] || $IS_HEADLESS ); then
    # Standalone (explicit or headless-detected) without SSL: UI binds 80
    CHECK_PORTS="80 443 5000 5432 9000 9001"
fi
for PORT in $CHECK_PORTS; do
    HOLDER=""
    if $IS_MAC; then
        if lsof -iTCP:"$PORT" -sTCP:LISTEN &>/dev/null 2>&1; then
            HOLDER=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1}')
        fi
    else
        if ss -tlnp 2>/dev/null | grep -q ":${PORT} " 2>/dev/null; then
            HOLDER=$(ss -tlnpH "sport = :${PORT}" 2>/dev/null | grep -oP '"\K[^"]+' | head -1)
        fi
    fi
    if [[ -n "$HOLDER" ]]; then
        # docker-proxy on the standalone HTTP/HTTPS ports usually means a
        # previous run of this stack — non-fatal.
        if [[ "$HOLDER" == "docker-proxy" ]]; then
            ok "Port $PORT: held by docker-proxy (likely a previous forge run)"
        else
            CONFLICTS="$CONFLICTS $PORT(${HOLDER})"
        fi
    fi
done
if [[ -n "$CONFLICTS" ]]; then
    warn "Ports already in use:$CONFLICTS"
    warn "You can change ports in .env after setup, or run with --public to"
    warn "have setup offer to stop common system services (nginx, apache)."
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
    info "Run this script from the forge-deploy repo root:"
    info "  cd forge-deploy && ./setup.sh"
    exit 1
fi

if [[ ! -f ".env.example" ]]; then
    fail ".env.example not found — the repo may be incomplete."
    info "Try a fresh clone:"
    info "  git clone https://github.com/armoryworks/forge-deploy.git"
    exit 1
fi

ok "Project files found"

# ─────────────────────────────────────────────────────────────
# 3b. Source-build mode: verify sibling repos
# ─────────────────────────────────────────────────────────────
# In --source mode the docker-compose.yml `build:` blocks reference
# ../forge-{server,ui,test}. The deploy repo must be cloned
# alongside its sibling source repos. In GHCR-pull mode (default) the
# prod overlay swaps build for image: and these directories are not
# touched.
if $SOURCE_BUILD; then
    step "Verifying sibling source repos (--source mode)"

    PARENT_DIR=$(cd .. && pwd)
    REQUIRED_SIBLINGS=(forge-api forge-ui forge-test)
    MISSING_SIBLINGS=()

    for sib in "${REQUIRED_SIBLINGS[@]}"; do
        if [[ -d "../${sib}" && -d "../${sib}/.git" ]]; then
            ok "Found ../${sib}"
        else
            MISSING_SIBLINGS+=("$sib")
        fi
    done

    if (( ${#MISSING_SIBLINGS[@]} > 0 )); then
        echo ""
        fail "Missing sibling source repos for --source build:"
        for sib in "${MISSING_SIBLINGS[@]}"; do
            info "  ${PARENT_DIR}/${sib}  (not found)"
        done
        echo ""
        info "Source-build mode requires all four repos checked out as siblings"
        info "under a master folder. Two ways to fix:"
        echo ""
        info "Option A — let setup.sh clone them now:"
        echo ""
        read -rp "    Clone the missing sibling repos into ${PARENT_DIR}? (y/N) " yn
        if [[ "$yn" =~ ^[Yy]$ ]]; then
            for sib in "${MISSING_SIBLINGS[@]}"; do
                step "  Cloning ${sib}"
                if ! git -C "$PARENT_DIR" clone "https://github.com/armoryworks/${sib}.git"; then
                    fail "git clone failed for ${sib}"
                    info "Clone manually then re-run ./setup.sh --source"
                    exit 1
                fi
                ok "Cloned ${sib}"
            done
        else
            echo ""
            info "Option B — clone them yourself, then re-run:"
            for sib in "${MISSING_SIBLINGS[@]}"; do
                info "  git -C ${PARENT_DIR} clone https://github.com/armoryworks/${sib}.git"
            done
            echo ""
            info "Or skip --source and use the default GHCR-pull path:"
            info "  ./setup.sh"
            exit 1
        fi
    fi

    ok "All sibling repos present"
fi

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
            # Do NOT touch UI_PORT here. The SSL override publishes 443/80 and
            # mounts the TLS nginx config; UI_PORT=443 on top of that makes the
            # base mapping ALSO bind host 443 (compose merges port lists), so
            # the container fails with "port is already allocated" while
            # nothing is listening. The plain-HTTP 4200 mapping is bound to
            # loopback below so TLS can't be bypassed from the network.
            sed -i "s|^UI_BIND=.*|UI_BIND=127.0.0.1|" .env
            grep -q "^UI_BIND=" .env || echo "UI_BIND=127.0.0.1" >> .env
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
        # in .env to match the external hostname (e.g. https://forge.com).
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
    echo "    Demo data includes 9 test users (admin@forge.local, etc.)"
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
    for v in UI_BIND API_BIND TEST_BIND POSTGRES_BIND MINIO_BIND AI_BIND TTS_BIND DOCUSEAL_BIND DEMO_BIND; do
        if grep -q "^${v}=" .env 2>/dev/null; then
            sed -i "/^${v}=/d" .env
        fi
    done
else
    # With SSL, the override publishes 443/80 and TLS must not be bypassable:
    # keep the plain-HTTP 4200 mapping on loopback. Without SSL, expose it.
    if $ENABLE_SSL; then
        set_env "UI_BIND" "127.0.0.1"
    else
        set_env "UI_BIND" "0.0.0.0"
    fi
    set_env "API_BIND" "0.0.0.0"
    set_env "TEST_BIND" "0.0.0.0"
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

# version.json injection only matters for source-build mode. With sibling
# context paths the UI assets dir lives at ../forge-ui/public/assets.
# In GHCR-pull mode the image already has version metadata baked in.
if $SOURCE_BUILD; then
    VERSION_DIR="../forge-ui/public/assets"
    if [[ -d "$VERSION_DIR" ]]; then
        echo -n "{\"version\":\"${BUILD_VERSION}\",\"sha\":\"${BUILD_SHA}\"}" > "${VERSION_DIR}/version.json"
        ok "Build ${BUILD_VERSION} (${BUILD_SHA})"
    else
        warn "UI assets directory not found — skipping version.json"
    fi
else
    info "GHCR-pull mode: version metadata baked into the image (skip)"
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

        # Pick the cert CN: explicit hostname > public-resolved hostname >
        # detected hostname > "forge".
        CERT_CN="forge"
        SAN_DNS="DNS:localhost"
        if [[ -n "$PUBLIC_HOSTNAME_RESOLVED" ]]; then
            CERT_CN="$PUBLIC_HOSTNAME_RESOLVED"
            SAN_DNS="DNS:${PUBLIC_HOSTNAME_RESOLVED},DNS:localhost"
        elif [[ -n "$PUBLIC_HOSTNAME" ]]; then
            CERT_CN="$PUBLIC_HOSTNAME"
            SAN_DNS="DNS:${PUBLIC_HOSTNAME},DNS:localhost"
        fi

        openssl req -x509 -nodes -days 3650 \
            -newkey rsa:2048 \
            -keyout "${CERT_DIR}/selfsigned.key" \
            -out "${CERT_DIR}/selfsigned.crt" \
            -subj "/CN=${CERT_CN}" \
            -addext "subjectAltName=IP:${HOST_IP:-127.0.0.1},IP:127.0.0.1,${SAN_DNS}" \
            2>/dev/null
        ok "Generated self-signed SSL certificate (CN=${CERT_CN}, valid 10 years)"
    fi

    # The override bind-mounts ./forge-ui/nginx-ssl.conf over the container's
    # nginx config. If that FILE is missing, docker silently mkdir-p's the
    # path as an empty DIRECTORY and the container dies with "not a directory:
    # are you trying to mount a directory onto a file?". Guard both states.
    SSL_CONF="./forge-ui/nginx-ssl.conf"
    if [[ -d "$SSL_CONF" ]]; then
        # Phantom directory from a previous failed run — remove it (it's
        # always empty; docker creates nothing inside it).
        rmdir "$SSL_CONF" 2>/dev/null || sudo rmdir "$SSL_CONF" 2>/dev/null || {
            fail "$SSL_CONF exists as a directory and couldn't be removed."
            info "Remove it, then re-run: sudo rm -rf $SSL_CONF"
            exit 1
        }
        ok "Removed phantom directory left by a previous failed run: $SSL_CONF"
    fi
    if [[ ! -f "$SSL_CONF" ]]; then
        fail "$SSL_CONF is missing — your forge-deploy checkout predates the SSL fix."
        info "Update it:  git -C \"$(pwd)\" pull"
        exit 1
    fi
    ok "TLS nginx config present: $SSL_CONF"

    NEEDS_OVERRIDE=true
fi

# Pre-create host directories that compose bind-mounts. If they don't exist,
# docker auto-creates them ROOT-owned, which breaks later non-root access
# (backup pruning, cert rotation, git operations under the repo).
for host_dir in ./backups ./certs; do
    if [[ ! -d "$host_dir" ]]; then
        mkdir -p "$host_dir" 2>/dev/null || true
    fi
done

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
  forge-ui:
    ports:
      - "443:443"
      - "80:80"
    volumes:
      - ./certs:/etc/nginx/certs:ro
      - ./forge-ui/nginx-ssl.conf:/etc/nginx/conf.d/default.conf:ro
SSLBLOCK
        fi

        # Memory limits for low-RAM systems
        if $IS_LOW_RAM; then
            cat <<'MEMBLOCK'
  forge-api:
    deploy:
      resources:
        limits:
          memory: 1G
  forge:
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
# Order matters: later files override earlier ones in docker compose.
#
#   GHCR-pull (default)     -> base + prod (prod swaps build: for image:)
#   GHCR-pull + cohost      -> base + cohost + prod
#   --source                -> base alone (auto-loads override.yml if present)
#   --source + cohost       -> base + cohost (+ override.yml explicitly)
#
# Setting COMPOSE_FILE disables auto-loading of override.yml, so any branch
# that sets COMPOSE_FILE must explicitly list override.yml when one exists.
CF_PARTS=("docker-compose.yml")
if $IS_COHOST; then
    CF_PARTS+=("docker-compose.cohost.yml")
fi
if ! $SOURCE_BUILD; then
    CF_PARTS+=("docker-compose.prod.yml")
fi
if $NEEDS_OVERRIDE; then
    CF_PARTS+=("docker-compose.override.yml")
fi

# In the simplest case (--source + standalone + no override) leave
# COMPOSE_FILE unset so docker compose auto-loads override.yml, matching
# pre-existing dev behavior.
if $SOURCE_BUILD && ! $IS_COHOST && ! $NEEDS_OVERRIDE; then
    if grep -q "^COMPOSE_FILE=" .env 2>/dev/null; then
        sed -i "/^COMPOSE_FILE=/d" .env
        ok "Removed COMPOSE_FILE from .env (override.yml auto-loads)"
    fi
else
    CF=$(IFS=:; echo "${CF_PARTS[*]}")
    set_env "COMPOSE_FILE" "$CF"
    ok "COMPOSE_FILE = ${CF}"
fi

# ─────────────────────────────────────────────────────────────
# 7. Build and start
# ─────────────────────────────────────────────────────────────

if $SOURCE_BUILD; then
    step "Building Docker images (--source mode)"
    if $IS_ARM; then
        warn "First build on ARM can take 10-20 minutes — go grab a coffee"
    else
        info "This may take several minutes on first run"
    fi
    echo ""

    echo "    Building API image..."
    docker compose build forge-api
    ok "API image built"

    echo "    Building UI image..."
    docker compose build forge-ui
    ok "UI image built"
else
    step "Pulling prebuilt images from GHCR"
    info "Multi-arch images: linux/amd64 + linux/arm64. Docker auto-selects."
    echo ""
    PULL_SVCS=()
    mapfile -t PULL_SVCS < <(keep_unscoped forge-api forge-ui)
    if (( ${#PULL_SVCS[@]} > 0 )) && ! docker compose pull "${PULL_SVCS[@]}"; then
        fail "Failed to pull GHCR images"
        info "Common causes:"
        info "  - No network connectivity to ghcr.io"
        info "  - Image tag doesn't exist (check SERVER_IMAGE_TAG / UI_IMAGE_TAG in .env)"
        info "  - Multi-arch image missing your architecture (try ./setup.sh --source)"
        exit 1
    fi
    ok "Images pulled from GHCR (${PULL_SVCS[*]})"
fi

# Git hooks only matter inside a git checkout that has them — skip if absent
# (e.g. tarball install of the deploy repo).
if [[ -d .githooks ]]; then
    step "Configuring git hooks"
    git config core.hooksPath .githooks
    ok "Pre-commit hook enabled (runs tests before commit)"
fi

# Core services minus anything scoped out for this box (forge-deploy --wizard).
# --remove-orphans then prunes a previously-running service that is now scoped
# out (e.g. forge-ui on a box converted to API-only).
CORE_UP=()
mapfile -t CORE_UP < <(keep_unscoped forge forge-storage forge-backup forge-api forge-ui)
step "Starting core services: ${CORE_UP[*]:-<none>}"
if (( ${#CORE_UP[@]} > 0 )); then
    docker compose up -d --remove-orphans "${CORE_UP[@]}"
fi

# --- Optional: AI ---
if $INCLUDE_AI; then
    step "Starting AI service (Ollama)"
    warn "First run downloads AI models (~4 GB) — this can take several minutes"
    docker compose --profile ai up -d forge-ai forge-ai-init
fi

# --- Optional: TTS ---
if $INCLUDE_TTS; then
    step "Starting TTS service (Coqui)"
    warn "First run downloads the VCTK voice model (~500 MB)"
    docker compose --profile tts up -d forge-tts
fi

# --- Optional: Signing ---
if $INCLUDE_SIGNING; then
    step "Starting DocuSeal signing service"
    docker compose --profile signing up -d forge-signing
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
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' forge-api 2>/dev/null || echo "unknown")
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
    warn "Check progress: docker compose logs -f forge-api"
fi

# Reset RECREATE_DB so next restart doesn't wipe again
if $FRESH; then
    set_env "RECREATE_DB" "false"
    ok "Reset RECREATE_DB=false (database won't be wiped on next restart)"
fi

# ─────────────────────────────────────────────────────────────
# 8b. Host resilience: install network watchdog (Linux only)
# ─────────────────────────────────────────────────────────────
#
# The Pi has a known failure mode where the OS stays alive but the network
# stack hangs (USB-attached Ethernet driver, WiFi firmware). The hardware
# watchdog can't catch it because systemd is still healthy. The host
# network watchdog pings out every minute and force-recovers (restart
# networking → reboot) if the host is unreachable. Idempotent; safe to
# re-run; bails out on macOS and on Linux without systemd.

if $IS_LINUX && ! $SKIP_HOST_WATCHDOG; then
    WATCHDOG_INSTALLER="$(dirname -- "$0")/scripts/install-host-watchdog.sh"
    if [[ -x "$WATCHDOG_INSTALLER" ]]; then
        step "Installing host network watchdog"
        # Bail out non-fatally — a failed watchdog install must not block
        # an otherwise-successful deploy. The user can re-run the installer
        # by hand to debug.
        if sudo -E "$WATCHDOG_INSTALLER"; then
            ok "Host network watchdog active"
        else
            warn "Host network watchdog install failed (non-fatal)"
            warn "Re-run by hand: sudo ${WATCHDOG_INSTALLER}"
        fi
    elif [[ -f "$WATCHDOG_INSTALLER" ]]; then
        warn "Found $WATCHDOG_INSTALLER but it isn't executable — skipping"
        warn "Fix: chmod +x $WATCHDOG_INSTALLER"
    fi
elif $IS_LINUX && $SKIP_HOST_WATCHDOG; then
    info "Skipping host network watchdog install (--skip-host-watchdog)"
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
echo "  View logs:    docker compose logs -f forge-api"
echo "  Stop all:     docker compose stop"
echo "  Start all:    docker compose up -d"
if $SOURCE_BUILD; then
echo "  Update:       ./refresh.sh        (rebuild from source — dev loop)"
else
echo "  Update:       docker compose pull && docker compose up -d"
echo "                or install forge-deploy for healthcheck-gated rollouts"
echo "                  (see scripts/install-forge-deploy.sh)"
fi
echo "  DB shell:     docker compose exec forge psql -U postgres -d forge"
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
