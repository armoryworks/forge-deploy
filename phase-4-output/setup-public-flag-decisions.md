# `--public` flag — design decisions

This documents the choices made when adding the `--public` macro to
`setup.sh` (and the lighter mirror in `setup.ps1`). These are the
load-bearing decisions; the implementation lives in `setup.sh`.

## What `--public` resolves to

- `--public` implies `--standalone --ssl` (the "this stack owns 80/443
  with HTTPS" pair).
- Incompatible with `--cohost` (opposite intent — that mode means an
  outer reverse proxy owns 80/443).
- Incompatible with `--no-ssl` (HTTPS is not optional in a public
  deploy macro).
- Both incompatibilities are hard errors at flag-parse time, before any
  preflight runs.

## Auto-offered port-conflict resolutions

When something is already listening on 80 or 443, the preflight matches
the listener's process name and offers an action:

| Listener | Action offered | Notes |
|---|---|---|
| `docker-proxy` | none — assumed OK | almost always a previous run of this stack; the new `compose up` reuses the binding |
| `nginx` | `sudo systemctl stop nginx && sudo systemctl disable nginx` | only when systemd manages it; otherwise abort with "stop manually" |
| `apache2` / `httpd` | `sudo systemctl stop <unit> && sudo systemctl disable <unit>` | same systemd guard |
| anything else | abort with the process name + PID and clear remediation | user must stop manually or pass `--no-public-preflight` |

The deliberate scope: only the two services that 99% of fresh-Ubuntu
testers will actually have running. Everything else is opaque to the
script (could be Caddy, lighttpd, a custom binary, an LSP language
server, anything) and must be resolved manually. Auto-killing arbitrary
listeners is too risky — see the project's existing `docker-proxy`
guidance in `CLAUDE.md`.

`docker-proxy` is special-cased because it's almost certainly a
previous run of this same stack (we don't auto-stop anything else's
docker-proxy either — that would defeat the existing port-ownership
discipline); the next `docker compose up -d` on the same project will
just reuse the binding.

## Firewall handling

- **UFW**: detected via `command -v ufw`. If active and 80/tcp or
  443/tcp aren't already allowed, prompt and run `sudo ufw allow X/tcp`.
  Existing rules are detected and skipped (idempotent).
- **firewalld / iptables / nftables / cloud security groups**: not
  auto-handled. Print an informational note and let the user verify.
  These have too many distro-specific permutations to safely automate.
- **No firewall installed**: silent no-op (no warning — assumed
  intentional on hardened hosts that manage their netfilter elsewhere).

## Cert hostname selection

Priority order:

1. `--hostname <fqdn>` flag — used directly, no prompt.
2. `hostname -f` (FQDN) — offered for confirmation:
   `Use detected hostname '<value>'? [Y/n/<custom>]`.
   - `Y` / Enter → use detected.
   - `n` → abort with instructions to re-run with `--hostname`.
   - any other input → use as the hostname (custom value).
3. `hostname` (short) as fallback if `-f` fails.
4. Final fallback `forge` (matches pre-existing default CN).

The cert subjectAltName always includes:
- `IP:<host primary IP>` (from `hostname -I`)
- `IP:127.0.0.1`
- `DNS:localhost`
- `DNS:<resolved hostname>` (when `--public` selected one)

This means existing localhost/IP access keeps working *and* the
hostname-based public URL gets a matching SAN, so browsers don't
trigger a separate warning when the user accesses by hostname.

## Rollback script

- File: `setup-public-rollback.sh` in the cwd, mode 0755.
- Generated **conditionally** — only if at least one preflight action
  actually ran. If port 80/443 were already free, UFW already had the
  rules, and the user passed `--hostname`, no rollback script appears.
  Reasoning: a rollback script that does nothing is misleading — the
  presence of the file implies "system state was changed."
- Each undoable action appends its inverse line(s) at the moment the
  forward action runs. If the user aborts mid-preflight (e.g., declines
  the UFW prompt after we've already stopped nginx), the rollback
  script still reflects exactly what was done.
- Script uses `|| true` after each command so a partial revert (e.g.
  user already manually re-enabled nginx) doesn't fail the whole run.
- Header includes the timestamp of the original `--public` invocation
  for ops/audit clarity.

## Port-check expansion (the existing prereq step)

The existing `CHECK_PORTS` list now includes 80 and 443 whenever the
resolved hosting mode will bind them:

- `--ssl` + standalone → 80, 443 (always was)
- `--public` → 80, 443 (via the implied --standalone --ssl)
- explicit `--standalone` (no SSL) or headless-detected standalone →
  80, 443 (now included; was missing before — UI binds 80 in that mode)
- `--cohost` → never includes 80/443 (cohost mode binds 127.0.0.1 only)

The check also identifies the holder process when possible (via `ss
-tlnpH` on Linux, `lsof` on macOS). `docker-proxy` is treated as
"likely a previous run of this stack" and reported but not flagged as
a conflict. This matches the production guidance in `CLAUDE.md` about
never blind-killing `docker-proxy`.

## Idempotence

Re-running `--public` on a host where the prep is already done is a
fast no-op:
- ports already free → "Port 80: free", "Port 443: free", no prompt.
- UFW rules already present → "UFW: 80/tcp and 443/tcp already
  allowed", no prompt.
- cert already present → existing `if [[ -f selfsigned.crt ]]` branch
  short-circuits before regeneration.
- rollback script not generated when nothing was done.

This is critical because tester walkthroughs and CI scenarios often
re-run setup.

## Windows mirror (setup.ps1)

Scope is intentionally narrower:

- `-Public` flag added; implies `-Standalone -Ssl`; same incompatibility
  errors with `-Cohost` / `-NoSsl`.
- Port-availability check expanded to include 80/443 when standalone /
  public / SSL is requested.
- Conflict reporter now identifies the holder via
  `Get-NetTCPConnection` + `Get-Process`.
- `-Hostname` parameter accepted (passed through to cert generation
  if/when the PowerShell path adds in-stack TLS — currently a marker).
- **No** systemctl logic (no equivalent on Windows; IIS / "World Wide
  Web Publishing Service" detection deliberately out of scope — too
  many distro-specific moving parts and a much smaller fresh-tester
  surface than Ubuntu).
- **No** UFW (Linux-only).
- `-NoPublicPreflight` accepted as a compatibility flag.

The Windows path is therefore mostly diagnostic: show the operator
what's wrong, let them fix it.

## What deliberately was NOT built

- **firewalld / iptables / nftables auto-config**: too many distro
  permutations; the failure mode (port unreachable from outside) is
  obvious and the operator can fix it once.
- **IIS / Windows W3SVC auto-stop**: low fresh-tester volume and the
  consequences of stopping IIS on a Windows host are larger than
  stopping system nginx on a fresh Ubuntu install.
- **Public-IP / DNS verification** (does the hostname actually resolve
  to this host, etc.): out of scope. Self-signed cert doesn't care
  about real DNS, and external reachability is a separate router/DNS
  step that's already documented in the existing setup.sh "Public
  Access" footer.
- **Let's Encrypt cert issuance**: deliberately not part of `--public`.
  Self-signed is the right default for testers (no rate-limit risk, no
  ACME challenge plumbing). LE belongs in a future `--lets-encrypt`
  flag with its own port-80 challenge / DNS-01 logic.
- **Auto-stop of unknown listeners**: never. If we can't identify the
  process as a known web server unit, we abort and ask the human.
