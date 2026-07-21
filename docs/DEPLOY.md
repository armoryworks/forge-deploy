# Forge Deployment Guide

This document is the canonical install runbook for deploying a customer Forge instance. It assumes you are the operator and that the customer has been onboarded (engagement type, customer slug, subdomain, OAuth client where applicable).

The reference target for this guide is a Raspberry Pi 5 (16GB) with Ubuntu Server arm64 on an NVMe drive, fronted by Cloudflare Tunnel. The same procedure applies to amd64 hosts with minor changes; differences are called out inline.

---

## 1. Decide the customer parameters before you start

Pin these down before touching anything. They appear in `.env`, in DNS, in the tunnel config, in the backup paths, and in Drive integration mappings. Changing them later is painful.

- **Customer slug**: lowercase, hyphenated, no spaces. Used in `.env`, backup prefixes, log scopes. Example: `armory-plastics`.
- **Public subdomain**: `<slug>.armoryworks.com` or per the customer's preference. Confirm the exact subdomain with whoever controls DNS before you start; ambiguity here causes rework.
- **Engagement type**: paid / design-partner / internal. Drives which capabilities are enabled at first login.
- **Preset selection**: must come from the actual `PresetCatalog.cs` list. Confirm by reading the catalog at deploy time. Do not trust verbal handoffs about which preset "is" the customer's vertical — preset numbering has shifted historically.

---

## 2. Hardware and OS prerequisites

### Raspberry Pi 5 reference target

The target host needs:

- 16GB RAM (8GB is workable without the AI profile, tight with it).
- arm64 (aarch64) architecture. All Forge core images publish arm64 manifests, but a few optional profiles (TTS in particular) have shaky arm64 support.
- An NVMe drive as the root filesystem. **Do not run Forge with Postgres on an SD card** — IOPS torch the SLA inside a week.
- A wired or stable wireless network connection with outbound HTTPS to:
  - `github.com` (repo clone)
  - `ghcr.io` and `registry-1.docker.io` (image pulls)
  - `cdimage.ubuntu.com` (OS install media, if applicable)
  - `*.cloudflare.com` (tunnel)

### OS install: Ubuntu Server arm64

Use Raspberry Pi Imager from a PC and write the current Ubuntu Server LTS arm64 image directly to the NVMe via a USB-to-NVMe adapter. This is the path of least resistance.

If you don't have a USB-to-NVMe adapter and have to install via the USB-boot-then-clone path, read the `dd UUID collision` and `growpart GDT limit` sections in TROUBLESHOOTING.md first. Both will bite you.

After install, set the boot order in EEPROM so the Pi prefers NVMe (Pi 5: `BOOT_ORDER=0xf416` puts NVMe first, USB second, SD third). Edit via:

```bash
sudo rpi-eeprom-config --edit
```

For Pi 5 with NVMe HATs that show thermal or signal-integrity issues at PCIe Gen 3, pin to Gen 2 in `/boot/firmware/config.txt`:

```
dtparam=pciex1_gen=2
```

Reboot.

### Preflight checks

Confirm before continuing:

```bash
lsblk                  # root must be on /dev/nvme0n1p2, not /dev/mmcblk0pX
free -h                # ~15GiB usable on a 16GB Pi 5
uname -m               # aarch64
df -h /                # at least 20GB free
curl -sI https://github.com | head -1
curl -sI https://ghcr.io | head -1
```

