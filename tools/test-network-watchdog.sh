#!/usr/bin/env bash
# test-network-watchdog.sh — the host watchdog never restarts or reboots a box whose network was never reachable.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/scripts/host-watchdog/network-watchdog.sh"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_0=$'\033[0m'
PASS=0; FAIL=0

check() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    printf '  %s✓%s %s\n' "$C_G" "$C_0" "$name"; PASS=$((PASS+1))
  else
    printf '  %s✗%s %s (got %q, want %q)\n' "$C_R" "$C_0" "$name" "$got" "$want"; FAIL=$((FAIL+1))
  fi
}

FAKE="$SANDBOX/fake"
RUN="$SANDBOX/run"
mkdir -p "$SANDBOX/bin" "$FAKE"

cat > "$SANDBOX/bin/ping" <<'STUB'
#!/usr/bin/env bash
[[ -e "$FAKE_DIR/net-up" ]]
STUB
cat > "$SANDBOX/bin/timeout" <<'STUB'
#!/usr/bin/env bash
[[ -e "$FAKE_DIR/net-up" ]]
STUB
cat > "$SANDBOX/bin/ip" <<'STUB'
#!/usr/bin/env bash
[[ -s "$FAKE_DIR/gateway" ]] && printf 'default via %s dev eth0\n' "$(cat "$FAKE_DIR/gateway")"
exit 0
STUB
cat > "$SANDBOX/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  is-active) [[ "$*" == *NetworkManager* ]] ;;
  *) printf '%s\n' "$*" >> "$FAKE_DIR/systemctl-calls" ;;
esac
STUB
chmod +x "$SANDBOX/bin/"*

WATCHDOG="$SANDBOX/network-watchdog.sh"
sed -E \
  -e "s#^readonly LOG=\".*\"#readonly LOG=\"$RUN/log\"#" \
  -e "s#^readonly STATE_FILE=\".*\"#readonly STATE_FILE=\"$RUN/state\"#" \
  -e "s#^readonly HEALTHY_MARKER=\".*\"#readonly HEALTHY_MARKER=\"$RUN/seen-healthy\"#" \
  -e "s#^readonly REBOOT_HISTORY=\".*\"#readonly REBOOT_HISTORY=\"$RUN/lib/reboot-history\"#" \
  "$SRC" > "$WATCHDOG"

printf '%sSandbox%s\n' "$C_Y" "$C_0"
check "every host path is redirected into the sandbox" "$(grep -c "^readonly [A-Z_]*=\"$RUN/" "$WATCHDOG")" 4

reset_box() {
  rm -rf "$RUN" "$FAKE"/net-up "$FAKE"/gateway "$FAKE"/systemctl-calls
  mkdir -p "$RUN/lib"
  : > "$FAKE/systemctl-calls"
  [[ -n "${1:-}" ]] && printf '%s\n' "$1" > "$FAKE/gateway"
  return 0
}
tick() { PATH="$SANDBOX/bin:$PATH" FAKE_DIR="$FAKE" bash "$WATCHDOG" >/dev/null 2>&1; }
ticks() { local i; for ((i = 0; i < $1; i++)); do tick; done; }
calls() { tr '\n' ';' < "$FAKE/systemctl-calls"; }

printf '%sNetwork never reachable since boot%s\n' "$C_Y" "$C_0"
reset_box 192.168.1.1
ticks 10
check "a gateway that never answers: no restart, no reboot" "$(calls)" ""
check "logs once instead of every minute" "$(grep -c . "$RUN/log")" 1
reset_box
ticks 10
check "no default route: no restart, no reboot" "$(calls)" ""

printf '%sNetwork was healthy, then failed%s\n' "$C_Y" "$C_0"
reset_box 192.168.1.1
touch "$FAKE/net-up"; tick; rm -f "$FAKE/net-up"
ticks 2
check "restarts networking on the second failure" "$(calls)" "restart NetworkManager;"
ticks 2
check "reboots on the fourth failure" "$(calls)" "restart NetworkManager;reboot;"

reset_box 192.168.1.1
touch "$FAKE/net-up"; tick; rm -f "$FAKE/gateway" "$FAKE/net-up"
ticks 6
check "no default route: restarts networking but never reboots" "$(calls)" "restart NetworkManager;"

reset_box 192.168.1.1
touch "$FAKE/net-up"; tick; rm -f "$FAKE/net-up"
ticks 1
touch "$FAKE/net-up"; tick; rm -f "$FAKE/net-up"
ticks 1
check "a healthy check resets the count" "$(calls)" ""

printf '\n──────────────────────────────\n'
printf '  %s%d passed%s   %s%d failed%s\n\n' "$C_G" "$PASS" "$C_0" \
  "$( ((FAIL)) && printf '%s' "$C_R" || printf '%s' "$C_G")" "$FAIL" "$C_0"
(( FAIL == 0 ))
