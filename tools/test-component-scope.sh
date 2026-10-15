#!/usr/bin/env bash
# test-component-scope.sh — the optional test/demo SPAs deploy only where
# their compose profile is on, whatever FORGE_DEPLOY_SERVICES says.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="${REPO_ROOT}/scripts/forge-deploy"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_0=$'\033[0m'
PASS=0; FAIL=0

mkdir -p "$SANDBOX/tree/scripts" "$SANDBOX/state"
cp "$REPO_ROOT/scripts/docker-probe.sh" "$SANDBOX/tree/scripts/"
: > "$SANDBOX/tree/docker-compose.yml"
: > "$SANDBOX/tree/docker-compose.prod.yml"

check() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    printf '  %s✓%s %s\n' "$C_G" "$C_0" "$name"; PASS=$((PASS+1))
  else
    printf '  %s✗%s %s\n      want: %s\n      got:  %s\n' "$C_R" "$C_0" "$name" "$want" "$got"; FAIL=$((FAIL+1))
  fi
}

write_env() {
  printf 'SERVER_IMAGE_TAG=1.0.0-beta.29\nUI_IMAGE_TAG=1.0.0-beta.29\n%s\n' "$1" > "$SANDBOX/tree/.env"
}

run_cli() {
  timeout 20 env PATH="$PATH" FORGE_DEPLOY_REPO="$SANDBOX/tree" FORGE_STATE_DIR="$SANDBOX/state" \
    FORGE_LOG_FILE="$SANDBOX/state/forge-deploy.log" NO_COLOR=1 bash "$CLI" "$@" 2>&1
}

deploys() { run_cli --components | grep -E '^This box deploys:' | sed -E 's/^This box deploys: +//;s/ *$//'; }
optin()   { run_cli --components | grep -E '^Opt-in via COMPOSE_PROFILES:' | sed -E 's/^[^:]+: +//'; }

printf '%sWhich components a box deploys%s\n' "$C_Y" "$C_0"
write_env 'FORGE_DEPLOY_SERVICES='
check "unset scope is api + ui" "$(deploys)" "api ui"
write_env $'FORGE_DEPLOY_SERVICES=api ui demo test'
check "a legacy all-four scope drops the extras without their profiles" "$(deploys)" "api ui"
check "and says how to opt in" "$(optin)" "test, demo"
write_env $'FORGE_DEPLOY_SERVICES=api ui demo test\nCOMPOSE_PROFILES=logging,test'
check "the test profile opts the test-bed in" "$(deploys)" "api ui test"
check "and only demo stays opt-in" "$(optin)" "demo"
write_env $'FORGE_DEPLOY_SERVICES=\nCOMPOSE_PROFILES=demo'
check "the demo profile opts the demo in with an unset scope" "$(deploys)" "api ui demo"
write_env $'FORGE_DEPLOY_SERVICES=ui\nCOMPOSE_PROFILES=test'
check "an explicit scope still excludes what it does not name" "$(deploys)" "ui"

printf '\n%sSetup extras%s\n' "$C_Y" "$C_0"
write_env 'FORGE_DEPLOY_SERVICES='
check "--with rejects an unknown extra" "$(run_cli --setup --role all --with nope | grep -oE "Unknown extra '[a-z]+'")" "Unknown extra 'nope'"
check "--with refuses an extra on a db box" "$(run_cli --setup --role db --with test | grep -oE 'runs no versioned component')" "runs no versioned component"

printf '\n──────────────────────────────\n'
printf '  %s%d passed%s   %s%d failed%s\n\n' "$C_G" "$PASS" "$C_0" \
  "$( ((FAIL)) && printf '%s' "$C_R" || printf '%s' "$C_G")" "$FAIL" "$C_0"
(( FAIL == 0 ))
