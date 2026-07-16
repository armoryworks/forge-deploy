#!/usr/bin/env bash
# tools/test-recovery-doctor.sh — isolated scenario tests for the forge-deploy
# recovery doctor (--recover / --fresh-start plumbing).
#
# Deliberately breaks a sandboxed install in a number of ways and asserts the
# doctor detects the state, heals what it can, and dead-ends politely on what
# it can't. Everything runs against a throwaway sandbox repo + shimmed
# docker/sudo/systemctl/gh — the real stack, /etc/forge, and the real .env are
# never touched.
#
# Usage:
#   bash tools/test-recovery-doctor.sh                 # all scenarios, gh shimmed (no network writes)
#   bash tools/test-recovery-doctor.sh --file-issues   # ALSO files two REAL GitHub issues titled
#                                                      # "Automated Test Result -- IGNORE/DELETE: ..."
#                                                      # (requires a gh login; delete them afterward)
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/forge-recovery-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

FILE_ISSUES=false
[[ "${1:-}" == "--file-issues" ]] && FILE_ISSUES=true

PASS=0; FAIL=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; (( PASS++ )); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; (( FAIL++ )); }
assert_contains() { # assert_contains <label> <haystack> <needle>
  if grep -qiF -- "$3" <<<"$2"; then pass "$1"; else fail "$1 — expected to find: $3"; printf '%s\n' "$2" | sed 's/^/       | /' | head -12; fi
}
assert_not_contains() {
  if grep -qiF -- "$3" <<<"$2"; then fail "$1 — should NOT contain: $3"; else pass "$1"; fi
}

# ── Library: the CLI's functions without its main dispatch ──────────────────
LIB="$WORK/fd-lib.sh"
sed '$ d' "$ROOT/scripts/forge-deploy" > "$LIB"

# ── Sandbox repo factory ─────────────────────────────────────────────────────
new_sandbox() { # new_sandbox <name> -> echoes path
  local sb="$WORK/$1"
  mkdir -p "$sb/scripts"
  cp "$ROOT/docker-compose.yml" "$ROOT/docker-compose.prod.yml" "$sb/"
  # Synthetic env template: enough keys to exercise merge/jwt/pin detection.
  cat > "$sb/.env.example" <<'EOT'
JWT_KEY=dev-secret-key-change-in-production-min-32-chars!!
SERVER_IMAGE_TAG=1.0.0
UI_IMAGE_TAG=1.0.0
API_PORT=5000
UI_PORT=4200
BRAND_NEW_SETTING=defaultval
EOT
  # Stub bootstrapper: records that it ran, exits per SETUP_STUB_RC.
  cat > "$sb/setup.sh" <<'EOT'
#!/usr/bin/env bash
echo "STUB-SETUP ran (FORGE_DEPLOY_CALLER=${FORGE_DEPLOY_CALLER:-unset})" >> "${SETUP_STUB_LOG:-/dev/null}"
exit "${SETUP_STUB_RC:-0}"
EOT
  chmod +x "$sb/setup.sh"
  printf '%s' "$sb"
}

# ── Command shims ────────────────────────────────────────────────────────────
SHIMS="$WORK/shims"
mkdir -p "$SHIMS"
CALLS="$WORK/calls.log"; : > "$CALLS"

