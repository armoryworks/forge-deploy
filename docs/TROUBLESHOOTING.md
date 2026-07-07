# Forge Troubleshooting Guide

Entries are organized by where the symptom appears — host setup, image pull, stack startup, runtime, tunnel / Cloudflare. Each follows the same shape: **Symptom → Cause → Fix**.

If you've hit something not in this list, add it. The cost of writing the entry is much less than the cost of the next person hitting the same thing cold.

---

## Host setup (Pi 5 / Ubuntu Server arm64)

### `docker stop` / `compose up` fails with "could not kill container: permission denied" (snap Docker + cgroup v2)

**Symptom**: On a host where Docker was installed via **snap**, `docker compose up -d`, `docker stop`, or `docker rm` on a **running** container fails with:

```
Error response from daemon: cannot stop container <id>: could not kill container: permission denied
```

`docker build`, `docker exec`, `docker ps`, and `docker inspect` all work — only stopping/killing/recreating a *running* container fails. `forge-api`'s Testcontainers-backed integration tests (`dotnet test`) pass their assertions but fail at **teardown** with the same error. This blocks any local rebuild-and-restart of a service (`docker compose up -d --build forge-api`, etc.).

**Cause**: The snap-packaged Docker daemon runs under an AppArmor profile (`snap.docker.dockerd`) whose cgroup rules target the **cgroupfs / cgroup-v1 layout** (`/sys/fs/cgroup/*/docker/**`). On a host with **cgroup v2 + the systemd cgroup driver** (Docker's default there), containers live at `/sys/fs/cgroup/system.slice/docker-<id>.scope/`, and killing one means writing that scope's `cgroup.kill` file — which the profile grants **no write access** to, so AppArmor denies it. Create/start/exec go through systemd D-Bus and never touch `cgroup.kill`, which is why they work. Confirm you have this exact combination:

```bash
docker info --format 'Root={{.DockerRootDir}}  Driver={{.CgroupDriver}}  v{{.CgroupVersion}}'
# Root=/var/snap/docker/...   Driver=systemd   v2      → this is the bug
```

**Fix**:

- **Quick, reversible (dev boxes)** — unload the daemon's AppArmor profile so it runs unconfined:

  ```bash
  sudo apparmor_parser -R /var/lib/snapd/apparmor/profiles/snap.docker.dockerd
  ```

  Stop / recreate works immediately after. Reverse with `sudo apparmor_parser -r <same path>`. **Not persistent** — snapd reloads (re-enforces) the profile on reboot and on the next `docker` snap refresh, so re-run it afterward, or use the permanent fix. (`aa-complain` from `apparmor-utils` does the same non-destructively if that package is installed; base installs only have `apparmor_parser`.)

  > ⚠ **Do NOT `snap restart docker` (or reboot) while the profile is unloaded.** The confined snap launcher requires the profile to be present, so `dockerd` exits immediately (`status=1`, ~88ms) and systemd gives up after a few retries ("start request repeated too quickly") — the daemon won't come back. Recover with: `sudo apparmor_parser -r /var/lib/snapd/apparmor/profiles/snap.docker.dockerd && sudo systemctl reset-failed snap.docker.dockerd.service && sudo snap start docker`. (A clean daemon start also reprograms Docker's iptables `FORWARD` rules — which fixes the separate "same-network containers time out reaching each other" symptom after network churn.)

- **Permanent** — replace the snap with **Docker CE from Docker's apt repo** (docs.docker.com/engine/install/ubuntu). The docker-ce daemon runs **unconfined**, so cgroup v2 + the systemd driver work natively and this whole class of failure is gone. **Back up data volumes first** — removing the `docker` snap deletes everything under `/var/snap/docker/` (images, containers, volumes).

**Related**: after a failed/partial recreate you may then hit a stray `docker-proxy` still holding the published host port (`failed to bind host port …: address already in use`). Don't blind-kill it — confirm its `-container-ip` matches **no** running container (`ps -o args -p <proxy-pid>` → compare against `docker inspect`), then `sudo kill <pid>`. See the "Port Conflicts — Never Blind-Kill `docker-proxy`" ownership check in the umbrella `CLAUDE.md`.

