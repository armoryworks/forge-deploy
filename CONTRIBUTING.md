# Contributing to qb-engineer-deploy

For project-wide guidelines (branch model, PR conventions), see the
umbrella repo:
**https://github.com/danielhokanson/qb-engineer/blob/main/CONTRIBUTING.md**

This repo is the operator-facing surface. PRs here change how the
platform is installed, configured, and upgraded — keep that audience in
mind.

## What lives here

- `docker-compose*.yml` — one base + variants (cohost, demo, dev, export)
- `setup.sh` / `setup.ps1` — first-time install
- `refresh.sh` / `refresh.ps1` — upgrade existing install
- `setup-demo.sh` / `refresh-demo.sh` / `export-demo-data.*` — demo flows
- `scripts/` — Ruby seed scripts for reference data
- `maintenance/` — nginx maintenance-mode page (Dockerfile + assets)
- `tools/rfid-relay/` — small Go utility for serial NFC readers

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
