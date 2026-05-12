#!/usr/bin/env bash
# refresh-demo.sh — Pull latest code, rebuild, and restart the static demo site
#
# The demo site is a single nginx container serving an Angular bundle + static
# JSON fixtures. No database, no API — all data is synthesized in-browser.
# This script pulls the latest code, rebuilds the demo image with new hashes,
# and restarts the container so clients pick up fresh bundles on next visit.
#
# Usage:
#   ./refresh-demo.sh

set -euo pipefail

step()  { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
ok()    { printf '    \033[32m[OK] %s\033[0m\n' "$1"; }
warn()  { printf '    \033[33m[!!] %s\033[0m\n' "$1"; }
fail()  { printf '    \033[31m[X]  %s\033[0m\n' "$1"; }

PROJECT="forge-demo"
COMPOSE_FILE="docker-compose.demo.yml"

if [[ ! -f "$COMPOSE_FILE" ]]; then
    fail "Run this from the repo root. $COMPOSE_FILE not found."
    exit 1
fi

step "Pulling latest code"
git pull
ok "Repo up to date"

step "Rebuilding demo image and restarting container"
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" up -d --build
ok "Container rebuilt and restarted"

step "Waiting for health check"
for _ in {1..30}; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$PROJECT" 2>/dev/null || echo "starting")
    if [[ "$STATUS" == "healthy" ]]; then
        ok "Container healthy"
        break
    fi
    sleep 2
done

if [[ "$STATUS" != "healthy" ]]; then
    warn "Container did not report healthy within 60s. Current status: $STATUS"
    warn "Check: docker compose -p $PROJECT -f $COMPOSE_FILE logs"
fi

HOST_PORT=$(docker compose -p "$PROJECT" -f "$COMPOSE_FILE" port forge-demo 80 2>/dev/null | sed 's/.*://')

step "Done"
if [[ -n "${HOST_PORT:-}" ]]; then
    ok "Demo serving on http://localhost:${HOST_PORT}/"
fi
ok "If fronted by Cloudflare Tunnel, the public URL needs no action — new hashed bundles will be picked up on next page load."