**⚠ Also check for a SECOND daemon (snap + docker-ce dual install).** On the box where this was first debugged (2026-07-07), the snap coexisted with a **docker-ce apt install, and BOTH daemons were running** — the snap owned `/var/run/docker.sock` (what the CLI saw) while docker-ce's `docker.service` silently ran **its own parallel copy of the compose stack** from `/var/lib/docker`. Symptoms of the dual-daemon state: "orphaned" containers that **resurrect with new PIDs after being killed** (the second daemon's restart policy), ghost `docker-proxy` processes on a *different* subnet than `docker network inspect` shows, host-port conflicts on every recreate, and broken container-to-container routing (two daemons programming iptables over each other). Diagnose: `systemctl is-active docker.service` while `docker info` reports a `/var/snap/docker/...` root, or a client/server version mismatch in `docker version`, or `containerd-shim` processes pointing at `/run/containerd/containerd.sock` (system containerd) under a snap daemon. Fix: pick ONE install (apt), migrate data, and remove the other completely — see the fix above.

### `apt install docker-compose-plugin` returns "Unable to locate package"

**Symptom**: `sudo apt install docker-compose-plugin` fails on Ubuntu 24.04 arm64 with "E: Unable to locate package docker-compose-plugin".

**Cause**: Ubuntu's package is named `docker-compose-v2`, not `docker-compose-plugin`. The latter is the upstream Docker name and ships from Docker's own repo.

**Fix**:

```bash
sudo apt install -y docker-compose-v2
```

### `resize2fs` fails at "group #512" trying to grow the rootfs beyond ~64GB

**Symptom**: On a fresh Pi 5 install onto a large NVMe (1TB+), `growpart` extends the partition successfully but `resize2fs` fails midway with `Invalid argument While trying to add group #512` and leaves the filesystem at ~64GB.

**Cause**: The Pi Ubuntu image is built with a small initial filesystem and reserves very limited GDT (Group Descriptor Table) space. Online resize (with the rootfs mounted as `/`) cannot grow past the reserved GDT cap, which works out to roughly 64GB at the default 128MB-per-group geometry.

**Fix**: Online resize cannot do this. Do an offline resize from rescue media:

1. Boot the Pi from a separate USB stick with a full Linux environment (Raspberry Pi OS Lite or another Ubuntu live image — make sure it has `resize2fs` and `tune2fs`).
2. Unmount the target NVMe partition.
3. `sudo e2fsck -fy /dev/nvme0n1p2`
4. `sudo resize2fs /dev/nvme0n1p2`
5. Reboot.

For most POC deployments 64GB is sufficient and you can defer this. Plan to do it in a maintenance window before the customer accumulates data.

### Pi boots into emergency mode after a `dd` clone install

**Symptom**: After flashing one drive (USB) and `dd`-cloning to another (NVMe), the system drops into `(initramfs)` or emergency mode at boot with `Failed to start systemd-fsck-root.service` and `Failed to mount /sysroot`.

**Cause**: `dd` clones the *filesystem UUID* along with the data. Both drives now report the same UUID, which confuses the kernel/initramfs root-mount logic when both are connected at boot.

**Fix**: Pick one of:

- **Quick**: physically remove the source drive (the USB) so only the NVMe with the duplicate UUID is present. The kernel has nothing to be confused about and mounts cleanly.
- **Proper**: change one of the UUIDs. Boot from a rescue environment with `tune2fs` available, then:
  ```bash
  sudo tune2fs -U random /dev/nvme0n1p2
  sudo blkid /dev/nvme0n1p2  # note the new UUID
  # If fstab/cmdline.txt reference UUID=, edit them to match the new UUID.
  # If they reference LABEL=, no change needed.
  ```

The Pi Ubuntu image uses `LABEL=writable` and `LABEL=system-boot` in `cmdline.txt` and `fstab` by default, so a UUID change alone usually works without editing those files. But labels can collide the same way — if both drives are connected, the kernel may still pick the wrong one. The safest combination is unique UUIDs + unplugging the source drive after install.

