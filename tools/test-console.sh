#!/usr/bin/env bash
# test-console.sh — exercise the guided console (`forge-deploy` with no args)
# against a fake machine.
#
# The console's whole job is deciding what to say and what to offer, and that
# decision is driven entirely by docker and the registry. Both are stubbed here
# so every branch can be driven on a box with no docker daemon at all — which
# is the only way this gets tested before it reaches a client.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="${REPO_ROOT}/scripts/forge-deploy"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0; FAIL=0
C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_0=$'\033[0m'

# ── fake machine ─────────────────────────────────────────────
# Behaviour is driven by files in $SANDBOX/fake so each scenario can flip one
# condition without rewriting the stubs.
mkdir -p "$SANDBOX/bin" "$SANDBOX/fake" "$SANDBOX/tree" "$SANDBOX/state"

cat > "$SANDBOX/bin/docker" <<'FAKE'
#!/usr/bin/env bash
F="$FAKE_DIR"
case "$1" in
  info)
    [[ -f "$F/docker_missing" ]] && exit 1
    if [[ -f "$F/docker_denied" ]]; then echo "permission denied while trying to connect" >&2; exit 1; fi
    [[ -f "$F/docker_stopped" ]] && exit 1
    exit 0 ;;
  compose)
    shift
    [[ "$1" == "version" ]] && { [[ -f "$F/no_compose" ]] && exit 1; echo "v2.29.0"; exit 0; }
    # ... -f a -f b ps -q <svc>
    local_args=("$@")
    for ((i=0; i<${#local_args[@]}; i++)); do
      if [[ "${local_args[$i]}" == "logs" ]]; then
        svc="${local_args[-1]}"
        [[ -f "$F/logs_${svc}" ]] && cat "$F/logs_${svc}"
        exit 0
      fi
      if [[ "${local_args[$i]}" == "ps" ]]; then
        svc="${local_args[-1]}"
        [[ -f "$F/no_container_${svc}" ]] && exit 0
        echo "cid-${svc}"
        exit 0
      fi
    done
    exit 0 ;;
  images)
    [[ -f "$F/images" ]] && cat "$F/images"
    exit 0 ;;
  logs)
    [[ -f "$F/logs_${*: -1}" ]] && cat "$F/logs_${*: -1}"
    exit 0 ;;
  ps)
    [[ -f "$F/running_images" ]] && cat "$F/running_images"
    exit 0 ;;
  inspect)
    cid="${*: -1}"
    svc="${cid#cid-}"
    if [[ -f "$F/health_${svc}" ]]; then cat "$F/health_${svc}"; else echo healthy; fi
    exit 0 ;;
esac
exit 0
FAKE

cat > "$SANDBOX/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# Models the two things the real CLI must tell apart: curl failing outright
# (non-zero, no body) versus the registry answering, where the status IS the
# diagnosis. Callers passing -w '%{http_code}' get the code on its own trailing
# line exactly as curl does; callers that don't are unaffected.
F="$FAKE_DIR"
url=""; want_code=0; bearer=0
for a in "$@"; do
  case "$a" in
    https://*) url="$a";;
    *'%{http_code}'*) want_code=1;;
    'Authorization: Bearer faketoken') bearer=1;;
  esac
