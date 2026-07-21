#!/usr/bin/env bash
# doctor.sh — one-command triage for a Forge install's network exposure.
#
# Runs every check an operator would otherwise do by hand — stack health,
# local TLS, host firewall, public IP, NAT-hairpin detection, and a real
# outside-in reachability probe — and ends with a plain-language verdict
# and the exact next action (including the literal port-forward rules to
# type into the router).
#
# Zero arguments, zero interaction, safe to re-run any time:
#   ./doctor.sh
#   ./setup.sh --doctor
#   npx @armoryworks/forge-deploy --doctor
#
# The outside-in probe uses check-host.net's free API (their monitoring
# nodes try to open TCP connections to this host from the internet). If
# that API is unreachable the doctor says so and falls back to telling
# the operator how to test manually — it never fakes a result.

set -uo pipefail
cd "$(dirname "$0")"

step()  { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
ok()    { printf '    \033[32m[OK] %s\033[0m\n' "$1"; }
warn()  { printf '    \033[33m[!!] %s\033[0m\n' "$1"; }
fail()  { printf '    \033[31m[X]  %s\033[0m\n' "$1"; }
info()  { printf '         %s\n' "$1"; }

# Verdict accumulator — every failed check queues one plain-language action.
ACTIONS=()
action() { ACTIONS+=("$1"); }

CURL="curl -s --max-time 8"

# ── 1. Stack health ─────────────────────────────────────────────────────────
step "Checking the Forge stack"

if ! command -v docker &>/dev/null; then
    fail "Docker is not installed (or not on PATH)."
    action "Install Docker, then run ./setup.sh"
    STACK_UP=false
elif ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^forge-ui$'; then
    fail "The forge-ui container is not running."
    action "Start the stack: cd $(pwd) && ./setup.sh"
    STACK_UP=false
else
    STACK_UP=true
    for c in forge-ui forge-api forge; do
        state=$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$c" 2>/dev/null || echo missing)
        case "$state" in
            "running healthy"|"running") ok "$c is running" ;;
            missing) fail "$c container is missing"; action "Re-run ./setup.sh to recreate the $c container" ;;
            *) warn "$c is $state"; action "Check logs: docker logs $c --tail 50" ;;
        esac
    done
fi

# ── 2. Exposure mode (from published ports) ────────────────────────────────
step "Detecting deployment target"

UI_PORTS=$($STACK_UP && docker port forge-ui 2>/dev/null || true)
HAS_443=false; LOOPBACK_ONLY=true
if grep -q '0.0.0.0:443' <<<"$UI_PORTS"; then HAS_443=true; LOOPBACK_ONLY=false; fi
if grep -qE '0.0.0.0:(80|4200)' <<<"$UI_PORTS"; then LOOPBACK_ONLY=false; fi

if ! $STACK_UP; then
    warn "Skipped — stack is not running."
elif $LOOPBACK_ONLY; then
    warn "This install is LOCAL-ONLY (UI bound to 127.0.0.1 — invisible even to your LAN)."
    info "That is the '--local' target. To expose it, re-run: ./setup.sh --lan  or  ./setup.sh --public"
    action "If you intended internet exposure, run: ./setup.sh --public"
elif $HAS_443; then
    ok "Public/standalone target: UI is published on this machine's port 443 (HTTPS)."
else
    ok "LAN target: UI is published over plain HTTP (no 443). Internet exposure needs: ./setup.sh --public"
fi

