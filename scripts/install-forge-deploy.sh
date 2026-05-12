#!/usr/bin/env bash
# install-forge-deploy.sh — Install or refresh the forge-deploy CLI on the Pi.
#
# Idempotent: re-running is safe and preserves /etc/forge/deploy-state.json.
#
# Usage:
#   sudo ./scripts/install-forge-deploy.sh
#   sudo FORGE_DEPLOY_USER=qbedeploy ./scripts/install-forge-deploy.sh
#
# Env:
#   FORGE_DEPLOY_USER   Owner of /etc/forge + log file (default: invoking user, or current user)
#   FORGE_DEPLOY_REPO   Path to the forge-deploy git checkout (default: detected from script location)

set -euo pipefail

# Auto-elevate. The install touches /usr/local/bin and /etc/forge,
# both of which require root. Re-exec under sudo if not already root so
# the script runs cleanly end-to-end instead of failing partway through
# at the install(1) step. Preserves caller env (notably FORGE_DEPLOY_USER)
# via sudo -E.
if [[ "$EUID" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "ERROR: must run as root (sudo not available either)" >&2
    exit 1
  fi
  exec sudo -E "$0" "$@"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT_DEFAULT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT_DEFAULT
readonly REPO_ROOT="${FORGE_DEPLOY_REPO:-${REPO_ROOT_DEFAULT}}"
readonly INSTALL_BIN="/usr/local/bin/forge-deploy"
readonly STATE_DIR="/etc/forge"
readonly STATE_FILE="${STATE_DIR}/deploy-state.json"
readonly LOG_FILE="/var/log/forge-deploy.log"

# Color (skipped when not a TTY)
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""
fi
step() { printf '%s==> %s%s\n' "${C_CYAN}" "$1" "${C_RESET}"; }
ok()   { printf '    %s[OK]%s %s\n' "${C_GREEN}" "${C_RESET}" "$1"; }
warn() { printf '    %s[!!]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$1"; }
die()  { printf '    %s[XX]%s %s\n' "${C_RED}" "${C_RESET}" "$1" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────
# Determine deploy user
# ─────────────────────────────────────────────────────────────

if [[ -n "${FORGE_DEPLOY_USER:-}" ]]; then
  DEPLOY_USER="$FORGE_DEPLOY_USER"
elif [[ -n "${SUDO_USER:-}" ]]; then
  DEPLOY_USER="$SUDO_USER"
else
  DEPLOY_USER=$(id -un)
fi

if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
  die "Deploy user does not exist: $DEPLOY_USER"
fi

DEPLOY_GROUP=$(id -gn "$DEPLOY_USER")

# ─────────────────────────────────────────────────────────────
# Pre-flight: required commands on the Pi
# ─────────────────────────────────────────────────────────────

step "Pre-flight checks"

for cmd in docker curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "Required command missing: $cmd (install via your package manager)"
  fi
done
ok "Found: docker, curl, jq"

if ! docker compose version >/dev/null 2>&1; then
  die "Docker Compose plugin missing (install docker-compose-plugin)"
fi
ok "Docker Compose plugin available"

if [[ ! -f "${REPO_ROOT}/scripts/forge-deploy" ]]; then
  die "Cannot find forge-deploy script at ${REPO_ROOT}/scripts/forge-deploy"
fi
ok "Source repo: ${REPO_ROOT}"

# ─────────────────────────────────────────────────────────────
# Install the CLI
# ─────────────────────────────────────────────────────────────

step "Installing CLI"

install -m 0755 "${REPO_ROOT}/scripts/forge-deploy" "$INSTALL_BIN"
ok "Installed: $INSTALL_BIN"

# ─────────────────────────────────────────────────────────────
# State directory + file
# ─────────────────────────────────────────────────────────────

step "Setting up state"

if [[ ! -d "$STATE_DIR" ]]; then
  install -d -m 0750 -o "$DEPLOY_USER" -g "$DEPLOY_GROUP" "$STATE_DIR"
  ok "Created $STATE_DIR (0750 ${DEPLOY_USER}:${DEPLOY_GROUP})"
else
  chmod 0750 "$STATE_DIR"
  chown "${DEPLOY_USER}:${DEPLOY_GROUP}" "$STATE_DIR"
  ok "Updated perms on $STATE_DIR"
fi

if [[ ! -f "$STATE_FILE" ]]; then
  cat > "$STATE_FILE" <<'JSON'
{
  "forge-api": {"current": "", "prior": "", "deployedAt": ""},
  "forge-ui":     {"current": "", "prior": "", "deployedAt": ""},
  "forge-test":   {"current": "", "prior": "", "deployedAt": ""}
}
JSON
  chmod 0640 "$STATE_FILE"
  chown "${DEPLOY_USER}:${DEPLOY_GROUP}" "$STATE_FILE"
  ok "Created empty $STATE_FILE"
else
  # Validate existing state file is valid JSON; back up if not.
  if ! jq -e '.' "$STATE_FILE" >/dev/null 2>&1; then
    local_backup="${STATE_FILE}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    cp "$STATE_FILE" "$local_backup"
    warn "Existing state file was invalid JSON — backed up to $local_backup"
    cat > "$STATE_FILE" <<'JSON'
{
  "forge-api": {"current": "", "prior": "", "deployedAt": ""},
  "forge-ui":     {"current": "", "prior": "", "deployedAt": ""},
  "forge-test":   {"current": "", "prior": "", "deployedAt": ""}
}
JSON
  fi
  chmod 0640 "$STATE_FILE"
  chown "${DEPLOY_USER}:${DEPLOY_GROUP}" "$STATE_FILE"
  ok "Preserved existing $STATE_FILE"
fi

# ─────────────────────────────────────────────────────────────
# Log file
# ─────────────────────────────────────────────────────────────

step "Setting up log"

if [[ ! -f "$LOG_FILE" ]]; then
  install -m 0644 -o "$DEPLOY_USER" -g "$DEPLOY_GROUP" /dev/null "$LOG_FILE"
  ok "Created $LOG_FILE"
else
  chmod 0644 "$LOG_FILE"
  chown "${DEPLOY_USER}:${DEPLOY_GROUP}" "$LOG_FILE"
  ok "Preserved existing $LOG_FILE"
fi

# ─────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────

step "Install complete"
cat <<EOF

Next steps:
  1. Make sure ${REPO_ROOT}/.env exists (run ./setup.sh once if not).
  2. Confirm ${REPO_ROOT}/docker-compose.prod.yml is present.
  3. Try:    forge-deploy --help
             forge-deploy --list
             forge-deploy --status

Repo:   ${REPO_ROOT}
State:  ${STATE_FILE}
Log:    ${LOG_FILE}
User:   ${DEPLOY_USER}:${DEPLOY_GROUP}

EOF