### `Pi 5 with NVMe HAT overheats or drops at PCIe Gen 3`

**Symptom**: NVMe-attached Pi 5 experiences kernel panics, I/O errors, or thermal shutdowns under load. Filesystem corruption may follow.

**Cause**: Pi 5's PCIe is officially Gen 2; Gen 3 is supported but is outside spec and depends on signal integrity for the specific NVMe HAT + drive combination.

**Fix**: Pin to PCIe Gen 2. Add to `/boot/firmware/config.txt`:

```
dtparam=pciex1_gen=2
```

Reboot. Performance loss vs Gen 3 is real but typically acceptable for Forge's workload.

### `findmnt /` shows root on the wrong device after install

**Symptom**: After installing Ubuntu Server to NVMe and rebooting, `findmnt /` reports `/dev/sdaX` instead of `/dev/nvme0n1p2`.

**Cause**: The Pi's `BOOT_ORDER` in EEPROM prefers the USB stick (or SD card) over NVMe and is finding a bootable installer there.

**Fix**: From a working Ubuntu boot on the Pi:

```bash
sudo rpi-eeprom-config --edit
# Change BOOT_ORDER to put NVMe first, e.g. 0xf416 for NVMe → USB → SD
```

Reboot, remove other bootable media, confirm `findmnt /` shows `nvme0n1p2`.

### Captive-portal-like redirects when curling `cdimage.ubuntu.com` (or similar) from the Pi

**Symptom**: HTTPS URLs that work in a browser return an HTML response containing `_uuid={guid}` and `fo=3` query parameters when curled from the Pi.

**Cause(s)**:

1. The Pi is on a network behind a MikroTik HotSpot captive portal (the `_uuid` + `fo=3` parameter combo is its signature).
2. DNS poisoning — the Pi's resolver is returning the captive portal's IP for the requested host.

**Fix**:

