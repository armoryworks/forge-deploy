# Air-Gap Update Bundle

Design for delivering Forge updates (container images, DB migrations, seed data,
config) to an **air-gapped / SKIFF-mode** Forge box via removable media, and
applying them safely.

Derived from the 2026-07-02 planning session (cluster E). Companion effort:
`forge/docs/delivery/pending/functional-backlog-2026-07-02` (E) and the seed-refresh
tie-in with the `compliance-calendar` effort (A‑5).

> **Status: design + skeleton.** `scripts/forge-bundle` is an unwired skeleton
> pending review/testing. Not yet integrated into the `forge-deploy` CLI.

---

## Principle — authenticity over confidentiality

The original ask was an "encrypted USB that auto-decrypts on the destination." We
**reframed** it: for air-gapped updates the property that matters is **authenticity
+ integrity** ("is this a genuine, untampered update from us"), not secrecy.
Auto-decrypt with transparent embedded keys is a *weak* model — anyone who steals a
Forge box extracts the keys and can then forge or read any media.

**So: a signed update bundle on _any_ removable media, verified on import.**
Media-agnostic; matches how real air-gap tooling works (RKE2, Zarf, Rancher,
Replicated). Confidentiality, if a customer wants it, is an **optional** LUKS /
VeraCrypt layer on the media — orthogonal to the security boundary, never the thing
we rely on.

**Signing stack: cosign** (`sign-blob` / `verify-blob`). Container-native, verifies
fully offline with `--insecure-ignore-tlog --offline` against a bundled public key,
ships as a single static binary inside the bundle.

---

## Bundle format

A single tar (optionally compressed), content-addressable where it counts:

```
forge-bundle-<version>.tar
├── MANIFEST.json         # artifact list + sha256 each, bundle version, forge version, metadata
├── MANIFEST.json.sig     # cosign detached signature over MANIFEST.json
├── cosign.pub            # public key (convenience; trust anchor is the PRE-installed key on the box)
├── bin/cosign            # static cosign binary (verify offline, no network)
├── images/               # docker save / skopeo oci-archive tarballs (digest-pinned)
│   └── forge-api.tar ...
├── migrations/           # offline-generated SQL (Liquibase update-sql / Alembic --sql / EF idempotent script)
├── seeds/                # seed-data refresh (feeds A-5 compliance seeds, etc.)
└── config/               # compose overrides, .env deltas (non-secret)
```

`MANIFEST.json` (shape):

```json
{
  "bundleVersion": 42,                     // monotonic integer — anti-rollback
  "forgeVersion": "1.8.3",
  "createdAtUtc": "…",                     // stamped by the build host (not the air-gapped box)
  "artifacts": [
    { "path": "images/forge-api.tar", "sha256": "…", "imageDigest": "sha256:…" },
    { "path": "migrations/0043.sql",  "sha256": "…" }
  ]
}
```

The **trust anchor is the public key already installed on the box** (shipped at
provisioning), NOT the `cosign.pub` in the bundle — the bundled copy is convenience
only. Verify against the installed key.

---

## Build flow — `forge-bundle build` (internet-connected host)

1. Resolve the image set (digest-pinned tags from `ghcr.io/armoryworks/forge-*`).
2. `docker save` (or `skopeo copy --preserve-digests docker:// oci-archive:`) each
   image into `images/`.
3. Generate migration SQL **offline** (do not require a live DB): Liquibase
   `update-sql`, Alembic `--sql`, or the EF Core idempotent script.
4. Assemble `seeds/`, `config/`.
5. Compute sha256 for every artifact → write `MANIFEST.json` with the next
   `bundleVersion`.
6. `cosign sign-blob --key <release.key> MANIFEST.json > MANIFEST.json.sig`.
7. tar it up. (Optional: wrap the tar in LUKS/VeraCrypt if the customer wants
   confidentiality.)

## Apply flow — `forge-bundle apply` (air-gapped box) — **fail-closed order**

```
verify signature  →  verify checksums  →  anti-rollback  →  backup  →  load  →  migrate  →  record
```

1. **Verify signature** over `MANIFEST.json` with the **pre-installed** public key:
   `cosign verify-blob --key /etc/forge/keys/forge-release.pub
   --signature MANIFEST.json.sig --insecure-ignore-tlog MANIFEST.json`. Abort on fail.
2. **Verify checksums** — recompute sha256 of every artifact vs. MANIFEST; abort on
   any mismatch. (`docker load` itself verifies nothing, so this gate is mandatory.)
3. **Anti-rollback** — read installed version from `/etc/forge/bundle-state`; refuse
   if `bundleVersion <= installed`. Clock-free monotonic guard (air-gapped boxes have
   no trusted time for TUF/Uptane-style expiry freshness — so we use a stored
   counter instead).
4. **Backup** — `pg_dump` (or the existing `forge-backup` sidecar) before touching
   the DB; abort if the backup fails.
5. **Load** — `docker load` each image tar (or `skopeo copy` into the local
   registry). Only after gates 1–3 pass.
6. **Migrate** — apply migration SQL. Postgres DDL is transactional (wrap in a
   transaction; auto-rolls back on error) **except** `CREATE INDEX CONCURRENTLY` /
   `CREATE DATABASE`. **Destructive steps require an explicit `--allow-destructive`
   flag** (expand/contract; the backup from step 4 is the real rollback net).
7. **Record** — write the new `bundleVersion` to `/etc/forge/bundle-state`
   atomically (write-temp-then-rename) + append an audit line. Then
   `docker compose up -d` via the normal healthcheck-gated flow.

---

## What stays out of scope (process / infra, not scripting)

USB is exactly how air-gaps get breached (Stuxnet). These are **operational
controls**, not things `forge-bundle` can enforce:
- Physical media control + chain of custody.
- BadUSB / HID-injection defense, media sanitization / reimaging, a scanning kiosk.
- One-way transfer / data diodes for the highest-assurance sites.

Document these as customer runbook expectations; the script assumes the media is
trusted *enough* and relies on the **signature** as the real integrity gate.

---

## Relationships
- **A‑5 (compliance-calendar):** the `seeds/` payload is the refresh vehicle for
  seeded compliance deadlines on air-gapped boxes. A disconnected box updates its
  seeds only when it takes a bundle → hence the "seed as-of ⟨date⟩" disclaimer.
- **Online `forge-deploy`:** the connected flow keeps pulling from GHCR with
  healthcheck-gated rollback. `forge-bundle apply` reuses the same compose +
  healthcheck machinery for the final bring-up; the two share `/etc/forge` state.
- **Future:** fold `forge-bundle build|apply` into the `forge-deploy` CLI as
  `cmd_bundle` / `cmd_apply_bundle` once the skeleton is validated.

## Open questions
- Image transport: `docker save` vs. daemonless `skopeo` + a local `registry:2` on
  the box (better for multi-arch / multi-host)? Skeleton assumes `docker save`.
- Migration generator: standardize on EF Core idempotent scripts (matches the .NET
  stack) vs. a tool-neutral SQL bundle?
- Key management + rotation for the release signing key; where the box's trust
  anchor is provisioned and how it's rotated.
