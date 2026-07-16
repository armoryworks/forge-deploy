# Changelog

All notable changes to forge-deploy and its packaged images. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions track the deploy stack as a whole, not the individual app image tags.

## [Unreleased]

### Fixed

- **SSL install was broken on every fresh box, two ways** (found on a clean Ubuntu 24.04 install, 2026-07-16). (1) *Double-publish of host 443*: setup.sh set `UI_PORT=443` while the generated override also published `443:443`; compose merges port lists, so the container tried to bind host 443 twice and died with "port is already allocated" — with nothing listening, which made it look like phantom daemon state. setup.sh no longer touches `UI_PORT`; the override solely owns 443/80 and the plain-HTTP 4200 mapping is pinned to loopback (`UI_BIND=127.0.0.1`) so TLS can't be bypassed from the network. (2) *`forge-ui/nginx-ssl.conf` was referenced but never shipped*: docker silently auto-created the mount source as an empty root-owned directory, then failed with "not a directory: are you trying to mount a directory onto a file?". The file (canonical source: forge-ui repo) is now tracked in this repo, setup.sh verifies it and removes phantom directories, and the port-80 server exempts the loopback healthcheck from the HTTPS redirect (a blanket 301 made `wget --spider http://127.0.0.1:80/` fail, so the container never went healthy).
- setup.sh pre-creates `./backups` and `./certs` so docker doesn't auto-create them root-owned.
- `--recover` detects and heals both SSL failure states (`sslports`, `sslconf` — restores the config from git), and now distinguishes "daemon not running" from "your user can't access the docker socket" (plain-language usermod + re-login guidance).
- setup.sh notes the missing-buildx Bake warning once (`sudo apt install -y docker-buildx`) instead of letting compose print a scary warning mid-build.

### Added

- **`forge-deploy` is now the single user-facing entry point** (forge-deploy `0.6.0`). A no-arg run on a never-bootstrapped box routes through the new **recovery doctor**, which runs the first-time bootstrap (delegating to `setup.sh` internally via `FORGE_DEPLOY_CALLER=1`) and then the topology wizard — users never invoke `setup.sh` directly anymore (direct runs print a deprecation pointer and continue).
- **`forge-deploy --recover` (alias `--doctor`)** — declarative state scan that detects common failure modes and the incomplete setups they leave behind: Docker missing/stopped, snap-Docker-on-cgroup-v2 packaging, missing Compose plugin, incomplete repo clone, missing/unwritable/outdated `.env` (merges new `.env.example` keys), placeholder JWT key, unpinned or `latest` image tags, uninstalled CLI state, stopped or crash-looping containers, and port conflicts (named in plain language, never blind-killed). Fixable items heal in place across up to 3 scan→heal passes, then the run health-gates on `forge-api`. Known API-log signatures (bad DB password, unreachable remote DB/storage, GHCR unauthorized) get plain-language explanations.
- **`forge-deploy --fresh-start`** — the rm-rf path: after a typed `FRESH` confirmation, tears down all Forge containers and volumes (database + uploaded files), removes generated config (`.env`, certs, overrides, box scope), resets the recorded role, and re-runs setup from scratch. Works from broken/partial states (belt-and-braces `docker rm -f` fallback when compose can't resolve).
- **Unrecoverable-issue reporting** — when recovery hits something it can't fix or identify, it explains the situation in plain language (no log dumps), prints a prefilled GitHub issue URL, and — if a `gh` login is present — offers to auto-file the issue with sanitized, secret-free diagnostics (`.env` is never included; log tails are credential-scrubbed).

### Changed

- **`forge-deploy --list` now pairs each version with its build-sha** (forge-deploy `0.2.0`). The default view resolves the manifest digest of every recent `X.Y.Z` tag and every `main-<sha>` tag (in parallel via `xargs -P`), groups by digest — they share one digest because the release-manifest workflow stitches all tags onto a single manifest list — and prints `0.0.115  (main-972e58a)  ← latest`. `--list --releases` and `--list --builds` give the old single-column views. Version sort fixed to `sort -Vr` so `0.0.115` ranks above `0.0.9` (plain `sort -r` ordered them wrong). `ghcr_list_tags` now follows GHCR pagination so images with 100+ accumulated tags aren't truncated to the first page.

### Added

- **GHCR Basic-auth support in `forge-deploy`** for the window where the `forge-*` container packages are still private. Reads `GHCR_USER` + `GHCR_TOKEN` from the environment, or from `${STATE_DIR}/ghcr-user` + `ghcr-token` written by `install-forge-deploy.sh` (`sudo GHCR_USER=… GHCR_TOKEN=ghp_… ./scripts/install-forge-deploy.sh`). Falls back to anonymous token requests for public images, so no change is needed once the packages are flipped to public. Per-repo token caching added so the parallel digest resolution doesn't re-mint a token per request.
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
