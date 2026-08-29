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

# Run as a regular user — the script sudos only where needed. Under sudo,
# root's PATH usually can't see an nvm-installed node, and fetched files
# would end up root-owned.
if [[ $EUID -eq 0 ]]; then
  echo "Please run as your regular user (not sudo) — it elevates only where needed." >&2
  exit 1
fi

DEPLOY_DIR="${FORGE_DEPLOY_DIR:-/opt/forge-deploy}"
TAG="${1:-}"
if [[ -n "$TAG" && "$TAG" == -* ]]; then
  # Leading flag (e.g. --allow-destructive), not a tag — forward it instead.
  set -- "" "$@"
  TAG=""
elif [[ -n "$TAG" && ! "$TAG" =~ ^(main-[a-f0-9]{7}|[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?)$ ]]; then
  echo "Not a valid release tag: $TAG (expected X.Y.Z, X.Y.Z-suffix, or main-<7-hex>)" >&2
  exit 1
fi
shift $(( $# > 0 ? 1 : 0 ))
EXTRA_ARGS=("$@")   # forwarded to the deploy CLI (e.g. --allow-destructive)

if ! command -v npx >/dev/null; then
  echo "Node.js is required (npx ships with it): https://nodejs.org — then re-run." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "==> Installing jq (may prompt for sudo)..."
  if command -v apt-get >/dev/null 2>&1; then
    # Try from the existing package lists first; a broken unrelated repo must
    # not block a jq install. Tolerate a failing update the same way.
    sudo apt-get install -y -qq jq 2>/dev/null \
      || { sudo apt-get update -qq 2>/dev/null || true; sudo apt-get install -y -qq jq || true; }
  elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y -q jq || true
  elif command -v yum >/dev/null 2>&1; then sudo yum install -y -q jq || true
  elif command -v apk >/dev/null 2>&1; then sudo apk add --quiet jq || true
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Could not install jq automatically — install it manually (e.g. sudo apt install jq), then re-run." >&2
    exit 1
  fi
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
  ./scripts/forge-deploy "$TAG" "${EXTRA_ARGS[@]}"
else
  echo "==> Updating to the newest release"
  ./scripts/forge-deploy --update "${EXTRA_ARGS[@]}"
fi

echo
echo "If the deploy halted listing DESTRUCTIVE schema changes, review them, then re-run:"
echo "  cd $DEPLOY_DIR && ./scripts/forge-deploy ${TAG:---update} --allow-destructive"

# One-time nudge: the in-app upgrade screen ships with the release, but the
# agent that performs the work is a host service and cannot install itself from
# inside a container that the upgrade replaces. Mention it exactly once per box.
if [[ ! -s /etc/forge/agent.token ]]; then
  echo
  echo "Tip: you can run future upgrades from inside Forge (Admin -> Updates)."
  echo "     One-time setup, from here:"
  echo "       cd $DEPLOY_DIR && bash scripts/install-forge-agent.sh"
  echo "     The command line stays available either way — it is the recovery path."
fi
