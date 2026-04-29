# Contributing to qb-engineer-deploy

For project-wide guidelines (branch model, PR conventions), see the
umbrella repo:
**https://github.com/danielhokanson/qb-engineer/blob/main/CONTRIBUTING.md**

This repo is the operator-facing surface. PRs here change how the
platform is installed, configured, and upgraded — keep that audience in
mind.

## What lives here

- `docker-compose*.yml` — one base + variants (cohost, demo, dev, export, prod)
- `setup.sh` / `setup.ps1` — **first-time bootstrap** (any host, runs once per install)
- `refresh.sh` / `refresh.ps1` — **dev-side dev-loop only** (`git pull` + local rebuild). Aborts on Pi-style hosts where `qb-deploy` is installed.
- `scripts/qb-deploy` — **prod CD CLI** (Pi only). Pulls prebuilt GHCR images, pins them in `.env`, runs `docker compose pull` + `up -d`, gates on healthcheck, rolls back on failure.
- `scripts/install-qb-deploy.sh` — installs `qb-deploy` and creates `/etc/qb-engineer/deploy-state.json` (the sentinel that retires `refresh.*` on that host).
- `setup-demo.sh` / `refresh-demo.sh` / `export-demo-data.*` — demo flows
- `scripts/` — Ruby seed scripts for reference data
- `maintenance/` — nginx maintenance-mode page (Dockerfile + assets)
- `tools/rfid-relay/` — small Go utility for serial NFC readers

### Three deploy surfaces, three roles (Phase 7)

| Script | Where it runs | What it does |
|---|---|---|
| `setup.{sh,ps1}` | dev workstations + Pi (first-time only) | Generates `.env`, JWT keys, prompts for seed password, brings the stack up from scratch. Idempotent but really only needed once per host. |
| `refresh.{sh,ps1}` | dev workstations only | `git pull` + `docker compose build` + `up -d`. **Refuses to run on the Pi** (detects `/etc/qb-engineer/deploy-state.json`). Prod no longer rebuilds locally. |
| `qb-deploy` | Pi only | Operator-initiated deploys. Pulls prebuilt GHCR images. See `docs/qb-deploy.md`. |

## Testing locally

```bash
git clone https://github.com/danielhokanson/qb-engineer-deploy.git
cd qb-engineer-deploy
cp .env.example .env
# edit .env to set passwords, ports, etc.
./setup.sh
```

## CI

The CI workflow validates compose files (`docker compose config`),
shell scripts (shellcheck), Dockerfiles (hadolint), and YAML
(yamllint). Keep the warnings clean.

## Releasing

Tag a `vX.Y.Z` from `main` and push. The `release.yml` workflow creates
a GitHub release with auto-generated notes. Pin the chosen image tags
of `qb-engineer-ui` and `qb-engineer-server` in `docker-compose.yml`
*before* tagging — the release IS the compose file, so it must
reference real images.

Then update [release-manifest.md in the umbrella repo](https://github.com/danielhokanson/qb-engineer/blob/main/release-manifest.md)
to record the bundle.

## Where to file what

- **Install/upgrade bug, compose issue, ops script bug** → here
- **App-level bug** → file in qb-engineer-ui or qb-engineer-server