done
emit() { # <body> <status>
  printf '%s' "$1"
  [[ "$want_code" == 1 ]] && printf '\n%s' "$2"
  exit 0
}
case "$url" in
  *registry.npmjs.org*)
    [[ -f "$F/npm_down" ]] && exit 22
    emit "$(printf '{"version":"%s"}' "$(cat "$F/npm_latest" 2>/dev/null || echo 0.1.6)")" 200 ;;
  *ghcr.io/token*)
    [[ -f "$F/ghcr_down" ]] && exit 22
    # A plain registry:2 (demo and matrix boxes) serves no token endpoint.
    # Anonymous pull is expected there, so tags/list must still work.
    [[ -f "$F/no_token_endpoint" ]] && exit 22
    emit '{"token":"faketoken"}' 200 ;;
  *tags/list*)
    # curl itself fails: DNS, refused, timeout.
    [[ -f "$F/ghcr_down" ]] && exit 7
    [[ -f "$F/ghcr_denied" ]]   && emit '{"errors":[{"code":"UNAUTHORIZED"}]}' 403
    [[ -f "$F/ghcr_notfound" ]] && emit '{"errors":[{"code":"NAME_UNKNOWN"}]}' 404
    [[ -f "$F/ghcr_teapot" ]]   && emit '{"errors":[{"code":"WAT"}]}' 500
    # Published, nothing released yet — a legitimate 200 with no tags.
    [[ -f "$F/ghcr_empty" ]] && emit '{"tags":[]}' 200
    tags=$(cat "$F/ghcr_tags" 2>/dev/null || echo "1.0.0-beta.22 1.0.0-beta.25")
    body=$(printf '{"tags":['; sep=""
      for t in $tags; do printf '%s"%s"' "$sep" "$t"; sep=","; done
      printf ']}')
    emit "$body" 200 ;;
  *manifests/*)
    [[ -f "$F/digests" ]] || exit 22
    [[ "$bearer" == 1 || -f "$F/no_token_endpoint" ]] || exit 22
    d=$(awk -v t="${url##*/manifests/}" '$1==t{print $2}' "$F/digests")
    [[ "$want_code" == 1 ]] && { [[ -n "$d" ]] && printf 200 || printf 404; exit 0; }
    [[ -n "$d" ]] || exit 22
    printf 'HTTP/2 200\r\ndocker-content-digest: %s\r\n\r\n' "$d" ;;
  *) exit 22 ;;
esac
exit 0
FAKE
chmod +x "$SANDBOX/bin/docker" "$SANDBOX/bin/curl"

# jq is a hard dependency of the real CLI. If the host has no jq, fall back to
# a downloaded static build so this harness runs anywhere.
if command -v jq >/dev/null 2>&1; then
  ln -sf "$(command -v jq)" "$SANDBOX/bin/jq"
elif [[ -x "${FORGE_TEST_JQ:-}" ]]; then
  ln -sf "$FORGE_TEST_JQ" "$SANDBOX/bin/jq"
else
  echo "jq not found. Install it, or set FORGE_TEST_JQ=/path/to/jq" >&2
  exit 1
fi

# Nothing under test may escalate. A scenario that reaches for sudo is a bug,
# and this makes it fail loudly instead of prompting the person running tests.
printf '#!/usr/bin/env bash\necho "REFUSED: test tried to sudo: $*" >&2\nexit 1\n' > "$SANDBOX/bin/sudo"
chmod +x "$SANDBOX/bin/sudo"

