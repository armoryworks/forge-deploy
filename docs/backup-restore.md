# Forge backup + restore

> The `forge-backup` sidecar takes daily snapshots of the Postgres
> database and MinIO buckets onto a host-mounted volume. This document
> covers what gets backed up, where it lands, and — most importantly —
> how to restore from a snapshot.
>
> **You don't trust a backup you haven't restored.** Run the "Test
> restore" procedure (§4) before you depend on the backups for anything
> that matters.

## 1. What gets backed up

| Source | How | Output |
|---|---|---|
| `forge` Postgres database | `pg_dump --format=custom --compress=9` | `forge.dump` |
| All MinIO buckets | `mc mirror storage /backups/.../minio/` | `minio/<bucket>/...` |
| (none — config lives in `.env`, not in the snapshot) | — | — |

Snapshots are point-in-time — each backup is a fresh, independent
folder (no incremental/diff chain). Retention is calendar-based:
folders older than `BACKUP_RETENTION_DAYS` (default 30) are deleted at
the end of each run.

**Not in scope for v1:** the host's `.env` file (passwords, JWT keys),
TLS certs, nginx vhosts, cloudflared config. Capture those separately
to 1Password / your config-management of choice. They're stable enough
that snapshotting them every backup is overkill; they change rarely
and recovery without them is also possible (re-generate keys, re-issue
certs, reapply vhosts from the deploy repo).

## 2. Where it lands

Default destination is the host directory `./backups/` (bind-mounted
into the container at `/backups`). Layout:

```
backups/
├── 2026-05-16T020000Z/
│   ├── forge.dump
│   ├── minio/
│   │   └── <bucket-name>/...
│   └── manifest.json
├── 2026-05-17T020000Z/
└── ...
```

`manifest.json` records the source host/db/MinIO endpoint and the
artifact filenames — the restore procedure reads it to know what it's
looking at.

S3 / SFTP destinations are planned for the admin-configurable version
(post-v1). For now, if you need off-host backups, set up rsync /
rclone on the host to push `./backups/` to your remote of choice on a
separate cron.

## 3. Schedule + retention

Configured via env vars (see `.env.example` → "Backups" section):

- `BACKUP_SCHEDULE` — cron expression in UTC. Default `0 2 * * *` (2am daily).
- `BACKUP_RETENTION_DAYS` — keep last N days. Default 30.
- `BACKUP_RUN_ON_START` — run an immediate backup when the container
  starts. Default false; flip to true after a major change (post-deploy
  smoke test, post-data-migration) to capture a fresh snapshot
  immediately.

Changes take effect on container restart:
`docker compose up -d forge-backup` (with new env vars in `.env`).

## 4. Test restore (do this BEFORE you depend on backups)

Restore a snapshot into a throwaway environment that you can wipe
freely. Goal: confirm the snapshot is recoverable end-to-end, get
familiar with the procedure under no time pressure.

### 4a. Spin up a parallel "restore-test" stack

On the host running the live stack (or any host with the same Docker
setup), create a sibling project that brings up fresh Postgres + MinIO
containers on different ports. Easiest path is a separate compose
project name + override file:

```bash
# Pick a snapshot to restore.
SNAPSHOT=2026-05-16T020000Z
cd /opt/forge-deploy

# Bring up a throwaway DB + storage in their own project namespace.
docker run -d --name restore-test-db \
  -e POSTGRES_PASSWORD=restoretest \
  -e POSTGRES_DB=forge \
  -p 15432:5432 \
  postgres:17-alpine

docker run -d --name restore-test-minio \
  -e MINIO_ROOT_USER=minioadmin \
  -e MINIO_ROOT_PASSWORD=restoretest \
  -p 19000:9000 \
  minio/minio server /data
```

### 4b. Restore Postgres

```bash
# Wait ~5s for postgres to accept connections.
docker exec restore-test-db pg_isready -U postgres -t 5

# Restore the dump. --clean drops existing objects first; --if-exists
# avoids errors on first restore into an empty DB.
PGPASSWORD=restoretest pg_restore \
  --host=localhost --port=15432 \
  --username=postgres \
  --dbname=forge \
  --clean --if-exists --no-owner --no-privileges \
  ./backups/${SNAPSHOT}/forge.dump
```

You'll see notice-level output for the `--if-exists` drops on a clean
DB — that's expected. Errors at the bottom (constraint violations,
missing extensions) indicate a real problem worth investigating.

### 4c. Restore MinIO

```bash
# Configure mc to point at the test MinIO.
mc alias set restoretest http://localhost:19000 minioadmin restoretest

# Mirror each bucket back from the snapshot.
for bucket in ./backups/${SNAPSHOT}/minio/*/; do
  name=$(basename "$bucket")
  mc mb --ignore-existing "restoretest/${name}"
  mc mirror --quiet "${bucket}" "restoretest/${name}/"
done
```

### 4d. Verify

Connect to the restored DB and spot-check core tables:

```bash
PGPASSWORD=restoretest psql -h localhost -p 15432 -U postgres -d forge -c "
  SELECT
    (SELECT COUNT(*) FROM customers) AS customers,
    (SELECT COUNT(*) FROM jobs)      AS jobs,
    (SELECT COUNT(*) FROM parts)     AS parts,
    (SELECT MAX(created_at) FROM jobs) AS latest_job;
"
```

Compare against the same query on the live DB — counts should match
(snapshot is point-in-time, so any rows created after the snapshot are
expected to be missing from the restore).

### 4e. Tear down

```bash
docker rm -f restore-test-db restore-test-minio
```

If everything matched, **the backup is trusted**. If it didn't,
debug before going live with real data.

## 5. Real restore (production-down scenario)

You almost never need this if you've been doing test restores
regularly. The shape is the same as §4, with three changes:

1. **Stop forge-api first.** Restores into a live DB underneath a
   running app corrupt state.
   ```bash
   docker compose stop forge-api
   ```
2. **Restore into the live containers** (`forge` and `forge-storage`),
   not throwaway ones — use the real ports (5432 / 9000) and real
   credentials from `.env`.
3. **Restart forge-api and verify the API health endpoint** before
   reopening to users.
   ```bash
   docker compose up -d forge-api
   curl -s http://127.0.0.1:5000/api/v1/health | jq .
   ```

If you have shipped builds to GHCR newer than the snapshot, deploying
those after the restore is the same as any normal deploy
(`forge-deploy <tag>`).

## 6. Operational notes

- Backups run as the postgres user inside the container (image is
  `postgres:17-alpine`). They connect to the live forge-* services
  over the compose network — no special host access needed.
- A snapshot of a fresh install is ~50-100 MB. With real production
  data (parts, jobs, attachments) expect 1-5 GB per snapshot in the
  first year, growing with attachments. Plan disk accordingly:
  `BACKUP_RETENTION_DAYS=30` × 3 GB ≈ 90 GB on the bind-mount target.
- If a backup fails (network blip, disk full, MinIO unreachable),
  supercronic logs the failure and keeps the schedule — the next
  scheduled run tries again. Failure does NOT crash the container.
- The container does not auto-encrypt snapshots. If the host's
  `./backups/` directory is on encrypted storage (LUKS, ZFS native
  encryption), that's enough for at-rest protection. If not, pipe
  through `gpg` in a wrapper script — or wait for the admin-UI
  version which will offer this as a checkbox.
