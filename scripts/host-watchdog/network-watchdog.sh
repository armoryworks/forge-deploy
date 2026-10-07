#!/usr/bin/env bash
# network-watchdog.sh — Detect a wedged network stack on the Forge host and
# recover automatically.
#
# Symptom this addresses: the host's OS stays alive (you can log in on the
# console, commands run), but the network stack is dead — SSH unreachable,
# Cloudflare Tunnel 1033/530, router doesn't even see the MAC. Pi 4/5
# Ethernet (USB-attached LAN7800) and Broadcom WiFi both hang in this mode
# under load or after long uptimes. The hardware watchdog won't catch it
# (systemd keeps petting); only a layer-3 reachability check will.
#
# Escalation:
#   - failure 1     : log only (one bad minute is normal noise)
#   - failure 2     : restart the active network manager
#   - failure >= 4  : reboot the host
#
# Counter resets on the first successful check.
#
# Pinged targets:
#   - 1.1.1.1, 8.8.8.8        (upstream reachability)
#   - default gateway (auto)  (LAN-level reachability)
#
# The gateway is resolved on every run via `ip route`, so the script works
# unchanged across networks (lab, customer site, traveling Pi).
#
# Designed to be run from a systemd timer once per minute. See the bundled
# .service and .timer units. Exits 0 on success and on handled failures —
# the timer is the supervisor.

set -uo pipefail   # NOT -e: we want every branch to run to completion.

readonly LOG="/var/log/network-watchdog.log"
readonly STATE_FILE="/run/network-watchdog.state"
# Cross-reboot history of recent reboot timestamps (one epoch per line).
# Lives in /var/lib (NOT /run) so it survives the reboots we record into it
# — that's the whole point of the rate limit.
readonly REBOOT_HISTORY="/var/lib/forge-watchdog/reboot-history"
readonly RESTART_THRESHOLD=2
readonly REBOOT_THRESHOLD=4
readonly PING_COUNT=2
readonly PING_TIMEOUT=3
# Reboot rate limit: at most REBOOT_MAX reboots inside REBOOT_WINDOW seconds.
# Beyond that, the watchdog stops rebooting and keeps restarting networking +
# logging loudly — assumes the next reboot won't help (dead NIC, dead router,
# unplugged cable) and an indefinite ~5-min reboot loop would just chew the
# SD card without recovering anything.
readonly REBOOT_WINDOW=3600
readonly REBOOT_MAX=3

log() {
    # Append timestamped line. Best-effort: if the log isn't writable we
    # still want the rest of the script to run.
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG" 2>/dev/null || true
}

# Resolve the current default gateway. Empty if no default route.
detect_gateway() {
    ip route 2>/dev/null | awk '/^default/ {print $3; exit}'
}

