# @armoryworks/forge-deploy

Installer for **Forge**, a self-hosted shop management system for small
manufacturers and job shops — jobs, scheduling, inventory, purchasing,
sales, quality, maintenance, and shop-floor kiosks, running entirely on
your own hardware via Docker.

This package is a thin bootstrapper. It downloads the current deploy tree
from [armoryworks/forge-deploy](https://github.com/armoryworks/forge-deploy)
and hands off to the setup script, which pulls prebuilt multi-arch images
(amd64 + arm64) from GHCR and brings the stack up. You always get the
latest deploy configuration — no waiting on an npm release.

## Quick start

```bash
npx @armoryworks/forge-deploy
```

That fetches the deploy tree into `./forge-deploy` and runs interactive
setup. It auto-detects platform, architecture, and available resources,
and asks how you want to deploy (this machine only / LAN / public).

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
npx @armoryworks/forge-deploy /opt/forge --lan
```

## Requirements

- **Docker** with the compose plugin (`docker compose`)
- **Node.js 18+** (only to run this installer)
- Linux or macOS with `bash` and `tar`; Windows 10+ uses `setup.ps1` via
  PowerShell automatically
- 4 GB RAM recommended — low-RAM systems get automatic memory tuning

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
| `--include-signing` | Also start the DocuSeal e-signature service |
| `--include-all` | All optional services |
| `--source` | Developer mode — build images locally from sibling source repos |
| `--fetch-only` | (installer flag) Download the deploy tree but don't run setup |

The full list is documented at the top of
[`setup.sh`](https://github.com/armoryworks/forge-deploy/blob/main/setup.sh).

## Updating

Re-run the same command in place:

```bash
npx @armoryworks/forge-deploy /opt/forge
```

The installer refreshes the deploy files and re-runs setup, which pulls
newer images. Your `.env`, compose overrides, and data volumes are left
untouched — configuration and data survive updates.

## What you get

A Docker Compose stack: the Forge API (.NET), the web UI (Angular behind
nginx), PostgreSQL, MinIO object storage, and a nightly backup service —
plus optional AI, TTS, and e-signature containers.

## Documentation

- [Deployment guide](https://github.com/armoryworks/forge-deploy/blob/main/docs/DEPLOY.md)
- [Troubleshooting](https://github.com/armoryworks/forge-deploy/blob/main/docs/TROUBLESHOOTING.md)
- [Backup & restore](https://github.com/armoryworks/forge-deploy/blob/main/docs/backup-restore.md)

## License

[Apache-2.0](https://github.com/armoryworks/forge-deploy/blob/main/LICENSE)
