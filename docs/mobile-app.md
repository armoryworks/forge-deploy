# Mobile app — what the deploy box needs

The native Forge app (Android / iOS) talks only to the Forge instance it was
enrolled against. Nothing on the phone contacts Armory Works.

## Required

| Variable | Purpose |
|---|---|
| `MOBILE_INSTANCE_NAME` | Name shown on the phone during enrollment. |
| `MOBILE_CERT_SHA256` | SHA-256 of the public TLS certificate. Pinned on first enrollment (trust-on-first-use); every refresh re-checks it. **Set the new value here before the certificate rotates**, or every phone refuses to connect until re-enrolled. |
| `MOBILE_MIN_APP_VERSION` | Phones on an older build are told to update. |

Then enable `CAP-MOBILE-CORE` under Admin → Capabilities, plus one flag per
screen you want on phones: `CAP-MOBILE-SCAN`, `-CLOCK`, `-JOBS`, `-STOCK`,
`-LOOKUP`. Enrollment QR codes are issued from Admin → Devices.

TLS is mandatory: the app refuses plain `http://` servers.

## Optional: crash reporting (GlitchTip)

```
COMPOSE_PROFILES=crash-reporting
CRASH_SECRET_KEY=<long random>
CRASH_DB_PASSWORD=<random>
CRASH_PUBLIC_URL=https://forge.example.com/crash   # or a dedicated host
```

1. `docker compose up -d` — the `forge-crash*` services start.
2. Open the GlitchTip UI, create the first user (registration is closed after
   that), an organization and a project of type *JavaScript*.
3. Copy the project DSN into `MOBILE_CRASH_DSN`, restart `forge-api`.

Phones read the DSN from `/.well-known/forge.json` and post crashes there —
error, app build and screen only; never the person or their data. Each phone
has a "Send crash reports" toggle under Account. Reports expire after
`CRASH_RETENTION_DAYS`.

"Report a problem" on the phone is separate: it needs no extra service and
lands as a notification for every admin plus a warning in the API log.
