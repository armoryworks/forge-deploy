# Changelog

All notable changes to forge-deploy and its packaged images. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions track the deploy stack as a whole, not the individual app image tags.

## [0.8.0] - 2026-08-27

### Added

- **The guided console — `forge-deploy` with no arguments.** The whole customer-facing surface is now one command that takes no flags and assumes no knowledge of the deploy model. It reads the machine, reports what is installed and whether it is healthy in plain language, says whether a newer release exists, and offers a short numbered menu with exactly one entry marked *(recommended)*. Every action is the same gated path the flags drive — the console cannot skip a gate. It covers every state of a box: never bootstrapped, installed but with no role chosen, unhealthy, behind, or current. On a machine that is not a terminal it prints the picture and the non-interactive command instead of hanging.

- **A stale installer is offered as the first step, not forced.** The console compares the npm package that delivered this tree (recorded in `.installer-version` at fetch time) against what `@armoryworks/forge-deploy` publishes now. If it is behind, that becomes menu entry 1 and carries the recommendation, because updating the tool may fix whatever else is wrong. Choosing it fetches the new installer and reopens the console automatically. The `exec` happens *before* the download for a reason documented at the call site: bash reads a script incrementally, and the fetch overwrites the file the function is running from.

- **`tools/test-console.sh`** — 43 assertions across 16 scenarios, driving the console on a real pty with `docker`, `curl`, `npx` and `sudo` all stubbed, so every branch runs on a machine with no Docker daemon at all. This is the first automated coverage of any interactive path in this repo, and it caught two real bugs on its first run (both fixed below). `FORGE_TEST_SHOW=1` prints each screen in full.

- `forge-deploy --pick` preserves the old bare-invocation behaviour (per-component release picker) as operator tooling.

### Changed

- `main()` no longer branches on zero-args before flag parsing (recovery doctor / setup wizard / version picker). Every one of those states is a menu entry in the console now, and the pre-emptive `preflight` that could `die()` in front of a client is gone.
- The npm bootstrapper opens the console on a box that is already configured, instead of re-running `setup.sh`. `npx @armoryworks/forge-deploy` is now the single command worth remembering.
- `STATE_DIR` and `LOG_FILE` honour `FORGE_STATE_DIR` / `FORGE_LOG_FILE`, so the tooling can be exercised outside `/etc` and `/var/log`.
- `docs/DEPLOY.md` §12 leads with the console; the operator flags follow it.

### Fixed

- **A Docker permission error was reported as "Docker is not running".** `docker info 2>&1 | grep -q 'permission denied'` under `set -o pipefail` returns the failure of `docker`, not the result of `grep`, so the branch could never be reached — every permission problem produced advice to start a daemon that was already running. Output is captured before matching now. Found by the new harness.
- **The menu could abort the script before printing.** Labels were built with `"…$( [[ cond ]] && printf ' (recommended)' )"`; when the condition was false the command substitution returned non-zero and `set -e` took the console down mid-render. Rebuilt with explicit `if` blocks, and the recommendation is now assigned once by urgency.
- `console_menu` retries are bounded at three: a closed stdin or a stuck key can no longer leave the tool spinning on a client's server.
- **`docs/DEPLOY.md` "Rollbacks" still described EF Core auto-migrations** — retired 2026-06-17 — five weeks after the Upgrades section next to it was corrected for the same reason. Rewritten: the automatic rollback covers the health-gate failure, manual rollback needs the pre-reconcile dump restored, and `SCHEMA_IMAGE_TAG` must be re-pinned with the image tags or the next deploy re-applies what was backed out. The matching *Known issues* entry above is corrected too.

## [0.7.0] - 2026-08-27

### Changed

- **The npm bootstrapper now fetches a PINNED release tree, not `main`** (`bin/install.mjs`). `TARBALL_URL` resolved `refs/heads/main`, so a client running `npx @armoryworks/forge-deploy upgrade` received whatever had landed on main minutes earlier — the deploy CLI, every compose file, and setup.sh included. Pinning the npm version only ever pinned the ~50-line bootstrapper. The tree ref is now `v0.7.0`; a missing tag is a hard failure with an explanatory message, never a silent fall back to main. `FORGE_DEPLOY_REF` (`heads/main`, `tags/vX.Y.Z`, or a bare tag) overrides it for development.

- **`--allow-destructive` is refused on customer-operated installs.** New `.env` key `SUPPORT_CONTACT`: when set, a reconcile that would drop data still halts and enumerates, but names the contact instead of printing the flag that bypasses the halt, and passing the flag is an error. The disposition prompt ("1 - ok to delete / 2 - cannot until x,y,z / 3 - cannot delete") is addressed to whoever can price the loss; the operator in front of a client box is not that person. Unset (the default) preserves the existing behaviour exactly.

- `tools/forge-upgrade.sh` no longer prints the `--allow-destructive` re-run command as unconditional trailing boilerplate after *every* run, successful or not.

### Added