- For case 1: authenticate the Pi against the portal (via browser on another host on the same network) or whitelist the Pi's MAC in the portal config.
- For case 2: confirm with `dig cdimage.ubuntu.com @1.1.1.1 +short` vs `dig cdimage.ubuntu.com +short`. If they disagree, replace the local resolver. On systemd-resolved systems, edit the netplan config or systemd-resolved drop-in — not `/etc/resolv.conf` directly (it's a symlink that gets overwritten).

---

## Image pull (GHCR)

### `Failed to pull GHCR images / unauthorized`

**Symptom**: `setup.sh` aborts at the image-pull step:

```
ERROR: failed to pull GHCR images
unauthorized
```

The script suggests "Image tag doesn't exist" or `--source` as causes. Both are usually wrong.

**Cause**: Docker is not authenticated to `ghcr.io`. The Forge images are private.

**Fix**: Log in with a GitHub Personal Access Token that has `read:packages` scope:

```bash
docker login ghcr.io -u <github-username>
# Paste the PAT (not your GitHub password) at the prompt
```

Then re-run setup. Credentials persist in `~/.docker/config.json`.

### `no matching manifest for linux/arm64`

**Symptom**: One specific image fails to pull with `no matching manifest for linux/arm64 in the manifest list entries`.

**Cause**: That image is published as amd64-only. This is a packaging bug in whichever repo builds the image, not a config problem.

**Fix**: Flag the upstream owner. As a stopgap, you can sometimes work around with `docker pull --platform linux/amd64 <image>`, but the resulting container will run under QEMU emulation, which is slow and unreliable. Avoid for production.

---

## Stack startup

### forge-ui doesn't come up after `docker compose up -d`

**Symptom**: `docker compose ps` after `docker compose up -d` shows only 3-4 services running. forge-ui is missing. The earlier compose output shows something like:

```
✘ Container forge-storage  Error
dependency failed to start: container forge-storage has no healthcheck configured
```

**Cause**: MinIO (`forge-storage`) does not have a `healthcheck` stanza defined in its compose service. Other services that declare `depends_on: forge-storage` with `condition: service_healthy` cannot have that condition satisfied, so they never start. forge-ui is typically the affected dependent.

**Fix**: Bring forge-ui up explicitly:

```bash
docker compose up -d forge-ui
```

The proper fix is upstream — add a healthcheck to `forge-storage` in `docker-compose.yml`:

```yaml
forge-storage:
  image: minio/minio
  # ... existing config ...
  healthcheck:
    test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
    interval: 10s
    timeout: 3s
    retries: 5
    start_period: 10s
```

This was fixed in forge-deploy `5df1180`; see CHANGELOG.md. On a fresh `git pull` the workaround above is no longer needed.

### forge-api enters a restart loop with .NET DI errors

**Symptom**: `forge-api` repeatedly shows `Restarting (0)` status. Logs contain hundreds of lines of:

```
System.InvalidOperationException: Cannot consume scoped service 'X' from singleton 'Y'.
```

(Specifically `Forge.Core.Settings.ISettingsService` from `Forge.Core.Interfaces.IStorageService` in the previously-observed case.)

**Cause**: A captive dependency in the service registration graph. A singleton is consuming a scoped service, which .NET DI rejects during startup validation (`ValidateScopes=true`). This is a code bug in the API.

**Fix**: Cannot be fixed from deployment config. Requires source change:

- Re-register the offending service as scoped if it has no per-process state; or
- Inject `IServiceScopeFactory` and resolve the scoped dependency per call.

Rebuild and republish the arm64 image. On the deploy host:

```bash
docker compose pull
docker compose up -d
```

No need to re-run setup.sh — state is preserved.

This specific bug was fixed; see CHANGELOG.md.

---

## Runtime

### `forge-deploy` rolls back the API after "waiting for healthy" times out

**Symptom**: `forge-deploy deploy api <tag>` pulls and starts the new image, then prints `Service did not become healthy — rolling back to <prior>` once the wait passes the timeout. The rolled-back (older) image comes up fine.

**Cause**: forge-api does its slow startup work **before** it serves traffic — `MigrateAsync` applies any pending EF Core migrations, the seeders run, and `/api/v1/health` is a *composite* readiness check that stays `503` until Postgres, Hangfire, MinIO, **and** SignalR all report healthy. The deploy gate polls `http://127.0.0.1:<API_PORT>/api/v1/health` with `curl -fsS`, which treats `503` (and connection-refused while still migrating) as "not healthy". Against a populated database, a clean deploy legitimately needs longer than the old fixed 60s, so the gate fired and rolled back a build that was actually fine.

> ⚠ This rollback is risky, not just annoying: `MigrateAsync` may have **already applied the new schema** before the gate gave up, leaving the older (rolled-back) image running against a newer database. If a deploy keeps rolling back, check `docker logs forge-api` for `[DB-LIFECYCLE] Running MigrateAsync...` and confirm the schema state before re-deploying.

**Fix**: the timeout is now configurable and defaults to **180s**. Raise it for slower hosts / larger databases by setting it in `.env` (persistent) or as a one-off shell env var:

```bash
# Persistent — survives future deploys
echo 'HEALTHCHECK_TIMEOUT_SECS=300' >> /opt/forge-deploy/.env

# One-off for a single deploy
HEALTHCHECK_TIMEOUT_SECS=300 forge-deploy deploy api <tag>
```

Confirm what's actually slow with `docker logs -f forge-api` during the deploy — the bulk of the time before the first `200` should be the `MigrateAsync` line. If it's a transient MinIO/Hangfire blip rather than migrations, fix that dependency instead of just raising the timeout.

### Health check returns 404 at `/health`

**Symptom**: `curl http://localhost:5000/health` returns 404. Older deployment docs say this is the health endpoint.

**Cause**: The route is `/api/v1/health`. Older docs are wrong.

**Fix**:

```bash
curl -s http://localhost:5000/api/v1/health | jq
```

Add an alias if you want backwards compatibility — but the canonical path is `/api/v1/health`.

### MinIO credentials don't rotate when I edit `.env`

**Symptom**: You edit `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` in `.env`, recreate `forge-storage` and `forge-api`. forge-api now reports `MinIO is not accessible` with `AccessDeniedException`, and `/api/v1/health` returns 503.

**Cause**: MinIO accepts `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` values **only on first init**. On subsequent starts with existing data on disk, the new env values are ignored — MinIO continues serving with the credentials baked into the data dir. forge-api meanwhile *does* pick up the new values from `.env`, producing a credential mismatch: forge-api authenticates as `<new>`, MinIO is still root-as-`<old>`, request gets rejected.

> ⚠ **Caveat**: the rotation protocol below is documented MinIO behavior, but the specific step sequence has not been battle-tested against a live forge-deploy install with real customer data. Practice it once on a throwaway MinIO container before running it against a customer instance. If it fails midway, you lock yourself out of the object store and a full restore from backup becomes the recovery path.

**Fix for a fresh deploy with no real data**: wipe and re-init so MinIO does a clean first-boot with the new creds.

```bash
cd /opt/forge-deploy
docker compose down
# edit .env with new MINIO_ROOT_USER / MINIO_ROOT_PASSWORD
docker volume rm forge-deploy_miniodata
docker compose up -d
```

**Fix for a live deploy with data you must preserve**: use MinIO's rotation protocol (the `_OLD` env vars). MinIO sees both sets and re-writes the data dir's credentials atomically.

```bash
cd /opt/forge-deploy
docker compose down

# 1. In .env, set the OLD vars to the CURRENT values:
# MINIO_ROOT_USER_OLD=<current>
# MINIO_ROOT_PASSWORD_OLD=<current>
# And the new values:
# MINIO_ROOT_USER=<new>
# MINIO_ROOT_PASSWORD=<new>

docker compose up -d
# Wait for MinIO to log "Root user credentials updated successfully"
docker compose down

# 2. In .env, remove the _OLD lines.
docker compose up -d
```

**Note on `_FILE` variants visible in `docker compose exec forge-storage env`**: the official `minio/minio` image ships with `MINIO_ROOT_USER_FILE=access_key`, `MINIO_ROOT_PASSWORD_FILE=secret_key`, etc. as image-level defaults so users *can* mount Docker Secrets at `/run/secrets/access_key`. forge-deploy does **not** mount such secrets — the referenced files don't exist on the container — so MinIO falls back to the inline `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` env vars. The `_FILE` variants are not the source of the rotation failure; it's MinIO's first-init-only semantics described above.

### `OllamaAiService` stack trace appears shortly after startup

**Symptom**: Without the `--include-ai` profile, forge-api logs a stack trace within a minute or two of boot:

```
[INF] Sending HTTP request GET http://forge-ai:11434/api/tags
[WRN] Ollama health check failed
System.Net.Http.HttpRequestException: Resource temporarily unavailable (forge-ai:11434)
   at Forge.Integrations.OllamaAiService.IsAvailableAsync(...)
[INF] AI service unavailable — skipping documentation indexing
```

**Cause**: It is **not** a constructor-time probe. `OllamaAiService` is registered via `AddHttpClient<>` (transient) and isn't instantiated at startup. The probe is fired by the `DocumentIndexJob` recurring Hangfire job, which fires its first run on boot when its previous-execution record is `null` (i.e., always on a fresh deploy). The job attempts to embed indexed documents against Ollama, finds it unreachable when the AI profile is off, catches the failure, and logs the trace at WRN.

**Fix**: Functionally benign; the job no-ops cleanly. Proper upstream fix is to gate the Hangfire job registration itself on the AI capability/profile so it doesn't even attempt the first run when AI is disabled.

### `Clock: MockClock (development)` appears in production logs

**Symptom**: forge-api startup log includes:

```
[INF] Clock: MockClock (development) — controllable via POST /api/v1/dev/clock
```

…despite `MOCK_INTEGRATIONS=false` in `.env`.

**Cause**: The clock is gated on the ASP.NET Core environment, **not** on `MOCK_INTEGRATIONS`. At `Program.cs:80`, the registration uses `builder.Environment.IsDevelopment()`, which is true whenever `ASPNETCORE_ENVIRONMENT=Development`. The `MOCK_INTEGRATIONS` flag is a separate switch for external service mocks (SMTP, USPS, DocuSeal, AI) and has no effect on the clock.

UAT and production must not run on a mockable clock — anyone with API access can shift the system clock and corrupt audit trails.

**Fix**: Set `ASPNETCORE_ENVIRONMENT=Production` (or `Staging`, or anything other than `Development`) in the `forge-api` service's environment in `docker-compose.yml`, or set it in `.env` if `docker-compose.yml` references it as `${ASPNETCORE_ENVIRONMENT}`. Restart forge-api:

```bash
docker compose up -d --force-recreate forge-api
docker compose logs forge-api --tail 20 | grep -i clock
```

The startup line should now read `Clock: SystemClock` with no mention of `(development)`.

### Admin login fails after re-running setup with a different `SEED_USER_PASSWORD`

**Symptom**: After a `docker compose down -v` (or otherwise wiping the Postgres volume) and re-running setup with a different `SEED_USER_PASSWORD` in `.env`, the seeded admin account (`admin@forge.local` or whatever the seed user resolves to) does not accept the new password. Login fails with bad credentials.

**Cause**: The seed runs on first boot and stamps the password hash into the Identity tables. On a subsequent boot, if the seed rows already exist, the seed logic treats them as existing entities and does not overwrite the hash — even if `SEED_USER_PASSWORD` in `.env` differs. The new password value is silently ignored.

**Fix**: Pick one:

- **Keep the original `SEED_USER_PASSWORD`.** The seed is a one-shot; pick a value at the start and don't change it.
- **Force a full reset.** Set `RECREATE_DB=true` in `.env` (or run the explicit teardown the deploy tooling provides) to drop and re-create the Postgres volume. The new seed runs against a clean DB and the new password is stamped.
- **Change the password via the admin UI** after logging in with the original. This is the right path for any real environment — the seed password should be rotated post-handoff regardless.

### Older forge-api image fails to start against a newer database

**Symptom**: After deploying an older `forge-api` image (e.g., rolling back), the container fails on startup with EF Core errors about missing migrations or invalid schema.

**Cause**: forge-api auto-applies EF Core migrations on startup via DbUp. There is no manual migration step. This is ergonomic for forward deploys but means **the database schema is always at-or-ahead of whatever image last ran**. Deploying an older image against a newer schema will throw at startup because the older image expects an older schema.

**Fix**: Downgrades require a deliberate rollback procedure:

1. Stop forge-api: `docker compose stop forge-api`.
2. Restore the Postgres volume from the pre-upgrade backup. forge-backup runs `pg_dump` on schedule; identify the latest backup taken before the version you're rolling back from.
3. Restore via `pg_restore` into the `forge` container.
4. Pin the older image tag in `.env` (`SERVER_IMAGE_TAG=<older-tag>`), then `docker compose up -d --force-recreate forge-api`.

**Implication for CHANGELOG entries**: any release that ships a database migration must note "downgrade requires manual rollback from backup."

---

## Tunnel / Cloudflare

### Public URL returns `502 Bad Gateway`

**Symptom**: `curl -I https://<slug>.armoryworks.com` returns 502.

**Cause(s)**:

1. The Cloudflare Tunnel is reaching the Pi, but the host port (`127.0.0.1:4200`) has nothing listening. This is almost always because forge-ui isn't up (see "forge-ui doesn't come up").
2. forge-ui is up, but its internal nginx upstream (forge-api) is unhealthy or restarting. forge-ui's nginx returns 502 when the upstream is down.

**Fix**:

```bash
docker compose ps
curl -sI http://localhost:4200       # should be 200
curl -s http://localhost:5000/api/v1/health | jq    # should be Healthy
```

The first thing not in expected state is your culprit.

### `cloudflared tunnel route dns` fails with "record already exists"

**Symptom**:

```
An A, AAAA, or CNAME record with that host already exists.
```

**Cause**: The DNS record for the subdomain was created previously (a manual entry, a previous tunnel attempt, etc.).

**Fix**: Delete the existing record in the Cloudflare dashboard:

`armoryworks.com` zone → DNS → Records → find the `<slug>` row → Delete.

Then re-run the tunnel route command.