# npx must never actually run during tests.
# Emulates `--fetch-only`: drops a runnable tree in place and stamps the newer
# installer version, which is what the console then re-enters.
cat > "$SANDBOX/bin/npx" <<NPX
#!/usr/bin/env bash
echo "[npx would run: \$*]"
target=""
for a in "\$@"; do case "\$a" in /*) target="\$a";; esac; done
if [[ -n "\$target" && -d "\$target" ]]; then
  mkdir -p "\$target/scripts"
  cp "${REPO_ROOT}/scripts/forge-deploy" "\$target/scripts/forge-deploy"
  chmod +x "\$target/scripts/forge-deploy"
  printf '0.2.0\n' > "\$target/.installer-version"
fi
exit 0
NPX
chmod +x "$SANDBOX/bin/npx"

# `env PATH=... bash` resolves bash through the PATH it just set, so the sandbox
# needs its own copy for any scenario that narrows CONSOLE_PATH to it.
ln -sf "$(command -v bash)" "$SANDBOX/bin/bash"

# The reachability doctor, stubbed: the console must offer and run it, and must
# survive the non-zero exit it uses to signal "found problems".
cat > "$SANDBOX/tree/doctor.sh" <<'DOC'
#!/usr/bin/env bash
echo "[doctor] checked reachability"
exit 1
DOC
chmod +x "$SANDBOX/tree/doctor.sh"

# Minimal tree the CLI insists on. docker-probe.sh is sourced before anything
# else runs, so the stub tree needs the real one.
mkdir -p "$SANDBOX/tree/scripts"
cp "$REPO_ROOT/scripts/docker-probe.sh" "$SANDBOX/tree/scripts/"

# Minimal tree the CLI insists on.
: > "$SANDBOX/tree/docker-compose.yml"
: > "$SANDBOX/tree/docker-compose.prod.yml"
cp "$REPO_ROOT/scripts/forge-deploy" "$SANDBOX/tree/forge-deploy-copy" 2>/dev/null || true

reset_fake() {
  rm -f "$SANDBOX/fake/"*
  cat > "$SANDBOX/tree/.env" <<ENV
SERVER_IMAGE_TAG=1.0.0-beta.22
UI_IMAGE_TAG=1.0.0-beta.22
FORGE_DEPLOY_SERVICES=api ui
ENABLE_SCHEMA_RECONCILE=true
ENV
  printf '{"box":{"role":"all"},"forge-api":{"current":"1.0.0-beta.22"},"forge-ui":{"current":"1.0.0-beta.22"}}' \
    > "$SANDBOX/state/deploy-state.json"
  : > "$SANDBOX/state/forge-deploy.log"
  printf '0.1.6\n' > "$SANDBOX/tree/.installer-version"
}

# CONSOLE_PATH lets a scenario narrow the console's PATH to the sandbox alone.
# Appending the real PATH is right for every other case, but it means a stub
# removed from $SANDBOX/bin is still found in /usr/bin — which is exactly how
# the jq scenario below passed on a developer box without jq and failed in CI
# with it.
_console_env() {
  printf 'PATH=%s FAKE_DIR=%s FORGE_DEPLOY_REPO=%s FORGE_STATE_DIR=%s FORGE_LOG_FILE=%s NO_COLOR=1' \
    "${CONSOLE_PATH:-$SANDBOX/bin:$PATH}" "$SANDBOX/fake" "$SANDBOX/tree" "$SANDBOX/state" "$SANDBOX/state/forge-deploy.log"
}

# Runs the console on a real pty, because the menu only appears on a terminal.
# `script` is the portable way to get one; input still arrives on stdin.
run_console() {
  local input="${1:-}"
  printf '%s\n' "$input" \
    | timeout 25 script -qec "env $(_console_env) bash '$CLI'" /dev/null 2>&1 \
    | tr -d '\r'
}

# Deliberately NOT a terminal — this is how cron or a piped invocation sees it.
run_console_piped() {
  printf '' | env \
    PATH="$SANDBOX/bin:$PATH" \
    FAKE_DIR="$SANDBOX/fake" \
    FORGE_DEPLOY_REPO="$SANDBOX/tree" \
    FORGE_STATE_DIR="$SANDBOX/state" \
    FORGE_LOG_FILE="$SANDBOX/state/forge-deploy.log" \
    NO_COLOR=1 \
    bash "$CLI" 2>&1
}

# FORGE_TEST_SHOW=1 prints every screen in full — the assertions say the words
# are present, only reading it says whether it is any good.
show() { [[ "${FORGE_TEST_SHOW:-0}" == "1" ]] && printf '%s\n' "$1" | sed 's/^/      │ /'; return 0; }

check() {
  local name="$1" out="$2" needle="$3"
  if grep -qF -- "$needle" <<<"$out"; then
    printf '  %s✓%s %s\n' "$C_G" "$C_0" "$name"; PASS=$((PASS+1))
  else
    printf '  %s✗%s %s\n      expected to find: %s\n' "$C_R" "$C_0" "$name" "$needle"; FAIL=$((FAIL+1))
    printf '%s\n' "$out" | sed 's/^/        | /' | head -30
  fi
}
check_not() {
  local name="$1" out="$2" needle="$3"
  if grep -qF -- "$needle" <<<"$out"; then
    printf '  %s✗%s %s\n      should NOT contain: %s\n' "$C_R" "$C_0" "$name" "$needle"; FAIL=$((FAIL+1))
  else
    printf '  %s✓%s %s\n' "$C_G" "$C_0" "$name"; PASS=$((PASS+1))
  fi
}

scenario() { printf '\n%s%s%s\n' "$C_Y" "$1" "$C_0"; reset_fake; }

# menu_number <rendered-menu> <label fragment> -> the option's number.
# Adding an entry shifts everything below it, so scenarios name the option they
# want rather than counting lines that move under them.
menu_number() {
  sed -n "s/^[[:space:]]*\([0-9]\{1,\}\)[[:space:]].*$2.*/\1/p" <<<"$1" | head -1
}

run_cli() {
  local input="$1"; shift
  printf '%s\n' "$input" | env \
    PATH="$SANDBOX/bin:$PATH" \
    FAKE_DIR="$SANDBOX/fake" \
    FORGE_DEPLOY_REPO="$SANDBOX/tree" \
    FORGE_STATE_DIR="$SANDBOX/state" \
    FORGE_LOG_FILE="$SANDBOX/state/forge-deploy.log" \
    NO_COLOR=1 \
    timeout 25 bash "$CLI" "$@" 2>&1
}

