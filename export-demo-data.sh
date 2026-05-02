#!/usr/bin/env bash
# Orchestrates the disposable export stack.
#
# Stands up a throwaway Postgres + API from docker-compose.export.yml, the API
# seeds itself + dumps business entities to ./qb-engineer-ui/public/demo-data/
# and exits. This script then tears the stack down (including volumes) so
# nothing lingers. The dev stack is untouched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OUT_DIR="qb-engineer-ui/public/demo-data"
COMPOSE_FILE="docker-compose.export.yml"

echo "[export] Cleaning previous demo-data output..."
find "$OUT_DIR" -type f ! -name '.gitkeep' -delete 2>/dev/null || true

cleanup() {
  echo "[export] Tearing down export stack..."
  docker compose -p qb-engineer-export -f "$COMPOSE_FILE" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[export] Building + running export stack (this can take a few minutes on first run)..."
docker compose -p qb-engineer-export -f "$COMPOSE_FILE" up \
  --build \
  --abort-on-container-exit \
  --exit-code-from qb-engineer-api-export

EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
  echo "[export] FAILED: api-export exited with code $EXIT_CODE"
  exit $EXIT_CODE
fi

FILE_COUNT=$(find "$OUT_DIR" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
echo "[export] Done — $FILE_COUNT JSON files written to $OUT_DIR/"