All four URLs should return a non-error HTTP status (200, 404, or 405 are all fine — those endpoints just don't serve content at the bare URL, but their reachability is the actual test).

---

## 3. Install Docker and dependencies

> **Use apt Docker, NOT the snap.** Install Docker via `apt` (`docker.io`, or Docker CE from
> docs.docker.com) — **never `snap install docker`**. The snap daemon runs under an AppArmor profile
> that can't write a container's cgroup-v2 `cgroup.kill`, so `docker stop`/`rm`/`compose up --build`
> on a running container fail with `could not kill container: permission denied` — teardown/recreate
> is broken, which cripples both the dev loop and deploys. `setup.sh` hard-fails if it detects the
> snap on cgroup v2; the full write-up is in [TROUBLESHOOTING.md](TROUBLESHOOTING.md) → Host setup.
> If a box already has the snap: back up any volumes, `sudo snap remove docker`, then install via apt.

Ubuntu 24.04 names the compose plugin `docker-compose-v2`, **not** `docker-compose-plugin` (which is the upstream Docker name). Don't waste time fighting `apt`:

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-v2 git curl jq age
sudo usermod -aG docker $USER
```

Log out and back in for the docker group membership to take effect, then verify:

```bash
docker --version
docker compose version
git --version
groups | grep -q docker && echo OK
# Sanity-check you're NOT on the snap (should print an apt path, not /var/snap/docker/...):
docker info --format 'Docker root: {{.DockerRootDir}}'
```

---

## 4. Authenticate Docker against GHCR

Forge images on `ghcr.io/armoryworks/*` are private. Without authentication the setup script will fail with an unhelpful `unauthorized` error and suggest `--source` mode, which is not what you want.

Create or retrieve a GitHub Personal Access Token with **`read:packages`** scope (only that scope; nothing else needs to be enabled). The AWT private repo's `secrets/` directory may already contain a service-account PAT; check there first.

Log in:

```bash
docker login ghcr.io -u <github-username>
# Paste the PAT at the password prompt
```

You should see `Login Succeeded`. The credential is written to `~/.docker/config.json` and persists across reboots.

---

## 5. Get the deploy tree (npx, npm, or git clone)

The deploy scripts and compose configuration live in `forge-deploy`, not the application repo. Three equivalent ways to get it onto the host — all end at the same tree with the same `setup.sh`:

**Option A — npx (one-shot, no Node knowledge needed beyond having Node 18+):**

```bash
sudo mkdir -p /opt/forge-deploy && sudo chown $USER:$USER /opt/forge-deploy
npx @armoryworks/forge-deploy /opt/forge-deploy --fetch-only
cd /opt/forge-deploy
```

The installer downloads the current `main` tree from GitHub. Drop `--fetch-only` to have it run `setup.sh` immediately after fetching (setup flags pass straight through, e.g. `npx @armoryworks/forge-deploy /opt/forge-deploy --public`). `npx` keeps nothing installed and always runs the latest published installer.

**Option B — npm global install (persistent `forge-deploy` command):**

```bash
npm install -g @armoryworks/forge-deploy
forge-deploy /opt/forge-deploy --fetch-only
```

Same behavior; the CLI stays on the PATH. It pins the *installer* at the installed version until you `npm update -g` — but since the deploy tree is always fetched fresh from GitHub, a stale installer only matters if the bootstrapper itself changed.

**Option C — git clone (no Node required; what the installer does under the hood):**

```bash
sudo mkdir -p /opt/forge-deploy
sudo chown $USER:$USER /opt/forge-deploy
git clone https://github.com/armoryworks/forge-deploy.git /opt/forge-deploy
cd /opt/forge-deploy
chmod +x setup.sh
```

A git clone additionally gives you `git pull` for updates and local history — preferable for operator-managed installs you'll revisit. The npx/npm path re-fetches over the same directory to update (it preserves `.env`, overrides, and volumes).

You do **not** need to clone the application source repos (`forge-api`, `forge-ui`, `forge-test`) for a production deploy. Those are only needed if you intend to build images from source with `./setup.sh --source` (developer mode).

---

## 6. Run setup.sh

`setup.sh` is the canonical bootstrap. It generates `.env`, creates the JWT signing key, prompts for the seed admin password, applies architecture-specific overrides (arm64 + low-RAM tuning), pulls or builds images, and brings the stack up.

### Flag selection

First decide the deployment target — how people will reach the install:

| Target | Flag | What it does |
|---|---|---|
| This machine only | `--local` | Localhost URLs, classic dev-workstation default. |
| Other PCs on the customer's LAN | `--lan` | Plain HTTP at the host's LAN IP, no domain/DNS/cert. Binds the UI to `0.0.0.0` and points `FRONTEND_BASE_URL` / `CORS_ORIGINS` / `MINIO_PUBLIC_ENDPOINT` at the LAN IP so browsers on other machines work out of the box. |
| Public internet | `--public` | Standalone HTTPS on 80/443 with self-signed cert and system preflight. |

With no flag, interactive runs are prompted (local / LAN / public) and the answer is saved to `.env` as `QBE_DEPLOY_TARGET`, so re-runs and `refresh.sh` never re-ask. Non-interactive runs default to local.

`--lan` is also the fix for an already-installed box that got the headless auto-SSL default (symptom: LAN clients get *connection refused* on `:4200` because it's pinned to loopback). Re-running `./setup.sh --lan` converts the install in place: drops the SSL override, rebinds the UI, and rewrites the URLs to `http://<lan-ip>:4200`. Note the URLs embed the host's IP — if the box is on DHCP, get the customer to add a DHCP reservation on their router, or re-run `--lan` after an IP change.

For a typical customer POC/UAT deploy fronted by Cloudflare Tunnel:

```bash
./setup.sh --cohost
```

Why `--cohost`:

- Binds the UI nginx to `127.0.0.1:4200`, not `0.0.0.0:80`. The Pi is unreachable from the LAN — only the tunnel can reach it.
- Skips self-signed SSL generation (the tunnel terminates TLS at the Cloudflare edge using the zone's existing cert).

Flags **not** to set unless you have a specific reason:

- `--seeded` — loads demo customers, jobs, and users. Never use for UAT or production.
- `--include-ai`, `--include-tts`, `--include-signing` — optional profiles. Skip unless the customer has explicitly requested them. AI adds ~5GB resident memory and noticeable CPU on a Pi.
- `--source` — local-build mode. Requires sibling source repos and is slow on a Pi. Use only for developer-mode installs.

### What it will ask you

Setup will prompt interactively for:

- **Deployment target** (only if no target flag was passed and none is saved in `.env`) — "How will people reach this Forge install?" local / LAN / public, as described under Flag selection above.
- **Customer slug** — answer with the value you pinned in step 1.
- **Seed admin password** — choose a strong one and save it. This is the only way to log in initially.
- Possibly **admin email** and **hostname**. Use real values.

It will not prompt for the preset or for capability enablement. Those are admin-UI operations after first login (see step 9).

### Image pull and bring-up

Setup runs `docker compose pull` and `docker compose up -d`. On a Pi this typically takes 5–10 minutes for the first run depending on network and SD/NVMe speed. Watch for:

- Any image that fails to pull with `unauthorized` — re-check the `docker login ghcr.io` step.
- Any image that fails with `no matching manifest for linux/arm64` — that image lacks an arm64 build. Flag upstream; this is a packaging bug, not a config one.

### Host network watchdog (installed automatically on Linux)

At the end of the deploy, `setup.sh` installs a small systemd-driven network watchdog at `/usr/local/sbin/forge-network-watchdog`. It runs every minute, pings `1.1.1.1`, `8.8.8.8`, and the host's default gateway, and on persistent failure restarts networking, then reboots the host. This catches the well-known Pi failure mode where the OS stays alive but the NIC firmware hangs (SSH unreachable, Cloudflare tunnel surfaces 530, the router doesn't see the MAC). The hardware watchdog can't recover from this mode because systemd keeps petting it; the layer-3 reachability check is what triggers recovery.

Two safety nets keep the recovery path from making things worse:

- **TCP-connect fallback.** If every ICMP probe fails, the watchdog tries TCP 443 against the public targets before concluding the network is dead. Networks that drop ICMP to public IPs while allowing HTTPS (common on managed / enterprise gateways) therefore don't false-trigger a reboot.
- **Reboot rate limit.** At most 3 reboots per hour, tracked across reboots in `/var/lib/forge-watchdog/reboot-history`. Beyond that the watchdog keeps restarting networking and logging loudly but stops rebooting — a sustained LAN failure (unplugged cable, dead router over a weekend, dead USB-Ethernet adapter) won't put the box into an indefinite reboot loop that just wears the SD card.

Opt out with `--skip-host-watchdog` to `setup.sh` if a customer has their own host-resilience tooling. To install or reinstall by hand on an existing host:

```bash
sudo ./scripts/install-host-watchdog.sh
```

To inspect after install:

```bash
systemctl status forge-network-watchdog.timer
systemctl list-timers forge-network-watchdog.timer
journalctl -u forge-network-watchdog.service --since today
cat /var/log/network-watchdog.log         # silent on success; only writes on failure
```

---

## 7. Verify the stack

After setup completes, confirm all containers are up:

```bash
docker compose ps
```

Expected state:

| Service          | Image                                | Status             |
|------------------|--------------------------------------|--------------------|
| `forge`          | `pgvector/pgvector:pg17`             | `Up (healthy)`     |
| `forge-api`      | `ghcr.io/armoryworks/forge-api:latest` | `Up (healthy)`     |
| `forge-storage`  | `minio/minio`                        | `Up (healthy)`     |
| `forge-ui`       | `ghcr.io/armoryworks/forge-ui:latest`  | `Up (healthy)`     |
| `forge-backup`   | (image varies)                       | `Up` or running on cron |

One nuance worth knowing:

- The API's health endpoint is **`/api/v1/health`**, not `/health`. Some older notes say otherwise.

Verify the API is responding to all its subchecks:

```bash
curl -s http://localhost:5000/api/v1/health | jq
```

You should see `"status": "Healthy"` and four subchecks (`postgresql`, `hangfire`, `minio`, `signalr`) all `"Healthy"`.

---

## 8. Configure the public ingress

This guide covers the **Cloudflare Tunnel** path. For Tailscale Funnel or direct port-forwarding alternatives, see `docs/INGRESS-ALTERNATIVES.md` (to be added).

### Install cloudflared (arm64)

The official `cloudflared` deb installer is amd64-only. On arm64 (Pi), use the architecture-specific binary:

```bash
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 \
  -o /tmp/cloudflared
sudo install /tmp/cloudflared /usr/local/bin/cloudflared
cloudflared --version
```

### Authenticate to Cloudflare

```bash
cloudflared tunnel login
```

This prints a one-time URL. Open it in a browser on a machine that's logged into the Cloudflare account, select the `armoryworks.com` zone (or whichever zone owns the customer subdomain), and approve. Cloudflare writes `~/.cloudflared/cert.pem` on the Pi.

### Create the tunnel and write config

```bash
TUNNEL_NAME="<slug>-prod"   # e.g., armoryplastics-prod
cloudflared tunnel create $TUNNEL_NAME
TUNNEL_UUID=$(cloudflared tunnel list | grep -w $TUNNEL_NAME | awk '{print $1}')

cat > ~/.cloudflared/config.yml <<EOF
tunnel: $TUNNEL_NAME
credentials-file: $HOME/.cloudflared/${TUNNEL_UUID}.json

ingress:
  - hostname: <slug>.armoryworks.com
    service: http://127.0.0.1:4200
  - service: http_status:404
EOF
```

**One ingress rule is correct.** The forge-ui nginx container handles all internal path routing (`/api/*` → forge-api, `/hubs/*` → forge-api with WebSocket upgrade, `/docuseal/*` → forge-signing when enabled, everything else → SPA fallback). Do not add separate hostnames for the API or hubs.

### Route DNS

```bash
cloudflared tunnel route dns $TUNNEL_NAME <slug>.armoryworks.com
```

If you get `An A, AAAA, or CNAME record with that host already exists`, delete the existing record in the Cloudflare dashboard first.

### Test in foreground, then install as a service

```bash
cloudflared tunnel run $TUNNEL_NAME
# From another machine: curl -I https://<slug>.armoryworks.com
# Expect HTTP/2 200 with an nginx Server header.
# Ctrl+C when satisfied.

sudo cloudflared --config $HOME/.cloudflared/config.yml service install
sudo systemctl enable --now cloudflared
sudo systemctl status cloudflared --no-pager | head -15
```

---

## 9. First-login configuration

With the public URL live, log in as the seed admin (the username and password you set during `setup.sh`).

### Apply the preset

Navigate to `/admin/presets`. Choose the preset that matches the customer's vertical from the actual catalog — do not assume preset numbering from prior documentation. As of this writing the catalog includes:

| ID         | Name                          |
|------------|-------------------------------|
| PRESET-01  | Two-Person Shop               |
| PRESET-02  | Growing Job Shop              |
| PRESET-03  | Distribution / Wholesale      |
| PRESET-04..07 | (other named profiles)     |
| PRESET-08  | Pro Services                  |
| PRESET-09  | Hybrid (Pro Services + Mfg)   |
| PRESET-CUSTOM | Hand-picked capabilities   |

Confirm by reading `PresetCatalog.cs` at deploy time. Picking the wrong preset disables core capabilities the customer needs.

### Set the ASP.NET Core environment to a non-Development value before going live

The MockClock (`POST /api/v1/dev/clock`) is gated on `ASPNETCORE_ENVIRONMENT=Development`, **not** on `MOCK_INTEGRATIONS`. If the image defaults to Development, you can shift the system clock via the API — unacceptable for UAT or production. Confirm the environment value in the running container:

```bash
docker compose exec forge-api env | grep ASPNETCORE
docker compose logs forge-api --tail 50 | grep -i clock
```

If you see `MockClock (development)` in the startup log, set `ASPNETCORE_ENVIRONMENT=Production` (or `Staging`) in `.env` (or directly in the `forge-api` service block in `docker-compose.yml`), then `docker compose up -d --force-recreate forge-api`. The startup line should read `Clock: SystemClock` with no `(development)` suffix.

### Strip capabilities for the engagement scope

For design-partner ($0) or scoped POCs, disable capabilities outside the deal scope. This is per-customer; there is no canonical "design partner cap set". Walk `/admin/capabilities` with the engagement scope document in hand and toggle accordingly.

### Harden MinIO credentials (if not already done)

setup.sh ships with `MINIO_ROOT_USER=minioadmin` and `MINIO_ROOT_PASSWORD=minioadmin`. Even on a private tunnel, leaving the defaults is sloppy. **Do not edit `.env` while MinIO has live data without using the rotation protocol** — see TROUBLESHOOTING.md → "MinIO credentials don't rotate when I edit .env".

For a fresh deploy (no real data yet), the safe rotation is:

```bash
cd /opt/forge-deploy
docker compose down
sed -i "s/^MINIO_ROOT_USER=.*/MINIO_ROOT_USER=forge-admin/" .env
NEW_PW=$(openssl rand -base64 24 | tr -d '/+=')
echo "New MinIO password: $NEW_PW"   # SAVE THIS
sed -i "s|^MINIO_ROOT_PASSWORD=.*|MINIO_ROOT_PASSWORD=$NEW_PW|" .env
docker volume rm forge-deploy_miniodata   # wipes any data — only safe for fresh deploys
docker compose up -d
```

---

## 10. Backups

forge-backup runs `pg_dump` plus a MinIO mirror on a cron schedule and pushes off-site via `rclone`. Configuration lives in `.env` and in the `forge-backup` service's mounted config.

For AWT-managed customer instances, the off-site target is the AWT Backblaze B2 bucket under a per-customer prefix. Apply the `backup-destination.yaml` template from the AWT private repo's `secrets/` directory and adjust the prefix to match the customer slug.

Verify with a manual run before considering the install complete:

```bash
docker compose exec forge-backup /usr/local/bin/backup-now
# or whatever the manual-trigger script is named in this version
```

Confirm a fresh dump lands in the B2 bucket under the customer prefix.

---

## 11. What "done" looks like

A deploy is complete when:

- All five core services are `Up` and the four health subchecks return `Healthy`.
- The public URL returns 200 with content (not 502 from the tunnel).
- Login as the seed admin succeeds and shows the customer-specific preset applied.
- A manual backup writes successfully to off-site storage.
- The seed admin password and MinIO root password are stored in the team password manager.
- A handoff note has been written for the customer covering: how to log in, where to file issues, expected response time for the engagement.

---

## 12. Upgrading and rolling back

### Upgrades

```bash
cd /opt/forge-deploy
git pull                              # pick up any compose / config changes
docker compose pull                   # pull latest image tags referenced in .env
docker compose up -d                  # recreate containers that have new images
docker compose logs forge-api --tail 50    # confirm clean startup, no DI/migration errors
curl -s http://localhost:5000/api/v1/health | jq
```

forge-api applies any pending EF Core migrations automatically on startup. There is no manual migration step. This is convenient for forward deploys but has a hard implication for rollbacks (see below).

### Rollbacks

Because migrations are applied at startup and are forward-only, the database schema is always at-or-ahead of whatever image last ran successfully. Deploying an older image against a newer schema will fail at startup with EF Core errors.

The safe rollback procedure is:

1. Stop forge-api: `docker compose stop forge-api`.
2. Identify the latest forge-backup `pg_dump` taken *before* the upgrade you're rolling back from.
3. Restore that dump into the `forge` (Postgres) container.
4. Pin the older image tag in `.env` (`SERVER_IMAGE_TAG=<older-tag>`).
5. `docker compose up -d --force-recreate forge-api`.

Any release that ships a schema migration must add a note to its CHANGELOG entry: "downgrade requires manual rollback from backup."

---

## Appendix: useful commands

```bash
# Tail logs for a single service
docker compose logs forge-api -f --tail 50

# Restart a single service without taking the rest down
docker compose restart forge-api

# Force-recreate a service after .env changes
docker compose up -d --force-recreate forge-api

# Inspect what env a running container actually sees
docker compose exec forge-api env | grep -i minio

# See the public URL's path from inside the cloudflared service
sudo journalctl -u cloudflared -n 50 -f
```