picker_fixture() {
  printf '1.0.0-beta.9 1.0.0-beta.25 main-aaaa111 1.0.0-beta.22 main-bbbb222 1.0.0-beta.3 1.0.0-beta.10\n' \
    > "$SANDBOX/fake/ghcr_tags"
  cat > "$SANDBOX/fake/digests" <<'DIG'
1.0.0-beta.25 sha256:a25
main-aaaa111 sha256:a25
1.0.0-beta.22 sha256:b22
main-bbbb222 sha256:b22
1.0.0-beta.10 sha256:d10
1.0.0-beta.9 sha256:c09
DIG
}

# ── scenarios ────────────────────────────────────────────────

scenario "jq missing — cannot misread a configured box as unconfigured"
rm -f "$SANDBOX/bin/jq"
# The sandbox alone: reaching the helper check needs no external program, and
# anything inherited from the system PATH would put jq back.
OUT=$(CONSOLE_PATH="$SANDBOX/bin" run_console "1")
check "names the missing program" "$OUT" "missing a small program the Forge tooling needs: jq"
check "gives an install command"  "$OUT" "sudo apt install -y jq"
check_not "does not claim no role" "$OUT" "has not been told what it should run"
check_not "does not offer setup"   "$OUT" "Finish setting this machine up"
if command -v jq >/dev/null 2>&1; then ln -sf "$(command -v jq)" "$SANDBOX/bin/jq"; else ln -sf "$FORGE_TEST_JQ" "$SANDBOX/bin/jq"; fi

scenario "Docker not running"
touch "$SANDBOX/fake/docker_stopped"
OUT=$(run_console "2")
check "explains the problem in plain language" "$OUT" "Docker is installed but is not running."
check "offers to fix it"                       "$OUT" "fix what can be fixed"
check_not "does not leak a flag"               "$OUT" "--recover"

scenario "Docker permission denied"
touch "$SANDBOX/fake/docker_denied"
OUT=$(run_console "2")
check "names the real cause" "$OUT" "This account is not allowed to use Docker."

scenario "Compose plugin missing"
touch "$SANDBOX/fake/no_compose"
OUT=$(run_console "2")
check "names the missing plugin" "$OUT" "The Docker Compose plugin is missing."

scenario "Not set up yet"
rm -f "$SANDBOX/tree/.env"
OUT=$(run_console "2")
check "says it is not set up" "$OUT" "Forge has not been set up on this machine yet."

scenario "Installed but no role chosen — offers setup, does not launch it"
printf '{"forge-api":{"current":"1.0.0-beta.22"}}' > "$SANDBOX/state/deploy-state.json"
OUT=$(run_console "2")
check "explains the state"   "$OUT" "has not been told what it should run"
check "offers to finish"     "$OUT" "Finish setting this machine up"
check "quitting is safe"     "$OUT" "Nothing was changed."
check_not "wizard not run"   "$OUT" "topology setup"

scenario "Healthy and up to date"
printf '1.0.0-beta.22\n' > "$SANDBOX/fake/ghcr_tags"
OUT=$(run_console "3")
show "$OUT"
check "confirms it is current"       "$OUT" "Forge is up to date"
check "shows friendly names"         "$OUT" "Forge application"
check "shows health"                 "$OUT" "healthy"
check_not "does not offer an upgrade" "$OUT" "Upgrade Forge to"

scenario "Behind — upgrade is the recommendation"
OUT=$(run_console "4")
check "announces the newer release" "$OUT" "A newer Forge release is available"
check "names the version"           "$OUT" "1.0.0-beta.25"
check "offers the upgrade"          "$OUT" "Upgrade Forge to 1.0.0-beta.25"
check "recommends it"               "$OUT" "1.0.0-beta.25   (recommended)"

scenario "Tool update available — presented first, not forced"
printf '0.2.0\n' > "$SANDBOX/fake/npm_latest"
OUT=$(run_console "5")
show "$OUT"
check "announces the tool update"   "$OUT" "A newer version of this tool is available"
check "shows both versions"         "$OUT" "0.1.6 → 0.2.0"
check "is the first option"         "$OUT" "1  Update this tool first"
check "carries the recommendation"  "$OUT" "come straight back here   (recommended)"
check "upgrade is still offered"    "$OUT" "Upgrade Forge to 1.0.0-beta.25"

