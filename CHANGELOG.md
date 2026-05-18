# Changelog

All notable changes to forge-deploy and its packaged images. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions track the deploy stack as a whole, not the individual app image tags.

## [Unreleased]

### Added

- `docs/DEPLOY.md` — canonical install runbook covering Pi 5 / Ubuntu Server arm64 + Cloudflare Tunnel topology.
- `docs/TROUBLESHOOTING.md` — symptom/cause/fix catalog covering host setup, image pull, stack startup, runtime, and ingress issues encountered in real deploys.
- `CHANGELOG.md` (this file).

### Fixed

- **`forge-api` DI lifetime bug** (forge-api `690c921`). `Forge.Core.Interfaces.IStorageService` was registered as singleton but consumed `Forge.Core.Settings.ISettingsService` (scoped), causing startup validation failure (`ValidateScopes=true`) and a container restart loop. Approximately 20 MediatR handlers were transitively affected, including `UploadLogoHandler`, `DeleteLogoHandler`, `DeleteLockupHandler`, and `HandleDocuSealWebhookHandler`. Fix delivered in `ghcr.io/armoryworks/forge-api:latest` (multi-arch arm64 + amd64).
- **`forge-storage` (MinIO) healthcheck added to `docker-compose.yml`** (forge-deploy `5df1180`). The service previously shipped without a `healthcheck:` stanza, so any downstream service declaring `depends_on: forge-storage condition: service_healthy` (notably `forge-ui`, and `forge-backup` once it was added) silently failed to start. The new healthcheck hits MinIO's own `/minio/health/live` endpoint at 10s intervals. `docker compose up -d` now brings the full stack up in one pass without needing to explicitly name dependent services.

### Clarified (not bugs — documentation drift)

- **`MockClock` gating is on `ASPNETCORE_ENVIRONMENT`, not `MOCK_INTEGRATIONS`.** Confirmed at `Program.cs:80` (`builder.Environment.IsDevelopment()`). `MOCK_INTEGRATIONS=false` will not switch the clock to `SystemClock`; set `ASPNETCORE_ENVIRONMENT=Production` (or any non-`Development` value) for that. TROUBLESHOOTING.md documents the env var to flip.
- **`OllamaAiService` is not a startup probe.** Service is `AddHttpClient<>` (transient), not instantiated at startup. The recurring `Ollama health check failed` stack trace in logs comes from `DocumentIndexJob` (a Hangfire recurring job) firing its first run on boot. The job catches the failure and no-ops, but the trace is logged at WRN. Cosmetic noise only; proper fix is to gate the job registration on the AI capability/profile so the first run doesn't fire when AI is disabled.
- **Health-check route is `/api/v1/health`.** Older notes say `/health`. Confirmed against the compose `healthcheck` stanza (`wget --spider http://localhost:8080/api/v1/health`). No `/health` route exists. DEPLOY.md corrected.
- **`setup.sh --cohost` binds UI to `127.0.0.1:4200`.** Older notes say `:80`. Cohost mode is the intended path for tunnel/proxy-fronted deploys; DEPLOY.md and the tunnel config reference use `4200`.

### Known issues (carried forward)

- **`forge-api` uses MinIO root credentials directly.** `docker-compose.yml:44-45` wires `Minio__AccessKey=${MINIO_ROOT_USER}` and `Minio__SecretKey=${MINIO_ROOT_PASSWORD}`. There is no separate scoped IAM user with bucket-only access. Acceptable on private-tunnel deployments; should be addressed before any deployment with broader network exposure. Fix is a forge-api change to consume a separate `MINIO_API_USER` / `MINIO_API_PASSWORD` plus a deploy-time `mc admin user add` step.
- **Preset documentation drift.** Earlier deploy notes referenced "PRESET-03 Plastics Manufacturing." `PresetCatalog.cs` lists PRESET-03 as **Distribution / Wholesale**. There is no Plastics-named preset. Applying PRESET-03 to a plastics manufacturer would disable BOM, Routing, WorkCenters, and all `MFG-*` capabilities — the opposite of intent. Operators must read the catalog at deploy time, not trust hand-off documents.
- **No `FORGE_PRESET` env var exists.** Preset application is admin-UI only via `POST /api/v1/presets/{id}/apply`. If reproducible/IaC-friendly preset application becomes a real requirement, it must be built; it cannot be configured around.
- **EF Core auto-migrations make rollback non-trivial.** forge-api applies pending migrations on startup. The DB schema is always at-or-ahead of whatever image last ran successfully. Rolling back to an older image requires restoring Postgres from a backup taken before the upgrade. Any release shipping a migration should add a "downgrade requires manual rollback from backup" note to its CHANGELOG entry.
- **`SEED_USER_PASSWORD` is one-shot.** Changing the value in `.env` and re-deploying does not rotate the seeded admin's password if the Identity row already exists. Rotate via the admin UI, or wipe the DB and re-seed.

---

## Conventions for future entries

- One entry per merged change. Group related infra changes under a single `Changed` bullet only when they ship as a unit.
- `Fixed` entries that originated in app code (forge-api, forge-ui, forge-test) must reference the app version they ship in (image tag or git SHA).
- `Known issues` carries forward across releases until resolved. Move resolved items to a release's `Fixed` section in the same change that resolves them.
- Operational footguns surfaced during a deploy that we documented in TROUBLESHOOTING.md should also get an entry here under `Added` so they're discoverable in release notes.
