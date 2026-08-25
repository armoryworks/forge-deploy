#!/usr/bin/env bash
# ensure-deps.sh — install the small prerequisites the deploy CLI needs.
# Idempotent; used by the npx upgrade path and tools/forge-upgrade.sh.
set -euo pipefail

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
