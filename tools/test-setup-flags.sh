#!/usr/bin/env bash
# test-setup-flags.sh — setup.sh's opt-outs do what its help says.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$REPO_ROOT/setup.sh"
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

READ_ENV=$(grep -E '^(SKIP_HOST_WATCHDOG=\$\{SKIP_HOST_WATCHDOG|\[\[ "\$\{SKIP_HOST_WATCHDOG)' "$SETUP")
GATE=$(grep -E '^if \$IS_LINUX && ! \$SKIP_HOST_WATCHDOG; then$' "$SETUP")

printf '%sHost watchdog opt-out%s\n' "$C_Y" "$C_0"
if [[ -z "$READ_ENV" || -z "$GATE" ]]; then
  printf '  %s✗%s could not find the SKIP_HOST_WATCHDOG lines in setup.sh — the extraction is stale\n' "$C_R" "$C_0"
  exit 1
fi

decide() {
  timeout 10 env -i PATH="$PATH" ${1+SKIP_HOST_WATCHDOG="$1"} bash -c "
    set -euo pipefail
    IS_LINUX=true
    $READ_ENV
    $GATE echo install; else echo skip; fi
  " 2>&1
}

for v in 1 true TRUE yes; do
  check "SKIP_HOST_WATCHDOG=$v skips the install" "$(decide "$v")" skip
done
for v in 0 false no ""; do
  check "SKIP_HOST_WATCHDOG='$v' installs it" "$(decide "$v")" install
done
check "unset installs it" "$(decide)" install

FLAG=$(grep -E '^[[:space:]]*--skip-host-watchdog\)' "$SETUP")
check "--skip-host-watchdog sets the skip" "$(sed -E 's/.*\)[[:space:]]*//' <<<"$FLAG")" "SKIP_HOST_WATCHDOG=true ;;"

printf '\n──────────────────────────────\n'
printf '  %s%d passed%s   %s%d failed%s\n\n' "$C_G" "$PASS" "$C_0" \
  "$( ((FAIL)) && printf '%s' "$C_R" || printf '%s' "$C_G")" "$FAIL" "$C_0"
(( FAIL == 0 ))
