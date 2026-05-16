#!/usr/bin/env bash
#
# backup.sh — one-shot snapshot of Postgres + MinIO into a fresh
# timestamped folder under /backups/. Called by supercronic on the
# configured schedule, plus optionally once at container start.
#
# Output layout:
#   /backups/2026-05-16T020000Z/
#     forge.dump              — pg_dump custom format, gzip level 9
#     minio/<bucket>/...      — mc mirror of every MinIO bucket
#     manifest.json           — metadata used by the restore runbook

set -euo pipefail

log() { echo "[$(date -u --iso-8601=seconds)] $*"; }

if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
  log "ERROR: POSTGRES_PASSWORD not set — skipping backup"
  exit 1
fi
if [[ -z "${MINIO_ROOT_PASSWORD:-}" ]]; then
  log "ERROR: MINIO_ROOT_PASSWORD not set — skipping backup"
  exit 1
fi

TIMESTAMP=$(date -u +%Y-%m-%dT%H%M%SZ)
BACKUP_DIR="/backups/${TIMESTAMP}"
mkdir -p "${BACKUP_DIR}"

log "Starting backup → ${BACKUP_DIR}"

# 1. Postgres custom-format dump (compressed, restorable via pg_restore)
log "  pg_dump ${POSTGRES_DB:-forge}..."
PGPASSWORD="${POSTGRES_PASSWORD}" pg_dump \
  -h "${POSTGRES_HOST:-forge}" \
  -p "${POSTGRES_PORT:-5432}" \
  -U "${POSTGRES_USER:-postgres}" \
  -d "${POSTGRES_DB:-forge}" \
  --format=custom \
  --compress=9 \
  --no-owner \
  --no-privileges \
  --file="${BACKUP_DIR}/forge.dump"

# 2. MinIO mirror — every bucket, fresh copy per snapshot (no --remove
#    because each snapshot is point-in-time, not a live mirror)
log "  mc mirror MinIO..."
mc alias set storage \
  "http://${MINIO_HOST:-forge-storage}:${MINIO_PORT:-9000}" \
  "${MINIO_ROOT_USER:-minioadmin}" "${MINIO_ROOT_PASSWORD}" >/dev/null
mkdir -p "${BACKUP_DIR}/minio"
mc mirror --quiet "storage" "${BACKUP_DIR}/minio/" >/dev/null

# 3. Manifest — restore runbook reads this to know what to expect
cat > "${BACKUP_DIR}/manifest.json" <<EOF
{
  "format_version": 1,
  "timestamp": "${TIMESTAMP}",
  "source": {
    "postgres": {
      "host": "${POSTGRES_HOST:-forge}",
      "port": ${POSTGRES_PORT:-5432},
      "db":   "${POSTGRES_DB:-forge}",
      "user": "${POSTGRES_USER:-postgres}"
    },
    "minio": {
      "host": "${MINIO_HOST:-forge-storage}",
      "port": ${MINIO_PORT:-9000}
    }
  },
  "artifacts": {
    "postgres_dump": "forge.dump",
    "postgres_dump_format": "custom",
    "minio_mirror_dir": "minio"
  }
}
EOF

# 4. Retention sweep — delete snapshot dirs older than N days
RETENTION="${BACKUP_RETENTION_DAYS:-30}"
log "  retention sweep (keep last ${RETENTION} days)..."
find /backups -maxdepth 1 -type d -name '20*' -mtime "+${RETENTION}" -print -exec rm -rf {} +

# 5. Summary
SIZE=$(du -sh "${BACKUP_DIR}" | cut -f1)
log "Backup complete: ${BACKUP_DIR} (${SIZE})"