cat > "$SHIMS/docker" <<'EOT'
#!/usr/bin/env bash
# Modes via DOCKER_SHIM_MODE: ok | down | snap | apilooping | apiunknownlogs | apidbauth
mode="${DOCKER_SHIM_MODE:-ok}"
echo "docker $*" >> "${SHIM_CALLS:-/dev/null}"
case "$1" in
  --version) echo "Docker version 27.0.0-shim"; exit 0 ;;
  compose)   [[ "$2" == "version" ]] && { echo "Docker Compose version v2-shim"; exit 0; }
             echo "compose-shim: $*"; exit 0 ;;
  info)
    [[ "$mode" == "down" ]] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
    if [[ "${2:-}" == "--format" ]]; then
      case "$3" in
        *DockerRootDir*CgroupVersion*) # combined diagnostics format
          if [[ "$mode" == snap ]]; then echo "root=/var/snap/docker/common  cgroup=2/systemd  storage=overlay2  arch=x86_64"
          else echo "root=/var/lib/docker  cgroup=2/systemd  storage=overlay2  arch=x86_64"; fi ;;
        *DockerRootDir*) if [[ "$mode" == snap ]]; then echo "/var/snap/docker/common"; else echo "/var/lib/docker"; fi ;;
        *CgroupVersion*) echo "2" ;;
        *CgroupDriver*)  echo "systemd" ;;
        *) echo "" ;;
      esac
    fi
    exit 0 ;;
  inspect)
    # docker inspect --format '{{.State.Status}}' <name>
    name="${*: -1}"
    if [[ "$mode" == "apilooping" && "$name" == "forge-api" ]]; then echo "restarting"; exit 0; fi
    case "$name" in forge|forge-storage|forge-backup|forge-api|forge-ui) echo "running"; exit 0 ;; esac
    exit 1 ;;
  logs)
    case "$mode" in
      apidbauth)      echo "FATAL: password authentication failed for user \"postgres\"" ;;
      apiunknownlogs) echo "Unhandled exception: System.MysteryException: flux capacitor drift at Warp.Core.Nacelle(): line 42" ;;
      *)              echo "info: all quiet" ;;
    esac
    exit 0 ;;
  ps) echo "NAMES  IMAGE  STATUS"; exit 0 ;;
  rm|volume) exit 0 ;;
  *) exit 0 ;;
esac
EOT

cat > "$SHIMS/sudo" <<'EOT'
#!/usr/bin/env bash
echo "sudo $*" >> "${SHIM_CALLS:-/dev/null}"
exit 0
EOT

cat > "$SHIMS/systemctl" <<'EOT'
#!/usr/bin/env bash
echo "systemctl $*" >> "${SHIM_CALLS:-/dev/null}"
exit 0
EOT