scenario "Tool is current — no update offered"
printf '0.1.6\n' > "$SANDBOX/fake/npm_latest"
OUT=$(run_console "4")
check_not "no tool update line" "$OUT" "A newer version of this tool"

scenario "A container is unhealthy"
printf 'unhealthy\n' > "$SANDBOX/fake/health_forge-api"
OUT=$(run_console "5")
check "counts the unhealthy parts" "$OUT" "are not healthy"
check "offers repair"              "$OUT" "Look at what is unhealthy"

scenario "Registry unreachable"
touch "$SANDBOX/fake/ghcr_down"
OUT=$(run_console "3")
check "says so without crashing" "$OUT" "cannot tell if you are up to date"
check "still offers the menu"    "$OUT" "Quit"

# The four ways "no tags came back" used to look identical. Each has a
# different fix, so each has to say something different.
scenario "Plain registry:2 with no token endpoint — anonymous still works"
touch "$SANDBOX/fake/no_token_endpoint"
OUT=$(run_console "3")
check "reads tags anonymously"          "$OUT" "A newer Forge release is available"
check "and resolves the newest one"     "$OUT" "1.0.0-beta.25"
check_not "does not claim it is denied" "$OUT" "read:packages"
check_not "does not claim unreachable"  "$OUT" "registry is unreachable"

scenario "Registry denies the token — not reported as a missing release"
touch "$SANDBOX/fake/ghcr_denied"
OUT=$(run_console "3")
check "names the real cause"          "$OUT" "no read:packages"
check "gives the fix"                 "$OUT" "docker login ghcr.io"
check_not "does not blame the network" "$OUT" "registry is unreachable"

scenario "Package is not in this registry"
touch "$SANDBOX/fake/ghcr_notfound"
OUT=$(run_console "3")
check "says it is not there"           "$OUT" "does not exist in this registry"
check_not "does not blame the network" "$OUT" "registry is unreachable"

scenario "Published, but nothing released yet"
touch "$SANDBOX/fake/ghcr_empty"
OUT=$(run_console "3")
check "says nothing is released"       "$OUT" "has no released versions yet"
check_not "does not blame permissions" "$OUT" "read:packages"
check_not "does not blame the network" "$OUT" "registry is unreachable"

scenario "Registry answers with something unexpected"
touch "$SANDBOX/fake/ghcr_teapot"
OUT=$(run_console "3")
check "says the answer was unexpected" "$OUT" "unexpected answer"
check "still offers the menu"          "$OUT" "Quit"

scenario "npm registry unreachable — degrades quietly"
touch "$SANDBOX/fake/npm_down"
OUT=$(run_console "4")
check_not "no tool update offered" "$OUT" "A newer version of this tool"
check "console still works"        "$OUT" "A newer Forge release is available"

scenario "Not a terminal — prints guidance, never hangs"
OUT=$(run_console_piped)
check "explains it needs a terminal" "$OUT" "needs a terminal"
check "gives the non-interactive route" "$OUT" "forge-deploy --update"

scenario "Upgrade — explains itself and cancels safely on empty input"
OUT=$(run_console "1")
show "$OUT"
check "names the target"        "$OUT" "Upgrading Forge to 1.0.0-beta.25"
check "says it backs up first"  "$OUT" "back up your database first"
check "warns about downtime"    "$OUT" "unavailable for roughly 3 to 10 minutes"
check "asks for a typed word"   "$OUT" "YES to continue"
check "cancelling is safe"      "$OUT" "Nothing was changed."
check_not "did not deploy"      "$OUT" "Deploying api"

scenario "Tool update — applies, reopens, and does not loop"
printf '0.2.0\n' > "$SANDBOX/fake/npm_latest"
OUT=$(run_console "1")
show "$OUT"
check "runs the installer"      "$OUT" "@armoryworks/forge-deploy@latest"
check "reopens the console"     "$OUT" "Reopening"
check "second pass is clean"    "$OUT" "This machine is ready."
check_not "does not loop"       "$OUT" "Updating the Forge tool\n  ────"

scenario "The reachability doctor is reachable from the one command"
OUT=$(run_console "")
check "offers it in the menu"       "$OUT" "cannot reach it"

