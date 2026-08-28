#!/usr/bin/env bash
# test-install-discovery.sh — how an install is wired up and found again.
#
# The promise is that `npx @armoryworks/forge-deploy`, typed from anywhere on a
# box that already runs Forge, opens the console on THAT install. The failure it
# guards against is the expensive one: a client standing in $HOME being handed
# the first-install wizard for a machine that is already deployed. None of the
# discovery scenarios may touch the network, so each also proves no fetch
# happened.
#
# The final section covers the other half: install-forge-deploy.sh, which puts
# `forge-deploy` on PATH. FORGE_INSTALL_PREFIX relocates everything it writes,
# so it runs here without root.
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
# A tree is scripts/forge-deploy + setup.sh; .env is what makes it an install.
make_tree() {
  local dir="$1"
  make_unfinished_tree "$dir"
  touch "$dir/.env"
}

# The state a client is left in when setup aborts on a prerequisite.
make_unfinished_tree() {
  local dir="$1"
  mkdir -p "$dir/scripts"
  printf '#!/usr/bin/env bash\necho "SETUP root=$FORGE_DEPLOY_REPO caller=$FORGE_DEPLOY_CALLER"\n' > "$dir/setup.sh"
  chmod +x "$dir/setup.sh"
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
if [[ -f /opt/forge-deploy/setup.sh || -f /opt/forge/setup.sh ]]; then
  printf '  %s—%s skipped: this machine has a real deploy tree under /opt\n' "$C_Y" "$C_0"
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

scenario "Setup that never finished resumes in place"
make_unfinished_tree "$SANDBOX/aborted"
printf '{"box":{"repoRoot":"%s/aborted"}}\n' "$SANDBOX" > "$SANDBOX/state/deploy-state.json"
out=$(run "$SANDBOX/elsewhere" "")
check "says it is resuming"           "$out" "Resuming setup in $SANDBOX/aborted"
check "runs that tree's setup"        "$out" "SETUP root=$SANDBOX/aborted"
check "and marks itself the caller"   "$out" "caller=1"
refute "never claims it is missing"   "$out" "is not in any of the"
refute "no second install elsewhere"  "$out" "Fetching forge-deploy"

scenario "A finished install still wins over an unfinished tree"
make_tree "$SANDBOX/done"
out=$(run "$SANDBOX/elsewhere" "FORGE_DEPLOY_DIR=$SANDBOX/done")
check "opens the console, not setup"  "$out" "CONSOLE"
refute "does not resume setup"        "$out" "Resuming setup"

scenario "A dev checkout in the cwd cannot shadow the recorded root"
make_unfinished_tree "$SANDBOX/real-install"
make_tree "$SANDBOX/dev-checkout"
printf '{"box":{"repoRoot":"%s/real-install"}}\n' "$SANDBOX" > "$SANDBOX/state/deploy-state.json"
out=$(run "$SANDBOX/dev-checkout" "")
check "uses the recorded root"        "$out" "$SANDBOX/real-install"
refute "not the checkout it stood in" "$out" "root=$SANDBOX/dev-checkout"

scenario "The Docker probe classifies, in one place, for every caller"
# shellcheck source=../scripts/docker-probe.sh
( . "$REPO_ROOT/scripts/docker-probe.sh"
  probe_bin="$SANDBOX/probe-bin"; mkdir -p "$probe_bin"
  fake_docker() { printf '#!/usr/bin/env bash\n%s\n' "$1" > "$probe_bin/docker"; chmod +x "$probe_bin/docker"; }

  fake_docker 'echo "permission denied while trying to connect" >&2; exit 1'
  got=$(PATH="$probe_bin:$PATH" docker_state)
  check "a denied socket is 'denied'"  "$got" "denied"

  fake_docker 'echo "Cannot connect to the Docker daemon" >&2; exit 1'
  got=$(PATH="$probe_bin:$PATH" docker_state)
  check "a dead daemon is 'stopped'"   "$got" "stopped"

  fake_docker 'exit 0'
  got=$(PATH="$probe_bin:$PATH" docker_state)
  check "a working daemon is 'ok'"     "$got" "ok"

  printf '%d %d\n' "$PASS" "$FAIL" > "$SANDBOX/probe-tally" ) || true
read -r PASS FAIL < "$SANDBOX/probe-tally"

# The classification the operator actually hit: pipefail must not swallow it.
got=$(set -euo pipefail; . "$REPO_ROOT/scripts/docker-probe.sh"
      PATH="$SANDBOX/probe-bin:$PATH"; printf '#!/usr/bin/env bash\necho "permission denied" >&2; exit 1\n' > "$SANDBOX/probe-bin/docker"
      docker_state)
check "survives set -o pipefail"       "$got" "denied"

scenario "install-forge-deploy.sh wires the CLI to the tree it was run from"
JQ="$(command -v jq || true)"; [[ -n "$JQ" ]] || JQ="${FORGE_TEST_JQ:-}"
if [[ ! -x "$JQ" ]]; then
  printf '  %s—%s skipped: needs jq (install it, or set FORGE_TEST_JQ)\n' "$C_Y" "$C_0"
else
  TREE="$SANDBOX/srv-forge"; PREFIX="$SANDBOX/prefix"; JQ_PATH="$(dirname "$JQ"):$PATH"
  mkdir -p "$TREE"
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/docker-compose.yml" "$REPO_ROOT/.env.example" "$TREE/"
  PATH="$JQ_PATH" FORGE_INSTALL_PREFIX="$PREFIX" FORGE_DEPLOY_USER="$(id -un)" \
    timeout 60 bash "$TREE/scripts/install-forge-deploy.sh" >/dev/null 2>&1

  wrapper=$(cat "$PREFIX/usr/local/bin/forge-deploy" 2>&1)
  check "names this tree, not /opt"    "$wrapper" "$TREE"
  refute "no hard-wired default root"  "$wrapper" "{FORGE_DEPLOY_REPO:-/opt/forge-deploy}"

  recorded=$("$JQ" -r '.box.repoRoot // ""' "$PREFIX/etc/forge/deploy-state.json" 2>&1)
  check "records the root for lookup"  "$recorded" "$TREE"

  # The proof that matters: the command on PATH resolves to its own tree. As a
  # blind copy it read /opt/forge-deploy whatever tree it came from. Which of
  # the incomplete-tree checks fires first doesn't matter — the path it names
  # is the assertion.
  acted=$(PATH="$JQ_PATH" FORGE_STATE_DIR="$PREFIX/etc/forge" \
    timeout 60 "$PREFIX/usr/local/bin/forge-deploy" --status 2>&1)
  check "acts on its own tree"         "$acted" "$TREE/"
  refute "does not reach for /opt"     "$acted" "/opt/forge-deploy"

  # And the bootstrapper finds it from an unrelated directory via that record.
  # Stubbed from here on: the real console wants docker and a terminal.
  touch "$TREE/.env"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TREE/setup.sh"
  printf '#!/usr/bin/env bash\necho "CONSOLE root=$FORGE_DEPLOY_REPO"\n' > "$TREE/scripts/forge-deploy"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TREE/scripts/ensure-deps.sh"
  chmod +x "$TREE/scripts/forge-deploy" "$TREE/scripts/ensure-deps.sh"
  out=$(run "$SANDBOX/elsewhere" "FORGE_STATE_DIR=$PREFIX/etc/forge")
  check "bare command discovers it"    "$out" "CONSOLE root=$TREE"
fi

printf '\n──────────────────────────────\n'
if (( FAIL == 0 )); then printf '  %s%d passed%s   %s0 failed%s\n\n' "$C_G" "$PASS" "$C_0" "$C_G" "$C_0"
else printf '  %s%d passed%s   %s%d failed%s\n\n' "$C_G" "$PASS" "$C_0" "$C_R" "$FAIL" "$C_0"; fi
(( FAIL == 0 ))
