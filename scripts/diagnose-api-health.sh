#!/usr/bin/env bash
# diagnose-api-health.sh — read-only triage for forge-api deploy health gating.
#
# When `forge-deploy` rolls a deploy back at "waiting for healthy", run this on
# the host to find out WHY:
#   - Did startup (migrations + seed) actually finish, and how long did it take?
#   - Is /api/v1/health returning 200, 503, or nothing (still starting)?
#   - If 503, which sub-check (postgres / hangfire / minio / signalr) is red?
#
# It only inspects + curls. It never restarts, recreates, or deletes anything.
#
# Usage: ./diagnose-api-health.sh [container-name]   (default: forge-api)
set -uo pipefail

CONTAINER="${1:-forge-api}"
REPO_ROOT="${FORGE_DEPLOY_REPO:-/opt/forge-deploy}"
ENV_FILE="${REPO_ROOT}/.env"

# Host-published API port (mirrors forge-deploy's own resolution).
API_PORT=5000
if [[ -f "$ENV_FILE" ]] && grep -qE '^API_PORT=' "$ENV_FILE"; then
  API_PORT=$(grep -E '^API_PORT=' "$ENV_FILE" | head -1 | cut -d= -f2-)
fi
HEALTH_URL="http://127.0.0.1:${API_PORT}/api/v1/health"

bold() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "Container '$CONTAINER' not found. Pass the name as arg 1 if it differs."
  exit 1
fi

bold "1. Container state"
docker inspect --format 'status        : {{.State.Status}}
running       : {{.State.Running}}
startedAt     : {{.State.StartedAt}}
restartCount  : {{.RestartCount}}
health.status : {{if .State.Health}}{{.State.Health.Status}}{{else}}<no container healthcheck>{{end}}
image         : {{.Config.Image}}' "$CONTAINER"

bold "2. Startup timeline (docker timestamps — compare against startedAt above)"
# -t prefixes each line with a docker RFC3339 UTC timestamp, comparable to startedAt.
logs_t=$(docker logs -t "$CONTAINER" 2>&1)
for marker in "Running MigrateAsync" "migrations applied successfully" "Seed data complete" "Now listening on"; do
  line=$(printf '%s\n' "$logs_t" | grep -F "$marker" | tail -1)
  printf '%-32s : %s\n' "$marker" "${line:-<not found>}"
done
echo "(Gap between startedAt and 'Seed data complete' = blocking startup time. If"
echo " that alone exceeds the deploy timeout, raise HEALTHCHECK_TIMEOUT_SECS.)"

bold "3. Live /api/v1/health probe"
# Capture body + HTTP code together (no temp file → portable, nothing left behind).
resp=$(curl -s -w $'\n%{http_code}' --max-time 5 "$HEALTH_URL" 2>/dev/null || printf '\n000')
code="${resp##*$'\n'}"
body="${resp%$'\n'*}"
echo "URL  : $HEALTH_URL"
echo "HTTP : $code   (000 = connection refused — not listening yet / crashed)"
if [[ -n "$body" ]]; then
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$body" | jq -r '"overall: \(.status)", (.checks[] | "  \(.name): \(.status)\(if .description then " — \(.description)" else "" end)")' 2>/dev/null || printf '%s\n' "$body"
  elif command -v python3 >/dev/null 2>&1; then
    forge_body="$body" python3 -c '
import os, json
try:
    d = json.loads(os.environ["forge_body"])
    print("overall:", d.get("status"))
    for c in d.get("checks", []):
        desc = (" - " + c["description"]) if c.get("description") else ""
        print("  " + str(c.get("name")) + ": " + str(c.get("status")) + desc)
except Exception:
    pass'
  else
    printf '%s\n' "$body"
  fi
fi

bold "4. Container healthcheck probe log (last 3)"
docker inspect --format '{{if .State.Health}}{{range .State.Health.Log}}exit={{.ExitCode}} {{.Output}}{{println}}{{end}}{{else}}<no container healthcheck>{{end}}' "$CONTAINER" 2>/dev/null | grep -v '^$' | tail -3

bold "5. Recent error / dependency signals"
# Target genuine failures only. Excludes routine health-check chatter (contains
# dependency names but reports 'Healthy') and the benign EF Core "global query
# filter" startup warnings, which are WRN-level noise unrelated to the deploy.
printf '%s\n' "$logs_t" \
  | grep -iE '\bERR\b|\bFTL\b|exception|refused|cannot connect|unhealthy|not accessible|did not start|unable to|timed out' \
  | grep -viE 'global query filter' \
  | tail -25 \
  || true
printf '%s\n' "$logs_t" | grep -qiE '\bERR\b|\bFTL\b|exception|refused|cannot connect|unhealthy|not accessible' \
  || echo "(no error/fatal lines found — startup itself looks clean)"

bold "Verdict hint"
cat <<'EOF'
 - HTTP 000 long after startedAt  -> still migrating/seeding or it crashed.
   Check sections 2 + 5. If startup is genuinely slow, raise HEALTHCHECK_TIMEOUT_SECS.
 - HTTP 503 with a sub-check Unhealthy -> FIX THAT DEPENDENCY (section 3).
   A bigger timeout will NOT help; the composite check will stay 503.
 - HTTP 200 -> healthy now; the gate just needed more time.
   Raise HEALTHCHECK_TIMEOUT_SECS in .env and redeploy.
EOF
