#!/usr/bin/env bash
# test-install-discovery.sh — the npm bootstrapper's no-argument path.
#
# The promise is that `npx @armoryworks/forge-deploy`, typed from anywhere on a
# box that already runs Forge, opens the console on THAT install. The failure it
# guards against is the expensive one: a client standing in $HOME being handed
# the first-install wizard for a machine that is already deployed. None of this
# may touch the network, so every assertion below also proves no fetch happened.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${REPO_ROOT}/bin/install.mjs"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0; FAIL=0
C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_0=$'\033[0m'

scenario() { printf '\n%s%s%s\n' "$C_Y" "$1" "$C_0"; }
check() {
  # check <label> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then printf '  %s✓%s %s\n' "$C_G" "$C_0" "$1"; PASS=$((PASS+1))
  else printf '  %s✗%s %s\n      wanted: %s\n' "$C_R" "$C_0" "$1" "$3"; FAIL=$((FAIL+1)); fi
}
refute() {
  if [[ "$2" != *"$3"* ]]; then printf '  %s✓%s %s\n' "$C_G" "$C_0" "$1"; PASS=$((PASS+1))
  else printf '  %s✗%s %s\n      unwanted: %s\n' "$C_R" "$C_0" "$1" "$3"; FAIL=$((FAIL+1)); fi
}

# A tree the installer must accept as an install and hand off to, without ever
# reaching for the network. The stub CLI reports the root it was given.
make_tree() {
  local dir="$1"
  mkdir -p "$dir/scripts"
  touch "$dir/.env"
  printf 'echo "CONSOLE root=${FORGE_DEPLOY_REPO:-unset} cwd=$PWD args=$*"\n' > "$dir/scripts/forge-deploy"
  printf 'exit 0\n' > "$dir/scripts/ensure-deps.sh"
  chmod +x "$dir/scripts/forge-deploy" "$dir/scripts/ensure-deps.sh"
}

# FORGE_DEPLOY_REF points at a tag that cannot exist, so any run that falls
# through to the download path fails loudly instead of quietly succeeding.
# run <cwd> <extra-env-assignments> [installer args...]
run() {
  local cwd="$1" extra="$2"; shift 2
  ( cd "$cwd" && env HOME="$SANDBOX/home" FORGE_STATE_DIR="$SANDBOX/state" \
      FORGE_DEPLOY_REF="tags/v0.0.0-never" \
      ${extra:+"$extra"} node "$INSTALLER" "$@" 2>&1 )
}

mkdir -p "$SANDBOX/state" "$SANDBOX/elsewhere" "$SANDBOX/home"

scenario "Standing inside the install"
make_tree "$SANDBOX/inplace"
out=$(run "$SANDBOX/inplace" "")
check "opens the console"            "$out" "CONSOLE"
check "on this tree"                 "$out" "root=$SANDBOX/inplace"
refute "never touches the network"   "$out" "Fetching forge-deploy"

scenario "Standing one level above it"
make_tree "$SANDBOX/above/forge-deploy"
out=$(run "$SANDBOX/above" "")
check "finds ./forge-deploy"         "$out" "root=$SANDBOX/above/forge-deploy"
refute "never touches the network"   "$out" "Fetching forge-deploy"

scenario "Standing somewhere unrelated, root recorded in the state file"
make_tree "$SANDBOX/recorded"
printf '{"box":{"role":"all","repoRoot":"%s"}}\n' "$SANDBOX/recorded" > "$SANDBOX/state/deploy-state.json"
out=$(run "$SANDBOX/elsewhere" "")
check "follows the recorded root"    "$out" "root=$SANDBOX/recorded"
refute "never touches the network"   "$out" "Fetching forge-deploy"

scenario "FORGE_DEPLOY_DIR wins over the recording"
make_tree "$SANDBOX/explicit"
out=$(run "$SANDBOX/elsewhere" "FORGE_DEPLOY_DIR=$SANDBOX/explicit")
check "uses the named tree"          "$out" "root=$SANDBOX/explicit"

scenario "Configured box whose tree cannot be found"
printf '{"box":{"role":"all","repoRoot":"%s/gone"}}\n' "$SANDBOX" > "$SANDBOX/state/deploy-state.json"
out=$(run "$SANDBOX/elsewhere" "")
check "refuses to install beside it" "$out" "has Forge configured"
check "says how to point at it"      "$out" "FORGE_DEPLOY_DIR"
refute "no first-install wizard"     "$out" "Fetching forge-deploy"

scenario "Genuinely fresh machine still installs"
rm -f "$SANDBOX/state/deploy-state.json"
# The search reaches /opt on any box; a real install there is a legitimate hit
# and would make this scenario meaningless rather than failing honestly.
if [[ -f /opt/forge-deploy/.env || -f /opt/forge/.env ]]; then
  printf '  %s—%s skipped: this machine has a real install under /opt\n' "$C_Y" "$C_0"
else
  out=$(run "$SANDBOX/home" "")
  check "goes to the download path"  "$out" "Fetching forge-deploy"
  check "into ./forge-deploy"        "$out" "$SANDBOX/home/forge-deploy"
fi

scenario "An argument means the caller has already chosen"
make_tree "$SANDBOX/recorded2"
printf '{"box":{"role":"all","repoRoot":"%s"}}\n' "$SANDBOX/recorded2" > "$SANDBOX/state/deploy-state.json"
out=$(run "$SANDBOX/elsewhere" "" --fetch-only)
refute "does not silently redirect"  "$out" "root=$SANDBOX/recorded2"
check "honours the explicit flag"    "$out" "Fetching forge-deploy"

printf '\n──────────────────────────────\n'
if (( FAIL == 0 )); then printf '  %s%d passed%s   %s0 failed%s\n\n' "$C_G" "$PASS" "$C_0" "$C_G" "$C_0"
else printf '  %s%d passed%s   %s%d failed%s\n\n' "$C_G" "$PASS" "$C_0" "$C_R" "$FAIL" "$C_0"; fi
(( FAIL == 0 ))
