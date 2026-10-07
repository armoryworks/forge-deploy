#!/usr/bin/env bash
# install-host-watchdog.sh — Install the Forge host network watchdog on the Pi.
#
# What this installs:
#   /usr/local/sbin/forge-network-watchdog            (executable script)
#   /etc/systemd/system/forge-network-watchdog.service
#   /etc/systemd/system/forge-network-watchdog.timer
#
# Then: daemon-reload, enable + start the timer.
#
# Idempotent: re-running is safe. Source files are overwritten, the timer
# is re-enabled, the log is preserved.
#
# Linux-only. Bails out cleanly on macOS or any system without systemd —
# setup.sh calls this unconditionally on Linux, so the bailout matters.
#
# Usage:
#   sudo ./scripts/install-host-watchdog.sh
#   sudo ./scripts/install-host-watchdog.sh --uninstall
#
# Env:
#   FORGE_DEPLOY_REPO   Path to the forge-deploy git checkout (default: auto)

set -euo pipefail

# ─────────────────────────────────────────────────────────────
# OS gate — fail fast and quietly on non-Linux or non-systemd hosts.
# ─────────────────────────────────────────────────────────────

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "host-watchdog: not Linux — skipping (systemd-only feature)." >&2
    exit 0
fi
if ! command -v systemctl >/dev/null 2>&1; then
    echo "host-watchdog: systemctl not found — skipping." >&2
    exit 0
fi

# ─────────────────────────────────────────────────────────────
# Auto-elevate (matches install-forge-deploy.sh pattern).
# ─────────────────────────────────────────────────────────────

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

readonly SRC_DIR="${REPO_ROOT}/scripts/host-watchdog"
readonly SRC_SCRIPT="${SRC_DIR}/network-watchdog.sh"
readonly SRC_SERVICE="${SRC_DIR}/network-watchdog.service"
readonly SRC_TIMER="${SRC_DIR}/network-watchdog.timer"

readonly DEST_SCRIPT="/usr/local/sbin/forge-network-watchdog"
readonly DEST_SERVICE="/etc/systemd/system/forge-network-watchdog.service"
readonly DEST_TIMER="/etc/systemd/system/forge-network-watchdog.timer"
readonly LOG_FILE="/var/log/network-watchdog.log"
readonly STATE_DIR="/var/lib/forge-watchdog"
readonly REBOOT_HISTORY="${STATE_DIR}/reboot-history"

# ─────────────────────────────────────────────────────────────
# Color helpers (skip when not a TTY) — matches install-forge-deploy.sh.
# ─────────────────────────────────────────────────────────────

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
# Uninstall path
# ─────────────────────────────────────────────────────────────

if [[ "${1:-}" == "--uninstall" ]]; then
    step "Uninstalling host network watchdog"
    systemctl disable --now forge-network-watchdog.timer 2>/dev/null || true
    systemctl stop forge-network-watchdog.service 2>/dev/null || true
    rm -f "$DEST_TIMER" "$DEST_SERVICE" "$DEST_SCRIPT"
    systemctl daemon-reload
    ok "Removed timer, service, and script"
    warn "Log preserved at $LOG_FILE (delete manually if desired)"
    warn "Reboot history preserved at $REBOOT_HISTORY (delete $STATE_DIR if desired)"
    exit 0
fi

# ─────────────────────────────────────────────────────────────
# Pre-flight
# ─────────────────────────────────────────────────────────────

step "Pre-flight checks"

for f in "$SRC_SCRIPT" "$SRC_SERVICE" "$SRC_TIMER"; do
    [[ -f "$f" ]] || die "Source file missing: $f"
done
ok "Source files present in $SRC_DIR"

for cmd in ip ping awk systemctl install; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command missing: $cmd"
done
ok "Found: ip, ping, awk, systemctl, install"

# Sanity check — confirm the script itself parses cleanly before we deploy it.
if ! bash -n "$SRC_SCRIPT"; then
    die "bash -n failed on $SRC_SCRIPT — refusing to install a broken watchdog"
fi
ok "Syntax check passed on watchdog script"

