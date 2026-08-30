# Postgres 17 → 18 upgrade

> The compose files now pin `pgvector/pgvector:pg18` (and `postgres:18-alpine`
> for the GlitchTip crash DB). **Postgres 18 cannot read a Postgres 17 data
> directory.** Pointing the new image at an existing `pgdata` volume fails to
> start — it does not silently corrupt anything, but the stack stays down until
> you migrate. Do the dump/restore below before or during the deploy that picks
> up the new tag.

## 0. Before you start (this step is load-bearing)

Two things must be true, and they are easy to get backwards:

```bash
cd /opt/forge                                       # wherever docker-compose.yml lives
grep -n 'pgvector/pgvector:pg' docker-compose.yml   # must already say pg18
forge-deploy compose exec -T forge psql -U postgres -tAc 'show server_version'
```

The compose file must be on **pg18** while the running container is still
**17**. If the checkout still says pg17, stop and update the deploy tree first
(`forge-deploy --self-update`). Running the rest against a pg17 checkout pulls
pg17 again and restores into a fresh **17** cluster - a clean-looking success
that upgraded nothing, and the easiest way to waste an outage window here.

Use `forge-deploy compose ...` rather than bare `docker compose` throughout.
The CLI composes a specific `-f` list, including `docker-compose.override.yml`,
which holds this box's public/SSL port bindings; a bare `docker compose` misses
that list and can recreate containers loopback-only, taking an exposed site off
the network.

## 1. What changed besides the version

The upstream image moved its default data directory in 18:

| | PGDATA | Declared VOLUME |
|---|---|---|
| ≤ 17 | `/var/lib/postgresql/data` | `/var/lib/postgresql/data` |
| 18 | `/var/lib/postgresql/18/docker` | `/var/lib/postgresql` |

The compose files set `PGDATA=/var/lib/postgresql/data` explicitly so the
mount path, the `pgdata` volume name, and every existing runbook keep working.
Don't drop that env var without also moving the volume mount.

## 2. Migrate the `forge` database

Run on the host, with the stack up on **pg17** (the old tag) so you can dump:

The compose project has no explicit `name:`, so volumes are prefixed with the
deploy directory name. Resolve the real names first and reuse them below:

```bash
cd /opt/forge          # wherever docker-compose.yml lives
PGVOL=$(forge-deploy compose ps -q forge | xargs docker inspect \
  -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}')
echo "$PGVOL"          # e.g. forge_pgdata — sanity-check it before continuing
```

```bash
# 1. Take a dump with the OLD server still running.
forge-deploy compose exec -T forge \
  pg_dump -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-forge}" \
  --format=custom --compress=9 > /tmp/forge-pre18.dump

# 2. Stop the stack and rename the old volume out of the way (do NOT delete
#    it — it is the rollback).
forge-deploy compose down
docker volume create "${PGVOL}_pg17_keep"
docker run --rm -v "$PGVOL":/from -v "${PGVOL}_pg17_keep":/to alpine \
  sh -c 'cd /from && cp -a . /to'
docker volume rm "$PGVOL"

# 3. Pull the new image and start ONLY the database so initdb runs clean.
forge-deploy compose pull forge
forge-deploy compose up -d forge
until forge-deploy compose exec -T forge pg_isready -U "${POSTGRES_USER:-postgres}"; do sleep 2; done

# 4. Restore.
forge-deploy compose exec -T forge \
  pg_restore -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-forge}" \
  --clean --if-exists --no-owner < /tmp/forge-pre18.dump

# 5. Bring the rest up.
forge-deploy --up
```

`pg_restore` will report errors for objects that did not exist yet on the
first `--clean` pass; those are expected. Anything mentioning `vector`,
a missing extension, or a failed constraint is not — stop and read it.

### If you would rather not remove the old volume at all

The sequence above copies `$PGVOL` aside and then removes the original, so the
data always exists in two places or one - never zero. If you want the pg17
volume genuinely untouched, point the new server at a different volume instead:
add `pgdata18:` under the top-level `volumes:` key and change the `forge`
service to mount `pgdata18:/var/lib/postgresql/data`. Restore into that, and
rollback becomes changing the one line back.

The trade-off is that this diverges docker-compose.yml from the committed file,
so `forge-deploy --self-update` will overwrite it - and the next start would
then point pg18 at the pg17 volume, which refuses to boot rather than
corrupting anything. Fine for a short window, worse as a steady state.

## 3. Verify before you delete the rollback volume

```bash
forge-deploy compose exec -T forge psql -U postgres -d forge -c "select version()"
forge-deploy compose exec -T forge psql -U postgres -d forge -c "\dx"     # pgvector present
forge-deploy compose exec -T forge psql -U postgres -d forge -tAc \
  "select count(*) from pg_tables where schemaname='public'"
curl -fsS http://127.0.0.1:8080/health
```

Compare the table count against the pre-upgrade number. Exercise a login, a
work-order read, and one AI/embedding path (that's the pgvector column). Only
then `docker volume rm "${PGVOL}_pg17_keep"`.

## 4. Rollback

```bash
forge-deploy compose down
docker volume rm "$PGVOL"
docker volume create "$PGVOL"
docker run --rm -v "${PGVOL}_pg17_keep":/from -v "$PGVOL":/to alpine \
  sh -c 'cd /from && cp -a . /to'

# Put the image back to 17. Do NOT use `git checkout -- docker-compose.yml`:
# the pg18 pin is COMMITTED (3b126d8), so checkout restores pg18 and you would
# be pointing 18 at the 17 data you just put back.
sed -i 's|pgvector/pgvector:pg18|pgvector/pgvector:pg17|' docker-compose.yml

forge-deploy --up
```

That `sed` is a hold, not a revert: the next `forge-deploy --self-update` pulls
the committed pg18 pin back, so re-apply it if you are staying on 17. Do not
put the pin in `docker-compose.override.yml` instead - `setup.sh` owns that
file for this box's public/SSL port bindings, and overwriting it drops them.

## 5. The crash-reporting database

`forge-crash-db` (GlitchTip) moved `postgres:16-alpine` → `postgres:18-alpine`.
It runs under the `crash-reporting` profile and holds only error events. If you
don't need the history, the cheapest path is to drop the volume and let
GlitchTip re-run its migrations on an empty database:

```bash
forge-deploy compose --profile crash-reporting down
docker volume rm "$(basename "$PWD")_crashpgdata"
forge-deploy compose --profile crash-reporting up -d
```

Otherwise dump/restore it the same way as §2.

## 6. What was already verified

- `forge.tests` (2444 tests) passes against `pgvector/pgvector:pg18` — the
  Testcontainers fixture in `forge.tests/Helpers/PostgresFixture.cs` now pins
  pg18, so CI exercises this on every run.
- CI service containers moved `postgres:17` → `postgres:18`; they create a
  fresh cluster per run, so no migration applies there.
