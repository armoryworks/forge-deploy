#!/usr/bin/env bash
# ensure-deps.sh — install the small prerequisites the deploy CLI needs.
# Idempotent; used by the npx upgrade path and tools/forge-upgrade.sh.
set -euo pipefail

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
