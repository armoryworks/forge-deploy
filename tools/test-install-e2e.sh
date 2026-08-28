#!/usr/bin/env bash
# test-install-e2e.sh — the first-install sequence, end to end, on a clean box.
#
# Every bug that reached an operator on 2026-08-28 lived between "npx" and "a
# stack you can manage": a notice that blocked, a CLI that was never installed,
# a Docker permission error diagnosed as a stopped daemon, instructions naming
# a directory the operator was not in, and a half-finished tree the documented
# command refused to resume. The console and discovery suites tested neither
# end of that. This does.
#
# A throwaway container per scenario, `docker` stubbed inside it so the sequence
# can be driven without a daemon-in-a-daemon, and the deploy tree fetched from
# the branch under test.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${FORGE_E2E_IMAGE:-node:20-bookworm-slim}"
REF="${FORGE_DEPLOY_REF:-heads/main}"

PASS=0; FAIL=0
C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_0=$'\033[0m'
scenario() { printf '\n%s%s%s\n' "$C_Y" "$1" "$C_0"; }
check()  { if [[ "$2" == *"$3"* ]]; then printf '  %s✓%s %s\n' "$C_G" "$C_0" "$1"; PASS=$((PASS+1));
           else printf '  %s✗%s %s\n      wanted: %s\n' "$C_R" "$C_0" "$1" "$3"; FAIL=$((FAIL+1)); fi; }
refute() { if [[ "$2" != *"$3"* ]]; then printf '  %s✓%s %s\n' "$C_G" "$C_0" "$1"; PASS=$((PASS+1));
           else printf '  %s✗%s %s\n      unwanted: %s\n' "$C_R" "$C_0" "$1" "$3"; FAIL=$((FAIL+1)); fi; }

DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
  if command -v sg >/dev/null 2>&1 && sg docker -c 'docker info' >/dev/null 2>&1; then
    DOCKER="sg docker -c docker"      # placeholder; real invocation below
  else
    printf '\n%s—%s skipped: this machine cannot run containers (no reachable Docker)\n\n' "$C_Y" "$C_0"
    exit 0
  fi
fi

# Runs a script inside a throwaway container. `sg` needs the whole command as
# one string, so the argv is assembled rather than interpolated ad hoc.
in_container() {
  local script="$1"
  local -a cmd=(docker run --rm -i
    -v "${REPO_ROOT}:/repo:ro"
    -e "FORGE_DEPLOY_REF=${REF}"
    -e DEBIAN_FRONTEND=noninteractive
    "$IMAGE" bash -s)
  if [[ "$DOCKER" == docker ]]; then
    printf '%s' "$script" | timeout 600 "${cmd[@]}" 2>&1
  else
    printf '%s' "$script" | timeout 600 sg docker -c "$(printf '%q ' "${cmd[@]}")" 2>&1
  fi
}

# Common preamble: deps, an unprivileged operator with passwordless sudo, and a
# docker stub whose behaviour the scenario picks.
preamble() {
  cat <<'PRE'
set -u
apt-get update -qq >/dev/null 2>&1
# git is a setup.sh prerequisite; without it setup bails before the Docker
# check and every Docker assertion below silently tests nothing.
apt-get install -y -qq curl tar sudo git >/dev/null 2>&1
useradd -m -s /bin/bash op
echo 'op ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/op
PRE
}

# $1: what `docker info` should do
docker_stub() {
  cat <<PRE
cat > /usr/local/bin/docker <<'STUB'
#!/usr/bin/env bash
case "\$1" in
  info) ${1} ;;
  compose) [[ "\$2" == version ]] && { echo "Docker Compose version v2.29.0"; exit 0; }; exit 0 ;;
  --version) echo "Docker version 27.0.0"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x /usr/local/bin/docker
PRE
}

INSTALL='sudo -u op env HOME=/home/op node /repo/bin/install.mjs /home/op/forge-deploy </dev/null'

scenario "First install on a box where Docker is not installed"
out=$(in_container "$(preamble)
$INSTALL")
check "fetches the tree"                "$out" "Fetching forge-deploy"
check "tries to install the CLI"        "$out" "Installing the forge-deploy CLI"
check "diagnoses Docker as missing"     "$out" "Docker"
refute "never blocks on a notice"       "$out" "Press Enter to continue anyway"
refute "never calls itself unsupported" "$out" "no longer the documented path"

scenario "First install where the daemon is up but this account cannot use it"
out=$(in_container "$(preamble)
$(docker_stub 'echo "permission denied while trying to connect to the Docker API at unix:///var/run/docker.sock" >&2; exit 1')
$INSTALL")
check "names the real problem"          "$out" "cannot access it"
check "gives the group fix"             "$out" "usermod -aG docker"
refute "does NOT blame the daemon"      "$out" "daemon is not running"
refute "does not send them to systemctl" "$out" "systemctl start docker"

scenario "First install where the daemon really is stopped"
out=$(in_container "$(preamble)
$(docker_stub 'echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock." >&2; exit 1')
$INSTALL")
check "says the daemon is not running"  "$out" "daemon is not running"
check "tells them how to start it"      "$out" "systemctl start docker"
refute "does not blame permissions"     "$out" "cannot access it"

scenario "What a failed first install leaves behind is usable"
out=$(in_container "$(preamble)
$(docker_stub 'echo "Cannot connect to the Docker daemon." >&2; exit 1')
$INSTALL
echo '--- ARTEFACTS ---'
echo \"wrapper: \$(cat /usr/local/bin/forge-deploy 2>/dev/null | tr '\n' ' ')\"
echo \"state:   \$(cat /etc/forge/deploy-state.json 2>/dev/null | tr -d '[:space:]')\"")
check "installs the CLI on PATH"        "$out" "/usr/local/bin/forge-deploy"
check "wrapper names the real tree"     "$out" "FORGE_DEPLOY_REPO:-/home/op/forge-deploy"
check "records the root for lookup"     "$out" '"repoRoot":"/home/op/forge-deploy"'

scenario "Every instruction it prints names its directory"
out=$(in_container "$(preamble)
$(docker_stub 'echo "Cannot connect to the Docker daemon." >&2; exit 1')
$INSTALL")
check "re-run instruction has the path" "$out" "cd /home/op/forge-deploy && ./setup.sh"
refute "no bare ./setup.sh anywhere"    "$out" "  ./setup.sh"

scenario "The documented command resumes the tree it left behind"
out=$(in_container "$(preamble)
$(docker_stub 'echo "Cannot connect to the Docker daemon." >&2; exit 1')
$INSTALL
echo '--- SECOND RUN, FROM HOME ---'
cd /home/op && sudo -u op env HOME=/home/op node /repo/bin/install.mjs </dev/null")
check "resumes in place"                "$out" "Resuming setup in /home/op/forge-deploy"
refute "does not install a second copy" "$out" "into /home/op/forge-deploy/forge-deploy"
refute "never says it cannot find it"   "$out" "is not in any of the"

printf '\n──────────────────────────────\n'
if (( FAIL == 0 )); then printf '  %s%d passed%s   %s0 failed%s\n\n' "$C_G" "$PASS" "$C_0" "$C_G" "$C_0"
else printf '  %s%d passed%s   %s%d failed%s\n\n' "$C_G" "$PASS" "$C_0" "$C_R" "$FAIL" "$C_0"; fi
(( FAIL == 0 ))