- **`npx @armoryworks/forge-deploy recover [dir]`** — the doctor (`forge-deploy --recover`) was unreachable from the npm path: in `upgrade` mode flags are appended to `--update` (so `upgrade --recover` became `--update --recover`), and the plain path hands off to `setup.sh`. It is the tool most useful to an operator working alone. Unlike `upgrade` it does not require a configured box — a half-finished install is what it exists for.

- **Node version gate before the implementation loads** (`bin/forge-deploy.mjs` is now a shim over `bin/install.mjs`). `fetch` and `Readable.fromWeb` fail on Node < 18 as a bare `ReferenceError` naming neither Node nor the version; `engines` only makes npm warn. The shim contains nothing newer than dynamic `import()`, checks the major version, and prints install instructions.

## [Unreleased]

### Fixed

- **`--lan` now fully recovers an install that was flipped by `--public`** (field incident, 2026-08-25: a LAN appliance re-run with `--public` left LAN clients on *connection refused* even after `--lan --no-ssl`, with all containers "healthy"). Three healing changes: (1) LAN mode normalizes a leftover `UI_PORT=4200` back to `80` on every run (the dev default is not an operator choice; genuinely custom ports are preserved) — previously the 4200→80 rewrite only ran on a fresh `.env`, so the recovery run advertised/bound the wrong port; (2) a stale **auto-generated** `docker-compose.override.yml` (e.g. the SSL override from a `--public` run) is deleted once no override is needed — it kept auto-loading in `--source` mode and made the exposure inference read the install as "public" forever (hand-written overrides, without the generation marker, are untouched); (3) after starting a LAN install, setup.sh now **probes the advertised `FRONTEND_BASE_URL`** and prints an explicit warning with `ss`/`UI_BIND`/`UI_PORT` guidance when nothing answers — container health alone never verified that the UI was published on the right host port/interface.

### Added

- **Exposure-change guard**: running `--public` against an existing install recorded as `--lan`/`--local` now requires typing `PUBLIC` at an interactive prompt (or passing the new `--confirm-exposure-change` flag in scripts). The prompt spells out the consequences — UI moves to self-signed HTTPS on 80/443, base URL/CORS rewritten away from the LAN address, preflight may stop host services and open UFW. Prevents the habit-run that took a customer LAN site down.

- **setup.sh died silently at the port check when re-run over a live stack as a non-root user** (field report, 2026-07-20). Non-root `ss` can't read root-owned process names (e.g. docker-proxy from the running stack), so the holder-name `grep` matched nothing and its pipefail status killed the script under `set -e` — no error, no output, right after the disk-space check. The port check now tolerates unidentifiable holders (warns and continues; a genuine conflict still surfaces at `compose up` with a clear "port is already allocated"). Same guard applied to the `--public` preflight's `port_listener()` and the `UI_PORT` reads.

### Added

- **Deployment targets in setup.sh: local / LAN / public** (`dbcf025`). Interactive first-time runs with no mode flags are asked "How will people reach this Forge install?"; the answer persists in `.env` (`QBE_DEPLOY_TARGET`) so re-runs never re-ask. New flags: `--lan` (turnkey LAN install — standalone, no TLS, UI bound `0.0.0.0`, `FRONTEND_BASE_URL` / `CORS_ORIGINS` / `MINIO_PUBLIC_ENDPOINT` pointed at the host's LAN IP) and `--local` (explicit localhost-only). `--lan` also converts an existing install in place, which fixes the field-reported failure where the headless auto-SSL default pinned `4200` to loopback and LAN clients got *connection refused*. Final banner now prints the port-correct URL other PCs should use. Documented in `docs/DEPLOY.md` §6 and `docs/TROUBLESHOOTING.md` › Network access (LAN).

## [0.6.1] - 2026-07-16

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
- **Rollback to an older release needs the database restored too.** (Corrected 2026-08-27 — this entry previously described EF Core auto-migrations, retired 2026-06-17.) Schema now comes from the forge-db reconcile, which runs *before* the app swap, so after a successful upgrade the database is at-or-ahead of the release you would return to; re-pinning an older image alone fails against it. `forge-deploy`'s own automatic rollback (health gate fails → previous tag re-pinned) is unaffected and needs none of this. Manual rollback = restore the pre-reconcile `pg_dump`, then re-pin `SERVER_IMAGE_TAG`, `UI_IMAGE_TAG` **and** `SCHEMA_IMAGE_TAG` together. Any release whose reconcile drops or rewrites anything must carry a "downgrade requires manual rollback from backup" note.
- **`SEED_USER_PASSWORD` is one-shot.** Changing the value in `.env` and re-deploying does not rotate the seeded admin's password if the Identity row already exists. Rotate via the admin UI, or wipe the DB and re-seed.

---

## Conventions for future entries

- One entry per merged change. Group related infra changes under a single `Changed` bullet only when they ship as a unit.
- `Fixed` entries that originated in app code (forge-api, forge-ui, forge-test) must reference the app version they ship in (image tag or git SHA).
- `Known issues` carries forward across releases until resolved. Move resolved items to a release's `Fixed` section in the same change that resolves them.
- Operational footguns surfaced during a deploy that we documented in TROUBLESHOOTING.md should also get an entry here under `Added` so they're discoverable in release notes.
