#!/usr/bin/env bash
#
# entrypoint.sh — generates a supercronic crontab from BACKUP_SCHEDULE,
# optionally runs an immediate backup at container start, then hands
# off to supercronic for the long-running scheduler.

set -euo pipefail

SCHEDULE="${BACKUP_SCHEDULE:-0 2 * * *}"
RUN_ON_START="${BACKUP_RUN_ON_START:-false}"
RETENTION="${BACKUP_RETENTION_DAYS:-30}"

cat <<EOF
forge-backup starting
  schedule:    ${SCHEDULE}
  retention:   ${RETENTION} days
  destination: /backups (host-mounted)
  run on start: ${RUN_ON_START}
EOF

# Generate the crontab supercronic reads.
echo "${SCHEDULE} /usr/local/bin/backup.sh" > /tmp/crontab

if [[ "${RUN_ON_START}" == "true" ]]; then
  echo "BACKUP_RUN_ON_START=true → running initial backup now"
  /usr/local/bin/backup.sh || echo "Initial backup failed (continuing into scheduled mode)"
fi

exec supercronic /tmp/crontab
