#!/usr/bin/env bash
# forge-upgrade.sh — one-command Forge upgrade for client installs.
#
#   ./forge-upgrade.sh                 upgrade to the newest release
#   ./forge-upgrade.sh 1.0.0-beta.22   upgrade to a specific release
#
# Refreshes the deploy tooling from npm, then runs the gated deploy
# (backup -> schema reconcile -> swap -> health check -> auto-rollback).
# Safe to re-run. Requires: Node.js 18+ (npm/npx included), docker.
set -euo pipefail

DEPLOY_DIR="${FORGE_DEPLOY_DIR:-/opt/forge-deploy}"
TAG="${1:-}"

if ! command -v npx >/dev/null; then
  echo "Node.js is required (npx ships with it): https://nodejs.org — then re-run." >&2
  exit 1
fi

# Prerequisites the deploy CLI needs. jq is tiny and universal — install it
# rather than telling the operator to.
if ! command -v jq >/dev/null 2>&1; then
  echo "==> Installing jq (needs sudo once)..."
  if command -v apt-get >/dev/null 2>&1; then sudo apt-get update -qq && sudo apt-get install -y -qq jq
  elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y -q jq
  elif command -v yum >/dev/null 2>&1; then sudo yum install -y -q jq
  elif command -v apk >/dev/null 2>&1; then sudo apk add --quiet jq
  else echo "Please install 'jq' with your package manager, then re-run." >&2; exit 1; fi
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required: https://docs.docker.com/engine/install/ — then re-run." >&2
  exit 1
fi

# First run on a box where /opt needs root: create the dir owned by this user.
if [[ ! -d "$DEPLOY_DIR" ]]; then
  if ! mkdir -p "$DEPLOY_DIR" 2>/dev/null; then
    echo "Creating $DEPLOY_DIR (needs sudo once)..."
    sudo mkdir -p "$DEPLOY_DIR"
    sudo chown "$USER": "$DEPLOY_DIR"
  fi
fi

echo "==> Refreshing deploy tooling into $DEPLOY_DIR (your .env and data are preserved)"
npx --yes @armoryworks/forge-deploy@latest "$DEPLOY_DIR" --fetch-only

cd "$DEPLOY_DIR"
chmod +x scripts/*.sh scripts/forge-deploy 2>/dev/null || true

if [[ -n "$TAG" ]]; then
  echo "==> Deploying release $TAG"
  ./scripts/forge-deploy "$TAG"
else
  echo "==> Updating to the newest release"
  ./scripts/forge-deploy --update
fi

echo
echo "If the deploy halted listing DESTRUCTIVE schema changes, review them, then re-run:"
echo "  cd $DEPLOY_DIR && ./scripts/forge-deploy ${TAG:---update} --allow-destructive"