# ── 3. Local TLS ────────────────────────────────────────────────────────────
LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if $STACK_UP && $HAS_443; then
    step "Checking HTTPS on this machine"
    code=$($CURL -k -o /dev/null -w '%{http_code}' https://localhost/ || echo 000)
    if [[ "$code" == "200" ]]; then
        ok "TLS answers locally (https://localhost -> $code)."
    else
        fail "https://localhost returned '$code' — the SSL config is not serving."
        action "Re-run ./setup.sh --public (regenerates the SSL override), then re-run this doctor"
    fi

    # From-the-LAN path (same TLS, but through the host firewall).
    if [[ -n "$LAN_IP" ]]; then
        code=$($CURL -k -o /dev/null -w '%{http_code}' "https://${LAN_IP}/" || echo 000)
        if [[ "$code" == "200" ]]; then
            ok "TLS answers on the LAN address (https://${LAN_IP})."
        else
            fail "https://${LAN_IP} returned '$code' — a host firewall is likely blocking LAN/WAN traffic."
            if command -v ufw &>/dev/null && sudo -n ufw status &>/dev/null; then
                sudo -n ufw status | grep -qE '443' && info "ufw has a 443 rule — check its ordering." \
                    || action "Open the firewall: sudo ufw allow 80/tcp && sudo ufw allow 443/tcp"
            else
                action "Open ports 80 and 443 in this machine's firewall (e.g. sudo ufw allow 443/tcp)"
            fi
        fi
    fi
fi

# ── 4. Public IP ────────────────────────────────────────────────────────────
step "Discovering this network's public IP"
PUBLIC_IP=$($CURL -4 https://ifconfig.me || true)
if [[ -z "$PUBLIC_IP" ]]; then
    warn "Could not discover the public IP (no outbound internet?)."
else
    ok "Public IP: $PUBLIC_IP"
    info "If your router's WAN/Internet status page shows a DIFFERENT address"
    info "(especially 100.64.x.x), you are behind carrier NAT and port"
    info "forwarding cannot work — ask your ISP for a routable IP."
fi

# ── 5. Hairpin check (why testing your own public IP from inside lies) ─────
if $STACK_UP && $HAS_443 && [[ -n "$PUBLIC_IP" ]]; then
    step "Checking what answers your public IP from INSIDE this network"
    local_serial=$(echo | openssl s_client -connect localhost:443 2>/dev/null | openssl x509 -noout -serial 2>/dev/null || true)
    pub_serial=$(echo | timeout 8 openssl s_client -connect "${PUBLIC_IP}:443" 2>/dev/null | openssl x509 -noout -serial 2>/dev/null || true)
    if [[ -n "$pub_serial" && "$pub_serial" == "$local_serial" ]]; then
        ok "Your router hairpins correctly — the public IP reaches Forge even from inside."
    elif [[ -n "$pub_serial" ]]; then
        warn "Something answered ${PUBLIC_IP}:443 from inside — but it is NOT this Forge install."
        info "That is almost certainly your router's own admin page. Move the router's"
        info "web admin off port 443 (Administration settings), or it will shadow Forge."
        action "Move the router's web-admin/remote-management port off 443"
    else
        warn "Testing your own public IP from inside this network does not work here"
        info "(no NAT hairpin). This is normal and NOT an error: from inside, use"
        info "https://${LAN_IP} — the public address is only for people outside."
    fi
fi

# ── 6. Outside-in reachability (the test that actually counts) ─────────────
if $STACK_UP && $HAS_443 && [[ -n "$PUBLIC_IP" ]]; then
    step "Probing ${PUBLIC_IP}:443 from the internet (via check-host.net)"
    probe_result="unknown"
    req=$($CURL -H 'Accept: application/json' \
        "https://check-host.net/check-tcp?host=${PUBLIC_IP}:443&max_nodes=3" || true)
    req_id=$(sed -n 's/.*"request_id" *: *"\([^"]*\)".*/\1/p' <<<"$req")
    if [[ -n "$req_id" ]]; then
        sleep 6
        res=$($CURL -H 'Accept: application/json' "https://check-host.net/check-result/${req_id}" || true)
        if grep -q '"time"' <<<"$res"; then
            probe_result="open"
        elif grep -qE '"error"|null' <<<"$res"; then
            probe_result="closed"
        fi
    fi
    case "$probe_result" in
        open)
            ok "REACHABLE — the internet can connect to https://${PUBLIC_IP}" ;;
        closed)
            fail "NOT reachable from the internet — connections to ${PUBLIC_IP}:443 are dropped."
            info "Everything on this machine checks out, so the block is upstream:"
            info "  1. Router port forwarding (most likely — see the rules below)"
            info "  2. Router web admin squatting on port 443 (move it off 443)"
            info "  3. ISP blocking inbound 80/443 (call them, or use a high port)"
            action "Add these port-forward rules on the router (then re-run this doctor):
              forge-http   external 80  -> ${LAN_IP:-<this-machine>}:80   TCP
              forge-https  external 443 -> ${LAN_IP:-<this-machine>}:443  TCP
           ...and make sure the router's master 'Enable Port Forwarding' switch is ON." ;;
        *)
            warn "Could not run the outside-in probe (check-host.net unreachable)."
            info "Manual test: from a phone on CELLULAR (Wi-Fi off), open https://${PUBLIC_IP}" ;;
    esac
fi

# ── Verdict ─────────────────────────────────────────────────────────────────
step "Verdict"
if [[ ${#ACTIONS[@]} -eq 0 ]]; then
    ok "No problems found."
    if $STACK_UP && $HAS_443 && [[ -n "${PUBLIC_IP:-}" ]]; then
        info "Share this address with users outside the building: https://${PUBLIC_IP}"
        [[ -n "$LAN_IP" ]] && info "People inside the building use: https://${LAN_IP}"
        info "(Browsers show a one-time 'proceed anyway' warning — expected with a self-signed certificate.)"
    fi
else
    printf '    \033[33mDo this next:\033[0m\n'
    n=1
    for a in "${ACTIONS[@]}"; do
        printf '    %d. %s\n' "$n" "$a"
        n=$((n+1))
    done
    info ""
    info "Then run this doctor again — it is safe to repeat until everything is [OK]."
fi
echo ""
