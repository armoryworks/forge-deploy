# Contributing to forge-deploy

For project-wide guidelines (branch model, PR conventions), see the
umbrella repo:
**https://github.com/armoryworks/forge/blob/main/CONTRIBUTING.md**

This repo is the operator-facing surface. PRs here change how the
platform is installed, configured, and upgraded — keep that audience in
mind.

## What lives here

- `docker-compose*.yml` — one base + variants (cohost, demo, dev, export, prod). The `prod` overlay swaps `build:` for `image:` references to GHCR — applied automatically by `setup.sh` (default) and by `forge-deploy`.
- `setup.sh` / `setup.ps1` — **first-time bootstrap** (any host, runs once per install). Defaults to GHCR-pull (no source code required); pass `--source` to build from sibling repos.
- `refresh.sh` / `refresh.ps1` — **dev-side dev-loop only** (`git pull` + local rebuild). Aborts on Pi-style hosts where `forge-deploy` is installed.
- `scripts/forge-deploy` — **prod CD CLI** (Pi only). Pulls prebuilt GHCR images, pins them in `.env`, runs `docker compose pull` + `up -d`, gates on healthcheck, rolls back on failure.
- `scripts/install-forge-deploy.sh` — installs `forge-deploy` and creates `/etc/forge/deploy-state.json` (the sentinel that retires `refresh.*` on that host).
- `setup-demo.sh` / `refresh-demo.sh` / `export-demo-data.*` — demo flows
- `scripts/` — Ruby seed scripts for reference data
- `maintenance/` — nginx maintenance-mode page (Dockerfile + assets)
- `tools/rfid-relay/` — small Go utility for serial NFC readers

### Three deploy surfaces, three roles (Phase 7)

| Script | Where it runs | What it does |
|---|---|---|
| `setup.{sh,ps1}` | dev workstations + Pi + tester hosts (first-time only) | Default: pulls prebuilt multi-arch images from GHCR (`linux/amd64` + `linux/arm64`), generates `.env`, JWT keys, prompts for seed password, brings the stack up. Pass `--source` to build from sibling repos instead (developer mode). Idempotent but really only needed once per host. |
| `refresh.{sh,ps1}` | dev workstations only | `git pull` + `docker compose build` + `up -d`. **Refuses to run on the Pi** (detects `/etc/forge/deploy-state.json`). Prod no longer rebuilds locally. |
| `forge-deploy` | Pi only | Operator-initiated deploys. Pulls prebuilt GHCR images, gates on healthcheck, rolls back on failure. The ongoing-deploys answer for any host that's already booted. |

## Two install paths

`setup.sh` has two modes. Pick the one that matches what you need.

### Production / tester path (default — GHCR-pull)

Pulls prebuilt images from `ghcr.io/armoryworks/forge-{server,ui,test}`.
Multi-arch images cover `linux/amd64` and `linux/arm64`, so x86_64 and arm64
hosts both work. **No source code required.**

```bash
git clone https://github.com/armoryworks/forge-deploy.git
cd forge-deploy
./setup.sh                  # creates .env, pulls images, brings up the stack
```

This is the path testers and production hosts should use. For ongoing
operator deploys on the Pi, install the `forge-deploy` CLI for
healthcheck-gated rollouts (see `scripts/install-forge-deploy.sh` and the
`forge-deploy` operator docs).

### Developer / source-build path (`--source`)

Builds images locally from sibling source repos. Use this if you're
hacking on `forge-api`, `forge-ui`, or `forge-test`.

```bash
# All four repos as siblings under a master folder:
mkdir forge && cd forge
git clone https://github.com/armoryworks/forge-api.git
git clone https://github.com/armoryworks/forge-ui.git
git clone https://github.com/armoryworks/forge-test.git
git clone https://github.com/armoryworks/forge-deploy.git

cd forge-deploy
./setup.sh --source         # builds locally, brings up the stack
```

If sibling repos are missing, `./setup.sh --source` offers to clone them
for you; declining prints the exact `git clone` commands you need.

### Testing the deploy repo itself

```bash
cd forge-deploy
cp .env.example .env
# edit .env to set passwords, ports, etc.
./setup.sh                  # GHCR-pull, fastest path to a running stack
# or:
./setup.sh --source         # build from local sources
```

### Public deploy (single-host network-reachable HTTPS)

For a tester or single-host install that wants the stack reachable from
the network on 80/443 with HTTPS, `--public` is the one-command macro:

```bash
./setup.sh --source --public
# or, for the GHCR-pull path:
./setup.sh --public
```

`--public` implies `--standalone --ssl` and runs a system-side preflight
that handles the most common Ubuntu/Debian gotchas. With explicit
consent at each step it will:

- Detect what (if anything) is listening on 80/443 and offer to stop +
  disable system `nginx` / `apache2` (`sudo systemctl stop … && disable …`).
  Anything else holding the port aborts with a clear message.