cat > "$SHIMS/gh" <<'EOT'
#!/usr/bin/env bash
echo "gh $*" >> "${SHIM_CALLS:-/dev/null}"
case "$1" in
  auth)  exit 0 ;;
  issue) # capture the body for assertions
         while [[ $# -gt 0 ]]; do [[ "$1" == "--body" ]] && printf '%s' "$2" > "${GH_BODY_CAPTURE:-/dev/null}"; shift; done
         echo "https://github.com/armoryworks/forge-deploy/issues/0"; exit 0 ;;
  *) exit 0 ;;
esac
EOT
chmod +x "$SHIMS"/*

# Run a snippet with the lib sourced, shims first in PATH, sandbox as repo.
# in_sandbox <sandbox> <docker-mode> <snippet> [stdin]
in_sandbox() {
  local sb="$1" dmode="$2" snippet="$3"
  FORGE_DEPLOY_REPO="$sb" DOCKER_SHIM_MODE="$dmode" SHIM_CALLS="$CALLS" \
    GH_BODY_CAPTURE="$WORK/ghbody.md" SETUP_STUB_LOG="$WORK/setup-stub.log" \
    PATH="$SHIMS:$PATH" bash -c "source '$LIB'; set +e; $snippet" 2>&1
}
# Same, but under a pty so [[ -t 0 ]] is true and prompts fire; feeds $4 as keys.
# The snippet goes through a temp file to dodge nested-quoting through script(1).
in_sandbox_tty() {
  local sb="$1" dmode="$2" snippet="$3" keys="$4" snipfile="$WORK/snippet.sh"
  { printf 'source "%s"; set +e\n' "$LIB"; printf '%s\n' "$snippet"; } > "$snipfile"
  printf '%b' "$keys" | FORGE_DEPLOY_REPO="$sb" DOCKER_SHIM_MODE="$dmode" SHIM_CALLS="$CALLS" \
    GH_BODY_CAPTURE="$WORK/ghbody.md" SETUP_STUB_LOG="$WORK/setup-stub.log" \
    PATH="$SHIMS:$PATH" script -qec "bash '$snipfile'" /dev/null 2>&1
}

echo "== forge-deploy recovery doctor — scenario tests =="
echo "   sandbox: $WORK"

# ── S1: Docker not installed at all ──────────────────────────────────────────
echo "S1: docker missing entirely"
FARM="$WORK/farm"; mkdir -p "$FARM"
for c in bash sh grep awk sed sort head tail cut tr cat printf mktemp id uname jq curl env dirname basename wc ls rm cp mv chmod mkdir date; do
  p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$FARM/$c"
done
SB=$(new_sandbox s1)
OUT=$(FORGE_DEPLOY_REPO="$SB" PATH="$FARM" bash -c "source '$LIB'; set +e; bootstrap_scan; printf 'FATALS:%s\n' \"\${SCAN_FATAL[*]:-}\"" 2>&1)
assert_contains "detects missing docker" "$OUT" "Docker is not installed"
assert_contains "points at README Step 0" "$OUT" "Step 0"

# ── S2: daemon installed but not running → daemon heal via systemctl ─────────
echo "S2: docker daemon down"
SB=$(new_sandbox s2)
OUT=$(in_sandbox "$SB" down 'bootstrap_scan; printf "HEALS:%s\n" "${SCAN_HEAL[*]:-}"')
assert_contains "flags daemon heal" "$OUT" "HEALS:daemon"
: > "$CALLS"
in_sandbox "$SB" down 'apply_heal daemon' >/dev/null
assert_contains "heal starts docker via systemctl" "$(cat "$CALLS")" "sudo systemctl start docker"

# ── S3: snap-packaged docker on cgroup v2 → fatal, plain-language ────────────
echo "S3: snap docker on cgroup v2"
SB=$(new_sandbox s3)
OUT=$(in_sandbox "$SB" snap 'bootstrap_scan')
assert_contains "identifies snap packaging" "$OUT" "snap-packaged Docker"
assert_contains "gives the apt replacement" "$OUT" "apt install -y docker.io"

# ── S4: half-deleted repo → fatal re-clone guidance ──────────────────────────
echo "S4: incomplete deploy repo"
SB=$(new_sandbox s4); rm -f "$SB/docker-compose.prod.yml"
OUT=$(in_sandbox "$SB" ok 'bootstrap_scan')
assert_contains "detects incomplete repo" "$OUT" "incomplete"
assert_contains "suggests re-clone" "$OUT" "git clone"

# ── S5: never bootstrapped (.env absent) → bootstrap heal → runs setup.sh ────
echo "S5: no .env — first-time bootstrap path"
SB=$(new_sandbox s5)
OUT=$(in_sandbox "$SB" ok 'bootstrap_scan; printf "HEALS:%s\n" "${SCAN_HEAL[*]:-}"')
assert_contains "flags bootstrap heal" "$OUT" "bootstrap"
: > "$WORK/setup-stub.log"
in_sandbox "$SB" ok 'run_bootstrap' </dev/null >/dev/null
assert_contains "bootstrap delegates to setup.sh with caller flag" "$(cat "$WORK/setup-stub.log")" "FORGE_DEPLOY_CALLER=1"

# ── S6: mangled .env (placeholder JWT, latest tag, missing keys) ─────────────
echo "S6: half-written .env — resume heals in place"
SB=$(new_sandbox s6)
printf 'JWT_KEY=dev-secret-key-change-in-production-min-32-chars!!\nSERVER_IMAGE_TAG=latest\nUI_IMAGE_TAG=1.2.3\n' > "$SB/.env"
OUT=$(in_sandbox "$SB" ok 'bootstrap_scan; printf "HEALS:%s\n" "${SCAN_HEAL[*]:-}"')
assert_contains "flags placeholder JWT" "$OUT" "jwt"
assert_contains "flags missing settings" "$OUT" "envmerge"
assert_contains "flags floating latest tag" "$OUT" "pin:api"
assert_not_contains "valid ui pin left alone" "$OUT" "pin:ui"
OUT=$(in_sandbox "$SB" ok '
apply_heal envmerge >/dev/null; apply_heal jwt >/dev/null
j=$(env_get JWT_KEY)
[[ ${#j} -eq 48 && "$j" != dev-secret-key-* ]] && echo JWTOK
[[ -n $(env_get BRAND_NEW_SETTING) ]] && echo MERGEOK
bootstrap_scan >/dev/null
for h in "${SCAN_HEAL[@]}"; do case "$h" in jwt|envmerge) echo "STILLBROKEN:$h";; esac; done
echo RESCANDONE')
assert_contains "jwt regenerated (48-char)" "$OUT" "JWTOK"
assert_contains "missing keys merged" "$OUT" "MERGEOK"
assert_not_contains "rescan converges" "$OUT" "STILLBROKEN"

# ── S7: crash-looping container → force-recreate heal ────────────────────────
echo "S7: forge-api restart loop"
SB=$(new_sandbox s7)
printf 'JWT_KEY=%s\nSERVER_IMAGE_TAG=1.0.0\nUI_IMAGE_TAG=1.0.0\nAPI_PORT=5000\nUI_PORT=4200\nBRAND_NEW_SETTING=x\n' "$(head -c 64 /dev/urandom | tr -dc A-Za-z0-9 | head -c 48)" > "$SB/.env"
OUT=$(in_sandbox "$SB" apilooping 'bootstrap_scan; printf "HEALS:%s\n" "${SCAN_HEAL[*]:-}"')
assert_contains "flags restart loop for recreate" "$OUT" "recreate:forge-api"

# ── S8: port conflict during bring-up → plain-language fatal ─────────────────
echo "S8: port already allocated"
SB=$(new_sandbox s8)
OUT=$(in_sandbox "$SB" ok '
cmd_up() { echo "Error response from daemon: driver failed ... bind for 0.0.0.0:4200 failed: port is already allocated"; return 1; }
heal_up; printf "FATALS:%s\n" "${SCAN_FATAL[*]:-}"')
assert_contains "names the port in plain language" "$OUT" "Port 4200 is already used"
assert_contains "warns against blind docker-proxy kills" "$OUT" "docker-proxy"

# ── S9: known API failure signature → identified, no issue needed ────────────
echo "S9: DB password mismatch is identified"
SB=$(new_sandbox s9)
OUT=$(in_sandbox "$SB" apidbauth 'diagnose_api && echo IDENTIFIED')
assert_contains "translates pg auth failure" "$OUT" "database password"
assert_contains "diagnose_api returns success" "$OUT" "IDENTIFIED"

# ── S10: unknown failure → plain words + issue URL + gh auto-file (shimmed) ──
echo "S10: unknown failure files an issue (gh shimmed)"
SB=$(new_sandbox s10)
printf 'API_PORT=5000\nSERVER_IMAGE_TAG=1.0.0\nSECRET_SAUCE_PASSWORD=hunter2\n' > "$SB/.env"
: > "$WORK/ghbody.md"; : > "$CALLS"
OUT=$(in_sandbox_tty "$SB" apiunknownlogs '
RECOVERY_ENTRY="forge-deploy --recover"
trace "Doctor scan pass 1: fixable=[up], needs-user=0."
trace "Auto-fix (up): succeeded."
trace "forge-api never reported healthy; log signatures matched no known cause."
diagnose_api || report_unrecoverable "recovery: forge-api will not become healthy" "Synthetic unknown failure for scenario S10."
' 'y\n')
assert_contains "plain-language dead end" "$OUT" "needs a human"
assert_contains "prints prefilled issue URL" "$OUT" "issues/new?title="
BODY=$(cat "$WORK/ghbody.md")
assert_contains "issue filed via gh" "$(cat "$CALLS")" "gh issue create"
assert_contains "repro steps frontloaded" "$(printf '%s' "$BODY" | head -8)" "Steps to reproduce"
assert_contains "repro includes entry command" "$BODY" "forge-deploy --recover"
assert_contains "repro includes doctor trace" "$BODY" "Auto-fix"
assert_contains "tech detail: host section" "$BODY" "### Host"
assert_contains "tech detail: config keys listed" "$BODY" "SERVER_IMAGE_TAG=1.0.0"
assert_contains "credential-shaped values redacted" "$BODY" "SECRET_SAUCE_PASSWORD=<redacted>"
assert_not_contains "no secret leaks into body" "$BODY" "hunter2"
assert_contains "api log tail included" "$BODY" "MysteryException"

# ── S13: SSL double-publish (UI_PORT=443 + override "443:443") ───────────────
echo "S13: SSL double-publish of host 443"
SB=$(new_sandbox s13)
printf 'JWT_KEY=%s\nSERVER_IMAGE_TAG=1.0.0\nUI_IMAGE_TAG=1.0.0\nUI_PORT=443\nAPI_PORT=5000\nBRAND_NEW_SETTING=x\n' "$(head -c 64 /dev/urandom | tr -dc A-Za-z0-9 | head -c 48)" > "$SB/.env"
printf 'services:\n  forge-ui:\n    ports:\n      - "443:443"\n      - "80:80"\n' > "$SB/docker-compose.override.yml"
printf 'server { listen 443 ssl; }\n' > "$SB/nginx-ssl-file.tmp"
mkdir -p "$SB/forge-ui" && mv "$SB/nginx-ssl-file.tmp" "$SB/forge-ui/nginx-ssl.conf"
OUT=$(in_sandbox "$SB" ok 'bootstrap_scan; printf "HEALS:%s\n" "${SCAN_HEAL[*]:-}"')
assert_contains "flags 443 double-publish" "$OUT" "sslports"
OUT=$(in_sandbox "$SB" ok '
apply_heal sslports >/dev/null
[[ $(env_get UI_PORT) == 4200 && $(env_get UI_BIND) == 127.0.0.1 ]] && echo PORTSFIXED
bootstrap_scan >/dev/null
for h in "${SCAN_HEAL[@]:-}"; do [[ "$h" == sslports ]] && echo STILLBROKEN; done
echo DONE')
assert_contains "heal resets UI_PORT/UI_BIND" "$OUT" "PORTSFIXED"
assert_not_contains "rescan clean" "$OUT" "STILLBROKEN"

# ── S14: phantom nginx-ssl.conf directory (docker auto-mkdir) ────────────────
echo "S14: phantom nginx-ssl.conf directory"
SB=$(new_sandbox s14)
printf 'JWT_KEY=%s\nSERVER_IMAGE_TAG=1.0.0\nUI_IMAGE_TAG=1.0.0\nUI_PORT=4200\nAPI_PORT=5000\nBRAND_NEW_SETTING=x\n' "$(head -c 64 /dev/urandom | tr -dc A-Za-z0-9 | head -c 48)" > "$SB/.env"
printf 'services:\n  forge-ui:\n    ports:\n      - "443:443"\n' > "$SB/docker-compose.override.yml"
mkdir -p "$SB/forge-ui/nginx-ssl.conf"     # the docker-created phantom DIRECTORY
git -C "$SB" init -q && git -C "$SB" config user.email t@t && git -C "$SB" config user.name t
( cd "$SB" && rmdir forge-ui/nginx-ssl.conf && printf 'server {}\n' > forge-ui/nginx-ssl.conf \
  && git add forge-ui/nginx-ssl.conf >/dev/null && git commit -qm seed >/dev/null \
  && rm forge-ui/nginx-ssl.conf && mkdir forge-ui/nginx-ssl.conf )   # tracked file + phantom dir on top
OUT=$(in_sandbox "$SB" ok 'bootstrap_scan; printf "HEALS:%s\n" "${SCAN_HEAL[*]:-}"')
assert_contains "flags phantom conf dir" "$OUT" "sslconf"
OUT=$(in_sandbox "$SB" ok '
apply_heal sslconf >/dev/null 2>&1
[[ -f "$FORGE_DEPLOY_REPO/forge-ui/nginx-ssl.conf" ]] && echo RESTOREDFILE
bootstrap_scan >/dev/null
for h in "${SCAN_HEAL[@]:-}"; do [[ "$h" == sslconf ]] && echo STILLBROKEN; done
echo DONE')
assert_contains "heal restores the real file from git" "$OUT" "RESTOREDFILE"
assert_not_contains "rescan clean" "$OUT" "STILLBROKEN"

# ── S11/S12: REAL issue submissions (opt-in) ─────────────────────────────────
if $FILE_ISSUES; then
  echo "S11/S12: filing two REAL issues (prefix: 'Automated Test Result -- IGNORE/DELETE: ')"
  if ! gh auth status >/dev/null 2>&1; then
    fail "gh not authenticated — cannot file real issues"
  else
    REAL_SHIMS="$WORK/realshims"; mkdir -p "$REAL_SHIMS"
    for s in docker sudo systemctl; do ln -sf "$SHIMS/$s" "$REAL_SHIMS/$s"; done  # keep docker shimmed, gh REAL
    for n in 11 12; do
      case $n in
        11) TITLE="Automated Test Result -- IGNORE/DELETE: recovery: forge-api will not become healthy"
            SUMMARY="Automated harness test (scenario S11) of the recovery doctor's unknown-API-failure path. This is not a real outage — safe to close/delete."
            DMODE=apiunknownlogs ;;
        12) TITLE="Automated Test Result -- IGNORE/DELETE: fresh start: setup failed"
            SUMMARY="Automated harness test (scenario S12) of the fresh-start dead-end path. This is not a real outage — safe to close/delete."
            DMODE=ok ;;
      esac
      SB=$(new_sandbox "s$n")
      printf 'API_PORT=5000\nSERVER_IMAGE_TAG=1.0.0\nUI_IMAGE_TAG=1.0.0\n' > "$SB/.env"
      SNIP="$WORK/real-snippet.sh"
      cat > "$SNIP" <<EOT
source "$LIB"; set +e
RECOVERY_ENTRY='bash tools/test-recovery-doctor.sh --file-issues'
trace 'Automated harness scenario S$n: sandbox install, docker shimmed, deliberate dead-end.'
trace 'Doctor reached report_unrecoverable by design.'
report_unrecoverable "$TITLE" "$SUMMARY"
EOT
      OUT=$(printf 'y\n' | FORGE_DEPLOY_REPO="$SB" DOCKER_SHIM_MODE="$DMODE" SHIM_CALLS="$CALLS" \
        PATH="$REAL_SHIMS:$PATH" script -qec "bash '$SNIP'" /dev/null 2>&1)
      URL=$(grep -oE 'https://github.com/[^ ]*/issues/[0-9]+' <<<"$OUT" | head -1)
      if [[ -n "$URL" ]]; then pass "S$n real issue filed: $URL"; else fail "S$n real issue not filed"; printf '%s\n' "$OUT" | tail -5 | sed 's/^/       | /'; fi
    done
  fi
else
  echo "S11/S12: skipped (pass --file-issues to file two real, prefixed GitHub issues)"
fi

echo ""
echo "== results: $PASS passed, $FAIL failed =="
(( FAIL == 0 ))