# ─────────────────────────────────────────────────────────────
# Install files
# ─────────────────────────────────────────────────────────────

step "Installing files"

install -m 0755 "$SRC_SCRIPT"  "$DEST_SCRIPT"
ok "Installed: $DEST_SCRIPT (0755)"

install -m 0644 "$SRC_SERVICE" "$DEST_SERVICE"
ok "Installed: $DEST_SERVICE (0644)"

install -m 0644 "$SRC_TIMER"   "$DEST_TIMER"
ok "Installed: $DEST_TIMER (0644)"

# Pre-create the log file so the first failure write isn't a race.
if [[ ! -f "$LOG_FILE" ]]; then
    install -m 0644 /dev/null "$LOG_FILE"
    ok "Created $LOG_FILE"
else
    chmod 0644 "$LOG_FILE"
    ok "Preserved existing $LOG_FILE"
fi

# Persistent state dir — lives in /var/lib (NOT /run) so the cross-reboot
# reboot-rate-limit history survives the reboots it records. Without this
# the rate limit is bypassed and a sustained LAN outage can loop the box
# every ~5 minutes indefinitely.
install -d -m 0755 "$STATE_DIR"
if [[ ! -f "$REBOOT_HISTORY" ]]; then
    install -m 0644 /dev/null "$REBOOT_HISTORY"
    ok "Created $REBOOT_HISTORY"
else
    ok "Preserved existing $REBOOT_HISTORY"
fi

# ─────────────────────────────────────────────────────────────
# Reload systemd + enable the timer
# ─────────────────────────────────────────────────────────────

step "Enabling timer"

systemctl daemon-reload
ok "systemd daemon-reload"

systemctl enable --now forge-network-watchdog.timer
ok "Timer enabled and started"

# ─────────────────────────────────────────────────────────────
# Verification — show the user what we just did.
# ─────────────────────────────────────────────────────────────

step "Verification"

if systemctl is-active --quiet forge-network-watchdog.timer; then
    ok "Timer is active"
else
    warn "Timer is not active — check 'systemctl status forge-network-watchdog.timer'"
fi

# Show the next scheduled fire time, if available.
NEXT=$(systemctl list-timers --no-pager forge-network-watchdog.timer 2>/dev/null \
         | awk 'NR==2 {print $1" "$2}')
if [[ -n "$NEXT" && "$NEXT" != " " ]]; then
    ok "Next run: $NEXT"
fi

# Run the watchdog once now as a smoke test. On a healthy host this exits
# silently and writes nothing to the log; on a broken host this is exactly
# what would happen on the next timer tick anyway.
step "Smoke test (one immediate run)"
if "$DEST_SCRIPT"; then
    ok "Watchdog script ran successfully"
else
    warn "Watchdog script exited non-zero — review $LOG_FILE"
fi

# ─────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────

step "Install complete"
cat <<EOF

The host network watchdog is now active.

  Behavior:
    - Runs every minute via systemd timer.
    - Probes ICMP to 1.1.1.1, 8.8.8.8, and the default gateway; falls back
      to TCP 443 on the public targets if ICMP is blocked (corporate /
      enterprise gateways often drop ICMP without blocking HTTPS).
    - After 2 consecutive failures: restarts the active network manager.
    - After 4 consecutive failures: reboots the host.
    - Reboot rate limit: at most 3 reboots per hour. Beyond that the
      watchdog keeps restarting networking + logging but stops rebooting
      — a sustained LAN failure means the next reboot won't help either,
      and an indefinite reboot loop just wears the SD card.
    - Counter resets on the first successful check.

  Files:
    Script:    $DEST_SCRIPT
    Service:   $DEST_SERVICE
    Timer:     $DEST_TIMER
    Log:       $LOG_FILE   (silent on success — only writes on failure)
    Reboot history: $REBOOT_HISTORY   (cross-reboot for the rate limit)

  Inspect:
    systemctl status  forge-network-watchdog.timer
    systemctl list-timers forge-network-watchdog.timer
    journalctl -u forge-network-watchdog.service --since today

  Uninstall:
    sudo ${BASH_SOURCE[0]} --uninstall

EOF