- Open UFW rules `80/tcp` and `443/tcp` if UFW is active.
- Pick the hostname for the self-signed cert. Use `--hostname <fqdn>`
  to skip the prompt; otherwise it offers `hostname -f` and accepts a
  custom value.

Every system change is logged into a `setup-public-rollback.sh` script
in the cwd. Run that script later to revert (re-enable nginx, close
UFW rules). The rollback script is only generated if at least one
preflight action actually ran.

`--public` is incompatible with `--cohost` (those modes have opposite
intents about who owns the host's 80/443) and with `--no-ssl`.

If you need the standalone+SSL behaviour but already have nginx/UFW
handled (or use a different firewall), pass `--no-public-preflight`:

```bash
./setup.sh --public --no-public-preflight
```

That still configures standalone+SSL but skips the system-side checks
and rollback-script generation. Other firewall systems (firewalld,
iptables, cloud security groups) are not auto-handled — verify them
manually.

## CI

The CI workflow validates compose files (`docker compose config`),
shell scripts (shellcheck), Dockerfiles (hadolint), and YAML
(yamllint). Keep the warnings clean.

## Releasing

### This repo (`forge-deploy`) — manual tag

`forge-deploy` publishes no Docker image; the release IS the
compose file + scripts at that tag. Workflow:

1. Pin the chosen image tags of `forge-ui`, `forge-api`,
   and `forge-test` in `docker-compose.yml`.
2. Tag `vX.Y.Z` from `main` and push. `release.yml` creates a GitHub
   release with auto-generated notes.
3. Update [release-manifest.md in the umbrella repo](https://github.com/armoryworks/forge/blob/main/release-manifest.md)
   to record the bundle.

### Sibling image repos — auto-bumped semver

`forge-api`, `forge-ui`, and `forge-test` each
publish a multi-arch GHCR image on every push to `main`, with a real
semver tag that auto-derives from a `VERSION` file at the repo root.

- **`VERSION`** holds `MAJOR.MINOR.BASE` (e.g. `0.0.0`, `0.1.0`,
  `1.0.0`). Manual edit only.
- **Patch is computed in CI** as `BASE + (commits since VERSION was
  last touched)`. Resets to 0 the moment `VERSION` is edited and
  committed.
- **Tag set per main push:** `<X.Y.Z>` (immutable patch), `<X.Y>`
  (floating minor), `latest` (dev exploration only — never deployed),
  `main-<sha>` (legacy hash tag, kept for compatibility).
- **Tag set per `v*.*.*` git tag:** adds `<X>` (floating major) and
  bypasses the VERSION-file computation entirely. Use for explicit
  milestones.

Operator workflow on the image repos:

```bash
# Patch bump — automatic on every main commit. Nothing to do.

# Minor bump — edit VERSION + commit:
echo "0.1.0" > VERSION
git commit -am "Bump VERSION to 0.1.0"
git push origin main
# next release.yml run publishes 0.1.0 + 0.1 + latest + main-<sha>

# Major bump — same shape:
echo "1.0.0" > VERSION
git commit -am "Bump VERSION to 1.0.0"
git push origin main

# Milestone semver (no VERSION edit needed):
git tag -a v2.0.0 -m "Major release" && git push origin v2.0.0
# release.yml publishes 2.0.0 + 2.0 + 2 (does not touch VERSION)
```

Why the `VERSION`-file model: hash tags (`main-<sha>`) are opaque to
operators staring at GHCR. Semver tags read like real versions, sort
lexicographically in the right order, and let `forge-deploy --list
--releases` surface a meaningful list. Patches auto-increment because
the operator shouldn't have to edit a file for every commit.

See [docs/cicd-design.md §Phase 8 addendum](https://github.com/armoryworks/forge/blob/main/docs/cicd-design.md)
for the design background and the matrix-split + Node 24 details.

## Operator deploys on the Pi

Use `forge-deploy` for ongoing deploys (after first-time `setup.sh`):

```bash
forge-deploy --list --releases   # show available semver tags in GHCR
forge-deploy 0.1.5               # deploy that semver to all services
forge-deploy --list              # show recent main-<sha> tags (legacy)
forge-deploy main-abc1234        # deploy a specific SHA
forge-deploy --status            # current deployed tag + container health
forge-deploy --rollback          # re-pin to the previously deployed tag
forge-deploy --service api 0.1.5 # narrow to one service
```

`forge-deploy` refuses `latest` — only immutable tags (`X.Y.Z` or
`main-<sha>`) deploy. Healthcheck-gated; failed deploys auto-rollback.

The deploy repo itself is NOT pulled by `forge-deploy`; it ships compose
files via `git clone` at a tag. Update the deploy repo with
`forge-deploy --self-update` (runs `git pull --ff-only` against
`/opt/forge-deploy` + reinstalls the CLI).

## Where to file what

- **Install/upgrade bug, compose issue, ops script bug** → here
- **App-level bug** → file in forge-ui or forge-api
