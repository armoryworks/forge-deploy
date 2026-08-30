# @armoryworks/forge-deploy

Installer for **Forge**, a self-hosted shop management system for small
manufacturers and job shops — jobs, scheduling, inventory, purchasing,
sales, quality, maintenance, and shop-floor kiosks, running entirely on
your own hardware via Docker.

This package is a thin bootstrapper. It downloads a **pinned release** of the
deploy tree from [armoryworks/forge-deploy](https://github.com/armoryworks/forge-deploy)
and hands off to it. The tree pulls prebuilt multi-arch images (amd64 + arm64)
from GHCR and brings the stack up. The tree is pinned to a tested tag, not to
`main`, so the package version you run determines exactly what you get — and
the tool tells you when a newer one is published.

## Already have Forge installed?

One command, no arguments:

```bash
npx @armoryworks/forge-deploy
```

Type it from anywhere — it finds the install on this machine rather than
assuming a directory, and opens a guided console: what is installed, whether it
is healthy, whether a newer release exists, and a short numbered menu —
upgrade, repair, diagnose why it can't be reached, history, quit. If a newer
installer is available it offers that first, applies it, and reopens itself.
Every action that changes anything runs the same gated path (backup → schema
reconcile → swap → health gate → automatic rollback), so nothing the menu can
do skips a safeguard.

## First install

```bash
npx @armoryworks/forge-deploy
```

On a machine with no Forge on it, the same command fetches the deploy tree into
`./forge-deploy`, installs the `forge-deploy` CLI (one sudo prompt), and runs
interactive setup. It auto-detects platform, architecture, and available
resources, and asks how you want to deploy (this machine only / LAN / public).

Afterwards there are two commands, and the second one is optional:

```bash
npx @armoryworks/forge-deploy    # from anywhere — finds the install, opens the console
forge-deploy                     # the same console, once the CLI is on your PATH
```

Common variants:

```bash
# Evaluate with demo data (users, jobs, customers) already loaded
npx @armoryworks/forge-deploy --seeded

# Turnkey LAN install — other PCs on your network reach the UI at this
# host's LAN IP. No domain, DNS, or certificate needed.
npx @armoryworks/forge-deploy --lan

# Expose to the internet with HTTPS: implies standalone nginx + self-signed
# TLS, and runs a system preflight (frees ports 80/443, opens UFW rules)
npx @armoryworks/forge-deploy --public

# Choose the install directory (first bare argument)
npx @armoryworks/forge-deploy /opt/forge-deploy --lan
```

`/opt/forge-deploy` is the conventional location — it is the default the
`forge-deploy` CLI and the docs assume — but any directory you own works.

> **GHCR access.** The `ghcr.io/armoryworks/*` images are not anonymously
> pullable. Before installing, run `docker login ghcr.io -u <github-username>`
> and paste a GitHub personal access token that has the `read:packages`
> scope. (Or skip GHCR entirely with `--source`, which builds the images
> from the sibling source repos.)

## npx or npm install?

Either works, and both end up running the same `forge-deploy` command:

```bash
# One-shot (recommended): downloads to a temp cache, runs once, leaves
# nothing installed. Always executes the latest published version.
npx @armoryworks/forge-deploy --lan

# Persistent install: keeps the CLI on your PATH as `forge-deploy`.
npm install -g @armoryworks/forge-deploy
forge-deploy --lan
```

The difference is only what's left behind. A global install stays at
whatever version you installed until you `npm update -g` — but since the
deploy tree itself is always fetched fresh from GitHub, a stale global
install only matters if the bootstrapper itself changed.

## Requirements

- **Docker** with the compose plugin (`docker compose`)
- **Node.js 18+** (only to run this installer)
- `bash` and `tar` on Linux or macOS; on Windows 10+ this installer calls
  `setup.ps1` via PowerShell automatically
- 4 GB RAM minimum, 8 GB+ recommended — low-RAM systems get automatic
  memory tuning

## Options

Everything starting with `-` is passed straight through to the setup
script. The most useful flags:

| Flag | What it does |
|------|--------------|
| `--seeded` | Seed demo data (users, jobs, customers, etc.) |
| `--fresh` | Wipe the existing database and start over (`--fresh --seeded` to reseed) |
| `--local` | This machine only — localhost URLs, no network exposure |
| `--lan` | Serve the UI to your local network over HTTP at this host's LAN IP |
| `--public` | Full "expose to the internet with HTTPS" macro (standalone + SSL + preflight) |
| `--ssl` / `--no-ssl` | Force or skip the self-signed certificate |
| `--hostname <fqdn>` | Hostname for the certificate CN/SAN (otherwise auto-detected) |
| `--cohost` | Run behind an existing host-level reverse proxy (nginx, Caddy, cloudflared) |
| `--include-ai` | Also start the Ollama AI assistant |
| `--include-tts` | Also start Coqui TTS for training-video narration |
| `--include-signing` | Also start the DocuSeal e-signature service |
| `--include-all` | All optional services |
| `--source` | Developer mode — build images locally from sibling source repos |
| `--doctor` | Diagnose instead of install: checks the stack, TLS, firewall, public IP, and probes reachability from the internet, then prints the exact next actions (including router port-forward rules) |
| `--fetch-only` | (installer flag) Download the deploy tree but don't run setup |

If your deploy tree lives somewhere unusual, `FORGE_DEPLOY_DIR=/path/to/tree`
tells the bare command where to look.

The full list is documented at the top of
[`setup.sh`](https://github.com/armoryworks/forge-deploy/blob/main/setup.sh).

## Something not working?

The same one command. Open the console and pick *"Forge runs here but people
cannot reach it — find out why"*:

```bash
npx @armoryworks/forge-deploy
```

It triages the whole install — stack health, HTTPS, firewall, public IP,
router/NAT problems, and whether the internet can actually reach you — and ends
with plain-language instructions for whatever it finds. It changes nothing and
is safe to re-run until every check reads `[OK]`.

`npx @armoryworks/forge-deploy --doctor` still runs it directly, for scripts.

## Updating

To move a running install to a newer release, use the gated upgrade path:

```bash
npx @armoryworks/forge-deploy upgrade                # newest release
npx @armoryworks/forge-deploy upgrade 1.2.3          # a specific release
```

That refreshes the deploy tree and then hands off to `scripts/forge-deploy`,
which runs the whole sequence: verify the tag exists in GHCR → pin `.env`
→ fresh backup → **database schema reconcile** → container swap → health
gate → automatic rollback of the pin if anything fails. Forge has no EF
Core migrations; the schema reconcile is what brings a populated database
forward, so a bare `docker compose pull && up` is not a supported upgrade.
The target directory defaults to `/opt/forge-deploy` — pass another as a
bare argument.

To refresh only the deploy files (compose configuration, scripts) without
changing versions, re-run the installer in place:

```bash
npx @armoryworks/forge-deploy /opt/forge-deploy
```

Either way your `.env`, compose overrides, and data volumes are left
untouched — configuration and data survive updates.

## What you get

A Docker Compose stack: the Forge API (.NET), the web UI (Angular behind
nginx), PostgreSQL 18 with pgvector, MinIO object storage, and a backup
service that takes a `pg_dump` nightly — plus optional AI, TTS, logging,
crash-reporting, and e-signature containers.

## Documentation

- [Deployment guide](https://github.com/armoryworks/forge-deploy/blob/main/docs/DEPLOY.md)
- [Troubleshooting](https://github.com/armoryworks/forge-deploy/blob/main/docs/TROUBLESHOOTING.md)
- [Backup & restore](https://github.com/armoryworks/forge-deploy/blob/main/docs/backup-restore.md)
- [Outbound email setup](https://github.com/armoryworks/forge-deploy/blob/main/docs/email-setup.md)
- [Air-gapped bundle](https://github.com/armoryworks/forge-deploy/blob/main/docs/airgap-bundle.md)

## License

[Apache-2.0](https://github.com/armoryworks/forge-deploy/blob/main/LICENSE)