scenario "Choosing it runs the doctor and survives its non-zero exit"
# The entry's number moves with what else the box needs, so it is read off the
# rendered menu rather than hardcoded.
DOCTOR_CHOICE=$(sed -n 's/^[[:space:]]*\([0-9]\{1,\}\)[[:space:]].*cannot reach it.*/\1/p' <<<"$OUT" | head -1)
if [[ -z "$DOCTOR_CHOICE" ]]; then
  printf '  %s✗%s could not find the doctor entry in the menu\n' "$C_R" "$C_0"; FAIL=$((FAIL+1))
else
  OUT=$(run_console "$DOCTOR_CHOICE")
  check "says it changes nothing"     "$OUT" "changes nothing"
  check "runs the doctor"             "$OUT" "checked reachability"
  check "reports what it found"       "$OUT" "found problems"
  check_not "the console did not die" "$OUT" "unbound variable"
fi

scenario "Superseded images are offered as a plain menu choice"
printf '{"forge-api":{"current":"1.0.0-beta.25","prior":"1.0.0-beta.24"},"box":{"role":"all"}}' \
  > "$SANDBOX/state/deploy-state.json"
printf 'ghcr.io/armoryworks/forge-api:1.0.0-beta.25\n' > "$SANDBOX/fake/running_images"
cat > "$SANDBOX/fake/images" <<'IMG'
ghcr.io/armoryworks/forge-api:1.0.0-beta.25
ghcr.io/armoryworks/forge-api:1.0.0-beta.24
ghcr.io/armoryworks/forge-api:1.0.0-beta.20
ghcr.io/armoryworks/forge-api:1.0.0-beta.2
ghcr.io/armoryworks/forge-ui:1.0.0-beta.19
IMG
OUT=$(run_console "")
check "offers the cleanup"       "$OUT" "Free up disk"
# beta.25 is running and beta.24 is the rollback target, so three of the five go.
check "counts only the stale"    "$OUT" "remove 3 superseded"
check_not "not recommended"      "$OUT" "Free up disk — remove 3 superseded Forge image(s)   (recommended)"

scenario "A box with no recorded versions refuses to prune"
printf '{"box":{"role":"all"}}' > "$SANDBOX/state/deploy-state.json"
OUT=$(run_console "")
check_not "no cleanup offered"   "$OUT" "Free up disk"

scenario "Version picker lists every published release, newest first"
picker_fixture
OUT=$(run_cli "q" --pick)
show "$OUT"
check_not "finds the published versions" "$OUT" "no published versions found"
check_not "sort does not fail"           "$OUT" "multi-character tab"
ORDER=$(sed -n 's/.*\[[0-9]\{1,\}\] \{1,\}\([^ ]\{1,\}\).*/\1/p' <<<"$OUT" | head -5 | tr '\n' ' ')
check "newest first, version-aware" "$ORDER" "1.0.0-beta.25 1.0.0-beta.22 1.0.0-beta.10 1.0.0-beta.9 1.0.0-beta.3 "
check "pairs a release with its build"  "$OUT" "[1] 1.0.0-beta.25 (main-aaaa111)"
check "marks the running release"       "$OUT" "[2] 1.0.0-beta.22 (main-bbbb222)  « current"
check "says when no build matches"      "$OUT" "[4] 1.0.0-beta.9 (no matching build hash)"
check "keeps a release with no digest"  "$OUT" "[5] 1.0.0-beta.3"
check_not "no bare question mark"       "$OUT" "(?)"
check "quitting changes nothing"        "$OUT" "Stopped — no further changes."

scenario "The --list view resolves build hashes too"
picker_fixture
OUT=$(run_cli "" --list)
show "$OUT"
check "pairs the newest release"   "$OUT" "1.0.0-beta.25  (main-aaaa111)"
check_not "every hash resolved for paired releases" "$OUT" "1.0.0-beta.22  (build hash unresolved)"

