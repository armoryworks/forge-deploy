# Contributing to qb-engineer-deploy

For project-wide guidelines (branch model, PR conventions), see the
umbrella repo:
**https://github.com/danielhokanson/qb-engineer/blob/main/CONTRIBUTING.md**

This repo is the operator-facing surface. PRs here change how the
platform is installed, configured, and upgraded — keep that audience in
mind.

## What lives here

- `docker-compose*.yml` — one base + variants (cohost, demo, dev, export, prod). The `prod` overlay swaps `build:` for `image:` references to GHCR — applied automatically by `setup.sh` (default) and by `qb-deploy`.
- `setup.sh` / `setup.ps1` — **first-time bootstrap** (any host, runs once per install). Defaults to GHCR-pull (no source code required); pass `--source` to build from sibling repos.
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
| `setup.{sh,ps1}` | dev workstations + Pi + tester hosts (first-time only) | Default: pulls prebuilt multi-arch images from GHCR (`linux/amd64` + `linux/arm64`), generates `.env`, JWT keys, prompts for seed password, brings the stack up. Pass `--source` to build from sibling repos instead (developer mode). Idempotent but really only needed once per host. |
| `refresh.{sh,ps1}` | dev workstations only | `git pull` + `docker compose build` + `up -d`. **Refuses to run on the Pi** (detects `/etc/qb-engineer/deploy-state.json`). Prod no longer rebuilds locally. |
| `qb-deploy` | Pi only | Operator-initiated deploys. Pulls prebuilt GHCR images, gates on healthcheck, rolls back on failure. The ongoing-deploys answer for any host that's already booted. |

## Two install paths

`setup.sh` has two modes. Pick the one that matches what you need.

### Production / tester path (default — GHCR-pull)

Pulls prebuilt images from `ghcr.io/danielhokanson/qb-engineer-{server,ui,test}`.
Multi-arch images cover `linux/amd64` and `linux/arm64`, so x86_64 and arm64
hosts both work. **No source code required.**

```bash
git clone https://github.com/danielhokanson/qb-engineer-deploy.git
cd qb-engineer-deploy
./setup.sh                  # creates .env, pulls images, brings up the stack
```

This is the path testers and production hosts should use. For ongoing
operator deploys on the Pi, install the `qb-deploy` CLI for
healthcheck-gated rollouts (see `scripts/install-qb-deploy.sh` and the
`qb-deploy` operator docs).

### Developer / source-build path (`--source`)

Builds images locally from sibling source repos. Use this if you're
hacking on `qb-engineer-server`, `qb-engineer-ui`, or `qb-engineer-test`.

```bash
# All four repos as siblings under a master folder:
mkdir qb-engineer && cd qb-engineer
git clone https://github.com/danielhokanson/qb-engineer-server.git
git clone https://github.com/danielhokanson/qb-engineer-ui.git
git clone https://github.com/danielhokanson/qb-engineer-test.git
git clone https://github.com/danielhokanson/qb-engineer-deploy.git

cd qb-engineer-deploy
./setup.sh --source         # builds locally, brings up the stack
```

If sibling repos are missing, `./setup.sh --source` offers to clone them
for you; declining prints the exact `git clone` commands you need.

### Testing the deploy repo itself

```bash
cd qb-engineer-deploy
cp .env.example .env
# edit .env to set passwords, ports, etc.
./setup.sh                  # GHCR-pull, fastest path to a running stack
# or:
./setup.sh --source         # build from local sources
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