# TCP-connect fallback for networks that drop ICMP to public IPs but allow
# HTTPS — common on managed / enterprise gateways. Without this, an ICMP
# block alone is sufficient to put a perfectly healthy box into a reboot
# loop. Uses bash's /dev/tcp pseudo-device under a hard timeout so a
# silently-dropped connect can't wedge the watchdog itself.
check_tcp() {
    local targets=("1.1.1.1:443" "8.8.8.8:443")
    local target host port
    for target in "${targets[@]}"; do
        host=${target%:*}
        port=${target#*:}
        if timeout "$PING_TIMEOUT" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# Returns 0 if ANY target answers ICMP, or — when every ICMP attempt fails —
# if a TCP connect to a public HTTPS port succeeds. The ICMP-first ordering
# stays the same; the TCP fallback only matters for networks that block ICMP
# for benign reasons (no fault on the box).
check_network() {
    local targets=("1.1.1.1" "8.8.8.8")
    local gw
    gw=$(detect_gateway)
    [[ -n "$gw" ]] && targets+=("$gw")

    local target
    for target in "${targets[@]}"; do
        if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$target" >/dev/null 2>&1; then
            return 0
        fi
    done
    # ICMP-blocked-but-otherwise-healthy fallback. Logs nothing on success
    # so the line is identical to the normal happy path.
    check_tcp
}

# Has the reboot rate limit (REBOOT_MAX per REBOOT_WINDOW seconds) been hit?
# Returns 0 when rebooting is still permitted, 1 when the limit is exhausted.
# Side effect: prunes timestamps older than the window before counting.
reboot_allowed() {
    local dir
    dir=$(dirname "$REBOOT_HISTORY")
    # If the state dir is missing (install-host-watchdog didn't create it),
    # err on the side of permitting reboots — the rate limit is a safety net,
    # not a hard gate.
    [[ -d "$dir" ]] || return 0
    local now cutoff recent
    now=$(date +%s)
    cutoff=$((now - REBOOT_WINDOW))
    if [[ -r "$REBOOT_HISTORY" ]]; then
        awk -v c="$cutoff" '$1+0 >= c+0' "$REBOOT_HISTORY" > "${REBOOT_HISTORY}.tmp" 2>/dev/null \
            && mv "${REBOOT_HISTORY}.tmp" "$REBOOT_HISTORY" 2>/dev/null
        recent=$(wc -l < "$REBOOT_HISTORY" 2>/dev/null || echo 0)
    else
        recent=0
    fi
    (( recent < REBOOT_MAX ))
}

# Record the impending reboot in the persistent history, then trigger it.
# The recording happens BEFORE the actual reboot call so the cross-reboot
# counter still increments even if systemctl reboot races against
# subsequent state mutation.
do_reboot() {
    local dir
    dir=$(dirname "$REBOOT_HISTORY")
    if [[ -d "$dir" ]]; then
        date +%s >> "$REBOOT_HISTORY" 2>/dev/null || true
    fi
    sync
    if command -v systemctl >/dev/null 2>&1; then
        systemctl reboot
    else
        /sbin/reboot
    fi
}

# Restart whichever network manager is actually in use. Some Pi OS / Ubuntu
# Server installs use NetworkManager; others use systemd-networkd. Try the
# active one first; fall back to the other for safety.
restart_networking() {
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        log "Restarting NetworkManager"
        systemctl restart NetworkManager
        return $?
    fi
    if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        log "Restarting systemd-networkd"
        systemctl restart systemd-networkd
        return $?
    fi
    log "No known network manager active — skipping restart"
    return 1
}

main() {
    if check_network; then
        # Healthy: clear counter and exit silently.
        echo 0 > "$STATE_FILE" 2>/dev/null || true
        exit 0
    fi

    local fails=0
    if [[ -r "$STATE_FILE" ]]; then
        fails=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
        # Guard against a junk state file.
        [[ "$fails" =~ ^[0-9]+$ ]] || fails=0
    fi
    fails=$((fails + 1))
    echo "$fails" > "$STATE_FILE" 2>/dev/null || true

    local gw
    gw=$(detect_gateway)
    log "Network check failed (failure #${fails}). gateway=${gw:-<none>}"

    if (( fails == RESTART_THRESHOLD )); then
        restart_networking || log "restart_networking returned non-zero"
    elif (( fails >= REBOOT_THRESHOLD )); then
        if reboot_allowed; then
            log "Network unrecoverable after ${fails} consecutive failures — rebooting."
            do_reboot
        else
            # The cross-reboot rate limit tripped. Almost always means the
            # fault is something a reboot can't fix (dead NIC, unplugged
            # cable, dead router) and we've already burned several reboots
            # on it. Stop the loop; keep restarting networking and logging
            # so an operator who logs in via console can see what happened.
            log "Reboot rate limit reached (${REBOOT_MAX} in ${REBOOT_WINDOW}s); skipping reboot, restarting network instead."
            restart_networking || log "restart_networking returned non-zero"
        fi
    fi
    exit 0
}

main "$@"