scenario "A failed health gate shows why before it rolls back"
picker_fixture
printf 'unhealthy\n' > "$SANDBOX/fake/health_forge-ui"
printf 'nginx: [emerg] host not found in upstream "forge-api"\nDB_PASSWORD=hunter2\n' > "$SANDBOX/fake/logs_forge-ui"
OUT=$(HEALTHCHECK_TIMEOUT_SECS=2 run_cli "" 1.0.0-beta.25 --service ui)
show "$OUT"
check "reports the failed gate"      "$OUT" "Service did not become healthy"
check "prints the container log"     "$OUT" 'host not found in upstream "forge-api"'
check_not "redacts credentials"      "$OUT" "hunter2"
check "still rolls back"             "$OUT" "Rolling back to 1.0.0-beta.22"
CAUSE_AT=$(grep -n 'host not found in upstream' <<<"$OUT" | head -1 | cut -d: -f1)
ROLLBACK_AT=$(grep -n 'Rolling back to' <<<"$OUT" | head -1 | cut -d: -f1)
if [[ -n "$CAUSE_AT" && -n "$ROLLBACK_AT" ]] && (( CAUSE_AT < ROLLBACK_AT )); then
  printf '  %s✓%s %s\n' "$C_G" "$C_0" "the cause comes before the rollback"; PASS=$((PASS+1))
else
  printf '  %s✗%s %s\n' "$C_R" "$C_0" "the cause comes before the rollback"; FAIL=$((FAIL+1))
fi

scenario "--version and --status name the tooling in one line"
OUT=$(run_cli "" --version)
check "names package and tree" "$OUT" "Deploy tooling: 0.1.6 (tree v"
LINES=$(grep -c . <<<"$OUT")
if [[ "$LINES" == 1 ]]; then
  printf '  %s✓%s %s\n' "$C_G" "$C_0" "--version is a single line"; PASS=$((PASS+1))
else
  printf '  %s✗%s %s (%s lines)\n' "$C_R" "$C_0" "--version is a single line" "$LINES"; FAIL=$((FAIL+1))
fi
OUT=$(run_cli "" --status)
check "--status carries the same line" "$OUT" "Deploy tooling: 0.1.6 (tree v"

scenario "--support-bundle writes one archive and says where"
printf 'api started\nJwt__Key=supersecretvalue\n' > "$SANDBOX/fake/logs_forge-api"
printf 'ui started\n' > "$SANDBOX/fake/logs_forge-ui"
printf 'database system is ready\n' > "$SANDBOX/fake/logs_forge"
mkdir -p "$SANDBOX/bundle"
OUT=$(cd "$SANDBOX/bundle" && run_cli "" --support-bundle)
show "$OUT"
ARCHIVE=$(grep -oE "$SANDBOX/bundle/forge-support-[0-9TZ]+\.tar\.gz" <<<"$OUT" | head -1)
if [[ -n "$ARCHIVE" && -f "$ARCHIVE" ]]; then
  printf '  %s✓%s %s\n' "$C_G" "$C_0" "prints the path of an archive that exists"; PASS=$((PASS+1))
  LISTING=$(tar -tzf "$ARCHIVE")
  for f in forge-api.log forge-ui.log forge-db.log doctor.txt version.txt status.txt; do
    check "contains $f" "$LISTING" "/$f"
  done
  UNPACK="$SANDBOX/bundle/unpacked"; mkdir -p "$UNPACK"; tar -xzf "$ARCHIVE" -C "$UNPACK"
  check "api log is in it"          "$(cat "$UNPACK"/*/forge-api.log)" "api started"
  check "db log is in it"           "$(cat "$UNPACK"/*/forge-db.log)" "database system is ready"
  check "doctor output is in it"    "$(cat "$UNPACK"/*/doctor.txt)" "checked reachability"
  check "version line is in it"     "$(cat "$UNPACK"/*/version.txt)" "Deploy tooling:"
  check_not "credentials redacted"  "$(cat "$UNPACK"/*/forge-api.log)" "supersecretvalue"
else
  printf '  %s✗%s %s\n' "$C_R" "$C_0" "prints the path of an archive that exists"; FAIL=$((FAIL+1))
  printf '%s\n' "$OUT" | sed 's/^/        | /' | head -30
fi

reset_fake
scenario "Starting over is offered, but never recommended"
OUT=$(run_console "")
check "offers a clean slate"     "$OUT" "Start over"
check "says what it does"        "$OUT" "erase everything on this box"
check_not "never recommended"    "$OUT" "set it up fresh   (recommended)"

scenario "Quit changes nothing"
OUT=$(run_console "$(menu_number "$(run_console "")" "Quit")")
check "says nothing changed" "$OUT" "Nothing was changed."

printf '\n──────────────────────────────\n'
printf '  %s%d passed%s   %s%d failed%s\n\n' "$C_G" "$PASS" "$C_0" \
  "$( ((FAIL)) && printf '%s' "$C_R" || printf '%s' "$C_G")" "$FAIL" "$C_0"
(( FAIL == 0 ))
